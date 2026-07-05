---
name: harness-init
description: プロジェクトに harness を導入する初期設定ウィザード。プロジェクトを調査し、対話で harness.yaml を生成し、settings.json に第二防衛線の deny を注入し、監査で検証する。新規プロジェクトへの harness 導入時、既存フック構成からの移行時に使う。
---

# /harness-init — 導入ウィザード

## 手順

### 0. 既導入チェック（最初に必ず行う）

`.claude/harness.yaml` が**既に存在する場合、絶対にゼロから作り直さない**。
既存の内容を読み、ユーザーの要望を差分編集として適用する
（既存のカスタマイズはプロジェクト固有の資産であり、ウィザードの雛形より優先する）。

### 1. プロジェクト調査（質問の前に必ず行う）

推測できることをユーザーに聞かない。以下を調べて回答案を作る:

- `package.json` / `pyproject.toml` → test / lint / typecheck コマンド、カバレッジ設定
- `.claude/skills/` → 既存レビュースキル（ゲート候補）
- `.claude/hooks/` + `.claude/settings.json` → 旧世代フックの有無（移行対象）
- `CLAUDE.md` → チケット運用（issue 駆動か）、ブランチ規約、カバレッジ閾値
- `src/` 構成 → impl / screen / test の glob 候補
- `docs/` → ペルソナ context に渡せる資料（product-context / architecture / テストポリシー）

### 2. ユーザーへの確認（AskUserQuestion）

調査で決まらないことだけを聞く。典型的には:

1. **チケット管理**: github-issues / github-projects / none
2. **ワークフロー構成**: implement + investigate + pr-review の標準3点でよいか
3. **レビューゲート**: どのスキル・ペルソナを implement のゲートに載せるか
4. **旧フックの扱い**: 既存 `.claude/hooks/` を無効化するか並走させるか

### 3. harness.yaml 生成

`${CLAUDE_PLUGIN_ROOT}/docs/harness.example.yaml` を雛形に `.claude/harness.yaml` を書く。
スキーマ: `${CLAUDE_PLUGIN_ROOT}/docs/schema-v0.md` / `${CLAUDE_PLUGIN_ROOT}/schemas/harness.schema.json`

エディタ補完のため、ファイル先頭に次の1行を入れる:

```yaml
# yaml-language-server: $schema=<プラグインの schemas/harness.schema.json への相対パスまたは URL>
```

### 4. settings.json への deny 注入（第二防衛線）

`.claude/settings.json` の `permissions.deny` に追記（なければ作成）:

```json
"Write(/tmp/claude-harness/**)",
"Edit(/tmp/claude-harness/**)"
```

既存の設定を壊さないこと。編集前に必ず現在の内容を読む。

### 5. 検証

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/harness-audit.sh   # FATAL=0 まで修正
bash ${CLAUDE_PLUGIN_ROOT}/scripts/harness-map.sh     # ビジュアライザ生成
```

生成された harness-map.md をユーザーに見せ、ワークフロー・ゲート構成が意図通りか確認してもらう。

### 6. 移行時の後始末（旧フックがある場合）

ユーザーが「無効化」を選んだ場合のみ:
- `settings.json` の hooks セクションから旧フック登録を外す（ファイル自体は残す）
- CLAUDE.md のスキル・フロー説明セクションを「/flow で宣言。詳細は docs/harness-map.md」に置き換え、
  ドメイン知識（確定方針・設計・rules）だけを残す
