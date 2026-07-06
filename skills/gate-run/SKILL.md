---
name: gate-run
description: harness.yaml でゲートに agent: が設定されている場合に、そのゲートのスキルを独立コンテキストのサブエージェントとして実行する。harness のゲート要求メッセージが「/gate-run <skill>」を案内したときに使う。agent: が設定されたゲートを /<skill> でメインコンテキストのまま直接実行してはいけない。
---

# /gate-run — 任意ゲートの独立コンテキスト実行

review-board 専用だった「独立コンテキストでの実行」を、harness.yaml で
`agent:` を設定すれば任意のゲート（refactor・tdd・design-check 等）にも
適用できるようにする汎用ゲートランナー。

## いつ使うか

harness のゲート要求メッセージに「`/gate-run <skill>`（独立コンテキストで実行）」
と書かれているとき。これは harness.yaml のそのゲートに `agent:` が設定されている
（`personas:` マップ内のペルソナ名を指す）ことを意味する。

## 手順

### 1. 準備

```bash
bash ${HARNESS_PLUGIN_ROOT}/scripts/gate-run-prep.sh <skill>
bash ${HARNESS_PLUGIN_ROOT}/scripts/gate-run-prep.sh <skill> --pr 42   # PR 対象の場合
```

出力 JSON:
- `persona` — agent/model/context（harness.yaml の `personas.<agent名>` 定義）
- `skill_md_path` — 元スキル（`/<skill>`）の指示内容ファイルパス
- `diff_file` — 対象 diff
- `artifact_path` — 結果の書き出し先（セッション+ゲート名でスコープ済み。
  他セッション・他ゲートと衝突しない）

### 2. サブエージェントを1体起動

```
あなたは harness ワークフローの "<skill>" ゲートを独立コンテキストで実行します。
実装者側の会話は見えていません。以下の指示・diff・資料だけを根拠に作業してください。

## このゲートで実行する指示（/<skill> の内容）
<skill_md_path の内容>

## 対象 diff
<diff_file の内容>

## コンテキスト資料
<persona.context の各ファイルパス>

## プロジェクトルート
<root>

作業内容（指摘・提案・実施した変更など）と最終結論を報告してください。
```

- `subagent_type` は `persona.agent` の値
- `persona.model` があれば `model` に指定する
- メインコンテキストの会話内容をプロンプトに含めない（バイアス排除がこの仕組みの目的）

### 3. 結果をアーティファクトに書き出す

サブエージェントの報告を `artifact_path` に書き出す。
そのゲートに `verify:` が設定されている場合は、`verify:` が期待する形式
（例: `{"all_approved": true, ...}`）に従うこと。`verify:` が未設定なら形式は自由。

### 4. ゲート通過の記録

```bash
bash ${HARNESS_PLUGIN_ROOT}/scripts/mark-gate-passed.sh <skill> <token>
```

`verify:` が設定されている場合、次の Stop フック発火時にエンジンが
`artifact_path` の内容を機械的に確認する。条件を満たしていなければ
検証コマンドの出力とともに再ブロックされる（同じトークンで再提出できる）。

## してはいけないこと

- `agent:` が設定されたゲートを `/gate-run` を介さず `/<skill>` としてメインコンテキストで直接実行する（独立性が失われる）
- サブエージェントの報告を都合よく書き換えてアーティファクトに記録する
