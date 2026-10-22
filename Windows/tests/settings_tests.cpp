// Unit tests for the settings screen's logic that needs no window: reading
// Core's definition, choosing controls, building requests, resolving error
// texts, the dictionary draft and shortcuts.
// Run: azookey-settings-tests.exe (exit code 0 means every check passed).
#include <windows.h>

#include <cstdio>
#include <string>

#include "../src/settings/dictionary_draft.h"
#include "../src/settings/dictionary_protocol.h"
#include "../src/settings/problem_text.h"
#include "../src/settings/settings_protocol.h"
#include "../src/settings/settings_schema.h"
#include "../src/settings/settings_widgets.h"
#include "../src/settings/shortcut.h"
#include "../src/shared/json.h"

namespace {

using namespace azookey::settings;
using azookey::json::Parse;
using azookey::json::Value;
using azookey::messages::Language;

int failures = 0;
int checks = 0;

void Check(bool condition, const char* description) {
    ++checks;
    if (!condition) {
        ++failures;
        std::printf("FAIL: %s\n", description);
    }
}

// The shape of Core's settings-schema reply on Windows, trimmed to one setting of each control.
constexpr char kSchemaReply[] = R"({"settingsResult":{"schema":{"platform":"windows",
 "items":[
  {"key":"live","control":"toggle","labelKey":"settings.live","default":true,"available":true},
  {"key":"punctuation","control":"choice","labelKey":"settings.punctuation","default":1,"available":true,
   "choices":[{"value":1,"labelKey":"settings.punctuation.kutenAndToten"},{"value":2,"labelKey":"settings.punctuation.kutenAndComma"}]},
  {"key":"inferenceLimit","control":"integer","labelKey":"settings.inferenceLimit","minimum":1,"maximum":100,"default":10,"available":true},
  {"key":"profile","control":"text","labelKey":"settings.profile","maximumCharacters":4096,"default":"","available":true},
  {"key":"customTable","control":"multilineText","labelKey":"settings.custom-table","default":"","available":true},
  {"key":"transformShortcut","control":"shortcut","labelKey":"ai.shortcut","accessKey":"S","default":{"key":"s","modifiers":2},"available":true},
  {"key":"userDictionary","control":"dictionary","labelKey":"settings.dictionary_edit","default":{"items":[]},"available":true},
  {"key":"typoCorrection","control":"toggle","labelKey":"settings.typoCorrection","default":false,"available":false,
   "unavailableReasonKey":"settings.unavailable.marisa_windows"}],
 "pages":[
  {"id":"input","titleKey":"settings.page.input","elements":[{"kind":"setting","key":"punctuation"},{"kind":"setting","key":"customTable"}]},
  {"id":"conversion","titleKey":"settings.page.conversion","elements":[{"kind":"setting","key":"live"},
   {"kind":"setting","key":"inferenceLimit"},{"kind":"setting","key":"typoCorrection"},
   {"kind":"action","action":{"id":"downloadTypoWeights","labelKey":"settings.downloadTypoWeights","available":false,
    "unavailableReasonKey":"settings.unavailable.marisa_windows"}}]},
  {"id":"dictionary","titleKey":"settings.page.dictionary","elements":[{"kind":"setting","key":"profile"},
   {"kind":"setting","key":"userDictionary"}]},
  {"id":"ai","titleKey":"settings.page.ai","elements":[{"kind":"note","textKey":"ai.scope.processing-windows"},
   {"kind":"setting","key":"transformShortcut"},
   {"kind":"secret","secret":{"id":"apiKey","labelKey":"ai.api-key","placeholderKey":"ai.api-key-placeholder",
    "descriptionKey":"ai.scope.api-key","accessKey":"K"}}]},
  {"id":"support","titleKey":"settings.page.support","elements":[{"kind":"support"}]}]}}})";

Schema LoadSchema() {
    auto reply = Parse(kSchemaReply);
    auto schema = reply ? ParseSchema(*reply) : std::nullopt;
    Check(schema.has_value(), "the schema reply parses");
    return schema ? *schema : Schema{};
}

