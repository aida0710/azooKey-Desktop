#!/usr/bin/env python3
"""Generate renderer data from one sRGB palette; no runtime resource lookup."""
import argparse
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
PALETTE_SOURCE = ROOT / "Shared/CandidatePalettes.json"
GENERATED_NOTICE = "Generated from Shared/CandidatePalettes.json. Run Tools/generate-candidate-palettes.py."
MODES = {"light", "dark", "highContrastLight", "highContrastDark"}
ROLES = {
    "background", "surface", "text", "secondaryText", "border", "selection", "selectionText",
    "scoreLow", "scoreHigh", "scoreUnknown", "scoreText",
}


def load_palettes():
    palettes = json.loads(PALETTE_SOURCE.read_text())
    assert palettes.keys() == MODES, "all four appearances are required"
    for colors in palettes.values():
        assert colors.keys() == ROLES, "every appearance must define the same color roles"
        assert all(re.fullmatch(r"#[0-9A-F]{6}", value) for value in colors.values()), "use opaque sRGB hex colors"
    return palettes


def swift_source(palettes):
    roles = list(next(iter(palettes.values())))
    lines = [f"// {GENERATED_NOTICE}", "import AppKit", "", "@MainActor", "struct CandidatePalette {"]
    lines += [f"    let {role}: NSColor" for role in roles]
    lines += ["}", "", "@MainActor", "enum CandidatePaletteData {", "    static let palettes: [String: CandidatePalette] = ["]
    for mode_index, (mode, colors) in enumerate(palettes.items()):
        lines.append(f'        "{mode}": CandidatePalette(')
        for index, (role, color) in enumerate(colors.items()):
            red, green, blue = (int(color[start:start + 2], 16) / 255 for start in (1, 3, 5))
            comma = "," if index + 1 < len(roles) else ""
            lines.append(f"            {role}: NSColor(srgbRed: {red:.9f}, green: {green:.9f}, blue: {blue:.9f}, alpha: 1){comma}")
        lines.append("        )" + ("," if mode_index + 1 < len(palettes) else ""))
    lines += ["    ]", "}", ""]
    return "\n".join(lines)


def cpp_identifier(name):
    return name[0].upper() + name[1:]


def cpp_source(palettes):
    roles = list(next(iter(palettes.values())))
    modes = list(palettes)
    lines = [f"// {GENERATED_NOTICE}", "#pragma once", "", "#include <cstdint>", "", "namespace azookey::tsf {", ""]
    lines.append("// Colors are 0xRRGGBB sRGB values.")
    lines.append("struct CandidatePalette {")
    lines += [f"    uint32_t {role};" for role in roles]
    lines += ["};", ""]
    lines.append("enum class CandidateAppearance { " + ", ".join(cpp_identifier(mode) for mode in modes) + " };")
    lines += ["", "inline constexpr CandidatePalette kCandidatePalettes[] = {"]
    for mode in modes:
        values = ", ".join(f"0x{palettes[mode][role][1:]}" for role in roles)
        lines.append(f"    {{{values}}},  // {mode}")
    lines += ["};", "", "}  // namespace azookey::tsf", ""]
    return "\n".join(lines)


def generated_sources(palettes):
    document = json.dumps(palettes, ensure_ascii=False, indent=4)
    return {
        "Linux/azookey/candidate_palette_data.py": f"# {GENERATED_NOTICE}\nPALETTES = {document}\n",
        "Linux/gnome-extension/candidatePaletteData.js": f"// {GENERATED_NOTICE}\nexport const PALETTES = {document};\n",
        "azooKeyMac/InputController/CandidateWindow/CandidatePaletteData.swift": swift_source(palettes),
        "Windows/src/textservice/candidate_palette_data.h": cpp_source(palettes),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    changed = []
    for relative, source in generated_sources(load_palettes()).items():
        path = ROOT / relative
        if arguments.check:
            if not path.exists() or path.read_text() != source:
                changed.append(relative)
        else:
            path.write_text(source)
    if changed:
        parser.exit(1, "Palette data needs regeneration: " + ", ".join(changed) + "\n")


if __name__ == "__main__":
    main()
