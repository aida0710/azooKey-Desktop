// Writes a whole file so a reader sees either the old or the new contents:
// the bytes go to a temporary file beside it, which then replaces the target.
#pragma once

#include <string>

namespace azookey::settings {

bool WriteFileReplacing(const std::wstring& path, const std::string& bytes);

}  // namespace azookey::settings
