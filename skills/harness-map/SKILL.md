---
name: harness-map
description: harness の設定（ワークフロー・ゲート・ペルソナ・CI/チケットアダプタ）と稼働中セッションのゲート進行状況を、読み取り専用の markdown ビジュアライザとして生成する。設定の全体像を確認したいとき、harness.yaml 変更後、並走セッションの進行を見たいときに使う。
---

# /harness-map — 読み取り専用ビジュアライザ

## 実行

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/harness-map.sh            # visualizer.output（デフォルト docs/harness-map.md）へ
bash ${CLAUDE_PLUGIN_ROOT}/scripts/harness-map.sh /tmp/map.md  # 出力先指定
```

## 内容

- ワークフローごとのゲートフロー図（mermaid）— entry / when / optional / ペルソナ / 成果物を注記
- ペルソナ一覧（agent / model / context 資料）
- 設定サマリ（チケット・CI・paths クラス）
- 稼働中セッションのゲート進行状況

## ルール

- 出力は**自動生成の読み取り専用ビュー**。手で編集しない（編集は harness.yaml 側で行い再生成する）
- デフォルト出力先（docs/ 配下）はコミットしてよい。セッション進行の節は実行時点のスナップショット
- 生成後、ユーザーに見せる場合はファイルをそのまま提示する
