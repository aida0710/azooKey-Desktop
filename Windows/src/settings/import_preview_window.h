// Shows what importing a dictionary file would do, row by row, before the
// additions reach the draft (Linux: UserDictionaryImportPreviewDialog).
#pragma once

#include <windows.h>

#include "../shared/message_catalog_data.h"
#include "dictionary_protocol.h"
#include "../ui/top_level_window.h"

namespace azookey::settings {

class ImportPreviewWindow final : public ui::TopLevelWindow {
public:
    static constexpr wchar_t kClassName[] = L"azooKeyTreeImportPreview";

    ImportPreviewWindow(HWND owner, const ImportPreview& preview, messages::Language language);

    // Shows the preview over `owner` until the user decides; true to add the additions.
    static bool Ask(HWND owner, const ImportPreview& preview, messages::Language language);
    // Shows this window and runs it with its owner disabled until the user decides.
    bool RunModal();

    HWND list() const { return list_; }
    HWND applyButton() const { return apply_; }
    bool finished() const { return finished_; }
    bool accepted() const { return accepted_; }

protected:
    void Layout() override;
    void OnCancel() override;
    bool HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT* result) override;

private:
    void Build();
    void ShowDetails();
    std::wstring Reason(const ImportRow& row) const;
    void Finish(bool accepted);

    const ImportPreview& preview_;
    messages::Language language_;
    HWND owner_ = nullptr;
    HWND counts_ = nullptr;
    HWND notices_ = nullptr;
    HWND help_ = nullptr;
    HWND list_ = nullptr;
    HWND details_ = nullptr;
    HWND cancel_ = nullptr;
    HWND apply_ = nullptr;
    bool finished_ = false;
    bool accepted_ = false;
};

}  // namespace azookey::settings
