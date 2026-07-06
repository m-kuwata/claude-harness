#!/usr/bin/env bash
# PostToolUse(Edit|Write|MultiEdit|NotebookEdit): dirty フラグ更新 + on_edit CI（非ブロック）
# ルート解決はファイル自身の場所から行う（cwd に依存しない。理由は pre-tool-dispatch.sh 参照）
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')

while IFS= read -r file; do
  [ -z "$file" ] && continue

  file_root=$(find_root_for_file "$file")
  [ -z "$file_root" ] && file_root=$(resolve_root "$cwd")
  [ -f "$file_root/.claude/harness.yaml" ] || continue

  file_lock=$(ensure_lock "$file_root") || continue
  register_session_root "$session_id" "$file_root"
  file_sp=$(state_path "$file_lock" "$session_id")
  init_state "$file_sp" "$session_id"

  rel=$(rel_path "$file_root" "$file")
  [ -z "$rel" ] && continue

  # dirty フラグ
  for cls in $(classify_file "$file_lock" "$rel"); do
    tmp=$(mktemp)
    jq --arg c "$cls" '.dirty[$c] = true' "$file_sp" > "$tmp" && mv "$tmp" "$file_sp"
  done

  # on_edit CI（非ブロック・警告のみ）
  n=$(jq '.ci.on_edit | length' "$file_lock")
  for ((i = 0; i < n; i++)); do
    re=$(jq -r ".ci.on_edit[$i].paths_re // empty" "$file_lock")
    re_test "$rel" "$re" || continue
    run=$(jq -r ".ci.on_edit[$i].run" "$file_lock")
    rel_to=$(jq -r ".ci.on_edit[$i].relative_to // empty" "$file_lock")
    relfile="$rel"
    [ -n "$rel_to" ] && relfile="${rel#"$rel_to"/}"
    run="${run//\{file\}/$rel}"
    run="${run//\{relfile\}/$relfile}"
    if ! out=$( (cd "$file_root" && eval "$run") 2>&1 ); then
      echo "⚠ harness on_edit ($rel):" >&2
      echo "$out" | tail -n 15 >&2
    fi
  done
done < <(extract_files "$input")
exit 0
