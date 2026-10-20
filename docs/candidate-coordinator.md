# 候補processの独立した制御

`Linux/azookey/candidate_coordinator.py` は、正式な読みを所有する呼出側から候補workerを使うための開発用モジュールです。Engine/InputCoordinatorへの接続はまだありません。かな変換や正式入力の再構築、入力欄へのpreedit/commitの適用は扱いません。

`CandidateCoordinator(dispatch, environment=..., bridge_factory=...)` へ、既存AsyncBridgeと同じ `dispatch(callback, reply)` を渡します。実frontendでは `GLib.idle_add` に相当します。公開操作とcallbackは作成元のthreadで実行します。専用threadだけが既存blocking Bridgeを生成・使用・回収し、環境のcopyへ `AZOOKEY_BRIDGE_ROLE=candidate` を指定します。

## 候補の要求と採用

- `request_candidates(request, callback)` は合意済みのDesktopCandidateRequestをcopyして送信します。現在authorityも更新します。計算は一度に1件、未処理の計算はcontextごとに最新1件。古いpendingを除去して新要求を末尾へ置くため、設定・確定などの操作の順序は変わりません。
- `set_authority(authority)` は計算を要求しない状態変更に使います。同じreading generationのepoch/revisionは巻き戻せません。reading generationが変わると旧contextを先にcloseします。別contextは独立です。
- 返答のauthority/workerGeneration/候補IDを確認し、同じworker処理内でretainを送ります。ACKの参照が一致するまではcallbackを配送せず、次の計算も開始しません。
- callbackを呼ぶ時点でも現在authority全field、未配送要求token、workerの世代を再照合します。古いbatchはreleaseし、表示・採用に渡しません。dispatchやcallbackの失敗でも参照を解放します。
- 配送済みの候補は、同じowner内の新計算では失いません。`release(reference)`、焦点/reading generation変更、`close_context(context, reading_process_generation)` で解放します。選択を保持するかは読み側の責務です。

返信は `CandidateReply` で、batch・settings・completion・errorを個別に持ちます。candidate protocolに入力欄命令が混入した場合は採用せず、接続を無効化します。入力や候補本文からidentityを作りません。正式な消費範囲の検査は読み側のCoreが行います。呼出側は選択を保持しない旧batchを明示releaseし、workerの採用済み8batchの上限を使い切らないようにします。

## 確定通知と設定の順序

`complete(completion, authority=current_owner, callback=...)` は、enqueue時に現ownerと保持済みbatch/candidateを照合します。元batchのcomposition/settings authorityは変えず、別fieldの確定時settingsRevisionをcurrent_ownerへ一致させます。payloadをcopyして固定し、以後のfocus/読み更新やcontext closeでは取り消しません。これは読み側で許可済みの確定に伴う独立した学習通知です。

`settings(callback)`、`configure_learning(learning, revision, worker_generation=..., callback=...)`、retain/release/complete/closeは同じFIFOで処理し、まとめません。設定のrevisionは呼出側とSwift workerの照合対象です。呼出側は失敗した設定を有効と推測せず、ACKで確認します。一般設定・辞書・表の同期は未接続です。

completeのreceiptは元commitID、candidateID、batchID、source authority、workerGenerationに一致することを確認します。候補の表示には使いません。後から焦点が変わっても、確認できた元のreceiptは返します。明示的な同payload再送だけは同worker内で許可し、SwiftのalreadyCompletedを返します。別payloadで同IDを使い回せません。

開発用transportの上限はSwiftと同じ64context・1contextにつき1024個の確定IDです。異なる確定IDを1024個enqueueした後は、新規の確定を送信前に拒否し、保持中の候補参照を消費しません。既存IDの同payload再送は引き続き許可します。拒否された通知もIDを予約したままにし、古い履歴を追い出して同IDの別payloadを再学習させません。呼出側は上限を通常入力の破棄理由にせず、この開発入口で学習を通知できないことを扱う必要があります。

履歴の寿命はcontext closeまたはworker世代の終了までです。closeは先行する確定の後に処理し、Swift側もそのcontextのreceiptを破棄します。終了したcontextの候補は保持済み参照の検査で、新世代への旧候補再送はworkerGenerationの検査で拒否します。これは別context寿命やprocess再起動をまたぐ永続的な重複排除ではありません。

送信後に接続を失った場合は `uncertain=True` として、学習が反映されたか未確認であることを一度通知します。自動再送は行いません。再起動後のworkerへ旧候補のcomplete/retain/releaseを適用しません。明示拒否されたcompleteは元batchをreleaseして終了します。

`close()` はUI threadをjoinで待たせず、子processをinterruptします。pipe回収と終了待ちは専用threadが行い、終了後のcallbackは配送しません。最初のhandshake中のcontext closeだけは、先行処理が決めたworker世代で順番に実行します。

## 検査と残件

`test_candidate_coordinator.py` は模擬Bridgeとqueue dispatcherで待機・順序・取消・逆順配送・ACK・失敗を検査します。`test_candidate_coordinator_process.py` は `AZOOKEY_BRIDGE` の実Swift bridgeを使い、専用子processのSIGSTOP/再開・再起動、実候補retain、学習保存とACK再送を検査します。テストのwait上限は停止した検査を検出するためのもので、キー応答性能の基準ではありません。

正式なreading processとの接続、Engine組込み、候補worker停止中の実GTK/Qt入力、一般設定同期、CPUモデル・arm64・macOSはこのモジュールの検査範囲に含めません。
