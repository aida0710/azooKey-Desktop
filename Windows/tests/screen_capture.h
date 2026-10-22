// Saves the screen, or a part of it, as a PNG through WIC, so windows can be
// reviewed from CI runs and machines without a desktop session.
#pragma once

#include <windows.h>

#include <string>

namespace azookey::tests {

// `region` is in screen coordinates. COM must be initialized on this thread.
bool SaveScreenRegionPng(const std::wstring& path, const RECT& region);
// The whole virtual screen (every monitor).
bool SaveScreenPng(const std::wstring& path);

}  // namespace azookey::tests
