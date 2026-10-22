// A one-line message beside the caret: the reading being typed for a
// reconversion, why Core declined one, or how an AI request went. It never
// takes focus; screen readers hear each new message as a notification.
#pragma once

#include <windows.h>

#include <memory>
#include <string>

#include "caret_popup.h"
#include "ime_windows.h"
#include "text_announcer.h"

namespace azookey::tsf {

class NoticeWindow {
public:
    NoticeWindow() = default;
    ~NoticeWindow();
    NoticeWindow(const NoticeWindow&) = delete;
    NoticeWindow& operator=(const NoticeWindow&) = delete;

    // `caret` is in physical screen pixels.
    void Show(const std::wstring& text, const RECT& caret, PopupSide side);
    void Hide();
    bool visible() const { return window_ && IsWindowVisible(window_); }

private:
    static LRESULT CALLBACK WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
    bool EnsureWindow();
    void Paint();

    HWND window_ = nullptr;
    std::unique_ptr<TextAnnouncer> announcer_;
    MessageFont font_;
    UINT dpi_ = 96;
    std::wstring text_;
};

}  // namespace azookey::tsf
