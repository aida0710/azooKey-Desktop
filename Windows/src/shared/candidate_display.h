// What Core decided to show in the candidate panel (candidateDisplay in every
// reply) and where it goes (the candidate-layout operation). The Windows side
// measures text, converts DIPs and draws; it does not decide. Format:
// docs/candidate-display.md.
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "json.h"

namespace azookey::display {

struct Point {
    float x = 0;
    float y = 0;
};

struct Frame {
    float x = 0;
    float y = 0;
    float width = 0;
    float height = 0;
    bool Contains(Point point) const { return point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height; }
};

struct DisplayNode {
    int id = 0;
    std::optional<int> number;  // 1-9
    bool selected = false;
    bool focused = false;
    std::wstring accessibleName;
    std::wstring accessibleDescription;
    std::wstring detailText;
};

struct ListItem {
    int index = 0;
    std::optional<int> number;
    std::wstring text;
    bool selected = false;
    std::wstring accessibleName;
    std::wstring accessibleDescription;
    std::wstring detailText;
};

struct CandidateList {
    std::wstring title;
    std::wstring commitText;
    std::wstring readingText;
    std::wstring positionText;
    bool keyboardConfirmsCandidate = false;
    std::wstring confirmLabel;
    std::wstring confirmAccessibleName;
    std::wstring confirmAccessibleDescription;
    std::optional<int> confirmIndex;
    std::optional<int> previousIndex;
    std::optional<int> nextIndex;
    std::vector<ListItem> items;
};

enum class DisplayMode { Hidden, Tree, List };

struct CandidateDisplay {
    DisplayMode mode = DisplayMode::Hidden;
    std::vector<std::vector<int>> columns;
    bool showsNumbers = false;
    float baseFontSize = 18;
    std::optional<int> detailNode;
    bool expandTree = false;
    std::wstring announcement;
    std::vector<DisplayNode> nodes;
    std::optional<CandidateList> list;

    const DisplayNode* FindNode(int id) const;
};

CandidateDisplay ParseCandidateDisplay(const json::Value& value);

// --- candidate-layout ---

struct LayoutColumnNode {
    int id = 0;
    std::optional<int> parent;
};

struct LayoutColumn {
    std::vector<LayoutColumnNode> nodes;
    float textWidth = 0;  // the column's first word, measured at measuredFontSize
};

struct LayoutRequest {
    DisplayMode mode = DisplayMode::Tree;
    bool largeText = false;
    float textScale = 1;
    float measuredFontSize = 18;
    std::vector<LayoutColumn> columns;
    // One line of text at measuredFontSize, including a border drawn inside a
    // node; Core never makes rows lower than this ratio.
    std::optional<float> lineHeight;
    std::optional<std::vector<float>> documentWordWidths;
    std::optional<float> columnAnchorX;
    bool showScores = false;
    bool showNumbers = false;
    Frame cursor;
    Frame workArea;
    // Whole DIPs: Core truncates positions and sizes, so a fractional height
    // would come back one smaller and look like a shrunk placement.
    std::optional<int> popupHeight;
    std::string preferredSide;
};

struct TreeMetrics {
    float fontSize = 18;
    float numberFontSize = 12;
    float scoreFontSize = 12;
    float wordHeight = 32;
    float numberHeight = 0;
    float scoreHeight = 0;
    // A score badge is its text plus this inset on each side, at least the
    // minimum width and at most the scoreFrame's width, centred in scoreFrame.
    float scoreBadgeMinimumWidth = 22;
    float scoreBadgeHorizontalInset = 3;
};

struct LayoutNode {
    int id = 0;
    Frame frame;
    Frame textFrame;
    std::optional<Frame> scoreFrame;
    std::optional<Frame> numberFrame;
};

struct LayoutEdge {
    int node = 0;
    Point start;
    Point end;
};

struct TreeLayout {
    bool aligned = false;
    bool leadingText = false;  // textAlignment == "leading"
    TreeMetrics metrics;
    std::vector<LayoutNode> nodes;
    std::vector<LayoutEdge> edges;
    Point rootAnchor;
    float contentWidth = 0;
    float contentHeight = 0;
};

struct LayoutResult {
    float popupWidth = 0;
    std::string placementStatus;  // notRequested, placed, unavailable
    std::optional<Frame> placement;
    std::string side;
    std::optional<TreeLayout> tree;
};

std::string LayoutRequestLine(const LayoutRequest& request);
std::optional<LayoutResult> ParseLayoutResult(const std::string& line);

}  // namespace azookey::display
