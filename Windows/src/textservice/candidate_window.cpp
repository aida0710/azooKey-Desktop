#include "candidate_window.h"

#include <shellscalingapi.h>
#include <windowsx.h>

#include <algorithm>

#include "module.h"

namespace azookey::tsf {
namespace {

constexpr wchar_t kWindowClassName[] = L"azooKeyTreeCandidateWindow";
// One page matches the physical number keys 1-9 that Core uses for selection.
constexpr int kRowsPerPage = 9;
// Sizes at 96 dpi; scaled to the monitor. Rows stay compact (the Ubuntu
// review asked for lower rows), and the text keeps a readable size.
constexpr int kTextPointSize96 = 16;
constexpr int kDetailPointSize96 = 12;
constexpr int kRowPadding96 = 3;
constexpr int kOuterPadding96 = 6;
constexpr int kAnchorGap96 = 2;
constexpr int kMinimumTextWidth96 = 120;

int Scale(int value, UINT dpi) { return MulDiv(value, static_cast<int>(dpi), 96); }

bool windowClassRegistered = false;

}  // namespace

CandidateWindow::CandidateWindow(ChooseHandler onChoose) : onChoose_(std::move(onChoose)) {}

CandidateWindow::~CandidateWindow() {
    if (window_) DestroyWindow(window_);
    if (textFont_) DeleteObject(textFont_);
    if (detailFont_) DeleteObject(detailFont_);
}

void CandidateWindow::UnregisterWindowClass() {
    if (windowClassRegistered) {
        UnregisterClassW(kWindowClassName, ModuleInstance());
        windowClassRegistered = false;
    }
}

bool CandidateWindow::EnsureWindow() {
    if (window_) return true;
    if (!windowClassRegistered) {
        WNDCLASSEXW windowClass{sizeof(windowClass)};
        windowClass.style = CS_IME | CS_DROPSHADOW;
        windowClass.lpfnWndProc = WindowProcedure;
        windowClass.hInstance = ModuleInstance();
        windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        windowClass.lpszClassName = kWindowClassName;
        windowClassRegistered = RegisterClassExW(&windowClass) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
        if (!windowClassRegistered) return false;
    }
    // Per-monitor awareness for our own window, whatever the host application
    // declares, so the list is sharp and sized for the monitor it is on.
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    window_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kWindowClassName, L"", WS_POPUP | WS_BORDER,
                              0, 0, 1, 1, nullptr, nullptr, ModuleInstance(), this);
    if (previous) SetThreadDpiAwarenessContext(previous);
    return window_ != nullptr;
}

