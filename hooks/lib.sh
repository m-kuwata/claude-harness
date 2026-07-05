#!/usr/bin/env bash
# lib.sh — エンジン共有関数。全フック・スクリプトが source する。
# 依存: jq(必須), yq または python3+PyYAML(コンパイル時), python3(コンパイル時)

HARNESS_ENGINE_VERSION="0.1.0"
STATE_ROOT="${HARNESS_STATE_DIR:-/tmp/claude-harness}"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- プロジェクトルート解決 -------------------------------------
# フック stdin の cwd → CLAUDE_PROJECT_DIR → pwd の順
resolve_root() {
  local cwd="$1"
  local root=""
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    root=$(cd "$cwd" && git rev-parse --show-toplevel 2>/dev/null || echo "$cwd")
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    root="$CLAUDE_PROJECT_DIR"
  else
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  fi
  echo "$root"
}

project_hash() { echo -n "$1" | md5sum | cut -c1-12; }

lock_path() { echo "$STATE_ROOT/locks/$(project_hash "$1").lock.json"; }

# ---- harness.yaml → lock.json コンパイル -------------------------
# 戻り値: 0=成功 / 2=YAMLパーサなし / 3=バリデーション失敗
# 失敗理由は stderr へ
yaml_to_json() {
  local yaml="$1" out
  # PyYAML 優先（挙動が一意）。yq は mikefarah 版 / kislyuk 版の両構文を試す
  if python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import yaml,json,sys; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$yaml"
    return $?
  fi
  if command -v yq >/dev/null 2>&1; then
    if out=$(yq -o=json '.' "$yaml" 2>/dev/null); then echo "$out"; return 0; fi   # mikefarah
    if out=$(yq '.' "$yaml" 2>/dev/null); then echo "$out"; return 0; fi           # kislyuk
    return 4
  fi
  return 2
}

compile_lock() {
  local root="$1"
  local yaml="$root/.claude/harness.yaml"
  local lock; lock=$(lock_path "$root")
  [ -f "$yaml" ] || return 1
  mkdir -p "$(dirname "$lock")"
  local json
  json=$(yaml_to_json "$yaml") || {
    local rc=$?
    if [ "$rc" = 2 ]; then
      echo "harness: YAML パーサがありません。python3 に PyYAML を導入するか、yq (https://github.com/mikefarah/yq) をインストールしてください。" >&2
    else
      echo "harness: harness.yaml のパースに失敗しました（YAML 構文を確認してください）。" >&2
    fi
    return 2
  }
  echo "$json" | python3 "$LIB_DIR/../scripts/compile.py" \
    --source "$yaml" --root "$root" --engine-version "$HARNESS_ENGINE_VERSION" \
    > "$lock.tmp" 2>"$lock.err" || { cat "$lock.err" >&2; rm -f "$lock.tmp" "$lock.err"; return 3; }
  rm -f "$lock.err"
  mv "$lock.tmp" "$lock"
}

# lock を最新化して返す。harness.yaml が無ければ 1（エンジン不活性）
ensure_lock() {
  local root="$1"
  local yaml="$root/.claude/harness.yaml"
  local lock; lock=$(lock_path "$root")
  [ -f "$yaml" ] || return 1
  if [ ! -f "$lock" ] || [ "$yaml" -nt "$lock" ]; then
    compile_lock "$root" || return $?
  fi
  echo "$lock"
}

# ---- セッション状態 ----------------------------------------------
state_path() { # $1=lock $2=session_id
  local project; project=$(jq -r '.project.name' "$1")
  echo "$STATE_ROOT/$project/$2.json"
}

init_state() { # $1=state_path $2=session_id
  mkdir -p "$(dirname "$1")"
  [ -f "$1" ] || jq -n --arg sid "$2" \
    '{schema:0, session_id:$sid, workflow:null, ticket:null,
      started_at:(now|todate), dirty:{}, gates:{}, pending_token:null}' > "$1"
}

# Bash ツールから呼ばれるスクリプト用のセッション ID 解決。
# 1) CLAUDE_SESSION_ID 環境変数
# 2) SessionStart フックが記録した祖先 PID → session_id マッピング
resolve_session_id() {
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then echo "$CLAUDE_SESSION_ID"; return 0; fi
  local pid=$$ map="$STATE_ROOT/by-pid"
  while [ "$pid" -gt 1 ] 2>/dev/null; do
    if [ -f "$map/$pid" ]; then cat "$map/$pid"; return 0; fi
    pid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null) || break
    [ -n "$pid" ] || break
  done
  return 1
}

record_session_pid() { # SessionStart から呼ぶ。$1=session_id
  local map="$STATE_ROOT/by-pid"
  mkdir -p "$map"
  echo "$1" > "$map/$PPID"
}

# ---- ファイル分類 -------------------------------------------------
# $1=lock $2=プロジェクトルート相対パス → マッチしたクラス名を1行ずつ出力
classify_file() {
  local lock="$1" rel="$2"
  jq -r --arg f "$rel" '
    .paths // {} | to_entries[] |
    .value.include_re as $inc | .value.exclude_re as $exc |
    select(($f | test($inc)) and (($exc == null) or (($f | test($exc)) | not))) |
    .key' "$lock" 2>/dev/null
}

# 絶対パスをルート相対に。ルート外なら空
rel_path() { # $1=root $2=path
  local p="$2"
  [[ "$p" = /* ]] || { echo "$p"; return; }
  case "$p" in
    "$1"/*) echo "${p#"$1"/}" ;;
    *) echo "" ;;
  esac
}

# ツール入力から編集対象ファイル一覧を抽出
extract_files() { # stdin JSON 全体を $1 に受ける
  echo "$1" | jq -r '
    .tool_input.file_path // .tool_input.notebook_path //
    (.tool_input.edits[]?.file_path) // empty' 2>/dev/null | sort -u
}

new_token() { head -c16 /dev/urandom | md5sum | cut -c1-16; }

# 24h 超の状態・マーカー・PIDマップを掃除
gc_state() {
  find "$STATE_ROOT" -type f -mmin +1440 -delete 2>/dev/null || true
  find "$STATE_ROOT" -type d -empty -delete 2>/dev/null || true
}
