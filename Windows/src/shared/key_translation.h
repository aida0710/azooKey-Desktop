// Decides what the IME does with a Windows key press and translates the keys
// it keeps into the Core key event contract (macOS virtual key codes), the
// same contract the Linux frontend uses. Pure logic so it is unit-testable.
#pragma once

#include <cstdint>
#include <optional>
#include <string>

namespace azookey::keys {

struct Modifiers {
    bool shift = false;
    bool control = false;
    bool alt = false;
};

struct KeyState {
    bool inputOpen = false;   // GUID_COMPARTMENT_KEYBOARD_OPENCLOSE
    bool composing = false;   // the converter holds a preedit or candidates
    bool privateInput = false;  // password and other protected fields
};

enum class KeyAction {
    PassThrough,      // the application receives the key unchanged
    SendToConverter,  // the key becomes a Core key event
    TurnInputOn,
    TurnInputOff,
    ToggleInput,
    PreviousPage,     // candidate paging stays inside the IME
    NextPage,
};

struct CoreKeyEvent {
    int keyCode = 0xFFFF;
    std::optional<std::string> characters;  // UTF-8
    int modifierFlags = 0;
};

// `typedText` is what the active keyboard layout produces for the key with
// Shift but without Ctrl/Alt (ToUnicodeEx); empty for non-character keys.
KeyAction Classify(uint32_t virtualKey, Modifiers modifiers, const std::wstring& typedText, KeyState state);

CoreKeyEvent Translate(uint32_t virtualKey, Modifiers modifiers, const std::wstring& typedText);

}  // namespace azookey::keys
