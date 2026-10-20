# 読み・候補 process の Python coordinator

`ReadingCoordinator` は開発検証用の明示的な接続です。生成した場合だけ reading / candidate の2 processを使用し、通常 Engine・InputCoordinator・IBus frontend の入口は変更しません。読みは Core の正式な CompositionState で処理し、Python でローマ字変換や候補を作りません。ライブ変換 OFF、一般設定・辞書・入力表の同期は未接続です。

## 呼出側との境界

`ReadingCoordinator(dispatch, *, publish_input, publish_candidates, notify, environment=None, reader_factory=None, candidate_factory=None)` を、dispatch が実行する所有 thread 上で生成します。全公開メソッドも同じ thread から呼びます。dispatch は callback と引数を所有 thread へ確実に届ける関数です。通信 thread から UI callback を直接実行してはいけません。

| API | 意味 |
| --- | --- |
| `open_context(context, callback=None)` | 非activeの欄を開く。世代は hello、参照は open ACK から取得 |
| `focus_in(context, surroundings, callback=None)` | `{leftContext, rightContext, privateInput}` を固定して焦点を取得 |
| `key(context, event, *, token, finish, double_tap=False)` | 正式な KeyEventCore を FIFO で送る |
| `barrier(context, *, token, finish)` | 先行入力の適用後に元キーを consumed=false で返す。解放や変換対象外キー向け |
| `select(context, selection, *, token, finish)` | 表示した batch 参照と candidateID による明示操作 |
| `reset(context, *, submit, token, finish)` | 同じ欄で確定または取消 |
| `focus_out(context, *, submit, token, finish)` | 元欄の入力応答を処理し、nextReference を後続操作だけに保存 |
| `close_context(context, callback=None)` | 非activeの欄を閉じる。先行の許可済み学習通知より後に候補側も閉じる |
| `configure_learning(learning, revision, callback=None)` | 非active・入力操作なしの限定条件で二つの設定 ACK を待つ |
| `close()` | 所有した元返信を一度完了し、通信を停止。入力を自動確定しない |

token は個々の元入力呼出を識別する不透明な値です。`finish(token, consumed)` は各受付操作について一度だけ呼びます。IBus の NativeKeyReply、フォーカス対象、元キーの native 再配送は adapter が所有し、この coordinator は IBus / GTK を import しません。

`publish_input(ReadingInput)` は context、元 reference、token、snapshot を受けます。元 token の所有を確認し、そのキーの応答内で preedit / commit を反映してから返ります。None / True は適用済み、False は副作用前の拒否です。その後に finish を呼びます。呼出側が snapshot をログへ出してはいけません。

`publish_candidates(ReadingCandidates)` は context、reference、実 batch だけを受けます。candidate worker の retain ACK と読み側の adopt ACK を両方得た後だけ呼び、入力本文を再描画しません。採用 ACK 中に新キーが並んだ場合は panel を出さず、Core が既に採用した候補の参照を保持します。次の元キーがその候補を選んだ場合に表示し、正式入力が変わった場合は release します。別欄・別焦点の結果は破棄します。

## 取消・失敗・学習

reset / focus-out の `submit=False` は既知の取消です。同じ焦点の先行入力 token を退役させ、未送信キーは送らず、送信済みの旧応答も入力・学習へ適用しません。元返信の順序を守れる場合は、旧 process の返答を待たずに退役を完了します。続く正式な取消操作で Core を空にして次欄へ進めます。OS が既に元欄の marked text を確定した場合に、adapter が `submit=True` で再度確定してはいけません。

publish_input の途中で取消が再入した場合も、旧 snapshot や候補画面を再設定しません。True / None で適用済みとなった確定の学習通知は元 candidate・元焦点・元 private 条件で一度送り、次焦点へ流用しません。False で副作用前に拒否された確定は学習せず、既知取消として元返信だけを完了します。

通常入力の適用拒否・適用途中例外・通信応答不明では、coordinator を復旧待ちにします。ReadingNotice は最後に適用済みの snapshot、元 token / payload と、`not-sent` / `response-unknown` / `not-applied` / `application-unknown` の境界を保持します。本文を含む field は repr へ出さず、通知の例外ログも本文を含みません。元キーを一律 false に返すと既に挿入した本文を二重配送するおそれがあるため、退役した返信は true で一度完了します。入力復旧は adapter がこの境界を使って判断し、明示 close → 新 coordinator を開始します。キーや不明な学習通知を別世代へ自動再送しません。

通知の識別子は `ReadingNotice.code` です。成功した学習 ACK は `candidate_learning_completed` と検証済み completion receipt を含み、入力 callback は呼びません。通知を文字列化しても元入力は出ませんが、呼出側が snapshot / payload / completion をログへ展開してはいけません。

未接続キー等の正式な拒否は元入力を保持し、エラー通知と元返信だけを完了して次キーへ進みます。拒否を成功の snapshot に置き換えません。候補到着・学習 ACK は input callback を呼びません。候補確定通知は元 candidateID、元 authority、確定時 settingsRevision / privateInput を照合し、一度 enqueue した後の focus / close では取消しません。学習 ACK 不明は入力確定の失敗と別に通知します。

学習設定変更は active context なし・待機入力なしでのみ開始します。candidate ACK → reader learning-revision ACK まで focus-in は明示拒否します。busy 条件の拒否は変更を始めず、条件が解消した後に再度開始できます。通信や設定 ACK が不明なら推測で前の設定へ戻しません。active 中の変更と確定時 revision の整合は最終 #14 / #17 受入までに必要で、通常 frontend の既存設定処理をこの制限で置き換えません。

candidate process が再起動して設定 revision が戻った場合、両 process で確認済みの学習設定を新 worker generation へ同期します。mode / revision / generation / transport epoch の一致した ACK を得るまで候補を要求しません。この待機は読み・確定・焦点切替を止めず、待機中に変わった焦点へ旧候補を採用しません。同じ revision の別 mode や先行 revision は明示エラーにします。復旧 ACK の消失後は、次の明示候補要求で設定を再確認します。不明な候補確定通知は再送しません。

## 検証の範囲

合成試験は順序・元返信一度・取消・旧参照・再入・例外・設定条件を検査します。実2 process 試験は正式読みの編集、候補 process の SIGSTOP 中の Enter / Escape / focus、実候補の保持・採用・部分確定、private、ACK 消失と再起動を検査します。候補停止中の入力応答を、実アプリの key-to-paint や GTK / Qt / IBus の応答性へ読み替えません。frontend adapter、元欄の復旧、実 GUI の検査は別の未完項目です。
