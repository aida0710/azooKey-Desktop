#include "notice_window.h"

// WIN32_LEAN_AND_MEAN leaves out the COM declarations UI Automation needs.
#include <ole2.h>
#include <dwmapi.h>
#include <shellscalingapi.h>
#include <uiautomation.h>

#include <algorithm>

#include "candidate_theme.h"
#include "module.h"

namespace azookey::tsf {
namespace {

constexpr wchar_t kWindowClassName[] = L"azooKeyTreeNotice";
bool windowClassRegistered = false;

// Space around the text, and between the caret and the notice, in DIPs; the
// same rhythm as the candidate panel's footer.
constexpr int kHorizontalPadding = 8;
constexpr int kVerticalPadding = 4;
constexpr int kCaretGap = 4;

int Scale(int dips, UINT dpi) { return MulDiv(dips, static_cast<int>(dpi), 96); }

COLORREF ToColorRef(uint32_t rgb) { return RGB((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF); }

VARIANT StringVariant(const std::wstring& text) {
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_BSTR;
    value.bstrVal = SysAllocString(text.c_str());
    return value;
}

VARIANT IntegerVariant(LONG number) {
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_I4;
    value.lVal = number;
    return value;
}

}  // namespace

// The notice as UI Automation sees it: static text that speaks up when it changes.
class NoticeWindow::Provider final : public IRawElementProviderSimple {
public:
    explicit Provider(NoticeWindow* owner) : owner_(owner) { AddModuleReference(); }

    void Detach() { owner_ = nullptr; }

    STDMETHODIMP QueryInterface(REFIID riid, void** object) override {
        if (!object) return E_INVALIDARG;
        *object = nullptr;
        if (riid != IID_IUnknown && riid != IID_IRawElementProviderSimple) return E_NOINTERFACE;
        *object = static_cast<IRawElementProviderSimple*>(this);
        AddRef();
        return S_OK;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&references_); }
    STDMETHODIMP_(ULONG) Release() override {
        LONG remaining = InterlockedDecrement(&references_);
        if (remaining == 0) delete this;
        return remaining;
    }

    STDMETHODIMP get_ProviderOptions(ProviderOptions* options) override {
        *options = ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading;
        return S_OK;
    }
    STDMETHODIMP GetPatternProvider(PATTERNID, IUnknown** provider) override {
        *provider = nullptr;
        return S_OK;
    }
    STDMETHODIMP GetPropertyValue(PROPERTYID property, VARIANT* value) override {
        VariantInit(value);
        if (!owner_) return UIA_E_ELEMENTNOTAVAILABLE;
        if (property == UIA_ControlTypePropertyId) *value = IntegerVariant(UIA_TextControlTypeId);
        else if (property == UIA_NamePropertyId) *value = StringVariant(owner_->text_);
        else if (property == UIA_LiveSettingPropertyId) *value = IntegerVariant(Assertive);
        return S_OK;
    }
    STDMETHODIMP get_HostRawElementProvider(IRawElementProviderSimple** provider) override {
        if (!owner_) return UIA_E_ELEMENTNOTAVAILABLE;
        return UiaHostProviderFromHwnd(owner_->window_, provider);
    }

private:
    ~Provider() { ReleaseModuleReference(); }
    LONG references_ = 1;
    NoticeWindow* owner_;
};

NoticeWindow::~NoticeWindow() {
    // The provider refers to the window, so it goes first.
    if (provider_) {
        UiaDisconnectProvider(provider_);
        provider_->Detach();
        provider_->Release();
    }
    if (window_) DestroyWindow(window_);
    if (font_) DeleteObject(font_);
}

void NoticeWindow::UnregisterWindowClass() {
    if (windowClassRegistered) {
        UnregisterClassW(kWindowClassName, ModuleInstance());
        windowClassRegistered = false;
    }
}

bool NoticeWindow::EnsureWindow() {
    if (window_) return true;
    if (!windowClassRegistered) {
        WNDCLASSEXW windowClass{sizeof(windowClass)};
        windowClass.style = CS_IME;
        windowClass.lpfnWndProc = WindowProcedure;
        windowClass.hInstance = ModuleInstance();
        windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        windowClass.lpszClassName = kWindowClassName;
        windowClassRegistered = RegisterClassExW(&windowClass) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
        if (!windowClassRegistered) return false;
    }
    // Per-monitor DPI aware whatever the host application declares, like the candidate panel.
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    window_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kWindowClassName, L"azooKey Tree",
                              WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, ModuleInstance(), this);
    if (previous) SetThreadDpiAwarenessContext(previous);
    if (!window_) return false;
    DWM_WINDOW_CORNER_PREFERENCE corners = DWMWCP_ROUNDSMALL;
    DwmSetWindowAttribute(window_, DWMWA_WINDOW_CORNER_PREFERENCE, &corners, sizeof(corners));
    provider_ = new Provider(this);
    return true;
}

