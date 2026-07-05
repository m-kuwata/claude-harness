# agents/ — 汎用ペルソナ

独立コンテキストで動くレビューペルソナ。プロジェクト知識は持たせず、
harness.yaml の personas.<name>.context で資料を注入する。

| エージェント | 観点 |
|---|---|
| qa-reviewer | テストシナリオが実運用に沿っているか |
| po-reviewer | 実装がユーザーの運用ニーズと合っているか |
| architect-reviewer | 構造・依存方向・拡張性 |
| security-reviewer | 脆弱性・秘密情報・RLS/認可 |

出力はペルソナエージェント契約（findings: severity/file/line/summary/suggestion）に従う。
