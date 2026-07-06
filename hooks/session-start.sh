#!/usr/bin/env bash
# SessionStart: lock コンパイル・状態GC・セッションPID記録・setup 実行
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
root=$(resolve_root "$cwd")

gc_state
[ -n "$session_id" ] && record_session_pid "$session_id"

# harness.yaml が無いプロジェクトではエンジンは不活性（無言で終了）
[ -f "$root/.claude/harness.yaml" ] || exit 0

# 必須ツール確認（エンジン自体の依存）
missing=()
command -v jq >/dev/null 2>&1 || missing+=("jq")
command -v python3 >/dev/null 2>&1 || missing+=("python3")
if ! command -v yq >/dev/null 2>&1 && ! python3 -c 'import yaml' 2>/dev/null; then
  missing+=("yq または python3+PyYAML（harness.yaml のコンパイルに必要）")
fi
if [ ${#missing[@]} -gt 0 ]; then
  echo "⛔ harness FATAL: 必須ツールが不足しています: ${missing[*]}" >&2
  echo "   ゲート強制は fail-closed で動作します（実装ファイル編集がブロックされます）。" >&2
  exit 0
fi

lock=$(ensure_lock "$root") || {
  echo "⛔ harness FATAL: harness.yaml のコンパイルに失敗しました（上記エラー参照）。" >&2
  exit 0
}

# setup: require_tools（プロジェクト側の要求）
while IFS= read -r tool; do
  [ -z "$tool" ] && continue
  command -v "$tool" >/dev/null 2>&1 || echo "⚠ harness: 推奨ツール '$tool' が見つかりません" >&2
done < <(jq -r '.setup.require_tools[]? // empty' "$lock")

# setup: git hooksPath
hooks_path=$(jq -r '.setup.git_hooks_path // empty' "$lock")
if [ -n "$hooks_path" ] && git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$root" config core.hooksPath "$hooks_path" 2>/dev/null || true
fi

# setup: commands（if_exists 条件つき・非ブロック）
n=$(jq '.setup.commands | length' "$lock" 2>/dev/null || echo 0)
for ((i = 0; i < n; i++)); do
  run=$(jq -r ".setup.commands[$i].run // empty" "$lock")
  cond=$(jq -r ".setup.commands[$i].if_exists // empty" "$lock")
  [ -z "$run" ] && continue
  [ -n "$cond" ] && [ ! -e "$root/$cond" ] && continue
  (cd "$root" && eval "$run") >/dev/null 2>&1 || echo "⚠ harness setup: '$run' が失敗しました" >&2
done

# 状態初期化 + コンテキストへのサマリ注入
if [ -n "$session_id" ]; then
  sp=$(state_path "$lock" "$session_id")
  init_state "$sp" "$session_id"
  register_session_root "$session_id" "$root"
fi
project=$(jq -r '.project.name' "$lock")
flows=$(jq -r '[.workflows | to_entries[] | .key + (if .value.default then "*" else "" end)] | join(", ")' "$lock")
echo "harness v$HARNESS_ENGINE_VERSION 有効: project=$project / workflows: $flows（* はデフォルト）。実装に着手する前に /flow でワークフローを宣言してください。"
exit 0
