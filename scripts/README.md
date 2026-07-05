# scripts/ — 補助スクリプト

| ファイル | 役割 |
|---|---|
| mark-gate-passed.sh | トークン付きゲート通過記録。`--skip "<理由>"` で optional ゲートのスキップ通過 |

Stop フックが block 理由に埋め込んだワンタイムトークンを引数に取る。
トークンなしの記録・他セッションのトークンは stop-sequencer が拒否する。
