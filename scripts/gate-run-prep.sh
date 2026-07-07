#!/usr/bin/env bash
# harness.yaml でゲートに agent: が設定されている任意のスキルを、
# 独立コンテキストのサブエージェントとして実行するための準備。
# ペルソナ定義（agent/model/context）・元スキルの指示内容・diff・チケット内容
# （github-issues なら gh で本文取得）・セッション+ゲート名スコープの
# アーティファクト出力先を JSON で出力する。
# diff はレビュー系ゲート、チケットは entry の計画系ゲート（plan 等）向け。
# どちらも常に取得を試み、値が空かどうかは呼び出し側（/gate-run）が判断する。
# Usage: gate-run-prep.sh <gate-skill-name> [--pr <番号>]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../hooks/lib.sh"

skill="${1:-}"
[ -z "$skill" ] && { echo "Usage: gate-run-prep.sh <gate-skill-name> [--pr <番号>]" >&2; exit 1; }
shift
pr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) pr="$2"; shift 2 ;;
    *) shift ;;
  esac
done

root=$(resolve_root "")
lock=$(ensure_lock "$root") || { echo "エラー: harness.yaml をコンパイルできません" >&2; exit 1; }
sid=$(resolve_session_id) || { echo "エラー: セッション ID を解決できません" >&2; exit 1; }
sp=$(state_path "$lock" "$sid")
[ -f "$sp" ] || { echo "エラー: セッション状態が見つかりません。/flow でワークフローを宣言してください" >&2; exit 1; }
workflow=$(jq -r '.workflow // empty' "$sp")
[ -z "$workflow" ] && { echo "エラー: ワークフロー未宣言です。/flow で宣言してください" >&2; exit 1; }
ticket=$(jq -r '.ticket // empty' "$sp")

gate=$(jq -c --arg w "$workflow" --arg s "$skill" \
  '((.workflows[$w].entry.gates // []) + (.workflows[$w].gates // [])) | .[] | select(.skill == $s)' "$lock")
[ -z "$gate" ] && { echo "エラー: ワークフロー '$workflow' に skill '$skill' のゲートが見つかりません" >&2; exit 1; }

agent_name=$(echo "$gate" | jq -r '.agent // empty')
[ -z "$agent_name" ] && { echo "エラー: ゲート '$skill' には agent: が設定されていません。独立コンテキスト実行の対象外です（/$skill を直接実行してください）" >&2; exit 1; }

persona=$(jq -c --arg a "$agent_name" '.personas[$a] // empty' "$lock")
[ -z "$persona" ] && { echo "エラー: personas.'$agent_name' が harness.yaml に未定義です" >&2; exit 1; }

# 元スキルの指示内容（プロジェクト固有を優先、なければプラグイン同梱）。
# 見つからない場合はサブエージェント自身の agent 定義（システムプロンプト）
# だけで完結する想定として扱う（例: planner はこれで足りる）。
skill_md=""
for cand in "$root/.claude/skills/$skill/SKILL.md" "$HARNESS_PLUGIN_ROOT/skills/$skill/SKILL.md"; do
  if [ -f "$cand" ]; then skill_md="$cand"; break; fi
done

# diff（review 系ゲート向け）
diff_file=$(gather_diff "$root" "$pr")

# チケット内容（plan 等の entry ゲート向け。github-issues なら本文取得）
ticket_body=""
provider=$(jq -r '.tickets.provider // "none"' "$lock")
if [ -n "$ticket" ] && [ "$provider" = "github-issues" ] && command -v gh >/dev/null 2>&1; then
  ticket_body=$( (cd "$root" && gh issue view "${ticket#\#}" --json title,body -q '.title + "\n\n" + .body' 2>/dev/null) || echo "")
fi

artifact_path=$(gate_artifact_path "$root" "$sid" "$skill" "report.md")

jq -n \
  --arg root "$root" \
  --arg skill "$skill" \
  --argjson persona "$persona" \
  --arg skill_md "$skill_md" \
  --arg diff_file "$diff_file" \
  --arg ticket "$ticket" \
  --arg ticket_body "$ticket_body" \
  --arg artifact "$artifact_path" \
  '{
    root: $root,
    skill: $skill,
    persona: $persona,
    skill_md_path: $skill_md,
    diff_file: $diff_file,
    ticket: $ticket,
    ticket_body: $ticket_body,
    artifact_path: $artifact
  }'
