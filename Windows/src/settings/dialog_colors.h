// These windows use the system's dialog colors (COLOR_BTNFACE and
// COLOR_BTNTEXT), which follow the user's contrast theme.
#pragma once

#include <windows.h>

namespace azookey::settings {

inline constexpr int kDialogBackgroundColor = COLOR_BTNFACE;

// The reply to WM_CTLCOLORSTATIC and WM_CTLCOLORBTN for labels, check boxes and read-only edits.
inline LRESULT DialogControlColors(WPARAM deviceContext) {
    HDC dc = reinterpret_cast<HDC>(deviceContext);
    SetTextColor(dc, GetSysColor(COLOR_BTNTEXT));
    SetBkColor(dc, GetSysColor(kDialogBackgroundColor));
    return reinterpret_cast<LRESULT>(GetSysColorBrush(kDialogBackgroundColor));
}

}  // namespace azookey::settings
