// The instruction window for transforming selected text with AI (Linux:
// prompt_dialog.py and ai_scope_view.py). It shows what Core will send and
// where, takes the instruction (typed, or from the history with its pin and
// shortcut), previews the AI's result, and copies or applies it. Core decides
// which preview is current and whether the result may replace the selection;
// the text service writes it into the document after this window closes.
#pragma once

#include <windows.h>

#include <memory>
#include <optional>
#include <string>

#include "../shared/message_catalog_data.h"
#include "../ui/bridge_worker.h"
#include "../ui/command_map.h"
#include "../ui/top_level_window.h"
#include "ai_transform_protocol.h"

namespace azookey::ai_transform {

class AITransformWindow final : public ui::TopLevelWindow {
public:
    static constexpr wchar_t kClassName[] = L"azooKeyTreeAITransform";

    struct Options {
        messages::Language language = messages::Language::English;
        HeldTransformation held;
        // Core's ai-transform-* operations, through the host's converter.
        channel::HostConnection::Options conversion;
        // The "transform" request, through the host's AI converter (much slower).
        channel::HostConnection::Options ai;
        bool quitWhenClosed = true;
    };

    explicit AITransformWindow(Options options);
    ~AITransformWindow() override;

    void Present();
    bool busy() const { return conversion_->busy() || ai_->busy(); }
    bool closed() const { return window() == nullptr; }

    HWND instructionEdit() const { return instruction_; }
    HWND historyList() const { return history_; }
    HWND pinCheckBox() const { return pin_; }
    HWND shortcutEdit() const { return shortcut_; }
    HWND includeContextCheckBox() const { return includeContext_; }
    HWND previewButton() const { return preview_; }
    HWND resultEdit() const { return result_; }
    HWND copyButton() const { return copy_; }
    HWND applyButton() const { return apply_; }
    HWND closeButton() const { return close_; }
    HWND statusText() const { return status_; }
    HWND targetText() const { return target_; }

protected:
    void Layout() override;
    void OnCancel() override;
    bool HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT* result) override;

private:
    void Build();
    HWND AddStatic(const std::wstring& text);
    HWND AddLabel(std::string_view key, const std::string& accessKey);
    HWND AddButton(std::string_view key, int id);
    std::wstring Text(std::string_view key) const;

    void Generate();
    void SendTransform(int revision, const json::Value& arguments, int edits);
    void ShowResult(const ResultReply& result, bool missingApiKey);
    void PreviewStarted();
    void PreviewFinished(const std::optional<std::wstring>& text, bool missingApiKey);
    void Invalidate();
    void ChangeIncludeContext();
    void ChooseHistory();
    void Apply();
    void Copy();
    void SetTargetAvailable(bool available);
    void SetStatus(const std::wstring& text);
    void CloseAfter(std::string request);

    Options options_;
    ui::CommandMap commands_;
    std::unique_ptr<ui::BridgeWorker> conversion_;
    std::unique_ptr<ui::BridgeWorker> ai_;
    bool targetAvailable_ = false;
    bool loading_ = false;
    bool closing_ = false;
    // Counts instruction edits, so the answer to an older instruction is not shown.
    int edits_ = 0;
    // The preview shown now: copyable, and applicable while the target is.
    std::optional<std::wstring> shownResult_;

    HWND destination_ = nullptr;
    HWND targetLabel_ = nullptr;
    HWND target_ = nullptr;
    HWND includeContext_ = nullptr;
    HWND historyNote_ = nullptr;
    HWND instructionLabel_ = nullptr;
    HWND instruction_ = nullptr;
    HWND historyLabel_ = nullptr;
    HWND history_ = nullptr;
    HWND pin_ = nullptr;
    HWND shortcutLabel_ = nullptr;
    HWND shortcut_ = nullptr;
    HWND preview_ = nullptr;
    HWND resultLabel_ = nullptr;
    HWND result_ = nullptr;
    HWND copy_ = nullptr;
    HWND targetMessage_ = nullptr;
    HWND status_ = nullptr;
    HWND close_ = nullptr;
    HWND apply_ = nullptr;
};

}  // namespace azookey::ai_transform
