#include "system_dialogs.h"

#include <commctrl.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <iterator>

#include "import_preview_window.h"

namespace azookey::settings {
namespace {

using Microsoft::WRL::ComPtr;

constexpr int kConfirmButton = 100;
// Ids of the controls added to the import file dialog.
constexpr DWORD kFormatGroup = 1;
constexpr DWORD kFormatList = 2;
constexpr DWORD kEncodingGroup = 3;
constexpr DWORD kEncodingList = 4;
constexpr DWORD kFormatHelp = 5;

struct Question {
    std::wstring instruction;
    std::wstring content;
    std::wstring confirmLabel;  // empty: the system's OK button confirms
    bool cancelIsDefault = false;
};

bool Ask(HWND owner, const std::wstring& title, const Question& question) {
    TASKDIALOG_BUTTON confirm{kConfirmButton, question.confirmLabel.c_str()};
    TASKDIALOGCONFIG config{sizeof(config)};
    config.hwndParent = owner;
    config.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW;
    config.pszWindowTitle = title.c_str();
    config.pszMainInstruction = question.instruction.c_str();
    config.pszContent = question.content.c_str();
    config.dwCommonButtons = TDCBF_CANCEL_BUTTON | (question.confirmLabel.empty() ? TDCBF_OK_BUTTON : 0);
    if (!question.confirmLabel.empty()) {
        config.cButtons = 1;
        config.pButtons = &confirm;
    }
    int confirmId = question.confirmLabel.empty() ? IDOK : kConfirmButton;
    config.nDefaultButton = question.cancelIsDefault ? IDCANCEL : confirmId;
    int pressed = 0;
    return SUCCEEDED(TaskDialogIndirect(&config, &pressed, nullptr, nullptr)) && pressed == confirmId;
}

std::wstring ResultPath(IFileDialog* dialog) {
    ComPtr<IShellItem> item;
    PWSTR path = nullptr;
    if (FAILED(dialog->GetResult(&item)) || FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) return {};
    std::wstring result(path);
    CoTaskMemFree(path);
    return result;
}

template <size_t Count>
void AddChoices(IFileDialogCustomize* customize, DWORD group, DWORD list, const std::wstring& label,
                const char* const (&values)[Count], const std::string& keyPrefix, messages::Language language) {
    customize->StartVisualGroup(group, label.c_str());
    customize->AddComboBox(list);
    for (DWORD index = 0; index < Count; ++index) {
        std::wstring text = messages::Text(keyPrefix + values[index], language, {}, messages::Table::UserDictionary);
        customize->AddControlItem(list, index, text.c_str());
    }
    customize->SetSelectedControlItem(list, 0);
    customize->EndVisualGroup();
}

}  // namespace

bool SystemDialogs::ConfirmResetLearning(HWND owner) {
    return Ask(owner, messages::Text("settings.window_title", language_),
               {messages::Text("learning.reset.title", language_), messages::Text("learning.reset.explanation", language_),
                messages::Text("learning.reset.confirm", language_), true});
}

bool SystemDialogs::ConfirmRecovery(HWND owner) {
    return Ask(owner, messages::Text("settings.window_title", language_),
               {messages::Text("settings.restore_question", language_),
                messages::Text("settings.restore_explanation", language_), L"", false});
}

bool SystemDialogs::ConfirmReloadChangedFile(HWND owner) {
    return Ask(owner, messages::Text("settings.window_title", language_),
               {messages::Text("settings.changed_question", language_),
                messages::Text("settings.changed_explanation", language_), messages::Text("settings.reload", language_),
                false});
}

std::optional<ImportSelection> SystemDialogs::ChooseImportFile(HWND owner) {
    auto text = [this](const std::string& key) {
        return messages::Text(key, language_, {}, messages::Table::UserDictionary);
    };
    ComPtr<IFileOpenDialog> dialog;
    ComPtr<IFileDialogCustomize> customize;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog))) ||
        FAILED(dialog.As(&customize))) {
        return std::nullopt;
    }
    std::wstring title = text("import.title");
    dialog->SetTitle(title.c_str());
    FILEOPENDIALOGOPTIONS options = 0;
    dialog->GetOptions(&options);
    dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST);
    std::wstring all = text("file_type.all"), json = text("file_type.json"), plain = text("file_type.text");
    COMDLG_FILTERSPEC filters[] = {{all.c_str(), L"*.*"}, {json.c_str(), L"*.json"}, {plain.c_str(), L"*.txt"}};
    dialog->SetFileTypes(static_cast<UINT>(std::size(filters)), filters);
    AddChoices(customize.Get(), kFormatGroup, kFormatList, text("import.format"), kImportFormats, "import.format.", language_);
    AddChoices(customize.Get(), kEncodingGroup, kEncodingList, text("import.encoding"), kImportEncodings,
               "import.encoding.", language_);
    std::wstring help = text("import.format_help");
    customize->AddText(kFormatHelp, help.c_str());
    if (FAILED(dialog->Show(owner))) return std::nullopt;
    std::wstring path = ResultPath(dialog.Get());
    DWORD format = 0;
    DWORD encoding = 0;
    customize->GetSelectedControlItem(kFormatList, &format);
    customize->GetSelectedControlItem(kEncodingList, &encoding);
    if (path.empty() || format >= std::size(kImportFormats) || encoding >= std::size(kImportEncodings)) return std::nullopt;
    return ImportSelection{path, kImportFormats[format], kImportEncodings[encoding]};
}

std::optional<std::wstring> SystemDialogs::ChooseExportFile(HWND owner) {
    auto text = [this](const std::string& key) {
        return messages::Text(key, language_, {}, messages::Table::UserDictionary);
    };
    ComPtr<IFileSaveDialog> dialog;
    if (FAILED(CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) {
        return std::nullopt;
    }
    std::wstring title = text("export.title"), fileName = text("export.filename"), json = text("file_type.json");
    dialog->SetTitle(title.c_str());
    dialog->SetFileName(fileName.c_str());
    dialog->SetDefaultExtension(L"json");
    COMDLG_FILTERSPEC filters[] = {{json.c_str(), L"*.json"}};
    dialog->SetFileTypes(static_cast<UINT>(std::size(filters)), filters);
    FILEOPENDIALOGOPTIONS options = 0;
    dialog->GetOptions(&options);
    dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_OVERWRITEPROMPT | FOS_PATHMUSTEXIST);
    if (FAILED(dialog->Show(owner))) return std::nullopt;
    std::wstring path = ResultPath(dialog.Get());
    if (path.empty()) return std::nullopt;
    return path;
}

bool SystemDialogs::ConfirmImport(HWND owner, const ImportPreview& preview) {
    return ImportPreviewWindow::Ask(owner, preview, language_);
}

}  // namespace azookey::settings
