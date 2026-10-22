// Unit tests for the platform-neutral pieces shared by the text service and
// the host. Run: azookey-windows-tests.exe (exit code 0 means every check passed).
#include <cstdio>
#include <string>

#include "../src/shared/ai_protocol.h"
#include "../src/shared/bridge_protocol.h"
#include "../src/shared/candidate_display.h"
#include "../src/shared/json.h"
#include "../src/shared/key_binding.h"
#include "../src/shared/key_translation.h"
#include "../src/shared/text_encoding.h"

namespace {

int failures = 0;
int checks = 0;

void Check(bool condition, const char* description) {
    ++checks;
    if (!condition) {
        ++failures;
        std::printf("FAIL: %s\n", description);
    }
}

using azookey::keys::Classify;
using azookey::keys::KeyAction;
using azookey::keys::KeyState;
using azookey::keys::Modifiers;
using azookey::keys::Translate;

constexpr uint32_t kVkA = 'A', kVkBack = 0x08, kVkReturn = 0x0D, kVkSpace = 0x20, kVkLeft = 0x25, kVkF7 = 0x76;
constexpr uint32_t kVkConvert = 0x1C, kVkNonConvert = 0x1D, kVkKanji = 0x19, kVkShift = 0x10, kVkNext = 0x22;
constexpr uint32_t kVkOem3 = 0xC0, kVkImeOn = 0x16, kVkR = 'R', kVkS = 'S', kVkC = 'C', kVkE = 'E', kVkEscape = 0x1B;

void TestJsonRoundTripKeepsJapaneseAndEscapes() {
    auto parsed = azookey::json::Parse(R"({"text":"日本\u8a9e","list":[1,true,null],"quote":"a\"b\n"})");
    Check(parsed.has_value(), "JSON with escapes parses");
    Check((*parsed)["text"].AsString() == "日本語", "\\u escape decodes to UTF-8");
    Check((*parsed)["list"].AsArray().size() == 3, "array keeps every element");
    Check((*parsed)["quote"].AsString() == "a\"b\n", "quote and newline escapes decode");
    Check((*parsed)["missing"].IsNull(), "missing member reads as null");
    auto again = azookey::json::Parse(azookey::json::Serialize(*parsed));
    Check(again && (*again)["text"].AsString() == "日本語", "serialized JSON parses back");
}

void TestJsonRejectsMalformedInput() {
    Check(!azookey::json::Parse("{\"a\":}").has_value(), "missing value is rejected");
    Check(!azookey::json::Parse("{\"a\":1} trailing").has_value(), "trailing garbage is rejected");
    Check(!azookey::json::Parse("\"\\ud800\"").has_value(), "lone surrogate escape is rejected");
    Check(!azookey::json::Parse(std::string(200, '[') + std::string(200, ']')).has_value(), "excessive nesting is rejected");
}

void TestQuoteEscapesControlCharacters() {
    // Ctrl+Z would end a text-mode stream on Windows; it must never be sent raw.
    Check(azookey::json::Quote(std::string("a\x1a" "b")) == "\"a\\u001ab\"", "Ctrl+Z is escaped");
}

void TestUtf16OffsetsCountSurrogatePairs() {
    std::wstring text = azookey::text::Utf8ToUtf16("𠮷野家");
    Check(text.size() == 4, "a character outside the BMP takes two UTF-16 units");
    Check(azookey::text::ScalarOffsetToUtf16(text, 1) == 2, "caret after 𠮷 is at UTF-16 offset 2");
    Check(azookey::text::ScalarOffsetToUtf16(text, 3) == 4, "caret at the end is the full length");
    Check(azookey::text::ScalarOffsetToUtf16(text, 10) == 4, "offsets past the end clamp");
    Check(azookey::text::Utf16ToUtf8(text) == "𠮷野家", "UTF-16 converts back to the same UTF-8");
    Check(azookey::text::Utf8ToUtf16("\xff") == L"\xfffd", "invalid UTF-8 becomes U+FFFD");
}

void TestScalarWindowsKeepSurrogatePairsWhole() {
    std::wstring text = azookey::text::Utf8ToUtf16("a𠮷b𠮷");
    Check(azookey::text::ScalarCount(text) == 4, "a surrogate pair counts as one scalar");
    Check(azookey::text::LastScalars(text, 2) == azookey::text::Utf8ToUtf16("b𠮷"), "the last scalars keep the trailing pair whole");
    Check(azookey::text::FirstScalars(text, 2) == azookey::text::Utf8ToUtf16("a𠮷"), "the first scalars keep the pair whole");
    Check(azookey::text::LastScalars(text, 10) == text, "asking for more scalars than there are returns the text");
}

