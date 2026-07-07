#!/usr/bin/env bash
# 汎用: レビュー系ゲートの verify: から呼ぶ検証ヘルパー。
# 2つの形状に対応する:
#   複数ペルソナ（review-board）: {"all_approved": bool, "personas": [{"name":..., "verdict":"approve"|"request_changes", "findings":[...]}]}
#   単一レビュアー（plan-review 等）: {"approved": bool, "feedback": "...", "concerns": [...]}
# いずれかの承認フラグが true であることを確認する。
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
if [ "$(jq -r '.all_approved // .approved // false' "$f" 2>/dev/null)" = "true" ]; then
  exit 0
fi

echo "'$f' が承認されていません。" >&2

# 複数ペルソナ形状（review-board）の内訳
jq -r '
  .personas[]? | select(.verdict != "approve") |
  "  - " + .name + " (" + .verdict + "): " +
  ((.findings // []) | length | tostring) + " 件の指摘"
' "$f" >&2 2>/dev/null

# 単一レビュアー形状（plan-review 等）の内訳
feedback=$(jq -r '.feedback // empty' "$f" 2>/dev/null)
[ -n "$feedback" ] && echo "  feedback: $feedback" >&2
jq -r '.concerns[]? | "  - " + .' "$f" >&2 2>/dev/null

exit 1
