# harness ランタイム設計 v0 — スキーマをどう使うか

`docs/harness-schema-v0.md` の続編。harness.yaml を「誰が・いつ・どう読むか」を定義する。

## 基本思想: スキーマの読者は Claude ではなくエンジン

harness.yaml は Claude が常時読み込むコンテキストではない。読者は次の5者で、
Claude 本体には**フックの出力（deny 理由 / block 理由 / additionalContext）を通じて
「今やるべきこと」だけが just-in-time で注入される**。

| 読者 | 読むタイミング | 読む形式 |
|---|---|---|
| エンジン（ディスパッチャフック4本） | 全ツールイベント | harness.lock.json |
| スキル（/flow, review-board, harness-map, config-audit） | 呼び出し時 | harness.lock.json |
| Claude | `/flow` 宣言時にゲート計画の提示を受けるときのみ | スキル出力経由 |
| 人間 | 閲覧時 | ビジュアライザ出力 |
| ウィザード（/harness-init） | 初期設定時 | harness.yaml（生成側） |

この構造の利点はコンテキスト経済にある。現行の CLAUDE.md は「スキル一覧・フロー・
ゲートの説明」を常時コンテキストに載せているが、ランタイム化後はプロセス知識が
イベント駆動の注入に移るため、**CLAUDE.md はドメイン知識（確定方針・設計・ルール）だけに痩せる**。

## データフロー

```
harness.yaml（人間/ウィザードが編集）
    │  SessionStart: yq でコンパイル + スキーマ検証
    ▼
harness.lock.json（source_hash / engine_version 付き）
    ├── PreToolUse ディスパッチャ … flow宣言ガード / read-onlyガード / on_commit CI / reuseガード
    ├── PostToolUse ディスパッチャ … paths判定→dirtyフラグ / on_edit CI
    ├── Stop シーケンサー        … 有効ワークフローのゲートを順に要求（ノンス発行）
    ├── SessionEnd クリーンアップ
    └── スキル群 / ビジュアライザ
```

エンジンは**イベントごとに1本のディスパッチャ**。現行の17本のフックは、
lock.json の宣言を反復処理する4本に集約される。settings.json（またはプラグインの
hooks 定義）に登録するのはこの4本 + SessionStart だけ。

lock.json には `source_hash`（harness.yaml のハッシュ）を埋め込み、各ディスパッチャは
先頭で mtime/ハッシュを照合してズレていれば再コンパイルする（セッション中の
harness.yaml 編集に追従）。yq 欠如は SessionStart が FATAL として明示警告する
（黙ってゲートが無効化される fail-open は絶対に避ける）。

## セッションウォークスルー（implement）

1. **SessionStart**: コンパイル + 検証 → lock.json。24h 超の状態ファイル GC。`setup:` 実行
2. ユーザー「issue 342 を実装して」→ Claude が Edit を試行
   → **PreToolUse**: セッション状態にワークフロー未宣言 → deny:
   「`/flow implement 342` でフローを宣言してください。調査のみなら `/flow investigate`」
3. **`/flow implement 342`**: tickets アダプタで issue 実在を確認 → セッション状態に
   `{workflow, ticket}` を記録 → **このワークフローのゲート計画を Claude に提示**
   （Claude がスキーマ内容を知る唯一の正規経路。これで TDD や後続レビューを見越した計画が立つ）
   → entry ゲート（/tdd）を要求
4. 実装中: **PostToolUse** が編集ファイルを paths で分類し dirty フラグ更新、
   `ci.on_edit` の該当コマンド（eslint / ruff）を非ブロックで実行
5. Claude がターンを終えようとする → **Stop シーケンサー**: `dirty.impl` かつ
   refactor 未通過 → block + トークン発行:
   「/refactor を完了し `mark-gate-passed refactor <token>` を実行してください」
6. 以降ゲートを宣言順に消化。**review-board** では skill が lock.json から
   personas を読み、ブランチ diff + context 資料を添えて qa / po サブエージェントを
   並列起動 → findings 集約 → 対応記録 → mark-gate-passed
7. `git commit` → **PreToolUse** の on_commit: カバレッジ・型・ブランチ名検証（ブロッキング）
8. 全ゲート通過 → Stop が素通し → ターン正常終了。**SessionEnd** で状態ファイル削除

### investigate の場合

`/flow investigate` → `permissions: read-only` により PreToolUse が Edit/Write を deny。
ただし **`gates[].output` で宣言されたパスと `paths.exempt` は書き込み例外**とする
（レポート成果物が書けないと成立しないため）。Stop は report ゲートの成果物存在を確認して通過。

## Claude との対話プロトコル（エンジン → Claude）

エンジンが Claude に語りかけるチャネルは3つだけ。文言はすべてエンジン側が
lock.json から組み立てる（Claude の記憶に依存しない）。

| チャネル | 用途 | 例 |
|---|---|---|
| PreToolUse deny 理由 | 前提未充足の是正指示 | 「/flow を宣言してください」「read-only フローです」 |
| Stop block 理由 | 次ゲートの実行指示 + トークン | 「/qa-review 完了後 `mark-gate-passed qa-review a3f9…`」 |
| additionalContext | 非ブロックの参考情報 | reuse ガードの既存資産一覧、lint 警告 |

statusline 連携（現在のフロー・ゲート進行の常時表示）は同じ状態ファイルを読むだけで
実現できるため、v1 のオプションとする。

## 導入フロー（新規プロジェクト）

1. プラグインをインストール（マーケットプレイス経由）
2. **`/harness-init`**: 対話ウィザード（チケットはどこ？ / CI コマンドは？ /
   レビュースキルは？ / ペルソナは？）→ harness.yaml 生成
3. 同ウィザードが settings.json に deny ルール（第二防衛線）を注入し、検証を実行
4. `/harness-map` で初回ビジュアライザ生成 → 人間が構成を確認して調整

既存プロジェクトの移行は「現行フックを無効化 → harness.yaml を書く →
`/config-audit` で新旧の挙動差を確認」の順。config-audit は lock.json の
engine_version と自プロジェクトの想定バージョンの乖離検出も担う。

## v0 実装スコープ（最小エンジン）

| 種別 | ファイル | 役割 |
|---|---|---|
| hook | session-start.sh | コンパイル・検証・GC・setup |
| hook | pre-tool-dispatch.sh | flow宣言/read-only/on_commit/reuse の各ガード |
| hook | post-tool-dispatch.sh | dirty 判定 + on_edit CI |
| hook | stop-sequencer.sh | ゲート順序制御 + ノンス発行/検証 |
| hook | session-end.sh | 状態クリーンアップ |
| script | mark-gate-passed.sh | トークン付きゲート通過記録（--skip 対応） |
| skill | /flow | ワークフロー宣言・チケット確認・ゲート計画提示 |
| skill | /review-board | ペルソナ並列レビュー |
| skill | /harness-map | ビジュアライザ生成 |
| skill | /harness-init | 初期設定ウィザード |
| skill | /config-audit | 整合・バージョン乖離チェック（既存を拡張） |
| schema | harness.schema.json | エディタ補完・検証用 JSON Schema |