void TestPrintableKeysStartCompositionOnlyWhenInputIsOn() {
    KeyState on{true, false, false};
    KeyState off{false, false, false};
    Check(Classify(kVkA, {}, L"a", on) == KeyAction::SendToConverter, "a letter starts a composition when input is on");
    Check(Classify(kVkA, {}, L"a", off) == KeyAction::PassThrough, "a letter passes through when input is off");
    Check(Classify(kVkReturn, {}, L"", on) == KeyAction::PassThrough, "Enter without a composition reaches the application");
    Check(Classify(kVkBack, {}, L"", on) == KeyAction::PassThrough, "Backspace without a composition reaches the application");
    const std::vector<azookey::keys::KeyBinding> noShortcuts;
    KeyState listed = on;
    listed.coreShortcuts = &noShortcuts;
    Check(Classify(kVkA, {false, true, false}, L"a", listed) == KeyAction::PassThrough,
          "Ctrl+A stays an application shortcut once Core's list is known");
}

azookey::keys::KeyBinding Binding(const char* key, int modifiers, const char* command) {
    azookey::keys::KeyBinding binding;
    binding.key = key;
    binding.modifiers = modifiers;
    binding.command = command;
    return binding;
}

void TestKeyBindingsMatchLikeCore() {
    auto save = Binding("s", 2, "suggestion");
    Check(save.Matches(Translate(kVkS, {false, true, false}, L"s")), "Ctrl+S matches its binding");
    Check(!save.Matches(Translate(kVkS, {true, true, false}, L"S")), "modifiers must be exactly equal");
    Check(Binding("s", 3, "toggleContext").Matches(Translate(kVkS, {true, true, false}, L"S")),
          "Shift's capital letter is compared lowercased");
    azookey::keys::KeyBinding escape;
    escape.keyCode = 53;
    escape.command = "cancel";
    Check(escape.Matches(Translate(kVkEscape, {}, L"")), "keys without text match by key code");
    std::vector<azookey::keys::KeyBinding> bindings{save, escape};
    const auto* found = azookey::keys::FindBinding(Translate(kVkEscape, {}, L""), bindings);
    Check(found && found->command == "cancel", "the first matching binding names the command");
}

void TestCoreShortcutsDecideWhichChordsReachCore() {
    std::vector<azookey::keys::KeyBinding> shortcuts{Binding("s", 2, "suggestion"), Binding("e", 6, "prompt")};
    KeyState listed{true, false, false};
    listed.coreShortcuts = &shortcuts;
    Modifiers control{false, true, false};
    Modifiers controlAlt{false, true, true};
    Check(Classify(kVkS, control, L"s", listed) == KeyAction::SendToConverter, "Ctrl+S asks Core for AI candidates");
    Check(Classify(kVkC, control, L"c", listed) == KeyAction::PassThrough, "Ctrl+C stays the application's once the list is known");
    Check(Classify(kVkE, controlAlt, L"e", listed) == KeyAction::PassThrough, "a prompt chord without a selection stays the application's");
    KeyState selected = listed;
    selected.hasSelection = true;
    Check(Classify(kVkE, controlAlt, L"e", selected) == KeyAction::SendToConverter, "a prompt chord on a selection reaches Core");
    KeyState unknown{true, false, false};
    Check(Classify(kVkC, control, L"c", unknown) == KeyAction::SendToConverter, "before the list arrives every Control chord reaches Core");
    Check(Classify(kVkE, {false, false, true}, L"e", unknown) == KeyAction::PassThrough, "Alt alone without a selection stays a menu key");
    KeyState reviewing{true, false, false};
    reviewing.aiReviewOpen = true;
    Check(Classify(kVkA, {}, L"a", reviewing) == KeyAction::SendToConverter, "an open review sees the next key first");
    Check(Classify(0x10, {true, false, false}, L"", reviewing) == KeyAction::PassThrough, "a bare modifier does not close the review");
}

void TestReconversionShortcutsReachCore() {
    KeyState on{true, false, false};
    Modifiers controlShift{true, true, false};
    Check(Classify(kVkBack, controlShift, L"", on) == KeyAction::SendToConverter, "Ctrl+Shift+Backspace asks Core to undo the commit");
    Check(Classify(kVkR, controlShift, L"R", on) == KeyAction::SendToConverter, "Ctrl+Shift+R asks Core to reconvert the selection");
    const std::vector<azookey::keys::KeyBinding> noShortcuts;
    KeyState listed = on;
    listed.coreShortcuts = &noShortcuts;
    Check(Classify(kVkBack, {false, true, false}, L"", listed) == KeyAction::PassThrough, "Ctrl+Backspace stays the application's");
    Check(Classify(kVkR, controlShift, L"R", {false, false, false}) == KeyAction::PassThrough, "the shortcuts need Japanese input on");
    auto undo = Translate(kVkBack, controlShift, L"");
    Check(undo.keyCode == 51 && undo.modifierFlags == 3, "Ctrl+Shift+Backspace matches Core's ReconversionShortcut");
}

