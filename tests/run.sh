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
personas:
  arch:
    agent: harness:architect-reviewer
    context: []
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
  verifyflow:
    gates:
      - { skill: checkpoint, verify: "test -f .verify-ok" }
  verifyflow2:
    gates:
      - { skill: scoped, verify: "test -f .claude-harness/{session_id}/marker" }
  agentflow:
    gates:
      - { skill: refactor, agent: arch }
  planflow:
    entry:
      gates:
        - { skill: plan, agent: arch, verify: "bash ${HARNESS_PLUGIN_ROOT}/scripts/verify-plan.sh .claude-harness/{session_id}/plan/report.md" }
        - { skill: plan-review, agent: arch, reads: plan, verify: "bash ${HARNESS_PLUGIN_ROOT}/scripts/verify-approved.sh .claude-harness/{session_id}/plan-review/report.md" }
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

echo "== 6b. gates[].verify（検証可能なアウトプットの強制） =="
VSID="sess-verify-1"
export CLAUDE_SESSION_ID="$VSID"
evv() { jq -n --arg sid "$VSID" --arg cwd "$ROOT" --arg tool "${1:-}" --arg f "${2:-}" --arg c "${3:-}" \
  '{session_id:$sid, cwd:$cwd, tool_name:$tool, tool_input:(if $f != "" then {file_path:$f} elif $c != "" then {command:$c} else {} end)}'; }
rm -f "$ROOT/.verify-ok"
(cd "$ROOT" && bash "$PLUGIN/scripts/flow-start.sh" verifyflow >/dev/null 2>&1)

out=$(evv "" | hook stop-sequencer.sh)
assert_contains "verify未設定な条件が満たされる前は checkpoint を要求" "/checkpoint" "$out"
vtoken=$(jq -r '.pending_token.token' "$HARNESS_STATE_DIR/testproj/$VSID.json")
t "トークン発行" test -n "$vtoken"

bash "$PLUGIN/scripts/mark-gate-passed.sh" checkpoint "$vtoken" >/dev/null
out=$(evv "" | hook stop-sequencer.sh)
assert_contains "verify コマンドが失敗（.verify-ok 未作成）すると再ブロックされる" "検証" "$out"
t "verify_failed として記録される" jq -e '.gates.checkpoint.status == "verify_failed"' "$HARNESS_STATE_DIR/testproj/$VSID.json"
vtoken2=$(jq -r '.pending_token.token' "$HARNESS_STATE_DIR/testproj/$VSID.json")
t "verify 失敗後もトークンは同じ（使い回せる。ブレーカーのカウンタも継続）" test "$vtoken" = "$vtoken2"
blocks=$(jq -r '.pending_token.blocks' "$HARNESS_STATE_DIR/testproj/$VSID.json")
t "ブロック回数がリセットされず継続している" test "$blocks" = "2"

touch "$ROOT/.verify-ok"
bash "$PLUGIN/scripts/mark-gate-passed.sh" checkpoint "$vtoken" >/dev/null
out=$(evv "" | hook stop-sequencer.sh)
assert_empty "verify コマンドが成功すれば同じトークンで通過できる" x "$out"
t "gates.checkpoint が passed になる" jq -e '.gates.checkpoint.status == "passed"' "$HARNESS_STATE_DIR/testproj/$VSID.json"
rm -f "$ROOT/.verify-ok"
export CLAUDE_SESSION_ID="$SID"

echo "== 6c. scripts/verify-approved.sh 単体 =="
echo '{"all_approved": true, "personas":[{"name":"qa","verdict":"approve","findings":[]}]}' > "$TMP/rf-ok.json"
t "all_approved:true で exit 0" bash "$PLUGIN/scripts/verify-approved.sh" "$TMP/rf-ok.json"
echo '{"all_approved": false, "personas":[{"name":"qa","verdict":"request_changes","findings":[{"severity":"P1"}]}]}' > "$TMP/rf-ng.json"
ngout=$(bash "$PLUGIN/scripts/verify-approved.sh" "$TMP/rf-ng.json" 2>&1); ngrc=$?
t "all_approved:false で exit 1" test "$ngrc" != 0
assert_contains "未承認ペルソナの内訳が stderr に出る（リダイレクト順序バグの回帰防止）" "qa" "$ngout"
ngout2=$(bash "$PLUGIN/scripts/verify-approved.sh" "$TMP/does-not-exist.json" 2>&1)
assert_contains "ファイル不在時は理由を説明する" "存在しません" "$ngout2"

