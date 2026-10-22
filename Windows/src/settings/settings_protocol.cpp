#include "settings_protocol.h"

#include <map>

#include "../shared/text_encoding.h"

namespace azookey::settings {
namespace {

using json::Value;

std::string Request(std::map<std::string, Value> members) {
    return json::Serialize(Value::MakeObject(std::move(members)));
}

std::optional<Problem> ParseProblem(const Value& document) {
    if (document.kind() != Value::Kind::Object) return std::nullopt;
    Problem problem{document["code"].AsString(), document["message"].AsString(), {}};
    for (const auto& [name, value] : document["arguments"].AsObject()) {
        problem.arguments.emplace_back(text::Utf8ToUtf16(name), text::Utf8ToUtf16(value.AsString()));
    }
    return problem;
}

std::optional<FileState> ParseFileState(const Value& document) {
    if (document.kind() != Value::Kind::Object) return std::nullopt;
    FileState state;
    state.path = text::Utf8ToUtf16(document["path"].AsString());
    state.stamp = document["stamp"].AsString();
    state.exists = document["exists"].AsBoolean();
    state.problem = ParseProblem(document["problem"]);
    return state;
}

}  // namespace

std::string SchemaRequest() { return Request({{"operation", Value::MakeString("settings-schema")}}); }

std::string LoadRequest() { return Request({{"operation", Value::MakeString("settings-load")}}); }

std::string SaveRequest(const json::Value& values, const std::string& expectedStamp) {
    return Request({
        {"operation", Value::MakeString("settings-save")},
        {"settings", values},
        {"settingsFile", Value::MakeObject({{"expectedStamp", Value::MakeString(expectedStamp)}})},
    });
}

std::string RecoverRequest(const std::string& expectedStamp, bool useDefaults) {
    return Request({
        {"operation", Value::MakeString("settings-recover")},
        {"settingsFile", Value::MakeObject({{"expectedStamp", Value::MakeString(expectedStamp)},
                                            {"useDefaults", Value::MakeBoolean(useDefaults)}})},
    });
}

std::string ResetLearningRequest() {
    return Request({{"operation", Value::MakeString("reset-learning")}, {"context", Value::MakeString(kSettingsContext)}});
}

SettingsReply ParseSettingsReply(const std::optional<json::Value>& reply) {
    SettingsReply result;
    if (!reply) {
        result.failure = "no_reply";
        return result;
    }
    result.failure = (*reply)["error"].AsString();
    if (!result.failure.empty()) return result;
    const Value& settingsResult = (*reply)["settingsResult"];
    result.error = ParseProblem(settingsResult["error"]);
    result.file = ParseFileState(settingsResult["file"]);
    const Value& saved = settingsResult["saved"];
    if (saved.kind() == Value::Kind::Object) {
        result.saved = SaveReport{text::Utf8ToUtf16(saved["recoveredPath"].AsString()), saved["lastGoodSaved"].AsBoolean(true)};
    }
    if ((*reply)["settings"].kind() == Value::Kind::Object) result.values = (*reply)["settings"];
    return result;
}

bool ResetLearningSucceeded(const std::optional<json::Value>& reply) {
    return reply.has_value() && (*reply)["error"].IsNull();
}

json::Value WithValue(const json::Value& values, const std::string& key, json::Value value) {
    auto members = values.AsObject();
    members[key] = std::move(value);
    return Value::MakeObject(std::move(members));
}

}  // namespace azookey::settings
