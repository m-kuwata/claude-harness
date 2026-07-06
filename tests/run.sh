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
git -C "$ROOT" config user.email t@t && git -C "$ROOT" config user.name t
echo init > "$ROOT/init.txt" && git -C "$ROOT" add -A && git -C "$ROOT" commit -qm init
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
  on_edit:
    - paths: ["src/**/*.ts"]
      run: "echo linted:{file} >> .lint.log"
  on_commit:
    - run: "test -f .ci-ok"
    - when_staged: ["src/solver/**"]
      run: "test -f .solver-ci-ok"
guards:
  reuse:
    - on_create: "src/**/new-widget.ts"
      inventory: "ls src"
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

echo "== 4b. compile.py の (?:...) 正規表現を grep ではなく jq test() で照合する経路 =="
# glob の ** は compile.py で (?:.*/)? のような jq/Oniguruma 専用構文にコンパイルされる。
# POSIX grep -E はこれを解釈できず、GNU grep のみ警告付きでたまたま動くという移植性のない
# 状態だったため、grep 不使用（re_test 経由）に修正した経路を実地で検証する。
out=$(ev Write "$ROOT/src/new-widget.ts" 2>&1 | hook pre-tool-dispatch.sh 2>&1)
assert_contains "guards.reuse: (?:...) パターンでも新規作成が検知される" "additionalContext" "$out"

rm -f "$ROOT/.lint.log"
ev Edit "$ROOT/src/main.ts" | hook post-tool-dispatch.sh 2>/dev/null >/dev/null
t "ci.on_edit: (?:...) パターンでも on_edit コマンドが実行される" test -f "$ROOT/.lint.log"

mkdir -p "$ROOT/src/solver"
echo x > "$ROOT/src/solver/core.ts"
git -C "$ROOT" add -A
out=$(ev Bash "" "git commit -m test" | hook pre-tool-dispatch.sh)
assert_contains "ci.on_commit.when_staged: (?:...) パターンでも staged 判定が効きコマンド未整備で deny" '"deny"' "$out"
touch "$ROOT/.solver-ci-ok" "$ROOT/.ci-ok"   # 無条件ルールも一時的に満たす（section 9 の前提を壊さないよう後で消す）
out=$(ev Bash "" "git commit -m test" | hook pre-tool-dispatch.sh)
assert_empty "when_staged 条件のコマンドが成功すれば commit 許可" x "$out"
git -C "$ROOT" reset -q
rm -f "$ROOT/.ci-ok" "$ROOT/.solver-ci-ok"

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

echo "== 9b. サーキットブレーカー =="
bash "$PLUGIN/scripts/flow-start.sh" implement >/dev/null 2>&1
ev Edit "$ROOT/src/main.ts" | hook post-tool-dispatch.sh >/dev/null
export HARNESS_MAX_GATE_BLOCKS=2
ev "" | hook stop-sequencer.sh >/dev/null   # block 1回目
ev "" | hook stop-sequencer.sh >/dev/null   # block 2回目
out=$(ev "" | hook stop-sequencer.sh)       # 3回目 → ブレーカー開放
assert_contains "上限超過で block せず警告" "systemMessage" "$out"
t "breaker_open が記録される" jq -e '.gates.refactor.status == "breaker_open"' "$HARNESS_STATE_DIR/testproj/$SID.json"
out=$(ev "" | hook stop-sequencer.sh)
assert_contains "次のゲートへ進む" "/qa-review" "$out"
unset HARNESS_MAX_GATE_BLOCKS
token=$(jq -r '.pending_token.token' "$HARNESS_STATE_DIR/testproj/$SID.json")
bash "$PLUGIN/scripts/mark-gate-passed.sh" qa-review "$token" --skip "テスト用" >/dev/null

echo "== 10. harness-map =="
map="$TMP/map.md"
bash "$PLUGIN/scripts/harness-map.sh" "$map" >/dev/null 2>&1
t "map 生成" test -f "$map"
mapout=$(cat "$map" 2>/dev/null)
assert_contains "mermaid 図を含む" '```mermaid' "$mapout"
assert_contains "ワークフローを含む" "implement" "$mapout"
assert_contains "稼働セッションを含む" "稼働中セッション" "$mapout"

echo "== 11. harness-audit =="
auditout=$(bash "$PLUGIN/scripts/harness-audit.sh" "$ROOT" 2>&1); rc=$?
t "FATAL なしで exit 0" test "$rc" = 0
assert_contains "コンパイル成功を報告" "コンパイル成功" "$auditout"
assert_contains "欠落スキルを WARN" "WARN" "$auditout"

echo "== 12. review-board-prep =="
prep=$(bash "$PLUGIN/scripts/review-board-prep.sh" --personas qa 2>/dev/null)
t "prep が valid JSON" jq -e '.diff_file' <<<"$prep"
t "ペルソナ名を返す" jq -e '.personas[0].name == "qa"' <<<"$prep"

echo "== 13. JSON Schema =="
if python3 -c 'import jsonschema' 2>/dev/null; then
  t "example.yaml がスキーマに適合" python3 -c "
