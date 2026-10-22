#include "key_translation.h"

#include <algorithm>
#include <cctype>

#include "key_binding.h"
#include "text_encoding.h"

namespace azookey::keys {
namespace {

// Windows virtual keys used here, spelled out so this file needs no windows.h.
constexpr uint32_t kBack = 0x08, kTab = 0x09, kReturn = 0x0D, kShift = 0x10, kControl = 0x11, kMenu = 0x12;
constexpr uint32_t kPause = 0x13, kCapital = 0x14, kImeOn = 0x16, kKanji = 0x19, kImeOff = 0x1A, kEscape = 0x1B;
constexpr uint32_t kConvert = 0x1C, kNonConvert = 0x1D, kSpace = 0x20, kPrior = 0x21, kNext = 0x22;
constexpr uint32_t kLeft = 0x25, kUp = 0x26, kRight = 0x27, kDown = 0x28;
constexpr uint32_t kLeftWindows = 0x5B, kRightWindows = 0x5C, kApps = 0x5D;
constexpr uint32_t kF6 = 0x75, kF7 = 0x76, kF8 = 0x77, kF9 = 0x78, kF10 = 0x79;
constexpr uint32_t kNumLock = 0x90, kScroll = 0x91;
constexpr uint32_t kLeftShift = 0xA0, kRightMenu = 0xA5;
constexpr uint32_t kOem3 = 0xC0;  // ` on US layouts; Alt+` is the IME toggle there
constexpr uint32_t kOemAuto = 0xF3, kOemEnlw = 0xF4;  // 半角/全角 on JIS layouts

// macOS virtual key codes that Core understands (kVK_*).
constexpr int kCoreReturn = 36, kCoreTab = 48, kCoreSpace = 49, kCoreDelete = 51, kCoreEscape = 53;
constexpr int kCoreF6 = 97, kCoreF7 = 98, kCoreF8 = 100, kCoreF9 = 101, kCoreF10 = 109;
constexpr int kCoreLeft = 123, kCoreRight = 124, kCoreDown = 125, kCoreUp = 126;

bool IsModifierOnly(uint32_t key) {
    return key == kShift || key == kControl || key == kMenu || (key >= kLeftShift && key <= kRightMenu) ||
           key == kLeftWindows || key == kRightWindows || key == kApps || key == kCapital || key == kNumLock ||
           key == kScroll || key == kPause;
}

bool IsPrintable(const std::wstring& text) {
    return !text.empty() && text[0] >= 0x20 && text[0] != 0x7F;
}

int CoreDigitKeyCode(wchar_t digit) {
    // kVK_ANSI_1 ... kVK_ANSI_0; Core uses them for candidate number selection.
    static const int codes[] = {29, 18, 19, 20, 21, 23, 22, 26, 28, 25};
    return codes[digit - L'0'];
}

// Chords Core acts on with nothing composed. TSF has to answer before Core
// sees the key, so it matches them against Core's ime-shortcuts list.
bool IsCoreShortcut(uint32_t virtualKey, Modifiers modifiers, const std::wstring& typedText, const KeyState& state) {
    if (!modifiers.control && !modifiers.alt) return false;
    // Core's ReconversionShortcut is not in the list: Ctrl+Shift+Backspace undoes
    // the last commit and Ctrl+Shift+R reconverts the selection.
    bool reconversion = modifiers.control && modifiers.shift && !modifiers.alt && (virtualKey == kBack || virtualKey == 'R');
    if (reconversion) return true;
    // Before the list arrives: every Control chord, and Alt chords that could
    // open the instruction window for a selection.
    if (!state.coreShortcuts) return modifiers.control || state.hasSelection;
    const KeyBinding* binding = FindBinding(Translate(virtualKey, modifiers, typedText), *state.coreShortcuts);
    return binding && (binding->command != "prompt" || state.hasSelection);
}

}  // namespace

KeyAction Classify(uint32_t virtualKey, Modifiers modifiers, const std::wstring& typedText, KeyState state) {
    if (state.privateInput || IsModifierOnly(virtualKey)) return KeyAction::PassThrough;
    if (state.aiReviewOpen) return KeyAction::SendToConverter;
    if (virtualKey == kImeOn) return KeyAction::TurnInputOn;
    if (virtualKey == kImeOff) return KeyAction::TurnInputOff;
    if (virtualKey == kKanji || virtualKey == kOemAuto || virtualKey == kOemEnlw) return KeyAction::ToggleInput;
    if (modifiers.alt) {
        if (virtualKey == kOem3 && !modifiers.control) return KeyAction::ToggleInput;
        // Otherwise menu keys, except an instruction-window chord on a selection.
        bool coreChord = state.inputOpen && !state.composing && IsCoreShortcut(virtualKey, modifiers, typedText, state);
        return coreChord ? KeyAction::SendToConverter : KeyAction::PassThrough;
    }
    // Like the JIS keys on a Mac (英数/かな): 無変換 leaves Japanese input and
    // 変換 enters it. While composing, 変換 converts as Space does.
    if (virtualKey == kConvert) return state.composing ? KeyAction::SendToConverter : KeyAction::TurnInputOn;
    if (!state.inputOpen) return KeyAction::PassThrough;
    if (virtualKey == kNonConvert) return KeyAction::TurnInputOff;
    if (!state.composing) {
        if (IsCoreShortcut(virtualKey, modifiers, typedText, state)) return KeyAction::SendToConverter;
        return !modifiers.control && IsPrintable(typedText) ? KeyAction::SendToConverter : KeyAction::PassThrough;
    }
    if (virtualKey == kPrior) return KeyAction::PreviousPage;
    if (virtualKey == kNext) return KeyAction::NextPage;
    // Every other key belongs to the composition; letting it through would
    // edit the document underneath the preedit.
    return KeyAction::SendToConverter;
}

std::optional<std::string> CoreKeyEvent::CharactersIgnoringModifiers() const {
    if (!characters) return std::nullopt;
    std::string lowered = *characters;
    std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                   [](unsigned char c) { return static_cast<char>(c < 0x80 ? std::tolower(c) : c); });
    return lowered;
}

