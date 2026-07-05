#!/usr/bin/env bash
# 読み取り専用ビジュアライザを生成する。
# Usage: harness-map.sh [出力パス]  （省略時: harness.yaml の visualizer.output → docs/harness-map.md）
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../hooks/lib.sh"

root=$(resolve_root "")
lock=$(ensure_lock "$root") || { echo "エラー: harness.yaml をコンパイルできません" >&2; exit 1; }

out="${1:-}"
[ -z "$out" ] && out=$(jq -r '.visualizer.output // "docs/harness-map.md"' "$lock")
[[ "$out" = /* ]] || out="$root/$out"

project=$(jq -r '.project.name' "$lock")
state_dir="$STATE_ROOT/$project"
mkdir -p "$(dirname "$out")" "$state_dir"

python3 "$(dirname "${BASH_SOURCE[0]}")/harness_map.py" "$lock" "$state_dir" > "$out"
echo "✓ 生成しました: $out"