HFONT NoticeWindow::FontFor(UINT dpi) {
    if (font_ && fontDpi_ == dpi) return font_;
    if (font_) DeleteObject(font_);
    // The system message font, so the notice follows the text-size setting.
    NONCLIENTMETRICSW metrics{sizeof(metrics)};
    SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, sizeof(metrics), &metrics, 0, dpi);
    font_ = CreateFontIndirectW(&metrics.lfMessageFont);
    fontDpi_ = dpi;
    return font_;
}

void NoticeWindow::Show(const std::wstring& text, const RECT& caret, NoticePlacement placement) {
    if (text.empty()) {
        Hide();
        return;
    }
    if (!EnsureWindow()) return;
    bool changed = text != text_ || !visible();
    text_ = text;

    HMONITOR monitor = MonitorFromPoint({caret.left, caret.bottom}, MONITOR_DEFAULTTONEAREST);
    UINT dpi = 96, unused = 96;
    GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi, &unused);
    MONITORINFO info{sizeof(info)};
    GetMonitorInfoW(monitor, &info);

    HDC context = GetDC(window_);
    HGDIOBJ previousFont = SelectObject(context, FontFor(dpi));
    RECT measured{};
    DrawTextW(context, text_.c_str(), -1, &measured, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
    SelectObject(context, previousFont);
    ReleaseDC(window_, context);

    const RECT& work = info.rcWork;
    int width = std::min<int>(measured.right + 2 * Scale(kHorizontalPadding, dpi), work.right - work.left);
    int height = measured.bottom + 2 * Scale(kVerticalPadding, dpi);
    int gap = Scale(kCaretGap, dpi);
    int x = std::clamp<int>(caret.left, work.left, std::max<int>(work.left, work.right - width));
    int below = caret.bottom + gap;
    int above = caret.top - gap - height;
    bool fitsBelow = below + height <= work.bottom;
    bool fitsAbove = above >= work.top;
    bool useAbove = placement == NoticePlacement::AboveCaret ? fitsAbove || !fitsBelow : !fitsBelow && fitsAbove;
    int y = std::clamp<int>(useAbove ? above : below, work.top, std::max<int>(work.top, work.bottom - height));
    SetWindowPos(window_, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    InvalidateRect(window_, nullptr, TRUE);
    if (changed) Announce();
}

void NoticeWindow::Hide() {
    if (window_) ShowWindow(window_, SW_HIDE);
    text_.clear();
}

void NoticeWindow::Announce() {
    if (!provider_ || !UiaClientsAreListening()) return;
    // The notice never has focus, so a notification is how screen readers hear it.
    BSTR text = SysAllocString(text_.c_str());
    BSTR activity = SysAllocString(L"azooKeyTree.notice");
    UiaRaiseNotificationEvent(provider_, NotificationKind_Other, NotificationProcessing_ImportantMostRecent, text, activity);
    SysFreeString(activity);
    SysFreeString(text);
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
    HGDIOBJ previousFont = SelectObject(context, FontFor(fontDpi_ ? fontDpi_ : 96));
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
        if (self && self->provider_ && static_cast<long>(lParam) == static_cast<long>(UiaRootObjectId)) {
            return UiaReturnRawElementProvider(window, wParam, lParam, self->provider_);
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
