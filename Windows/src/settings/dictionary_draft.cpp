#include "dictionary_draft.h"

#include <windows.h>

#include <algorithm>

#include "../shared/message_catalog_data.h"

namespace azookey::settings {
namespace {

std::wstring Lowercase(std::wstring_view text) {
    if (text.empty()) return {};
    int length = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, text.data(), static_cast<int>(text.size()), nullptr,
                               0, nullptr, nullptr, 0);
    std::wstring lowered(static_cast<size_t>(std::max(length, 0)), L'\0');
    LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, text.data(), static_cast<int>(text.size()), lowered.data(),
                  length, nullptr, nullptr, 0);
    return lowered;
}

const std::wstring& FieldOf(const DictionaryEntry& entry, DictionaryOrder order) {
    switch (order) {
    case DictionaryOrder::Reading: return entry.reading;
    case DictionaryOrder::Hint: return entry.hint;
    default: return entry.word;
    }
}

// The user's locale orders the list, as the column sort of a list view would.
bool Precedes(const std::wstring& left, const std::wstring& right) {
    return CompareStringEx(LOCALE_NAME_USER_DEFAULT, LINGUISTIC_IGNORECASE, left.c_str(), static_cast<int>(left.size()),
                           right.c_str(), static_cast<int>(right.size()), nullptr, nullptr, 0) == CSTR_LESS_THAN;
}

bool SameEntries(const std::vector<DictionaryEntry>& left, const std::vector<DictionaryEntry>& right) {
    return std::equal(left.begin(), left.end(), right.begin(), right.end(), SameEntry);
}

// A failure code without its own message reads as the operation's general failure.
std::string ExchangeFailureKey(const std::string& code) {
    std::string key = "exchange.failure." + code;
    return messages::FindMessage(key, messages::Table::UserDictionary) ? key : "exchange.failure.importFailed";
}

std::string SaveFailureKey(const std::string& stage) {
    std::string key = "failure." + stage;
    return messages::FindMessage(key, messages::Table::UserDictionary) ? key : "failure.unknown";
}

}  // namespace

bool MatchesDictionaryQuery(const DictionaryEntry& entry, std::wstring_view query) {
    if (query.empty()) return true;
    std::wstring needle = Lowercase(query);
    for (const std::wstring* field : {&entry.word, &entry.reading, &entry.hint}) {
        if (Lowercase(*field).find(needle) != std::wstring::npos) return true;
    }
    return false;
}

DictionaryDraft::DictionaryDraft(std::vector<DictionaryEntry> saved) : entries_(saved), saved_(std::move(saved)) {}

const DictionaryEntry* DictionaryDraft::Find(const std::wstring& id) const {
    for (const auto& entry : entries_) {
        if (SameEntryId(entry.id, id)) return &entry;
    }
    return nullptr;
}

bool DictionaryDraft::HasChanges() const { return !SameEntries(entries_, saved_); }

std::vector<size_t> DictionaryDraft::VisibleIndices(std::wstring_view query, DictionaryOrder order) const {
    std::vector<size_t> indices;
    for (size_t index = 0; index < entries_.size(); ++index) {
        if (MatchesDictionaryQuery(entries_[index], query)) indices.push_back(index);
    }
    if (order != DictionaryOrder::Registration) {
        std::stable_sort(indices.begin(), indices.end(), [&](size_t left, size_t right) {
            return Precedes(FieldOf(entries_[left], order), FieldOf(entries_[right], order));
        });
    }
    return indices;
}

bool DictionaryDraft::CanEdit() const { return !saving_ && fileOperation_ == FileOperation::None && !importPreview_; }

std::wstring DictionaryDraft::Add() {
    if (!CanEdit()) return {};
    DictionaryEntry entry{NewEntryId(), L"", L"", L""};
    entries_.push_back(entry);
    ClearFeedback();
    return entry.id;
}

void DictionaryDraft::Update(const std::wstring& id, DictionaryField field, const std::wstring& value) {
    if (!CanEdit()) return;
    for (auto& entry : entries_) {
        if (!SameEntryId(entry.id, id)) continue;
        switch (field) {
        case DictionaryField::Word: entry.word = value; break;
        case DictionaryField::Reading: entry.reading = value; break;
        case DictionaryField::Hint: entry.hint = value; break;
        }
        std::erase_if(issues_, [&](const ValidationIssue& issue) { return SameEntryId(issue.entryId, id); });
        ClearFeedback();
        return;
    }
}

void DictionaryDraft::Remove(const std::wstring& id) {
    if (!CanEdit()) return;
    std::erase_if(entries_, [&](const DictionaryEntry& entry) { return SameEntryId(entry.id, id); });
    std::erase_if(issues_, [&](const ValidationIssue& issue) { return SameEntryId(issue.entryId, id); });
    ClearFeedback();
}

