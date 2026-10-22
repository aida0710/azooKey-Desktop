#include "ai_protocol.h"

#include "text_encoding.h"

namespace azookey::protocol {

std::optional<keys::KeyBinding> ParseKeyBinding(const json::Value& value) {
    if (value.kind() != json::Value::Kind::Object || value["command"].kind() != json::Value::Kind::String) return std::nullopt;
    keys::KeyBinding binding;
    binding.command = value["command"].AsString();
    binding.modifiers = static_cast<int>(value["modifiers"].AsInteger(0));
    if (value["keyCode"].kind() == json::Value::Kind::Number) binding.keyCode = static_cast<int>(value["keyCode"].AsInteger(0));
    if (value["key"].kind() == json::Value::Kind::String) binding.key = value["key"].AsString();
    if (!binding.key && !binding.keyCode) return std::nullopt;
    return binding;
}

namespace {

std::vector<keys::KeyBinding> ParseKeyBindings(const json::Value& value) {
    std::vector<keys::KeyBinding> bindings;
    if (value.kind() != json::Value::Kind::Array) return bindings;
    for (const auto& item : value.AsArray()) {
        if (auto binding = ParseKeyBinding(item)) bindings.push_back(std::move(*binding));
    }
    return bindings;
}

json::Value StringArray(const std::vector<std::string>& items) {
    std::vector<json::Value> values;
    for (const auto& item : items) values.push_back(json::Value::MakeString(item));
    return json::Value::MakeArray(std::move(values));
}

json::Value Utf8(const std::wstring& text) { return json::Value::MakeString(text::Utf16ToUtf8(text)); }

json::Value FieldValue(const AITextField& field) {
    std::map<std::string, json::Value> members;
    members["identity"] = field.identity.empty() ? json::Value() : StringArray(field.identity);
    if (field.surrounding) {
        members["surrounding"] = json::Value::MakeObject({
            {"text", Utf8(field.surrounding->text)},
            {"cursorUTF16", json::Value::MakeNumber(field.surrounding->cursorUTF16)},
            {"anchorUTF16", json::Value::MakeNumber(field.surrounding->anchorUTF16)},
        });
    } else {
        members["surrounding"] = json::Value();
    }
    // TSF reads the field when it is asked, so the read is always current.
    members["hasSurroundingUpdate"] = json::Value::MakeBoolean(field.surrounding.has_value());
    members["isSensitive"] = json::Value::MakeBoolean(field.isSensitive);
    return json::Value::MakeObject(std::move(members));
}

json::Value WitnessValue(const AISelectionWitness& witness) {
    return json::Value::MakeObject({
        {"object", StringArray(witness.object)},
        {"window", StringArray(witness.window)},
        {"start", json::Value::MakeNumber(witness.start)},
        {"end", json::Value::MakeNumber(witness.end)},
        {"before", Utf8(witness.before)},
        {"selected", Utf8(witness.selected)},
        {"after", Utf8(witness.after)},
    });
}

std::string ContextOnlyFields(const RequestContext& context) {
    return ",\"context\":" + json::Quote(context.context) + ",\"privateInput\":" + (context.document.privateInput ? "true" : "false");
}

}  // namespace

std::optional<AIReview> ParseAIReview(const json::Value& value) {
    if (value.kind() != json::Value::Kind::Object || value["id"].kind() != json::Value::Kind::Number) return std::nullopt;
    AIReview review;
    review.id = static_cast<int>(value["id"].AsInteger(0));
    review.target = text::Utf8ToUtf16(value["target"].AsString());
    if (value["destination"].kind() == json::Value::Kind::String) {
        review.destination = text::Utf8ToUtf16(value["destination"].AsString());
    }
    review.includeContext = value["includeContext"].AsBoolean(false);
    review.bindings = ParseKeyBindings(value["bindings"]);
    return review;
}

std::string ImeShortcutsRequest() { return "{\"operation\":\"ime-shortcuts\"}"; }

std::optional<std::vector<keys::KeyBinding>> ParseImeShortcuts(const std::string& line) {
    auto parsed = json::Parse(line);
    if (!parsed || (*parsed)["shortcuts"].kind() != json::Value::Kind::Array) return std::nullopt;
    return ParseKeyBindings((*parsed)["shortcuts"]);
}

std::string AIReviewSendRequest(const RequestContext& context, int review, bool includeContext) {
    return "{\"operation\":\"ai-review-send\"" + ContextOnlyFields(context) + ",\"ai\":{\"review\":" + std::to_string(review) +
           ",\"includeContext\":" + (includeContext ? "true" : "false") + "}}";
}

std::optional<AISuggestionRequest> ParseAIReviewSend(const std::string& line) {
    auto parsed = json::Parse(line);
    if (!parsed || (*parsed)["request"].kind() != json::Value::Kind::Object) return std::nullopt;
    AISuggestionRequest request;
    request.arguments = (*parsed)["request"];
    request.generation = static_cast<int>((*parsed)["generation"].AsInteger(0));
    request.reading = text::Utf8ToUtf16((*parsed)["reading"].AsString());
    return request;
}

std::string AISuggestionsLine(const AISuggestionRequest& request) {
    std::map<std::string, json::Value> members = request.arguments.AsObject();
    members.erase("apiKey");
    members["operation"] = json::Value::MakeString("ai");
    return json::Serialize(json::Value::MakeObject(std::move(members)));
}

std::optional<std::vector<std::wstring>> ParseAISuggestions(const std::string& line) {
    auto parsed = json::Parse(line);
    if (!parsed || (*parsed)["suggestions"].kind() != json::Value::Kind::Array) return std::nullopt;
    std::vector<std::wstring> texts;
    for (const auto& item : (*parsed)["suggestions"].AsArray()) {
        if (item.kind() == json::Value::Kind::String) texts.push_back(text::Utf8ToUtf16(item.AsString()));
    }
    return texts;
}

std::string IncludeContextUpdateRequest(bool includeContext) {
    return std::string("{\"operation\":\"settings-update\",\"settings\":{\"includeContext\":") + (includeContext ? "true" : "false") +
           "}}";
}

bool IsSettingsUpdateSaved(const std::string& line) {
    auto parsed = json::Parse(line);
    return parsed && (*parsed)["settings"].kind() == json::Value::Kind::Object && !(*parsed)["settingsResult"].Has("error");
}

std::string SuggestionsRequest(const RequestContext& context, const std::vector<std::wstring>& texts, int generation,
                               const std::wstring& reading) {
    std::vector<json::Value> items;
    for (const auto& text : texts) items.push_back(json::Value::MakeString(text::Utf16ToUtf8(text)));
    return "{\"operation\":\"suggestions\"" + ContextOnlyFields(context) + ",\"suggestions\":" +
           json::Serialize(json::Value::MakeArray(std::move(items))) + ",\"generation\":" + std::to_string(generation) +
           ",\"reading\":" + json::Quote(text::Utf16ToUtf8(reading)) + "}";
}

std::string AITransformOpenRequest(const RequestContext& context, const AITextField& field) {
    return "{\"operation\":\"ai-transform-open\"" + ContextOnlyFields(context) + ",\"ai\":" +
           json::Serialize(json::Value::MakeObject({{"field", FieldValue(field)}})) + "}";
}

std::string AITransformRequest(const RequestContext& context, const std::string& operation, int transformation,
                               const AITransformFacts& facts) {
    std::map<std::string, json::Value> ai{{"transformation", json::Value::MakeNumber(transformation)}};
    if (facts.field) ai["field"] = FieldValue(*facts.field);
    if (facts.witness) ai["witness"] = WitnessValue(*facts.witness);
    return "{\"operation\":" + json::Quote(operation) + ContextOnlyFields(context) + ",\"ai\":" +
           json::Serialize(json::Value::MakeObject(std::move(ai))) + "}";
}

std::optional<AITransformOpened> ParseAITransformOpen(const std::string& line) {
    auto parsed = json::Parse(line);
    if (!parsed || (*parsed)["transformation"].kind() != json::Value::Kind::Number) return std::nullopt;
    AITransformOpened opened;
    opened.transformation = static_cast<int>((*parsed)["transformation"].AsInteger(0));
    opened.needsWitness = (*parsed)["needsWitness"].AsBoolean(false);
    opened.reply = *parsed;
    return opened;
}

std::optional<AITransformReply> ParseAITransformReply(const std::string& line) {
    auto parsed = json::Parse(line);
    if (!parsed || (*parsed)["transformation"].kind() != json::Value::Kind::Number) return std::nullopt;
    AITransformReply reply;
    reply.stale = (*parsed)["stale"].AsBoolean(false);
    reply.targetAvailable = (*parsed)["targetAvailable"].AsBoolean(false);
    reply.matches = (*parsed)["matches"].AsBoolean(false);
    if ((*parsed)["replacement"].kind() == json::Value::Kind::String) {
        reply.replacement = text::Utf8ToUtf16((*parsed)["replacement"].AsString());
    }
    return reply;
}

std::string HostOpenAITransformRequest(const RequestContext& context, const AITransformOpened& opened,
                                       const std::wstring& initialPrompt, const AITextField& field) {
    return json::Serialize(json::Value::MakeObject({
        {"operation", json::Value::MakeString("host-open-ai-transform")},
        {"context", json::Value::MakeString(context.context)},
        {"transformation", json::Value::MakeNumber(opened.transformation)},
        {"initialPrompt", Utf8(initialPrompt)},
        {"field", FieldValue(field)},
        {"open", opened.reply},
    }));
}

bool ParseHostOpened(const std::string& line) {
    auto parsed = json::Parse(line);
    return parsed && (*parsed)["opened"].AsBoolean(false);
}

}  // namespace azookey::protocol
