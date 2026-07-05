# skills/ — 汎用スキル

| スキル | 役割 |
|---|---|
| flow | ワークフロー宣言・チケット確認・ゲート計画の提示 |
| review-board | ペルソナ並列レビュー（サブエージェント起動・findings 集約） |
| harness-map | 読み取り専用ビジュアライザ生成（md + html） |
| harness-init | 初期設定ウィザード（harness.yaml 生成・deny 注入） |
| config-audit | 設定整合・エンジンバージョン乖離チェック |

プロジェクト固有スキル（例: classly-review）は各プロジェクトの .claude/skills/ に置き、
harness.yaml の gates から名前で参照する（ゲートスキル契約に従うこと）。
