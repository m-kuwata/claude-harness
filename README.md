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
  改ざん防止と複数セッション並走時の競合防止を同じ仕組みで実現
- **ペルソナレビュー**: レビュー観点（QA / PO / アーキテクト / セキュリティ）を
  独立コンテキストのサブエージェントとして並列起動。プロジェクト知識は
  harness.yaml の `context:` でファイル注入する
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
├── skills/                  # /flow, /review-board, /harness-map, /harness-init, /config-audit
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

**エンジン + 全スキル実装済み（v0.2.0）**。E2E スモークテスト 37 件通過（`bash tests/run.sh`）。pokotto-box / classly / ehon-note でパイロット導入済み。

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
- [x] E2E スモークテスト（tests/run.sh・37 件）
- [x] パイロット移行: pokotto-box / classly / ehon-note
- [ ] hooks.json のプラグイン実地検証（実セッションでのフック発火）

> takt 連携は不採用とした。ワークフロー定義・順序保証・並列レビューはネイティブ機構で
> 充足しており、無人バッチ実行の需要が生じた場合のみ lock.json からのエクスポータを検討する。

## 出自

classly / pokotto-box / ehon-note / booktalk-ai の4プロジェクトで試行錯誤した
ハーネス（レビューゲート・TDD ガード・issue 駆動ガード・ペルソナエージェント）の統合。