void TestSchemaKeepsItemsPagesAndAvailability() {
    Schema schema = LoadSchema();
    Check(schema.platform == "windows", "the platform is read");
    Check(schema.items.size() == 8 && schema.pages.size() == 5, "every item and page is read");
    const SettingItem* punctuation = schema.FindItem("punctuation");
    Check(punctuation && punctuation->choices.size() == 2 && punctuation->choices[1].value.AsInteger() == 2,
          "integer choice values stay integers");
    const SettingItem* limit = schema.FindItem("inferenceLimit");
    Check(limit && limit->minimum == 1 && limit->maximum == 100, "integer ranges are read");
    const SettingItem* typo = schema.FindItem("typoCorrection");
    Check(typo && !typo->available && typo->unavailableReasonKey == "settings.unavailable.marisa_windows",
          "an unavailable setting keeps its reason");
    Check(schema.FindItem("transformShortcut")->accessKey == "S", "the access key is read");
    Check(schema.PageIndex("dictionary") == 2 && !schema.PageIndex("missing"), "pages are found by id");
    const PageElement& action = schema.pages[1].elements[3];
    Check(action.kind == ElementKind::Action && !action.action.available, "an unavailable action is read");
    const PageElement& secret = schema.pages[3].elements[2];
    Check(secret.kind == ElementKind::Secret && secret.secret.placeholderKey == "ai.api-key-placeholder",
          "the secret's texts are read");
}

void TestSchemaRefusesWhatTheScreenDoesNotKnow() {
    auto unknownControl = Parse(R"({"settingsResult":{"schema":{"items":[{"key":"x","control":"slider","labelKey":"x"}],
        "pages":[{"id":"p","titleKey":"t","elements":[]}]}}})");
    Check(unknownControl && !ParseSchema(*unknownControl), "an unknown control refuses the schema");
    auto unknownSetting = Parse(R"({"settingsResult":{"schema":{"items":[],
        "pages":[{"id":"p","titleKey":"t","elements":[{"kind":"setting","key":"missing"}]}]}}})");
    Check(unknownSetting && !ParseSchema(*unknownSetting), "a page naming a missing setting refuses the schema");
    auto unknownElement = Parse(R"({"settingsResult":{"schema":{"items":[],
        "pages":[{"id":"p","titleKey":"t","elements":[{"kind":"video"}]}]}}})");
    Check(unknownElement && !ParseSchema(*unknownElement), "an unknown element refuses the schema");
    auto bridgeError = Parse(R"({"consumed":false,"error":"converter_unavailable"})");
    Check(bridgeError && !ParseSchema(*bridgeError), "a reply without a schema is not a schema");
}

void TestEveryControlBecomesItsWidget() {
    Schema schema = LoadSchema();
    auto kindOf = [&](size_t page, size_t element) { return WidgetKindFor(schema.pages[page].elements[element], schema); };
    Check(kindOf(0, 0) == WidgetKind::DropDownList, "choice becomes a drop-down list");
    Check(kindOf(0, 1) == WidgetKind::MultiLineEdit, "multilineText becomes a multi-line edit");
    Check(kindOf(1, 0) == WidgetKind::CheckBox, "toggle becomes a check box");
    Check(kindOf(1, 1) == WidgetKind::NumberEdit, "integer becomes a number edit");
    Check(kindOf(1, 3) == WidgetKind::ActionButton, "action becomes a button");
    Check(kindOf(2, 0) == WidgetKind::SingleLineEdit, "text becomes a single-line edit");
    Check(kindOf(2, 1) == WidgetKind::DictionaryButton, "dictionary becomes the dictionary button");
    Check(kindOf(3, 0) == WidgetKind::NoteText, "note becomes text");
    Check(kindOf(3, 1) == WidgetKind::ShortcutField, "shortcut becomes the shortcut field");
    Check(kindOf(3, 2) == WidgetKind::PasswordEdit, "secret becomes a password edit");
    Check(kindOf(4, 0) == WidgetKind::SupportPanel, "support becomes the support panel");
}

void TestSaveAndRecoverRequestsCarryTheStamp() {
    Value values = Value::MakeObject({{"live", Value::MakeBoolean(false)}, {"punctuation", Value::MakeNumber(2)}});
    auto save = Parse(SaveRequest(values, "file:12:1700000000.5"));
    Check(save && (*save)["operation"].AsString() == "settings-save", "save names its operation");
    Check(save && (*save)["settings"]["live"].kind() == Value::Kind::Boolean && !(*save)["settings"]["live"].AsBoolean(),
          "save sends the values");
    Check(save && (*save)["settingsFile"]["expectedStamp"].AsString() == "file:12:1700000000.5",
          "save sends the stamp unchanged");
    auto recover = Parse(RecoverRequest("absent", true));
    Check(recover && (*recover)["operation"].AsString() == "settings-recover" &&
              (*recover)["settingsFile"]["useDefaults"].AsBoolean(),
          "recover can ask for input defaults");
    auto reset = Parse(ResetLearningRequest());
    Check(reset && (*reset)["context"].AsString() == kSettingsContext, "reset-learning uses the screen's own session");
    Value changed = WithValue(values, "live", Value::MakeBoolean(true));
    Check(changed["live"].AsBoolean() && changed["punctuation"].AsInteger() == 2, "WithValue keeps the other values");
}

