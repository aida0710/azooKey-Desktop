// The line protocol shared with azookey-desktop-bridge (Core/Sources/DesktopBridge):
// one JSON request per line in, one DesktopSnapshot per line out.
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "candidate_display.h"
#include "key_binding.h"
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

// The field around the selection, for undoing a commit and reconverting a
// selection (ReconversionContext in Core). Positions are UTF-16 offsets from the
// start of the document: Core compares them between requests, so they must not
// move when text far before the caret is out of the window. `before` and
// `after` hold at most kReconversionContextLimit scalars.
struct ReconversionContext {
    std::wstring before;
    std::wstring selected;
    std::wstring after;
    int cursorUTF16 = 0;
    int anchorUTF16 = 0;
    bool canReplace = false;
    bool isSensitive = false;
};

// Core's bound for `before`, `selected` and `after`, in scalars.
inline constexpr size_t kReconversionContextLimit = 256;

// The text Core will turn back into a composition: `count` scalars starting
// `offset` scalars from the caret (negative: before it).
struct ReconversionReplacement {
    std::string token;
    int offset = 0;
    int count = 0;
    std::wstring text;
};

// Core's review of an AI suggestion request (the `ai.review` of a key reply):
// what would be sent and where, shown before anything leaves the machine.
struct AIReview {
    int id = 0;
    std::wstring target;                      // the text to send; Core's word for "the continuation" when nothing is composed
    std::optional<std::wstring> destination;  // host and port; missing when the endpoint cannot be shown
    bool includeContext = false;
    std::vector<keys::KeyBinding> bindings;   // send / toggleContext / cancel while the review is shown
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
    // Zenzai loads its model on the first conversion, so this turns true only
    // after the bridge has converted with it.
    bool zenzaiLoaded = false;
    std::string error;

    std::optional<ReconversionReplacement> reconversion;
    std::string reconversionError;              // ReconversionSession.Failure raw value
    std::optional<std::wstring> reconversionReading;  // set while the user types the reading

    std::optional<AIReview> aiReview;
    std::optional<std::wstring> aiPrompt;  // open the selected-text instruction window with this text

    std::string inputState;  // Core's InputState: "composing" while typing, "selecting" while choosing, ...
    std::vector<TreeNode> nodes;
    std::vector<std::vector<int>> columns;
    std::vector<int> selectedPath;
    std::optional<int> focusedNode;
    CandidatePage candidatePage;
    bool largeText = false;  // candidateTextSize == "large"
    bool showRelativeScores = false;
    display::CandidateDisplay display;  // what Core decided to show

    const TreeNode* FindNode(int id) const;
};

// The settings the text service reads for its own presentation.
struct PresentationSettings {
    bool treeCandidates = true;
};

// The document as Core should see it. During a composition this stays the
// document from before the composition started (Core treats the composition as
// not yet in the document), advanced past each commit.
struct DocumentContext {
    std::wstring leftContext;   // text before the caret, for better conversion
    std::wstring rightContext;  // text after the caret (or the selection), likewise
    bool privateInput = false;
    std::optional<ReconversionContext> reconversion;
};

// The document once `committed` has replaced the selection, as Core's
// ReconversionContext.replacingSelection records it for undoing that commit.
DocumentContext AdvancedPastCommit(const DocumentContext& document, const std::wstring& committed);

struct RequestContext {
    std::string context;  // one bridge session per text service instance
    DocumentContext document;
};

// What the text service knows about the field when the key arrives.
struct KeyFacts {
    bool hasSelection = false;  // Core opens the AI instruction window only for a selection
};

std::string KeyRequest(const RequestContext& context, const keys::CoreKeyEvent& event, const KeyFacts& facts);
// While Core asks for the reading of the selection, keys go here instead.
std::string ReconversionReadingRequest(const RequestContext& context, const keys::CoreKeyEvent& event);
std::string ConfirmReconversionRequest(const RequestContext& context, const std::string& token);
std::string UndoCommitRequest(const RequestContext& context);
std::string ReconvertRequest(const RequestContext& context);
std::string SelectRequest(const RequestContext& context, int candidateIndex, int generation, bool submit);
std::string NodeRequest(const RequestContext& context, int nodeId, int generation, bool submit);
std::string ResetRequest(const RequestContext& context, bool submit);
std::string SettingsRequest(const std::string& context);
std::string CloseRequest(const std::string& context);

std::optional<Snapshot> ParseSnapshot(const std::string& line);
// Reads the "settings" member of the reply to SettingsRequest.
std::optional<PresentationSettings> ParsePresentationSettings(const std::string& line);

}  // namespace azookey::protocol
