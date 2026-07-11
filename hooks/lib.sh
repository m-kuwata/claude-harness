#!/usr/bin/env bash
# lib.sh — エンジン共有関数。全フック・スクリプトが source する。
# 依存: jq(必須), yq または python3+PyYAML(コンパイル時), python3(コンパイル時)

HARNESS_ENGINE_VERSION="0.9.0"
STATE_ROOT="${HARNESS_STATE_DIR:-/tmp/claude-harness}"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# harness.yaml に書かれた run:/verify:/inventory: コマンドをエンジンが eval する際に
# 使える、プラグインルートへの確実な参照。Claude Code の ${CLAUDE_PLUGIN_ROOT} は
# hooks.json 等 Claude Code 自身が解釈するフィールド専用のテキスト置換であり、
# このスクリプトが eval する任意コマンド内で環境変数として展開される保証がない
# （実地未検証）。harness.yaml 側で確実に使えるのはこの変数。
HARNESS_PLUGIN_ROOT="$(cd "$LIB_DIR/.." && pwd)"
export HARNESS_PLUGIN_ROOT

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

# 編集対象ファイル自身の場所から git top-level を解決する。
# セッションの cwd に依存しないため、cwd が複数リポジトリの親ディレクトリ
# （例: マルチリポジトリセッションの起動ディレクトリ）であっても正しく動く。
# 見つからなければ空を返す（呼び出し側は resolve_root(cwd) にフォールバックすること）。
find_root_for_file() {
  local file="$1" dir
  dir=$(dirname -- "$file")
  while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do dir=$(dirname -- "$dir"); done
  [ -d "$dir" ] || return 1
  (cd "$dir" && git rev-parse --show-toplevel 2>/dev/null)
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

# compile.py が生成する正規表現（jq/Oniguruma の (?:...) 非捕捉グループ構文）を
# 文字列に対してテストする。POSIX grep -E は (?:...) を解釈できず、GNU grep は
# 警告付きでたまたま動くように見えるだけで移植性がない。compile.py 由来の
# 正規表現を扱うときは grep ではなく必ずこれを使うこと。
re_test() { # $1=対象文字列 $2=正規表現
  [ -z "$2" ] && return 1
  [ "$(jq -n --arg s "$1" --arg p "$2" '$s | test($p)' 2>/dev/null)" = "true" ]
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

# ---- セッション内マルチプロジェクト registry ----------------------
# 1セッションが複数の harness 導入済みリポジトリを横断して触ることがある
# （例: cwd が複数リポジトリの親ディレクトリのマルチリポジトリセッション）。
# Stop / SessionEnd は cwd 由来の単一 root だけでなく、このセッションが
# 実際に触れた全プロジェクトを把握する必要があるため、ここに記録する。
session_registry_path() { echo "$STATE_ROOT/_sessions/$1/roots"; }

register_session_root() { # $1=session_id $2=root
  if [ -z "$1" ] || [ -z "$2" ]; then return 0; fi
  local f; f=$(session_registry_path "$1")
  mkdir -p "$(dirname "$f")"
  grep -qxF -- "$2" "$f" 2>/dev/null || echo "$2" >> "$f"
}

session_known_roots() { # $1=session_id
  local f; f=$(session_registry_path "$1")
  [ -f "$f" ] && cat "$f"
}

# 24h 超の状態・マーカー・PIDマップを掃除（/tmp 配下の使い捨て状態のみ。
# 永続進捗ログ .claude-harness/progress.log はプロジェクト側にあり対象外）
gc_state() {
  find "$STATE_ROOT" -type f -mmin +1440 -delete 2>/dev/null || true
  find "$STATE_ROOT" -type d -empty -delete 2>/dev/null || true
}

# ---- 永続進捗ログ（長時間・複数セッションのループを見えるようにする） ----
# セッション状態（/tmp 配下）は SessionEnd で消えるため、Anthropic の
# claude-progress.txt に相当する「セッションをまたいで残る進捗」を
# プロジェクト側 .claude-harness/progress.log（JSONL, 追記専用）に持つ。
# 消さない・削らない・上書きしない。harness-map がこれを読んで表示する。
progress_log_path() { echo "$1/.claude-harness/progress.log"; } # $1=root

# 進捗ログに1行追記する。$1=root $2=session_id $3=project $4=event種別 $5=detail(任意の文字列)
log_progress_event() {
  local root="$1" sid="$2" project="$3" event="$4" detail="${5:-}"
  local f; f=$(progress_log_path "$root")
  mkdir -p "$(dirname "$f")"
  jq -nc --arg ts "$(date -Iseconds)" --arg sid "$sid" --arg p "$project" --arg e "$event" --arg d "$detail" \
    '{ts:$ts, session_id:$sid, project:$p, event:$e, detail:$d}' >> "$f" 2>/dev/null || true
}

# harness.yaml の verify:/output: に書ける {session_id} プレースホルダを実値に置換する。
# 固定パスを書くと複数セッション同時実行でアーティファクトが衝突するため、
# セッション（さらにゲート名も含めれば1セッション内の複数ゲートでも）スコープを
# 強制しやすくするための機構。$1=文字列 $2=session_id
subst_session() {
  echo "${1//\{session_id\}/$2}"
}

# レビュー/ゲート実行系スクリプトが共通で使う、セッション+ゲート名スコープの
# アーティファクト置き場。複数セッション同時実行・同一セッション内の複数ゲートの
# どちらでも衝突しない。$1=root $2=session_id $3=gate/skill名 $4=ファイル名（例: findings.json）
gate_artifact_path() {
  local dir=".claude-harness/$2/$3"
  mkdir -p "$1/$dir" 2>/dev/null
  echo "$dir/$4"
}

# 現在のブランチ diff（または --pr 指定時は PR diff）を一時ファイルに書き出し、
# パスを返す。gh 未導入で PR diff を取得できない場合は空ファイルを返す
# （呼び出し側が diff_pending 等で扱う）。$1=root $2=pr番号（空なら通常diff）
gather_diff() {
  local root="$1" pr="$2"
  local diff_file; diff_file=$(mktemp "${TMPDIR:-/tmp}/harness-diff.XXXXXX")
  if [ -n "$pr" ]; then
    if command -v gh >/dev/null 2>&1; then
      (cd "$root" && gh pr diff "$pr") > "$diff_file" 2>/dev/null
    fi
  else
    local base
    base=$(git -C "$root" merge-base HEAD origin/main 2>/dev/null \
        || git -C "$root" merge-base HEAD main 2>/dev/null \
        || git -C "$root" rev-parse HEAD~1 2>/dev/null || echo "")
    {
      [ -n "$base" ] && git -C "$root" diff "$base" 2>/dev/null || true
      git -C "$root" diff 2>/dev/null || true
    } > "$diff_file"
  fi
  echo "$diff_file"
}
