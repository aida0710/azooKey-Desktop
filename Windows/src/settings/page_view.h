// A scrollable panel that places its controls one row under another across
// its width. Rows say how they are sized; heights follow the text, the font
// and the DPI, so a page relays out when the window or the DPI changes.
#pragma once

#include <windows.h>

#include <string>
#include <utility>
#include <vector>

#include "../ui/ui_metrics.h"

namespace azookey::settings {

enum class RowSizing {
    WrappedText,    // a static whose text wraps at the panel width
    Heading,        // a static in the heading font
    CheckBox,       // a check box whose label wraps
    Field,          // a single-line edit
    NarrowField,    // a single-line edit for a short value (a number with its up-down arrows)
    DropDown,       // a drop-down list
    MultiLineField, // a multi-line edit of several lines
    Buttons,        // push buttons side by side, wrapping to the next line
    Link,           // a SysLink sized to its text
};

struct PageRow {
    std::vector<HWND> controls;
    RowSizing sizing = RowSizing::WrappedText;
    int gapBefore = 8;  // 96-DPI pixels above the row
};

class PageView {
public:
    // Creates the hidden panel. WM_COMMAND and WM_NOTIFY from its controls go to `commandTarget`.
    PageView(HWND parent, HWND commandTarget);
    ~PageView();
    PageView(const PageView&) = delete;
    PageView& operator=(const PageView&) = delete;

    HWND window() const { return window_; }
    // Creates a visible child control of the panel.
    HWND AddControl(const wchar_t* className, const std::wstring& text, DWORD style, int id, DWORD extendedStyle = 0);
    void AddRow(PageRow row) { rows_.push_back(std::move(row)); }

    void Layout(const ui::UiMetrics& metrics);
    // Lays out again with the last metrics, after a control's text changed its height.
    void Relayout();
    // Scrolls so `control`, a child of this panel, is fully visible.
    void ScrollIntoView(HWND control);

    static void RegisterWindowClass(HINSTANCE instance);

private:
    static LRESULT CALLBACK Procedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
    LRESULT Handle(UINT message, WPARAM wParam, LPARAM lParam);
    // Places every row with the current scroll offset; returns the content height.
    int Place(const ui::UiMetrics& metrics);
    void ScrollTo(int offset);
    void UpdateScrollBar(int clientHeight);

    HWND window_ = nullptr;
    HWND commandTarget_ = nullptr;
    std::vector<PageRow> rows_;
    const ui::UiMetrics* metrics_ = nullptr;
    int contentHeight_ = 0;
    int scrollOffset_ = 0;
};

}  // namespace azookey::settings
