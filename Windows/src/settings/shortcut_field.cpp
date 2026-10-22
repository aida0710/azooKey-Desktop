#include "shortcut_field.h"

#include <commctrl.h>

#include <utility>

namespace azookey::settings {
namespace {

constexpr UINT_PTR kSubclassId = 1;

bool IsDown(int virtualKey) { return (GetKeyState(virtualKey) & 0x8000) != 0; }

int CurrentModifiers() {
    int modifiers = 0;
    if (IsDown(VK_SHIFT)) modifiers |= Shortcut::kShift;
    if (IsDown(VK_CONTROL)) modifiers |= Shortcut::kControl;
    if (IsDown(VK_MENU)) modifiers |= Shortcut::kAlt;
    if (IsDown(VK_LWIN) || IsDown(VK_RWIN)) modifiers |= Shortcut::kWindows;
    return modifiers;
}

// Keys that move focus or answer the window keep working without Ctrl or Alt.
bool IsNavigationKey(const MSG* message) {
    if (!message || (message->message != WM_KEYDOWN && message->message != WM_CHAR)) return false;
    if (IsDown(VK_CONTROL) || IsDown(VK_MENU)) return false;
    UINT key = static_cast<UINT>(message->wParam);
    return message->message == WM_KEYDOWN ? (key == VK_TAB || key == VK_RETURN || key == VK_ESCAPE)
                                          : (key == L'\t' || key == L'\r' || key == 0x1B);
}

}  // namespace

ShortcutField::ShortcutField(HWND edit) : edit_(edit) {
    SetWindowSubclass(edit_, Procedure, kSubclassId, reinterpret_cast<DWORD_PTR>(this));
}

ShortcutField::~ShortcutField() { RemoveWindowSubclass(edit_, Procedure, kSubclassId); }

void ShortcutField::SetValue(std::optional<Shortcut> value) {
    value_ = std::move(value);
    SetWindowTextW(edit_, value_ ? ShortcutText(*value_).c_str() : L"");
}

bool ShortcutField::Record(UINT virtualKey) {
    wchar_t character = static_cast<wchar_t>(MapVirtualKeyW(virtualKey, MAPVK_VK_TO_CHAR) & 0xFFFF);
    auto shortcut = ShortcutForKeyPress(character, CurrentModifiers());
    if (!shortcut) return false;
    SetValue(*shortcut);
    return true;
}

LRESULT CALLBACK ShortcutField::Procedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam, UINT_PTR,
                                          DWORD_PTR selfPointer) {
    auto* self = reinterpret_cast<ShortcutField*>(selfPointer);
    switch (message) {
    case WM_GETDLGCODE:
        // Without this the dialog manager would take Alt+letter as an access key.
        if (IsNavigationKey(reinterpret_cast<const MSG*>(lParam))) break;
        return DLGC_WANTALLKEYS | DLGC_WANTCHARS;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
        if (self->Record(static_cast<UINT>(wParam))) return 0;
        // Modifier presses and keys that type nothing do not reach the read-only edit.
        if (message == WM_SYSKEYDOWN) return 0;
        break;
    case WM_CHAR:
    case WM_SYSCHAR:
        return 0;  // the characters of a recorded combination are not typed
    default:
        break;
    }
    return DefSubclassProc(window, message, wParam, lParam);
}

}  // namespace azookey::settings
