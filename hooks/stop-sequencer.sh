#!/usr/bin/env bash
# Stop: 有効ワークフローのゲートを宣言順に要求する。
# 通過記録は自セッションが発行したワンタイムトークン（scripts/mark-gate-passed.sh 経由）でのみ有効。
#
# 1セッションが複数の harness 導入済みリポジトリを横断して触ることがある
# （cwd が複数リポジトリの親ディレクトリのマルチリポジトリセッション等）。
# そのため cwd 由来の1プロジェクトだけでなく、セッションが実際に触れた
# 全プロジェクト（session_known_roots）を巡回し、いずれかに未通過ゲートが
# あれば block する。
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
[ -z "$session_id" ] && exit 0

block() {
  jq -nc --arg r "$1" '{decision:"block", reason:$r}'
  exit 0
}

# $1=root → 0: 未通過ゲートなし / 1: block 済み(標準出力にJSON出力してexit) / 2: この root は対象外
check_gates_for_root() {
  local root="$1"
  [ -f "$root/.claude/harness.yaml" ] || return 2
  local lock; lock=$(ensure_lock "$root") || return 2
  local sp; sp=$(state_path "$lock" "$session_id")
  [ -f "$sp" ] || return 2

  local workflow; workflow=$(jq -r '.workflow // empty' "$sp")
  [ -z "$workflow" ] && return 2   # フロー未宣言 = 編集もブロック済み = 強制対象なし

  # 保留トークンのマーカーを回収して状態へ反映。
  # gates[].verify（シェルコマンド）が定義されている場合、"passed" 申告は
  # トークン一致だけでなく verify の exit 0 を確認できて初めて受理する
  # （自己申告だけで通す旧来の仕様への「検証可能なアウトプット」の強制）。
  # verify 失敗時は pending_token を維持する（トークンを再利用させ、
  # サーキットブレーカーの連続ブロック回数カウンタも継続させるため）。
  local token gate marker tmp
  token=$(jq -r '.pending_token.token // empty' "$sp")
  gate=$(jq -r '.pending_token.gate // empty' "$sp")
  if [ -n "$token" ]; then
    marker="$STATE_ROOT/markers/$token.json"
    if [ -f "$marker" ]; then
      if [ "$(jq -r '.gate // empty' "$marker")" = "$gate" ]; then
        if [ "$(jq -r '.skipped // false' "$marker")" = "true" ]; then
          local reason; reason=$(jq -r '.reason // ""' "$marker")
          tmp=$(mktemp)
          jq --arg g "$gate" --arg r "$reason" \
            '.gates[$g] = {status:"skipped", reason:$r, at:(now|todate)} | .pending_token = null' \
            "$sp" > "$tmp" && mv "$tmp" "$sp"
        else
          local verify_cmd
          verify_cmd=$(jq -r --arg w "$workflow" --arg g "$gate" \
            '((.workflows[$w].entry.gates // []) + (.workflows[$w].gates // [])) | .[] | select(.skill == $g) | .verify // empty' "$lock")
          if [ -n "$verify_cmd" ]; then
            local vout vrc
            vout=$( (cd "$root" && eval "$verify_cmd") 2>&1 ); vrc=$?
            if [ "$vrc" -eq 0 ]; then
              tmp=$(mktemp)
              jq --arg g "$gate" '.gates[$g] = {status:"passed", at:(now|todate)} | .pending_token = null' \
                "$sp" > "$tmp" && mv "$tmp" "$sp"
            else
              local detail; detail=$(echo "$vout" | tail -n 15)
              tmp=$(mktemp)
              jq --arg g "$gate" --arg d "$detail" \
                '.gates[$g] = {status:"verify_failed", detail:$d, at:(now|todate)}' \
                "$sp" > "$tmp" && mv "$tmp" "$sp"
            fi
          else
            tmp=$(mktemp)
            jq --arg g "$gate" '.gates[$g] = {status:"passed", at:(now|todate)} | .pending_token = null' \
              "$sp" > "$tmp" && mv "$tmp" "$sp"
          fi
        fi
      fi
      rm -f "$marker"
    fi
  fi

  # entry ゲート → 通常ゲートの順に走査
  local gates
  gates=$(jq -c --arg w "$workflow" \
    '((.workflows[$w].entry.gates // []) + (.workflows[$w].gates // []))[]' "$lock")

  local project; project=$(jq -r '.project.name' "$lock")

  while IFS= read -r g; do
    [ -z "$g" ] && continue
    local skill when optional output status
    skill=$(echo "$g" | jq -r '.skill')
    when=$(echo "$g" | jq -r '.when // empty')
    optional=$(echo "$g" | jq -r '.optional // false')
    output=$(echo "$g" | jq -r '.output // empty')

    if [ -n "$when" ]; then
      local dirty; dirty=$(jq -r --arg c "$when" '.dirty[$c] // false' "$sp")
      [ "$dirty" != "true" ] && continue
    fi

    status=$(jq -r --arg g "$skill" '.gates[$g].status // empty' "$sp")
    [ "$status" = "passed" ] || [ "$status" = "skipped" ] || [ "$status" = "breaker_open" ] && continue

    if [ -n "$output" ]; then
      local og; og="${output//\{date\}/$(date +%Y-%m-%d)}"
      og="${og//\{slug\}/*}"
      if compgen -G "$root/$og" >/dev/null 2>&1; then
        tmp=$(mktemp)
        jq --arg g "$skill" '.gates[$g] = {status:"passed", at:(now|todate)}' "$sp" > "$tmp" && mv "$tmp" "$sp"
        continue
      fi
    fi

    local max_blocks="${HARNESS_MAX_GATE_BLOCKS:-5}"
    local gtoken blocks
    gtoken=$(jq -r --arg g "$skill" \
      'if .pending_token.gate == $g then .pending_token.token else empty end' "$sp")
    if [ -z "$gtoken" ]; then
      gtoken=$(new_token)
      blocks=1
      tmp=$(mktemp)
      jq --arg g "$skill" --arg t "$gtoken" \
        '.pending_token = {gate:$g, token:$t, issued_at:(now|todate), blocks:1}' "$sp" > "$tmp" && mv "$tmp" "$sp"
    else
      blocks=$(( $(jq -r '.pending_token.blocks // 1' "$sp") + 1 ))
      tmp=$(mktemp)
      jq --argjson b "$blocks" '.pending_token.blocks = $b' "$sp" > "$tmp" && mv "$tmp" "$sp"
    fi

    if [ "$blocks" -gt "$max_blocks" ]; then
      tmp=$(mktemp)
      jq --arg g "$skill" \
        '.gates[$g] = {status:"breaker_open", at:(now|todate)} | .pending_token = null' \
        "$sp" > "$tmp" && mv "$tmp" "$sp"
      jq -nc --arg m "⚠ harness [$project]: ゲート /$skill が ${max_blocks} 回連続でブロックされたため、サーキットブレーカーで解放しました。ゲートは未通過（breaker_open）として記録されています。スキル名の誤り・ゲートスキルの不具合を確認してください（上限は HARNESS_MAX_GATE_BLOCKS で変更可）。" \
        '{systemMessage:$m}'
      return 0
    fi

    local plugin_root; plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local msg
    if [ "$status" = "verify_failed" ]; then
      local detail; detail=$(jq -r --arg g "$skill" '.gates[$g].detail // empty' "$sp")
      msg="harness ゲート [$project / $workflow]: /$skill の完了報告を検証しましたが、条件を満たしていませんでした。"
      [ -n "$detail" ] && msg+=$'\n'"検証コマンドの出力:"$'\n'"$detail"
      msg+=$'\n'"問題を修正してから同じコマンドを再実行してください: \`bash $plugin_root/scripts/mark-gate-passed.sh $skill $gtoken\`"
      [ "$optional" = "true" ] && msg+=" このゲートは optional です。対象外と判断した場合は \`bash $plugin_root/scripts/mark-gate-passed.sh $skill $gtoken --skip \"<理由>\"\` でスキップできます（verify は迂回されます）。"
    else
      msg="harness ゲート [$project / $workflow]: /$skill が未完了です。"
      if [ -n "$output" ]; then
        msg+=" 成果物 '$output' を作成してください（存在すれば自動通過します）。"
      else
        msg+=" /$skill を完了してから \`bash $plugin_root/scripts/mark-gate-passed.sh $skill $gtoken\` を実行してください。"
        [ "$optional" = "true" ] && msg+=" このゲートは optional です。対象外と判断した場合は \`bash $plugin_root/scripts/mark-gate-passed.sh $skill $gtoken --skip \"<理由>\"\` でスキップできます。"
      fi
    fi
    msg+=" トークンなしの記録・touch による偽装は無効です。"
    block "$msg"
  done <<< "$gates"

  return 2
}

# 巡回対象: このセッションが実際に触れた全プロジェクト + cwd 由来のルート（後方互換・フォールバック）
roots=$(session_known_roots "$session_id")
cwd_root=$(resolve_root "$cwd")
all_roots=$(printf '%s\n%s\n' "$roots" "$cwd_root" | grep -v '^$' | sort -u)

[ -z "$all_roots" ] && exit 0

while IFS= read -r r; do
  [ -z "$r" ] && continue
  check_gates_for_root "$r"   # block() 内で exit するので、未 block なら次の root へ
done <<< "$all_roots"

exit 0
