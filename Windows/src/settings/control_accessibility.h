// What screen readers announce for a control: its name (the label the eye
// reads beside it), its description, and live updates of status lines.
#pragma once

#include <windows.h>

#include <string>

namespace azookey::settings {

void SetAccessibleName(HWND control, const std::wstring& name);
void SetAccessibleDescription(HWND control, const std::wstring& description);
// Marks a status line whose changes are announced without moving focus.
void MakeLiveRegion(HWND control);
// Sets the status line's text and announces it.
void AnnounceText(HWND liveRegion, const std::wstring& text);

}  // namespace azookey::settings
