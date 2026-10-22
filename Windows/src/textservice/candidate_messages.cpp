#include "candidate_messages.h"

#include <cstring>

namespace azookey::tsf {
namespace {

struct Entry {
    const char* key;
    const wchar_t* text;
};

// Copied from Linux/azookey/locales/ja.json until the shared catalog exists.
constexpr Entry kEntries[] = {
    {"candidate.position", L"変換候補 {position} / {total}"},
    {"candidate.submit", L"確定"},
    {"candidate.previousPage", L"前へ"},
    {"candidate.nextPage", L"次へ"},
    {"candidate.selectHint", L"候補を選び、Enterで確定"},
};

}  // namespace

std::wstring CandidateMessage(const char* key, std::initializer_list<std::pair<const wchar_t*, std::wstring>> values) {
    std::wstring text;
    for (const auto& entry : kEntries) {
        if (std::strcmp(entry.key, key) == 0) text = entry.text;
    }
    for (const auto& [name, value] : values) {
        std::wstring placeholder = std::wstring(L"{") + name + L"}";
        for (size_t found = text.find(placeholder); found != std::wstring::npos; found = text.find(placeholder, found + value.size())) {
            text.replace(found, placeholder.size(), value);
        }
    }
    return text;
}

}  // namespace azookey::tsf
