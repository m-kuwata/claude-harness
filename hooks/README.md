# hooks/ — エンジン本体（ディスパッチャ）

イベントごとに1本。harness.lock.json を読んで宣言を反復処理する。

| ファイル | イベント | 役割 |
|---|---|---|
| session-start.sh | SessionStart | harness.yaml コンパイル・検証・状態GC・setup 実行 |
| pre-tool-dispatch.sh | PreToolUse | flow宣言ガード / read-onlyガード / on_commit CI / reuseガード |
| post-tool-dispatch.sh | PostToolUse | paths 判定→dirty フラグ / on_edit CI |
| stop-sequencer.sh | Stop | ゲート順序制御・ノンス発行/検証 |
| session-end.sh | SessionEnd | セッション状態クリーンアップ |

詳細: docs/runtime-v0.md
