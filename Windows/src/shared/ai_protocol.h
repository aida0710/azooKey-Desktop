// The AI operations of docs/ai-bridge-protocol.md that Windows uses: which
// chords reach Core (ime-shortcuts), the suggestion review, and the request the
// host sends to its AI bridge. Core decides; these only read and write the lines.
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "bridge_protocol.h"
#include "json.h"
#include "key_binding.h"

namespace azookey::protocol {

std::optional<keys::KeyBinding> ParseKeyBinding(const json::Value& value);
std::optional<AIReview> ParseAIReview(const json::Value& value);

std::string ImeShortcutsRequest();
// nullopt for a reply that is not a shortcut list.
std::optional<std::vector<keys::KeyBinding>> ParseImeShortcuts(const std::string& line);

std::string AIReviewSendRequest(const RequestContext& context, int review, bool includeContext);

// What Core allows to be sent after a review: the `ai` operation's arguments
// (passed on untouched) and the composition the suggestions are for.
struct AISuggestionRequest {
    json::Value arguments;
    int generation = 0;
    std::wstring reading;
};
// nullopt when the review no longer applies (Core answered `{}`).
std::optional<AISuggestionRequest> ParseAIReviewSend(const std::string& line);

// The `ai` operation for the host. The host adds the API key; a key in the
// line is replaced, never forwarded from the application's process.
std::string AISuggestionsLine(const AISuggestionRequest& request);
// The texts the AI returned, or nullopt when the request failed.
std::optional<std::vector<std::wstring>> ParseAISuggestions(const std::string& line);

std::string SuggestionsRequest(const RequestContext& context, const std::vector<std::wstring>& texts, int generation,
                               const std::wstring& reading);

}  // namespace azookey::protocol
