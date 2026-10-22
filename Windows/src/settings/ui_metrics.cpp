#include "ui_metrics.h"

#include <algorithm>

namespace azookey::settings {
namespace {

// Push buttons keep at least this width so short labels remain easy to hit.
constexpr int kMinimumButtonWidth = 88;
constexpr int kButtonHorizontalPadding = 24;
constexpr int kButtonHeight = 28;

HFONT CreateMessageFont(UINT dpi, LONG weight) {
    NONCLIENTMETRICSW metrics{sizeof(metrics)};
    SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, sizeof(metrics), &metrics, 0, dpi);
    metrics.lfMessageFont.lfWeight = weight;
    return CreateFontIndirectW(&metrics.lfMessageFont);
}

class ScreenContext {
public:
    explicit ScreenContext(HFONT font) : dc_(GetDC(nullptr)), previous_(SelectObject(dc_, font)) {}
    ~ScreenContext() {
        SelectObject(dc_, previous_);
        ReleaseDC(nullptr, dc_);
    }
    HDC get() const { return dc_; }

private:
    HDC dc_;
    HGDIOBJ previous_;
};

}  // namespace

UiMetrics::UiMetrics(UINT dpi) : dpi_(dpi) {
    font_ = CreateMessageFont(dpi, FW_NORMAL);
    headingFont_ = CreateMessageFont(dpi, FW_SEMIBOLD);
    ScreenContext context(font_);
    TEXTMETRICW text{};
    GetTextMetricsW(context.get(), &text);
    lineHeight_ = text.tmHeight + text.tmExternalLeading;
}

UiMetrics::~UiMetrics() {
    DeleteObject(font_);
    DeleteObject(headingFont_);
}

int UiMetrics::WrappedTextHeight(const std::wstring& text, int width, HFONT font) const {
    if (text.empty()) return 0;
    ScreenContext context(font);
    RECT bounds{0, 0, std::max(width, 1), 0};
    DrawTextW(context.get(), text.c_str(), static_cast<int>(text.size()), &bounds,
              DT_CALCRECT | DT_WORDBREAK | DT_EDITCONTROL | DT_NOPREFIX);
    return bounds.bottom - bounds.top;
}

int UiMetrics::TextWidth(const std::wstring& text, HFONT font) const {
    ScreenContext context(font);
    SIZE size{};
    GetTextExtentPoint32W(context.get(), text.c_str(), static_cast<int>(text.size()), &size);
    return size.cx;
}

SIZE UiMetrics::ButtonSize(const std::wstring& label) const {
    std::wstring shown;
    for (wchar_t character : label) {
        if (character != L'&') shown.push_back(character);  // access key markers take no space
    }
    int width = std::max(Scale(kMinimumButtonWidth), TextWidth(shown, font_) + Scale(kButtonHorizontalPadding));
    return {width, std::max(Scale(kButtonHeight), lineHeight_ + Scale(10))};
}

void ApplyFont(HWND window, HFONT font) {
    SendMessageW(window, WM_SETFONT, reinterpret_cast<WPARAM>(font), FALSE);
    EnumChildWindows(
        window,
        [](HWND child, LPARAM font) -> BOOL {
            SendMessageW(child, WM_SETFONT, static_cast<WPARAM>(font), FALSE);
            return TRUE;
        },
        reinterpret_cast<LPARAM>(font));
}

}  // namespace azookey::settings
