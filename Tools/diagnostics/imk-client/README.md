# IMK client初期化の一時診断

99c089cのMac試験はbundle登録を通過した後、IMKInputControllerの指定初期化で
NSObjectのFakeTextInputを「unexpected client proxy」として拒否した。
この診断はその初期化だけを比較し、製品と既存の動作試験を変更しない。

実試験のFakeTextInput宣言をそのまま抽出し、sourceと抽出部分のSHA256を記録する。
各ケースは別process、上限20秒。Objective-C例外とabortを区別する。

- direct-client: 実試験と同じNSObject/IMKTextInputを指定初期化へ渡す対照。
- nil-client: IMKInputControllerの指定初期化へnilを渡す。
- nil-client-override: Swiftの試験専用subclassがnilで指定初期化し、公開client()で同じmockを返す。
- connection-root-proxy: 別processのNSConnectionが持つmockを、正規のrootProxy経由で渡す。NSDistantObjectを直接初期化しない。
- default-init: 公開された継承initがSDKで許されるかを別compileで確認する。他ケースの診断をcompile失敗で止めない。

初期化後はclientのclass、protocol、nil状態、合成文字だけを使ったmarked/insertの呼出結果を記録する。
結果はbuild/imk-client-diagnosisへ保存する。診断の完了は、製品の動作試験や実IMEの合格を意味しない。

一時branchのtree-ci.ymlだけをworkflow_dispatch専用にした。通常のPRや既定branchの検査を省略する変更ではなく、
このbranchはPR・merge対象にしない。診断終了後に証跡を保存して片付ける。

公開APIの参照:

- [IMK指定初期化](https://developer.apple.com/documentation/inputmethodkit/imkinputcontroller/init(server:delegate:client:))
- [client()](https://developer.apple.com/documentation/inputmethodkit/imkinputcontroller/client())
- [NSDistantObject](https://developer.apple.com/documentation/foundation/nsdistantobject)
- [NSConnection.rootProxy](https://developer.apple.com/documentation/foundation/nsconnection/rootproxy)
