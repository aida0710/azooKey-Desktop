#include "bridge_protocol.h"

#include <algorithm>
#include <cctype>

#include "json.h"
#include "text_encoding.h"

namespace azookey::protocol {
namespace {

// The bridge keeps only this much surrounding text (DesktopSession), so sending
// more would only enlarge every request.
constexpr size_t kMaximumLeftContextUnits = 100;

std::string CommonFields(const RequestContext& context) {
    std::wstring left = context.leftContext;
    if (left.size() > kMaximumLeftContextUnits) left = left.substr(left.size() - kMaximumLeftContextUnits);
    return ",\"context\":" + json::Quote(context.context) + ",\"leftContext\":" + json::Quote(text::Utf16ToUtf8(left)) +
           ",\"privateInput\":" + (context.privateInput ? "true" : "false");
}

std::string AsciiLowercase(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) {
        return static_cast<char>(c < 0x80 ? std::tolower(c) : c);
    });
    return text;
}

}  // namespace

std::string KeyRequest(const RequestContext& context, const keys::CoreKeyEvent& event) {
    std::string characters = event.characters ? json::Quote(*event.characters) : "null";
    std::string ignoring = event.characters ? json::Quote(AsciiLowercase(*event.characters)) : "null";
    return "{\"operation\":\"key\"" + CommonFields(context) + ",\"event\":{\"keyCode\":" + std::to_string(event.keyCode) +
           ",\"characters\":" + characters + ",\"charactersIgnoringModifiers\":" + ignoring +
           ",\"modifierFlags\":" + std::to_string(event.modifierFlags) + "}}";
}

std::string SelectRequest(const RequestContext& context, int candidateIndex, int generation, bool submit) {
    return "{\"operation\":\"select\"" + CommonFields(context) + ",\"index\":" + std::to_string(candidateIndex) +
           ",\"generation\":" + std::to_string(generation) + ",\"submit\":" + (submit ? "true" : "false") + "}";
}

std::string ResetRequest(const RequestContext& context, bool submit) {
    return "{\"operation\":\"reset\"" + CommonFields(context) + ",\"submit\":" + (submit ? "true" : "false") + "}";
}

std::string CloseRequest(const std::string& context) {
    return "{\"operation\":\"close\",\"context\":" + json::Quote(context) + "}";
}

std::optional<Snapshot> ParseSnapshot(const std::string& line) {
    auto parsed = json::Parse(line);
    if (!parsed || parsed->kind() != json::Value::Kind::Object) return std::nullopt;
    const json::Value& value = *parsed;
    Snapshot snapshot;
    snapshot.consumed = value["consumed"].AsBoolean(false);
    snapshot.preedit = text::Utf8ToUtf16(value["preedit"].AsString());
    for (const auto& segment : value["preeditSegments"].AsArray()) {
        std::wstring text = text::Utf8ToUtf16(segment["text"].AsString());
        // Core appends an empty unfocused element after the converted clause.
        if (text.empty()) continue;
        const std::string& focus = segment["focus"].AsString();
        SegmentFocus kind = focus == "focused" ? SegmentFocus::Focused
                            : focus == "unfocused" ? SegmentFocus::Unfocused
                                                   : SegmentFocus::None;
        snapshot.segments.push_back({std::move(text), kind});
    }
    snapshot.cursorScalars = static_cast<size_t>(std::max<int64_t>(0, value["cursor"].AsInteger(0)));
    for (const auto& commit : value["commits"].AsArray()) {
        if (!commit.AsString().empty()) snapshot.commits.push_back(text::Utf8ToUtf16(commit.AsString()));
    }
    for (const auto& candidate : value["candidates"].AsArray()) {
        snapshot.candidates.push_back({static_cast<int>(candidate["index"].AsInteger(0)),
                                       text::Utf8ToUtf16(candidate["text"].AsString()),
                                       text::Utf8ToUtf16(candidate["annotation"].AsString())});
    }
    if (value["selection"].kind() == json::Value::Kind::Number) {
        snapshot.selection = static_cast<int>(value["selection"].AsInteger(0));
    }
    snapshot.generation = static_cast<int>(value["generation"].AsInteger(0));
    snapshot.pageStart = static_cast<int>(value["pageStart"].AsInteger(0));
    snapshot.showCandidateIndex = value["showCandidateIndex"].AsBoolean(false);
    snapshot.japanese = value["language"].AsString() != "english";
    snapshot.error = value["error"].AsString();
    return snapshot;
}

}  // namespace azookey::protocol
