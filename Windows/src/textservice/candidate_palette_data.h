// Generated from Shared/CandidatePalettes.json. Run Tools/generate-candidate-palettes.py.
#pragma once

#include <cstdint>

namespace azookey::tsf {

// Colors are 0xRRGGBB sRGB values.
struct CandidatePalette {
    uint32_t background;
    uint32_t surface;
    uint32_t text;
    uint32_t secondaryText;
    uint32_t border;
    uint32_t selection;
    uint32_t selectionText;
    uint32_t scoreLow;
    uint32_t scoreHigh;
    uint32_t scoreUnknown;
    uint32_t scoreText;
};

enum class CandidateAppearance { Light, Dark, HighContrastLight, HighContrastDark };

inline constexpr CandidatePalette kCandidatePalettes[] = {
    {0xFFFFFF, 0xF6F5F9, 0x242433, 0x626171, 0x81798F, 0xEEE8FF, 0x35265E, 0x9A4600, 0x315D9C, 0x5B6068, 0xFFFFFF},  // light
    {0x202126, 0x2A2A34, 0xF3F1F9, 0xB8B6C8, 0x9891A9, 0x3C305B, 0xF3F1F9, 0x9A4600, 0x315D9C, 0x5B6068, 0xFFFFFF},  // dark
    {0xFFFFFF, 0xFFFFFF, 0x000000, 0x000000, 0x595959, 0x000000, 0xFFFFFF, 0x703000, 0x003D80, 0x454545, 0xFFFFFF},  // highContrastLight
    {0x000000, 0x000000, 0xFFFFFF, 0xFFFFFF, 0xAAAAAA, 0xFFFFFF, 0x000000, 0xFED7AA, 0xBEDBFF, 0xDEDEDE, 0x000000},  // highContrastDark
};

}  // namespace azookey::tsf
