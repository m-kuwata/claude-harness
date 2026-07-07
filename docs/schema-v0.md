# harness.yaml スキーマ v0 草案

Claude Code ハーネスフレームワークの中核となる宣言的設定ファイルのスキーマ草案。
classly / pokotto-box / ehon-note / booktalk-ai の現行フック・スキル構成を突き合わせ、
全差分がこの1ファイルで表現できることを検証済み（末尾の検証表を参照）。

## 設計原則

1. **エンジンとパラメータの分離** — フック本体（エンジン）は全プロジェクト共通のプラグインとして配布し、プロジェクト差分は `.claude/harness.yaml` だけに置く
2. **ワークフローは複数定義** — implement / investigate / pr-review など粒度の違うフローを名前つきで宣言し、セッションごとに1つを有効化する
3. **ゲート状態はセッション単位** — 状態はセッションIDをキーにした JSON 1ファイル。複数セッション並走で競合しない
4. **改ざん防止はノンス方式** — ゲート通過の記録は Stop フックが発行したワンタイムトークンでのみ有効。他セッションのマーカーも `touch` も効かない
5. **閲覧は自動生成、編集は YAML** — 編集 GUI は作らない。JSON Schema + 初期化ウィザード + 読み取り専用ビジュアライザで代替する

## ファイル配置

```
<project>/
├── .claude/
│   ├── harness.yaml            # 本スキーマ。プロジェクトが書くのはこれだけ
│   ├── settings.json           # permissions（deny 等）とプラグイン外フックのみ
│   ├── agents/                 # プロジェクト固有ペルソナ（任意）
│   └── rules/                  # ドメイン固有ルール（従来通り）
├── CLAUDE.md
└── docs/harness-map.md         # ビジュアライザの出力（自動生成・コミット可）

/tmp/claude-harness/<project>/
├── <session_id>.json           # セッション状態（エンジンが管理）
└── harness.lock.json           # harness.yaml のコンパイル済み JSON キャッシュ
```

---

## スキーマ全体（注釈つきフル例）

classly を移植した場合の記述例。全セクションを含む。

