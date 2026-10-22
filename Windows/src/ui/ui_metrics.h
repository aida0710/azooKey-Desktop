// Sizes on these screens are written in 96-DPI pixels and scaled to the DPI of
// the monitor the window is on (Per-Monitor V2). The text uses the system's
// message font at that DPI.
#pragma once

#include <windows.h>

#include <string>

namespace azookey::ui {

class UiMetrics {
public:
    explicit UiMetrics(UINT dpi);
    ~UiMetrics();
    UiMetrics(const UiMetrics&) = delete;
    UiMetrics& operator=(const UiMetrics&) = delete;

    UINT dpi() const { return dpi_; }
    int Scale(int pixelsAt96Dpi) const { return MulDiv(pixelsAt96Dpi, static_cast<int>(dpi_), USER_DEFAULT_SCREEN_DPI); }
    HFONT font() const { return font_; }
    HFONT headingFont() const { return headingFont_; }

    // Height of `text` wrapped at `width` pixels in `font`.
    int WrappedTextHeight(const std::wstring& text, int width, HFONT font) const;
    // Width of `text` on one line in `font`.
    int TextWidth(const std::wstring& text, HFONT font) const;
    // Height of one line of the message font.
    int LineHeight() const { return lineHeight_; }
    // A single-line edit or drop-down list: one line plus the control's border and padding.
    int FieldHeight() const { return lineHeight_ + Scale(10); }
    // A push button sized to its label.
    SIZE ButtonSize(const std::wstring& label) const;

private:
    UINT dpi_;
    HFONT font_ = nullptr;
    HFONT headingFont_ = nullptr;
    int lineHeight_ = 0;
};

// Gives `window` and every child window `font`.
void ApplyFont(HWND window, HFONT font);

}  // namespace azookey::ui
