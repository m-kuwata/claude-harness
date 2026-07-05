#!/usr/bin/env bash
# harness 設定の健全性監査。FATAL があれば exit 1。
# Usage: harness-audit.sh [プロジェクトルート]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../hooks/lib.sh"
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

root="${1:-$(resolve_root "")}"
FATAL=0; WARN=0
fatal() { echo "  FATAL: $1"; FATAL=$((FATAL+1)); }
warn()  { echo "  WARN:  $1"; WARN=$((WARN+1)); }
ok()    { echo "  ok:    $1"; }

echo "== harness 監査: $root =="

echo "[0] エンジン依存"
for t in jq python3; do
  command -v "$t" >/dev/null 2>&1 && ok "$t" || fatal "$t がありません"
done
if python3 -c 'import yaml' 2>/dev/null; then ok "YAML パーサ (PyYAML)"
elif command -v yq >/dev/null 2>&1; then ok "YAML パーサ (yq)"
else fatal "YAML パーサがありません（PyYAML または yq）"; fi

echo "[1] harness.yaml コンパイル"
if [ ! -f "$root/.claude/harness.yaml" ]; then
  fatal ".claude/harness.yaml がありません（/harness-init で生成してください）"
  echo ""; echo "結果: FATAL=$FATAL WARN=$WARN"; exit 1
fi
if err=$(compile_lock "$root" 2>&1); then
  lock=$(lock_path "$root")
  ok "コンパイル成功（engine v$(jq -r '.meta.engine_version' "$lock") / source $(jq -r '.meta.source_hash' "$lock")）"
else
  fatal "コンパイル失敗: $(echo "$err" | head -5 | tr '\n' ' ')"
  echo ""; echo "結果: FATAL=$FATAL WARN=$WARN"; exit 1
fi

echo "[2] エンジンバージョン整合"
plugin_ver=$(jq -r '.version' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || echo "?")
lock_ver=$(jq -r '.meta.engine_version' "$lock")
if [ "$plugin_ver" = "$lock_ver" ]; then ok "plugin v$plugin_ver = lock v$lock_ver"
else warn "plugin v$plugin_ver と lock v$lock_ver が不一致（lock を再コンパイルしてください）"; fi

echo "[3] ゲートが参照するスキルの存在"
while IFS= read -r skill; do
  [ -z "$skill" ] && continue
  if [ -f "$root/.claude/skills/$skill/SKILL.md" ] || [ -f "$PLUGIN_ROOT/skills/$skill/SKILL.md" ]; then
    ok "スキル '$skill'"
  else
    warn "ゲートが参照するスキル '$skill' がプロジェクト（.claude/skills/）にもプラグインにも見つかりません"
  fi
done < <(jq -r '[.workflows[] | ((.entry.gates // []) + (.gates // []))[] | .skill] | unique[]' "$lock")

echo "[4] ペルソナ定義の存在"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  name="${line%%|*}"; agent="${line#*|}"
  base="${agent#harness:}"
  if [ -f "$PLUGIN_ROOT/agents/$base.md" ] || [ -f "$root/.claude/agents/$base.md" ]; then
    ok "ペルソナ '$name' → agent '$base'"
  else
    warn "ペルソナ '$name' の agent 定義 '$base' が見つかりません（plugin agents/ or .claude/agents/）"
  fi
done < <(jq -r '.personas | to_entries[] | .key + "|" + .value.agent' "$lock")
while IFS= read -r ctx; do
  [ -z "$ctx" ] && continue
  [ -f "$root/$ctx" ] && ok "context 資料 '$ctx'" || warn "context 資料 '$ctx' がありません"
done < <(jq -r '[.personas[]?.context[]?] | unique[]' "$lock")

echo "[5] settings.json"
settings="$root/.claude/settings.json"
if [ -f "$settings" ]; then
  if jq . "$settings" >/dev/null 2>&1; then
    ok "valid JSON"
    if jq -e '.permissions.deny[]? | select(test("claude-harness"))' "$settings" >/dev/null 2>&1; then
      ok "状態ディレクトリ保護の deny あり"
    else
      warn "deny リストに harness 状態ディレクトリ保護がありません（推奨: \"Write(${STATE_ROOT}/**)\" / \"Edit(${STATE_ROOT}/**)\"）"
    fi
  else
    fatal "settings.json が不正な JSON です"
  fi
else
  warn ".claude/settings.json がありません（deny 第二防衛線が未設定）"
fi

echo ""
echo "結果: FATAL=$FATAL WARN=$WARN"
[ "$FATAL" = 0 ]