void DictionaryDraft::Discard() {
    if (!CanEdit()) return;
    entries_ = saved_;
    issues_.clear();
    ClearFeedback();
}

std::vector<ValidationIssue> DictionaryDraft::IssuesFor(const std::wstring& id) const {
    std::vector<ValidationIssue> found;
    for (const auto& issue : issues_) {
        if (SameEntryId(issue.entryId, id)) found.push_back(issue);
    }
    return found;
}

std::optional<std::vector<DictionaryEntry>> DictionaryDraft::BeginSave() {
    if (!CanEdit() || needsRecovery_) return std::nullopt;
    issues_.clear();
    ClearFeedback();
    saving_ = true;
    return entries_;
}

void DictionaryDraft::FinishSave(const std::vector<DictionaryEntry>& sent, std::vector<ValidationIssue> issues,
                                 const std::string& stage) {
    saving_ = false;
    issues_ = std::move(issues);
    failureStage_ = stage;
    // Core could not put the previous dictionary back; another save could make it worse.
    if (stage == "rollback") needsRecovery_ = true;
    if (stage.empty() && issues_.empty()) saved_ = sent;
}

void DictionaryDraft::SetSaveProblem(std::wstring text) { saveProblem_ = std::move(text); }

std::optional<std::vector<DictionaryEntry>> DictionaryDraft::BeginFileOperation(FileOperation operation) {
    if (!CanEdit() || operation == FileOperation::None || (operation == FileOperation::Import && needsRecovery_)) {
        return std::nullopt;
    }
    ClearFeedback();
    fileOperation_ = operation;
    return entries_;
}

void DictionaryDraft::FailFileOperation(const std::string& failureCode) {
    std::string fallback = fileOperation_ == FileOperation::Export ? "exportFailed" : "importFailed";
    fileOperation_ = FileOperation::None;
    exchangeFailure_ = failureCode.empty() ? fallback : failureCode;
}

void DictionaryDraft::FinishExport() {
    fileOperation_ = FileOperation::None;
    didExport_ = true;
}

void DictionaryDraft::ReceiveImportPreview(const std::vector<DictionaryEntry>& sent, ImportPreview preview) {
    fileOperation_ = FileOperation::None;
    if (!SameEntries(entries_, sent)) {
        exchangeFailure_ = "stalePreview";
        return;
    }
    importPreview_ = std::move(preview);
}

std::optional<std::wstring> DictionaryDraft::ApplyImport() {
    if (!importPreview_) return std::nullopt;
    ImportPreview preview = std::move(*importPreview_);
    importPreview_.reset();
    size_t original = entries_.size();
    if (preview.additions == 0 || preview.entriesAfterImport.size() <= original) return std::nullopt;
    entries_ = std::move(preview.entriesAfterImport);
    issues_.clear();
    ClearFeedback();
    return entries_[original].id;
}

void DictionaryDraft::CancelImport() {
    importPreview_.reset();
    ClearFeedback();
}

std::vector<DraftStatusLine> DictionaryDraft::Status() const {
    std::vector<DraftStatusLine> lines;
    if (fileOperation_ == FileOperation::Import) {
        lines.push_back({"exchange.working.import", {}});
    } else if (fileOperation_ == FileOperation::Export) {
        lines.push_back({"exchange.working.export", {}});
    } else if (saving_) {
        lines.push_back({"saving", {}});
    } else if (!exchangeFailure_.empty()) {
        lines.push_back({ExchangeFailureKey(exchangeFailure_), {}});
    } else if (didExport_) {
        lines.push_back({HasChanges() ? "export.done_unsaved" : "export.done", {}});
    } else if (needsRecovery_) {
        lines.push_back({"failure.rollback", {}});
    } else if (!saveProblem_.empty()) {
        lines.push_back({"", {}, saveProblem_});
    } else if (!failureStage_.empty()) {
        lines.push_back({SaveFailureKey(failureStage_), {}});
    } else if (!issues_.empty()) {
        lines.push_back({"invalid", {{L"count", std::to_wstring(issues_.size())}}});
    } else if (HasChanges()) {
        lines.push_back({"unsaved", {}});
    } else {
        lines.push_back({entries_.empty() ? "empty" : "unchanged", {}});
    }
    if (needsRecovery_ && lines.front().key != "failure.rollback") {
        lines.insert(lines.begin(), DraftStatusLine{"failure.rollback", {}, {}});
    }
    return lines;
}

void DictionaryDraft::ClearFeedback() {
    failureStage_.clear();
    exchangeFailure_.clear();
    saveProblem_.clear();
    didExport_ = false;
}

}  // namespace azookey::settings
