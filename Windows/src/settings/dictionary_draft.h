// The dictionary editor's draft and its state, apart from any window
// (Linux/azookey/user_dictionary_model.py does the same for GTK). Entries are
// edited here; nothing is saved until the editor sends the draft to Core.
#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "dictionary_protocol.h"

namespace azookey::settings {

enum class DictionaryField { Word, Reading, Hint };
// The order the list shows; Registration keeps the order entries were added in.
enum class DictionaryOrder { Registration, Word, Reading, Hint };
enum class FileOperation { None, Import, Export };

// A message key of the UserDictionary table and the values for its
// placeholders, or, when the key is empty, a text already in the screen's language.
struct DraftStatusLine {
    std::string key;
    std::vector<std::pair<std::wstring, std::wstring>> arguments;
    std::wstring text;
};

// True when `query` appears in the word, reading or hint, ignoring letter case.
bool MatchesDictionaryQuery(const DictionaryEntry& entry, std::wstring_view query);

class DictionaryDraft {
public:
    explicit DictionaryDraft(std::vector<DictionaryEntry> saved);

    const std::vector<DictionaryEntry>& entries() const { return entries_; }
    const DictionaryEntry* Find(const std::wstring& id) const;
    bool HasChanges() const;

    // Indices into entries() that match `query`, in `order`.
    std::vector<size_t> VisibleIndices(std::wstring_view query, DictionaryOrder order) const;

    // Editing is refused while a save or a file operation is running, or while
    // an import preview waits for the user.
    bool CanEdit() const;
    std::wstring Add();  // the new entry's id
    void Update(const std::wstring& id, DictionaryField field, const std::wstring& value);
    void Remove(const std::wstring& id);
    void Discard();

    const std::vector<ValidationIssue>& issues() const { return issues_; }
    std::vector<ValidationIssue> IssuesFor(const std::wstring& id) const;

    // Saving: Begin returns the entries to send, or nullopt when saving is not possible now.
    std::optional<std::vector<DictionaryEntry>> BeginSave();
    // `stage` is empty on success; issues may come with or without a stage.
    void FinishSave(const std::vector<DictionaryEntry>& sent, std::vector<ValidationIssue> issues, const std::string& stage);
    bool saving() const { return saving_; }
    bool needsRecovery() const { return needsRecovery_; }
    // A refusal Core described with its own text (the settings file changed, ...).
    void SetSaveProblem(std::wstring text);

    // Import and export: Begin returns the draft the file operation works on.
    std::optional<std::vector<DictionaryEntry>> BeginFileOperation(FileOperation operation);
    FileOperation fileOperation() const { return fileOperation_; }
    void FailFileOperation(const std::string& failureCode);
    void FinishExport();
    // Holds the preview for the user unless the draft changed since the request.
    void ReceiveImportPreview(const std::vector<DictionaryEntry>& sent, ImportPreview preview);
    const std::optional<ImportPreview>& importPreview() const { return importPreview_; }
    // Applies or drops the preview. Returns the first added entry's id when applied.
    std::optional<std::wstring> ApplyImport();
    void CancelImport();

    // What the status line says, one line per message.
    std::vector<DraftStatusLine> Status() const;

private:
    void ClearFeedback();

    std::vector<DictionaryEntry> entries_;
    std::vector<DictionaryEntry> saved_;
    std::vector<ValidationIssue> issues_;
    bool saving_ = false;
    bool needsRecovery_ = false;
    std::string failureStage_;
    std::wstring saveProblem_;
    FileOperation fileOperation_ = FileOperation::None;
    std::string exchangeFailure_;
    bool didExport_ = false;
    std::optional<ImportPreview> importPreview_;
};

}  // namespace azookey::settings
