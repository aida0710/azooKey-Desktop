#include "text_encoding.h"

#include <cstdint>

namespace azookey::text {
namespace {

constexpr uint32_t kReplacementCharacter = 0xFFFD;

bool IsHighSurrogate(wchar_t unit) { return unit >= 0xD800 && unit <= 0xDBFF; }
bool IsLowSurrogate(wchar_t unit) { return unit >= 0xDC00 && unit <= 0xDFFF; }

// Decodes one scalar starting at `index`; malformed sequences become U+FFFD
// and consume one byte so decoding always makes progress.
uint32_t DecodeUtf8(const std::string& text, size_t* index) {
    auto byte = [&](size_t i) { return static_cast<unsigned char>(text[i]); };
    unsigned char lead = byte(*index);
    size_t length = lead < 0x80 ? 1 : (lead >> 5) == 0x6 ? 2 : (lead >> 4) == 0xE ? 3 : (lead >> 3) == 0x1E ? 4 : 0;
    if (length == 0 || *index + length > text.size()) {
        ++*index;
        return kReplacementCharacter;
    }
    uint32_t scalar = length == 1 ? lead : length == 2 ? (lead & 0x1F) : length == 3 ? (lead & 0x0F) : (lead & 0x07);
    for (size_t i = 1; i < length; ++i) {
        unsigned char next = byte(*index + i);
        if ((next & 0xC0) != 0x80) {
            ++*index;
            return kReplacementCharacter;
        }
        scalar = (scalar << 6) | (next & 0x3F);
    }
    static const uint32_t minimum[] = {0, 0, 0x80, 0x800, 0x10000};
    if (scalar < minimum[length] || scalar > 0x10FFFF || (scalar >= 0xD800 && scalar <= 0xDFFF)) {
        ++*index;
        return kReplacementCharacter;
    }
    *index += length;
    return scalar;
}

}  // namespace

std::wstring Utf8ToUtf16(const std::string& text) {
    std::wstring out;
    out.reserve(text.size());
    for (size_t index = 0; index < text.size();) {
        uint32_t scalar = DecodeUtf8(text, &index);
        if (scalar >= 0x10000) {
            scalar -= 0x10000;
            out.push_back(static_cast<wchar_t>(0xD800 + (scalar >> 10)));
            out.push_back(static_cast<wchar_t>(0xDC00 + (scalar & 0x3FF)));
        } else {
            out.push_back(static_cast<wchar_t>(scalar));
        }
    }
    return out;
}

std::string Utf16ToUtf8(const std::wstring& text) {
    std::string out;
    out.reserve(text.size() * 3);
    for (size_t i = 0; i < text.size(); ++i) {
        uint32_t scalar = text[i];
        if (IsHighSurrogate(text[i]) && i + 1 < text.size() && IsLowSurrogate(text[i + 1])) {
            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (text[i + 1] - 0xDC00);
            ++i;
        } else if (IsHighSurrogate(text[i]) || IsLowSurrogate(text[i])) {
            scalar = kReplacementCharacter;
        }
        if (scalar < 0x80) {
            out.push_back(static_cast<char>(scalar));
        } else if (scalar < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (scalar >> 6)));
            out.push_back(static_cast<char>(0x80 | (scalar & 0x3F)));
        } else if (scalar < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (scalar >> 12)));
            out.push_back(static_cast<char>(0x80 | ((scalar >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (scalar & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (scalar >> 18)));
            out.push_back(static_cast<char>(0x80 | ((scalar >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((scalar >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (scalar & 0x3F)));
        }
    }
    return out;
}

size_t ScalarOffsetToUtf16(const std::wstring& text, size_t scalarCount) {
    size_t units = 0;
    for (size_t scalars = 0; scalars < scalarCount && units < text.size(); ++scalars) {
        bool pair = IsHighSurrogate(text[units]) && units + 1 < text.size() && IsLowSurrogate(text[units + 1]);
        units += pair ? 2 : 1;
    }
    return units;
}

size_t ScalarCount(const std::wstring& text) {
    size_t count = 0;
    for (size_t i = 0; i < text.size(); ++i) {
        if (!(IsLowSurrogate(text[i]) && i > 0 && IsHighSurrogate(text[i - 1]))) ++count;
    }
    return count;
}

std::wstring LastScalars(const std::wstring& text, size_t scalarCount) {
    size_t total = ScalarCount(text);
    if (total <= scalarCount) return text;
    return text.substr(ScalarOffsetToUtf16(text, total - scalarCount));
}

std::wstring FirstScalars(const std::wstring& text, size_t scalarCount) {
    return text.substr(0, ScalarOffsetToUtf16(text, scalarCount));
}

}  // namespace azookey::text
