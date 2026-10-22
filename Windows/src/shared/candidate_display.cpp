#include "candidate_display.h"

#include "text_encoding.h"

namespace azookey::display {
namespace {

std::optional<int> OptionalInteger(const json::Value& value) {
    if (value.kind() != json::Value::Kind::Number) return std::nullopt;
    return static_cast<int>(value.AsInteger(0));
}

std::wstring Text(const json::Value& value) { return text::Utf8ToUtf16(value.AsString()); }

float Number(const json::Value& value, float fallback = 0) { return static_cast<float>(value.AsNumber(fallback)); }

Point ParsePoint(const json::Value& value) { return {Number(value["x"]), Number(value["y"])}; }

Frame ParseFrame(const json::Value& value) {
    return {Number(value["x"]), Number(value["y"]), Number(value["width"]), Number(value["height"])};
}

std::optional<Frame> OptionalFrame(const json::Value& value) {
    if (value.kind() != json::Value::Kind::Object) return std::nullopt;
    return ParseFrame(value);
}

json::Value FrameValue(const Frame& frame) {
    return json::Value::MakeObject({{"x", json::Value::MakeNumber(frame.x)}, {"y", json::Value::MakeNumber(frame.y)},
                                    {"width", json::Value::MakeNumber(frame.width)},
                                    {"height", json::Value::MakeNumber(frame.height)}});
}

std::string ModeName(DisplayMode mode) { return mode == DisplayMode::List ? "list" : "tree"; }

}  // namespace

const DisplayNode* CandidateDisplay::FindNode(int id) const {
    for (const auto& node : nodes) {
        if (node.id == id) return &node;
    }
    return nullptr;
}

CandidateDisplay ParseCandidateDisplay(const json::Value& value) {
    CandidateDisplay display;
    if (value.kind() != json::Value::Kind::Object) return display;
    const std::string& mode = value["mode"].AsString();
    display.mode = mode == "tree" ? DisplayMode::Tree : mode == "list" ? DisplayMode::List : DisplayMode::Hidden;
    for (const auto& column : value["columns"].AsArray()) {
        std::vector<int> ids;
        for (const auto& id : column.AsArray()) ids.push_back(static_cast<int>(id.AsInteger(0)));
        display.columns.push_back(std::move(ids));
    }
    display.showsNumbers = value["showsNumbers"].AsBoolean(false);
    display.baseFontSize = Number(value["baseFontSize"], 18);
    display.detailNode = OptionalInteger(value["detailNode"]);
    display.expandTree = value["expandTree"].AsBoolean(false);
    display.announcement = Text(value["announcement"]);
    for (const auto& node : value["nodes"].AsArray()) {
        display.nodes.push_back({static_cast<int>(node["id"].AsInteger(0)), OptionalInteger(node["number"]),
                                 node["selected"].AsBoolean(false), node["focused"].AsBoolean(false),
                                 Text(node["accessibleName"]), Text(node["accessibleDescription"]), Text(node["detailText"])});
    }
    const json::Value& list = value["list"];
    if (list.kind() == json::Value::Kind::Object) {
        CandidateList parsed;
        parsed.title = Text(list["title"]);
        parsed.commitText = Text(list["commitText"]);
        parsed.readingText = Text(list["readingText"]);
        parsed.positionText = Text(list["positionText"]);
        parsed.keyboardConfirmsCandidate = list["keyboardConfirmsCandidate"].AsBoolean(false);
        parsed.confirmLabel = Text(list["confirmLabel"]);
        parsed.confirmAccessibleName = Text(list["confirmAccessibleName"]);
        parsed.confirmAccessibleDescription = Text(list["confirmAccessibleDescription"]);
        parsed.confirmIndex = OptionalInteger(list["confirmIndex"]);
        parsed.previousIndex = OptionalInteger(list["previousIndex"]);
        parsed.nextIndex = OptionalInteger(list["nextIndex"]);
        for (const auto& item : list["items"].AsArray()) {
            parsed.items.push_back({static_cast<int>(item["index"].AsInteger(0)), OptionalInteger(item["number"]), Text(item["text"]),
                                    item["selected"].AsBoolean(false), Text(item["accessibleName"]),
                                    Text(item["accessibleDescription"]), Text(item["detailText"])});
        }
        display.list = std::move(parsed);
    }
    return display;
}

std::string LayoutRequestLine(const LayoutRequest& request) {
    std::vector<json::Value> columns;
    for (const auto& column : request.columns) {
        std::vector<json::Value> nodes;
        for (const auto& node : column.nodes) {
            nodes.push_back(json::Value::MakeObject(
                {{"id", json::Value::MakeNumber(node.id)},
                 {"parent", node.parent ? json::Value::MakeNumber(*node.parent) : json::Value()}}));
        }
        columns.push_back(json::Value::MakeObject(
            {{"nodes", json::Value::MakeArray(std::move(nodes))}, {"textWidth", json::Value::MakeNumber(column.textWidth)}}));
    }
    std::map<std::string, json::Value> layout = {
        {"mode", json::Value::MakeString(ModeName(request.mode))},
        {"textSize", json::Value::MakeString(request.largeText ? "large" : "standard")},
        {"textScale", json::Value::MakeNumber(request.textScale)},
        {"measuredFontSize", json::Value::MakeNumber(request.measuredFontSize)},
        {"columns", json::Value::MakeArray(std::move(columns))},
        {"showScores", json::Value::MakeBoolean(request.showScores)},
        {"showNumbers", json::Value::MakeBoolean(request.showNumbers)},
        {"cursor", FrameValue(request.cursor)},
        {"workArea", FrameValue(request.workArea)},
    };
    if (request.documentWordWidths) {
        std::vector<json::Value> widths;
        for (float width : *request.documentWordWidths) widths.push_back(json::Value::MakeNumber(width));
        layout["documentWordWidths"] = json::Value::MakeArray(std::move(widths));
    }
    if (request.columnAnchorX) layout["columnAnchorX"] = json::Value::MakeNumber(*request.columnAnchorX);
    if (request.popupHeight) layout["popupHeight"] = json::Value::MakeNumber(*request.popupHeight);
    if (!request.preferredSide.empty()) layout["preferredSide"] = json::Value::MakeString(request.preferredSide);
    return json::Serialize(json::Value::MakeObject(
        {{"operation", json::Value::MakeString("candidate-layout")}, {"layout", json::Value::MakeObject(std::move(layout))}}));
}

std::optional<LayoutResult> ParseLayoutResult(const std::string& line) {
    auto parsed = json::Parse(line);
    if (!parsed) return std::nullopt;
    const json::Value& value = (*parsed)["candidateLayout"];
    if (value.kind() != json::Value::Kind::Object) return std::nullopt;
    LayoutResult result;
    result.popupWidth = Number(value["popupWidth"]);
    result.placementStatus = value["placementStatus"].AsString();
    result.placement = OptionalFrame(value["placement"]);
    result.side = value["placement"]["side"].AsString();
    const json::Value& tree = value["tree"];
    if (tree.kind() == json::Value::Kind::Object) {
        TreeLayout layout;
        layout.aligned = tree["aligned"].AsBoolean(false);
        layout.leadingText = tree["textAlignment"].AsString() == "leading";
        const json::Value& metrics = tree["metrics"];
        layout.metrics = {Number(metrics["fontSize"], 18), Number(metrics["numberFontSize"], 12), Number(metrics["scoreFontSize"], 12),
                          Number(metrics["wordHeight"], 32), Number(metrics["numberHeight"]), Number(metrics["scoreHeight"])};
        for (const auto& node : tree["nodes"].AsArray()) {
            layout.nodes.push_back({static_cast<int>(node["id"].AsInteger(0)), ParseFrame(node["frame"]), ParseFrame(node["textFrame"]),
                                    OptionalFrame(node["scoreFrame"]), OptionalFrame(node["numberFrame"])});
        }
        for (const auto& edge : tree["edges"].AsArray()) {
            layout.edges.push_back({static_cast<int>(edge["node"].AsInteger(0)), ParsePoint(edge["start"]), ParsePoint(edge["end"])});
        }
        layout.rootAnchor = ParsePoint(tree["rootAnchor"]);
        layout.contentWidth = Number(tree["contentSize"]["width"]);
        layout.contentHeight = Number(tree["contentSize"]["height"]);
        result.tree = std::move(layout);
    }
    return result;
}

}  // namespace azookey::display
