#!/usr/bin/env bash
# 汎用: レビュー系ゲートの verify: から呼ぶ検証ヘルパー。
# {"all_approved": bool, "personas": [{"name":..., "verdict":"approve"|"request_changes", "findings":[...]}]}
# 形式の JSON ファイルを読み、all_approved が true であることを確認する。
# Usage: verify-approved.sh <path-to-json>
set -uo pipefail

f="${1:-}"
if [ -z "$f" ]; then
  echo "Usage: verify-approved.sh <json-file>" >&2
  exit 1
fi
if [ ! -f "$f" ]; then
  echo "検証対象ファイル '$f' が存在しません。レビュー結果を書き出してから再度 mark-gate-passed を実行してください。" >&2
  exit 1
fi
if ! jq -e . "$f" >/dev/null 2>&1; then
  echo "'$f' が valid な JSON ではありません。" >&2
  exit 1
fi
if [ "$(jq -r '.all_approved // false' "$f" 2>/dev/null)" = "true" ]; then
  exit 0
fi
echo "'$f' の all_approved が true ではありません。未解決の指摘:" >&2
jq -r '
  .personas[]? | select(.verdict != "approve") |
  "  - " + .name + " (" + .verdict + "): " +
  ((.findings // []) | length | tostring) + " 件の指摘"
' "$f" >&2 2>/dev/null
exit 1
