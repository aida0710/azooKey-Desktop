# 実候補を保持する開発用process

`AZOOKEY_BRIDGE_ROLE=candidate` は、読み側から受けた正式なsnapshotを変換し、実Candidateを保持する明示的な開発入口です。通常IBus frontendと既存bridgeは切り替えません。初回はライブ変換OFFの通常変換だけを扱い、予測・AI・debug/action候補は対象外です。予測入力の設定が有効なら候補要求を明示拒否します。

`CompositionSnapshot.restore` で正式な入力へ戻し、`SegmentsManager.restoreComposition`、通常の選択候補、`makeCandidatePresentations` を使います。候補の本文、スコア、辞書token、annotation、消費構造は実候補から取得します。非ゼロの正式消費を持たない候補は出力しません。候補や辞書語の組合せを再構築しません。

## JSONL protocol

全ての応答に `workerGeneration`（起動時UUID）と現在の `settingsRevision` を含みます。候補・参照・完了要求では `authority` を返します。失敗は `error` を返し、入力欄へ適用する命令を含みません。JSON自体を読めないときはauthorityを取得できないため、呼出側が元の要求との対応を保持します。

| operation | 必要なfield | 応答 |
| --- | --- | --- |
| `settings` | なし | learning、customInputTableRevisions |
| `candidates` | `request: DesktopCandidateRequest` | `batch: DesktopCandidateBatch` |
| `retain` / `release` | `reference: DesktopCandidateBatchReference` | 同じreference |
| `complete` | `completion: DesktopCandidateCompletion` | `completion: DesktopCandidateCompletionResult` |
| `configure-learning` | workerGeneration、settingsRevision、learning | 更新後のsettings |
| `close` | workerGeneration、context、readingProcessGeneration | contextを終了した応答 |

一般の `configure`、入力の `key/reset`、AI、候補の直接確定命令は未対応です。`commits`、`preedit`、`cursor`、`inputState`、`consumed` はこのprotocolにありません。候補返信だけで読みや入力欄を更新してはいけません。

`CandidateRequestAuthority` は `context`、`readingProcessGeneration`、`focusEpoch`、`compositionRevision`、`settingsRevision`、`requestID` を持ちます。ID/世代は空でないASCII文字列、epoch/revisionは負でないIntです。新しいreading processは旧contextをcloseしてから別generationで開き直します。context内のepoch/revisionを巻き戻す要求、使い直したrequestID、現在のsettingsRevisionと異なる計算要求は拒否します。

`DesktopCandidateRequest` はauthority、composition、leftContext、rightContext、privateInputを固定します。batchは同じauthority、workerGeneration、batchID、candidatesを持ち、各itemはcandidateID、text、ComposingCountSnapshot、presentationを持ちます。batchIDとcandidateIDはUUIDです。同文・同スコアでも別IDで、表示順や本文はidentityに使いません。

## 保持と一度だけの完了

新しい候補要求は、未retainの旧batchを退役させます。採用したbatchは読み側が `retain` し、計算用session・実Candidate・元の正式入力を保持します。後の計算は別のsessionを使用し、converter本体と辞書/modelだけ共有します。retainが確認できる前に、読み側がその候補を確定可能な選択へ移してはいけません。

`complete` はretain済みの参照だけを受け付けます。authority、workerGeneration、batchID、candidateID、元の消費範囲を照合し、保持した実Candidateを `prefixCandidateCommited` へ渡します。既存順序で学習データを保存し、そのbatchを退役させます。部分候補の残る入力は読み側の正式コピーから求めます。workerの完了処理で残りの候補を再計算する既存動作は、この段階では変更していません。

`commitID` は確定ごとの不透明なIDです。同worker内で同じcommitID・同payloadを再送した場合だけ `alreadyCompleted` を返します。別payloadの使い回しは拒否します。receiptの `learningRequested` は学習更新を要求したかを表し、クラッシュ後も必ず永続化されたという保証ではありません。ACKを受け取る前にworkerが落ちた場合、読みの確定と学習の未確認を分け、世代を越えて学習を自動再送しません。

`release` / `close` は未確定の候補を学習せずに退役させます。close後や別workerの参照は使えません。

## 設定とprivate input

起動時の設定・辞書・登録済みカスタム表を使い、revisionは0から開始します。初回入口で変更できるのは `configure-learning` だけです。新しいrevisionを渡し、未保存の学習を先に保存してから既存の学習設定適用処理を使います。採用済みの候補と消費元は保持します。一般の設定・辞書・入力表の同期は未接続で、通常入力へ組み込む前に実装・検証が必要です。

completionのauthorityは計算時のものを保ち、別fieldの `settingsRevision` が確定時の現設定に一致することを要求します。これにより、選択後に学習をOFF/ONへ変更しても、その時点のモードで同じ実候補を処理します。元要求または確定時のどちらかがprivateなら学習を抑止します。privateによって保存済みのlearning preferenceを書き換えません。

## 上限と未接続部分

上限は1processあたり64context、1contextあたり採用済み8batch＋最新の未採用1batch、request ID 16,384件、完了receipt 1,024件です。IDは512 bytes、左右文脈はそれぞれ16 KiB、入力JSON全体は4 MiBまで。上限では明示エラーを返し、保持済み候補を勝手に再利用・追い出しません。制限超過でも読み側の正式入力は保持します。これらは開発用transportだけの上限です。

読み側の採用・焦点/世代検査、入力中の候補表示、Spaceでの正式separator挿入、候補確定の実入力欄反映、実IPC遅延/クラッシュからの回復は別の統合段階です。Mac実IME・VoiceOver・GTK/Qt/Waylandの応答性はこのworker単体で合格とは判断しません。
