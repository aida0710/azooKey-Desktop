#include "ai_transform_protocol.h"

#include <map>
#include <utility>

#include "../shared/text_encoding.h"

namespace azookey::ai_transform {
namespace {

using json::Value;

Value Utf8(const std::wstring& text) { return Value::MakeString(text::Utf16ToUtf8(text)); }

std::wstring Utf16(const Value& value) { return text::Utf8ToUtf16(value.AsString()); }

// Every ai-transform-* request names the text service's session and this transformation.
std::string TransformationLine(const HeldTransformation& held, const std::string& operation,
                               std::map<std::string, Value> ai) {
    ai["transformation"] = Value::MakeNumber(held.transformation);
    return json::Serialize(Value::MakeObject({
        {"operation", Value::MakeString(operation)},
        {"context", Value::MakeString(held.context)},
        {"ai", Value::MakeObject(std::move(ai))},
    }));
}

bool IsStale(const Value& reply) { return reply["stale"].AsBoolean(false); }

}  // namespace

std::string TakeRequest(const std::string& token) {
    return json::Serialize(
        Value::MakeObject({{"operation", Value::MakeString("host-take-ai-transform")}, {"token", Value::MakeString(token)}}));
}

std::optional<HeldTransformation> ParseHeldTransformation(const json::Value& reply) {
    const Value& open = reply["open"];
    if (reply["context"].AsString().empty() || reply["transformation"].kind() != Value::Kind::Number ||
        open.kind() != Value::Kind::Object) {
        return std::nullopt;
    }
    HeldTransformation held;
    held.context = reply["context"].AsString();
    held.transformation = static_cast<int>(reply["transformation"].AsInteger());
    held.initialPrompt = Utf16(reply["initialPrompt"]);
    held.field = reply["field"];
    held.target = Utf16(open["target"]);
    if (open["destination"].kind() == Value::Kind::String) held.destination = Utf16(open["destination"]);
    held.includeContext = open["includeContext"].AsBoolean(false);
    held.needsWitness = open["needsWitness"].AsBoolean(false);
    for (const auto& item : open["history"].AsArray()) {
        held.history.push_back({Utf16(item["prompt"]), item["pinned"].AsBoolean(false), Utf16(item["shortcutText"])});
    }
    return held;
}

std::string PreviewRequest(const HeldTransformation& held, const PreviewInput& input) {
    return TransformationLine(held, "ai-transform-preview",
                              {
                                  {"prompt", Utf8(input.prompt)},
                                  {"pinned", Value::MakeBoolean(input.pinned)},
                                  {"shortcutText", Utf8(input.shortcutText)},
                                  {"includeContext", Value::MakeBoolean(input.includeContext)},
                                  {"field", held.field},
                              });
}

std::string TransformationRequest(const HeldTransformation& held, const std::string& operation) {
    return TransformationLine(held, operation, {});
}

std::string ResultRequest(const HeldTransformation& held, int revision, const std::optional<std::wstring>& text) {
    return TransformationLine(held, "ai-transform-result",
                              {
                                  {"revision", Value::MakeNumber(revision)},
                                  {"text", text ? Utf8(*text) : Value()},
                                  // The text service checks the focus itself when the result is applied.
                                  {"inputContextChanged", Value::MakeBoolean(false)},
                              });
}

std::string TransformRequest(const json::Value& arguments) {
    std::map<std::string, Value> members = arguments.AsObject();
    // The host adds the key from Credential Manager; the window never holds it.
    members.erase("apiKey");
    members["operation"] = Value::MakeString("transform");
    return json::Serialize(Value::MakeObject(std::move(members)));
}

PreviewReply ParsePreviewReply(const std::optional<json::Value>& reply) {
    PreviewReply result;
    if (!reply) return result;
    result.stale = IsStale(*reply);
    result.historyError = (*reply)["historyError"].AsString();
    if ((*reply)["revision"].kind() == Value::Kind::Number) result.revision = static_cast<int>((*reply)["revision"].AsInteger());
    if ((*reply)["request"].kind() == Value::Kind::Object) result.request = (*reply)["request"];
    return result;
}

ResultReply ParseResultReply(const std::optional<json::Value>& reply) {
    ResultReply result;
    if (!reply) {
        result.stale = true;
        return result;
    }
    result.stale = IsStale(*reply);
    result.accepted = (*reply)["accepted"].AsBoolean(false);
    if ((*reply)["text"].kind() == Value::Kind::String) result.text = Utf16((*reply)["text"]);
    result.targetAvailable = (*reply)["targetAvailable"].AsBoolean(false);
    return result;
}

bool IsConfirmed(const std::optional<json::Value>& reply) { return reply && (*reply)["confirmed"].AsBoolean(false); }

TransformReply ParseTransformReply(const std::optional<json::Value>& reply) {
    TransformReply result;
    if (!reply) return result;
    result.missingApiKey = (*reply)["error"].AsString() == "missing_api_key";
    const auto& suggestions = (*reply)["suggestions"].AsArray();
    if (!suggestions.empty() && suggestions.front().kind() == Value::Kind::String) result.text = Utf16(suggestions.front());
    return result;
}

}  // namespace azookey::ai_transform
