#!/usr/bin/env bash
# review-board の準備: 対象 diff を保存し、起動すべきペルソナの定義を JSON で出力する。
# Usage: review-board-prep.sh [--pr <番号>] [--personas p1,p2]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../hooks/lib.sh"

pr=""
personas_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) pr="$2"; shift 2 ;;
    --personas) personas_arg="$2"; shift 2 ;;
    *) shift ;;
  esac
done

root=$(resolve_root "")
lock=$(ensure_lock "$root") || { echo "エラー: harness.yaml をコンパイルできません" >&2; exit 1; }

# ---- ペルソナの決定 ------------------------------------------------
# 優先順: --personas 引数 > セッション状態の pending ゲート定義 > 全ペルソナ
personas=""
if [ -n "$personas_arg" ]; then
  personas=$(echo "$personas_arg" | tr ',' '\n')
else
  sid=$(resolve_session_id 2>/dev/null || echo "")
  if [ -n "$sid" ]; then
    sp=$(state_path "$lock" "$sid")
    if [ -f "$sp" ]; then
      wf=$(jq -r '.workflow // empty' "$sp")
      gate=$(jq -r '.pending_token.gate // empty' "$sp")
      if [ -n "$wf" ] && [ -n "$gate" ]; then
        personas=$(jq -r --arg w "$wf" --arg g "$gate" \
          '((.workflows[$w].entry.gates // []) + (.workflows[$w].gates // []))[]
           | select(.skill == $g) | .personas[]? // empty' "$lock")
      fi
    fi
  fi
fi
[ -z "$personas" ] && personas=$(jq -r '.personas | keys[]' "$lock")

# ---- diff の保存 ---------------------------------------------------
diff_file=$(mktemp "${TMPDIR:-/tmp}/harness-review-diff.XXXXXX")
if [ -n "$pr" ]; then
  if command -v gh >/dev/null 2>&1; then
    (cd "$root" && gh pr diff "$pr") > "$diff_file"
  else
    echo "エラー: gh がありません。PR diff は GitHub MCP ツールで取得し、$diff_file に保存してください。" >&2
    echo '{}' | jq --arg f "$diff_file" '{diff_file:$f, diff_pending:true}'
  fi
else
  base=$(git -C "$root" merge-base HEAD origin/main 2>/dev/null \
      || git -C "$root" merge-base HEAD main 2>/dev/null \
      || git -C "$root" rev-parse HEAD~1 2>/dev/null || echo "")
  {
    [ -n "$base" ] && git -C "$root" diff "$base" 2>/dev/null || true
    git -C "$root" diff 2>/dev/null || true
  } > "$diff_file"
fi
lines=$(wc -l < "$diff_file" | tr -d ' ')

# ---- 出力 -----------------------------------------------------------
jq -n \
  --arg root "$root" \
  --arg diff_file "$diff_file" \
  --arg lines "$lines" \
  --argjson defs "$(jq -c '.personas' "$lock")" \
  --arg names "$(echo "$personas" | paste -sd, -)" \
  '{
    root: $root,
    diff_file: $diff_file,
    diff_lines: ($lines | tonumber),
    personas: ($names | split(",") | map(select(. != "")) | map({
      name: .,
      def: $defs[.]
    }))
  }'
