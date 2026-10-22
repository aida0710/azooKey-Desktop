// Where the host sends each request line from a client. Every rule that picks
// a destination lives here, so a new operation is routed in one place.
#pragma once

#include "../shared/json.h"

namespace azookey::host {

enum class RequestRoute {
    // The converter that holds the input sessions: keys, candidates, settings and
    // Core's AI decisions (ai-transform-*, ai-review-send).
    Conversion,
    // "ai" and "transform": the separate converter that waits for the AI API.
    AIService,
    // host-open-ai-transform: the text service asks the host to open the AI instruction window.
    OpenAITransformWindow,
    // host-take-ai-transform: the instruction window claims what the host holds for it.
    TakeAITransform,
};

RequestRoute RouteFor(const json::Value& request);

// Whether the request's context is a session of the client that sent it, so
// the host closes that session when the client disconnects. The instruction
// window works on a text service's session and must not close it.
bool OwnsContext(const json::Value& request);

}  // namespace azookey::host
