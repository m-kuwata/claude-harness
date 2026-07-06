#!/usr/bin/env bash
# harness.yaml でゲートに agent: が設定されている任意のスキルを、
# 独立コンテキストのサブエージェントとして実行するための準備。
# ペルソナ定義（agent/model/context）・元スキルの指示内容・diff・
# セッション+ゲート名スコープのアーティファクト出力先を JSON で出力する。
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

gate=$(jq -c --arg w "$workflow" --arg s "$skill" \
  '((.workflows[$w].entry.gates // []) + (.workflows[$w].gates // [])) | .[] | select(.skill == $s)' "$lock")
[ -z "$gate" ] && { echo "エラー: ワークフロー '$workflow' に skill '$skill' のゲートが見つかりません" >&2; exit 1; }

agent_name=$(echo "$gate" | jq -r '.agent // empty')
[ -z "$agent_name" ] && { echo "エラー: ゲート '$skill' には agent: が設定されていません。独立コンテキスト実行の対象外です（/$skill を直接実行してください）" >&2; exit 1; }

persona=$(jq -c --arg a "$agent_name" '.personas[$a] // empty' "$lock")
[ -z "$persona" ] && { echo "エラー: personas.'$agent_name' が harness.yaml に未定義です" >&2; exit 1; }

# 元スキルの指示内容（プロジェクト固有を優先、なければプラグイン同梱）
skill_md=""
for cand in "$root/.claude/skills/$skill/SKILL.md" "$HARNESS_PLUGIN_ROOT/skills/$skill/SKILL.md"; do
  if [ -f "$cand" ]; then skill_md="$cand"; break; fi
done
[ -z "$skill_md" ] && echo "⚠ スキル '$skill' の SKILL.md が見つかりません（プロジェクト .claude/skills/ にもプラグインにもない）。指示内容なしでサブエージェントを起動することになります。" >&2

diff_file=$(gather_diff "$root" "$pr")
artifact_path=$(gate_artifact_path "$root" "$sid" "$skill" "report.json")

jq -n \
  --arg root "$root" \
  --arg skill "$skill" \
  --argjson persona "$persona" \
  --arg skill_md "$skill_md" \
  --arg diff_file "$diff_file" \
  --arg artifact "$artifact_path" \
  '{
    root: $root,
    skill: $skill,
    persona: $persona,
    skill_md_path: $skill_md,
    diff_file: $diff_file,
    artifact_path: $artifact
  }'
