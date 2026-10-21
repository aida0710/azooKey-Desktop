# フォーカス変更時の未確定文字の確定責任

通常 Engine と開発中の ReadingEngine は `preedit_ownership.preedit_focus_mode` を共用する。`FocusInId` で受けた client 名が正確に `QIBusInputContext` の場合は `CLEAR`、それ以外は従来の `COMMIT` を使う。Unicode 入力の `CLEAR` は維持する。候補や正式入力を変更する関数ではない。

Qt 6.4.2 の IBus plugin は `commit()` で現在の入力欄へ未確定文字を確定してから `Reset` を送る。別の入力欄でも同じ InputContext を使い、次の `FocusIn` を送る。一方 IBus 1.5.29 は `COMMIT` モードで `ClientCommitPreedit` が無効なら、Engine へ Reset を渡す前に保持した未確定文字を確定する。その通知を Qt が新しい欄へ配送すると二重確定になる。Engine の Reset 内で空の未確定文字を送っても、その時点では遅い。

- [Qt 6.4.2 の commit / setFocusObject / commitText](https://github.com/qt/qtbase/blob/v6.4.2/src/plugins/platforminputcontexts/ibus/qibusplatforminputcontext.cpp#L149)
- [IBus 1.5.29 の Reset](https://github.com/ibus/ibus/blob/1.5.29/bus/inputcontext.c#L1108)
- [IBus の focus-out と ClientCommitPreedit](https://github.com/ibus/ibus/blob/1.5.29/bus/inputcontext.c#L1696)

この識別で、Qt 自身の確定を残し、daemon の重複確定を防ぐ。client 名に部分一致や接頭辞一致を使わない。未知の client の確定責任を推測して変更しない。明示 Enter、Core の確定、取消や元キーの返信方式は変えない。候補待ちの preview と再変換の復旧表示も同じ規則を使う。

`test_preedit_ownership.py` は両 Engine の実メソッドと復旧経路を検査する。`linux-preedit-ownership.sh` は実 daemon と両 product adapter で Reset 後の重複なし、Enter 一回、取消、未知 client の focus-out 確定を検査する。後者の Qt client は通信契約を検査するための fixture であり、実 Qt widget の受入とは区別する。実 GTK4/Qt の欄移動・別 window・確定・取消は別の画面検査に残す。
