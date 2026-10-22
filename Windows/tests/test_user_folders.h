// The per-user folder a test's host and converter use for settings.json. They
// inherit this process's environment, and Core keeps settings.json under
// %APPDATA%. (Core's other settings go to Foundation's UserDefaults in the
// user's %LOCALAPPDATA%\<program>.plist, which this environment variable does
// not move; see docs/windows.md.)
#pragma once

#include <windows.h>

#include <filesystem>
#include <string>

namespace azookey::tests {

// Creates `root`\Roaming and `root`\Local and points %APPDATA% at the first.
inline void UseTestUserFolders(const std::wstring& root) {
    std::wstring roaming = root + L"\\Roaming";
    std::filesystem::create_directories(roaming);
    std::filesystem::create_directories(root + L"\\Local");
    SetEnvironmentVariableW(L"APPDATA", roaming.c_str());
}

}  // namespace azookey::tests
