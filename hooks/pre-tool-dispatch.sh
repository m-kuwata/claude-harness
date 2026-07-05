#!/usr/bin/env bash
# PreToolUse: flow宣言ガード / read-only ガード / on_commit CI / reuse ガード
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

input=$(cat)
tool=$(echo "$input" | jq -r '.tool_name // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
root=$(resolve_root "$cwd")

[ -f "$root/.claude/harness.yaml" ] || exit 0

deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
context() {
  jq -nc --arg c "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
  exit 0
}

lock=$(ensure_lock "$root") || {
  # fail-closed: コンパイル不能な状態での編集は止める（Bash 等は素通し）
  case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit)
      deny "harness.yaml をコンパイルできません（yq / python3+PyYAML の導入、または harness.yaml の検証エラーを解消してください）。解消するまで編集はブロックされます。" ;;
    *) exit 0 ;;
  esac
}

sp=$(state_path "$lock" "$session_id")

case "$tool" in
# ---- 編集ガード ---------------------------------------------------
Edit|Write|MultiEdit|NotebookEdit)
  workflow=""
  [ -f "$sp" ] && workflow=$(jq -r '.workflow // empty' "$sp")
  exempt_classes=$(jq -r '.tickets.exempt[]? // empty' "$lock")

  reuse_msgs=""
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    rel=$(rel_path "$root" "$file")
    [ -z "$rel" ] && continue   # プロジェクト外は対象外

    classes=$(classify_file "$lock" "$rel")

    # exempt クラスに該当すれば全ガード対象外
    is_exempt=""
    for c in $classes; do
      grep -qx "$c" <<<"$exempt_classes" && is_exempt=1
    done
    [ -n "$is_exempt" ] && continue

    # reuse ガード（非ブロック）: 新規作成ファイルのみ
    if [ ! -e "$file" ] && [ ! -e "$root/$rel" ]; then
      gn=$(jq '.guards.reuse | length' "$lock")
      for ((i = 0; i < gn; i++)); do
        re=$(jq -r ".guards.reuse[$i].on_create_re // empty" "$lock")
        [ -n "$re" ] && echo "$rel" | grep -qE "$re" || continue
        inv=$(jq -r ".guards.reuse[$i].inventory // empty" "$lock")
        [ -z "$inv" ] && continue
        listing=$( (cd "$root" && eval "$inv") 2>/dev/null | head -30)
        reuse_msgs+="♻ 新規ファイル $rel を作成しようとしています。既存資産を確認してください:\n$listing\n"
      done
    fi

    # ガード対象クラス（impl/screen 等 = paths に定義され exempt でないもの）
    guarded=""
    for c in $classes; do guarded="$c"; done
    [ -z "$guarded" ] && continue

    if [ -z "$workflow" ]; then
      flows=$(jq -r '[.workflows | keys[]] | join(" / ")' "$lock")
      deny "harness: ワークフロー未宣言です。編集の前に /flow <ワークフロー名> [チケット番号] を宣言してください（定義済み: $flows）。調査のみなら read-only フローを選んでください。"
    fi

    perm=$(jq -r --arg w "$workflow" '.workflows[$w].permissions // "edit"' "$lock")
    if [ "$perm" = "read-only" ]; then
      # gates[].output で宣言された成果物パスは書き込み例外
      allowed=""
      while IFS= read -r out_glob; do
        [ -z "$out_glob" ] && continue
        out_glob="${out_glob//\{date\}/$(date +%Y-%m-%d)}"
        out_glob="${out_glob//\{slug\}/*}"
        # 簡易 glob 照合
        case "$rel" in $out_glob) allowed=1 ;; esac
      done < <(jq -r --arg w "$workflow" '.workflows[$w].gates[]?.output // empty' "$lock")
      [ -z "$allowed" ] && deny "harness: 現在のワークフロー '$workflow' は read-only です。'$rel' への書き込みはできません。実装に切り替える場合は /flow implement <チケット番号> を宣言してください。"
    fi
  done < <(extract_files "$input")

  [ -n "$reuse_msgs" ] && context "$(echo -e "$reuse_msgs")"
  exit 0
  ;;

# ---- git commit ゲート ---------------------------------------------
Bash)
  cmd=$(echo "$input" | jq -r '.tool_input.command // empty')
  echo "$cmd" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+commit' || exit 0

  errors=()

  # ブランチ検証（tickets アダプタ）
  provider=$(jq -r '.tickets.provider // "none"' "$lock")
  if [ "$provider" != "none" ]; then
    branch=$(git -C "$root" branch --show-current 2>/dev/null || echo "")
    while IFS= read -r prot; do
      [ -n "$prot" ] && [ "$branch" = "$prot" ] && \
        errors+=("保護ブランチ '$branch' への直接コミットは禁止です。/flow でチケットとブランチを作成してください。")
    done < <(jq -r '.tickets.protected_branches[]? // empty' "$lock")

    fmt=$(jq -r '.tickets.branch_format // empty' "$lock")
    escape=$(jq -r '.tickets.escape_env // empty' "$lock")
    if [ -n "$fmt" ] && [ -n "$branch" ]; then
      # {type}/{n}-{slug} → 正規表現化
      re="^${fmt//\{type\}/(feat|fix|refactor|chore|docs)}"
      re="${re//\{n\}/[0-9]+}"
      re="${re//\{slug\}/.+}"
      allow_ok=""
      while IFS= read -r pre; do
        [ -n "$pre" ] && [[ "$branch" == "$pre"* ]] && allow_ok=1
      done < <(jq -r '.tickets.allow_branch_prefixes[]? // empty' "$lock")
      if [ -z "$allow_ok" ] && ! echo "$branch" | grep -qE "$re"; then
        if [ -z "$escape" ] || [ "${!escape:-}" != "1" ]; then
          errors+=("ブランチ名 '$branch' がチケット形式 '$fmt' に一致しません。緊急時は ${escape:-SKIP_ISSUE_CHECK}=1 で回避できます。")
        fi
      fi
    fi
  fi

  # ci.on_commit（ブロッキング実行）
  n=$(jq '.ci.on_commit | length' "$lock")
  for ((i = 0; i < n; i++)); do
    when_re=$(jq -r ".ci.on_commit[$i].when_staged_re // empty" "$lock")
    if [ -n "$when_re" ]; then
      git -C "$root" diff --cached --name-only 2>/dev/null | grep -qE "$when_re" || continue
    fi
    run=$(jq -r ".ci.on_commit[$i].run" "$lock")
    cov=$(jq -r ".ci.on_commit[$i].coverage_min // empty" "$lock")
    echo "▶ harness on_commit: $run" >&2
    if ! out=$( (cd "$root" && eval "$run") 2>&1 ); then
      tail_out=$(echo "$out" | tail -n 15)
      errors+=("on_commit チェック失敗: \`$run\`${cov:+（カバレッジ ${cov}% 必須）}
$tail_out")
    fi
  done

  if [ ${#errors[@]} -gt 0 ]; then
    msg="harness: コミット前チェックに失敗しました:"
    for e in "${errors[@]}"; do msg+=$'\n'"- $e"; done
    deny "$msg"
  fi
  exit 0
  ;;

*) exit 0 ;;
esac
