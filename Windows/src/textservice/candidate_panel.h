// The candidate popup, drawn with Direct2D. Core decides what it shows
// (candidateDisplay) and where everything goes (candidate-layout); the panel
// measures text, draws, hit-tests and reports actions. It never takes focus.
// It is a layered window, so each update changes its size and its picture
// together, and it draws its own rounded corners and shadow.
#pragma once

#include <windows.h>
#include <d2d1.h>
#include <dwrite.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "candidate_accessibility.h"
#include "candidate_theme.h"
#include "layered_window_surface.h"
#include "shared/bridge_protocol.h"
#include "shared/candidate_display.h"

namespace azookey::tsf {

// One panel update.
struct PanelContent {
    display::CandidateDisplay display;
    std::vector<protocol::TreeNode> nodes;    // word text and score labels by id
    std::optional<display::TreeLayout> tree;  // set when the word tree is drawn
    bool showList = false;                    // the numbered page of full candidates
    bool showScores = false;
    float fontSize = 14;                      // candidate text, after the text-size setting
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

    // Width of `text` in DIPs at `fontSize`, for the candidate-layout request.
    float MeasureText(const std::wstring& text, float fontSize);
    // One line of text at `fontSize` plus the border drawn inside a selected
    // node, in DIPs (candidate-layout's lineHeight).
    float LineHeight(float fontSize);
    // Height in DIPs of `content` laid out at `width`, for placing the popup.
    float ContentHeight(const PanelContent& content, float width);
    // `frame` is where Core placed the popup, in physical screen pixels. When
    // Core had to make it lower than the content, the content scrolls inside
    // it and keeps the selected row or word in view.
    void Show(const PanelContent& content, const RECT& frame, UINT dpi);
    void Hide();
    bool visible() const { return window_ && IsWindowVisible(window_); }

private:
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

    // Room for the shadow around the panel inside the window, in physical pixels.
    struct ShadowMargins {
        int left = 0;
        int top = 0;
        int right = 0;
        int bottom = 0;
    };

    static LRESULT CALLBACK WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
    bool EnsureWindow();
    // Draws the panel and moves the window to frame_ in one step.
    bool Present();
    bool IsOnPanel(POINT clientPixels) const;
    IDWriteTextFormat* TextFormat(float size);
    void LayoutSections(const PanelContent& content, float width);
    void UpdateAccessibility();
    std::optional<D2D1_RECT_F> FocusFrame() const;
    void KeepFocusVisible();
    void ScrollBy(float dips);

    void Paint(ID2D1RenderTarget* target);
    void PaintShadow(const D2D1_RECT_F& panel);
    void PaintList();
    void PaintTree();
    void DrawText(const std::wstring& text, IDWriteTextFormat* format, const D2D1_RECT_F& frame, uint32_t color,
                  DWRITE_TEXT_ALIGNMENT alignment);
    void FillRounded(const D2D1_RECT_F& frame, float radius, uint32_t color);
    void StrokeRounded(const D2D1_RECT_F& frame, float radius, uint32_t color, float width);
    D2D1_RECT_F TreeRect(const display::Frame& frame) const;
    Hit HitTest(POINT clientPixels) const;
    void Activate(const Hit& hit, bool doubleClick);

    Actions actions_;
    HWND window_ = nullptr;
    std::unique_ptr<LayeredWindowSurface> surface_;
    std::unique_ptr<CandidateAccessibility> accessibility_;
    UINT dpi_ = 96;
    CandidateAppearance appearance_ = CandidateAppearance::Light;
    RECT frame_{};  // where Core placed the panel, physical screen pixels
    ShadowMargins shadowMargins_;

    // Set only while Paint runs; the brush belongs to that frame's target.
    ID2D1RenderTarget* target_ = nullptr;
    ID2D1SolidColorBrush* brush_ = nullptr;
    ID2D1StrokeStyle* dashed_ = nullptr;
    // Formats by point size; candidate text and the small labels.
    std::vector<std::pair<float, IDWriteTextFormat*>> formats_;

    PanelContent content_;
    float panelWidth_ = 0;
    float panelHeight_ = 0;
    float contentHeight_ = 0;
    float scrollOffset_ = 0;  // DIPs of content above the panel's top edge
    // List section
    std::vector<ListRow> rows_;
    D2D1_RECT_F previousFrame_{}, nextFrame_{}, confirmFrame_{}, footerFrame_{};
    float listBottom_ = 0;
    // Tree section starts here (DIPs from the panel's top).
    float treeTop_ = 0;
    std::wstring lastAnnouncement_;
};

}  // namespace azookey::tsf
