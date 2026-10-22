// Core's review of an AI suggestion request, shown beside the composition
// before anything leaves the machine: where it goes, the text, and whether the
// surrounding text goes too. Keys reach it through the text service (Core's
// bindings). Its controls are drawn rather than child windows, so a click can
// never move the keyboard focus away from the document.
#pragma once

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

#include "caret_popup.h"
#include "ime_windows.h"
#include "shared/bridge_protocol.h"
#include "text_announcer.h"

namespace azookey::tsf {

class AIReviewWindow {
public:
    struct Actions {
        std::function<void()> send;
        std::function<void()> toggleContext;
        std::function<void()> cancel;
    };

    explicit AIReviewWindow(Actions actions) : actions_(std::move(actions)) {}
    ~AIReviewWindow();
    AIReviewWindow(const AIReviewWindow&) = delete;
    AIReviewWindow& operator=(const AIReviewWindow&) = delete;

    // `caret` is in physical screen pixels. `includeContext` is the user's
    // current choice, which may differ from the review's initial one.
    void Show(const protocol::AIReview& review, bool includeContext, const RECT& caret, PopupSide side);
    void Hide();
    bool visible() const { return window_ && IsWindowVisible(window_); }

private:
    // Physical pixels inside the window, worked out for the current DPI.
    struct Layout {
        RECT title{}, destination{}, targetLabel{}, target{}, contextBox{}, context{}, keyboard{}, send{}, cancel{};
        SIZE size{};
    };

    static LRESULT CALLBACK WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
    bool EnsureWindow();
    Layout Measure(HDC context) const;
    void Paint();
    void Click(POINT point);
    std::wstring SpokenText() const;

    Actions actions_;
    HWND window_ = nullptr;
    std::unique_ptr<TextAnnouncer> announcer_;
    MessageFont font_;
    UINT dpi_ = 96;
    Layout layout_;
    protocol::AIReview review_;
    bool includeContext_ = false;
};

}  // namespace azookey::tsf
