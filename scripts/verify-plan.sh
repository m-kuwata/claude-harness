#!/usr/bin/env bash
# 汎用: plan ゲートの verify: から呼ぶ検証ヘルパー。
# 計画は自然文なので内容の妥当性は機械検証できない（正直な限界）。
# ここで確認するのは「空・プレースホルダではない実質的な計画が存在するか」という
# 浅いが実在チェック: ファイルが存在し、行数が最低限あることだけ。
# Usage: verify-plan.sh <path-to-plan.md> [最低行数（デフォルト5）]
set -uo pipefail

f="${1:-}"
min_lines="${2:-5}"
if [ -z "$f" ]; then
  echo "Usage: verify-plan.sh <plan.md> [最低行数]" >&2
  exit 1
fi
if [ ! -f "$f" ]; then
  echo "計画ファイル '$f' が存在しません。plan ゲートでプランナーの出力を書き出してから再度 mark-gate-passed を実行してください。" >&2
  exit 1
fi
lines=$(grep -cve '^[[:space:]]*$' "$f" 2>/dev/null || echo 0)
if [ "$lines" -lt "$min_lines" ]; then
  echo "計画ファイル '$f' の内容が薄すぎます（非空行 $lines / 最低 $min_lines）。プレースホルダのまま記録していませんか。" >&2
  exit 1
fi
exit 0
