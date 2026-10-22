// A read-only edit that records the key combination pressed while it has
// focus and shows it as "Ctrl+Alt+E". Tab, Shift+Tab, Enter and Escape keep
// their usual meaning so the field never traps keyboard users.
#pragma once

#include <windows.h>

#include <optional>

#include "shortcut.h"

namespace azookey::settings {

class ShortcutField {
public:
    // Takes over `edit`, which must be a read-only edit control.
    explicit ShortcutField(HWND edit);
    ~ShortcutField();
    ShortcutField(const ShortcutField&) = delete;
    ShortcutField& operator=(const ShortcutField&) = delete;

    HWND window() const { return edit_; }
    const std::optional<Shortcut>& value() const { return value_; }
    void SetValue(std::optional<Shortcut> value);

private:
    static LRESULT CALLBACK Procedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam, UINT_PTR id,
                                      DWORD_PTR self);
    // Records the press when it makes a shortcut; returns true when the key was used.
    bool Record(UINT virtualKey);

    HWND edit_;
    std::optional<Shortcut> value_;
};

}  // namespace azookey::settings