void TestCompositionKeepsEditingKeys() {
    KeyState composing{true, true, false};
    Check(Classify(kVkBack, {}, L"", composing) == KeyAction::SendToConverter, "Backspace edits the composition");
    Check(Classify(kVkLeft, {true, false, false}, L"", composing) == KeyAction::SendToConverter, "Shift+Left changes the clause");
    Check(Classify(kVkNext, {}, L"", composing) == KeyAction::NextPage, "PageDown pages candidates inside the IME");
    Check(Classify(kVkShift, {true, false, false}, L"", composing) == KeyAction::PassThrough, "a bare modifier never reaches the converter");
    Check(Classify(kVkA, {false, false, true}, L"a", composing) == KeyAction::PassThrough, "Alt combinations stay menu shortcuts");
}

void TestModeKeys() {
    KeyState on{true, false, false};
    KeyState composing{true, true, false};
    KeyState off{false, false, false};
    Check(Classify(kVkKanji, {}, L"", off) == KeyAction::ToggleInput, "半角/全角 toggles input");
    Check(Classify(kVkOem3, {false, false, true}, L"`", off) == KeyAction::ToggleInput, "Alt+` toggles input on US layouts");
    Check(Classify(kVkImeOn, {}, L"", off) == KeyAction::TurnInputOn, "the IME-on key turns input on");
    Check(Classify(kVkNonConvert, {}, L"", on) == KeyAction::TurnInputOff, "無変換 leaves Japanese input");
    Check(Classify(kVkConvert, {}, L"", off) == KeyAction::TurnInputOn, "変換 turns Japanese input on");
    Check(Classify(kVkNonConvert, {}, L"", off) == KeyAction::PassThrough, "無変換 while input is off reaches the application");
    Check(Classify(kVkConvert, {}, L"", on) == KeyAction::TurnInputOn, "変換 without a composition keeps Japanese input");
    Check(Classify(kVkConvert, {}, L"", composing) == KeyAction::SendToConverter, "変換 converts while composing");
    Check(Classify(kVkA, {}, L"a", {true, false, true}) == KeyAction::PassThrough, "password fields bypass the converter");
}

void TestTranslationUsesCoreKeyCodes() {
    Check(Translate(kVkSpace, {}, L" ").keyCode == 49, "Space becomes kVK_Space");
    Check(Translate(kVkConvert, {}, L"").keyCode == 49, "変換 converts like Space");
    Check(Translate(kVkReturn, {}, L"").keyCode == 36, "Enter becomes kVK_Return");
    Check(Translate(kVkBack, {}, L"").keyCode == 51, "Backspace becomes kVK_Delete");
    Check(Translate(kVkF7, {}, L"").keyCode == 98, "F7 becomes kVK_F7");
    auto digit = Translate('1', {}, L"1");
    Check(digit.keyCode == 18 && digit.characters == "1", "1 keeps its text and kVK_ANSI_1 for candidate selection");
    auto letter = Translate(kVkA, {true, false, false}, L"A");
    Check(letter.keyCode == 0xFFFF && letter.characters == "A" && letter.modifierFlags == 1, "Shift+A sends the typed text with Shift");
}

void TestKeyRequestMatchesBridgeContract() {
    azookey::protocol::RequestContext context{"ctx", {L"前の文", false}};
    std::string request = azookey::protocol::KeyRequest(context, Translate(kVkA, {true, false, false}, L"A"), {});
    auto parsed = azookey::json::Parse(request);
    Check(parsed.has_value(), "key request is valid JSON");
    Check((*parsed)["operation"].AsString() == "key", "operation is key");
    Check((*parsed)["event"]["characters"].AsString() == "A", "characters keep the case");
    Check((*parsed)["event"]["charactersIgnoringModifiers"].AsString() == "a", "charactersIgnoringModifiers is lowercased");
    Check((*parsed)["leftContext"].AsString() == "前の文", "left context is sent as UTF-8");
    std::wstring longContext(150, L'あ');
    auto trimmed = azookey::json::Parse(azookey::protocol::ResetRequest({"ctx", {longContext, false}}, true));
    Check(azookey::text::Utf8ToUtf16((*trimmed)["leftContext"].AsString()).size() == 100, "left context keeps the last 100 units");
}

azookey::protocol::ReconversionContext SampleField() {
    azookey::protocol::ReconversionContext field;
    field.before = L"前";
    field.selected = L"選択";
    field.after = L"後";
    field.cursorUTF16 = 12;  // the caret after the selection, 10 units into the document
    field.anchorUTF16 = 10;
    field.canReplace = true;
    return field;
}

