#include "bridge_protocol.h"

#include <algorithm>

#include "ai_protocol.h"
#include "json.h"
#include "text_encoding.h"

namespace azookey::protocol {
namespace {

// The bridge keeps only this much surrounding text (DesktopSession), so sending
// more would only enlarge every request.
constexpr size_t kMaximumLeftContextUnits = 100;
constexpr size_t kMaximumRightContextScalars = 100;

std::string ReconversionContextField(const ReconversionContext& reconversion) {
    return ",\"reconversionContext\":{\"before\":" + json::Quote(text::Utf16ToUtf8(reconversion.before)) +
           ",\"selected\":" + json::Quote(text::Utf16ToUtf8(reconversion.selected)) +
           ",\"after\":" + json::Quote(text::Utf16ToUtf8(reconversion.after)) +
           ",\"cursorUTF16\":" + std::to_string(reconversion.cursorUTF16) +
           ",\"anchorUTF16\":" + std::to_string(reconversion.anchorUTF16) +
           ",\"canReplace\":" + (reconversion.canReplace ? "true" : "false") +
           ",\"isSensitive\":" + (reconversion.isSensitive ? "true" : "false") + "}";
}

std::wstring LastUnits(const std::wstring& text, size_t units) {
    return text.size() > units ? text.substr(text.size() - units) : text;
}

std::string CommonFields(const RequestContext& context) {
    const DocumentContext& document = context.document;
    std::wstring left = LastUnits(document.leftContext, kMaximumLeftContextUnits);
    std::wstring right = text::FirstScalars(document.rightContext, kMaximumRightContextScalars);
    return ",\"context\":" + json::Quote(context.context) + ",\"leftContext\":" + json::Quote(text::Utf16ToUtf8(left)) +
           ",\"rightContext\":" + json::Quote(text::Utf16ToUtf8(right)) + ",\"privateInput\":" + (document.privateInput ? "true" : "false") +
           (document.reconversion ? ReconversionContextField(*document.reconversion) : "");
}

std::string EventField(const keys::CoreKeyEvent& event) {
    std::string characters = event.characters ? json::Quote(*event.characters) : "null";
    auto unmodified = event.CharactersIgnoringModifiers();
    std::string ignoring = unmodified ? json::Quote(*unmodified) : "null";
    return ",\"event\":{\"keyCode\":" + std::to_string(event.keyCode) + ",\"characters\":" + characters +
           ",\"charactersIgnoringModifiers\":" + ignoring + ",\"modifierFlags\":" + std::to_string(event.modifierFlags) + "}";
}

std::optional<int> OptionalInteger(const json::Value& value) {
    if (value.kind() != json::Value::Kind::Number) return std::nullopt;
    return static_cast<int>(value.AsInteger(0));
}

}  // namespace

DocumentContext AdvancedPastCommit(const DocumentContext& document, const std::wstring& committed) {
    DocumentContext advanced = document;
    advanced.leftContext = LastUnits(document.leftContext + committed, kMaximumLeftContextUnits);
    if (advanced.reconversion) {
        ReconversionContext& reconversion = *advanced.reconversion;
        int caret = std::min(reconversion.cursorUTF16, reconversion.anchorUTF16) + static_cast<int>(committed.size());
        reconversion.before = text::LastScalars(reconversion.before + committed, kReconversionContextLimit);
        reconversion.selected.clear();
        reconversion.cursorUTF16 = reconversion.anchorUTF16 = caret;
    }
    return advanced;
}

std::string KeyRequest(const RequestContext& context, const keys::CoreKeyEvent& event, const KeyFacts& facts) {
    std::string ai = facts.hasSelection ? ",\"ai\":{\"hasSelection\":true}" : "";
    return "{\"operation\":\"key\"" + CommonFields(context) + EventField(event) + ai + "}";
}

std::string ReconversionReadingRequest(const RequestContext& context, const keys::CoreKeyEvent& event) {
    return "{\"operation\":\"reconversion-reading\"" + CommonFields(context) + EventField(event) + "}";
}

std::string ConfirmReconversionRequest(const RequestContext& context, const std::string& token) {
    return "{\"operation\":\"confirm-reconversion\"" + CommonFields(context) + ",\"reconversionToken\":" + json::Quote(token) + "}";
}

std::string UndoCommitRequest(const RequestContext& context) {
    return "{\"operation\":\"undo-commit\"" + CommonFields(context) + "}";
}

std::string ReconvertRequest(const RequestContext& context) {
    return "{\"operation\":\"reconvert\"" + CommonFields(context) + "}";
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
    snapshot.display = display::ParseCandidateDisplay(value["candidateDisplay"]);
    const json::Value& reconversion = value["reconversion"];
    if (reconversion.kind() == json::Value::Kind::Object) {
        snapshot.reconversion = ReconversionReplacement{reconversion["token"].AsString(), static_cast<int>(reconversion["offset"].AsInteger(0)),
                                                        static_cast<int>(reconversion["count"].AsInteger(0)),
                                                        text::Utf8ToUtf16(reconversion["text"].AsString())};
    }
    snapshot.reconversionError = value["reconversionError"].AsString();
    if (value["reconversionReading"].kind() == json::Value::Kind::String) {
        snapshot.reconversionReading = text::Utf8ToUtf16(value["reconversionReading"].AsString());
    }
    const json::Value& ai = value["ai"];
    snapshot.aiReview = ParseAIReview(ai["review"]);
    if (ai["prompt"].kind() == json::Value::Kind::Object) {
        snapshot.aiPrompt = text::Utf8ToUtf16(ai["prompt"]["initialPrompt"].AsString());
    }
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
