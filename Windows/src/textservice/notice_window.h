// A one-line message beside the caret: the reading being typed for a
// reconversion, or why Core declined one. It never takes focus; screen readers
// hear each new message as a UI Automation notification.
#pragma once

#include <windows.h>

#include <string>

namespace azookey::tsf {

// The candidate panel usually sits below the caret; the notice then goes above.
enum class NoticePlacement { BelowCaret, AboveCaret };

class NoticeWindow {
public:
    NoticeWindow() = default;
    ~NoticeWindow();
    NoticeWindow(const NoticeWindow&) = delete;
    NoticeWindow& operator=(const NoticeWindow&) = delete;

    // `caret` is in physical screen pixels. The notice goes on the `placement`
    // side, or the other one when the work area has no room there.
    void Show(const std::wstring& text, const RECT& caret, NoticePlacement placement);
    void Hide();
    bool visible() const { return window_ && IsWindowVisible(window_); }

    // Must run before the DLL unloads so no window class points into freed code.
    static void UnregisterWindowClass();

    class Provider;

private:
    friend class Provider;

    static LRESULT CALLBACK WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
    bool EnsureWindow();
    HFONT FontFor(UINT dpi);
    void Paint();
    void Announce();

    HWND window_ = nullptr;
    Provider* provider_ = nullptr;
    HFONT font_ = nullptr;
    UINT fontDpi_ = 0;
    std::wstring text_;
};

}  // namespace azookey::tsf