void TestReconversionRequestsCarryTheField() {
    azookey::protocol::RequestContext context{"ctx", {L"前", false, SampleField()}};
    auto undo = azookey::json::Parse(azookey::protocol::UndoCommitRequest(context));
    Check(undo && (*undo)["operation"].AsString() == "undo-commit", "undo-commit request");
    const auto& field = (*undo)["reconversionContext"];
    Check(field["before"].AsString() == "前" && field["selected"].AsString() == "選択" && field["after"].AsString() == "後",
          "the field's text is sent");
    Check(field["cursorUTF16"].AsInteger(0) == 12 && field["anchorUTF16"].AsInteger(0) == 10, "positions are sent as given");
    Check(field["canReplace"].AsBoolean(false) && !field["isSensitive"].AsBoolean(true), "replaceability is sent");
    auto reconvert = azookey::json::Parse(azookey::protocol::ReconvertRequest(context));
    Check(reconvert && (*reconvert)["operation"].AsString() == "reconvert", "reconvert request");
    auto confirm = azookey::json::Parse(azookey::protocol::ConfirmReconversionRequest(context, "token-1"));
    Check(confirm && (*confirm)["operation"].AsString() == "confirm-reconversion" &&
              (*confirm)["reconversionToken"].AsString() == "token-1",
          "confirm-reconversion carries the token");
    auto reading = azookey::json::Parse(azookey::protocol::ReconversionReadingRequest(context, Translate(kVkA, {}, L"a")));
    Check(reading && (*reading)["operation"].AsString() == "reconversion-reading" && (*reading)["event"]["characters"].AsString() == "a",
          "reading keys go to reconversion-reading");
    auto plain = azookey::json::Parse(azookey::protocol::KeyRequest({"ctx", {}}, Translate(kVkA, {}, L"a"), {}));
    Check(plain && (*plain)["reconversionContext"].kind() == azookey::json::Value::Kind::Null, "no field, no reconversionContext");
}

void TestCommitAdvancesTheDocumentLikeCore() {
    azookey::protocol::DocumentContext document{L"前", false, SampleField()};
    auto advanced = azookey::protocol::AdvancedPastCommit(document, L"漢字");
    Check(advanced.leftContext == L"前漢字", "the left context gains the commit");
    const auto& field = *advanced.reconversion;
    Check(field.before == L"前漢字" && field.selected.empty() && field.after == L"後", "the commit replaces the selection");
    Check(field.cursorUTF16 == 12 && field.anchorUTF16 == 12, "the caret ends after the commit, counted from the selection start");
    document.reconversion->before = std::wstring(256, L'あ');
    auto trimmed = azookey::protocol::AdvancedPastCommit(document, L"漢字");
    Check(trimmed.reconversion->before.size() == 256 && trimmed.reconversion->before.substr(254) == L"漢字",
          "the field keeps Core's 256-scalar window");
}

void TestSnapshotParsing() {
    auto snapshot = azookey::protocol::ParseSnapshot(
        R"({"consumed":true,"preedit":"日本語","preeditSegments":[{"text":"日本語","focus":"focused"},{"text":"","focus":"unfocused"}],)"
        R"("cursor":3,"commits":["前"],"candidates":[{"index":0,"text":"日本語","annotation":"","tokens":[]}],)"
        R"("selection":0,"generation":7,"pageStart":0,"showCandidateIndex":true,"language":"japanese","zenzaiLoaded":true})");
    Check(snapshot.has_value(), "snapshot parses");
    Check(!snapshot->reconversion && snapshot->reconversionError.empty() && !snapshot->reconversionReading,
          "an ordinary snapshot has no reconversion state");
    Check(snapshot->preedit == L"日本語" && snapshot->cursorScalars == 3, "preedit and caret are read");
    Check(snapshot->segments.size() == 1 && snapshot->segments[0].focus == azookey::protocol::SegmentFocus::Focused,
          "the empty trailing segment is dropped");
    Check(snapshot->showCandidateIndex, "converting shows the candidate list");
    Check(snapshot->zenzaiLoaded, "the Zenzai state is read");
    // While typing, Core still reports a selected index for live conversion.
    auto typing = azookey::protocol::ParseSnapshot(
        R"({"consumed":true,"preedit":"n","preeditSegments":[{"text":"n","focus":"none"}],"selection":0,"showCandidateIndex":false})");
    Check(typing && typing->selection == 0 && !typing->showCandidateIndex, "typing keeps a selection without the candidate list");
    Check(typing && typing->segments[0].focus == azookey::protocol::SegmentFocus::None, "typing has no clause focus");
    Check(snapshot->commits.size() == 1 && snapshot->commits[0] == L"前", "commits are read");
    Check(snapshot->selection == 0 && snapshot->generation == 7, "selection and generation are read");
    auto idle = azookey::protocol::ParseSnapshot(R"({"consumed":false,"preedit":"","selection":null})");
    Check(idle && !idle->selection.has_value(), "a null selection means no candidate is being chosen");
    Check(idle && !idle->zenzaiLoaded, "a reply without the Zenzai state means Zenzai is not loaded");
    Check(!azookey::protocol::ParseSnapshot("not json").has_value(), "a broken line is not a snapshot");
}

