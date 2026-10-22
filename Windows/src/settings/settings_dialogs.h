// The questions the settings screens ask the user. The app shows system
// dialogs; the screen tests answer them without showing anything.
#pragma once

#include <windows.h>

#include <optional>
#include <string>

#include "dictionary_protocol.h"

namespace azookey::settings {

struct ImportSelection {
    std::wstring path;
    std::string format;    // one of kImportFormats
    std::string encoding;  // one of kImportEncodings
};

class SettingsDialogs {
public:
    virtual ~SettingsDialogs() = default;

    virtual bool ConfirmResetLearning(HWND owner) = 0;
    // Recovery replaces the damaged settings file and keeps the original under another name.
    virtual bool ConfirmRecovery(HWND owner) = 0;
    // The settings file changed after the screen read it; reloading drops unsaved changes.
    virtual bool ConfirmReloadChangedFile(HWND owner) = 0;
    virtual std::optional<ImportSelection> ChooseImportFile(HWND owner) = 0;
    virtual std::optional<std::wstring> ChooseExportFile(HWND owner) = 0;
    // Shows what an import would add; true when the user adds it to the draft.
    virtual bool ConfirmImport(HWND owner, const ImportPreview& preview) = 0;
};

}  // namespace azookey::settings
