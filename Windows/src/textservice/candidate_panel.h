// The candidate popup, drawn with Direct2D. While typing it shows the word
// tree; while converting it shows the numbered page of full candidates. It
// never takes focus from the application.
#pragma once

#include <windows.h>
#include <d2d1.h>
#include <dwrite.h>

#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "candidate_accessibility.h"
#include "candidate_theme.h"
#include "shared/bridge_protocol.h"

namespace azookey::tsf {

// A node's box in device-independent pixels (96 dpi), relative to the panel.
struct TreeNodeFrame {
    int nodeId = 0;
    float x = 0;
    float y = 0;
    float width = 0;
    float height = 0;
};

// Where each word of the tree goes. Core computes it from measured text
// widths (candidate-layout), so every renderer places nodes the same way.
struct TreePresentation {
    std::vector<TreeNodeFrame> frames;
    float width = 0;
    float height = 0;
    bool aligned = false;  // columns follow the words in the document
    float wordHeight = 0;
    float numberHeight = 0;
    float scoreHeight = 0;
    std::map<int, int> numbers;  // node id -> number key 1-9
};

class CandidatePanel {
public:
    struct Actions {
        std::function<void(int candidateIndex)> selectCandidate;   // highlight only
        std::function<void(int candidateIndex)> confirmCandidate;  // commit
        std::function<void(int nodeId)> selectNode;
    };

    explicit CandidatePanel(Actions actions);
    ~CandidatePanel();
    CandidatePanel(const CandidatePanel&) = delete;
    CandidatePanel& operator=(const CandidatePanel&) = delete;

    // `anchor` is the composition rectangle in physical screen pixels.
    void ShowList(const protocol::Snapshot& snapshot, const RECT& anchor);
    // `origin` is the panel's top-left in physical screen pixels.
    void ShowTree(const protocol::Snapshot& snapshot, const TreePresentation& tree, POINT origin);
    void Hide();
    bool visible() const { return window_ && IsWindowVisible(window_); }

    // Must run before the DLL unloads so no window class points into freed code.
    static void UnregisterWindowClass();

private:
    enum class Mode { Hidden, List, Tree };

    struct ListRow {
        int candidateIndex = 0;
        std::wstring number;
        std::wstring text;
        bool selected = false;
        D2D1_RECT_F frame{};
    };

    struct Hit {
        enum class Kind { None, Row, Node, PreviousPage, NextPage, Confirm } kind = Kind::None;
        int value = 0;
    };

    static LRESULT CALLBACK WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
    bool EnsureWindow();
    bool EnsureDeviceResources();
    void ReleaseDeviceResources();
    bool EnsureTextFormats(float textSize);
    float MeasureText(const std::wstring& text, IDWriteTextFormat* format) const;
    void PlaceWindow(int x, int y, float widthDips, float heightDips);
    UINT DpiAt(POINT point) const;

    void LayoutList(const protocol::Snapshot& snapshot);
    void Paint();
    void PaintList();
    void PaintTree();
    void DrawText(const std::wstring& text, IDWriteTextFormat* format, const D2D1_RECT_F& frame, uint32_t color,
                  DWRITE_TEXT_ALIGNMENT alignment);
    void FillRounded(const D2D1_RECT_F& frame, float radius, uint32_t color);
    void StrokeRounded(const D2D1_RECT_F& frame, float radius, uint32_t color, float width);
    Hit HitTest(POINT clientPixels) const;
    void Activate(const Hit& hit, bool doubleClick);

    void UpdateAccessibility();

    Actions actions_;
    HWND window_ = nullptr;
    std::unique_ptr<CandidateAccessibility> accessibility_;
    Mode mode_ = Mode::Hidden;
    UINT dpi_ = 96;
    CandidateAppearance appearance_ = CandidateAppearance::Light;

    ID2D1HwndRenderTarget* target_ = nullptr;
    ID2D1SolidColorBrush* brush_ = nullptr;
    ID2D1StrokeStyle* dashed_ = nullptr;
    IDWriteTextFormat* textFormat_ = nullptr;
    IDWriteTextFormat* smallFormat_ = nullptr;
    float textSize_ = 0;

    // List mode
    std::vector<ListRow> rows_;
    std::wstring status_;
    std::wstring annotation_;
    std::optional<int> selection_;
    std::optional<int> previousIndex_;
    std::optional<int> nextIndex_;
    D2D1_RECT_F previousFrame_{}, nextFrame_{}, confirmFrame_{}, footerFrame_{};
    float panelWidth_ = 0;
    float panelHeight_ = 0;

    // Tree mode
    TreePresentation tree_;
    protocol::Snapshot treeSnapshot_;
};

}  // namespace azookey::tsf
