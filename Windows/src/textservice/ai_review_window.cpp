#include "ai_review_window.h"

#include <windowsx.h>

#include <algorithm>

#include "candidate_theme.h"
#include "shared/ui_language.h"

namespace azookey::tsf {
namespace {

constexpr wchar_t kWindowClassName[] = L"azooKeyTreeAIReview";

// DIPs. The width leaves room for a whole destination; the target box shows a
// few lines of a long target, as Linux keeps its target view short.
constexpr int kWidth = 440;
constexpr int kPadding = 12;
constexpr int kGap = 8;
constexpr int kTargetLines = 4;
constexpr int kButtonPadding = 12;
constexpr int kCaretGap = 4;
constexpr int kCornerRadius = 4;

constexpr UINT kWrap = DT_WORDBREAK | DT_EDITCONTROL | DT_NOPREFIX;

std::wstring Message(const char* key) { return messages::Text(key, messages::CurrentUiLanguage()); }

bool Contains(const RECT& rect, POINT point) { return PtInRect(&rect, point) != FALSE; }

int TextHeight(HDC context, const std::wstring& text, int width, UINT format) {
    RECT measured{0, 0, width, 0};
    DrawTextW(context, text.c_str(), -1, &measured, format | DT_CALCRECT);
    return measured.bottom;
}

int TextWidth(HDC context, const std::wstring& text) {
    RECT measured{};
    DrawTextW(context, text.c_str(), -1, &measured, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
    return measured.right;
}

std::wstring DestinationText(const protocol::AIReview& review) {
    return Message("ai.scope.destination") + L": " + review.destination.value_or(Message("ai.destination.invalid"));
}

}  // namespace

AIReviewWindow::~AIReviewWindow() {
    // The announcer refers to the window, so it goes first.
    announcer_.reset();
    if (window_) DestroyWindow(window_);
}

bool AIReviewWindow::EnsureWindow() {
    if (window_) return true;
    window_ = CreateImePopup({kWindowClassName, WindowProcedure}, this);
    if (!window_) return false;
    announcer_ = std::make_unique<TextAnnouncer>(window_, L"azooKeyTree.aiReview");
    return true;
}

AIReviewWindow::Layout AIReviewWindow::Measure(HDC context) const {
    Layout layout;
    int padding = ScaleForDpi(kPadding, dpi_);
    int gap = ScaleForDpi(kGap, dpi_);
    int width = ScaleForDpi(kWidth, dpi_);
    int inner = width - 2 * padding;
    int lineHeight = TextHeight(context, L"漢", inner, kWrap);
    int y = padding;
    auto row = [&](RECT* rect, int height) {
        *rect = {padding, y, padding + inner, y + height};
        y += height + gap;
    };
    row(&layout.title, TextHeight(context, Message("ai.scope.confirm"), inner, kWrap));
    row(&layout.destination, TextHeight(context, DestinationText(review_), inner, kWrap));
    row(&layout.targetLabel, lineHeight);
    int targetHeight = std::min(TextHeight(context, review_.target, inner - 2 * gap, kWrap), kTargetLines * lineHeight);
    row(&layout.target, targetHeight + gap);
    int box = GetSystemMetricsForDpi(SM_CXMENUCHECK, dpi_);
    row(&layout.context, std::max(lineHeight, box));
    layout.contextBox = {layout.context.left, layout.context.top + (layout.context.bottom - layout.context.top - box) / 2,
                         layout.context.left + box, 0};
    layout.contextBox.bottom = layout.contextBox.top + box;
    row(&layout.keyboard, TextHeight(context, Message("ai.scope.keyboard"), inner, kWrap));
    int buttonHeight = lineHeight + gap;
    int buttonPadding = ScaleForDpi(kButtonPadding, dpi_);
    int cancelWidth = TextWidth(context, Message("ai.scope.cancel")) + 2 * buttonPadding;
    int sendWidth = TextWidth(context, Message("ai.scope.send")) + 2 * buttonPadding;
    layout.cancel = {padding + inner - cancelWidth, y, padding + inner, y + buttonHeight};
    layout.send = {layout.cancel.left - gap - sendWidth, y, layout.cancel.left - gap, y + buttonHeight};
    layout.size = {width, y + buttonHeight + padding};
    return layout;
}

void AIReviewWindow::Show(const protocol::AIReview& review, bool includeContext, const RECT& caret, PopupSide side) {
    if (!EnsureWindow()) return;
    review_ = review;
    includeContext_ = includeContext;
    dpi_ = MonitorOfCaret(caret).dpi;
    HDC context = GetDC(window_);
    HGDIOBJ previousFont = SelectObject(context, font_.At(dpi_));
    layout_ = Measure(context);
    SelectObject(context, previousFont);
    ReleaseDC(window_, context);
    POINT origin = PlaceBesideCaret(layout_.size, caret, side, ScaleForDpi(kCaretGap, dpi_));
    SetWindowPos(window_, HWND_TOPMOST, origin.x, origin.y, layout_.size.cx, layout_.size.cy, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    InvalidateRect(window_, nullptr, TRUE);
    announcer_->Announce(SpokenText());
}

void AIReviewWindow::Hide() {
    if (window_) ShowWindow(window_, SW_HIDE);
    if (announcer_) announcer_->Forget();
}

std::wstring AIReviewWindow::SpokenText() const {
    const wchar_t* separator = L"\n";
    return Message("ai.scope.confirm") + separator + DestinationText(review_) + separator + Message("ai.scope.target") + L": " +
           review_.target + separator +
           Message(includeContext_ ? "ai.scope.include-context.on" : "ai.scope.include-context.off") + separator +
           Message("ai.scope.keyboard");
}

void AIReviewWindow::Paint() {
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

    HGDIOBJ previousFont = SelectObject(context, font_.At(dpi_));
    SetBkMode(context, TRANSPARENT);
    auto draw = [&](const std::wstring& text, RECT rect, uint32_t color, UINT format) {
        SetTextColor(context, ToColorRef(color));
        DrawTextW(context, text.c_str(), -1, &rect, format);
    };
    draw(Message("ai.scope.confirm"), layout_.title, palette.text, kWrap);
    draw(DestinationText(review_), layout_.destination, palette.text, kWrap);
    draw(Message("ai.scope.target"), layout_.targetLabel, palette.secondaryText, kWrap);

    HBRUSH surface = CreateSolidBrush(ToColorRef(palette.surface));
    FillRect(context, &layout_.target, surface);
    DeleteObject(surface);
    FrameRect(context, &layout_.target, border);
    RECT targetText = layout_.target;
    InflateRect(&targetText, -ScaleForDpi(kGap, dpi_) / 2, -ScaleForDpi(kGap, dpi_) / 2);
    draw(review_.target, targetText, palette.text, kWrap | DT_END_ELLIPSIS);

    RECT box = layout_.contextBox;
    DrawFrameControl(context, &box, DFC_BUTTON, DFCS_BUTTONCHECK | DFCS_FLAT | (includeContext_ ? DFCS_CHECKED : 0));
    RECT contextLabel = layout_.context;
    contextLabel.left = box.right + ScaleForDpi(kGap, dpi_);
    draw(Message("ai.scope.include-context"), contextLabel, palette.text, DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS);
    draw(Message("ai.scope.keyboard"), layout_.keyboard, palette.secondaryText, kWrap);

    int radius = ScaleForDpi(kCornerRadius, dpi_);
    auto button = [&](const RECT& rect, const std::wstring& label, uint32_t fill, uint32_t text) {
        HBRUSH fillBrush = CreateSolidBrush(ToColorRef(fill));
        HPEN pen = CreatePen(PS_SOLID, 1, ToColorRef(text));
        HGDIOBJ previousBrush = SelectObject(context, fillBrush);
        HGDIOBJ previousPen = SelectObject(context, pen);
        RoundRect(context, rect.left, rect.top, rect.right, rect.bottom, radius, radius);
        SelectObject(context, previousPen);
        SelectObject(context, previousBrush);
        DeleteObject(pen);
        DeleteObject(fillBrush);
        draw(label, rect, text, DT_SINGLELINE | DT_CENTER | DT_VCENTER | DT_NOPREFIX);
    };
    // Sending is the action the review exists for; it gets the selection colors.
    button(layout_.send, Message("ai.scope.send"), palette.selection, palette.selectionText);
    button(layout_.cancel, Message("ai.scope.cancel"), palette.surface, palette.text);
    SelectObject(context, previousFont);
    DeleteObject(border);
    EndPaint(window_, &paint);
}

void AIReviewWindow::Click(POINT point) {
    if (Contains(layout_.send, point)) {
        if (actions_.send) actions_.send();
    } else if (Contains(layout_.cancel, point)) {
        if (actions_.cancel) actions_.cancel();
    } else if (Contains(layout_.context, point)) {
        if (actions_.toggleContext) actions_.toggleContext();
    }
}

LRESULT CALLBACK AIReviewWindow::WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_NCCREATE) {
        auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto* self = reinterpret_cast<AIReviewWindow*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    switch (message) {
    case WM_MOUSEACTIVATE:
        // Clicking the review must not move focus away from the text being edited.
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
    case WM_LBUTTONUP:
        // The actions may hide or replace this window; nothing touches `self` afterwards.
        if (self) self->Click({GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)});
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
