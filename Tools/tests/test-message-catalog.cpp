// Checks the generated C++ message lookup used by the Windows screens.
#include "../../Windows/src/shared/message_catalog_data.h"

#include <cstdio>
#include <cstring>
#include <iterator>
#include <string>
#include <utility>
#include <vector>

namespace {

int failures = 0;

void Expect(bool condition, const char* description) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", description);
        ++failures;
    }
}

template <size_t Count>
bool IsSortedByKey(const azookey::messages::MessageEntry (&entries)[Count]) {
    for (size_t index = 1; index < Count; ++index) {
        if (std::strcmp(entries[index - 1].key, entries[index].key) >= 0) return false;
    }
    return true;
}

}  // namespace

int main() {
    using namespace azookey::messages;
    Expect(IsSortedByKey(kLocalizableMessages), "Localizable entries are sorted for binary search");
    Expect(IsSortedByKey(kUserDictionaryMessages), "UserDictionary entries are sorted for binary search");
    Expect(Text("candidate.position", Language::Japanese, {{L"position", L"2"}, {L"total", L"9"}}) == L"変換候補 2 / 9",
           "Japanese text fills named placeholders");
    Expect(Text("candidate.position", Language::English, {{L"position", L"2"}, {L"total", L"9"}}) == L"Candidates 2 / 9",
           "English text fills named placeholders");
    Expect(Text("reconversion.undo_menu", Language::English) == L"Undo the last commit (Ctrl+Shift+Backspace)",
           "Windows uses the base wording, not the macOS override");
    Expect(Text("title", Language::English, {}, Table::UserDictionary) == L"User dictionary", "UserDictionary table lookup");
    const std::vector<std::pair<std::wstring, std::wstring>> runtimeValues = {{L"line", L"3"}, {L"column", L"14"}};
    Expect(FillPlaceholders(Template("settings.invalid_json", Language::English), runtimeValues) ==
               Text("settings.invalid_json", Language::English, {{L"line", L"3"}, {L"column", L"14"}}),
           "values known only at run time fill a template like Text");
    Expect(Template("missing.key", Language::English) == L"missing.key", "Template keeps an unknown key visible");
    Expect(Text("missing.key", Language::Japanese) == L"missing.key", "an unknown key stays visible");
    Expect(FindMessage("missing.key") == nullptr, "FindMessage reports an unknown key");
    Expect(LanguageForLocaleName(L"ja-JP") == Language::Japanese, "ja-JP shows Japanese");
    Expect(LanguageForLocaleName(L"ja") == Language::Japanese, "ja shows Japanese");
    Expect(LanguageForLocaleName(L"jam-JM") == Language::English, "a language that only starts with ja is not Japanese");
    Expect(LanguageForLocaleName(L"en-US") == Language::English, "other languages show English");
    Expect(LanguageForLocaleName(L"") == Language::English, "an unknown language shows English");
    if (failures == 0) std::puts("PASS: generated message catalog lookup");
    return failures == 0 ? 0 : 1;
}
