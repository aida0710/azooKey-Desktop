#include "ui_language.h"

#include <windows.h>

#include <vector>

namespace azookey::messages {

Language CurrentUiLanguage() {
    ULONG count = 0;
    ULONG length = 0;
    if (!GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, nullptr, &length) || length == 0) return Language::English;
    std::vector<wchar_t> names(length);
    if (!GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, names.data(), &length) || count == 0) return Language::English;
    // The buffer is a list of NUL-terminated names; the first is the preferred one.
    return LanguageForLocaleName(names.data());
}

}  // namespace azookey::messages
