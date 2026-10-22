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

std::optional<int> OptionalInteger(const json::Value& value) {
    if (value.kind() != json::Value::Kind::Number) return std::nullopt;
    return static_cast<int>(value.AsInteger(0));
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

std::string NodeRequest(const RequestContext& context, int nodeId, int generation, bool submit) {
    return "{\"operation\":\"node\"" + CommonFields(context) + ",\"node\":" + std::to_string(nodeId) +
           ",\"generation\":" + std::to_string(generation) + ",\"submit\":" + (submit ? "true" : "false") + "}";
}

std::string SettingsRequest(const std::string& context) {
    return "{\"operation\":\"settings\",\"context\":" + json::Quote(context) + "}";
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
    snapshot.zenzaiLoaded = value["zenzaiLoaded"].AsBoolean(false);
    snapshot.error = value["error"].AsString();
    snapshot.inputState = value["inputState"].AsString();
    for (const auto& node : value["nodes"].AsArray()) {
        TreeNode item;
        item.id = static_cast<int>(node["id"].AsInteger(0));
        item.text = text::Utf8ToUtf16(node["text"].AsString());
        item.reading = text::Utf8ToUtf16(node["reading"].AsString());
        item.parent = OptionalInteger(node["parent"]);
        item.previewCandidateIndex = OptionalInteger(node["preview"]["candidateIndex"]);
        if (node["scorePresentation"].kind() == json::Value::Kind::Object) {
            const json::Value& score = node["scorePresentation"];
            item.score = ScorePresentation{text::Utf8ToUtf16(score["label"].AsString()),
                                           text::Utf8ToUtf16(score["detailDescription"].AsString()),
                                           score["role"].AsString()};
        }
        item.previewDescription = text::Utf8ToUtf16(node["previewDescription"].AsString());
        snapshot.nodes.push_back(std::move(item));
    }
    for (const auto& column : value["columns"].AsArray()) {
        std::vector<int> ids;
        for (const auto& id : column.AsArray()) ids.push_back(static_cast<int>(id.AsInteger(0)));
        snapshot.columns.push_back(std::move(ids));
    }
    for (const auto& id : value["selectedPath"].AsArray()) snapshot.selectedPath.push_back(static_cast<int>(id.AsInteger(0)));
    snapshot.focusedNode = OptionalInteger(value["focusedNode"]);
    const json::Value& page = value["candidatePage"];
    snapshot.candidatePage.totalCount = static_cast<int>(page["totalCount"].AsInteger(0));
    snapshot.candidatePage.position = OptionalInteger(page["position"]);
    snapshot.candidatePage.start = static_cast<int>(page["start"].AsInteger(0));
    for (const auto& item : page["items"].AsArray()) {
        snapshot.candidatePage.items.push_back({static_cast<int>(item["index"].AsInteger(0)),
                                                text::Utf8ToUtf16(item["text"].AsString()),
                                                text::Utf8ToUtf16(item["reading"].AsString()),
                                                text::Utf8ToUtf16(item["annotation"].AsString()),
                                                text::Utf8ToUtf16(item["detailDescription"].AsString())});
    }
    snapshot.candidatePage.previousIndex = OptionalInteger(page["previousIndex"]);
    snapshot.candidatePage.nextIndex = OptionalInteger(page["nextIndex"]);
    snapshot.largeText = value["candidateTextSize"].AsString() == "large";
    snapshot.showRelativeScores = value["showRelativeScores"].AsBoolean(false);
    return snapshot;
}

const TreeNode* Snapshot::FindNode(int id) const {
    for (const auto& node : nodes) {
        if (node.id == id) return &node;
    }
    return nullptr;
}

std::optional<PresentationSettings> ParsePresentationSettings(const std::string& line) {
    auto parsed = json::Parse(line);
    if (!parsed || (*parsed)["settings"].kind() != json::Value::Kind::Object) return std::nullopt;
    PresentationSettings settings;
    settings.treeCandidates = (*parsed)["settings"]["tree"].AsBoolean(true);
    return settings;
}

}  // namespace azookey::protocol
