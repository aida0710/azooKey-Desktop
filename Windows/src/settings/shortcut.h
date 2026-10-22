// Core's KeyboardShortcut ({"key": "s", "modifiers": 2}) as the screen reads,
// shows and records it. Modifier bits follow KeyEventCore.ModifierFlag.
#pragma once

#include <optional>
#include <string>

#include "../shared/json.h"

namespace azookey::settings {

struct Shortcut {
    static constexpr int kShift = 1 << 0;
    static constexpr int kControl = 1 << 1;
    static constexpr int kAlt = 1 << 2;      // Core's option
    static constexpr int kWindows = 1 << 3;  // Core's command

    std::wstring key;  // the character of the key without modifiers, lowercase for letters
    int modifiers = 0;

    bool operator==(const Shortcut&) const = default;
};

std::optional<Shortcut> ShortcutFromJson(const json::Value& value);
json::Value ShortcutToJson(const Shortcut& shortcut);

// "Ctrl+Alt+E", in the order Windows lists modifiers.
std::wstring ShortcutText(const Shortcut& shortcut);

// The shortcut a key press records. `character` is what the key types without
// modifiers (MapVirtualKey); 0 for keys that type nothing. Returns nullopt for
// a press that cannot be a shortcut: no character, or no modifier at all, as
// on Linux.
std::optional<Shortcut> ShortcutForKeyPress(wchar_t character, int modifiers);

}  // namespace azookey::settings
