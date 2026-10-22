#include "key_translation.h"

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
constexpr int kShiftFlag = 1 << 0, kControlFlag = 1 << 1, kOptionFlag = 1 << 2;

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

}  // namespace

KeyAction Classify(uint32_t virtualKey, Modifiers modifiers, const std::wstring& typedText, KeyState state) {
    if (state.privateInput || IsModifierOnly(virtualKey)) return KeyAction::PassThrough;
    if (virtualKey == kImeOn) return KeyAction::TurnInputOn;
    if (virtualKey == kImeOff) return KeyAction::TurnInputOff;
    if (virtualKey == kKanji || virtualKey == kOemAuto || virtualKey == kOemEnlw) return KeyAction::ToggleInput;
    if (modifiers.alt) {
        return virtualKey == kOem3 && !modifiers.control ? KeyAction::ToggleInput : KeyAction::PassThrough;
    }
    if (!state.inputOpen) return KeyAction::PassThrough;
    // Like the JIS keys on a Mac (英数/かな): 無変換 leaves Japanese input and
    // 変換 enters it. While composing, 変換 converts as Space does.
    if (virtualKey == kNonConvert) return KeyAction::TurnInputOff;
    if (virtualKey == kConvert) return state.composing ? KeyAction::SendToConverter : KeyAction::TurnInputOn;
    if (!state.composing) {
        return !modifiers.control && IsPrintable(typedText) ? KeyAction::SendToConverter : KeyAction::PassThrough;
    }
    if (virtualKey == kPrior) return KeyAction::PreviousPage;
    if (virtualKey == kNext) return KeyAction::NextPage;
    // Every other key belongs to the composition; letting it through would
    // edit the document underneath the preedit.
    return KeyAction::SendToConverter;
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