void CandidateWindow::UpdateFonts(UINT dpi) {
    if (dpi == fontDpi_ && textFont_) return;
    if (textFont_) DeleteObject(textFont_);
    if (detailFont_) DeleteObject(detailFont_);
    textFont_ = CreateFontW(-Scale(kTextPointSize96, dpi), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                            OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Yu Gothic UI");
    detailFont_ = CreateFontW(-Scale(kDetailPointSize96, dpi), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                              OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Yu Gothic UI");
    fontDpi_ = dpi;
}

SIZE CandidateWindow::MeasureContent(HDC dc) {
    UINT dpi = fontDpi_;
    padding_ = Scale(kOuterPadding96, dpi);
    HGDIOBJ previous = SelectObject(dc, textFont_);
    TEXTMETRICW metrics{};
    GetTextMetricsW(dc, &metrics);
    rowHeight_ = metrics.tmHeight + 2 * Scale(kRowPadding96, dpi);
    SIZE digit{};
    GetTextExtentPoint32W(dc, L"9", 1, &digit);
    numberWidth_ = digit.cx + Scale(kOuterPadding96, dpi);
    int textWidth = Scale(kMinimumTextWidth96, dpi);
    for (const auto& row : rows_) {
        SIZE size{};
        GetTextExtentPoint32W(dc, row.text.c_str(), static_cast<int>(row.text.size()), &size);
        textWidth = std::max<int>(textWidth, size.cx);
    }
    SelectObject(dc, detailFont_);
    GetTextMetricsW(dc, &metrics);
    footerHeight_ = metrics.tmHeight + Scale(kRowPadding96, dpi) * 2;
    std::wstring footerLine = annotation_.empty() ? footer_ : annotation_ + L"  " + footer_;
    SIZE footerSize{};
    GetTextExtentPoint32W(dc, footerLine.c_str(), static_cast<int>(footerLine.size()), &footerSize);
    SelectObject(dc, previous);
    int width = std::max<int>(numberWidth_ + textWidth, footerSize.cx) + 2 * padding_;
    int height = static_cast<int>(rows_.size()) * rowHeight_ + footerHeight_ + 2 * padding_;
    return {width, height};
}

void CandidateWindow::Show(const protocol::Snapshot& snapshot, const RECT& anchor) {
    if (snapshot.candidates.empty() || !snapshot.showCandidateIndex || !snapshot.selection || !EnsureWindow()) {
        Hide();
        return;
    }
    int selected = *snapshot.selection;
    int pageStart = std::clamp(snapshot.pageStart, 0, static_cast<int>(snapshot.candidates.size()) - 1);
    rows_.clear();
    selectedRow_ = -1;
    annotation_.clear();
    for (int i = pageStart; i < static_cast<int>(snapshot.candidates.size()) && i < pageStart + kRowsPerPage; ++i) {
        const auto& candidate = snapshot.candidates[i];
        if (candidate.index == selected) {
            selectedRow_ = static_cast<int>(rows_.size());
            annotation_ = candidate.annotation;
        }
        rows_.push_back({candidate.index, std::to_wstring(i - pageStart + 1), candidate.text});
    }
    footer_ = std::to_wstring(selected + 1) + L" / " + std::to_wstring(snapshot.candidates.size());

    POINT anchorPoint{anchor.left, anchor.bottom};
    HMONITOR monitor = MonitorFromPoint(anchorPoint, MONITOR_DEFAULTTONEAREST);
    MONITORINFO monitorInfo{sizeof(monitorInfo)};
    GetMonitorInfoW(monitor, &monitorInfo);
    // Size for the monitor the list will appear on, not the one it was last on.
    UINT dpi = GetDpiForWindow(window_);
    UINT monitorDpiX = 0, monitorDpiY = 0;
    if (SUCCEEDED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &monitorDpiX, &monitorDpiY))) dpi = monitorDpiX;
    UpdateFonts(dpi);
    HDC dc = GetDC(window_);
    SIZE size = MeasureContent(dc);
    ReleaseDC(window_, dc);

    const RECT& work = monitorInfo.rcWork;
    int gap = Scale(kAnchorGap96, dpi);
    int x = std::clamp<int>(anchor.left, work.left, std::max<int>(work.left, work.right - size.cx));
    int y = anchor.bottom + gap;
    // Above the text when there is no room below, never covering the caret line.
    if (y + size.cy > work.bottom) y = std::max<int>(work.top, anchor.top - gap - size.cy);
    SetWindowPos(window_, HWND_TOPMOST, x, y, size.cx, size.cy, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    InvalidateRect(window_, nullptr, TRUE);
}

void CandidateWindow::Hide() {
    if (window_) ShowWindow(window_, SW_HIDE);
}

void CandidateWindow::Paint(HDC dc) {
    RECT client{};
    GetClientRect(window_, &client);
    // System colors follow the user's theme and high-contrast settings.
    FillRect(dc, &client, GetSysColorBrush(COLOR_WINDOW));
    SetBkMode(dc, TRANSPARENT);
    HGDIOBJ previous = SelectObject(dc, textFont_);
    for (size_t i = 0; i < rows_.size(); ++i) {
        RECT row{client.left + padding_, padding_ + static_cast<int>(i) * rowHeight_, client.right - padding_,
                 padding_ + static_cast<int>(i + 1) * rowHeight_};
        bool selected = static_cast<int>(i) == selectedRow_;
        if (selected) FillRect(dc, &row, GetSysColorBrush(COLOR_HIGHLIGHT));
        RECT number = row;
        number.right = number.left + numberWidth_;
        SetTextColor(dc, GetSysColor(selected ? COLOR_HIGHLIGHTTEXT : COLOR_GRAYTEXT));
        DrawTextW(dc, rows_[i].number.c_str(), -1, &number, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        RECT text = row;
        text.left = number.right;
        SetTextColor(dc, GetSysColor(selected ? COLOR_HIGHLIGHTTEXT : COLOR_WINDOWTEXT));
        DrawTextW(dc, rows_[i].text.c_str(), -1, &text, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
    }
    SelectObject(dc, detailFont_);
    SetTextColor(dc, GetSysColor(COLOR_GRAYTEXT));
    RECT footer{client.left + padding_, client.bottom - padding_ - footerHeight_, client.right - padding_, client.bottom - padding_};
    DrawTextW(dc, footer_.c_str(), -1, &footer, DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
    if (!annotation_.empty()) {
        DrawTextW(dc, annotation_.c_str(), -1, &footer, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
    }
    SelectObject(dc, previous);
}

int CandidateWindow::RowAt(POINT point) const {
    if (rowHeight_ <= 0 || point.y < padding_) return -1;
    int row = (point.y - padding_) / rowHeight_;
    return row < static_cast<int>(rows_.size()) ? row : -1;
}

LRESULT CALLBACK CandidateWindow::WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_NCCREATE) {
        auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto* self = reinterpret_cast<CandidateWindow*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    switch (message) {
    case WM_MOUSEACTIVATE:
        // Clicking the list must not move focus away from the text being edited.
        return MA_NOACTIVATE;
    case WM_PAINT: {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(window, &paint);
        if (self) self->Paint(dc);
        EndPaint(window, &paint);
        return 0;
    }
    case WM_LBUTTONUP:
        if (self) {
            int row = self->RowAt({GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)});
            if (row >= 0 && self->onChoose_) self->onChoose_(self->rows_[row].candidateIndex);
        }
        return 0;
    case WM_NCDESTROY:
        if (self) self->window_ = nullptr;
        break;
    default:
        break;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

}  // namespace azookey::tsf