# 単一レビュアー形状（plan-review 等: {approved, feedback, concerns}）にも対応
echo '{"approved": true, "feedback": "OK", "concerns": []}' > "$TMP/single-ok.json"
t "単一形状 approved:true で exit 0" bash "$PLUGIN/scripts/verify-approved.sh" "$TMP/single-ok.json"
echo '{"approved": false, "feedback": "スコープ外が薄い", "concerns": ["スコープ外不足"]}' > "$TMP/single-ng.json"
singleout=$(bash "$PLUGIN/scripts/verify-approved.sh" "$TMP/single-ng.json" 2>&1); singlerc=$?
t "単一形状 approved:false で exit 1" test "$singlerc" != 0
assert_contains "単一形状の feedback が stderr に出る" "スコープ外が薄い" "$singleout"
assert_contains "単一形状の concerns が stderr に出る" "スコープ外不足" "$singleout"

echo "== 6d. gates[].agent（独立コンテキスト実行の一般化） =="
# compile.py: 未定義ペルソナを agent: に指定したら検証エラー
badyaml="$TMP/bad-agent.yaml"
cat > "$badyaml" <<'EOF'
version: 0
project: { name: badagent }
workflows:
  implement: { default: true, gates: [ { skill: refactor, agent: nope } ] }
EOF
badout2=$(yaml_to_json "$badyaml" | python3 "$PLUGIN/scripts/compile.py" --source "$badyaml" --root "$TMP" --engine-version t 2>&1 >/dev/null)
assert_contains "未定義ペルソナを agent: に指定するとエラー" "nope" "$badout2"

# compile.py: reads: が同一ワークフロー内に存在しないゲート名を指したら検証エラー
badyaml2="$TMP/bad-reads.yaml"
cat > "$badyaml2" <<'EOF'
version: 0
project: { name: badreads }
personas: { p: { agent: harness:architect-reviewer } }
workflows:
  implement: { default: true, gates: [ { skill: review, agent: p, reads: nonexistent-gate } ] }
EOF
badout3=$(yaml_to_json "$badyaml2" | python3 "$PLUGIN/scripts/compile.py" --source "$badyaml2" --root "$TMP" --engine-version t 2>&1 >/dev/null)
assert_contains "reads: が存在しないゲートを指すとエラー" "nonexistent-gate" "$badout3"

ASID="sess-agent-1"
export CLAUDE_SESSION_ID="$ASID"
(cd "$ROOT" && bash "$PLUGIN/scripts/flow-start.sh" agentflow >/dev/null 2>&1)
out=$(jq -n --arg sid "$ASID" --arg cwd "$ROOT" '{session_id:$sid, cwd:$cwd, tool_name:"", tool_input:{}}' | hook stop-sequencer.sh)
assert_contains "agent: 付きゲートは /gate-run を案内する（メインコンテキストでの直接実行を防ぐ）" "/gate-run refactor" "$out"
assert_contains "ペルソナ名も案内に含まれる" "arch" "$out"

prep=$(bash "$PLUGIN/scripts/gate-run-prep.sh" refactor 2>/dev/null)
t "gate-run-prep が valid JSON を返す" jq -e '.artifact_path' <<<"$prep"
t "persona 定義(agent/context)を含む。harness: prefix は compile.py が実 plugin 名（claude-harness:）へ解決済み" jq -e '.persona.agent == "claude-harness:architect-reviewer"' <<<"$prep"
assert_contains "artifact_path がセッションでスコープされる" "$ASID" "$(jq -r '.artifact_path' <<<"$prep")"

noagent_err=$(bash "$PLUGIN/scripts/gate-run-prep.sh" qa-review 2>&1 >/dev/null)
assert_contains "agent: 未設定のゲートは gate-run-prep がエラーで案内する" "agent" "$noagent_err"
export CLAUDE_SESSION_ID="$SID"

# harness: → 実プラグイン名（plugin.json の name）への解決は実地検証（classly への
# 実インストール）で発見した不具合の回帰防止。HARNESS_PLUGIN_ROOT 未設定時は
# 解決できないため 'harness:' のまま通す（compile.py 単独実行時のフォールバック）。
resolveyaml="$TMP/resolve-agent.yaml"
cat > "$resolveyaml" <<'EOF'
version: 0
project: { name: resolveagent }
personas: { p: { agent: harness:qa-reviewer } }
workflows:
  implement: { default: true, gates: [ { skill: refactor, agent: p } ] }
