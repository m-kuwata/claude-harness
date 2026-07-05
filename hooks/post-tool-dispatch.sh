#!/usr/bin/env bash
# PostToolUse(Edit|Write|MultiEdit|NotebookEdit): dirty フラグ更新 + on_edit CI（非ブロック）
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
root=$(resolve_root "$cwd")

[ -f "$root/.claude/harness.yaml" ] || exit 0
lock=$(ensure_lock "$root") || exit 0
sp=$(state_path "$lock" "$session_id")
init_state "$sp" "$session_id"

while IFS= read -r file; do
  [ -z "$file" ] && continue
  rel=$(rel_path "$root" "$file")
  [ -z "$rel" ] && continue

  # dirty フラグ
  for cls in $(classify_file "$lock" "$rel"); do
    tmp=$(mktemp)
    jq --arg c "$cls" '.dirty[$c] = true' "$sp" > "$tmp" && mv "$tmp" "$sp"
  done

  # on_edit CI（非ブロック・警告のみ）
  n=$(jq '.ci.on_edit | length' "$lock")
  for ((i = 0; i < n; i++)); do
    re=$(jq -r ".ci.on_edit[$i].paths_re // empty" "$lock")
    [ -n "$re" ] && echo "$rel" | grep -qE "$re" || continue
    run=$(jq -r ".ci.on_edit[$i].run" "$lock")
    rel_to=$(jq -r ".ci.on_edit[$i].relative_to // empty" "$lock")
    relfile="$rel"
    [ -n "$rel_to" ] && relfile="${rel#"$rel_to"/}"
    run="${run//\{file\}/$rel}"
    run="${run//\{relfile\}/$relfile}"
    if ! out=$( (cd "$root" && eval "$run") 2>&1 ); then
      echo "⚠ harness on_edit ($rel):" >&2
      echo "$out" | tail -n 15 >&2
    fi
  done
done < <(extract_files "$input")
exit 0
