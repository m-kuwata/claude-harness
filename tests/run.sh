#!/usr/bin/env bash
# エンジンの E2E スモークテスト。フックに偽の stdin JSON を流し、実セッションの流れを再現する。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(dirname "$HERE")"
TMP=$(mktemp -d)
export HARNESS_STATE_DIR="$TMP/state"
export CLAUDE_SESSION_ID="sess-test-1"
SID="sess-test-1"
PASS=0; FAIL=0

t() { # $1=名前 $2=期待(成功コマンド)
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "  ok: $name"
  else FAIL=$((FAIL+1)); echo "  NG: $name"; fi
}
assert_contains() { # $1=名前 $2=needle $3=haystack
  if echo "$3" | grep -qF -- "$2"; then PASS=$((PASS+1)); echo "  ok: $1"
  else FAIL=$((FAIL+1)); echo "  NG: $1"; echo "     期待: $2"; echo "     実際: $(echo "$3" | head -3)"; fi
}
assert_empty() {
  if [ -z "$3" ]; then PASS=$((PASS+1)); echo "  ok: $1"
  else FAIL=$((FAIL+1)); echo "  NG: $1（出力が空でない: $(echo "$3" | head -2)）"; fi
}
hook() { # $1=hook名 stdin=JSON
  bash "$PLUGIN/hooks/$1" 2>/dev/null
}
ev() { # イベント JSON 生成 $1=tool $2=file (省略可) $3=command (省略可)
  jq -n --arg sid "$SID" --arg cwd "$ROOT" --arg tool "${1:-}" --arg f "${2:-}" --arg c "${3:-}" \
    '{session_id:$sid, cwd:$cwd, tool_name:$tool,
      tool_input: (if $f != "" then {file_path:$f} elif $c != "" then {command:$c} else {} end)}'
}

# ---- テスト用プロジェクト ----------------------------------------
ROOT="$TMP/proj"
mkdir -p "$ROOT/.claude" "$ROOT/src/app" "$ROOT/docs"
cd "$ROOT" && git init -q -b main
cat > "$ROOT/.claude/harness.yaml" <<'EOF'
version: 0
project: { name: testproj }
paths:
  impl:
    include: ["src/**/*.{ts,tsx}"]
    exclude: ["**/*.{test,spec}.{ts,tsx}"]
  screen:
    include: ["src/app/**/*.tsx"]
  test:
    include: ["**/*.{test,spec}.{ts,tsx}"]
  exempt:
    include: ["docs/**", "*.md"]
tickets:
  provider: none
  exempt: [exempt, test]
ci:
  on_commit:
    - run: "test -f .ci-ok"
workflows:
  implement:
    default: true
    gates:
      - { skill: refactor, when: impl }
      - { skill: qa-review, when: impl, optional: true }
      - { skill: design-check, when: screen }
  investigate:
    permissions: read-only
    gates:
      - { skill: report, output: "docs/research/{date}-{slug}.md" }
EOF

echo "== 1. コンパイル =="
source "$PLUGIN/hooks/lib.sh"
lock=$(ensure_lock "$ROOT"); rc=$?
t "lock 生成" test "$rc" = 0
t "lock は valid JSON" jq -e '.project.name == "testproj"' "$lock"
t "glob→regex 変換" jq -e '.paths.impl.include_re' "$lock"
echo 'version: 0
project: { name: bad }
workflows:
  w1: { gates: [ { skill: x, when: nonexistent } ] }' > "$ROOT/.claude/harness.yaml.bad"
badout=$(yaml_to_json "$ROOT/.claude/harness.yaml.bad" | python3 "$PLUGIN/scripts/compile.py" --source "$ROOT/.claude/harness.yaml.bad" --root "$ROOT" --engine-version t 2>&1 >/dev/null)
assert_contains "未定義 paths クラスを検証エラーにする" "nonexistent" "$badout"

echo "== 2. SessionStart =="
out=$(ev "" | jq --arg s "$SID" '. + {session_id:$s}' | hook session-start.sh)
assert_contains "サマリ注入" "workflows: implement*" "$out"
t "セッション状態が初期化される" test -f "$HARNESS_STATE_DIR/testproj/$SID.json"

echo "== 3. flow 未宣言ガード =="
out=$(ev Edit "$ROOT/src/main.ts" | hook pre-tool-dispatch.sh)
assert_contains "impl 編集を deny" '"permissionDecision":"deny"' "$out"
out=$(ev Edit "$ROOT/docs/note.md" | hook pre-tool-dispatch.sh)
assert_empty "exempt(docs) は素通し" x "$out"
out=$(ev Edit "$ROOT/src/main.test.ts" | hook pre-tool-dispatch.sh)
assert_empty "test は素通し（RED 先行可）" x "$out"

