// Captures the screen, or a part of it, and saves it as a PNG through WIC, so
// windows can be reviewed from CI runs and machines without a desktop session.
#pragma once

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

namespace azookey::tests {

// 32-bit BGRA pixels in top-down rows; every pixel is opaque.
struct ScreenImage {
    int width = 0;
    int height = 0;
    std::vector<uint8_t> pixels;
};

// `region` is in screen coordinates. Empty when the region is empty.
ScreenImage CaptureScreenRegion(const RECT& region);
// COM must be initialized on this thread.
bool SavePng(const std::wstring& path, const ScreenImage& image);

bool SaveScreenRegionPng(const std::wstring& path, const RECT& region);
// The whole virtual screen (every monitor).
bool SaveScreenPng(const std::wstring& path);

}  // namespace azookey::tests
