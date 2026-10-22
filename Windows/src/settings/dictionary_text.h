// Texts of the dictionary screens, from the UserDictionary table of the shared catalog.
#pragma once

#include <initializer_list>
#include <string>
#include <string_view>
#include <utility>

#include "../shared/message_catalog_data.h"
#include "dictionary_protocol.h"

namespace azookey::settings {

std::wstring DictionaryText(std::string_view key, messages::Language language,
                            std::initializer_list<std::pair<std::wstring_view, std::wstring_view>> values = {});
// Why Core refused a word or reading, e.g. "Enter a reading."
std::wstring ValidationReasonText(const ValidationIssue& issue, messages::Language language);

}  // namespace azookey::settings
