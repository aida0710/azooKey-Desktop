// Unit tests for the platform-neutral pieces shared by the text service and
// the host. Run: azookey-windows-tests.exe (exit code 0 means every check passed).
#include <cstdio>
#include <string>

#include "../src/shared/bridge_protocol.h"
#include "../src/shared/json.h"
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
constexpr uint32_t kVkOem3 = 0xC0, kVkImeOn = 0x16;

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

void TestPrintableKeysStartCompositionOnlyWhenInputIsOn() {
    KeyState on{true, false, false};
    KeyState off{false, false, false};
    Check(Classify(kVkA, {}, L"a", on) == KeyAction::SendToConverter, "a letter starts a composition when input is on");
    Check(Classify(kVkA, {}, L"a", off) == KeyAction::PassThrough, "a letter passes through when input is off");
    Check(Classify(kVkReturn, {}, L"", on) == KeyAction::PassThrough, "Enter without a composition reaches the application");
    Check(Classify(kVkBack, {}, L"", on) == KeyAction::PassThrough, "Backspace without a composition reaches the application");
    Check(Classify(kVkA, {false, true, false}, L"a", on) == KeyAction::PassThrough, "Ctrl+A stays an application shortcut");
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
    azookey::protocol::RequestContext context{"ctx", L"前の文", false};
    std::string request = azookey::protocol::KeyRequest(context, Translate(kVkA, {true, false, false}, L"A"));
    auto parsed = azookey::json::Parse(request);
    Check(parsed.has_value(), "key request is valid JSON");
    Check((*parsed)["operation"].AsString() == "key", "operation is key");
    Check((*parsed)["event"]["characters"].AsString() == "A", "characters keep the case");
    Check((*parsed)["event"]["charactersIgnoringModifiers"].AsString() == "a", "charactersIgnoringModifiers is lowercased");
    Check((*parsed)["leftContext"].AsString() == "前の文", "left context is sent as UTF-8");
    std::wstring longContext(150, L'あ');
    auto trimmed = azookey::json::Parse(azookey::protocol::ResetRequest({"ctx", longContext, false}, true));
    Check(azookey::text::Utf8ToUtf16((*trimmed)["leftContext"].AsString()).size() == 100, "left context keeps the last 100 units");
}

void TestSnapshotParsing() {
    auto snapshot = azookey::protocol::ParseSnapshot(
        R"({"consumed":true,"preedit":"日本語","preeditSegments":[{"text":"日本語","focus":"focused"},{"text":"","focus":"unfocused"}],)"
        R"("cursor":3,"commits":["前"],"candidates":[{"index":0,"text":"日本語","annotation":"","tokens":[]}],)"
        R"("selection":0,"generation":7,"pageStart":0,"showCandidateIndex":true,"language":"japanese","zenzaiLoaded":true})");
    Check(snapshot.has_value(), "snapshot parses");
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

}  // namespace

int main() {
    TestJsonRoundTripKeepsJapaneseAndEscapes();
    TestJsonRejectsMalformedInput();
    TestQuoteEscapesControlCharacters();
    TestUtf16OffsetsCountSurrogatePairs();
    TestPrintableKeysStartCompositionOnlyWhenInputIsOn();
    TestCompositionKeepsEditingKeys();
    TestModeKeys();
    TestTranslationUsesCoreKeyCodes();
    TestKeyRequestMatchesBridgeContract();
    TestSnapshotParsing();
    std::printf("%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
