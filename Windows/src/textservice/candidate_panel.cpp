#include "candidate_panel.h"

#include <windowsx.h>

#include <algorithm>
#include <map>

#include "ime_windows.h"
#include "module.h"

namespace azookey::tsf {
namespace {

constexpr wchar_t kWindowClassName[] = L"azooKeyTreeCandidatePanel";
// Secondary labels (numbers, page position, buttons); Core's numberFontSize.
constexpr float kSmallTextSize = 12;
constexpr float kPadding = 6;
constexpr float kRowExtraHeight = 14;  // a row is its text plus 7 above and below, like the tree's words
constexpr float kRowGap = 2;
constexpr float kCornerRadius = 8;
constexpr float kNodeRadius = 4;
// A kanji reaches as high and low as Japanese candidate text does.
constexpr wchar_t kLineSample[] = L"漢";

ID2D1Factory* direct2D = nullptr;
IDWriteFactory* directWrite = nullptr;

// Selection is shown by background, border and text color together; the
// border is heavier in high contrast.
float SelectionStrokeWidth(CandidateAppearance appearance) { return IsHighContrast(appearance) ? 3.0f : 2.0f; }

template <typename T>
void SafeRelease(T** pointer) {
    if (*pointer) {
        (*pointer)->Release();
        *pointer = nullptr;
    }
}

D2D1_COLOR_F Color(uint32_t rgb) {
    return D2D1::ColorF(((rgb >> 16) & 0xFF) / 255.0f, ((rgb >> 8) & 0xFF) / 255.0f, (rgb & 0xFF) / 255.0f, 1.0f);
}

bool Contains(const D2D1_RECT_F& frame, D2D1_POINT_2F point) {
    return point.x >= frame.left && point.x <= frame.right && point.y >= frame.top && point.y <= frame.bottom;
}

bool EnsureFactories() {
    if (!direct2D && FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &direct2D))) return false;
    if (!directWrite &&
        FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(&directWrite)))) {
        return false;
    }
    return true;
}

const protocol::TreeNode* FindWord(const std::vector<protocol::TreeNode>& nodes, int id) {
    for (const auto& node : nodes) {
        if (node.id == id) return &node;
    }
    return nullptr;
}

}  // namespace

CandidatePanel::CandidatePanel(Actions actions) : actions_(std::move(actions)) {}

CandidatePanel::~CandidatePanel() {
    // UIA providers refer to the window, so they go first.
    accessibility_.reset();
    ReleaseDeviceResources();
    for (auto& [size, format] : formats_) format->Release();
    if (window_) DestroyWindow(window_);
}

bool CandidatePanel::EnsureWindow() {
    if (window_) return true;
    if (!EnsureFactories()) return false;
    window_ = CreateImePopup({kWindowClassName, WindowProcedure, CS_DBLCLKS}, this);
    if (!window_) return false;
    CandidateAccessibility::Actions accessibilityActions;
    accessibilityActions.select = [this](int candidateIndex) {
        if (actions_.selectCandidate) actions_.selectCandidate(candidateIndex);
    };
    accessibilityActions.confirm = [this](int candidateIndex) {
        if (actions_.confirmCandidate) actions_.confirmCandidate(candidateIndex);
    };
    accessibility_ = std::make_unique<CandidateAccessibility>(window_, std::move(accessibilityActions));
    return true;
}

bool CandidatePanel::EnsureDeviceResources() {
    if (target_) return true;
    RECT client{};
    GetClientRect(window_, &client);
    D2D1_RENDER_TARGET_PROPERTIES properties = D2D1::RenderTargetProperties();
    properties.dpiX = properties.dpiY = static_cast<float>(dpi_);
    if (FAILED(direct2D->CreateHwndRenderTarget(
            properties, D2D1::HwndRenderTargetProperties(window_, D2D1::SizeU(client.right, client.bottom)), &target_))) {
        return false;
    }
    target_->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0), &brush_);
    if (!dashed_) {
        float dashes[] = {2, 3};  // the other paths of the tree are thin dotted lines
        direct2D->CreateStrokeStyle(D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT,
                                                                D2D1_LINE_JOIN_MITER, 10.0f, D2D1_DASH_STYLE_CUSTOM, 0.0f),
                                    dashes, ARRAYSIZE(dashes), &dashed_);
    }
    return brush_ != nullptr;
}

