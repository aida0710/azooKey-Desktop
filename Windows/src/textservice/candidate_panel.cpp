#include "candidate_panel.h"

#include <dwmapi.h>
#include <shellscalingapi.h>
#include <windowsx.h>

#include <algorithm>

#include "candidate_messages.h"
#include "module.h"

namespace azookey::tsf {
namespace {

constexpr wchar_t kWindowClassName[] = L"azooKeyTreeCandidatePanel";
// Sizes in device-independent pixels, matching the Linux renderers: words
// 18 (24 when the large text setting is on), secondary text 12.
constexpr float kStandardTextSize = 18;
constexpr float kLargeTextSize = 24;
constexpr float kSmallTextSize = 12;
constexpr float kPadding = 6;
constexpr float kRowExtraHeight = 14;  // a compact row: text plus 7 above and below
constexpr float kRowGap = 2;
constexpr float kMinimumListWidth = 220;
constexpr float kCornerRadius = 8;
constexpr float kNodeRadius = 4;
constexpr float kAnchorGap = 2;
// The tree's root marker, where the first branch starts (as in the GTK tree).
constexpr D2D1_POINT_2F kTreeRoot = {4, 18};

bool windowClassRegistered = false;
ID2D1Factory* direct2D = nullptr;
IDWriteFactory* directWrite = nullptr;

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

}  // namespace

CandidatePanel::CandidatePanel(Actions actions) : actions_(std::move(actions)) {}

CandidatePanel::~CandidatePanel() {
    ReleaseDeviceResources();
    SafeRelease(&textFormat_);
    SafeRelease(&smallFormat_);
    if (window_) DestroyWindow(window_);
}

void CandidatePanel::UnregisterWindowClass() {
    if (windowClassRegistered) {
        UnregisterClassW(kWindowClassName, ModuleInstance());
        windowClassRegistered = false;
    }
}

bool CandidatePanel::EnsureWindow() {
    if (window_) return true;
    if (!EnsureFactories()) return false;
    if (!windowClassRegistered) {
        WNDCLASSEXW windowClass{sizeof(windowClass)};
        windowClass.style = CS_IME | CS_DBLCLKS;
        windowClass.lpfnWndProc = WindowProcedure;
        windowClass.hInstance = ModuleInstance();
        windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        windowClass.lpszClassName = kWindowClassName;
        windowClassRegistered = RegisterClassExW(&windowClass) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
        if (!windowClassRegistered) return false;
    }
    // Our window is per-monitor DPI aware whatever the host application declares.
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    window_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kWindowClassName, L"azooKey Tree",
                              WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, ModuleInstance(), this);
    if (previous) SetThreadDpiAwarenessContext(previous);
    if (!window_) return false;
    DWM_WINDOW_CORNER_PREFERENCE corners = DWMWCP_ROUNDSMALL;
    DwmSetWindowAttribute(window_, DWMWA_WINDOW_CORNER_PREFERENCE, &corners, sizeof(corners));
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
        float dashes[] = {2, 3};  // the GTK tree's dotted branches
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

bool CandidatePanel::EnsureTextFormats(float textSize) {
    if (textFormat_ && textSize_ == textSize) return true;
    SafeRelease(&textFormat_);
    SafeRelease(&smallFormat_);
    textSize_ = textSize;
    for (auto [format, size] : {std::pair{&textFormat_, textSize}, std::pair{&smallFormat_, kSmallTextSize}}) {
        if (FAILED(directWrite->CreateTextFormat(L"Yu Gothic UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                                                 DWRITE_FONT_STRETCH_NORMAL, size, L"ja-jp", format))) {
            return false;
        }
        (*format)->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        (*format)->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        IDWriteInlineObject* ellipsis = nullptr;
        if (SUCCEEDED(directWrite->CreateEllipsisTrimmingSign(*format, &ellipsis))) {
            DWRITE_TRIMMING trimming{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
            (*format)->SetTrimming(&trimming, ellipsis);
            ellipsis->Release();
        }
    }
    return true;
}

float CandidatePanel::MeasureText(const std::wstring& text, IDWriteTextFormat* format) const {
    IDWriteTextLayout* layout = nullptr;
    if (FAILED(directWrite->CreateTextLayout(text.c_str(), static_cast<UINT32>(text.size()), format, 10000, 1000, &layout))) {
        return 0;
    }
    DWRITE_TEXT_METRICS metrics{};
    layout->GetMetrics(&metrics);
    layout->Release();
    return metrics.widthIncludingTrailingWhitespace;
}

UINT CandidatePanel::DpiAt(POINT point) const {
    UINT dpiX = 96, dpiY = 96;
    GetDpiForMonitor(MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST), MDT_EFFECTIVE_DPI, &dpiX, &dpiY);
    return dpiX;
}

void CandidatePanel::PlaceWindow(int x, int y, float widthDips, float heightDips) {
    int width = static_cast<int>(widthDips * dpi_ / 96.0f + 0.5f);
    int height = static_cast<int>(heightDips * dpi_ / 96.0f + 0.5f);
    SetWindowPos(window_, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    if (target_) {
        target_->SetDpi(static_cast<float>(dpi_), static_cast<float>(dpi_));
        target_->Resize(D2D1::SizeU(width, height));
    }
    InvalidateRect(window_, nullptr, FALSE);
}

void CandidatePanel::LayoutList(const protocol::Snapshot& snapshot) {
    const protocol::CandidatePage& page = snapshot.candidatePage;
    selection_ = snapshot.selection;
    previousIndex_ = page.previousIndex;
    nextIndex_ = page.nextIndex;
    rows_.clear();
    annotation_.clear();
    float textWidth = 0;
    float numberWidth = MeasureText(L"9", textFormat_) + kPadding;
    float rowHeight = textSize_ + kRowExtraHeight;
    float y = kPadding;
    for (const auto& item : page.items) {
        ListRow row;
        row.candidateIndex = item.index;
        row.number = snapshot.showCandidateIndex ? std::to_wstring(item.index - page.start + 1) : L"";
        row.text = item.text;
        row.selected = snapshot.selection && *snapshot.selection == item.index;
        if (row.selected) annotation_ = item.annotation;
        textWidth = std::max(textWidth, MeasureText(item.text, textFormat_));
        row.frame = D2D1::RectF(kPadding, y, 0, y + rowHeight);
        rows_.push_back(std::move(row));
        y += rowHeight + kRowGap;
    }
    status_ = CandidateMessage("candidate.position",
                               {{L"position", page.position ? std::to_wstring(*page.position) : L"—"},
                                {L"total", std::to_wstring(page.totalCount)}});
    float footerHeight = kSmallTextSize + kRowExtraHeight;
    std::wstring confirmLabel = CandidateMessage("candidate.submit") + L" ↵";
    float footerWidth = MeasureText(status_, smallFormat_) + MeasureText(confirmLabel, smallFormat_) +
                        MeasureText(L"‹ ›", smallFormat_) + 4 * kPadding;
    panelWidth_ = std::max({kMinimumListWidth, numberWidth + textWidth + 3 * kPadding, footerWidth});
    for (auto& row : rows_) row.frame.right = panelWidth_ - kPadding;
    footerFrame_ = D2D1::RectF(kPadding, y, panelWidth_ - kPadding, y + footerHeight);
    float confirmWidth = MeasureText(confirmLabel, smallFormat_) + 2 * kPadding;
    confirmFrame_ = D2D1::RectF(footerFrame_.right - confirmWidth, footerFrame_.top + 2, footerFrame_.right, footerFrame_.bottom - 2);
    float arrowWidth = MeasureText(L"›", smallFormat_) + 2 * kPadding;
    nextFrame_ = D2D1::RectF(confirmFrame_.left - kPadding - arrowWidth, footerFrame_.top, confirmFrame_.left - kPadding, footerFrame_.bottom);
    previousFrame_ = D2D1::RectF(nextFrame_.left - arrowWidth, footerFrame_.top, nextFrame_.left, footerFrame_.bottom);
    panelHeight_ = footerFrame_.bottom + kPadding;
}

void CandidatePanel::ShowList(const protocol::Snapshot& snapshot, const RECT& anchor) {
    if (snapshot.candidatePage.items.empty() || !EnsureWindow()) {
        Hide();
        return;
    }
    POINT anchorPoint{anchor.left, anchor.bottom};
    dpi_ = DpiAt(anchorPoint);
    appearance_ = CurrentCandidateAppearance();
    if (!EnsureTextFormats(snapshot.largeText ? kLargeTextSize : kStandardTextSize)) return;
    mode_ = Mode::List;
    LayoutList(snapshot);

    MONITORINFO monitor{sizeof(monitor)};
    GetMonitorInfoW(MonitorFromPoint(anchorPoint, MONITOR_DEFAULTTONEAREST), &monitor);
    const RECT& work = monitor.rcWork;
    int width = static_cast<int>(panelWidth_ * dpi_ / 96.0f + 0.5f);
    int height = static_cast<int>(panelHeight_ * dpi_ / 96.0f + 0.5f);
    int gap = static_cast<int>(kAnchorGap * dpi_ / 96.0f + 0.5f);
    int x = std::clamp<int>(anchor.left, work.left, std::max<int>(work.left, work.right - width));
    int y = anchor.bottom + gap;
    // Above the line when there is no room below, never covering the caret.
    if (y + height > work.bottom) y = std::max<int>(work.top, anchor.top - gap - height);
    PlaceWindow(x, y, panelWidth_, panelHeight_);
}

void CandidatePanel::ShowTree(const protocol::Snapshot& snapshot, const TreePresentation& tree, POINT origin) {
    if (tree.frames.empty() || !EnsureWindow()) {
        Hide();
        return;
    }
    dpi_ = DpiAt(origin);
    appearance_ = CurrentCandidateAppearance();
    if (!EnsureTextFormats(snapshot.largeText ? kLargeTextSize : kStandardTextSize)) return;
    mode_ = Mode::Tree;
    tree_ = tree;
    treeSnapshot_ = snapshot;
    panelWidth_ = tree.width;
    panelHeight_ = tree.height;
    PlaceWindow(origin.x, origin.y, panelWidth_, panelHeight_);
}

void CandidatePanel::Hide() {
    mode_ = Mode::Hidden;
    if (window_) ShowWindow(window_, SW_HIDE);
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
    if (text.empty() || frame.right <= frame.left) return;
    format->SetTextAlignment(alignment);
    brush_->SetColor(Color(color));
    target_->DrawText(text.c_str(), static_cast<UINT32>(text.size()), format, frame, brush_, D2D1_DRAW_TEXT_OPTIONS_CLIP);
}

void CandidatePanel::PaintList() {
    const CandidatePalette& palette = PaletteFor(appearance_);
    float strokeWidth = IsHighContrast(appearance_) ? 3.0f : 2.0f;
    for (const auto& row : rows_) {
        // Selection is shown by background, border and text color together,
        // never by color alone.
        if (row.selected) {
            FillRounded(row.frame, kNodeRadius, palette.selection);
            StrokeRounded(row.frame, kNodeRadius, palette.selectionText, strokeWidth);
        }
        uint32_t textColor = row.selected ? palette.selectionText : palette.text;
        float numberWidth = textSize_;
        DrawText(row.number, smallFormat_, D2D1::RectF(row.frame.left, row.frame.top, row.frame.left + numberWidth, row.frame.bottom),
                 row.selected ? palette.selectionText : palette.secondaryText, DWRITE_TEXT_ALIGNMENT_CENTER);
        DrawText(row.text, textFormat_,
                 D2D1::RectF(row.frame.left + numberWidth + kPadding / 2, row.frame.top, row.frame.right - kPadding, row.frame.bottom),
                 textColor, DWRITE_TEXT_ALIGNMENT_LEADING);
    }
    std::wstring footerText = annotation_.empty() ? status_ : annotation_ + L"  " + status_;
    DrawText(footerText, smallFormat_, D2D1::RectF(footerFrame_.left, footerFrame_.top, previousFrame_.left - kPadding, footerFrame_.bottom),
             palette.secondaryText, DWRITE_TEXT_ALIGNMENT_LEADING);
    DrawText(L"‹", smallFormat_, previousFrame_, previousIndex_ ? palette.text : palette.border, DWRITE_TEXT_ALIGNMENT_CENTER);
    DrawText(L"›", smallFormat_, nextFrame_, nextIndex_ ? palette.text : palette.border, DWRITE_TEXT_ALIGNMENT_CENTER);
    FillRounded(confirmFrame_, kNodeRadius, palette.selection);
    StrokeRounded(confirmFrame_, kNodeRadius, palette.selectionText, 1.0f);
    DrawText(CandidateMessage("candidate.submit") + L" ↵", smallFormat_, confirmFrame_, palette.selectionText, DWRITE_TEXT_ALIGNMENT_CENTER);
}

void CandidatePanel::PaintTree() {
    const CandidatePalette& palette = PaletteFor(appearance_);
    std::map<int, D2D1_RECT_F> frames;
    for (const auto& frame : tree_.frames) {
        frames[frame.nodeId] = D2D1::RectF(frame.x, frame.y, frame.x + frame.width, frame.y + frame.height);
    }
    auto isSelected = [&](int id) {
        return std::find(treeSnapshot_.selectedPath.begin(), treeSnapshot_.selectedPath.end(), id) != treeSnapshot_.selectedPath.end();
    };
    // Branches first so the boxes cover their ends: the chosen path is a thick
    // solid line, the other paths thin dotted lines.
    for (const auto& node : treeSnapshot_.nodes) {
        auto found = frames.find(node.id);
        if (found == frames.end()) continue;
        D2D1_POINT_2F start = kTreeRoot;
        if (node.parent) {
            auto parent = frames.find(*node.parent);
            if (parent != frames.end()) {
                start = D2D1::Point2F(parent->second.right, (parent->second.top + parent->second.bottom) / 2);
            }
        }
        D2D1_POINT_2F end = D2D1::Point2F(found->second.left, (found->second.top + found->second.bottom) / 2);
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
        bool selected = isSelected(node.id);
        brush_->SetColor(Color(selected ? palette.text : palette.border));
        target_->DrawGeometry(path, brush_, selected ? 3.0f : 1.0f, selected ? nullptr : dashed_);
        sink->Release();
        path->Release();
    }
    brush_->SetColor(Color(palette.text));
    target_->FillEllipse(D2D1::Ellipse(kTreeRoot, 3, 3), brush_);

    float strokeWidth = IsHighContrast(appearance_) ? 3.0f : 2.0f;
    for (const auto& node : treeSnapshot_.nodes) {
        auto found = frames.find(node.id);
        if (found == frames.end()) continue;
        const D2D1_RECT_F& box = found->second;
        bool selected = isSelected(node.id);
        FillRounded(box, kNodeRadius, selected ? palette.selection : palette.surface);
        if (selected) StrokeRounded(box, kNodeRadius, palette.text, strokeWidth);
        uint32_t textColor = selected ? palette.selectionText : palette.text;
        if (treeSnapshot_.focusedNode && *treeSnapshot_.focusedNode == node.id) {
            // The node that the arrow keys act on is underlined.
            brush_->SetColor(Color(textColor));
            float underline = box.top + tree_.wordHeight - 4;
            target_->DrawLine(D2D1::Point2F(box.left + 6, underline), D2D1::Point2F(box.right - 6, underline), brush_, 2.0f);
        }
        float inset = tree_.aligned ? 2.0f : 4.0f;
        DrawText(node.text, textFormat_, D2D1::RectF(box.left + inset, box.top, box.right - inset, box.top + tree_.wordHeight),
                 textColor, tree_.aligned ? DWRITE_TEXT_ALIGNMENT_LEADING : DWRITE_TEXT_ALIGNMENT_CENTER);
        if (treeSnapshot_.showRelativeScores && node.score && tree_.scoreHeight > 0) {
            float badgeWidth = std::min(box.right - box.left, std::max(22.0f, MeasureText(node.score->label, smallFormat_) + 6));
            float left = box.left + (box.right - box.left - badgeWidth) / 2;
            D2D1_RECT_F badge = D2D1::RectF(left, box.top + tree_.wordHeight, left + badgeWidth, box.top + tree_.wordHeight + tree_.scoreHeight);
            uint32_t badgeColor = node.score->role == "scoreLow"    ? palette.scoreLow
                                  : node.score->role == "scoreHigh" ? palette.scoreHigh
                                                                     : palette.scoreUnknown;
            brush_->SetColor(Color(badgeColor));
            target_->FillRectangle(badge, brush_);
            DrawText(node.score->label, smallFormat_, badge, palette.scoreText, DWRITE_TEXT_ALIGNMENT_CENTER);
        }
        auto number = tree_.numbers.find(node.id);
        if (number != tree_.numbers.end()) {
            DrawText(std::to_wstring(number->second), smallFormat_,
                     D2D1::RectF(box.left + 6, box.bottom - tree_.numberHeight, box.right - 6, box.bottom), textColor,
                     DWRITE_TEXT_ALIGNMENT_LEADING);
        }
    }
}

void CandidatePanel::Paint() {
    if (!EnsureDeviceResources()) return;
    target_->BeginDraw();
    const CandidatePalette& palette = PaletteFor(appearance_);
    target_->Clear(Color(palette.background));
    StrokeRounded(D2D1::RectF(0.5f, 0.5f, panelWidth_ - 0.5f, panelHeight_ - 0.5f), kCornerRadius, palette.border, 1.0f);
    if (mode_ == Mode::List) PaintList();
    else if (mode_ == Mode::Tree) PaintTree();
    if (target_->EndDraw() == D2DERR_RECREATE_TARGET) ReleaseDeviceResources();
}

CandidatePanel::Hit CandidatePanel::HitTest(POINT clientPixels) const {
    D2D1_POINT_2F point = D2D1::Point2F(clientPixels.x * 96.0f / dpi_, clientPixels.y * 96.0f / dpi_);
    if (mode_ == Mode::List) {
        for (const auto& row : rows_) {
            if (Contains(row.frame, point)) return {Hit::Kind::Row, row.candidateIndex};
        }
        if (Contains(confirmFrame_, point)) return {Hit::Kind::Confirm, 0};
        if (previousIndex_ && Contains(previousFrame_, point)) return {Hit::Kind::PreviousPage, *previousIndex_};
        if (nextIndex_ && Contains(nextFrame_, point)) return {Hit::Kind::NextPage, *nextIndex_};
    } else if (mode_ == Mode::Tree) {
        for (auto frame = tree_.frames.rbegin(); frame != tree_.frames.rend(); ++frame) {
            if (Contains(D2D1::RectF(frame->x, frame->y, frame->x + frame->width, frame->y + frame->height), point)) {
                return {Hit::Kind::Node, frame->nodeId};
            }
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
        if (selection_ && actions_.confirmCandidate) actions_.confirmCandidate(*selection_);
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
    case WM_SETTINGCHANGE:
    case WM_THEMECHANGED:
        if (self) {
            self->appearance_ = CurrentCandidateAppearance();
            InvalidateRect(window, nullptr, FALSE);
        }
        break;
    case WM_NCDESTROY:
        if (self) {
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
