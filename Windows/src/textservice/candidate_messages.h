// Candidate panel wording, keyed like Linux/azookey/locales/ja.json so the
// shared message catalog can replace this table without touching callers.
#pragma once

#include <string>

namespace azookey::tsf {

// Returns the Japanese text for `key` with "{name}" placeholders replaced.
std::wstring CandidateMessage(const char* key, std::initializer_list<std::pair<const wchar_t*, std::wstring>> values = {});

}  // namespace azookey::tsf
