# 正式な読みの通信形式 v1

この形式は、読み編集と候補計算を別の所有者へ分けるための追加 API です。既定の `SegmentsManager`、macOS、Desktop bridge の同期経路には接続していません。`CompositionCheckpoint` は context 内の取り消し専用のままで、通信には使いません。

`CompositionSnapshot.capture(_:registeredCustomTables:)` は `CompositionState` のコピーを採取します。`encoded()` と `CompositionSnapshot.decode(_:)` が JSON のサイズ制限を適用し、`restore(registeredCustomTables:)` は正式な `CompositionState` を復元します。失敗しても採取元の入力は変更しません。

```json
{
  "schemaVersion": 1,
  "input": [
    {
      "piece": {"kind": "key", "intention": null, "input": "t", "modifiers": []},
      "inputStyle": {"kind": "mapped", "table": {"kind": "defaultKanaJIS"}}
    },
    {
      "piece": {"kind": "key", "intention": "＠", "input": "@", "modifiers": []},
      "inputStyle": {"kind": "mapped", "table": {"kind": "defaultKanaJIS"}}
    }
  ],
  "convertTarget": "が",
  "convertTargetCursorPosition": 1,
  "lastInputStyle": {"kind": "mapped", "table": {"kind": "defaultKanaJIS"}},
  "conversionRangeEnd": null,
  "customInputTableRevisions": {}
}
```

`input` はその時点の正式な `ComposingText.input` で、打鍵履歴ではありません。途中編集によって frozen な `mapped/empty` 入力へ変化した場合も、その値を保ちます。カーソルと文節終端は Swift `Character` の個数です。UTF-16 offset や Unicode scalar offset は渡しません。文節終端は未指定、`null`、または `1...convertTarget.count`。カーソルは `0...convertTarget.count` です。

`piece` は次のいずれかです。

| kind | 値 |
| --- | --- |
| `character` | `value`: 一つの Character を表す文字列 |
| `compositionSeparator` | 追加の値なし |
| `key` | `input`: 一つの Character、`intention`: 一つの Character または null/未指定、`modifiers`: `[]` または `["shift"]` |

`inputStyle` は `{"kind":"direct"}`、`{"kind":"roman2kana"}`、または `{"kind":"mapped","table":...}`。`table.kind` は `defaultRomanToKana`、`defaultAZIK`、`defaultKanaJIS`、`defaultKanaUS`、`empty`、`tableName` のいずれかです。`tableName` だけは `name` を持ちます。未知の種別・修飾キー、重複した修飾キー、余分なフィールドは拒否します。

単独 wrapper の公開 API は `try InputPieceSnapshot(piece)` / `.piece`、`try InputStyleSnapshot(style)` / `.inputStyle` です。正式な型へ戻すだけで、候補の適用や表の登録を許可するものではありません。

カスタム表は `input` または `lastInputStyle` が参照する名前だけを `customInputTableRevisions` に含めます。revision は `CompositionSnapshot.customInputTableRevision(exportedTable:)` で算出する、表の export 文字列の UTF-8 に対する小文字 SHA-256 です。余分・欠落・不正な revision を拒否します。受信側は、実際に登録を終えた表の revision を `restore` に渡します。復元処理はネットワークやファイルから表を読み込みません。

上流の表 registry は process-global です。呼出側は登録と採取・復元を直列化し、登録済みの表と revision の対応を維持してください。同じ名前でも内容が異なる表を、古い revision のまま使うことは契約外です。復元時には revision 一致に加え、正式な input を現在の表で再計算し、`convertTarget` と UTF-8 が完全に一致することを確認します。正規化で同一視できる文字列でも、元の scalar 列が違えば拒否します。

実候補の消費範囲は、別の `ComposingCountSnapshot` で表します。

```json
{
  "kind": "composite",
  "lhs": {"kind": "inputCount", "count": 2},
  "rhs": {"kind": "surfaceCount", "count": 1}
}
```

`try ComposingCountSnapshot(count)` と Codable が全 case を保持します。`.validated(for: composition)` はコピーに左から順に消費を適用し、各 leaf の値をその時点で残る正式な input / 読みの個数に照合して、元の `ComposingCount` を返します。負数、過大値、構造の上限超過は拒否します。0 は正当な消費なしとして保持します。実際の確定は行いません。

| transport 専用の上限 | 値 |
| --- | --- |
| JSON | 4 MiB |
| input 要素数 / 読みの Character 数 | それぞれ 16,384 |
| 一つの piece 文字列の UTF-8 | 4 KiB |
| カスタム表名の UTF-8 / 参照する表数 | 1 KiB / 64 |
| ComposingCount の深さ / ノード数 | 32 / 127 |

上限は `CompositionSnapshotLimits` に定義しています。サイズ検査がある `encoded()` / `decode(_:)` を通信の入口に使ってください。単独 wrapper を別の envelope に埋める場合、その envelope でも読み込む JSON のサイズを制限する必要があります。制限超過はこの追加 transport の失敗で、既定の同期経路や正式な読みへ制限を追加するものではありません。呼出側は現在の読みを残したまま失敗を処理します。

この形式は `Candidate` や converter を作り直しません。実候補の不透明な ID、要求 ID、worker/context/focus/設定世代、snapshot の採用判断は外側の所有者が管理します。正しい snapshot と消費範囲だけでは、別の要求や入力欄へ結果を適用できません。候補側からの返信だけで marked text を非同期更新する権限もありません。