```yaml
version: 0

project:
  name: classly                       # 状態ディレクトリのキー。必須
  # state_dir: /tmp/claude-harness    # 省略時デフォルト

# ============================================================
# setup — SessionStart で実行される環境準備
# （現行 session-start.sh の一般化）
# ============================================================
setup:
  require_tools: [jq, yq, gh]         # 欠如時に警告（エンジン自体は jq 必須）
  git_hooks_path: .claude/git-hooks   # git config core.hooksPath
  commands:
    - run: npm install --prefer-offline --silent
      if_exists: package.json
    - run: npx playwright install chromium
      if_exists: node_modules/.bin/playwright

# ============================================================
# paths — ファイル分類。ゲートの when: とガードの対象判定に使う
# （現行 set-impl-flag.sh / set-screen-flag.sh のパターンを宣言化）
# ============================================================
paths:
  impl:
    include: ["src/**/*.ts", "src/**/*.tsx", "apps/solver-api/**/*.py"]
    exclude:
      - "**/*.{test,spec,stories}.{ts,tsx}"
      - "**/{vitest,playwright,tailwind,next,postcss}.config.*"
      - "**/{test_*,*_test,conftest}.py"
  screen:
    include: ["src/app/**/*.tsx", "src/components/classly/**/*.tsx"]
    exclude: ["**/*.{test,spec,stories}.tsx"]
  test:
    include: ["**/*.{test,spec}.{ts,tsx}", "**/test_*.py", "e2e/**"]
  exempt:                              # チケットガードの対象外
    include: [".claude/**", "docs/**", "*.md", "/tmp/**"]

# ============================================================
# tickets — チケットアダプタ
# （現行 pre-edit-issue-guard.sh / pre-commit-check.sh のブランチ検証を吸収）
# ============================================================
tickets:
  provider: github-issues              # github-issues | github-projects | none
  branch_format: "{type}/{n}-{slug}"   # type ∈ feat|fix|refactor|chore|docs
  protected_branches: [main, master]
  allow_branch_prefixes: [claude/]     # リモートセッション用の例外
  escape_env: SKIP_ISSUE_CHECK         # 緊急脱出ハッチ（env=1 で警告のみ）
  exempt: [exempt, test]               # paths のクラス名参照。テストは RED 先行可

# ============================================================
# ci — CIアダプタ。イベント別のコマンド宣言
# （現行 post-edit-lint.sh / pre-commit-check.sh のコマンドを吸収）
# ============================================================
ci:
  on_edit:                             # PostToolUse。非ブロック（警告のみ）
    - paths: ["**/*.{ts,tsx}"]
      run: "npx eslint {file}"
    - paths: ["apps/solver-api/**/*.py"]
      run: "cd apps/solver-api && uv run ruff check {relfile}"
      relative_to: apps/solver-api
  on_commit:                           # PreToolUse(git commit)。ブロッキング
    - run: "npm run test:coverage"
      coverage_min: 80
    - run: "npx tsc --noEmit"
    - when_staged: ["apps/solver-api/**"]   # 該当パスが staged のときのみ
      run: "cd apps/solver-api && uv run ruff check . && uv run pytest --cov -q"
      coverage_min: 90

# ============================================================
# guards — 編集時の予防的ガード
# （現行 pre-edit-reuse-guard.sh の探索先を宣言化。非ブロック）
# ============================================================
guards:
  reuse:                               # 新規ファイル作成時に既存資産を提示
    - on_create: "src/components/classly/*/*.tsx"
      inventory: "ls src/components/classly"
    - on_create: "apps/solver-api/solver/*.py"
      inventory: "grep -l '^def ' apps/solver-api/solver/*.py"

# ============================================================
# personas — レビューペルソナ。独立コンテキストのサブエージェントに写像
# 汎用エージェント定義はプラグイン側（harness: 名前空間）、
# プロジェクト知識は context: のファイル差し込みで吸収する
# ============================================================
personas:
  architect:
    agent: harness:architect-reviewer
    context: [CLAUDE.md, docs/data-architecture.md]
  qa:
    agent: harness:qa-reviewer
    context: [CLAUDE.md, src/test/POLICY.md]
  po:
    agent: harness:po-reviewer
    context: [docs/product-context.md, docs/mvp-draft.md]
  security:
    agent: harness:security-reviewer
    model: opus                        # ペルソナ単位でモデル指定可
  # プロジェクト固有ペルソナは .claude/agents/ に置き agent: <name> で参照

# ============================================================
# workflows — 名前つきワークフロー（複数定義可）
# ============================================================
workflows:

  implement:                           # 通常実装フロー
    default: true
    description: issue 駆動の実装。TDD とレビューゲートを強制
    permissions: edit                  # edit | read-only
    entry:                             # /flow implement <n> 宣言時に要求
      require_ticket: true             # tickets アダプタ経由で issue 確認
      gates:
        - skill: tdd                   # 着手時ゲート（RED 先行の確認）
    gates:                             # Stop フックが上から順に要求する
      - skill: refactor
        when: impl                     # paths クラス参照。該当変更時のみ
      - skill: classly-review          # ← プロジェクトのレビュースキル名を直接指定
        when: impl
      - skill: review-board            # ペルソナレビュー（プラグイン同梱の汎用ゲート）
        when: impl
        personas: [qa, po]
        min_diff_lines: 30             # 小差分ではスキップ（コスト制御）
      - skill: design-check
        when: screen
      - skill: uiux-check
        when: screen
        optional: true                 # 要求はするがスキップ宣言で通過可

  investigate:                         # 調査フロー。成果物はレポート
    description: コードを変更しない調査・分析
    permissions: read-only             # PreToolUse ガードが Edit/Write を拒否
    gates:
      - skill: report
        output: "docs/research/{date}-{slug}.md"

  pr-review:                           # PR レビュー専用フロー
    description: 指定 PR をペルソナ観点でレビューしコメントする
    permissions: read-only
    inputs: [pr_number]                # /flow pr-review 123 の引数
    gates:
      - skill: review-board
        target: pr                     # diff の取得元を PR にする
        personas: [architect, qa, security]
      - skill: review-summary          # 指摘の集約とコメント投稿

# ============================================================
# visualizer — 読み取り専用ビジュアライザ
# /harness-map スキルが harness.yaml とセッション状態から生成する
# ============================================================
visualizer:
  output: docs/harness-map.md          # mermaid 埋め込み markdown
  html: docs/harness-map.html          # 任意。単一 HTML（依存なし）も出力
  include_sessions: true               # 稼働中セッションのゲート進行を表示
```

---

## セッション状態ファイル

エンジン（フック群）が `{state_dir}/{project}/{session_id}.json` に保持する。
session_id は全フックイベントの stdin JSON から取得する。

```json
{
  "schema": 0,
  "session_id": "sess_...",
  "workflow": "implement",
  "ticket": "#342",
  "started_at": "2026-07-05T10:00:00+09:00",
  "dirty": { "impl": true, "screen": false },
  "gates": {
    "refactor":       { "status": "passed",  "at": "..." },
    "classly-review": { "status": "pending" }
  },
  "pending_token": {
    "gate": "classly-review",
    "token": "a3f9c1…",
    "issued_at": "..."
  }
}
```

