#include "top_level_window.h"

#include <algorithm>

#include "dialog_colors.h"

namespace azookey::ui {
namespace {

// Below this the controls of the smallest window no longer fit side by side.
constexpr int kMinimumWidth = 480;
constexpr int kMinimumHeight = 360;

bool IsPushButton(HWND control) {
    wchar_t className[16] = {};
    GetClassNameW(control, className, static_cast<int>(std::size(className)));
    if (_wcsicmp(className, L"Button") != 0) return false;
    LONG type = GetWindowLongW(control, GWL_STYLE) & BS_TYPEMASK;
    return type == BS_PUSHBUTTON || type == BS_DEFPUSHBUTTON;
}

// Centers `window` over `owner`, or leaves the system's default position.
void PlaceWindow(HWND window, HWND owner, SIZE size) {
    RECT bounds{};
    GetWindowRect(window, &bounds);
    int x = bounds.left;
    int y = bounds.top;
    if (owner) {
        RECT ownerBounds{};
        GetWindowRect(owner, &ownerBounds);
        x = ownerBounds.left + (ownerBounds.right - ownerBounds.left - size.cx) / 2;
        y = ownerBounds.top + (ownerBounds.bottom - ownerBounds.top - size.cy) / 2;
    }
    MONITORINFO monitor{sizeof(monitor)};
    GetMonitorInfoW(MonitorFromWindow(owner ? owner : window, MONITOR_DEFAULTTONEAREST), &monitor);
    const int left = monitor.rcWork.left;
    const int top = monitor.rcWork.top;
    const int width = static_cast<int>(size.cx);
    const int height = static_cast<int>(size.cy);
    x = std::clamp(x, left, std::max(left, static_cast<int>(monitor.rcWork.right) - width));
    y = std::clamp(y, top, std::max(top, static_cast<int>(monitor.rcWork.bottom) - height));
    SetWindowPos(window, nullptr, x, y, size.cx, size.cy, SWP_NOZORDER | SWP_NOACTIVATE);
}

}  // namespace

void TopLevelWindow::RegisterWindowClass(HINSTANCE instance, const wchar_t* className, HICON icon) {
    WNDCLASSEXW windowClass{sizeof(windowClass)};
    windowClass.lpfnWndProc = Procedure;
    windowClass.hInstance = instance;
    windowClass.hIcon = icon;
    windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    windowClass.hbrBackground = reinterpret_cast<HBRUSH>(static_cast<INT_PTR>(kDialogBackgroundColor + 1));
    windowClass.lpszClassName = className;
    RegisterClassExW(&windowClass);
}

TopLevelWindow::~TopLevelWindow() {
    if (window_) {
        SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
        DestroyWindow(window_);
    }
}

bool TopLevelWindow::Create(const wchar_t* className, const std::wstring& title, HWND owner, SIZE clientSizeAt96Dpi) {
    CreateWindowExW(WS_EX_CONTROLPARENT, className, title.c_str(), WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, CW_USEDEFAULT,
                    CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, owner, nullptr, GetModuleHandleW(nullptr), this);
    if (!window_) return false;
    RECT bounds{0, 0, metrics_->Scale(clientSizeAt96Dpi.cx), metrics_->Scale(clientSizeAt96Dpi.cy)};
    AdjustWindowRectExForDpi(&bounds, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_CONTROLPARENT, metrics_->dpi());
    PlaceWindow(window_, owner, {bounds.right - bounds.left, bounds.bottom - bounds.top});
    return true;
}

void TopLevelWindow::ReplaceMetrics(UINT dpi) {
    metrics_ = std::make_unique<UiMetrics>(dpi);
    ApplyFont(window_, metrics_->font());
    OnFontsChanged();
}

bool TopLevelWindow::HandleMessage(UINT, WPARAM, LPARAM, LRESULT*) { return false; }

LRESULT CALLBACK TopLevelWindow::Procedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_NCCREATE) {
        auto* self = static_cast<TopLevelWindow*>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams);
        self->window_ = window;
        self->metrics_ = std::make_unique<UiMetrics>(GetDpiForWindow(window));
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    }
    auto* self = reinterpret_cast<TopLevelWindow*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (!self) return DefWindowProcW(window, message, wParam, lParam);
    return self->Handle(message, wParam, lParam);
}

LRESULT TopLevelWindow::Handle(UINT message, WPARAM wParam, LPARAM lParam) {
    HWND window = window_;
    LRESULT result = 0;
    if (HandleMessage(message, wParam, lParam, &result)) return result;
    switch (message) {
    case WM_SIZE:
        if (wParam != SIZE_MINIMIZED) Layout();
        return 0;
    case WM_DPICHANGED: {
        ReplaceMetrics(HIWORD(wParam));
        const RECT* suggested = reinterpret_cast<const RECT*>(lParam);
        SetWindowPos(window, nullptr, suggested->left, suggested->top, suggested->right - suggested->left,
                     suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
        Layout();
        return 0;
    }
    case WM_SETTINGCHANGE:
        if (wParam == SPI_SETNONCLIENTMETRICS) {
            ReplaceMetrics(metrics_->dpi());
            Layout();
        }
        break;
    case WM_SYSCOLORCHANGE:
    case WM_THEMECHANGED:
        InvalidateRect(window, nullptr, TRUE);
        break;
    case WM_GETMINMAXINFO:
        if (metrics_) {
            auto* limits = reinterpret_cast<MINMAXINFO*>(lParam);
            limits->ptMinTrackSize = {metrics_->Scale(kMinimumWidth), metrics_->Scale(kMinimumHeight)};
        }
        return 0;
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLORBTN:
        return DialogControlColors(wParam);
    case WM_COMMAND:
        // The dialog manager sends IDOK for Enter and IDCANCEL for Escape.
        if (LOWORD(wParam) == IDOK && IsPushButton(GetFocus())) {
            SendMessageW(GetFocus(), BM_CLICK, 0, 0);
            return 0;
        }
        if (LOWORD(wParam) == IDCANCEL) {
            OnCancel();
            return 0;
        }
        break;
    case WM_ACTIVATE:
        if (LOWORD(wParam) == WA_INACTIVE) {
            HWND focus = GetFocus();
            if (focus && IsChild(window, focus)) lastFocus_ = focus;
        } else if (lastFocus_ && IsWindow(lastFocus_) && IsChild(window, lastFocus_) && !HIWORD(wParam)) {
            SetFocus(lastFocus_);
            return 0;
        }
        break;
    case WM_CLOSE:
        OnCancel();
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

bool TranslateDialogKeys(MSG* message) {
    HWND root = GetAncestor(message->hwnd, GA_ROOT);
    return root && IsDialogMessageW(root, message);
}

void RunModalLoop(HWND owner, const bool& finished) {
    if (owner) EnableWindow(owner, FALSE);
    MSG message;
    while (!finished) {
        BOOL received = GetMessageW(&message, nullptr, 0, 0);
        if (received <= 0) {
            // Leave WM_QUIT for the application's own loop.
            if (received == 0) PostQuitMessage(static_cast<int>(message.wParam));
            break;
        }
        if (TranslateDialogKeys(&message)) continue;
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    if (owner) {
        EnableWindow(owner, TRUE);
        SetActiveWindow(owner);
    }
}

}  // namespace azookey::ui
