// Requests and replies of Core's user dictionary operations
// (DesktopDictionaryController and DesktopDictionaryExchangeController):
// validating readings, saving into the settings file, previewing an import
// and serializing an export.
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "../shared/json.h"
#include "settings_protocol.h"

namespace azookey::settings {

struct DictionaryEntry {
    std::wstring id;  // a UUID; Core writes it in upper case
    std::wstring word;
    std::wstring reading;
    std::wstring hint;  // empty when the entry has none

    bool operator==(const DictionaryEntry&) const = default;
};

// Core's UUIDs may differ from the screen's only in letter case.
bool SameEntryId(const std::wstring& left, const std::wstring& right);
// Same id, word, reading and hint.
bool SameEntry(const DictionaryEntry& left, const DictionaryEntry& right);

struct ValidationIssue {
    std::wstring entryId;
    std::string field;   // "word" or "reading"
    std::string reason;  // "empty", "controlCharacter", "unsupportedCharacter"
};

// The import formats and encodings Core reads, in the order the screen offers them.
inline constexpr const char* kImportFormats[] = {"json", "atok2017", "mozc"};
inline constexpr const char* kImportEncodings[] = {"automatic", "utf8", "utf16", "shiftJIS"};

struct ImportRow {
    int sourceIndex = 0;
    std::optional<int> sourceLine;
    std::optional<DictionaryEntry> entry;
    std::wstring partOfSpeech;
    std::string outcome;  // "addition", "duplicate", "conflict", "excluded"
    std::string problem;  // empty, or why the row is not added
    std::vector<ValidationIssue> validationIssues;
};

struct ImportPreview {
    std::vector<ImportRow> rows;
    int additions = 0;
    int duplicates = 0;
    int conflicts = 0;
    int excluded = 0;
    std::vector<std::string> notices;
    // The draft the preview was made for, followed by the additions.
    std::vector<DictionaryEntry> entriesAfterImport;
};

// The entries of settings.userDictionary.items.
std::vector<DictionaryEntry> DictionaryEntriesIn(const json::Value& settings);
std::wstring NewEntryId();

std::string ValidateRequest(const std::vector<DictionaryEntry>& entries);
std::string DictionarySaveRequest(const std::vector<DictionaryEntry>& entries, const std::string& expectedStamp);
std::string ExportRequest(const std::vector<DictionaryEntry>& entries);
std::string ImportPreviewRequest(const std::wstring& path, const std::string& format, const std::string& encoding,
                                 const std::vector<DictionaryEntry>& entries);

struct ValidateReply {
    bool answered = false;  // false: the converter could not validate
    std::vector<ValidationIssue> issues;
};

struct DictionarySaveReply {
    bool saved = false;
    // "compile", "persistence", "activation", "rollback", or "unknown" for a
    // reply that cannot be read. Empty when saved or only issues were found.
    std::string failureStage;
    std::vector<ValidationIssue> issues;
    SettingsReply settings;  // the saved settings and file stamp, or why the file refused
};

struct ImportReply {
    std::optional<ImportPreview> preview;
    std::string failure;  // Core's exchange failure code, e.g. "invalidEncoding"
};

struct ExportReply {
    std::string document;  // the JSON to write, UTF-8
    std::string failure;
};

ValidateReply ParseValidateReply(const std::optional<json::Value>& reply);
DictionarySaveReply ParseDictionarySaveReply(const std::optional<json::Value>& reply);
// `draft` is what the request sent; a preview whose items do not start with it is refused.
ImportReply ParseImportReply(const std::optional<json::Value>& reply, const std::vector<DictionaryEntry>& draft);
ExportReply ParseExportReply(const std::optional<json::Value>& reply);

}  // namespace azookey::settings
