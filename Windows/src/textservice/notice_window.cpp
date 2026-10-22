#include "notice_window.h"

#include <algorithm>

#include "candidate_theme.h"
#include "ime_windows.h"
#include "module.h"

namespace azookey::tsf {
namespace {

constexpr wchar_t kWindowClassName[] = L"azooKeyTreeNotice";

// Space around the text, and between the caret and the notice, in DIPs; the
// same rhythm as the candidate panel's footer.
constexpr int kHorizontalPadding = 8;
constexpr int kVerticalPadding = 4;
constexpr int kCaretGap = 4;

}  // namespace

NoticeWindow::~NoticeWindow() {
    // The announcer refers to the window, so it goes first.
    announcer_.reset();
    if (window_) DestroyWindow(window_);
}

bool NoticeWindow::EnsureWindow() {
    if (window_) return true;
    window_ = CreateImePopup({kWindowClassName, WindowProcedure}, this);
    if (!window_) return false;
    announcer_ = std::make_unique<TextAnnouncer>(window_, L"azooKeyTree.notice");
    return true;
}

void NoticeWindow::Show(const std::wstring& text, const RECT& caret, PopupSide side) {
    if (text.empty()) {
        Hide();
        return;
    }
    if (!EnsureWindow()) return;
    text_ = text;
    CaretMonitor monitor = MonitorOfCaret(caret);
    UINT dpi = monitor.dpi;
    dpi_ = dpi;

    HDC context = GetDC(window_);
    HGDIOBJ previousFont = SelectObject(context, font_.At(dpi));
    RECT measured{};
    DrawTextW(context, text_.c_str(), -1, &measured, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
    SelectObject(context, previousFont);
    ReleaseDC(window_, context);

    SIZE size{std::min<int>(measured.right + 2 * ScaleForDpi(kHorizontalPadding, dpi), monitor.workArea.right - monitor.workArea.left),
              measured.bottom + 2 * ScaleForDpi(kVerticalPadding, dpi)};
    POINT origin = PlaceBesideCaret(size, caret, side, ScaleForDpi(kCaretGap, dpi));
    SetWindowPos(window_, HWND_TOPMOST, origin.x, origin.y, size.cx, size.cy, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    InvalidateRect(window_, nullptr, TRUE);
    announcer_->Announce(text_);
}

void NoticeWindow::Hide() {
    if (window_) ShowWindow(window_, SW_HIDE);
    text_.clear();
    // The same message shown again later is news again.
    if (announcer_) announcer_->Forget();
}

void NoticeWindow::Paint() {
    PAINTSTRUCT paint;
    HDC context = BeginPaint(window_, &paint);
    const CandidatePalette& palette = PaletteFor(CurrentCandidateAppearance());
    RECT client{};
    GetClientRect(window_, &client);
    HBRUSH background = CreateSolidBrush(ToColorRef(palette.background));
    FillRect(context, &client, background);
    DeleteObject(background);
    HBRUSH border = CreateSolidBrush(ToColorRef(palette.border));
    FrameRect(context, &client, border);
    DeleteObject(border);
    HGDIOBJ previousFont = SelectObject(context, font_.At(dpi_));
    SetBkMode(context, TRANSPARENT);
    SetTextColor(context, ToColorRef(palette.text));
    DrawTextW(context, text_.c_str(), -1, &client, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
    SelectObject(context, previousFont);
    EndPaint(window_, &paint);
}

LRESULT CALLBACK NoticeWindow::WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_NCCREATE) {
        auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto* self = reinterpret_cast<NoticeWindow*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    switch (message) {
    case WM_MOUSEACTIVATE:
        // Clicking the notice must not move focus away from the text being edited.
        return MA_NOACTIVATE;
    case WM_GETOBJECT:
        if (self && self->announcer_) {
            if (LRESULT result = self->announcer_->HandleGetObject(wParam, lParam)) return result;
        }
        break;
    case WM_PAINT:
        if (self) {
            self->Paint();
            return 0;
        }
        break;
    default:
        break;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

}  // namespace azookey::tsf
