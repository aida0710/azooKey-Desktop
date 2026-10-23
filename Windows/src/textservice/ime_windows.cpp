#include "ime_windows.h"

#include <dwmapi.h>

#include <string>
#include <vector>

#include "module.h"

namespace azookey::tsf {
namespace {

std::vector<std::wstring> registeredClasses;

bool EnsureClass(const ImeWindowClass& windowClass) {
    for (const auto& name : registeredClasses) {
        if (name == windowClass.name) return true;
    }
    WNDCLASSEXW registration{sizeof(registration)};
    registration.style = CS_IME | windowClass.style;
    registration.lpfnWndProc = windowClass.procedure;
    registration.hInstance = ModuleInstance();
    registration.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    registration.lpszClassName = windowClass.name;
    if (!RegisterClassExW(&registration) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
    registeredClasses.push_back(windowClass.name);
    return true;
}

HWND CreatePopup(const ImeWindowClass& windowClass, void* owner, DWORD extraExtendedStyle) {
    if (!EnsureClass(windowClass)) return nullptr;
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    HWND window = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | extraExtendedStyle, windowClass.name,
                                  L"azooKey Tree", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, ModuleInstance(), owner);
    if (previous) SetThreadDpiAwarenessContext(previous);
    return window;
}

}  // namespace

HWND CreateImePopup(const ImeWindowClass& windowClass, void* owner) {
    HWND window = CreatePopup(windowClass, owner, 0);
    if (!window) return nullptr;
    DWM_WINDOW_CORNER_PREFERENCE corners = DWMWCP_ROUNDSMALL;
    DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE, &corners, sizeof(corners));
    return window;
}

HWND CreateImeLayeredPopup(const ImeWindowClass& windowClass, void* owner) {
    return CreatePopup(windowClass, owner, WS_EX_LAYERED);
}

MessageFont::~MessageFont() {
    if (font_) DeleteObject(font_);
}

HFONT MessageFont::At(UINT dpi) {
    if (font_ && dpi_ == dpi) return font_;
    if (font_) DeleteObject(font_);
    NONCLIENTMETRICSW metrics{sizeof(metrics)};
    SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, sizeof(metrics), &metrics, 0, dpi);
    font_ = CreateFontIndirectW(&metrics.lfMessageFont);
    dpi_ = dpi;
    return font_;
}

HWND CreateImeMessageWindow(const ImeWindowClass& windowClass, void* owner) {
    if (!EnsureClass(windowClass)) return nullptr;
    return CreateWindowExW(0, windowClass.name, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, ModuleInstance(), owner);
}

void UnregisterImeWindowClasses() {
    for (const auto& name : registeredClasses) UnregisterClassW(name.c_str(), ModuleInstance());
    registeredClasses.clear();
}

}  // namespace azookey::tsf