void TestRepliesSeparateSuccessRefusalAndFailure() {
    auto loaded = ParseSettingsReply(Parse(R"({"settings":{"live":true},"settingsResult":{"file":{"path":"C:\\Users\\u\\AppData\\Roaming\\azooKey Tree\\settings.json",
        "stamp":"absent","exists":false}}})"));
    Check(loaded.succeeded() && loaded.file && !loaded.file->exists && loaded.file->stamp == "absent",
          "a load reply gives values and the file");
    Check(loaded.file && loaded.file->path.find(L"azooKey Tree") != std::wstring::npos, "the file path is UTF-16");
    auto damaged = ParseSettingsReply(Parse(R"({"settings":{"live":true},"settingsResult":{"file":{"path":"p","stamp":"file:1:2",
        "exists":true,"problem":{"code":"invalidJSON","message":"settings.invalid_json","arguments":{"line":"3","column":"7"}}}}})"));
    Check(damaged.file && damaged.file->problem && damaged.file->problem->code == "invalidJSON", "a damaged file is reported");
    auto refused = ParseSettingsReply(Parse(R"({"settingsResult":{"error":{"code":"changed","message":"settings.changed","arguments":{}}}})"));
    Check(!refused.succeeded() && refused.error && refused.error->code == "changed", "a refusal is an error");
    auto failed = ParseSettingsReply(Parse(R"({"consumed":false,"error":"converter_unavailable"})"));
    Check(failed.failure == "converter_unavailable", "a host failure is kept apart");
    Check(ParseSettingsReply(std::nullopt).failure == "no_reply", "no reply is a failure");
    auto recovered = ParseSettingsReply(Parse(R"({"settings":{},"settingsResult":{"file":{"path":"p","stamp":"s","exists":true},
        "saved":{"recoveredPath":"C:\\settings.damaged.json","lastGoodSaved":false}}})"));
    Check(recovered.saved && recovered.saved->recoveredPath == L"C:\\settings.damaged.json" && !recovered.saved->lastGoodSaved,
          "a recovery reports where the damaged file went");
}

void TestProblemTextsNameTheSettingByItsLabel() {
    Schema schema = LoadSchema();
    Problem invalid{"invalidValue", "settings.invalid_value", {{L"field", L"inferenceLimit"}}};
    std::wstring japanese = ProblemText(invalid, Language::Japanese, &schema);
    Check(japanese.find(L"推論回数") != std::wstring::npos && japanese.find(L"inferenceLimit") == std::wstring::npos,
          "a known field is shown by its label");
    Problem nested{"invalidValue", "settings.invalid_value", {{L"field", L"transformShortcut.key"}}};
    Check(ProblemText(nested, Language::English, &schema).find(L"AI conversion shortcut") != std::wstring::npos,
          "a field inside a setting is shown by the setting's label");
    Problem unknown{"unknownKey", "settings.unknown_key", {{L"field", L"surprise"}}};
    Check(ProblemText(unknown, Language::English, &schema).find(L"surprise") != std::wstring::npos,
          "an unknown field stays as Core named it");
    Problem syntax{"invalidJSON", "settings.invalid_json", {{L"line", L"3"}, {L"column", L"14"}}};
    std::wstring text = ProblemText(syntax, Language::English, nullptr);
    Check(text.find(L"3") != std::wstring::npos && text.find(L"14") != std::wstring::npos && text.find(L"{") == std::wstring::npos,
          "every argument fills its placeholder");
}

std::vector<DictionaryEntry> SampleEntries() {
    return {{L"A0000000-0000-0000-0000-000000000001", L"東京", L"とうきょう", L"地名"},
            {L"A0000000-0000-0000-0000-000000000002", L"azooKey", L"あずーきー", L""}};
}

