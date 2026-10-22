// Puts text on the clipboard as Unicode text.
#pragma once

#include <windows.h>

#include <string>

namespace azookey::ui {

// `owner` is a window of this process; returns false when the clipboard is busy.
bool CopyTextToClipboard(HWND owner, const std::wstring& text);

}  // namespace azookey::ui
