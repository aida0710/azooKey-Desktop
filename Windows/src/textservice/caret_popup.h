// Placing a small popup beside the caret: on the monitor showing the caret,
// on the side asked for, or the other side when the work area has no room.
#pragma once

#include <windows.h>

namespace azookey::tsf {

// The candidate panel usually sits below the caret; other popups then go above.
enum class PopupSide { BelowCaret, AboveCaret };

struct CaretMonitor {
    UINT dpi = 96;
    RECT workArea{};
};

// `caret` is in physical screen pixels.
CaretMonitor MonitorOfCaret(const RECT& caret);

// The top-left corner for a popup of `size` pixels, `gap` pixels from the caret.
POINT PlaceBesideCaret(SIZE size, const RECT& caret, PopupSide side, int gap);

}  // namespace azookey::tsf
