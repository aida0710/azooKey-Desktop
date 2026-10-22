#include "caret_popup.h"

#include <shellscalingapi.h>

#include <algorithm>

namespace azookey::tsf {

CaretMonitor MonitorOfCaret(const RECT& caret) {
    CaretMonitor result;
    HMONITOR monitor = MonitorFromPoint({caret.left, caret.bottom}, MONITOR_DEFAULTTONEAREST);
    UINT unused = 96;
    GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &result.dpi, &unused);
    MONITORINFO info{sizeof(info)};
    GetMonitorInfoW(monitor, &info);
    result.workArea = info.rcWork;
    return result;
}

POINT PlaceBesideCaret(SIZE size, const RECT& caret, PopupSide side, int gap) {
    const RECT work = MonitorOfCaret(caret).workArea;
    int below = caret.bottom + gap;
    int above = caret.top - gap - size.cy;
    bool fitsBelow = below + size.cy <= work.bottom;
    bool fitsAbove = above >= work.top;
    bool useAbove = side == PopupSide::AboveCaret ? fitsAbove || !fitsBelow : !fitsBelow && fitsAbove;
    int x = std::clamp<int>(caret.left, work.left, std::max<int>(work.left, work.right - size.cx));
    int y = std::clamp<int>(useAbove ? above : below, work.top, std::max<int>(work.top, work.bottom - size.cy));
    return {x, y};
}

}  // namespace azookey::tsf
