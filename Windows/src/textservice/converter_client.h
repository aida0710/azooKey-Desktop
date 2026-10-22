// The text service's view of the converter: one bridge session per text
// service instance (one per UI thread), reached through the per-user host.
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "shared/ai_protocol.h"
#include "shared/bridge_protocol.h"
#include "shared/host_channel.h"

namespace azookey::tsf {

// How the text service reaches the per-user host; starts it when it is not running.
channel::HostConnection::Options TextServiceHostOptions();

class ConverterClient {
public:
    ConverterClient();
    ~ConverterClient();

    // The document the following requests describe. The client advances it past
    // every commit the converter reports, so a composition keeps describing the
    // document as it was before the composition, plus what was committed since.
    void SetDocument(const protocol::DocumentContext& document) { context_.document = document; }

    // nullopt means the converter is unavailable; the caller keeps the
    // document as the user sees it and stops composing.
    std::optional<protocol::Snapshot> Key(const keys::CoreKeyEvent& event, const protocol::KeyFacts& facts);
    std::optional<protocol::Snapshot> ReconversionReading(const keys::CoreKeyEvent& event);
    std::optional<protocol::Snapshot> UndoCommit();
    std::optional<protocol::Snapshot> Reconvert();
    std::optional<protocol::Snapshot> ConfirmReconversion(const std::string& token);
    std::optional<protocol::Snapshot> Select(int candidateIndex, int generation, bool submit);
    std::optional<protocol::Snapshot> SelectNode(int nodeId, int generation, bool submit);
    std::optional<protocol::Snapshot> Reset(bool submit);
    // Core's placement of the candidate panel (candidate-layout; no input state).
    std::optional<display::LayoutResult> Layout(const display::LayoutRequest& request);
    std::optional<protocol::PresentationSettings> PresentationSettings();
    // The chords Core acts on outside a composition; nullopt when Core did not answer with a list.
    std::optional<std::vector<keys::KeyBinding>> ImeShortcuts();
    // What Core allows to be sent for a confirmed review; nullopt when the review no longer applies.
    std::optional<protocol::AISuggestionRequest> AIReviewSend(int review, bool includeContext);
    bool SaveIncludeContext(bool includeContext);
    // Offers AI suggestions to the composition they were asked for.
    std::optional<protocol::Snapshot> Suggestions(const std::vector<std::wstring>& texts, int generation, const std::wstring& reading);

private:
    std::optional<protocol::Snapshot> Send(const std::string& request);

    channel::HostConnection connection_;
    protocol::RequestContext context_;
};

}  // namespace azookey::tsf
