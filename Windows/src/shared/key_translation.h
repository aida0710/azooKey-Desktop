// Decides what the IME does with a Windows key press and translates the keys
// it keeps into the Core key event contract (macOS virtual key codes), the
// same contract the Linux frontend uses. Pure logic so it is unit-testable.
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace azookey::keys {

struct Modifiers {
    bool shift = false;
    bool control = false;
    bool alt = false;
};

struct KeyBinding;

struct KeyState {
    bool inputOpen = false;   // GUID_COMPARTMENT_KEYBOARD_OPENCLOSE
    bool composing = false;   // the converter holds a preedit, candidates or a reading being typed
    bool privateInput = false;  // password and other protected fields
    bool hasSelection = false;  // read only for Ctrl/Alt chords outside a composition
    bool aiReviewOpen = false;  // every key goes to the review first (it closes on keys it does not bind)
    // Core's ime-shortcuts list; nullptr until it arrives, when every Control
    // chord goes to Core rather than being guessed away to the application.
    const std::vector<KeyBinding>* coreShortcuts = nullptr;
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

    // What Core compares chords against: the characters with ASCII letters
    // lowercased, as macOS reports them without Shift.
    std::optional<std::string> CharactersIgnoringModifiers() const;
};

// Core's modifierFlags bits.
inline constexpr int kShiftFlag = 1 << 0, kControlFlag = 1 << 1, kOptionFlag = 1 << 2;

// `typedText` is what the active keyboard layout produces for the key with
// Shift but without Ctrl/Alt (ToUnicodeEx); empty for non-character keys.
KeyAction Classify(uint32_t virtualKey, Modifiers modifiers, const std::wstring& typedText, KeyState state);

CoreKeyEvent Translate(uint32_t virtualKey, Modifiers modifiers, const std::wstring& typedText);

}  // namespace azookey::keys
