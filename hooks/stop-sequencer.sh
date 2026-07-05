#!/usr/bin/env bash
# Stop: 有効ワークフローのゲートを宣言順に要求する。
# 通過記録は自セッションが発行したワンタイムトークン（scripts/mark-gate-passed.sh 経由）でのみ有効。
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
root=$(resolve_root "$cwd")

[ -f "$root/.claude/harness.yaml" ] || exit 0
lock=$(ensure_lock "$root") || exit 0
sp=$(state_path "$lock" "$session_id")
[ -f "$sp" ] || exit 0

workflow=$(jq -r '.workflow // empty' "$sp")
[ -z "$workflow" ] && exit 0   # フロー未宣言 = 編集もブロック済み = 強制対象なし

block() {
  jq -nc --arg r "$1" '{decision:"block", reason:$r}'
  exit 0
}

# 保留トークンのマーカーを回収して状態へ反映
consume_marker() {
  local token gate marker status reason tmp
  token=$(jq -r '.pending_token.token // empty' "$sp")
  gate=$(jq -r '.pending_token.gate // empty' "$sp")
  [ -z "$token" ] && return
  marker="$STATE_ROOT/markers/$token.json"
  [ -f "$marker" ] || return
  # マーカーのゲート名が一致しなければ無効（別ゲートへの流用防止）
  [ "$(jq -r '.gate // empty' "$marker")" = "$gate" ] || { rm -f "$marker"; return; }
  if [ "$(jq -r '.skipped // false' "$marker")" = "true" ]; then
    status="skipped"; reason=$(jq -r '.reason // ""' "$marker")
  else
    status="passed"; reason=""
  fi
  tmp=$(mktemp)
  jq --arg g "$gate" --arg s "$status" --arg r "$reason" \
    '.gates[$g] = {status:$s, reason:$r, at:(now|todate)} | .pending_token = null' \
    "$sp" > "$tmp" && mv "$tmp" "$sp"
  rm -f "$marker"
}
consume_marker

# entry ゲート → 通常ゲートの順に走査
gates=$(jq -c --arg w "$workflow" \
  '((.workflows[$w].entry.gates // []) + (.workflows[$w].gates // []))[]' "$lock")

while IFS= read -r gate; do
  [ -z "$gate" ] && continue
  skill=$(echo "$gate" | jq -r '.skill')
  when=$(echo "$gate" | jq -r '.when // empty')
  optional=$(echo "$gate" | jq -r '.optional // false')
  output=$(echo "$gate" | jq -r '.output // empty')

  # when: 該当クラスが dirty でなければスキップ
  if [ -n "$when" ]; then
    dirty=$(jq -r --arg c "$when" '.dirty[$c] // false' "$sp")
    [ "$dirty" != "true" ] && continue
  fi

  # 通過済み・スキップ済み・ブレーカー開放済み
  status=$(jq -r --arg g "$skill" '.gates[$g].status // empty' "$sp")
  [ "$status" = "passed" ] || [ "$status" = "skipped" ] || [ "$status" = "breaker_open" ] && continue

  # output 宣言ゲート: 成果物が存在すれば自動通過
  if [ -n "$output" ]; then
    g="${output//\{date\}/$(date +%Y-%m-%d)}"
    g="${g//\{slug\}/*}"
    if compgen -G "$root/$g" >/dev/null 2>&1; then
      tmp=$(mktemp)
      jq --arg g "$skill" '.gates[$g] = {status:"passed", at:(now|todate)}' "$sp" > "$tmp" && mv "$tmp" "$sp"
      continue
    fi
  fi

  # 未通過ゲート発見 → トークン発行して block（同一ゲートの再 block は回数を数える）
  max_blocks="${HARNESS_MAX_GATE_BLOCKS:-5}"
  token=$(jq -r --arg g "$skill" \
    'if .pending_token.gate == $g then .pending_token.token else empty end' "$sp")
  if [ -z "$token" ]; then
    token=$(new_token)
    blocks=1
    tmp=$(mktemp)
    jq --arg g "$skill" --arg t "$token" \
      '.pending_token = {gate:$g, token:$t, issued_at:(now|todate), blocks:1}' "$sp" > "$tmp" && mv "$tmp" "$sp"
  else
    blocks=$(( $(jq -r '.pending_token.blocks // 1' "$sp") + 1 ))
    tmp=$(mktemp)
    jq --argjson b "$blocks" '.pending_token.blocks = $b' "$sp" > "$tmp" && mv "$tmp" "$sp"
  fi

  # サーキットブレーカー: 同一ゲートで max 回連続 block しても進捗がなければ
  # ブロックをやめて解放する（無限ループでトークンを浪費しない）。
  # ゲートは breaker_open として記録され、通過扱いにはならない。/flow 再宣言でリセット。
  if [ "$blocks" -gt "$max_blocks" ]; then
    tmp=$(mktemp)
    jq --arg g "$skill" \
      '.gates[$g] = {status:"breaker_open", at:(now|todate)} | .pending_token = null' \
      "$sp" > "$tmp" && mv "$tmp" "$sp"
    jq -nc --arg m "⚠ harness: ゲート /$skill が ${max_blocks} 回連続でブロックされたため、サーキットブレーカーで解放しました。ゲートは未通過（breaker_open）として記録されています。スキル名の誤り・ゲートスキルの不具合を確認してください（上限は HARNESS_MAX_GATE_BLOCKS で変更可）。" \
      '{systemMessage:$m}'
    exit 0
  fi

  plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  msg="harness ゲート [$workflow]: /$skill が未完了です。"
  if [ -n "$output" ]; then
    msg+=" 成果物 '$output' を作成してください（存在すれば自動通過します）。"
  else
    msg+=" /$skill を完了してから \`bash $plugin_root/scripts/mark-gate-passed.sh $skill $token\` を実行してください。"
    [ "$optional" = "true" ] && msg+=" このゲートは optional です。対象外と判断した場合は \`bash $plugin_root/scripts/mark-gate-passed.sh $skill $token --skip \"<理由>\"\` でスキップできます。"
  fi
  msg+=" トークンなしの記録・touch による偽装は無効です。"
  block "$msg"
done <<< "$gates"

exit 0