void TestDictionaryRequestsAndReplies() {
    auto request = Parse(DictionarySaveRequest(SampleEntries(), "file:1:2"));
    Check(request && (*request)["items"].AsArray().size() == 2, "dictionary-save sends every entry");
    Check(request && (*request)["items"].AsArray()[1]["hint"].IsNull(), "an empty hint is sent as none");
    Check(request && (*request)["settingsFile"]["expectedStamp"].AsString() == "file:1:2", "dictionary-save sends the stamp");
    auto validated = ParseValidateReply(Parse(R"({"dictionaryIssues":[{"rowID":"a0000000-0000-0000-0000-000000000001",
        "field":"reading","reason":"unsupportedCharacter","characters":"x"}]})"));
    Check(validated.answered && validated.issues.size() == 1 && validated.issues[0].reason == "unsupportedCharacter",
          "validation issues are read");
    Check(!ParseValidateReply(Parse(R"({"dictionarySaveError":"compile"})")).answered, "a failed validation is not an answer");
    auto saved = ParseDictionarySaveReply(Parse(R"({"dictionarySaved":true,"settings":{"userDictionary":{"items":[]}},
        "settingsResult":{"file":{"path":"p","stamp":"file:3:4","exists":true}}})"));
    Check(saved.saved && saved.settings.file && saved.settings.file->stamp == "file:3:4", "a saved dictionary returns the new stamp");
    auto refused = ParseDictionarySaveReply(Parse(R"({"dictionarySaved":false,"dictionarySaveError":"persistence",
        "settingsResult":{"error":{"code":"changed","message":"settings.changed","arguments":{}}}})"));
    Check(!refused.saved && refused.failureStage == "persistence" && refused.settings.error, "a refused save keeps Core's reason");
    Check(ParseDictionarySaveReply(std::nullopt).failureStage == "unknown", "no reply is an unknown failure");
}

void TestImportPreviewMustKeepTheDraft() {
    auto draft = SampleEntries();
    const char* reply = R"({"dictionaryImportPreview":{"rows":[
        {"source":{"sourceIndex":1,"sourceLine":1,"item":{"id":"B0000000-0000-0000-0000-000000000001","word":"大阪","reading":"おおさか"},
         "partOfSpeech":"地名"},"outcome":"addition","validationIssues":[]},
        {"source":{"sourceIndex":2,"sourceLine":2},"outcome":"excluded","problem":"invalidColumns","validationIssues":[]}],
        "counts":{"additions":1,"duplicates":0,"conflicts":0,"excluded":1},"notices":["properNounRegistration"]},
      "dictionaryImportItems":[
        {"id":"a0000000-0000-0000-0000-000000000001","word":"東京","reading":"とうきょう","hint":"地名"},
        {"id":"A0000000-0000-0000-0000-000000000002","word":"azooKey","reading":"あずーきー"},
        {"id":"B0000000-0000-0000-0000-000000000001","word":"大阪","reading":"おおさか"}]})";
    auto imported = ParseImportReply(Parse(reply), draft);
    Check(imported.preview && imported.preview->entriesAfterImport.size() == 3, "the preview adds the new entry");
    Check(imported.preview && imported.preview->entriesAfterImport[0].id == draft[0].id, "the draft keeps its own ids");
    Check(imported.preview && imported.preview->rows[1].problem == "invalidColumns" && imported.preview->rows[0].sourceLine == 1,
          "rows keep their source and problem");
    auto changedDraft = draft;
    changedDraft[0].word = L"京都";
    Check(ParseImportReply(Parse(reply), changedDraft).failure == "importFailed", "items that do not start with the draft are refused");
    Check(ParseImportReply(Parse(R"({"dictionaryExchangeError":"invalidEncoding"})"), draft).failure == "invalidEncoding",
          "Core's import failure is kept");
    Check(ParseExportReply(Parse(R"({"dictionaryExportJSON":"{\"format\":\"azookey-user-dictionary\"}"})")).document.size() > 0,
          "the export document is read");
}

void TestDraftEditsIssuesAndStatus() {
    DictionaryDraft draft(SampleEntries());
    Check(!draft.HasChanges() && draft.Status().front().key == "unchanged", "an opened draft has no changes");
    std::wstring added = draft.Add();
    Check(draft.entries().size() == 3 && draft.Find(added) && draft.HasChanges(), "add appends an empty entry");
    Check(draft.Status().front().key == "unsaved", "changes are unsaved");
    draft.Update(added, DictionaryField::Word, L"名古屋");
    draft.Update(added, DictionaryField::Reading, L"なごや");
    Check(draft.Find(added)->word == L"名古屋" && draft.Find(added)->reading == L"なごや", "update edits one field");
    auto sent = draft.BeginSave();
    Check(sent && draft.saving() && !draft.CanEdit(), "saving locks the draft");
    Check(draft.Status().front().key == "saving", "the status says saving");
    std::wstring lowercaseId = added;
    for (auto& character : lowercaseId) character = static_cast<wchar_t>(towlower(character));
    draft.FinishSave(*sent, {{lowercaseId, "reading", "unsupportedCharacter"}}, "");
    Check(draft.IssuesFor(added).size() == 1, "issues match ids in any letter case");
    Check(draft.Status().front().key == "invalid" && draft.Status().front().arguments[0].second == L"1", "the status counts issues");
    draft.Update(added, DictionaryField::Reading, L"なごやし");
    Check(draft.IssuesFor(added).empty(), "editing an entry clears its issues");
    sent = draft.BeginSave();
    draft.FinishSave(*sent, {}, "");
    Check(!draft.HasChanges(), "a successful save becomes the saved state");
    draft.Remove(added);
    Check(draft.entries().size() == 2 && draft.HasChanges(), "remove takes the entry out");
    draft.Discard();
    Check(draft.entries().size() == 3 && !draft.HasChanges(), "discard returns to the saved entries");
    sent = draft.BeginSave();
    draft.FinishSave(*sent, {}, "rollback");
    Check(draft.needsRecovery() && !draft.BeginSave(), "after a failed rollback no further save starts");
    Check(draft.Status().front().key == "failure.rollback", "the status explains the rollback failure");
}

