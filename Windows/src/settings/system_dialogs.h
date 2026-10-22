// SettingsDialogs with the system's task dialogs and file dialogs.
#pragma once

#include "../shared/message_catalog_data.h"
#include "settings_dialogs.h"

namespace azookey::settings {

class SystemDialogs final : public SettingsDialogs {
public:
    explicit SystemDialogs(messages::Language language) : language_(language) {}

    bool ConfirmResetLearning(HWND owner) override;
    bool ConfirmRecovery(HWND owner) override;
    bool ConfirmReloadChangedFile(HWND owner) override;
    std::optional<ImportSelection> ChooseImportFile(HWND owner) override;
    std::optional<std::wstring> ChooseExportFile(HWND owner) override;
    bool ConfirmImport(HWND owner, const ImportPreview& preview) override;

private:
    messages::Language language_;
};

}  // namespace azookey::settings
