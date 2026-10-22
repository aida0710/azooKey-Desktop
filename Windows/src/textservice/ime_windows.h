// The IME's own windows, which live inside the application's process: popups
// (the candidate panel, notices, the AI review) are topmost, never activated,
// per-monitor DPI aware whatever the application declares and have small
// rounded corners; message-only windows carry work back to the UI thread.
// Window classes are registered on first use.
#pragma once

#include <windows.h>

#include <cstdint>

namespace azookey::tsf {

inline int ScaleForDpi(int dips, UINT dpi) { return MulDiv(dips, static_cast<int>(dpi), 96); }

// Palette colors are 0xRRGGBB.
inline COLORREF ToColorRef(uint32_t rgb) { return RGB((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF); }

// The system message font at a monitor's DPI, so text popups follow the
// Windows text-size setting.
class MessageFont {
public:
    MessageFont() = default;
    ~MessageFont();
    MessageFont(const MessageFont&) = delete;
    MessageFont& operator=(const MessageFont&) = delete;

    HFONT At(UINT dpi);

private:
    HFONT font_ = nullptr;
    UINT dpi_ = 0;
};

struct ImeWindowClass {
    const wchar_t* name;
    WNDPROC procedure;
    UINT style = 0;  // added to CS_IME, e.g. CS_DBLCLKS
};

// `owner` arrives in WM_NCCREATE's CREATESTRUCT::lpCreateParams. nullptr on failure.
HWND CreateImePopup(const ImeWindowClass& windowClass, void* owner);
HWND CreateImeMessageWindow(const ImeWindowClass& windowClass, void* owner);

// Must run before the DLL unloads so no window class points into freed code.
void UnregisterImeWindowClasses();

}  // namespace azookey::tsf
