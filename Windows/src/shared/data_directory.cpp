#include "data_directory.h"

#include <windows.h>
#include <shlobj.h>

namespace azookey::storage {

std::wstring DefaultDataDirectory() {
    PWSTR localAppData = nullptr;
    std::wstring directory;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &localAppData))) {
        directory = std::wstring(localAppData) + L"\\azooKey Tree";
    }
    CoTaskMemFree(localAppData);
    return directory;
}

}  // namespace azookey::storage
