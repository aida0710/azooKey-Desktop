#include "dictionary_protocol.h"

#include <windows.h>
#include <objbase.h>

#include <map>

#include "../shared/text_encoding.h"

namespace azookey::settings {
namespace {

using json::Value;

Value EntryToJson(const DictionaryEntry& entry) {
    return Value::MakeObject({
        {"id", Value::MakeString(text::Utf16ToUtf8(entry.id))},
        {"word", Value::MakeString(text::Utf16ToUtf8(entry.word))},
        {"reading", Value::MakeString(text::Utf16ToUtf8(entry.reading))},
        // Core keeps an empty hint as no hint.
        {"hint", entry.hint.empty() ? Value() : Value::MakeString(text::Utf16ToUtf8(entry.hint))},
    });
}

Value EntriesToJson(const std::vector<DictionaryEntry>& entries) {
    std::vector<Value> items;
    items.reserve(entries.size());
    for (const auto& entry : entries) items.push_back(EntryToJson(entry));
    return Value::MakeArray(std::move(items));
}

std::optional<DictionaryEntry> EntryFromJson(const Value& document) {
    if (document.kind() != Value::Kind::Object || document["id"].AsString().empty()) return std::nullopt;
    return DictionaryEntry{text::Utf8ToUtf16(document["id"].AsString()), text::Utf8ToUtf16(document["word"].AsString()),
                           text::Utf8ToUtf16(document["reading"].AsString()),
                           text::Utf8ToUtf16(document["hint"].AsString())};
}

std::vector<ValidationIssue> IssuesFromJson(const Value& documents) {
    std::vector<ValidationIssue> issues;
    for (const auto& document : documents.AsArray()) {
        issues.push_back({text::Utf8ToUtf16(document["rowID"].AsString()), document["field"].AsString(),
                          document["reason"].AsString()});
    }
    return issues;
}

std::optional<int> OptionalPosition(const Value& value) {
    if (value.kind() != Value::Kind::Number) return std::nullopt;
    return static_cast<int>(value.AsInteger());
}

ImportRow RowFromJson(const Value& document) {
    const Value& source = document["source"];
    ImportRow row;
    row.sourceIndex = static_cast<int>(source["sourceIndex"].AsInteger());
    row.sourceLine = OptionalPosition(source["sourceLine"]);
    row.entry = EntryFromJson(source["item"]);
    row.partOfSpeech = text::Utf8ToUtf16(source["partOfSpeech"].AsString());
    row.outcome = document["outcome"].AsString();
    row.problem = document["problem"].AsString();
    row.validationIssues = IssuesFromJson(document["validationIssues"]);
    return row;
}

std::string Request(std::map<std::string, Value> members) {
    return json::Serialize(Value::MakeObject(std::move(members)));
}

}  // namespace

bool SameEntryId(const std::wstring& left, const std::wstring& right) {
    return CompareStringOrdinal(left.c_str(), static_cast<int>(left.size()), right.c_str(), static_cast<int>(right.size()),
                                TRUE) == CSTR_EQUAL;
}

bool SameEntry(const DictionaryEntry& left, const DictionaryEntry& right) {
    return SameEntryId(left.id, right.id) && left.word == right.word && left.reading == right.reading &&
           left.hint == right.hint;
}

std::vector<DictionaryEntry> DictionaryEntriesIn(const json::Value& settings) {
    std::vector<DictionaryEntry> entries;
    for (const auto& item : settings["userDictionary"]["items"].AsArray()) {
        if (auto entry = EntryFromJson(item)) entries.push_back(std::move(*entry));
    }
    return entries;
}

std::wstring NewEntryId() {
    GUID guid{};
    CoCreateGuid(&guid);
    wchar_t braced[64];
    int length = StringFromGUID2(guid, braced, static_cast<int>(std::size(braced)));
    // "{XXXXXXXX-...}" with the terminating NUL counted: keep what is inside the braces.
    return length > 2 ? std::wstring(braced + 1, braced + length - 2) : std::wstring();
}

std::string ValidateRequest(const std::vector<DictionaryEntry>& entries) {
    return Request({{"operation", Value::MakeString("dictionary-validate")}, {"items", EntriesToJson(entries)}});
}

std::string DictionarySaveRequest(const std::vector<DictionaryEntry>& entries, const std::string& expectedStamp) {
    return Request({
        {"operation", Value::MakeString("dictionary-save")},
        {"items", EntriesToJson(entries)},
        {"settingsFile", Value::MakeObject({{"expectedStamp", Value::MakeString(expectedStamp)}})},
    });
}

std::string ExportRequest(const std::vector<DictionaryEntry>& entries) {
    return Request({{"operation", Value::MakeString("dictionary-export")}, {"items", EntriesToJson(entries)}});
}

std::string ImportPreviewRequest(const std::wstring& path, const std::string& format, const std::string& encoding,
                                 const std::vector<DictionaryEntry>& entries) {
    return Request({
        {"operation", Value::MakeString("dictionary-import-preview")},
        {"importPath", Value::MakeString(text::Utf16ToUtf8(path))},
        {"importFormat", Value::MakeString(format)},
        {"importEncoding", Value::MakeString(encoding)},
        {"items", EntriesToJson(entries)},
    });
}

ValidateReply ParseValidateReply(const std::optional<json::Value>& reply) {
    ValidateReply result;
    if (!reply || !(*reply)["error"].IsNull() || (*reply)["dictionaryIssues"].kind() != Value::Kind::Array) return result;
    result.answered = true;
    result.issues = IssuesFromJson((*reply)["dictionaryIssues"]);
    return result;
}

DictionarySaveReply ParseDictionarySaveReply(const std::optional<json::Value>& reply) {
    DictionarySaveReply result;
    result.settings = ParseSettingsReply(reply);
    if (!reply || !(*reply)["error"].IsNull()) {
        result.failureStage = "unknown";
        return result;
    }
    result.issues = IssuesFromJson((*reply)["dictionaryIssues"]);
    result.failureStage = (*reply)["dictionarySaveError"].AsString();
    // Core reports refused entries as a compile failure; the entries say more (as on Linux).
    // A failed rollback stays, because no further save may start after it.
    if (!result.issues.empty() && result.failureStage != "rollback") result.failureStage.clear();
    result.saved = (*reply)["dictionarySaved"].AsBoolean() && result.failureStage.empty() && result.settings.succeeded();
    if (!result.saved && result.failureStage.empty() && result.issues.empty()) result.failureStage = "unknown";
    return result;
}

ImportReply ParseImportReply(const std::optional<json::Value>& reply, const std::vector<DictionaryEntry>& draft) {
    ImportReply result;
    if (!reply || !(*reply)["error"].IsNull()) {
        result.failure = "importFailed";
        return result;
    }
    result.failure = (*reply)["dictionaryExchangeError"].AsString();
    if (!result.failure.empty()) return result;
    const Value& document = (*reply)["dictionaryImportPreview"];
    ImportPreview preview;
    for (const auto& row : document["rows"].AsArray()) preview.rows.push_back(RowFromJson(row));
    const Value& counts = document["counts"];
    preview.additions = static_cast<int>(counts["additions"].AsInteger());
    preview.duplicates = static_cast<int>(counts["duplicates"].AsInteger());
    preview.conflicts = static_cast<int>(counts["conflicts"].AsInteger());
    preview.excluded = static_cast<int>(counts["excluded"].AsInteger());
    for (const auto& notice : document["notices"].AsArray()) preview.notices.push_back(notice.AsString());
    std::vector<DictionaryEntry> items;
    for (const auto& item : (*reply)["dictionaryImportItems"].AsArray()) {
        auto entry = EntryFromJson(item);
        if (!entry) {
            result.failure = "importFailed";
            return result;
        }
        items.push_back(std::move(*entry));
    }
    // Core returns the draft it was given followed by the additions. Anything
    // else would replace entries the user did not choose to import.
    bool keepsDraft = items.size() == draft.size() + static_cast<size_t>(preview.additions);
    for (size_t index = 0; keepsDraft && index < draft.size(); ++index) keepsDraft = SameEntry(items[index], draft[index]);
    if (!keepsDraft) {
        result.failure = "importFailed";
        return result;
    }
    preview.entriesAfterImport = draft;
    preview.entriesAfterImport.insert(preview.entriesAfterImport.end(), items.begin() + draft.size(), items.end());
    result.preview = std::move(preview);
    return result;
}

ExportReply ParseExportReply(const std::optional<json::Value>& reply) {
    ExportReply result;
    if (!reply || !(*reply)["error"].IsNull()) {
        result.failure = "exportFailed";
        return result;
    }
    result.failure = (*reply)["dictionaryExchangeError"].AsString();
    if (result.failure.empty()) result.document = (*reply)["dictionaryExportJSON"].AsString();
    if (result.failure.empty() && result.document.empty()) result.failure = "exportFailed";
    return result;
}

}  // namespace azookey::settings
