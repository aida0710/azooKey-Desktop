// Where the converter keeps a user's learning data and compiled dictionaries:
// %LOCALAPPDATA%\azooKey Tree. The host passes it to the converter, and the
// settings screen shows it.
#pragma once

#include <string>

namespace azookey::storage {

// Empty when the known folder cannot be resolved.
std::wstring DefaultDataDirectory();

}  // namespace azookey::storage