### ゲート通過のノンスプロトコル

1. **Stop フック**（session_id を知っている）が未通過ゲートを検出すると、
   ワンタイムトークンを `pending_token` に記録し、block 理由に
   「完了後に `mark-gate-passed classly-review <token>` を実行せよ」とトークンを埋め込む
2. Claude がゲートスキルを完了し、指示どおりコマンドを実行 →
   `mark-gate-passed` がマーカー `{state_dir}/{project}/{session_id}.mark` にトークンを書く
3. 次の Stop フックがトークン一致を検証して初めて `status: passed` に更新し、次のゲートを要求する

これにより **(a) `touch` による偽装、(b) 他セッションのマーカー混入** の両方が同じ仕組みで無効化される。
`settings.json` の deny（`touch` 系の禁止）は第二防衛線として維持する。

### ライフサイクル

- SessionStart: `harness.yaml` を `harness.lock.json` にコンパイル（yq 使用）、状態ファイル初期化、24h 超の残骸 GC
- `/flow <workflow> [args]`: workflow と ticket を状態に記録。未宣言のまま impl 編集 → PreToolUse がブロックし宣言を促す
- SessionEnd: 自セッションの状態ファイルを削除

---

## 契約（コントラクト）

### ゲートスキル契約

ゲートに載せるスキルが守ること：

1. frontmatter に `name` / `description` を持つ（従来どおり）
2. 完了条件を満たしたら、block メッセージ内のトークンを使って
   `mark-gate-passed <gate> <token>` を実行して終わる
3. `optional: true` のゲートは `mark-gate-passed <gate> <token> --skip "<理由>"` でスキップ通過できる（理由は状態に記録）

この契約さえ守れば、プロジェクト固有スキル（classly-review）も汎用スキル（qa-review）も同列にゲートへ差し込める。

### ペルソナエージェント契約

`review-board` ゲートが起動するサブエージェントが守ること：

1. 入力: 対象 diff（ブランチ diff または PR diff）+ `context:` で指定された資料パス。
   **ペルソナは会話コンテキストを見ていない**ため、必要な情報はすべて明示的に渡される
2. 出力: findings のリスト（severity / file / line / summary / suggestion）を所定フォーマットで返す
3. `review-board` は全ペルソナを並列起動 → 重複除去 → severity 順に集約 →
   各指摘への対応（修正 or 見送り理由）が記録されてからゲート通過

---

## 現行資産 → スキーマ対応の検証表

| 現行資産（4リポジトリ） | スキーマでの表現 | 備考 |
|---|---|---|
| classly `set-impl-flag.sh` の判定パターン | `paths.impl` | TS/Python の exclude 込みで表現可 |
| classly `set-screen-flag.sh` | `paths.screen` | |
| classly `post-edit-lint.sh`（eslint / ruff） | `ci.on_edit` | `{file}` `{relfile}` プレースホルダ |
| classly `pre-commit-check.sh`（テスト・カバレッジ・ブランチ検証） | `ci.on_commit` + `tickets.branch_format` | solver-api の 90% は `when_staged` + `coverage_min` |
| classly `pre-edit-issue-guard.sh`（除外パス・マーカー） | `workflows.*.entry.require_ticket` + `tickets.exempt` | マーカーはセッション状態に統合 |
| classly `pre-edit-reuse-guard.sh` | `guards.reuse` | |
| classly `session-start.sh`（jq/gh 確認・npm install・hooksPath・playwright） | `setup` | |
| classly/pokotto `auto-*-review.sh` 群 + フラグファイル | `workflows.implement.gates` + セッション状態 | フック N 本 → シーケンサー1本 |
| classly/pokotto `mark-review-passed.sh`（REVIEWED: 検証） | `mark-gate-passed` + ノンス | セッション分離を追加して強化 |
| pokotto `mark-review-passed.sh` の deny 保護 | settings.json に残置（第二防衛線） | プラグインは permissions を配布できない |
| ehon-note（旧世代・ゲート少なめ） | 同スキーマで `gates` を減らすだけ | 世代差はスキーマの差分として可視化される |
| booktalk-ai の agents（code-reviewer 等） | `personas` + プラグイン同梱エージェント | プロジェクト知識は `context:` で注入 |
| booktalk-ai `strategic-compact` / `memory-persistence` | **v0 対象外** | エンジンのオプション機能として v1 で検討 |
| classly `pre-compact-backup.sh` | **v0 対象外**（プラグインの固定機能として同梱） | 設定不要のため schema に載せない |
| booktalk-ai のドキュメント連動更新ルール | **v0 対象外** | rules/CLAUDE.md の領分。schema に載せない |

