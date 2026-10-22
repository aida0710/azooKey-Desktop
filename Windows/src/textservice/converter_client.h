// The text service's view of the converter: one bridge session per text
// service instance (one per UI thread), reached through the per-user host.
#pragma once

#include <optional>
#include <string>

#include "shared/bridge_protocol.h"
#include "shared/host_channel.h"

namespace azookey::tsf {

class ConverterClient {
public:
    ConverterClient();
    ~ConverterClient();

    // nullopt means the converter is unavailable; the caller keeps the
    // document as the user sees it and stops composing.
    std::optional<protocol::Snapshot> Key(const keys::CoreKeyEvent& event, const std::wstring& leftContext, bool privateInput);
    std::optional<protocol::Snapshot> Select(int candidateIndex, int generation, bool submit);
    std::optional<protocol::Snapshot> SelectNode(int nodeId, int generation, bool submit);
    std::optional<protocol::Snapshot> Reset(bool submit);
    // Core's placement of the candidate panel (candidate-layout; no input state).
    std::optional<display::LayoutResult> Layout(const display::LayoutRequest& request);
    std::optional<protocol::PresentationSettings> PresentationSettings();

private:
    std::optional<protocol::Snapshot> Send(const std::string& request);

    channel::HostConnection connection_;
    protocol::RequestContext context_;
};

}  // namespace azookey::tsf
