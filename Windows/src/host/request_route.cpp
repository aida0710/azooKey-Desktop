#include "request_route.h"

#include <string_view>

namespace azookey::host {
namespace {

constexpr std::string_view kTransformationOperationPrefix = "ai-transform-";

}  // namespace

RequestRoute RouteFor(const json::Value& request) {
    const std::string& operation = request["operation"].AsString();
    if (operation == "ai" || operation == "transform") return RequestRoute::AIService;
    if (operation == "host-open-ai-transform") return RequestRoute::OpenAITransformWindow;
    if (operation == "host-take-ai-transform") return RequestRoute::TakeAITransform;
    return RequestRoute::Conversion;
}

bool OwnsContext(const json::Value& request) {
    if (RouteFor(request) != RequestRoute::Conversion) return false;
    if (request["context"].AsString().empty()) return false;
    return !std::string_view(request["operation"].AsString()).starts_with(kTransformationOperationPrefix);
}

}  // namespace azookey::host