---

## ビジュアライザ仕様（読み取り専用）

`/harness-map` スキル（プラグイン同梱）が生成する。**書き込み経路は増やさない**。

入力: `harness.lock.json` + `{state_dir}/{project}/*.json`（稼働中セッション状態）

出力1 — `docs/harness-map.md`（コミット可能な静的ビュー）:
- ワークフローごとのゲートフロー図（mermaid flowchart）
- ペルソナ一覧（agent / model / context）
- paths / tickets / ci の設定サマリテーブル
- classly の `docs/dev-workflow.md` に手描きしていた図の自動生成版に相当

出力2 — `docs/harness-map.html`（任意・依存なし単一ファイル）:
- 上記に加え、**稼働中セッションのゲート進行状況**（どのセッションがどのフローの何番目か）
- 並走運用時のダッシュボードとして機能

---

## 未決事項（Open Questions）

| # | 論点 | 現時点の仮置き |
|---|---|---|
| 1 | ゲート順序は厳密シーケンスか集合か | v0 は宣言順の厳密シーケンス。並列許可は v1 で `group:` を検討 |
| 2 | YAML パーサ依存（フックは bash+jq） | SessionStart で yq により lock.json へコンパイル。yq 欠如は FATAL |
| 3 | 1セッション複数ワークフローの切替 | `/flow` の再宣言で上書き可。ただし未通過ゲートがある場合は警告 |
| 4 | `permissions: read-only` の強制範囲 | Edit/Write/NotebookEdit をブロック。Bash 経由の書き込みは v0 では防がない（deny 併用を推奨） |
| 5 | tickets provider の拡張（Linear/Jira） | provider をアダプタスクリプトの選択子にする。v0 は github-issues / github-projects / none のみ |
| 6 | takt 連携 | harness.yaml → takt YAML の変換は v1 以降。一次ソースは本スキーマ |
| 7 | JSON Schema の提供 | v0 スキーマ確定と同時に `schemas/harness.schema.json` を同梱し yaml-language-server で補完・検証 |
| 8 | プラグイン名・マーケットプレイス配置 | 仮称 `claude-harness`。マーケットプレイスはこのリポジトリを転用するか新設するか未定 |
| 9 | ゲート完了の検証強度 | v0.4.0 で `gates[].verify` を追加。未設定ならトークンのみの自己申告（弱）、設定すればエンジンが exit code で機械検証（強）。デフォルトは自己申告のまま（後方互換優先）。将来 review 系ゲートは `verify` 必須にするか検討 |
| 10 | `${CLAUDE_PLUGIN_ROOT}` が eval される任意コマンド内で実環境変数として使えるか | 未検証（プラグイン実地インストールが未実施のため）。安全側に倒し、harness.yaml の `run:`/`verify:`/`inventory:` 用にエンジン自身が `HARNESS_PLUGIN_ROOT` を export して代替。実地検証（論点 issue に別記の hooks.json 実セッション検証）で解消され次第、統合を再検討 |
| 11 | 進捗ログ（`.claude-harness/progress.log`）のローテーション | v0.5.0 は追記のみでローテーション・上限なし。長期運用でファイルが肥大化する懸念があるため、将来的に世代ローテーションかサイズ上限を検討 |
| 12 | `gates[].agent` の粒度（単一 vs 複数） | v0.5.0 は単一ペルソナのみ（`personas:` マップの1エントリ参照）。review-board の `personas:`（複数・パネル形式）とは別軸。将来「任意ゲートを複数ペルソナで独立実行」を統合するか検討 |
| 13 | Planner が立てた計画のレビュー（Sprint contracts の完全形） | v0.6.0 は「計画が存在し最低限の分量があるか」のみ機械検証。Anthropic 記事の Evaluator は計画内容そのものをレビューしてから実装着手を許可するが、これは `entry.gates` に `plan` → `plan-review`（別ペルソナによる計画レビュー）の2段構成にすれば表現可能（現状の機構だけで実現できるが、デフォルト構成には未採用。コスト増とのトレードオフのため必要になったら追加） |
| 14 | Planner の計画とその後の実装の追従確認 | v0.6.0 は計画を立てさせるだけで、実装がその計画通りに進んでいるかを機械チェックする仕組みはない（review-board 等の後続ゲートが実質的な代替になっているが、計画の「スコープ外」逸脱を直接検出する仕組みではない） |
