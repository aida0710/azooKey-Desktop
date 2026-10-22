#include "dictionary_text.h"

namespace azookey::settings {

std::wstring DictionaryText(std::string_view key, messages::Language language,
                            std::initializer_list<std::pair<std::wstring_view, std::wstring_view>> values) {
    return messages::Text(key, language, values, messages::Table::UserDictionary);
}

std::wstring ValidationReasonText(const ValidationIssue& issue, messages::Language language) {
    std::string key = "validation." + issue.field + "." + issue.reason;
    if (!messages::FindMessage(key, messages::Table::UserDictionary)) key = "validation.unknown";
    return DictionaryText(key, language);
}

}  // namespace azookey::settings
