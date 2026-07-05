#!/usr/bin/env bash
# SessionEnd: 自セッションの状態・保留マーカー・PIDマップを掃除する
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
[ -z "$session_id" ] && exit 0
root=$(resolve_root "$cwd")

[ -f "$root/.claude/harness.yaml" ] || exit 0
lock=$(lock_path "$root")
if [ -f "$lock" ]; then
  sp=$(state_path "$lock" "$session_id")
  if [ -f "$sp" ]; then
    token=$(jq -r '.pending_token.token // empty' "$sp")
    [ -n "$token" ] && rm -f "$STATE_ROOT/markers/$token.json"
    rm -f "$sp"
  fi
fi
rm -f "$STATE_ROOT/by-pid/$PPID" 2>/dev/null || true
exit 0
