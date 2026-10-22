// The line protocol shared with azookey-desktop-bridge (Core/Sources/DesktopBridge):
// one JSON request per line in, one DesktopSnapshot per line out.
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "key_translation.h"

namespace azookey::protocol {

struct PreeditSegment {
    std::wstring text;
    bool focused = false;  // the clause currently being converted
};

struct Candidate {
    int index = 0;
    std::wstring text;
    std::wstring annotation;
};

struct Snapshot {
    bool consumed = false;
    std::wstring preedit;
    std::vector<PreeditSegment> segments;
    size_t cursorScalars = 0;
    std::vector<std::wstring> commits;
    std::vector<Candidate> candidates;
    std::optional<int> selection;  // set while the user is choosing a candidate
    int generation = 0;
    int pageStart = 0;
    bool showCandidateIndex = false;
    bool japanese = true;
    std::string error;
};

struct RequestContext {
    std::string context;       // one bridge session per text service instance
    std::wstring leftContext;  // text before the caret, for better conversion
    bool privateInput = false;
};

std::string KeyRequest(const RequestContext& context, const keys::CoreKeyEvent& event);
std::string SelectRequest(const RequestContext& context, int candidateIndex, int generation, bool submit);
std::string ResetRequest(const RequestContext& context, bool submit);
std::string CloseRequest(const std::string& context);

std::optional<Snapshot> ParseSnapshot(const std::string& line);

}  // namespace azookey::protocol
