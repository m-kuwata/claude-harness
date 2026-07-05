---
name: config-audit
description: harness 設定（harness.yaml・lock・ゲート参照スキル・ペルソナ定義・settings.json）の健全性を監査する。harness.yaml 変更後、プラグイン更新後、月次の定期チェック、ゲートが期待通り動かないときに使う。
---

# /config-audit — harness 設定監査

## 実行

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/harness-audit.sh
```

終了コード: `1` = FATAL あり（エンジンが正しく動作しない）/ `0` = FATAL なし。

## チェック内容

| # | 内容 | 重大度 |
|---|---|---|
| 0 | エンジン依存（jq / python3 / YAML パーサ） | FATAL |
| 1 | harness.yaml の存在とコンパイル成功 | FATAL |
| 2 | plugin バージョンと lock の engine_version 整合 | WARN |
| 3 | ゲートが参照するスキルの存在（プロジェクト or プラグイン） | WARN |
| 4 | ペルソナの agent 定義・context 資料の存在 | WARN |
| 5 | settings.json の valid JSON・状態ディレクトリ保護 deny | FATAL / WARN |

## 修正の指針

- FATAL は必ず解消する。WARN は内容を確認し、修正するか許容理由をユーザーに報告する
- スキル欠落（#3）: ゲート名の typo か、プロジェクト固有スキルの未作成。harness.yaml 側を直すのが先
- deny 未設定（#5）: `.claude/settings.json` の `permissions.deny` に
  `"Write(/tmp/claude-harness/**)"` と `"Edit(/tmp/claude-harness/**)"` を追加する