void TestReconversionReplyParsing() {
    auto replacement = azookey::protocol::ParseSnapshot(
        R"({"consumed":true,"preedit":"","commits":[],"reconversion":{"token":"t","offset":-3,"count":3,"text":"日本語","reading":"にほんご",)"
        R"("removedContext":{"before":"","selected":"","after":"","cursorUTF16":0,"anchorUTF16":0,"canReplace":true,"isSensitive":false}}})");
    Check(replacement && replacement->reconversion && replacement->reconversion->token == "t" &&
              replacement->reconversion->offset == -3 && replacement->reconversion->count == 3 &&
              replacement->reconversion->text == L"日本語",
          "a replacement is read");
    auto reading = azookey::protocol::ParseSnapshot(
        R"({"consumed":true,"preedit":"","commits":[],"reconversionError":"reading_required","reconversionReading":""})");
    Check(reading && reading->reconversionError == "reading_required" && reading->reconversionReading == L"",
          "an empty reading still means the reading prompt is open");
}

void TestAIRepliesAndRequests() {
    auto shortcuts = azookey::protocol::ParseImeShortcuts(
        R"({"shortcuts":[{"key":"s","modifiers":2,"command":"suggestion"},{"keyCode":53,"modifiers":0,"command":"cancel"},{"modifiers":2}]})");
    Check(shortcuts && shortcuts->size() == 2 && (*shortcuts)[1].keyCode == 53, "ime-shortcuts are read and malformed items skipped");
    Check(!azookey::protocol::ParseImeShortcuts(R"({"preedit":""})"), "a reply without shortcuts is not a list");

    auto review = azookey::protocol::ParseSnapshot(
        R"({"consumed":true,"preedit":"にほんご","ai":{"review":{"id":7,"target":"にほんご","destination":"api.example.com:8443",)"
        R"("includeContext":false,"bindings":[{"key":"s","modifiers":2,"command":"send"}]}}})");
    Check(review && review->aiReview && review->aiReview->id == 7 && review->aiReview->destination == L"api.example.com:8443" &&
              review->aiReview->bindings.size() == 1,
          "a suggestion review is read from the key reply");
    auto prompt = azookey::protocol::ParseSnapshot(R"({"consumed":true,"preedit":"","ai":{"prompt":{"initialPrompt":"敬語に直す"}}})");
    Check(prompt && prompt->aiPrompt == L"敬語に直す" && !prompt->aiReview, "an instruction window request is read");

    azookey::protocol::RequestContext context{"ctx", {L"", false}};
    auto send = azookey::json::Parse(azookey::protocol::AIReviewSendRequest(context, 7, true));
    Check(send && (*send)["operation"].AsString() == "ai-review-send" && (*send)["ai"]["review"].AsInteger() == 7 &&
              (*send)["ai"]["includeContext"].AsBoolean(false),
          "ai-review-send names the review and the context choice");
    Check(!azookey::protocol::ParseAIReviewSend("{}"), "an empty reply means the review no longer applies");
    auto allowed = azookey::protocol::ParseAIReviewSend(
        R"({"request":{"target":"にほんご","leftContext":"","rightContext":"","includeContext":false,"aiModel":"m",)"
        R"("aiEndpoint":"https://api.example.com/v1","apiKey":"from-the-application"},"generation":12,"reading":"にほんご"})");
    Check(allowed && allowed->generation == 12 && allowed->reading == L"にほんご", "Core's request arguments are kept");
    auto line = azookey::json::Parse(azookey::protocol::AISuggestionsLine(*allowed));
    Check(line && (*line)["operation"].AsString() == "ai" && (*line)["target"].AsString() == "にほんご" && !(*line).Has("apiKey"),
          "the ai line passes Core's arguments on and never carries a key from the application");
    auto texts = azookey::protocol::ParseAISuggestions(R"({"suggestions":["日本語","二本後"]})");
    Check(texts && texts->size() == 2 && (*texts)[1] == L"二本後", "AI suggestions are read");
    Check(!azookey::protocol::ParseAISuggestions(R"({"consumed":false,"error":"invalid_request"})"), "a failed AI request has no suggestions");
    auto suggestions = azookey::json::Parse(azookey::protocol::SuggestionsRequest(context, {L"日本語"}, 12, L"にほんご"));
    Check(suggestions && (*suggestions)["operation"].AsString() == "suggestions" && (*suggestions)["generation"].AsInteger() == 12 &&
              (*suggestions)["suggestions"].AsArray().size() == 1,
          "suggestions go back to the reviewed composition");
    auto withSelection = azookey::json::Parse(azookey::protocol::KeyRequest(context, Translate(kVkE, {false, true, true}, L"e"), {true}));
    Check(withSelection && (*withSelection)["ai"]["hasSelection"].AsBoolean(false), "a key on a selection says so");
}

void TestAITransformationRequestsAndReplies() {
    azookey::protocol::RequestContext context{"ctx", {}};
    azookey::protocol::AITextField field;
    field.identity = {"tsf", "0001", "0002"};
    field.surrounding = azookey::protocol::AISurrounding{L"前 原文 後", 2, 4};
    auto open = azookey::json::Parse(azookey::protocol::AITransformOpenRequest(context, field));
    const auto& sent = (*open)["ai"]["field"];
    Check(open && (*open)["operation"].AsString() == "ai-transform-open" && sent["identity"].AsArray().size() == 3,
          "ai-transform-open carries the field's identity");
    Check(sent["surrounding"]["text"].AsString() == "前 原文 後" && sent["surrounding"]["cursorUTF16"].AsInteger() == 2 &&
              sent["hasSurroundingUpdate"].AsBoolean(false) && !sent["isSensitive"].AsBoolean(true),
          "the surrounding text is sent as read now");
    azookey::protocol::AITextField unnamed;
    auto openUnnamed = azookey::json::Parse(azookey::protocol::AITransformOpenRequest(context, unnamed));
    Check((*openUnnamed)["ai"]["field"]["identity"].IsNull() && !(*openUnnamed)["ai"]["field"]["hasSurroundingUpdate"].AsBoolean(true),
          "a field that cannot be named sends null and no surrounding update");

    azookey::protocol::AISelectionWitness witness;
    witness.object = {"tsf-context", "0002"};
    witness.window = {"0003"};
    witness.start = 12;
    witness.end = 14;
    witness.selected = L"原文";
    auto take = azookey::json::Parse(azookey::protocol::AITransformRequest(context, "ai-transform-take", 3, {field, witness}));
    Check(take && (*take)["operation"].AsString() == "ai-transform-take" && (*take)["ai"]["transformation"].AsInteger() == 3 &&
              (*take)["ai"]["witness"]["start"].AsInteger() == 12 && (*take)["ai"]["witness"]["selected"].AsString() == "原文",
          "ai-transform-take carries the field and the witness");
    auto close = azookey::json::Parse(azookey::protocol::AITransformRequest(context, "ai-transform-close", 3, {}));
    Check(close && !(*close)["ai"].Has("field") && !(*close)["ai"].Has("witness"), "closing needs only the id");

    auto opened = azookey::protocol::ParseAITransformOpen(
        R"({"transformation":3,"target":"原文","needsWitness":true,"history":[{"prompt":"敬語に直す","pinned":true,"shortcutText":""}]})");
    Check(opened && opened->transformation == 3 && opened->needsWitness, "an opened transformation is read");
    Check(!azookey::protocol::ParseAITransformOpen("{}"), "an empty reply opens nothing");
    auto host = azookey::json::Parse(azookey::protocol::HostOpenAITransformRequest(context, *opened, L"敬語に直す", field));
    Check(host && (*host)["operation"].AsString() == "host-open-ai-transform" && (*host)["open"]["target"].AsString() == "原文" &&
              (*host)["initialPrompt"].AsString() == "敬語に直す" && (*host)["context"].AsString() == "ctx",
          "the host gets Core's answer, the prompt and the field");

    auto taken = azookey::protocol::ParseAITransformReply(R"({"transformation":3,"replacement":"変換した本文"})");
    Check(taken && taken->replacement == L"変換した本文" && !taken->stale, "the confirmed result is read once");
    auto stale = azookey::protocol::ParseAITransformReply(R"({"transformation":3,"stale":true})");
    Check(stale && stale->stale && !stale->matches, "a stale transformation is recognised");
    auto matches = azookey::protocol::ParseAITransformReply(R"({"transformation":3,"matches":true})");
    Check(matches && matches->matches, "a matching return is read");
}

void TestTreeAndPageParsing() {
    auto snapshot = azookey::protocol::ParseSnapshot(
        R"({"inputState":"composing","preedit":"日本語","nodes":[)"
        R"({"id":0,"text":"日本","reading":"にほん","parent":null,"children":[1],"terminals":[],"depth":0,)"
        R"("preview":{"candidateIndex":2,"text":"日本"},"scorePresentation":{"label":"80","detailDescription":"相対スコア 80","role":"scoreHigh"}},)"
        R"({"id":1,"text":"語","reading":"ご","parent":0,"children":[],"terminals":[0],"depth":1}],)"
        R"("columns":[[0],[1]],"selectedPath":[0,1],"focusedNode":1,)"
        R"("candidatePage":{"totalCount":12,"position":3,"start":0,"items":[{"index":0,"text":"日本語","reading":"にほんご","annotation":null,"detailDescription":"日本語"}],"previousIndex":null,"nextIndex":9},)"
        R"("candidateTextSize":"large","showRelativeScores":true})");
    Check(snapshot.has_value(), "a snapshot with a tree parses");
    Check(snapshot->inputState == "composing", "the input state is read");
    Check(snapshot->nodes.size() == 2 && !snapshot->nodes[0].parent && snapshot->nodes[1].parent == 0, "nodes keep their parents");
    Check(snapshot->nodes[0].previewCandidateIndex == 2, "a node's preview candidate is read");
    Check(snapshot->nodes[0].score && snapshot->nodes[0].score->role == "scoreHigh", "Core's score role is read");
    Check(snapshot->columns.size() == 2 && snapshot->columns[1][0] == 1, "columns are read");
    Check(snapshot->selectedPath.size() == 2 && snapshot->focusedNode == 1, "the selected path and focus are read");
    Check(snapshot->candidatePage.totalCount == 12 && snapshot->candidatePage.position == 3, "the page position is read");
    Check(!snapshot->candidatePage.previousIndex && snapshot->candidatePage.nextIndex == 9, "page neighbors are read");
    Check(snapshot->largeText && snapshot->showRelativeScores, "presentation settings are read");
    Check(snapshot->FindNode(1) && snapshot->FindNode(1)->text == L"語" && !snapshot->FindNode(5), "nodes are found by id");
    auto settings = azookey::protocol::ParsePresentationSettings(R"({"settings":{"tree":false}})");
    Check(settings && !settings->treeCandidates, "the tree setting is read from the settings reply");
}

void TestCandidateDisplayParsing() {
    // The example from docs/candidate-display.md.
    auto snapshot = azookey::protocol::ParseSnapshot(
        R"({"preedit":"にほんご","candidateDisplay":{"mode":"list","columns":[[1,0,3],[2]],"showsNumbers":true,"baseFontSize":18,)"
        R"("detailNode":1,"expandTree":false,"announcement":"変換候補 2 / 56。にほん",)"
        R"("nodes":[{"id":1,"number":2,"selected":true,"focused":true,"accessibleName":"にほん（ニホン）","accessibleDescription":"操作対象","detailText":"にほん"}],)"
        R"("list":{"title":"確定する文章","commitText":"にほんご","readingText":"読み にほんご","positionText":"変換候補 2 / 56",)"
        R"("keyboardConfirmsCandidate":true,"confirmLabel":"確定 ↵","confirmAccessibleName":"確定 にほんご","confirmAccessibleDescription":"押すと候補を確定",)"
        R"("confirmIndex":1,"previousIndex":null,"nextIndex":9,"items":[{"index":0,"number":1,"text":"日本語","selected":false,)"
        R"("accessibleName":"日本語（にほんご）","accessibleDescription":"押すと候補を選択","detailText":"確定予定: 日本語"}]}}})");
    Check(snapshot.has_value(), "a snapshot with candidateDisplay parses");
    const auto& shown = snapshot->display;
    Check(shown.mode == azookey::display::DisplayMode::List, "the display mode is read");
    Check(shown.columns.size() == 2 && shown.columns[0].size() == 3 && shown.columns[1][0] == 2, "display columns are read");
    Check(shown.showsNumbers && shown.baseFontSize == 18 && shown.detailNode == 1 && !shown.expandTree, "display flags are read");
    Check(shown.announcement == L"変換候補 2 / 56。にほん", "the announcement is read");
    const auto* node = shown.FindNode(1);
    Check(node && node->number == 2 && node->selected && node->focused && node->accessibleName == L"にほん（ニホン）", "display nodes are read");
    Check(shown.list && shown.list->confirmIndex == 1 && !shown.list->previousIndex && shown.list->nextIndex == 9, "list buttons are read");
    Check(shown.list && shown.list->items.size() == 1 && shown.list->items[0].number == 1 && shown.list->items[0].text == L"日本語",
          "list items are read");
    Check(shown.list && shown.list->confirmLabel == L"確定 ↵" && shown.list->positionText == L"変換候補 2 / 56", "list wording is Core's");
    auto hidden = azookey::protocol::ParseSnapshot(R"({"preedit":""})");
    Check(hidden && hidden->display.mode == azookey::display::DisplayMode::Hidden, "a reply without candidateDisplay shows nothing");
}

void TestLayoutRequestAndResult() {
    azookey::display::LayoutRequest request;
    request.mode = azookey::display::DisplayMode::Tree;
    request.measuredFontSize = 18;
    request.columns = {{{{0, std::nullopt}, {1, 0}}, 54.5f}};
    request.documentWordWidths = std::vector<float>{60.0f};
    request.columnAnchorX = 100.0f;
    request.lineHeight = 25.5f;
    request.showNumbers = true;
    request.cursor = {300.0f, 200.0f, 0.0f, 24.0f};
    request.workArea = {0.0f, 32.0f, 1280.0f, 768.0f};
    auto line = azookey::json::Parse(azookey::display::LayoutRequestLine(request));
    Check(line.has_value(), "the layout request is valid JSON");
    const auto& layout = (*line)["layout"];
    Check((*line)["operation"].AsString() == "candidate-layout" && !(*line).Has("context"), "candidate-layout needs no context");
    Check(layout["mode"].AsString() == "tree" && layout["textSize"].AsString() == "standard", "mode and text size are sent");
    Check(layout["columns"].AsArray()[0]["nodes"].AsArray()[1]["parent"].AsInteger() == 0, "node parents are sent");
    Check(layout["columns"].AsArray()[0]["nodes"].AsArray()[0]["parent"].IsNull(), "a root node has a null parent");
    Check(layout["documentWordWidths"].AsArray().size() == 1 && layout["columnAnchorX"].AsNumber() == 100, "document words are sent");
    Check(layout["lineHeight"].AsNumber() == 25.5, "the measured line height is sent");
    Check(!layout.Has("popupHeight") && !layout.Has("preferredSide"), "optional members are left out");
    request.popupHeight = 181;
    auto placed = azookey::json::Parse(azookey::display::LayoutRequestLine(request));
    Check((*placed)["layout"]["popupHeight"].AsNumber() == 181, "the popup height is sent in whole DIPs");

    auto result = azookey::display::ParseLayoutResult(
        R"({"candidateLayout":{"popupWidth":240,"placementStatus":"placed","placement":{"x":300,"y":224,"width":240,"height":180,"side":"below"},)"
        R"("tree":{"aligned":false,"reason":"unavailable-or-narrow","textAlignment":"center","rowHeight":66,)"
        R"("metrics":{"fontSize":18,"numberFontSize":12,"scoreFontSize":12,"wordHeight":32,"numberHeight":18,"scoreHeight":16,)"
        R"("scoreBadgeMinimumWidth":24,"scoreBadgeHorizontalInset":4},)"
        R"("nodes":[{"id":0,"column":0,"row":0,"frame":{"x":12,"y":6,"width":66,"height":66},"textFrame":{"x":16,"y":6,"width":58,"height":32},)"
        R"("scoreFrame":{"x":12,"y":38,"width":66,"height":16},"numberFrame":{"x":18,"y":54,"width":54,"height":18}}],)"
        R"("edges":[{"node":0,"start":{"x":4,"y":39},"end":{"x":12,"y":39}}],"rootAnchor":{"x":4,"y":39},"contentSize":{"width":90,"height":216}}}})");
    Check(result.has_value(), "the layout result parses");
    Check(result->popupWidth == 240 && result->placementStatus == "placed" && result->side == "below", "placement is read");
    Check(result->placement && result->placement->y == 224 && result->placement->height == 180, "the placement frame is read");
    Check(result->tree && !result->tree->aligned && !result->tree->leadingText, "tree alignment is read");
    Check(result->tree && result->tree->metrics.numberHeight == 18 && result->tree->metrics.wordHeight == 32, "tree metrics are read");
    Check(result->tree && result->tree->metrics.scoreBadgeMinimumWidth == 24 && result->tree->metrics.scoreBadgeHorizontalInset == 4,
          "score badge dimensions come from Core");
    Check(result->tree && result->tree->nodes.size() == 1 && result->tree->nodes[0].numberFrame &&
              result->tree->nodes[0].numberFrame->y == 54, "node frames are read");
    Check(result->tree && result->tree->edges.size() == 1 && result->tree->edges[0].start.x == 4, "edges are read");
    Check(result->tree && result->tree->contentHeight == 216, "the content size is read");
    Check(!azookey::display::ParseLayoutResult(R"({"error":"invalid_request"})").has_value(), "an error reply is not a layout");
}

}  // namespace

int main() {
    TestJsonRoundTripKeepsJapaneseAndEscapes();
    TestJsonRejectsMalformedInput();
    TestQuoteEscapesControlCharacters();
    TestUtf16OffsetsCountSurrogatePairs();
    TestScalarWindowsKeepSurrogatePairsWhole();
    TestPrintableKeysStartCompositionOnlyWhenInputIsOn();
    TestReconversionShortcutsReachCore();
    TestKeyBindingsMatchLikeCore();
    TestCoreShortcutsDecideWhichChordsReachCore();
    TestCompositionKeepsEditingKeys();
    TestModeKeys();
    TestTranslationUsesCoreKeyCodes();
    TestKeyRequestMatchesBridgeContract();
    TestReconversionRequestsCarryTheField();
    TestCommitAdvancesTheDocumentLikeCore();
    TestSnapshotParsing();
    TestReconversionReplyParsing();
    TestAIRepliesAndRequests();
    TestAITransformationRequestsAndReplies();
    TestTreeAndPageParsing();
    TestCandidateDisplayParsing();
    TestLayoutRequestAndResult();
    std::printf("%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
