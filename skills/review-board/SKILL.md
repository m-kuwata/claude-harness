---
name: review-board
description: 複数のレビューペルソナ（QA・PO・アーキテクト・セキュリティ等）を独立コンテキストのサブエージェントとして並列起動し、findings を集約して対応するレビューゲート。harness のゲート要求で review-board が指定されたとき、または PR・差分の多観点レビューを求められたときに使う。
---

# /review-board — ペルソナ並列レビュー

## 手順

### 1. 準備スクリプトを実行

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/review-board-prep.sh          # ブランチ diff
bash ${CLAUDE_PLUGIN_ROOT}/scripts/review-board-prep.sh --pr 42  # PR diff
bash ${CLAUDE_PLUGIN_ROOT}/scripts/review-board-prep.sh --personas qa,po  # ペルソナ指定
```

出力 JSON に「起動すべきペルソナ（agent 名・context 資料パス）」と「diff ファイルパス」が入る。
ゲートとして呼ばれた場合はペルソナ一覧が自動で解決される（harness.yaml の gate 定義から）。

### 2. ペルソナを並列起動

**全ペルソナを1つのメッセージで同時に** Agent ツールで起動する（直列起動しない）。
各ペルソナへのプロンプトは次のテンプレートに従う:

```
あなたは <persona> レビュアーとして diff をレビューします。

## 対象 diff
<diff_file の内容。3000 行を超える場合はファイルパスを渡して Read させる>

## コンテキスト資料（必ず先に読むこと）
<def.context の各ファイルパス>

## プロジェクトルート
<root>

エージェント定義の「出力契約」に従い、findings を JSON で報告してください。
```

- `subagent_type` は `def.agent` の値（`harness:` プレフィックスは付いていればプラグインの agents/ を指す）
- `def.model` があれば `model` に指定する
- ペルソナは会話を見ていない。**必要な情報はすべてプロンプトに含める**

### 3. findings の集約

全ペルソナの JSON を回収し:

1. 同一ファイル・同一趣旨の指摘をマージ（指摘したペルソナ名は併記）
2. severity 順（P0 → P3）に並べる
3. 集約表をユーザー向けに報告する

### 4. 対応

- **P0 / P1**: 修正する（現在のフローが read-only の場合は修正せず報告のみ）
- **P2 / P3**: 対応するか、見送り理由を明記する
- ペルソナが「ユーザー確認が必要」とした事項は AskUserQuestion で確認する

### 5. ゲート通過の記録

ゲートとして呼ばれた場合のみ、全 P0/P1 の対応完了後に
block メッセージに記載されたトークン付きコマンドで記録する:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/mark-gate-passed.sh review-board <token>
```

## してはいけないこと

- ペルソナを直列で起動する（時間の無駄）
- findings を握りつぶして通過記録する（P0/P1 は対応または明示的な見送り理由が必須）
- 自分（メインコンテキスト）でレビューを代行する（実装者バイアスの排除がこのゲートの目的）
