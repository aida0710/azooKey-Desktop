// Creating the standard controls of these windows and reading their text.
#pragma once

#include <windows.h>

#include <string>

namespace azookey::ui {

// A visible child control. Edits that take text get WS_TABSTOP from `style`.
HWND CreateChildControl(HWND parent, const wchar_t* className, const std::wstring& text, DWORD style, int id,
                        DWORD extendedStyle = 0);
std::wstring WindowText(HWND window);
// "Line 1\nLine 2" as a multi-line edit shows it ("\r\n").
std::wstring ToEditLineBreaks(const std::wstring& text);
// A multi-line edit's text with the "\n" line breaks the settings file uses.
std::wstring FromEditLineBreaks(const std::wstring& text);
void MoveControl(HWND control, int x, int y, int width, int height);

}  // namespace azookey::ui
