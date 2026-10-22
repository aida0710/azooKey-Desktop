#include "ai_transform_window.h"

#include <commctrl.h>

#include <algorithm>

#include "../shared/ai_protocol.h"
#include "../ui/access_key_label.h"
#include "../ui/child_controls.h"
#include "../ui/clipboard.h"
#include "../ui/control_accessibility.h"

namespace azookey::ai_transform {
namespace {

constexpr UINT kRepliesReadyMessage = WM_APP + 1;
// Room for the target, the instruction controls and a preview of several lines.
constexpr SIZE kClientSize = {620, 660};
constexpr int kMargin = 16;
constexpr int kGap = 8;
constexpr int kLabelGap = 4;
constexpr int kTargetHeight = 72;
constexpr int kMinimumResultHeight = 80;
constexpr int kMaximumFieldWidth = 560;
constexpr DWORD kTextStyle = SS_LEFT | SS_NOPREFIX;
constexpr DWORD kButtonStyle = WS_TABSTOP | BS_PUSHBUTTON;
// Core's codes for an instruction that cannot be kept in the history.
constexpr std::pair<const char*, const char*> kHistoryErrorKeys[] = {
    {"format", "ai.shortcut.error.format"},
    {"modifierRequired", "ai.shortcut.error.modifier-required"},
    {"duplicateShortcut", "ai.shortcut.error.duplicate"},
    {"saveFailed", "ai.history.error.save"},
};
// Pinned instructions are marked as on Linux.
constexpr wchar_t kPinnedMark[] = L"★ ";

}  // namespace

AITransformWindow::AITransformWindow(Options options) : options_(std::move(options)) {
    targetAvailable_ = options_.held.needsWitness;
    if (!Create(kClassName, Text("ai.title"), nullptr, kClientSize)) return;
    conversion_ = std::make_unique<ui::BridgeWorker>(
        ui::BridgeWorker::Options{options_.conversion, window(), kRepliesReadyMessage});
    ai_ = std::make_unique<ui::BridgeWorker>(ui::BridgeWorker::Options{options_.ai, window(), kRepliesReadyMessage});
    Build();
}

AITransformWindow::~AITransformWindow() {
    ai_.reset();
    conversion_.reset();
}

std::wstring AITransformWindow::Text(std::string_view key) const { return messages::Text(key, options_.language); }

HWND AITransformWindow::AddStatic(const std::wstring& text) {
    return ui::CreateChildControl(window(), WC_STATICW, text, kTextStyle, commands_.Reserve());
}

HWND AITransformWindow::AddLabel(std::string_view key, const std::string& accessKey) {
    // Without SS_NOPREFIX the access key moves focus to the control created next.
    return ui::CreateChildControl(window(), WC_STATICW, ui::LabelWithAccessKey(Text(key), accessKey), SS_LEFT,
                                  commands_.Reserve());
}

HWND AITransformWindow::AddButton(std::string_view key, int id) {
    return ui::CreateChildControl(window(), WC_BUTTONW, ui::EscapeAccessKeyMarkers(Text(key)), kButtonStyle, id);
}

void AITransformWindow::Build() {
    const HeldTransformation& held = options_.held;
    std::wstring destination = Text("ai.scope.destination") + L": " +
                               (held.destination ? *held.destination : Text("ai.destination.invalid"));
    destination_ = AddStatic(destination);
    targetLabel_ = AddStatic(Text("ai.scope.target"));
    target_ = ui::CreateChildControl(window(), WC_EDITW, ui::ToEditLineBreaks(held.target),
                                     WS_TABSTOP | WS_VSCROLL | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL,
                                     commands_.Reserve(), WS_EX_CLIENTEDGE);
    ui::SetAccessibleName(target_, Text("ai.scope.target"));
    includeContext_ = ui::CreateChildControl(window(), WC_BUTTONW, ui::EscapeAccessKeyMarkers(Text("ai.scope.include-context")),
                                             WS_TABSTOP | BS_AUTOCHECKBOX | BS_MULTILINE,
                                             commands_.Register([this](unsigned notification) {
                                                 if (notification == BN_CLICKED) ChangeIncludeContext();
                                             }));
    SendMessageW(includeContext_, BM_SETCHECK, held.includeContext ? BST_CHECKED : BST_UNCHECKED, 0);
    historyNote_ = AddStatic(Text("ai.scope.history"));
    instructionLabel_ = AddLabel("ai.instruction", "I");
    instruction_ = ui::CreateChildControl(window(), WC_EDITW, held.initialPrompt, WS_TABSTOP | ES_AUTOHSCROLL,
                                          commands_.Register([this](unsigned notification) {
                                              if (notification == EN_CHANGE) Invalidate();
                                          }),
                                          WS_EX_CLIENTEDGE);
    std::wstring placeholder = Text("ai.instruction-placeholder");
    SendMessageW(instruction_, EM_SETCUEBANNER, TRUE, reinterpret_cast<LPARAM>(placeholder.c_str()));
    ui::SetAccessibleName(instruction_, Text("ai.instruction"));
    historyLabel_ = AddLabel("ai.history", "H");
    history_ = ui::CreateChildControl(window(), WC_COMBOBOXW, L"", WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST,
                                      commands_.Register([this](unsigned notification) {
                                          if (notification == CBN_SELCHANGE) ChooseHistory();
                                      }));
    SendMessageW(history_, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(Text("ai.history.choose").c_str()));
    for (const auto& item : held.history) {
        std::wstring shown = (item.pinned ? kPinnedMark : L"") + item.prompt;
        if (!item.shortcutText.empty()) {
            shown = messages::Text("ai.history.item-with-shortcut", options_.language,
                                   {{L"prompt", shown}, {L"shortcut", item.shortcutText}});
        }
        SendMessageW(history_, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(shown.c_str()));
    }
    SendMessageW(history_, CB_SETCURSEL, 0, 0);
    ui::SetAccessibleName(history_, Text("ai.history"));
    pin_ = ui::CreateChildControl(window(), WC_BUTTONW, ui::EscapeAccessKeyMarkers(Text("ai.pin")),
                                  WS_TABSTOP | BS_AUTOCHECKBOX, commands_.Reserve());
    shortcutLabel_ = AddLabel("ai.shortcut.prompt", "S");
    shortcut_ = ui::CreateChildControl(window(), WC_EDITW, L"", WS_TABSTOP | ES_AUTOHSCROLL, commands_.Reserve(),
                                       WS_EX_CLIENTEDGE);
    std::wstring shortcutPlaceholder = Text("ai.shortcut.placeholder");
    SendMessageW(shortcut_, EM_SETCUEBANNER, TRUE, reinterpret_cast<LPARAM>(shortcutPlaceholder.c_str()));
    ui::SetAccessibleName(shortcut_, Text("ai.shortcut.prompt"));
    preview_ = AddButton("ai.scope.preview", commands_.Register([this](unsigned notification) {
        if (notification == BN_CLICKED) Generate();
    }));
    resultLabel_ = AddStatic(Text("ai.preview"));
    result_ = ui::CreateChildControl(window(), WC_EDITW, L"", WS_TABSTOP | WS_VSCROLL | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL,
                                     commands_.Reserve(), WS_EX_CLIENTEDGE);
    ui::SetAccessibleName(result_, Text("ai.preview"));
    copy_ = AddButton("ai.preview.copy", commands_.Register([this](unsigned notification) {
        if (notification == BN_CLICKED) Copy();
    }));
    targetMessage_ = AddStatic(L"");
    ui::MakeLiveRegion(targetMessage_);
    status_ = AddStatic(L"");
    ui::MakeLiveRegion(status_);
    close_ = AddButton("ai.close", IDCANCEL);
    apply_ = AddButton("ai.preview.apply", commands_.Register([this](unsigned notification) {
        if (notification == BN_CLICKED) Apply();
    }));
    EnableWindow(copy_, FALSE);
    ui::ApplyFont(window(), metrics().font());
    SetTargetAvailable(targetAvailable_);
}

void AITransformWindow::Present() {
    if (!window()) return;
    ShowWindow(window(), SW_SHOW);
    SetForegroundWindow(window());
    SetFocus(instruction_);
    SendMessageW(instruction_, EM_SETSEL, 0, -1);
}

void AITransformWindow::Layout() {
    if (!apply_) return;
    const ui::UiMetrics& metrics = this->metrics();
    RECT client{};
    GetClientRect(window(), &client);
    const int margin = metrics.Scale(kMargin);
    const int gap = metrics.Scale(kGap);
    const int labelGap = metrics.Scale(kLabelGap);
    const int width = std::max(1, static_cast<int>(client.right) - 2 * margin);
    const int fieldWidth = std::min(width, metrics.Scale(kMaximumFieldWidth));
    auto wrapped = [&](HWND control, int availableWidth) {
        return metrics.WrappedTextHeight(ui::WindowText(control), availableWidth, metrics.font());
    };
    int y = margin;
    auto placeText = [&](HWND control, int gapAfter) {
        int height = wrapped(control, width);
        ui::MoveControl(control, margin, y, width, height);
        if (height > 0) y += height + gapAfter;
    };
    auto placeField = [&](HWND control, int height, int gapAfter) {
        ui::MoveControl(control, margin, y, fieldWidth, height);
        y += height + gapAfter;
    };
    placeText(destination_, gap);
    placeText(targetLabel_, labelGap);
    placeField(target_, metrics.Scale(kTargetHeight), gap);
    int checkHeight = std::max(wrapped(includeContext_, width - metrics.Scale(24)), metrics.LineHeight()) + metrics.Scale(4);
    ui::MoveControl(includeContext_, margin, y, width, checkHeight);
    y += checkHeight + gap;
    placeText(historyNote_, gap);
    placeText(instructionLabel_, labelGap);
    placeField(instruction_, metrics.FieldHeight(), gap);
    placeText(historyLabel_, labelGap);
    // A drop-down list's window height includes the list it opens.
    ui::MoveControl(history_, margin, y, fieldWidth, metrics.FieldHeight() + metrics.Scale(200));
    y += metrics.FieldHeight() + gap;
    ui::MoveControl(pin_, margin, y, width, metrics.LineHeight() + metrics.Scale(4));
    y += metrics.LineHeight() + metrics.Scale(4) + gap;
    placeText(shortcutLabel_, labelGap);
    placeField(shortcut_, metrics.FieldHeight(), gap);
    SIZE previewSize = metrics.ButtonSize(ui::WindowText(preview_));
    ui::MoveControl(preview_, margin, y, previewSize.cx, previewSize.cy);
    y += previewSize.cy + gap;
    placeText(resultLabel_, labelGap);

    // From the bottom: the buttons, the status lines and the copy button; the preview takes what is left.
    SIZE applySize = metrics.ButtonSize(ui::WindowText(apply_));
    SIZE closeSize = metrics.ButtonSize(ui::WindowText(close_));
    int bottom = client.bottom - margin;
    ui::MoveControl(apply_, margin + width - applySize.cx, bottom - applySize.cy, applySize.cx, applySize.cy);
    ui::MoveControl(close_, margin + width - applySize.cx - gap - closeSize.cx, bottom - closeSize.cy, closeSize.cx,
                    closeSize.cy);
    bottom -= applySize.cy + gap;
    for (HWND text : {status_, targetMessage_}) {
        int height = wrapped(text, width);
        ui::MoveControl(text, margin, bottom - height, width, height);
        if (height > 0) bottom -= height + labelGap;
    }
    SIZE copySize = metrics.ButtonSize(ui::WindowText(copy_));
    ui::MoveControl(copy_, margin, bottom - copySize.cy, copySize.cx, copySize.cy);
    bottom -= copySize.cy + gap;
    ui::MoveControl(result_, margin, y, width, std::max(metrics.Scale(kMinimumResultHeight), bottom - y));
}

void AITransformWindow::SetStatus(const std::wstring& text) {
    ui::AnnounceText(status_, text);
    Layout();
}

void AITransformWindow::SetTargetAvailable(bool available) {
    targetAvailable_ = available;
    EnableWindow(apply_, !closing_ && available && shownResult_.has_value());
    std::wstring message = available ? L"" : Text("ai.preview.target-changed");
    if (message != ui::WindowText(targetMessage_)) ui::AnnounceText(targetMessage_, message);
    Layout();
}

void AITransformWindow::Generate() {
    if (closing_ || loading_) return;
    PreviewInput input;
    input.prompt = ui::WindowText(instruction_);
    input.pinned = SendMessageW(pin_, BM_GETCHECK, 0, 0) == BST_CHECKED;
    input.shortcutText = ui::WindowText(shortcut_);
    input.includeContext = SendMessageW(includeContext_, BM_GETCHECK, 0, 0) == BST_CHECKED;
    int edits = edits_;
    conversion_->Send(PreviewRequest(options_.held, input), [this, edits](const std::optional<json::Value>& reply) {
        if (closing_ || edits != edits_) return;
        PreviewReply preview = ParsePreviewReply(reply);
        if (preview.stale) {
            // Core no longer holds this transformation, so nothing it returns can be applied.
            SetTargetAvailable(false);
            PreviewFinished(std::nullopt, false);
            return;
        }
        if (!preview.historyError.empty()) {
            for (const auto& [code, key] : kHistoryErrorKeys) {
                if (preview.historyError == code) SetStatus(Text(key));
            }
            return;
        }
        // Without a revision Core refused: an empty instruction, or one still generating.
        if (!preview.revision) return;
        PreviewStarted();
        if (!preview.request) {
            PreviewFinished(std::nullopt, false);  // Core ended this preview without sending anything
            return;
        }
        SendTransform(*preview.revision, *preview.request, edits);
    });
}

void AITransformWindow::SendTransform(int revision, const json::Value& arguments, int edits) {
    ai_->Send(TransformRequest(arguments), [this, revision, edits](const std::optional<json::Value>& reply) {
        if (closing_) return;
        TransformReply transformed = ParseTransformReply(reply);
        // Core decides whether this answer is still the current preview.
        conversion_->Send(ResultRequest(options_.held, revision, transformed.text),
                          [this, edits, missingApiKey = transformed.missingApiKey](const std::optional<json::Value>& resultReply) {
                              if (closing_ || edits != edits_) return;
                              ShowResult(ParseResultReply(resultReply), missingApiKey);
                          });
    });
}

void AITransformWindow::ShowResult(const ResultReply& result, bool missingApiKey) {
    if (result.stale) {
        SetTargetAvailable(false);
        PreviewFinished(std::nullopt, missingApiKey);
        return;
    }
    if (!result.accepted) return;
    // Core no longer trusts the target when the answer came after a focus change.
    if (targetAvailable_ && !result.targetAvailable) SetTargetAvailable(false);
    PreviewFinished(result.text, missingApiKey);
}

void AITransformWindow::PreviewStarted() {
    loading_ = true;
    shownResult_.reset();
    SetWindowTextW(result_, L"");
    EnableWindow(preview_, FALSE);
    EnableWindow(includeContext_, FALSE);
    EnableWindow(apply_, FALSE);
    EnableWindow(copy_, FALSE);
    SetStatus(Text("ai.scope.generating"));
}

void AITransformWindow::PreviewFinished(const std::optional<std::wstring>& text, bool missingApiKey) {
    loading_ = false;
    shownResult_.reset();
    if (text && !text->empty()) shownResult_ = *text;
    EnableWindow(preview_, TRUE);
    EnableWindow(includeContext_, TRUE);
    SetWindowTextW(result_, ui::ToEditLineBreaks(shownResult_.value_or(L"")).c_str());
    EnableWindow(copy_, shownResult_.has_value());
    SetTargetAvailable(targetAvailable_);
    if (shownResult_) {
        SetStatus(Text("ai.preview.ready"));
    } else {
        SetStatus(Text(missingApiKey ? "ai.error.missing-key" : "ai.preview.failed"));
    }
}

void AITransformWindow::Invalidate() {
    if (closing_) return;
    bool hadPreview = loading_ || shownResult_.has_value();
    ++edits_;
    loading_ = false;
    shownResult_.reset();
    SetWindowTextW(result_, L"");
    EnableWindow(apply_, FALSE);
    EnableWindow(copy_, FALSE);
    EnableWindow(preview_, TRUE);
    EnableWindow(includeContext_, TRUE);
    if (hadPreview) SetStatus(Text("ai.scope.changed"));
    // Sent even without a visible preview: Core may have started one whose answer has not arrived.
    conversion_->Send(TransformationRequest(options_.held, "ai-transform-invalidate"), [](const std::optional<json::Value>&) {});
}

void AITransformWindow::ChangeIncludeContext() {
    Invalidate();
    bool included = SendMessageW(includeContext_, BM_GETCHECK, 0, 0) == BST_CHECKED;
    // The choice is also the setting's new value, as on Linux.
    conversion_->Send(protocol::IncludeContextUpdateRequest(included), [this](const std::optional<json::Value>& reply) {
        if (closing_) return;
        if (!reply || !protocol::IsSettingsUpdateSaved(json::Serialize(*reply))) SetStatus(Text("ai.scope.include-error"));
    });
}

void AITransformWindow::ChooseHistory() {
    LRESULT selected = SendMessageW(history_, CB_GETCURSEL, 0, 0);
    if (selected <= 0 || static_cast<size_t>(selected) > options_.held.history.size()) return;
    const HistoryItem& item = options_.held.history[static_cast<size_t>(selected) - 1];
    // Changing the instruction invalidates the preview, as typing it would.
    SetWindowTextW(instruction_, item.prompt.c_str());
    SendMessageW(pin_, BM_SETCHECK, item.pinned ? BST_CHECKED : BST_UNCHECKED, 0);
    SetWindowTextW(shortcut_, item.shortcutText.c_str());
}

void AITransformWindow::Copy() {
    if (shownResult_) ui::CopyTextToClipboard(window(), ui::ToEditLineBreaks(*shownResult_));
}

void AITransformWindow::Apply() {
    if (closing_ || !shownResult_ || !targetAvailable_) return;
    conversion_->Send(TransformationRequest(options_.held, "ai-transform-confirm"), [this](const std::optional<json::Value>& reply) {
        if (closing_) return;
        if (!IsConfirmed(reply)) {
            SetTargetAvailable(false);
            return;
        }
        // The text service now waits for its document to get focus back, then
        // checks and takes the result from Core; this window must not close it.
        closing_ = true;
        DestroyWindow(window());
    });
}

void AITransformWindow::OnCancel() {
    if (closing_) return;
    CloseAfter(TransformationRequest(options_.held, "ai-transform-close"));
}

// Disables the window, tells Core, and closes once Core answered (or the host is gone).
void AITransformWindow::CloseAfter(std::string request) {
    closing_ = true;
    EnableWindow(window(), FALSE);
    conversion_->Send(std::move(request), [this](const std::optional<json::Value>&) { DestroyWindow(window()); });
}

bool AITransformWindow::HandleMessage(UINT message, WPARAM wParam, LPARAM, LRESULT* result) {
    *result = 0;
    switch (message) {
    case kRepliesReadyMessage:
        if (conversion_) conversion_->DeliverReplies();
        if (ai_) ai_->DeliverReplies();
        return true;
    case WM_COMMAND:
        // Enter in the instruction asks for a preview, as on Linux.
        if (LOWORD(wParam) == IDOK && GetFocus() == instruction_) {
            Generate();
            return true;
        }
        return LOWORD(wParam) != IDOK && LOWORD(wParam) != IDCANCEL && commands_.Dispatch(LOWORD(wParam), HIWORD(wParam));
    case WM_DESTROY:
        if (options_.quitWhenClosed) PostQuitMessage(0);
        return false;
    default:
        return false;
    }
}

}  // namespace azookey::ai_transform
