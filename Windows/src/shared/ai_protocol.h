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

// The review's "include surrounding text" choice is also the setting's new value
// (settings-update); false when Core could not save it.
std::string IncludeContextUpdateRequest(bool includeContext);
bool IsSettingsUpdateSaved(const std::string& line);

std::string SuggestionsRequest(const RequestContext& context, const std::vector<std::wstring>& texts, int generation,
                               const std::wstring& reading);

// --- Selected-text transformation (ai-transform-*) ---

// The text around the selection as the field shows it; positions are UTF-16
// offsets into `text`.
struct AISurrounding {
    std::wstring text;
    int cursorUTF16 = 0;
    int anchorUTF16 = 0;
};

// Core's AITextField: what the text service observes about the focused field.
struct AITextField {
    std::vector<std::string> identity;  // empty when the field cannot be named
    std::optional<AISurrounding> surrounding;
    bool isSensitive = false;
};

// Core's AISelectionWitness: a second read of the selection, made right
// before a result may replace it.
struct AISelectionWitness {
    std::vector<std::string> object;
    std::vector<std::string> window;
    int start = 0;  // in the reading API's own units; compared only with another witness
    int end = 0;
    std::wstring before;
    std::wstring selected;
    std::wstring after;
};

// `ai` members beyond the transformation id, for the request builders below.
struct AITransformFacts {
    std::optional<AITextField> field;
    std::optional<AISelectionWitness> witness;
};

std::string AITransformOpenRequest(const RequestContext& context, const AITextField& field);
// operation is one of ai-transform-target / -check / -take / -reject / -close.
std::string AITransformRequest(const RequestContext& context, const std::string& operation, int transformation,
                               const AITransformFacts& facts);

struct AITransformOpened {
    int transformation = 0;
    bool needsWitness = false;
    json::Value reply;  // passed to the instruction window as it is
};
// nullopt when Core does not open one (no selection, protected field, AI off).
std::optional<AITransformOpened> ParseAITransformOpen(const std::string& line);

struct AITransformReply {
    bool stale = false;  // Core no longer holds this transformation
    bool targetAvailable = false;
    bool matches = false;
    std::optional<std::wstring> replacement;
};
std::optional<AITransformReply> ParseAITransformReply(const std::string& line);

// Asks the host to open the instruction window for this transformation. The
// field and Core's answer stay with the host; nothing goes on a command line.
std::string HostOpenAITransformRequest(const RequestContext& context, const AITransformOpened& opened,
                                       const std::wstring& initialPrompt, const AITextField& field);
bool ParseHostOpened(const std::string& line);

}  // namespace azookey::protocol
