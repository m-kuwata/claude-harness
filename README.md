# claude-harness

Claude Code のハーネスエンジニアリングをフレームワーク化したプラグイン。
宣言的な設定ファイル `.claude/harness.yaml` 1枚で、プロジェクトごとに異なる
CI・チケット管理・レビュー体制を吸収しながら、共通のワークフローエンジンを配布する。

## 解決する問題

複数プロジェクトでハーネス（CLAUDE.md / skills / hooks / settings）をコピペ運用すると、
プロジェクト間で世代ドリフトが起きる。改良が他プロジェクトに還流せず、
どのプロジェクトが第何世代かも分からなくなる。

このリポジトリはハーネスの**エンジン部分を1箇所に集約**し、プラグインとして
バージョン付きで配布する。プロジェクト側に残るのは設定（harness.yaml）と
ドメイン知識（CLAUDE.md / rules / 固有スキル）だけ。

## 5層モデル

| 層 | 内容 | 置き場所 |
|---|---|---|
| Context | CLAUDE.md・docs・rules（ドメイン知識） | 各プロジェクト |
| Knowledge | スキル（判断基準・手順書） | プラグイン（汎用）+ プロジェクト（固有） |
| Enforcement | フックによる構造的強制（ゲート・ガード） | **プラグイン（本リポジトリ）** |
| Automation | サブエージェント（ペルソナレビュー等） | プラグイン（汎用）+ プロジェクト（固有） |
| Audit | config-audit・ビジュアライザ | プラグイン |

## 中核コンセプト

- **複数ワークフロー**: implement / investigate / pr-review を名前つきで宣言し、
  セッションごとに `/flow <name>` で有効化。フローごとに編集権限とゲート列が変わる
- **ゲートシーケンサー**: Stop フック1本が harness.yaml のゲート列を順に要求。
  通過記録はセッション単位のノンス（ワンタイムトークン）でのみ有効 —
  改ざん防止と複数セッション並走時の競合防止を同じ仕組みで実現。
  同一ゲートが規定回数（デフォルト5回・`HARNESS_MAX_GATE_BLOCKS`）連続でブロックされ
  進捗がない場合はサーキットブレーカーが解放し、無限ループを構造的に防ぐ
- **検証可能なアウトプットの強制**（`gates[].verify`）: トークンによる完了申告は
  デフォルトでは自己申告（「やった」と言えば通る）に過ぎない。`verify:` に
  シェルコマンドを書くと、エンジンがそれを実行して exit 0 を確認できて初めて
  通過を受理する（非0なら同じトークンで再ブロック。サーキットブレーカーの
  連続ブロック回数カウンタも継続し、無限リトライを許さない）
- **ペルソナレビュー / 任意ゲートの独立コンテキスト実行**: レビュー観点
  （QA / PO / アーキテクト / セキュリティ）を独立コンテキストのサブエージェントとして
  並列起動する review-board（`personas:`）に加え、**任意のゲートを1エージェントで
  独立実行**できる `gates[].agent`（`personas:` マップの単一参照）も v0.5.0 で追加。
  refactor・tdd 等も yaml 1行で「実装者の会話から隔離して実行」に切り替えられる
  （`/gate-run` 経由。未設定ならメインコンテキストで直接実行する後方互換動作）
- **セッション/ゲートスコープのアーティファクト**: `verify:`/`output:` に書ける
  `{session_id}` プレースホルダをエンジンが実セッションIDに置換してから評価する。
  固定パスのまま書くと複数セッション同時実行でレビュー結果等が衝突するため、
  `gate_artifact_path()` が `.claude-harness/<session_id>/<gate名>/...` の形で
  セッション+ゲート名スコープのパスを一元発行する
- **永続進捗ログ**（`.claude-harness/progress.log`, JSONL・追記専用）:
  Anthropic の `claude-progress.txt` 相当。セッション状態（`/tmp` 配下）は
  SessionEnd で消えるが、workflow 宣言・ゲート通過/スキップ/検証失敗/
  ブレーカー解放は全てこのログに残り、長時間・複数セッションにわたるループの
  進捗を `/harness-map` の「最近の進捗」セクションで追跡できる
- **アダプタ**: チケット置き場（GitHub Issues / Projects / なし）と
  CI コマンド・カバレッジ閾値を設定で吸収
- **Just-in-time 注入**: スキーマの読者は Claude ではなくエンジン。
  Claude へはフック出力経由で「次の一手」だけが注入される

## 設計ドキュメント

1. [`docs/schema-v0.md`](docs/schema-v0.md) — harness.yaml スキーマ草案（注釈つきフル例・検証表・未決事項）
2. [`docs/runtime-v0.md`](docs/runtime-v0.md) — ランタイム設計（データフロー・ウォークスルー・導入フロー・v0 実装スコープ）

## リポジトリ構成（プラグインレイアウト）

