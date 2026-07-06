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

出力 JSON に「起動すべきペルソナ（agent 名・context 資料パス）」「diff ファイルパス」
「アーティファクト出力先 `artifact_path`（セッション+ゲート名でスコープ済み。
複数セッション同時実行でも衝突しない）」が入る。
ゲートとして呼ばれた場合はペルソナ一覧が自動で解決される（harness.yaml の gate 定義から）。

**`artifact_path` は固定パスではない**。`.claude-harness/<session_id>/review-board/findings.json`
の形でセッションごとに異なる。ステップ5で書き出す先は必ずこの値を使うこと
（`.claude-harness/review-findings.json` のような固定パスをここで決め打ちしない）。

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

### 5. 検証可能な成果物として書き出す（必須）

harness.yaml の review-board ゲートに `verify:` が設定されている場合、
**「対応した」という自己申告だけではゲートを通過できない**。エンジンが
機械的に確認できる成果物として、対応後の最終状態を
ステップ1で取得した `artifact_path`（セッションごとに異なるパス）に書き出す：

```json
{
  "personas": [
    { "name": "qa", "verdict": "approve", "findings": [] },
    { "name": "po", "verdict": "approve", "findings": [
        { "severity": "P2", "file": "...", "summary": "...", "resolution": "対応済み: ..." }
      ]
    }
  ],
  "all_approved": true
}
```

- `verdict` は各ペルソナの**最終**判定（P0/P1 に対応した後の再判定でも、
  対応内容をこのファイルに記録した上で `approve` として良い。ただし
  実際には対応していないのに `approve` と書くのは禁止）
- `all_approved` は全ペルソナが `approve` のときのみ `true`
- `artifact_path` のディレクトリがなければ作成する（`review-board-prep.sh` が
  既に作成済みのはず）

harness.yaml 側の設定例（`{session_id}` プレースホルダはエンジンが実セッションIDに
置換してから `verify:` を評価する。固定パスにすると複数セッション同時実行で
衝突するため必ず含めること）:

```yaml
- skill: review-board
  when: impl
  personas: [qa, po]
  verify: "bash ${HARNESS_PLUGIN_ROOT}/scripts/verify-approved.sh .claude-harness/{session_id}/review-board/findings.json"
```

（`verify:` はエンジンが `eval` するため `${HARNESS_PLUGIN_ROOT}` を使う。
`${CLAUDE_PLUGIN_ROOT}` はこのファイル自身のような Claude Code が直接解釈する
場所専用で、harness.yaml の verify/run コマンド内では使わないこと）

`verify:` が未設定のプロジェクトでは、このファイルを書かなくてもゲートは通過できる
（トークンのみの自己申告で足りる後方互換）。ただし新規導入時は `verify:` を設定し、
このファイルを書く運用を推奨する。

### 6. ゲート通過の記録

ゲートとして呼ばれた場合のみ、全 P0/P1 の対応完了後（`verify:` があれば
成果物ファイルの書き出し後）に block メッセージ記載のトークン付きコマンドで記録する:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/mark-gate-passed.sh review-board <token>
```

`verify:` が設定されている場合、エンジンがこのコマンド実行時ではなく
**次の Stop フック発火時に** `.claude-harness/review-findings.json` の
`all_approved` を確認する。条件を満たしていなければ通過は却下され、
検証コマンドの出力とともに再ブロックされる（同じトークンで再提出できる）。

## してはいけないこと

- ペルソナを直列で起動する（時間の無駄）
- findings を握りつぶして通過記録する（P0/P1 は対応または明示的な見送り理由が必須）
- 自分（メインコンテキスト）でレビューを代行する（実装者バイアスの排除がこのゲートの目的）
- `verify:` がある場合に、対応していないのに `review-findings.json` の
  `verdict`/`all_approved` を `approve`/`true` と偽って書く
  （エンジンはファイルの内容しか見ないため技術的には検出できないが、
  これは harness の前提を破る行為であり禁止）
