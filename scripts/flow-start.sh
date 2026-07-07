#!/usr/bin/env bash
# ワークフローを宣言し、セッション状態に記録してゲート計画を表示する。
# Usage: flow-start.sh <workflow> [ticket_or_input]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../hooks/lib.sh"

workflow="${1:-}"
ticket="${2:-}"

root=$(resolve_root "")
[ -f "$root/.claude/harness.yaml" ] || { echo "エラー: $root に .claude/harness.yaml がありません" >&2; exit 1; }
lock=$(ensure_lock "$root") || { echo "エラー: harness.yaml のコンパイルに失敗しました" >&2; exit 1; }

if [ -z "$workflow" ]; then
  echo "Usage: flow-start.sh <workflow> [ticket]"
  echo "定義済みワークフロー:"
  jq -r '.workflows | to_entries[] | "  \(.key)\(if .value.default then " (デフォルト)" else "" end) — \(.value.description // "")"' "$lock"
  exit 1
fi

jq -e --arg w "$workflow" '.workflows[$w]' "$lock" >/dev/null || {
  echo "エラー: ワークフロー '$workflow' は定義されていません" >&2
  jq -r '"定義済み: " + (.workflows | keys | join(", "))' "$lock" >&2
  exit 1
}

session_id=$(resolve_session_id) || {
  echo "エラー: セッション ID を解決できません。SessionStart フックが動作しているか確認してください。" >&2
  exit 1
}

# チケット要求の確認
require_ticket=$(jq -r --arg w "$workflow" '.workflows[$w].entry.require_ticket // false' "$lock")
provider=$(jq -r '.tickets.provider // "none"' "$lock")
if [ "$require_ticket" = "true" ] && [ "$provider" != "none" ] && [ -z "$ticket" ]; then
  echo "エラー: ワークフロー '$workflow' はチケット番号が必須です（例: flow-start.sh $workflow 42）" >&2
  exit 1
fi
if [ -n "$ticket" ] && [ "$provider" = "github-issues" ] && command -v gh >/dev/null 2>&1; then
  title=$(cd "$root" && gh issue view "${ticket#\#}" --json title -q .title 2>/dev/null) || {
    echo "⚠ issue #${ticket#\#} を gh で確認できませんでした（存在しないか、gh 未認証）。番号を確認してください。" >&2
    title=""
  }
  [ -n "$title" ] && echo "issue #${ticket#\#}: $title"
fi

# 状態書き込み（既存フローの未通過ゲートがあれば警告して上書き）
sp=$(state_path "$lock" "$session_id")
init_state "$sp" "$session_id"
prev=$(jq -r '.workflow // empty' "$sp")
if [ -n "$prev" ] && [ "$prev" != "$workflow" ]; then
  echo "⚠ ワークフローを '$prev' から '$workflow' に切り替えます。ゲート進行はリセットされます。"
fi
tmp=$(mktemp)
jq --arg w "$workflow" --arg t "$ticket" \
  '.workflow = $w | .ticket = (if $t == "" then null else $t end)
   | .gates = {} | .dirty = {} | .pending_token = null' "$sp" > "$tmp" && mv "$tmp" "$sp"

register_session_root "$session_id" "$root"
project=$(jq -r '.project.name' "$lock")
log_progress_event "$root" "$session_id" "$project" "workflow_started" \
  "$workflow${ticket:+ (ticket: $ticket)}"

# ゲート計画の提示（Claude がスキーマ内容を知る唯一の正規経路）
echo ""
echo "ワークフロー '$workflow' を開始しました。"
perm=$(jq -r --arg w "$workflow" '.workflows[$w].permissions' "$lock")
[ "$perm" = "read-only" ] && echo "このフローは read-only です。実装ファイルの編集はブロックされます。"
echo ""
echo "ゲート計画（Stop フックがこの順に要求します）:"
jq -r --arg w "$workflow" '
  ((.workflows[$w].entry.gates // []) | map(
    "  [entry] " + (if .agent then "/gate-run " + .skill + " (独立コンテキスト・ペルソナ: " + .agent + ")"
                    else "/" + .skill end)
  )) +
  ((.workflows[$w].gates // []) | map(
    "  " + (if .when then "[" + .when + " 変更時] " else "" end) +
    (if .agent then "/gate-run " + .skill + " (独立コンテキスト・ペルソナ: " + .agent + ")"
     else "/" + .skill end) +
    (if .optional then " (optional)" else "" end) +
    (if .output then " → 成果物: " + .output else "" end) +
    (if .personas then " (ペルソナ: " + (.personas | join(", ")) + ")" else "" end)
  )) | .[]' "$lock"
echo ""
echo "entry ゲートがある場合は着手前に完了してください。各ゲートの完了記録はゲート要求メッセージ内のトークン付きコマンドで行います。"