import json, yaml, jsonschema
schema = json.load(open('$PLUGIN/schemas/harness.schema.json'))
doc = yaml.safe_load(open('$PLUGIN/docs/harness.example.yaml'))
jsonschema.validate(doc, schema)
"
else
  echo "  skip: jsonschema 未導入"
fi

echo "== 14. SessionEnd =="
ev "" | hook session-end.sh
t "状態ファイルが削除される" test ! -f "$HARNESS_STATE_DIR/testproj/$SID.json"

# ============================================================
# 15. マルチリポジトリセッション
#   cwd が「複数リポジトリを含む親ディレクトリ」であるケース
#   （例: ユーザースコープでプラグインを入れ、~/projects/ のような
#   親ディレクトリからセッションを開始し、その配下の複数リポジトリを
#   同一セッションで横断する）。
#   ルート解決を cwd 依存にすると、この構成でエンジンが一切発火しない
#   回帰バグがあったため、ファイル単位のルート解決 + セッション内
#   registry で正しく動くことを検証する。
# ============================================================
echo "== 15. マルチリポジトリセッション（cwd が複数repoの親） =="
PARENT="$TMP/multi"
REPO_A="$PARENT/repo-a"; REPO_B="$PARENT/repo-b"
mkdir -p "$REPO_A/.claude/src" "$REPO_B/.claude/src" "$REPO_A/src" "$REPO_B/src"
for R in "$REPO_A" "$REPO_B"; do
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
done
cat > "$REPO_A/.claude/harness.yaml" <<'EOF'
version: 0
project: { name: repoa }
paths:
  impl: { include: ["src/**/*.ts"] }
workflows:
  implement: { default: true, gates: [ { skill: refactor, when: impl } ] }
EOF
cp "$REPO_A/.claude/harness.yaml" "$REPO_B/.claude/harness.yaml"
sed -i 's/repoa/repob/' "$REPO_B/.claude/harness.yaml"
git -C "$REPO_A" add -A && git -C "$REPO_A" commit -qm init >/dev/null
git -C "$REPO_B" add -A && git -C "$REPO_B" commit -qm init >/dev/null

MULTI_SID="sess-multi-1"
export CLAUDE_SESSION_ID="$MULTI_SID"
evc() { # $1=cwd $2=tool $3=file
  jq -n --arg sid "$MULTI_SID" --arg cwd "$1" --arg tool "$2" --arg f "$3" \
    '{session_id:$sid, cwd:$cwd, tool_name:$tool, tool_input:{file_path:$f}}'
}

# PARENT 自体は git リポジトリではない（複数リポジトリの単なる置き場）
git -C "$PARENT" rev-parse --show-toplevel >/dev/null 2>&1 && echo "  警告: PARENT が git repo になっている(テスト前提が崩れている)"

out=$(evc "$PARENT" Edit "$REPO_A/src/foo.ts" | hook pre-tool-dispatch.sh)
assert_contains "cwdが共有親でも repo-a の harness が発火して deny" '"deny"' "$out"

(cd "$REPO_A" && bash "$PLUGIN/scripts/flow-start.sh" implement >/dev/null 2>&1)

out=$(evc "$PARENT" Edit "$REPO_A/src/foo.ts" | hook pre-tool-dispatch.sh)
assert_empty "repo-a で flow 宣言後は cwd が親でも編集可" x "$out"

out=$(evc "$PARENT" Edit "$REPO_B/src/bar.ts" | hook pre-tool-dispatch.sh)
assert_contains "repo-b は別プロジェクトとして未宣言のまま(cwdが親でも正しく分離)" '"deny"' "$out"

echo "x" > "$REPO_A/src/foo.ts"
evc "$PARENT" Edit "$REPO_A/src/foo.ts" | hook post-tool-dispatch.sh >/dev/null
t "repo-a の dirty.impl が正しいプロジェクト配下に記録される" \
  jq -e '.dirty.impl == true' "$HARNESS_STATE_DIR/repoa/$MULTI_SID.json"

out=$(evc "$PARENT" "" "" | hook stop-sequencer.sh)
assert_contains "cwdが親のままでも Stop が repo-a の未通過ゲートを検知する" "/refactor" "$out"

token=$(jq -r '.pending_token.token' "$HARNESS_STATE_DIR/repoa/$MULTI_SID.json")
bash "$PLUGIN/scripts/mark-gate-passed.sh" refactor "$token" >/dev/null
out=$(evc "$PARENT" "" "" | hook stop-sequencer.sh)
assert_empty "repo-a のゲート通過後は(repo-bは未dirtyのため)Stopが素通し" x "$out"

evc "$PARENT" "" "" | hook session-end.sh
t "SessionEnd で repo-a の状態も掃除される（registry 経由）" \
  test ! -f "$HARNESS_STATE_DIR/repoa/$MULTI_SID.json"

export CLAUDE_SESSION_ID="$SID"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
rm -rf "$TMP"
[ "$FAIL" = 0 ]
