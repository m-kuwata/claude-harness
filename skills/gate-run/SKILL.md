---
name: gate-run
description: harness.yaml でゲートに agent: が設定されている場合に、そのゲートを独立コンテキストのサブエージェントとして実行する。harness のゲート要求メッセージが「/gate-run <skill>」を案内したときに使う。レビュー系（diffベース）・計画系（チケットベース。plan 等）のどちらのゲートにも使える汎用の独立実行メカニズム。agent: が設定されたゲートを /<skill> でメインコンテキストのまま直接実行してはいけない。
---

# /gate-run — 任意ゲートの独立コンテキスト実行

review-board 専用だった「独立コンテキストでの実行」を一般化した、任意ゲート用の
汎用ランナー。harness.yaml で `agent:` を設定すれば、レビュー系ゲート
（refactor・design-check 等、diff を対象にする）にも、計画系ゲート
（plan 等、チケットを対象にし diff がまだ存在しない着手前の entry ゲート）にも
同じ仕組みで独立コンテキスト実行を適用できる。

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
- `skill_md_path` — 元スキル（`/<skill>`）の指示内容ファイルパス（空の場合は
  サブエージェント自身の agent 定義だけで完結する想定。例: planner）
- `diff_file` — 対象 diff（レビュー系ゲート向け。計画系では空のことがある）
- `ticket` / `ticket_body` — 宣言済みチケット番号と本文（計画系ゲート向け。
  レビュー系では空のことがある）
- `artifact_path` — 結果の書き出し先（セッション+ゲート名でスコープ済み。
  他セッション・他ゲートと衝突しない）

### 2. サブエージェントを1体起動

```
あなたは harness ワークフローの "<skill>" ゲートを独立コンテキストで実行します。
実装者側の会話は見えていません。以下の情報だけを根拠に作業してください。

## このゲートの追加指示（/<skill> の内容。ある場合のみ）
<skill_md_path の内容>

## 対象 diff（ある場合のみ）
<diff_file の内容>

## チケット（ある場合のみ）
<ticket_body>

## コンテキスト資料
<persona.context の各ファイルパス>

## プロジェクトルート
<root>

あなた自身のエージェント定義の出力契約に従って作業し、結論を報告してください。
```

- `subagent_type` は `persona.agent` の値
- `persona.model` があれば `model` に指定する
- メインコンテキストの会話内容をプロンプトに含めない（バイアス排除がこの仕組みの目的）
- `diff_file`/`ticket_body` は該当しない方を省略してよい（review-style のゲートに
  チケットは無関係、plan のような着手前ゲートに diff は存在しない）

### 3. 結果をアーティファクトに書き出す

サブエージェントの最終報告を **そのまま** `artifact_path` に書き出す
（内容を書き換えない）。そのゲートに `verify:` が設定されている場合は、
`verify:` が期待する形式に従うこと。`verify:` が未設定なら形式は自由。

### 4. ゲート通過の記録

```bash
bash ${HARNESS_PLUGIN_ROOT}/scripts/mark-gate-passed.sh <skill> <token>
```

`verify:` が設定されている場合、次の Stop フック発火時にエンジンが
`artifact_path` の内容を機械的に確認する。条件を満たしていなければ
検証コマンドの出力とともに再ブロックされる（同じトークンで再提出できる）。

## してはいけないこと

- `agent:` が設定されたゲートを `/gate-run` を介さず直接メインコンテキストで実行する
- サブエージェントの報告を都合よく書き換えてアーティファクトに記録する
- entry ゲート（例: plan）の場合、計画が通る前に実装ファイルを編集する
  （エンジンが構造的にブロックするが、それを回避しようとしない）