EOF
resolved_with_root=$(HARNESS_PLUGIN_ROOT="$PLUGIN" python3 -c "
import yaml, json, sys
print(json.dumps(yaml.safe_load(open('$resolveyaml'))))
" | HARNESS_PLUGIN_ROOT="$PLUGIN" python3 "$PLUGIN/scripts/compile.py" --source "$resolveyaml" --root "$TMP" --engine-version t 2>/dev/null)
t "HARNESS_PLUGIN_ROOT 設定時: harness:qa-reviewer が claude-harness:qa-reviewer に解決される" \
  jq -e '.personas.p.agent == "claude-harness:qa-reviewer"' <<<"$resolved_with_root"

resolved_no_root=$(env -u HARNESS_PLUGIN_ROOT python3 -c "
import yaml, json, sys
print(json.dumps(yaml.safe_load(open('$resolveyaml'))))
" | env -u HARNESS_PLUGIN_ROOT python3 "$PLUGIN/scripts/compile.py" --source "$resolveyaml" --root "$TMP" --engine-version t 2>/dev/null)
t "HARNESS_PLUGIN_ROOT 未設定時はフォールバックで harness: のまま（クラッシュしない）" \
  jq -e '.personas.p.agent == "harness:qa-reviewer"' <<<"$resolved_no_root"

echo "== 6e. {session_id} 置換によるアーティファクト衝突防止 =="
BSID1="sess-scoped-1"; BSID2="sess-scoped-2"
evscoped() { jq -n --arg sid "$1" --arg cwd "$ROOT" '{session_id:$sid, cwd:$cwd, tool_name:"", tool_input:{}}'; }

export CLAUDE_SESSION_ID="$BSID1"
(cd "$ROOT" && bash "$PLUGIN/scripts/flow-start.sh" verifyflow2 >/dev/null 2>&1)
evscoped "$BSID1" | hook stop-sequencer.sh >/dev/null   # 1回目 block・トークン発行
btoken1=$(jq -r '.pending_token.token' "$HARNESS_STATE_DIR/testproj/$BSID1.json")

export CLAUDE_SESSION_ID="$BSID2"
(cd "$ROOT" && bash "$PLUGIN/scripts/flow-start.sh" verifyflow2 >/dev/null 2>&1)
evscoped "$BSID2" | hook stop-sequencer.sh >/dev/null   # 1回目 block・トークン発行
btoken2=$(jq -r '.pending_token.token' "$HARNESS_STATE_DIR/testproj/$BSID2.json")
t "2セッションのトークンは別物" test "$btoken1" != "$btoken2"

# セッション1の marker だけを作り、両セッションとも mark-gate-passed する
mkdir -p "$ROOT/.claude-harness/$BSID1"
touch "$ROOT/.claude-harness/$BSID1/marker"
bash "$PLUGIN/scripts/mark-gate-passed.sh" scoped "$btoken1" >/dev/null
bash "$PLUGIN/scripts/mark-gate-passed.sh" scoped "$btoken2" >/dev/null

out=$(evscoped "$BSID1" | hook stop-sequencer.sh)
assert_empty "セッション1は自分の {session_id} 展開先の marker で通過する" x "$out"
out=$(evscoped "$BSID2" | hook stop-sequencer.sh)
assert_contains "セッション2はセッション1の marker では通過しない（{session_id}展開で衝突していない証拠）" "検証" "$out"

# セッション2は自分の marker を作れば独立に通過できる
mkdir -p "$ROOT/.claude-harness/$BSID2"
touch "$ROOT/.claude-harness/$BSID2/marker"
btoken2b=$(jq -r '.pending_token.token' "$HARNESS_STATE_DIR/testproj/$BSID2.json")
bash "$PLUGIN/scripts/mark-gate-passed.sh" scoped "$btoken2b" >/dev/null
out=$(evscoped "$BSID2" | hook stop-sequencer.sh)
assert_empty "セッション2も自分の marker を作れば独立に通過する" x "$out"

rm -rf "$ROOT/.claude-harness"
export CLAUDE_SESSION_ID="$SID"

echo "== 6f. 進捗ログ（.claude-harness/progress.log。セッションをまたいで永続） =="
rm -f "$ROOT/.claude-harness/progress.log"
CSID="sess-log-1"
export CLAUDE_SESSION_ID="$CSID"
(cd "$ROOT" && bash "$PLUGIN/scripts/flow-start.sh" verifyflow >/dev/null 2>&1)
t "workflow_started が記録される" bash -c "jq -e 'select(.event==\"workflow_started\")' '$ROOT/.claude-harness/progress.log' >/dev/null"
touch "$ROOT/.verify-ok"
lsid_sp="$HARNESS_STATE_DIR/testproj/$CSID.json"
jq -n --arg sid "$CSID" --arg cwd "$ROOT" '{session_id:$sid, cwd:$cwd, tool_name:"", tool_input:{}}' | hook stop-sequencer.sh >/dev/null
ltoken=$(jq -r '.pending_token.token' "$lsid_sp")
bash "$PLUGIN/scripts/mark-gate-passed.sh" checkpoint "$ltoken" >/dev/null
jq -n --arg sid "$CSID" --arg cwd "$ROOT" '{session_id:$sid, cwd:$cwd, tool_name:"", tool_input:{}}' | hook stop-sequencer.sh >/dev/null
t "gate_passed が記録される（SessionEnd後も消えない永続ログ）" bash -c "jq -e 'select(.event==\"gate_passed\")' '$ROOT/.claude-harness/progress.log' >/dev/null"
rm -f "$ROOT/.verify-ok"
export CLAUDE_SESSION_ID="$SID"

echo "== 6g. plan entry ゲート（Anthropic Planner相当・着手前の計画） =="
PSID="sess-plan-1"
export CLAUDE_SESSION_ID="$PSID"
(cd "$ROOT" && bash "$PLUGIN/scripts/flow-start.sh" planflow 99 >/dev/null 2>&1)

# entry ゲートは編集より前に要求される（tdd と同様、実装ファイルへの編集も
# この時点ではまだ許可されない設計だが、ここでは Stop の要求内容を確認する）
out=$(jq -n --arg sid "$PSID" --arg cwd "$ROOT" '{session_id:$sid, cwd:$cwd, tool_name:"", tool_input:{}}' | hook stop-sequencer.sh)
assert_contains "entry ゲートも agent: があれば /gate-run を要求する（flow-start の表示バグを含め検証）" "/gate-run plan" "$out"
ptoken=$(jq -r '.pending_token.token' "$HARNESS_STATE_DIR/testproj/$PSID.json")

prep=$(bash "$PLUGIN/scripts/gate-run-prep.sh" plan 2>/dev/null)
t "gate-run-prep が plan ゲートにも使える（agent も claude-harness: へ解決済み）" jq -e '.persona.agent == "claude-harness:architect-reviewer"' <<<"$prep"
assert_contains "ticket が宣言時の値を反映する（diffではなくticket文脈が必要な計画系ゲート）" "99" "$(jq -r '.ticket' <<<"$prep")"
artifact=$(jq -r '.artifact_path' <<<"$prep")
assert_contains "artifact_path が plan 配下でセッションスコープされる" "plan" "$artifact"

bash "$PLUGIN/scripts/mark-gate-passed.sh" plan "$ptoken" >/dev/null
out=$(jq -n --arg sid "$PSID" --arg cwd "$ROOT" '{session_id:$sid, cwd:$cwd, tool_name:"", tool_input:{}}' | hook stop-sequencer.sh)
assert_contains "計画ファイル未作成なら verify-plan.sh が却下する" "検証" "$out"

mkdir -p "$(dirname "$ROOT/$artifact")"
printf '# 実装計画\n\n## スコープ\nダミー計画の本文\n\n## スコープ外\nダミー\n\n## リスク\nダミー\n' > "$ROOT/$artifact"
bash "$PLUGIN/scripts/mark-gate-passed.sh" plan "$ptoken" >/dev/null
out=$(jq -n --arg sid "$PSID" --arg cwd "$ROOT" '{session_id:$sid, cwd:$cwd, tool_name:"", tool_input:{}}' | hook stop-sequencer.sh)
assert_contains "plan 通過後は plan-review（reads: plan）がブロックする" "/gate-run plan-review" "$out"
t "gates.plan が passed になる" jq -e '.gates.plan.status == "passed"' "$HARNESS_STATE_DIR/testproj/$PSID.json"
prtoken=$(jq -r '.pending_token.token' "$HARNESS_STATE_DIR/testproj/$PSID.json")

echo "== 6h. plan-review（reads: による計画の独立レビュー・却下→再提出ループ） =="
rprep=$(bash "$PLUGIN/scripts/gate-run-prep.sh" plan-review 2>/dev/null)
t "reads_skill が plan を指す" jq -e '.reads_skill == "plan"' <<<"$rprep"
assert_contains "reads_content に plan が書いた計画本文が含まれる（別ゲートの成果物参照が機能している）" "ダミー計画の本文" "$(jq -r '.reads_content' <<<"$rprep")"
rartifact=$(jq -r '.artifact_path' <<<"$rprep")

# 却下（approved:false）→ verify-approved.sh が拒否 → 同じトークンで再ブロック
mkdir -p "$(dirname "$ROOT/$rartifact")"
echo '{"approved": false, "feedback": "スコープ外が薄い", "concerns": ["スコープ外の具体性不足"]}' > "$ROOT/$rartifact"
bash "$PLUGIN/scripts/mark-gate-passed.sh" plan-review "$prtoken" >/dev/null
out=$(jq -n --arg sid "$PSID" --arg cwd "$ROOT" '{session_id:$sid, cwd:$cwd, tool_name:"", tool_input:{}}' | hook stop-sequencer.sh)
assert_contains "却下(approved:false)なら verify-approved.sh が再ブロックする" "検証" "$out"
prtoken2=$(jq -r '.pending_token.token' "$HARNESS_STATE_DIR/testproj/$PSID.json")
t "却下後もトークンは同じ（計画を直して同じトークンで再提出するループになる）" test "$prtoken" = "$prtoken2"

echo "== 6i. プランナーの再起動（reads の逆引きで却下フィードバックを自動検出） =="
replan_prep=$(bash "$PLUGIN/scripts/gate-run-prep.sh" plan 2>/dev/null)
assert_contains "却下している plan-review を revision_from として自動検出する" "plan-review" "$(jq -r '.revision_from' <<<"$replan_prep")"
assert_contains "却下時の feedback が revision_feedback に自動的に入る（手動再構成不要）" "スコープ外が薄い" "$(jq -r '.revision_feedback' <<<"$replan_prep")"
assert_contains "却下時の concerns も含まれる" "スコープ外の具体性不足" "$(jq -r '.revision_feedback' <<<"$replan_prep")"

# プランナー役が計画を修正 → レビュアー役が承認（approved:true）に変えて再提出
printf '# 実装計画\n\n## スコープ\nダミー計画の本文（改訂）\n\n## スコープ外\n具体的に明記した\n\n## リスク\nダミー\n' > "$ROOT/$artifact"
echo '{"approved": true, "feedback": "スコープ外が明確になった", "concerns": []}' > "$ROOT/$rartifact"
bash "$PLUGIN/scripts/mark-gate-passed.sh" plan-review "$prtoken" >/dev/null
out=$(jq -n --arg sid "$PSID" --arg cwd "$ROOT" '{session_id:$sid, cwd:$cwd, tool_name:"", tool_input:{}}' | hook stop-sequencer.sh)
assert_empty "承認(approved:true)されれば全 entry ゲート通過（ループの出口）" x "$out"
t "gates.plan-review が passed になる" jq -e '.gates["plan-review"].status == "passed"' "$HARNESS_STATE_DIR/testproj/$PSID.json"

replan_prep2=$(bash "$PLUGIN/scripts/gate-run-prep.sh" plan 2>/dev/null)
t "承認後は revision_from が再検出されない（最新状態を都度参照している）" \
  test "$(jq -r '.revision_from' <<<"$replan_prep2")" = ""

rm -rf "$ROOT/.claude-harness/$PSID"
export CLAUDE_SESSION_ID="$SID"

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
assert_contains "永続進捗ログのセクションを含む" "最近の進捗" "$mapout"
assert_contains "6f で記録した workflow_started が表示される" "workflow_started" "$mapout"
assert_contains "agent: のバッジを mermaid に含む" "独立コンテキスト" "$mapout"

echo "== 11. harness-audit =="
auditout=$(bash "$PLUGIN/scripts/harness-audit.sh" "$ROOT" 2>&1); rc=$?
t "FATAL なしで exit 0" test "$rc" = 0
assert_contains "コンパイル成功を報告" "コンパイル成功" "$auditout"
assert_contains "欠落スキルを WARN" "WARN" "$auditout"
assert_contains "agent 付きゲートは SKILL.md 不要として WARN しない" "agent 付き。/gate-run 経由のため SKILL.md 不要" "$auditout"
if echo "$auditout" | grep -q "スキル 'plan' がプロジェクト"; then
  FAIL=$((FAIL+1)); echo "  NG: agent 付き plan ゲートが誤って WARN されている"
else
  PASS=$((PASS+1)); echo "  ok: agent 付き plan ゲートが WARN されない（実地検証で発見した誤検知の回帰防止）"
fi

echo "== 12. review-board-prep =="
prep=$(bash "$PLUGIN/scripts/review-board-prep.sh" --personas qa 2>/dev/null)
t "prep が valid JSON" jq -e '.diff_file' <<<"$prep"
t "ペルソナ名を返す" jq -e '.personas[0].name == "qa"' <<<"$prep"
t "artifact_path を返す" jq -e '.artifact_path' <<<"$prep"
assert_contains "artifact_path がセッションでスコープされる" "$SID" "$(jq -r '.artifact_path' <<<"$prep")"
assert_contains "artifact_path が review-board 配下" "review-board" "$(jq -r '.artifact_path' <<<"$prep")"

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
