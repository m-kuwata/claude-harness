---
name: report
description: 調査・分析フロー（read-only ワークフロー）の成果物レポートを所定パスに書き出すゲートスキル。investigate 系フローで harness が report ゲートを要求したとき、コード変更を伴わない調査の結論をまとめるときに使う。
---

# /report — 調査レポート成果物

read-only ワークフローの終端ゲート。調査の結論を harness.yaml の `output:` で
宣言されたパス（例: `docs/research/{date}-{slug}.md`）に書き出す。

## 手順

1. harness のゲート要求メッセージ、または `harness.yaml` の investigate フローの
   `output:` パターンから出力先を確認する（`{date}` は当日、`{slug}` は調査対象の短い識別子）
2. 調査結果を次の構成でまとめる:

   ```markdown
   # <調査タイトル>

   - 日付 / 調査者 / 対象（issue やファイル範囲）

   ## 問い
   何を明らかにするための調査か

   ## 調べたこと
   確認した箇所（file:line で参照）・実行したコマンド・観測結果

   ## わかったこと
   結論。事実と推測を区別する

   ## 推奨アクション
   次に取るべき手（実装が必要なら別途 /flow implement で着手する）
   ```

3. 宣言パスに書き出す。read-only フローでも `output:` 宣言パスは書き込みが許可される
4. 成果物が存在すれば Stop シーケンサーがゲートを自動通過させる
   （トークン記録は不要。成果物の存在が通過条件）

## してはいけないこと

- 調査フロー中にコードを実装する（read-only ガードがブロックする。実装は /flow implement へ）
- 出力先を勝手に変える（harness.yaml の宣言に従う）