```
claude-harness/
├── .claude-plugin/
│   ├── plugin.json          # プラグインマニフェスト
│   └── marketplace.json     # このリポジトリ自身をマーケットプレイスにする
├── hooks/                   # エンジン: ディスパッチャフック（5本）
├── scripts/                 # mark-gate-passed 等の補助スクリプト
├── skills/                  # /flow, /review-board, /gate-run, /harness-map, /harness-init, /config-audit, /report
├── agents/                  # 汎用ペルソナ（qa / po / architect / security）
├── schemas/                 # harness.schema.json（エディタ補完・検証用）
└── docs/                    # 設計ドキュメント
```

## 導入（予定）

```bash
# マーケットプレイス追加 → プラグインインストール
/plugin marketplace add m-kuwata/claude-harness
/plugin install claude-harness@m-kuwata

# プロジェクト初期化（対話ウィザードが harness.yaml を生成）
/harness-init
```

## ステータス

**エンジン + 全スキル実装済み（v0.5.0）**。E2E スモークテスト 82 件通過（`bash tests/run.sh`）。pokotto-box / classly / ehon-note でパイロット導入済み。

**v0.5.0 での追加**（長時間ループ運用のための拡張）:
- `gates[].agent`: review-board 専用だった「独立コンテキスト実行」を任意のゲートに
  一般化。yaml で `agent: <personas内の名前>` を1行足すだけで、そのゲートは
  `/gate-run` を通じて独立コンテキストのサブエージェントとして実行される
  （新スキル `/gate-run` + `scripts/gate-run-prep.sh`）
- `{session_id}` プレースホルダ: `verify:`/`output:` に書くと実セッションIDに
  置換される。複数セッション同時実行時のアーティファクト衝突を防ぐため、
  review-board 等のアーティファクトパスは `gate_artifact_path()` で
  セッション+ゲート名スコープに統一（固定パス運用は廃止）
- `.claude-harness/progress.log`（JSONL・追記専用の永続進捗ログ）:
  `/tmp` 配下のセッション状態は SessionEnd で消えるため、workflow 宣言・
  ゲート通過/スキップ/検証失敗/ブレーカー解放を全てこのログに記録し、
  `/harness-map` で長時間・複数セッションの進捗を追跡できるようにした

**v0.4.0 での追加**: ゲートの完了条件に `verify:`（検証コマンド）を追加。
これまでは `mark-gate-passed` の実行＝トークン一致だけで通過を受理する
**自己申告**だった。`verify:` を設定すると、エンジンがそのコマンドを
プロジェクトルートで実行し exit 0 を確認できて初めて通過を受理する
（失敗時は同じトークンで再提出でき、サーキットブレーカーのカウンタも継続する）。
未設定のゲートは引き続き自己申告のまま（後方互換）。

**v0.3.0 での修正**: ユーザースコープ（`~/.claude/settings.json`）でインストールした場合、
セッションの起動ディレクトリ（`cwd`）が複数リポジトリの親ディレクトリになるケース
（例: `~/projects/` から起動し、配下の複数リポジトリを同一セッションで横断する）で、
プロジェクトルート解決が cwd に依存していたためエンジンが一切発火しない回帰バグを修正。
現在はルート解決を編集対象ファイル自身の場所ベースに変更し、セッションが実際に触れた
全プロジェクトを registry で追跡する。あわせて `guards.reuse` / `ci.on_edit` /
`ci.on_commit.when_staged` が POSIX 非互換の `grep -E` に依存していた箇所を
jq(Oniguruma) ベースの照合に統一（`(?:...)` 構文は GNU grep 依存で移植性がなかった）。

### エンジンの依存

- 必須: `bash` / `jq` / `python3`
- YAML パーサ（いずれか1つ）: `PyYAML`（優先）/ `yq`（mikefarah 版・kislyuk 版の両構文に対応）

### ロードマップ

- [x] スキーマ v0 草案（4プロジェクトの現行資産との対応検証済み）
- [x] ランタイム設計 v0
- [x] エンジン実装（ディスパッチャフック5本 + mark-gate-passed + flow-start）
- [x] スキル6本（/flow・/harness-init・/review-board・/harness-map・/config-audit・/report）
- [x] 汎用ペルソナ agents（qa / po / architect / security）
- [x] harness.schema.json（yaml-language-server 用）
- [x] E2E スモークテスト（tests/run.sh・82 件）
- [x] パイロット移行: pokotto-box / classly / ehon-note
- [x] ゲート完了の検証強化（gates[].verify・review-board との統合）
- [x] 任意ゲートの独立コンテキスト実行（gates[].agent・/gate-run）
- [x] セッション/ゲートスコープのアーティファクト（{session_id} 置換・衝突防止）
- [x] 永続進捗ログ（.claude-harness/progress.log・長時間ループの可視化）
- [ ] hooks.json のプラグイン実地検証（実セッションでのフック発火。
      `${CLAUDE_PLUGIN_ROOT}` が eval 文脈で実環境変数として使えるかも
      この検証で確定させる）

> takt 連携は不採用とした。ワークフロー定義・順序保証・並列レビューはネイティブ機構で
> 充足しており、無人バッチ実行の需要が生じた場合のみ lock.json からのエクスポータを検討する。

## 出自

classly / pokotto-box / ehon-note / booktalk-ai の4プロジェクトで試行錯誤した
ハーネス（レビューゲート・TDD ガード・issue 駆動ガード・ペルソナエージェント）の統合。
