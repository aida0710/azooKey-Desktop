#include "page_view.h"

#include <commctrl.h>

#include <algorithm>
#include <iterator>

#include "child_controls.h"
#include "dialog_colors.h"

namespace azookey::settings {
namespace {

constexpr wchar_t kClassName[] = L"azooKeyTreeSettingsPage";
constexpr int kMargin = 16;
// Long lines are hard to read; fields and text stop growing at these widths.
constexpr int kMaximumTextWidth = 640;
constexpr int kMaximumFieldWidth = 520;
constexpr int kDropDownWidth = 360;
constexpr int kDropDownListHeight = 240;
constexpr int kNumberFieldWidth = 96;
constexpr int kMultiLineFieldHeight = 132;
constexpr int kCheckBoxGlyphWidth = 24;
constexpr int kButtonGap = 8;
constexpr int kScrollLine = 24;

// Whether a control's notification says it received keyboard focus. The codes
// mean different things for different classes, so the class decides.
bool ReportsFocus(HWND control, WORD notification) {
    if (!control) return false;
    wchar_t className[32] = {};
    GetClassNameW(control, className, static_cast<int>(std::size(className)));
    if (_wcsicmp(className, WC_EDITW) == 0) return notification == EN_SETFOCUS;
    if (_wcsicmp(className, WC_COMBOBOXW) == 0) return notification == CBN_SETFOCUS;
    if (_wcsicmp(className, WC_BUTTONW) == 0) return notification == BN_SETFOCUS;
    return false;
}

}  // namespace

void PageView::RegisterWindowClass(HINSTANCE instance) {
    WNDCLASSEXW windowClass{sizeof(windowClass)};
    windowClass.lpfnWndProc = Procedure;
    windowClass.hInstance = instance;
    windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    windowClass.hbrBackground = reinterpret_cast<HBRUSH>(static_cast<INT_PTR>(kDialogBackgroundColor + 1));
    windowClass.lpszClassName = kClassName;
    RegisterClassExW(&windowClass);
}

PageView::PageView(HWND parent, HWND commandTarget) : commandTarget_(commandTarget) {
    window_ = CreateWindowExW(WS_EX_CONTROLPARENT, kClassName, L"", WS_CHILD | WS_VSCROLL | WS_CLIPCHILDREN, 0, 0, 0, 0,
                              parent, nullptr, reinterpret_cast<HINSTANCE>(GetWindowLongPtrW(parent, GWLP_HINSTANCE)), this);
}

PageView::~PageView() {
    if (window_) DestroyWindow(window_);
}

HWND PageView::AddControl(const wchar_t* className, const std::wstring& text, DWORD style, int id, DWORD extendedStyle) {
    return CreateChildControl(window_, className, text, style, id, extendedStyle);
}

void PageView::Layout(const UiMetrics& metrics) {
    metrics_ = &metrics;
    RECT client{};
    GetClientRect(window_, &client);
    contentHeight_ = Place(metrics);
    UpdateScrollBar(client.bottom);
    // Showing or hiding the scroll bar changes the width the rows wrap at.
    RECT after{};
    GetClientRect(window_, &after);
    if (after.right != client.right) {
        contentHeight_ = Place(metrics);
        UpdateScrollBar(after.bottom);
    }
}

void PageView::Relayout() {
    if (metrics_) Layout(*metrics_);
}

int PageView::Place(const UiMetrics& metrics) {
    RECT client{};
    GetClientRect(window_, &client);
    const int margin = metrics.Scale(kMargin);
    const int width = std::max(1, std::min(static_cast<int>(client.right) - 2 * margin, metrics.Scale(kMaximumTextWidth)));
    int y = margin - scrollOffset_;
    bool first = true;
    for (const auto& row : rows_) {
        if (row.controls.empty()) continue;
        HWND control = row.controls.front();
        std::wstring text = WindowText(control);
        bool textRow = row.sizing == RowSizing::WrappedText || row.sizing == RowSizing::Heading;
        // An empty explanation takes no space and is skipped by keyboard focus.
        if (textRow && text.empty()) {
            ShowWindow(control, SW_HIDE);
            continue;
        }
        ShowWindow(control, SW_SHOWNA);
        if (!first) y += metrics.Scale(row.gapBefore);
        first = false;
        int height = 0;
        switch (row.sizing) {
        case RowSizing::WrappedText:
        case RowSizing::Heading: {
            HFONT font = row.sizing == RowSizing::Heading ? metrics.headingFont() : metrics.font();
            height = metrics.WrappedTextHeight(text, width, font);
            MoveControl(control, margin, y, width, height);
            break;
        }
        case RowSizing::CheckBox:
            height = std::max(metrics.WrappedTextHeight(text, width - metrics.Scale(kCheckBoxGlyphWidth), metrics.font()),
                              metrics.LineHeight()) + metrics.Scale(4);
            MoveControl(control, margin, y, width, height);
            break;
        case RowSizing::Field:
            height = metrics.FieldHeight();
            MoveControl(control, margin, y, std::min(width, metrics.Scale(kMaximumFieldWidth)), height);
            break;
        case RowSizing::NarrowField:
            height = metrics.FieldHeight();
            MoveControl(control, margin, y, metrics.Scale(kNumberFieldWidth), height);
            // The up-down arrows attach to the edit's new position.
            if (row.controls.size() > 1) SendMessageW(row.controls[1], UDM_SETBUDDY, reinterpret_cast<WPARAM>(control), 0);
            break;
        case RowSizing::DropDown:
            height = metrics.FieldHeight();
            // A drop-down list's window height includes the list it opens.
            MoveControl(control, margin, y, std::min(width, metrics.Scale(kDropDownWidth)),
                  height + metrics.Scale(kDropDownListHeight));
            break;
        case RowSizing::MultiLineField:
            height = metrics.Scale(kMultiLineFieldHeight);
            MoveControl(control, margin, y, std::min(width, metrics.Scale(kMaximumFieldWidth)), height);
            break;
        case RowSizing::Buttons: {
            int x = margin;
            int rowHeight = 0;
            for (HWND button : row.controls) {
                SIZE size = metrics.ButtonSize(WindowText(button));
                if (x > margin && x + size.cx > margin + width) {
                    x = margin;
                    y += rowHeight + metrics.Scale(kButtonGap);
                    rowHeight = 0;
                }
                MoveControl(button, x, y, size.cx, size.cy);
                x += size.cx + metrics.Scale(kButtonGap);
                rowHeight = std::max(rowHeight, static_cast<int>(size.cy));
            }
            height = rowHeight;
            break;
        }
        case RowSizing::Link: {
            SIZE ideal{};
            SendMessageW(control, LM_GETIDEALSIZE, static_cast<WPARAM>(width), reinterpret_cast<LPARAM>(&ideal));
            height = std::max(static_cast<int>(ideal.cy), metrics.LineHeight());
            MoveControl(control, margin, y, width, height);
            break;
        }
        }
        y += height;
    }
    return y + scrollOffset_ + margin;
}

void PageView::UpdateScrollBar(int clientHeight) {
    scrollOffset_ = std::clamp(scrollOffset_, 0, std::max(0, contentHeight_ - clientHeight));
    SCROLLINFO info{sizeof(info)};
    info.fMask = SIF_RANGE | SIF_PAGE | SIF_POS;
    info.nMin = 0;
    info.nMax = std::max(0, contentHeight_ - 1);
    info.nPage = static_cast<UINT>(std::max(0, clientHeight));
    info.nPos = scrollOffset_;
    SetScrollInfo(window_, SB_VERT, &info, TRUE);
}

void PageView::ScrollTo(int offset) {
    if (!metrics_) return;
    RECT client{};
    GetClientRect(window_, &client);
    int clamped = std::clamp(offset, 0, std::max(0, contentHeight_ - static_cast<int>(client.bottom)));
    if (clamped == scrollOffset_) return;
    scrollOffset_ = clamped;
    Place(*metrics_);
    UpdateScrollBar(client.bottom);
    InvalidateRect(window_, nullptr, TRUE);
}

void PageView::ScrollIntoView(HWND control) {
    if (!metrics_ || GetParent(control) != window_) return;
    RECT bounds{};
    GetWindowRect(control, &bounds);
    MapWindowPoints(nullptr, window_, reinterpret_cast<POINT*>(&bounds), 2);
    RECT client{};
    GetClientRect(window_, &client);
    int margin = metrics_->Scale(kMargin);
    if (bounds.top < 0) {
        ScrollTo(scrollOffset_ + bounds.top - margin);
    } else if (bounds.bottom > client.bottom) {
        ScrollTo(scrollOffset_ + bounds.bottom - client.bottom + margin);
    }
}

LRESULT CALLBACK PageView::Procedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_NCCREATE) {
        auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
        auto* self = static_cast<PageView*>(create->lpCreateParams);
        self->window_ = window;
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    }
    auto* self = reinterpret_cast<PageView*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (!self) return DefWindowProcW(window, message, wParam, lParam);
    return self->Handle(message, wParam, lParam);
}

