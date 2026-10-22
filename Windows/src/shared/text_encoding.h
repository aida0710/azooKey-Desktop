// Conversions between the bridge's UTF-8 strings and TSF's UTF-16 ranges.
// The bridge reports the caret in Unicode scalars (code points), while TSF
// ranges count UTF-16 code units, so characters outside the BMP (emoji, 𠮷)
// take two units on the Windows side.
#pragma once

#include <string>

namespace azookey::text {

std::wstring Utf8ToUtf16(const std::string& text);
std::string Utf16ToUtf8(const std::wstring& text);

// Number of UTF-16 code units covering the first `scalarCount` scalars of
// `text`. Counts past the end clamp to the whole string.
size_t ScalarOffsetToUtf16(const std::wstring& text, size_t scalarCount);

}  // namespace azookey::text