void CandidatePanel::ReleaseDeviceResources() {
    SafeRelease(&brush_);
    SafeRelease(&target_);
    SafeRelease(&dashed_);
}

IDWriteTextFormat* CandidatePanel::TextFormat(float size) {
    for (auto& [existing, format] : formats_) {
        if (existing == size) return format;
    }
    if (!EnsureFactories()) return nullptr;
    IDWriteTextFormat* format = nullptr;
    if (FAILED(directWrite->CreateTextFormat(L"Yu Gothic UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                                             DWRITE_FONT_STRETCH_NORMAL, size, L"ja-jp", &format))) {
        return nullptr;
    }
    format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    IDWriteInlineObject* ellipsis = nullptr;
    if (SUCCEEDED(directWrite->CreateEllipsisTrimmingSign(format, &ellipsis))) {
        // Words that do not fit end with an ellipsis, as Core's textFrame expects.
        DWRITE_TRIMMING trimming{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        format->SetTrimming(&trimming, ellipsis);
        ellipsis->Release();
    }
    formats_.push_back({size, format});
    return format;
}

float CandidatePanel::LineHeight(float fontSize) {
    IDWriteTextFormat* format = TextFormat(fontSize);
    IDWriteTextLayout* layout = nullptr;
    if (!format || FAILED(directWrite->CreateTextLayout(kLineSample, 1, format, 10000, 1000, &layout))) return fontSize;
    DWRITE_TEXT_METRICS metrics{};
    layout->GetMetrics(&metrics);
    layout->Release();
    // The border is centred on the node's edge, so half of it on each side falls inside.
    return metrics.height + SelectionStrokeWidth(CurrentCandidateAppearance());
}

float CandidatePanel::MeasureText(const std::wstring& text, float fontSize) {
    IDWriteTextFormat* format = TextFormat(fontSize);
    if (!format || text.empty()) return 0;
    IDWriteTextLayout* layout = nullptr;
    if (FAILED(directWrite->CreateTextLayout(text.c_str(), static_cast<UINT32>(text.size()), format, 10000, 1000, &layout))) {
        return 0;
    }
    DWRITE_TEXT_METRICS metrics{};
    layout->GetMetrics(&metrics);
    layout->Release();
    return metrics.widthIncludingTrailingWhitespace;
}

void CandidatePanel::LayoutSections(const PanelContent& content, float width) {
    rows_.clear();
    float y = 0;
    listBottom_ = 0;
    if (content.showList && content.display.list) {
        const display::CandidateList& list = *content.display.list;
        float rowHeight = content.fontSize + kRowExtraHeight;
        y = kPadding;
        for (const auto& item : list.items) {
            ListRow row;
            row.candidateIndex = item.index;
            row.number = item.number ? std::to_wstring(*item.number) : L"";
            row.text = item.text;
            row.selected = item.selected;
            row.frame = D2D1::RectF(kPadding, y, width - kPadding, y + rowHeight);
            rows_.push_back(std::move(row));
            y += rowHeight + kRowGap;
        }
        float footerHeight = kSmallTextSize + kRowExtraHeight;
        footerFrame_ = D2D1::RectF(kPadding, y, width - kPadding, y + footerHeight);
        float confirmWidth = MeasureText(list.confirmLabel, kSmallTextSize) + 2 * kPadding;
        confirmFrame_ = D2D1::RectF(footerFrame_.right - confirmWidth, footerFrame_.top + 2, footerFrame_.right, footerFrame_.bottom - 2);
        float arrowWidth = MeasureText(L"›", kSmallTextSize) + 2 * kPadding;
        nextFrame_ = D2D1::RectF(confirmFrame_.left - kPadding - arrowWidth, footerFrame_.top, confirmFrame_.left - kPadding,
                                 footerFrame_.bottom);
        previousFrame_ = D2D1::RectF(nextFrame_.left - arrowWidth, footerFrame_.top, nextFrame_.left, footerFrame_.bottom);
        y = footerFrame_.bottom + kPadding;
        listBottom_ = y;
    }
    treeTop_ = y;
}

float CandidatePanel::ContentHeight(const PanelContent& content, float width) {
    LayoutSections(content, width);
    return treeTop_ + (content.tree ? content.tree->contentHeight : 0);
}

void CandidatePanel::Show(const PanelContent& content, const RECT& frame, UINT dpi) {
    if (!EnsureWindow()) return;
    content_ = content;
    dpi_ = dpi;
    appearance_ = CurrentCandidateAppearance();
    panelWidth_ = (frame.right - frame.left) * 96.0f / dpi_;
    panelHeight_ = (frame.bottom - frame.top) * 96.0f / dpi_;
    LayoutSections(content_, panelWidth_);
    contentHeight_ = treeTop_ + (content_.tree ? content_.tree->contentHeight : 0);
    KeepFocusVisible();
    SetWindowPos(window_, HWND_TOPMOST, frame.left, frame.top, frame.right - frame.left, frame.bottom - frame.top,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
    if (target_) {
        target_->SetDpi(static_cast<float>(dpi_), static_cast<float>(dpi_));
        target_->Resize(D2D1::SizeU(frame.right - frame.left, frame.bottom - frame.top));
    }
    InvalidateRect(window_, nullptr, FALSE);
    UpdateAccessibility();
}

void CandidatePanel::Hide() {
    scrollOffset_ = 0;
    if (accessibility_) accessibility_->Clear();
    lastAnnouncement_.clear();
    if (window_) ShowWindow(window_, SW_HIDE);
}

void CandidatePanel::UpdateAccessibility() {
    if (!accessibility_) return;
    RECT window{};
    GetWindowRect(window_, &window);
    float scale = dpi_ / 96.0f;
    auto toScreen = [&](const D2D1_RECT_F& frame) {
        float top = frame.top - scrollOffset_;
        float bottom = frame.bottom - scrollOffset_;
        return RECT{window.left + static_cast<LONG>(frame.left * scale), window.top + static_cast<LONG>(top * scale),
                    window.left + static_cast<LONG>(frame.right * scale), window.top + static_cast<LONG>(bottom * scale)};
    };
    std::vector<AccessibleCandidate> items;
    if (content_.display.list && !rows_.empty()) {
        for (size_t i = 0; i < rows_.size() && i < content_.display.list->items.size(); ++i) {
            const auto& item = content_.display.list->items[i];
            items.push_back({item.index, item.accessibleName.empty() ? item.text : item.accessibleName, toScreen(rows_[i].frame),
                             item.selected});
        }
    }
    // Core announces only changes in the selection or the word being edited.
    std::wstring announcement;
    if (content_.display.announcement != lastAnnouncement_) announcement = content_.display.announcement;
    lastAnnouncement_ = content_.display.announcement;
    accessibility_->Update(std::move(items), announcement);
}

std::optional<D2D1_RECT_F> CandidatePanel::FocusFrame() const {
    if (content_.display.list) {
        for (const auto& row : rows_) {
            if (row.selected) return row.frame;
        }
    }
    if (!content_.tree) return std::nullopt;
    std::optional<D2D1_RECT_F> selected;
    for (const auto& layoutNode : content_.tree->nodes) {
        const display::DisplayNode* node = content_.display.FindNode(layoutNode.id);
        if (node && node->focused) return TreeRect(layoutNode.frame);
        if (node && node->selected && !selected) selected = TreeRect(layoutNode.frame);
    }
    return selected;
}

void CandidatePanel::KeepFocusVisible() {
    if (auto focus = FocusFrame()) {
        scrollOffset_ = std::min(scrollOffset_, focus->top - kPadding);
        scrollOffset_ = std::max(scrollOffset_, focus->bottom + kPadding - panelHeight_);
    }
    ScrollBy(0);
}

void CandidatePanel::ScrollBy(float dips) {
    scrollOffset_ = std::clamp(scrollOffset_ + dips, 0.0f, std::max(0.0f, contentHeight_ - panelHeight_));
}

void CandidatePanel::FillRounded(const D2D1_RECT_F& frame, float radius, uint32_t color) {
    brush_->SetColor(Color(color));
    target_->FillRoundedRectangle(D2D1::RoundedRect(frame, radius, radius), brush_);
}

void CandidatePanel::StrokeRounded(const D2D1_RECT_F& frame, float radius, uint32_t color, float width) {
    brush_->SetColor(Color(color));
    target_->DrawRoundedRectangle(D2D1::RoundedRect(frame, radius, radius), brush_, width);
}

void CandidatePanel::DrawText(const std::wstring& text, IDWriteTextFormat* format, const D2D1_RECT_F& frame, uint32_t color,
                              DWRITE_TEXT_ALIGNMENT alignment) {
    if (!format || text.empty() || frame.right <= frame.left) return;
    format->SetTextAlignment(alignment);
    brush_->SetColor(Color(color));
    target_->DrawText(text.c_str(), static_cast<UINT32>(text.size()), format, frame, brush_, D2D1_DRAW_TEXT_OPTIONS_CLIP);
}

D2D1_RECT_F CandidatePanel::TreeRect(const display::Frame& frame) const {
    return D2D1::RectF(frame.x, treeTop_ + frame.y, frame.x + frame.width, treeTop_ + frame.y + frame.height);
}

void CandidatePanel::PaintList() {
    const display::CandidateList& list = *content_.display.list;
    const CandidatePalette& palette = PaletteFor(appearance_);
    float strokeWidth = SelectionStrokeWidth(appearance_);
    IDWriteTextFormat* candidateFormat = TextFormat(content_.fontSize);
    IDWriteTextFormat* labelFormat = TextFormat(kSmallTextSize);
    for (const auto& row : rows_) {
        // Selection is background, border and text color together, never color alone.
        if (row.selected) {
            FillRounded(row.frame, kNodeRadius, palette.selection);
            StrokeRounded(row.frame, kNodeRadius, palette.selectionText, strokeWidth);
        }
        float numberWidth = content_.fontSize;
        DrawText(row.number, labelFormat, D2D1::RectF(row.frame.left, row.frame.top, row.frame.left + numberWidth, row.frame.bottom),
                 row.selected ? palette.selectionText : palette.secondaryText, DWRITE_TEXT_ALIGNMENT_CENTER);
        DrawText(row.text, candidateFormat,
                 D2D1::RectF(row.frame.left + numberWidth + kPadding / 2, row.frame.top, row.frame.right - kPadding, row.frame.bottom),
                 row.selected ? palette.selectionText : palette.text, DWRITE_TEXT_ALIGNMENT_LEADING);
    }
    DrawText(list.positionText, labelFormat, D2D1::RectF(footerFrame_.left, footerFrame_.top, previousFrame_.left - kPadding, footerFrame_.bottom),
             palette.secondaryText, DWRITE_TEXT_ALIGNMENT_LEADING);
    DrawText(L"‹", labelFormat, previousFrame_, list.previousIndex ? palette.text : palette.border, DWRITE_TEXT_ALIGNMENT_CENTER);
    DrawText(L"›", labelFormat, nextFrame_, list.nextIndex ? palette.text : palette.border, DWRITE_TEXT_ALIGNMENT_CENTER);
    uint32_t confirmFill = list.confirmIndex ? palette.selection : palette.surface;
    uint32_t confirmText = list.confirmIndex ? palette.selectionText : palette.border;
    FillRounded(confirmFrame_, kNodeRadius, confirmFill);
    StrokeRounded(confirmFrame_, kNodeRadius, confirmText, 1.0f);
    DrawText(list.confirmLabel, labelFormat, confirmFrame_, confirmText, DWRITE_TEXT_ALIGNMENT_CENTER);
}

void CandidatePanel::PaintTree() {
    const display::TreeLayout& tree = *content_.tree;
    const CandidatePalette& palette = PaletteFor(appearance_);
    // Branches first so the boxes cover their ends: the chosen sentence is a
    // thick solid line, the other paths thin dotted lines.
    for (const auto& edge : tree.edges) {
        const display::DisplayNode* node = content_.display.FindNode(edge.node);
        bool selected = node && node->selected;
        D2D1_POINT_2F start = D2D1::Point2F(edge.start.x, treeTop_ + edge.start.y);
        D2D1_POINT_2F end = D2D1::Point2F(edge.end.x, treeTop_ + edge.end.y);
        float middle = (start.x + end.x) / 2;
        ID2D1PathGeometry* path = nullptr;
        ID2D1GeometrySink* sink = nullptr;
        if (FAILED(direct2D->CreatePathGeometry(&path)) || FAILED(path->Open(&sink))) {
            SafeRelease(&path);
            continue;
        }
        sink->BeginFigure(start, D2D1_FIGURE_BEGIN_HOLLOW);
        sink->AddBezier(D2D1::BezierSegment(D2D1::Point2F(middle, start.y), D2D1::Point2F(middle, end.y), end));
        sink->EndFigure(D2D1_FIGURE_END_OPEN);
        sink->Close();
        brush_->SetColor(Color(selected ? palette.text : palette.border));
        target_->DrawGeometry(path, brush_, selected ? 3.0f : 1.0f, selected ? nullptr : dashed_);
        sink->Release();
        path->Release();
    }
    brush_->SetColor(Color(palette.text));
    target_->FillEllipse(D2D1::Ellipse(D2D1::Point2F(tree.rootAnchor.x, treeTop_ + tree.rootAnchor.y), 3, 3), brush_);

    float strokeWidth = SelectionStrokeWidth(appearance_);
    IDWriteTextFormat* wordFormat = TextFormat(tree.metrics.fontSize);
    IDWriteTextFormat* numberFormat = TextFormat(tree.metrics.numberFontSize);
    IDWriteTextFormat* scoreFormat = TextFormat(tree.metrics.scoreFontSize);
    for (const auto& layoutNode : tree.nodes) {
        const display::DisplayNode* node = content_.display.FindNode(layoutNode.id);
        const protocol::TreeNode* word = FindWord(content_.nodes, layoutNode.id);
        if (!node || !word) continue;
        D2D1_RECT_F box = TreeRect(layoutNode.frame);
        FillRounded(box, kNodeRadius, node->selected ? palette.selection : palette.surface);
        if (node->selected) StrokeRounded(box, kNodeRadius, palette.text, strokeWidth);
        uint32_t textColor = node->selected ? palette.selectionText : palette.text;
        D2D1_RECT_F textBox = TreeRect(layoutNode.textFrame);
        if (node->focused) {
            // The word the arrow keys act on is underlined.
            brush_->SetColor(Color(textColor));
            float underline = textBox.bottom - 4;
            target_->DrawLine(D2D1::Point2F(box.left + 6, underline), D2D1::Point2F(box.right - 6, underline), brush_, 2.0f);
        }
        DrawText(word->text, wordFormat, textBox, textColor,
                 tree.leadingText ? DWRITE_TEXT_ALIGNMENT_LEADING : DWRITE_TEXT_ALIGNMENT_CENTER);
        if (content_.showScores && layoutNode.scoreFrame && word->score) {
            D2D1_RECT_F row = TreeRect(*layoutNode.scoreFrame);
            float labelWidth = MeasureText(word->score->label, tree.metrics.scoreFontSize);
            float badgeWidth = std::min(row.right - row.left, std::max(tree.metrics.scoreBadgeMinimumWidth,
                                                                       labelWidth + 2 * tree.metrics.scoreBadgeHorizontalInset));
            float left = row.left + (row.right - row.left - badgeWidth) / 2;
            D2D1_RECT_F badge = D2D1::RectF(left, row.top, left + badgeWidth, row.bottom);
            uint32_t badgeColor = word->score->role == "scoreLow"    ? palette.scoreLow
                                  : word->score->role == "scoreHigh" ? palette.scoreHigh
                                                                     : palette.scoreUnknown;
            brush_->SetColor(Color(badgeColor));
            target_->FillRectangle(badge, brush_);
            DrawText(word->score->label, scoreFormat, badge, palette.scoreText, DWRITE_TEXT_ALIGNMENT_CENTER);
        }
        if (layoutNode.numberFrame && node->number) {
            DrawText(std::to_wstring(*node->number), numberFormat, TreeRect(*layoutNode.numberFrame), textColor,
                     DWRITE_TEXT_ALIGNMENT_LEADING);
        }
    }
}

void CandidatePanel::Paint() {
    if (!EnsureDeviceResources()) return;
    target_->BeginDraw();
    const CandidatePalette& palette = PaletteFor(appearance_);
    target_->Clear(Color(palette.background));
    target_->SetTransform(D2D1::Matrix3x2F::Translation(0, -scrollOffset_));
    if (!rows_.empty() && content_.display.list) PaintList();
    if (content_.tree) PaintTree();
    target_->SetTransform(D2D1::Matrix3x2F::Identity());
    // The outline goes last so scrolled content never covers it.
    StrokeRounded(D2D1::RectF(0.5f, 0.5f, panelWidth_ - 0.5f, panelHeight_ - 0.5f), kCornerRadius, palette.border, 1.0f);
    if (target_->EndDraw() == D2DERR_RECREATE_TARGET) ReleaseDeviceResources();
}

CandidatePanel::Hit CandidatePanel::HitTest(POINT clientPixels) const {
    D2D1_POINT_2F point = D2D1::Point2F(clientPixels.x * 96.0f / dpi_, clientPixels.y * 96.0f / dpi_ + scrollOffset_);
    if (content_.display.list && !rows_.empty()) {
        for (const auto& row : rows_) {
            if (Contains(row.frame, point)) return {Hit::Kind::Row, row.candidateIndex};
        }
        const display::CandidateList& list = *content_.display.list;
        if (list.confirmIndex && Contains(confirmFrame_, point)) return {Hit::Kind::Confirm, *list.confirmIndex};
        if (list.previousIndex && Contains(previousFrame_, point)) return {Hit::Kind::PreviousPage, *list.previousIndex};
        if (list.nextIndex && Contains(nextFrame_, point)) return {Hit::Kind::NextPage, *list.nextIndex};
    }
    if (content_.tree) {
        display::Point treePoint{point.x, point.y - treeTop_};
        for (auto node = content_.tree->nodes.rbegin(); node != content_.tree->nodes.rend(); ++node) {
            if (node->frame.Contains(treePoint)) return {Hit::Kind::Node, node->id};
        }
    }
    return {};
}

void CandidatePanel::Activate(const Hit& hit, bool doubleClick) {
    switch (hit.kind) {
    case Hit::Kind::Row:
        // A click selects; confirming is explicit (button, Enter or a double click).
        if (doubleClick) {
            if (actions_.confirmCandidate) actions_.confirmCandidate(hit.value);
        } else if (actions_.selectCandidate) {
            actions_.selectCandidate(hit.value);
        }
        break;
    case Hit::Kind::Confirm:
        if (actions_.confirmCandidate) actions_.confirmCandidate(hit.value);
        break;
    case Hit::Kind::PreviousPage:
    case Hit::Kind::NextPage:
        if (actions_.selectCandidate) actions_.selectCandidate(hit.value);
        break;
    case Hit::Kind::Node:
        if (actions_.selectNode) actions_.selectNode(hit.value);
        break;
    case Hit::Kind::None:
        break;
    }
}

LRESULT CALLBACK CandidatePanel::WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_NCCREATE) {
        auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto* self = reinterpret_cast<CandidatePanel*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    switch (message) {
    case WM_MOUSEACTIVATE:
        // Clicking the panel must not move focus away from the text being edited.
        return MA_NOACTIVATE;
    case WM_GETOBJECT:
        if (self && self->accessibility_) {
            if (LRESULT result = self->accessibility_->HandleGetObject(wParam, lParam)) return result;
        }
        break;
    case WM_PAINT: {
        PAINTSTRUCT paint;
        BeginPaint(window, &paint);
        if (self) self->Paint();
        EndPaint(window, &paint);
        return 0;
    }
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
        if (self) self->Activate(self->HitTest({GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)}), message == WM_LBUTTONDBLCLK);
        return 0;
    case WM_MOUSEWHEEL:
        // Windows sends the wheel to the window under the pointer, so a shrunk panel can be scrolled without focus.
        if (self && self->contentHeight_ > self->panelHeight_) {
            float rowStep = self->content_.fontSize + kRowExtraHeight;
            self->ScrollBy(-static_cast<float>(GET_WHEEL_DELTA_WPARAM(wParam)) / WHEEL_DELTA * rowStep);
            InvalidateRect(window, nullptr, FALSE);
            self->UpdateAccessibility();
            return 0;
        }
        break;
    case WM_SETTINGCHANGE:
    case WM_THEMECHANGED:
        if (self) {
            self->appearance_ = CurrentCandidateAppearance();
            InvalidateRect(window, nullptr, FALSE);
        }
        break;
    case WM_NCDESTROY:
        if (self) {
            self->accessibility_.reset();
            self->ReleaseDeviceResources();
            self->window_ = nullptr;
        }
        break;
    default:
        break;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

}  // namespace azookey::tsf
