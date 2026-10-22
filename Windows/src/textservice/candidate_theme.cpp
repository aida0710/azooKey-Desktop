#include "candidate_theme.h"

#include <windows.h>

namespace azookey::tsf {
namespace {

bool AppsUseDarkTheme() {
    DWORD value = 1;
    DWORD size = sizeof(value);
    // Missing value means the light default.
    RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                 L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size);
    return value == 0;
}

bool IsDarkColor(COLORREF color) {
    // Relative luminance below the midpoint reads as a dark background.
    double luminance = 0.2126 * GetRValue(color) + 0.7152 * GetGValue(color) + 0.0722 * GetBValue(color);
    return luminance < 128;
}

}  // namespace

CandidateAppearance CurrentCandidateAppearance() {
    HIGHCONTRASTW contrast{sizeof(contrast)};
    if (SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0) && (contrast.dwFlags & HCF_HIGHCONTRASTON)) {
        return IsDarkColor(GetSysColor(COLOR_WINDOW)) ? CandidateAppearance::HighContrastDark
                                                      : CandidateAppearance::HighContrastLight;
    }
    return AppsUseDarkTheme() ? CandidateAppearance::Dark : CandidateAppearance::Light;
}

const CandidatePalette& PaletteFor(CandidateAppearance appearance) {
    return kCandidatePalettes[static_cast<int>(appearance)];
}

bool IsHighContrast(CandidateAppearance appearance) {
    return appearance == CandidateAppearance::HighContrastLight || appearance == CandidateAppearance::HighContrastDark;
}

}  // namespace azookey::tsf
