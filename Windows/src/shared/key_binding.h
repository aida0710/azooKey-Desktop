// Core's DesktopKeyBinding: a chord and the command Core gives it. TSF has to
// decide whether a key is the IME's before Core sees it, so it matches keys
// against the bindings Core lists (ime-shortcuts, and the keys of an AI review).
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "key_translation.h"

namespace azookey::keys {

struct KeyBinding {
    std::optional<std::string> key;  // the unmodified character, lowercased (UTF-8)
    std::optional<int> keyCode;      // matched instead of `key` for keys without a character
    int modifiers = 0;               // Core's modifierFlags; must be equal, not a subset
    std::string command;             // "suggestion", "unicode", "prompt", "send", "toggleContext", "cancel"

    bool Matches(const CoreKeyEvent& event) const;
};

// The first binding `event` matches, as Core's DesktopKeyBinding.command(for:in:).
const KeyBinding* FindBinding(const CoreKeyEvent& event, const std::vector<KeyBinding>& bindings);

}  // namespace azookey::keys
