#!/usr/bin/env bash
# SessionEnd: 自セッションが触れた全プロジェクトの状態・保留マーカー・
# PIDマップ・registry を掃除する（cwd 由来の1プロジェクトだけではない。
# 理由は stop-sequencer.sh のコメント参照）
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
[ -z "$session_id" ] && exit 0

cleanup_root() {
  local root="$1"
  [ -f "$root/.claude/harness.yaml" ] || return 0
  local lock; lock=$(lock_path "$root")
  [ -f "$lock" ] || return 0
  local sp; sp=$(state_path "$lock" "$session_id")
  [ -f "$sp" ] || return 0
  local token; token=$(jq -r '.pending_token.token // empty' "$sp")
  [ -n "$token" ] && rm -f "$STATE_ROOT/markers/$token.json"
  rm -f "$sp"
}

roots=$(session_known_roots "$session_id")
cwd_root=$(resolve_root "$cwd")
all_roots=$(printf '%s\n%s\n' "$roots" "$cwd_root" | grep -v '^$' | sort -u)

while IFS= read -r r; do
  [ -z "$r" ] && continue
  cleanup_root "$r"
done <<< "$all_roots"

rm -f "$(session_registry_path "$session_id")"
rm -f "$STATE_ROOT/by-pid/$PPID" 2>/dev/null || true
exit 0