LRESULT PageView::Handle(UINT message, WPARAM wParam, LPARAM lParam) {
    HWND window = window_;
    switch (message) {
    case WM_COMMAND:
        if (ReportsFocus(reinterpret_cast<HWND>(lParam), HIWORD(wParam))) ScrollIntoView(reinterpret_cast<HWND>(lParam));
        return SendMessageW(commandTarget_, message, wParam, lParam);
    case WM_NOTIFY:
        return SendMessageW(commandTarget_, message, wParam, lParam);
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLORBTN:
        return DialogControlColors(wParam);
    case WM_SIZE:
        if (metrics_) Layout(*metrics_);
        return 0;
    case WM_VSCROLL: {
        if (!metrics_) return 0;
        RECT client{};
        GetClientRect(window_, &client);
        int offset = scrollOffset_;
        switch (LOWORD(wParam)) {
        case SB_LINEUP: offset -= metrics_->Scale(kScrollLine); break;
        case SB_LINEDOWN: offset += metrics_->Scale(kScrollLine); break;
        case SB_PAGEUP: offset -= client.bottom; break;
        case SB_PAGEDOWN: offset += client.bottom; break;
        case SB_TOP: offset = 0; break;
        case SB_BOTTOM: offset = contentHeight_; break;
        case SB_THUMBTRACK:
        case SB_THUMBPOSITION: {
            SCROLLINFO info{sizeof(info), SIF_TRACKPOS};
            GetScrollInfo(window_, SB_VERT, &info);
            offset = info.nTrackPos;
            break;
        }
        default: break;
        }
        ScrollTo(offset);
        return 0;
    }
    case WM_MOUSEWHEEL:
        if (metrics_) {
            int delta = GET_WHEEL_DELTA_WPARAM(wParam);
            ScrollTo(scrollOffset_ - MulDiv(delta, 3 * metrics_->LineHeight(), WHEEL_DELTA));
        }
        return 0;
    case WM_NCDESTROY:
        SetWindowLongPtrW(window, GWLP_USERDATA, 0);
        window_ = nullptr;
        break;
    default:
        break;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

}  // namespace azookey::settings