void TestDraftFiltersSortsAndImports() {
    DictionaryDraft draft(SampleEntries());
    Check(draft.VisibleIndices(L"AZOO", DictionaryOrder::Registration) == std::vector<size_t>{1}, "search ignores letter case");
    Check(draft.VisibleIndices(L"地名", DictionaryOrder::Registration) == std::vector<size_t>{0}, "search looks at hints");
    Check(draft.VisibleIndices(L"", DictionaryOrder::Reading) == std::vector<size_t>{1, 0}, "sorting by reading orders あ before と");
    auto sent = draft.BeginFileOperation(FileOperation::Import);
    Check(sent && draft.fileOperation() == FileOperation::Import && !draft.CanEdit(), "an import locks the draft");
    ImportPreview preview;
    preview.additions = 1;
    preview.entriesAfterImport = *sent;
    preview.entriesAfterImport.push_back({L"C0000000-0000-0000-0000-000000000001", L"福岡", L"ふくおか", L""});
    draft.ReceiveImportPreview(*sent, preview);
    Check(draft.importPreview().has_value() && !draft.CanEdit(), "the preview waits for the user");
    auto first = draft.ApplyImport();
    Check(first && *first == L"C0000000-0000-0000-0000-000000000001" && draft.entries().size() == 3,
          "applying adds the previewed entries");
    sent = draft.BeginFileOperation(FileOperation::Export);
    draft.FailFileOperation("");
    Check(draft.Status().front().key == "exchange.failure.exportFailed", "a failed export without a code says export failed");
    sent = draft.BeginFileOperation(FileOperation::Export);
    draft.FinishExport();
    Check(draft.Status().front().key == "export.done_unsaved", "an export of unsaved changes says they are not saved");
}

void TestShortcutsRoundTripAndRecordKeys() {
    auto shortcut = ShortcutFromJson(*Parse(R"({"key":"s","modifiers":2})"));
    Check(shortcut && shortcut->key == L"s" && shortcut->modifiers == Shortcut::kControl, "the stored shortcut is read");
    Check(ShortcutText({L"e", Shortcut::kControl | Shortcut::kAlt}) == L"Ctrl+Alt+E", "the text lists modifiers and the key");
    Value json = ShortcutToJson({L"e", Shortcut::kControl | Shortcut::kShift});
    Check(json["key"].AsString() == "e" && json["modifiers"].AsInteger() == 3, "the shortcut is written as Core reads it");
    Check(ShortcutForKeyPress(L'E', Shortcut::kControl) == Shortcut{L"e", Shortcut::kControl}, "a letter is recorded in lower case");
    Check(!ShortcutForKeyPress(L'e', 0), "a key without a modifier is not a shortcut");
    Check(!ShortcutForKeyPress(0, Shortcut::kControl), "a key that types nothing is not a shortcut");
    Check(!ShortcutForKeyPress(L' ', Shortcut::kControl), "Space is not a shortcut key");
}

}  // namespace

int main() {
    SetConsoleOutputCP(CP_UTF8);
    TestSchemaKeepsItemsPagesAndAvailability();
    TestSchemaRefusesWhatTheScreenDoesNotKnow();
    TestEveryControlBecomesItsWidget();
    TestSaveAndRecoverRequestsCarryTheStamp();
    TestRepliesSeparateSuccessRefusalAndFailure();
    TestProblemTextsNameTheSettingByItsLabel();
    TestDictionaryRequestsAndReplies();
    TestImportPreviewMustKeepTheDraft();
    TestDraftEditsIssuesAndStatus();
    TestDraftFiltersSortsAndImports();
    TestShortcutsRoundTripAndRecordKeys();
    std::printf("%d checks, %d failed\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
