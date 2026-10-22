// The line protocol shared with azookey-desktop-bridge (Core/Sources/DesktopBridge):
// one JSON request per line in, one DesktopSnapshot per line out.
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "key_translation.h"

namespace azookey::protocol {

// Core's MarkedText focus: while typing every part is None; while choosing
// candidates the clause being converted is Focused and the others Unfocused.
enum class SegmentFocus { None, Focused, Unfocused };

struct PreeditSegment {
    std::wstring text;
    SegmentFocus focus = SegmentFocus::None;
};

struct Candidate {
    int index = 0;
    std::wstring text;
    std::wstring annotation;
};

// Core's wording for a node's relative score; shown only when enabled.
struct ScorePresentation {
    std::wstring label;
    std::wstring detail;
    std::string role;  // palette role: "scoreLow", "scoreHigh" or "scoreUnknown"
};

// One word in the candidate tree (CandidateTree in Core). Columns list the
// node ids per word position; the first id of each column is on the selected path.
struct TreeNode {
    int id = 0;
    std::wstring text;
    std::wstring reading;
    std::optional<int> parent;
    std::optional<int> previewCandidateIndex;  // the candidate this node would select
    std::optional<ScorePresentation> score;
    std::wstring previewDescription;
};

struct CandidatePageItem {
    int index = 0;
    std::wstring text;
    std::wstring reading;
    std::wstring annotation;
    std::wstring detail;
};

// The nine-candidate page that the number keys address (CandidatePage in Core).
struct CandidatePage {
    int totalCount = 0;
    std::optional<int> position;
    int start = 0;
    std::vector<CandidatePageItem> items;
    std::optional<int> previousIndex;
    std::optional<int> nextIndex;
};

struct Snapshot {
    bool consumed = false;
    std::wstring preedit;
    std::vector<PreeditSegment> segments;
    size_t cursorScalars = 0;
    std::vector<std::wstring> commits;
    std::vector<Candidate> candidates;
    // Core keeps a selected index even while typing (live conversion); only
    // showCandidateIndex says the user is choosing from the candidate list.
    std::optional<int> selection;
    int generation = 0;
    int pageStart = 0;
    bool showCandidateIndex = false;
    bool japanese = true;
    std::string error;

    std::string inputState;  // Core's InputState: "composing" while typing, "selecting" while choosing, ...
    std::vector<TreeNode> nodes;
    std::vector<std::vector<int>> columns;
    std::vector<int> selectedPath;
    std::optional<int> focusedNode;
    CandidatePage candidatePage;
    bool largeText = false;  // candidateTextSize == "large"
    bool showRelativeScores = false;

    const TreeNode* FindNode(int id) const;
};

// The settings the text service reads for its own presentation.
struct PresentationSettings {
    bool treeCandidates = true;
};

struct RequestContext {
    std::string context;       // one bridge session per text service instance
    std::wstring leftContext;  // text before the caret, for better conversion
    bool privateInput = false;
};

std::string KeyRequest(const RequestContext& context, const keys::CoreKeyEvent& event);
std::string SelectRequest(const RequestContext& context, int candidateIndex, int generation, bool submit);
std::string NodeRequest(const RequestContext& context, int nodeId, int generation, bool submit);
std::string ResetRequest(const RequestContext& context, bool submit);
std::string SettingsRequest(const std::string& context);
std::string CloseRequest(const std::string& context);

std::optional<Snapshot> ParseSnapshot(const std::string& line);
// Reads the "settings" member of the reply to SettingsRequest.
std::optional<PresentationSettings> ParsePresentationSettings(const std::string& line);

}  // namespace azookey::protocol
