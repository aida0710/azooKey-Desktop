#include "child_controls.h"

namespace azookey::ui {

HWND CreateChildControl(HWND parent, const wchar_t* className, const std::wstring& text, DWORD style, int id,
                        DWORD extendedStyle) {
    return CreateWindowExW(extendedStyle, className, text.c_str(), WS_CHILD | WS_VISIBLE | style, 0, 0, 0, 0, parent,
                           reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
                           reinterpret_cast<HINSTANCE>(GetWindowLongPtrW(parent, GWLP_HINSTANCE)), nullptr);
}

std::wstring WindowText(HWND window) {
    int length = GetWindowTextLengthW(window);
    std::wstring text(static_cast<size_t>(length) + 1, L'\0');
    int copied = GetWindowTextW(window, text.data(), length + 1);
    text.resize(static_cast<size_t>(copied));
    return text;
}

std::wstring ToEditLineBreaks(const std::wstring& text) {
    std::wstring converted;
    converted.reserve(text.size());
    for (size_t index = 0; index < text.size(); ++index) {
        if (text[index] == L'\n' && (index == 0 || text[index - 1] != L'\r')) converted.push_back(L'\r');
        converted.push_back(text[index]);
    }
    return converted;
}

std::wstring FromEditLineBreaks(const std::wstring& text) {
    std::wstring converted;
    converted.reserve(text.size());
    for (size_t index = 0; index < text.size(); ++index) {
        if (text[index] == L'\r' && index + 1 < text.size() && text[index + 1] == L'\n') continue;
        converted.push_back(text[index]);
    }
    return converted;
}

void MoveControl(HWND control, int x, int y, int width, int height) {
    SetWindowPos(control, nullptr, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
}

}  // namespace azookey::ui
