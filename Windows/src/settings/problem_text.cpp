#include "problem_text.h"

#include "../shared/text_encoding.h"

namespace azookey::settings {
namespace {

// "userDictionary.items[3].reading" names the setting "userDictionary".
std::string SettingKeyOfField(const std::wstring& field) {
    std::string key = text::Utf16ToUtf8(field);
    size_t end = key.find_first_of(".[");
    return end == std::string::npos ? key : key.substr(0, end);
}

std::wstring FieldLabel(const std::wstring& field, messages::Language language, const Schema* schema) {
    const SettingItem* item = schema ? schema->FindItem(SettingKeyOfField(field)) : nullptr;
    if (!item) return field;
    std::wstring label = messages::Template(item->labelKey, language);
    // A label with its own placeholders ("… ({count} entries)") would read worse than the key.
    return label.find(L'{') == std::wstring::npos ? label : field;
}

}  // namespace

std::wstring ProblemText(const Problem& problem, messages::Language language, const Schema* schema) {
    auto arguments = problem.arguments;
    for (auto& [name, value] : arguments) {
        if (name == L"field") value = FieldLabel(value, language, schema);
    }
    return messages::FillPlaceholders(messages::Template(problem.messageKey, language), arguments);
}

}  // namespace azookey::settings