echo "== 4. flow 宣言 =="
out=$(bash "$PLUGIN/scripts/flow-start.sh" implement 2>&1)
assert_contains "ゲート計画を提示" "/refactor" "$out"
out=$(ev Edit "$ROOT/src/main.ts" | hook pre-tool-dispatch.sh)
assert_empty "宣言後は impl 編集可" x "$out"

echo "== 5. dirty 追跡 + シーケンサー =="
echo "x" > "$ROOT/src/main.ts"
ev Edit "$ROOT/src/main.ts" | hook post-tool-dispatch.sh >/dev/null
t "dirty.impl が立つ" jq -e '.dirty.impl == true' "$HARNESS_STATE_DIR/testproj/$SID.json"
out=$(ev "" | hook stop-sequencer.sh)
assert_contains "最初のゲート(refactor)を要求" "/refactor" "$out"
token=$(jq -r '.pending_token.token' "$HARNESS_STATE_DIR/testproj/$SID.json")
t "トークン発行" test -n "$token"
out2=$(ev "" | hook stop-sequencer.sh)
tok2=$(jq -r '.pending_token.token' "$HARNESS_STATE_DIR/testproj/$SID.json")
t "再 block でトークン不変" test "$token" = "$tok2"

echo "== 6. ノンス検証 =="
bash "$PLUGIN/scripts/mark-gate-passed.sh" refactor "deadbeef00000000" >/dev/null
out=$(ev "" | hook stop-sequencer.sh)
assert_contains "偽トークンは無効（まだ refactor 要求）" "/refactor" "$out"
bash "$PLUGIN/scripts/mark-gate-passed.sh" refactor "$token" >/dev/null
out=$(ev "" | hook stop-sequencer.sh)
assert_contains "正トークンで次ゲート(qa-review)へ" "/qa-review" "$out"
assert_contains "optional の案内あり" "--skip" "$out"
token=$(jq -r '.pending_token.token' "$HARNESS_STATE_DIR/testproj/$SID.json")
bash "$PLUGIN/scripts/mark-gate-passed.sh" qa-review "$token" --skip "テスト用" >/dev/null
out=$(ev "" | hook stop-sequencer.sh)
assert_empty "screen 未変更なので design-check はスキップ → 全通過" x "$out"
t "skip 理由が記録される" jq -e '.gates["qa-review"].status == "skipped"' "$HARNESS_STATE_DIR/testproj/$SID.json"

echo "== 7. セッション分離 =="
SID2="sess-test-2"
export CLAUDE_SESSION_ID="$SID2"
out=$(ev Edit "$ROOT/src/other.ts" | jq --arg s "$SID2" '. + {session_id:$s}' | hook pre-tool-dispatch.sh)
assert_contains "別セッションはフロー未宣言のまま" '"deny"' "$out"
export CLAUDE_SESSION_ID="$SID"

echo "== 8. read-only フロー =="
bash "$PLUGIN/scripts/flow-start.sh" investigate >/dev/null 2>&1
out=$(ev Edit "$ROOT/src/main.ts" | hook pre-tool-dispatch.sh)
assert_contains "read-only で impl 編集を deny" "read-only" "$out"
out=$(ev "" | hook stop-sequencer.sh)
assert_contains "report ゲート（成果物）を要求" "docs/research/" "$out"
mkdir -p "$ROOT/docs/research"
echo r > "$ROOT/docs/research/$(date +%Y-%m-%d)-abc.md"
out=$(ev "" | hook stop-sequencer.sh)
assert_empty "成果物が存在すれば自動通過" x "$out"

echo "== 9. on_commit ゲート =="
bash "$PLUGIN/scripts/flow-start.sh" implement >/dev/null 2>&1
out=$(ev Bash "" "git commit -m test" | hook pre-tool-dispatch.sh)
assert_contains "CI 失敗で commit を deny" '"deny"' "$out"
touch "$ROOT/.ci-ok"
out=$(ev Bash "" "git commit -m test" | hook pre-tool-dispatch.sh)
assert_empty "CI 成功で commit 許可" x "$out"

echo "== 10. SessionEnd =="
ev "" | hook session-end.sh
t "状態ファイルが削除される" test ! -f "$HARNESS_STATE_DIR/testproj/$SID.json"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
rm -rf "$TMP"
[ "$FAIL" = 0 ]
