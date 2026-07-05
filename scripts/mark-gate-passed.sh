#!/usr/bin/env bash
# ゲート通過をワンタイムトークンつきで記録する。
# Usage: mark-gate-passed.sh <gate> <token> [--skip "<理由>"]
# トークンは Stop フックの block メッセージに埋め込まれたものを使うこと。
set -euo pipefail

STATE_ROOT="${HARNESS_STATE_DIR:-/tmp/claude-harness}"

gate="${1:-}"
token="${2:-}"
skipped=false
reason=""
if [ "${3:-}" = "--skip" ]; then
  skipped=true
  reason="${4:-}"
  if [ -z "$reason" ]; then
    echo "エラー: --skip にはスキップ理由が必須です" >&2
    exit 1
  fi
fi

if [ -z "$gate" ] || [ -z "$token" ]; then
  echo "Usage: mark-gate-passed.sh <gate> <token> [--skip \"<理由>\"]" >&2
  echo "トークンは harness の block メッセージに記載されています。" >&2
  exit 1
fi

mkdir -p "$STATE_ROOT/markers"
jq -n --arg g "$gate" --argjson s "$skipped" --arg r "$reason" \
  '{gate:$g, skipped:$s, reason:$r, at:(now|todate)}' \
  > "$STATE_ROOT/markers/$token.json"

if [ "$skipped" = "true" ]; then
  echo "✓ ゲート '$gate' をスキップ記録しました（理由: $reason）"
else
  echo "✓ ゲート '$gate' の完了を記録しました"
fi