CoreKeyEvent Translate(uint32_t virtualKey, Modifiers modifiers, const std::wstring& typedText) {
    CoreKeyEvent event;
    event.modifierFlags = (modifiers.shift ? kShiftFlag : 0) | (modifiers.control ? kControlFlag : 0) |
                          (modifiers.alt ? kOptionFlag : 0);
    switch (virtualKey) {
    case kBack: event.keyCode = kCoreDelete; return event;
    case kTab: event.keyCode = kCoreTab; return event;
    case kReturn: event.keyCode = kCoreReturn; return event;
    case kEscape: event.keyCode = kCoreEscape; return event;
    case kLeft: event.keyCode = kCoreLeft; return event;
    case kRight: event.keyCode = kCoreRight; return event;
    case kUp: event.keyCode = kCoreUp; return event;
    case kDown: event.keyCode = kCoreDown; return event;
    case kF6: event.keyCode = kCoreF6; return event;
    case kF7: event.keyCode = kCoreF7; return event;
    case kF8: event.keyCode = kCoreF8; return event;
    case kF9: event.keyCode = kCoreF9; return event;
    case kF10: event.keyCode = kCoreF10; return event;
    case kSpace:
    case kConvert:
        event.keyCode = kCoreSpace;
        event.characters = " ";
        return event;
    default:
        break;
    }
    if (IsPrintable(typedText)) {
        event.characters = text::Utf16ToUtf8(typedText);
        if (typedText.size() == 1 && typedText[0] >= L'0' && typedText[0] <= L'9') {
            event.keyCode = CoreDigitKeyCode(typedText[0]);
        }
    }
    return event;
}

}  // namespace azookey::keys
