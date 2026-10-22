// The user dictionary editor: a searchable, sortable list of entries, a form
// for the selected entry, import and export, and an explicit save that Core
// validates and applies (Linux: user_dictionary_editor.py). Nothing reaches
// the settings file until Save; Cancel discards the draft.
#pragma once

#include <windows.h>

#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "../shared/message_catalog_data.h"
#include "bridge_worker.h"
#include "command_map.h"
#include "dictionary_draft.h"
#include "settings_dialogs.h"
#include "top_level_window.h"

namespace azookey::settings {

class DictionaryWindow final : public TopLevelWindow {
public:
    static constexpr wchar_t kClassName[] = L"azooKeyTreeUserDictionary";

    struct Options {
        HWND owner = nullptr;  // disabled while the editor is open
        messages::Language language = messages::Language::English;
        BridgeWorker* worker = nullptr;
        SettingsDialogs* dialogs = nullptr;
        std::vector<DictionaryEntry> entries;
        std::string stamp;  // the settings file the entries came from
        // After Core saved the dictionary: the saved settings and the file's new stamp.
        std::function<void(const SettingsReply& saved)> onSaved;
        // The window is gone; the owner may now release this object.
        std::function<void()> onClosed;
    };

    explicit DictionaryWindow(Options options);

    void Present();
    const DictionaryDraft& draft() const { return draft_; }
    HWND list() const { return list_; }
    HWND searchEdit() const { return search_; }
    HWND wordEdit() const { return word_; }
    HWND readingEdit() const { return reading_; }
    HWND hintEdit() const { return hint_; }
    HWND addButton() const { return add_; }
    HWND removeButton() const { return remove_; }
    HWND importButton() const { return import_; }
    HWND exportButton() const { return export_; }
    HWND saveButton() const { return save_; }
    HWND cancelButton() const { return cancel_; }
    HWND statusText() const { return status_; }
    HWND issueText() const { return issues_; }

protected:
    void Layout() override;
    void OnFontsChanged() override;
    void OnCancel() override;
    bool HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT* result) override;

private:
    void Build();
    HWND AddButton(const std::string& key, std::function<void()> action);
    HWND AddFormField(const std::string& labelKey, DictionaryField field, DWORD style);
    void RefreshRows(const std::optional<std::wstring>& selectId);
    void SelectionChanged();
    void RefreshFeedback();
    void Edit(DictionaryField field, HWND edit);
    void UpdateSelectedRow();
    // Shows every entry again, so one the window is about to select is visible.
    void ClearSearch();
    std::wstring IssuesText(const std::wstring& id, const wchar_t* separator) const;
    std::wstring Text(std::string_view key,
                      std::initializer_list<std::pair<std::wstring_view, std::wstring_view>> values = {}) const;

    void AddEntry();
    void RemoveEntry();
    void Save();
    void FinishSave(const std::vector<DictionaryEntry>& sent, const DictionarySaveReply& reply);
    void Import();
    void FinishImport(const std::vector<DictionaryEntry>& sent, const ImportReply& reply);
    void Export();
    void Close();

    Options options_;
    DictionaryDraft draft_;
    CommandMap commands_;
    std::wstring selectedId_;
    std::wstring query_;
    DictionaryOrder order_ = DictionaryOrder::Registration;
    // The window is changing a control's text itself; its EN_CHANGE is not an edit.
    bool settingText_ = false;
    bool updatingRows_ = false;
    bool closed_ = false;

    HWND instructions_ = nullptr;
    HWND search_ = nullptr;
    HWND sortReset_ = nullptr;
    HWND filterCount_ = nullptr;
    HWND list_ = nullptr;
    HWND add_ = nullptr;
    HWND remove_ = nullptr;
    HWND import_ = nullptr;
    HWND export_ = nullptr;
    std::vector<HWND> formLabels_;
    HWND word_ = nullptr;
    HWND reading_ = nullptr;
    HWND hint_ = nullptr;
    HWND issues_ = nullptr;
    HWND status_ = nullptr;
    HWND cancel_ = nullptr;
    HWND save_ = nullptr;
};

}  // namespace azookey::settings
