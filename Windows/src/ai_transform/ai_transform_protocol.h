// The lines the AI instruction window exchanges with the host: claiming the
// transformation the host holds for it, and Core's ai-transform-* operations
// for that transformation (docs/ai-bridge-protocol.md). Core decides what is
// sent and which preview may be applied; the window shows its answers.
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "../shared/json.h"

namespace azookey::ai_transform {

struct HistoryItem {
    std::wstring prompt;
    bool pinned = false;
    std::wstring shortcutText;  // empty when the instruction has no shortcut
};

// What the text service asked the host to open (host-open-ai-transform),
// claimed once with the token on the window's command line.
struct HeldTransformation {
    std::string context;  // the text service's session; every request uses it
    int transformation = 0;
    std::wstring initialPrompt;
    json::Value field;  // Core's AITextField as the text service read it, sent back unchanged
    std::wstring target;
    std::optional<std::wstring> destination;  // host and port; absent when Core cannot show it
    bool includeContext = false;
    bool needsWitness = false;  // false: the result can only be copied
    std::vector<HistoryItem> history;
};

std::string TakeRequest(const std::string& token);
// nullopt when the host holds nothing for the token.
std::optional<HeldTransformation> ParseHeldTransformation(const json::Value& reply);

struct PreviewInput {
    std::wstring prompt;
    bool pinned = false;
    std::wstring shortcutText;
    bool includeContext = false;
};

std::string PreviewRequest(const HeldTransformation& held, const PreviewInput& input);
// ai-transform-invalidate, -confirm and -close carry only the transformation.
std::string TransformationRequest(const HeldTransformation& held, const std::string& operation);
// `text` is nullopt when the AI request failed.
std::string ResultRequest(const HeldTransformation& held, int revision, const std::optional<std::wstring>& text);
// Core's AI arguments from a preview reply, as the host's "transform" operation.
std::string TransformRequest(const json::Value& arguments);

struct PreviewReply {
    bool stale = false;          // Core no longer holds this transformation
    std::string historyError;    // "format", "modifierRequired", "duplicateShortcut", "saveFailed"
    std::optional<int> revision; // absent: Core refused (empty instruction, or one still generating)
    std::optional<json::Value> request;  // absent with a revision: the preview already failed
};
PreviewReply ParsePreviewReply(const std::optional<json::Value>& reply);

struct ResultReply {
    bool stale = false;
    bool accepted = false;  // false: an older preview's answer; nothing changes
    std::optional<std::wstring> text;
    bool targetAvailable = false;
};
ResultReply ParseResultReply(const std::optional<json::Value>& reply);

bool IsConfirmed(const std::optional<json::Value>& reply);

struct TransformReply {
    std::optional<std::wstring> text;  // the AI's result
    bool missingApiKey = false;
};
TransformReply ParseTransformReply(const std::optional<json::Value>& reply);

}  // namespace azookey::ai_transform
