// The azooKey Tree text input processor. TSF creates one per UI thread of an
// application; it turns key presses into converter requests and writes the
// results into the focused document.
#pragma once

#include <msctf.h>

#include <memory>
#include <optional>

#include "candidate_list_element.h"
#include "candidate_panel.h"
#include "composition_writer.h"
#include "converter_client.h"
#include "shared/bridge_protocol.h"
#include "shared/key_translation.h"

namespace azookey::tsf {

class TextService final : public ITfTextInputProcessorEx,
                          public ITfThreadMgrEventSink,
                          public ITfKeyEventSink,
                          public ITfCompositionSink,
                          public ITfDisplayAttributeProvider,
                          public ITfCompartmentEventSink {
public:
    TextService();

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** object) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    // ITfTextInputProcessor / ITfTextInputProcessorEx
    STDMETHODIMP Activate(ITfThreadMgr* threadManager, TfClientId clientId) override;
    STDMETHODIMP ActivateEx(ITfThreadMgr* threadManager, TfClientId clientId, DWORD flags) override;
    STDMETHODIMP Deactivate() override;

    // ITfThreadMgrEventSink
    STDMETHODIMP OnInitDocumentMgr(ITfDocumentMgr*) override { return S_OK; }
    STDMETHODIMP OnUninitDocumentMgr(ITfDocumentMgr*) override { return S_OK; }
    STDMETHODIMP OnSetFocus(ITfDocumentMgr* focus, ITfDocumentMgr* previous) override;
    STDMETHODIMP OnPushContext(ITfContext*) override { return S_OK; }
    STDMETHODIMP OnPopContext(ITfContext*) override { return S_OK; }

    // ITfKeyEventSink
    STDMETHODIMP OnSetFocus(BOOL) override { return S_OK; }
    STDMETHODIMP OnTestKeyDown(ITfContext* context, WPARAM wParam, LPARAM lParam, BOOL* eaten) override;
    STDMETHODIMP OnTestKeyUp(ITfContext*, WPARAM, LPARAM, BOOL* eaten) override;
    STDMETHODIMP OnKeyDown(ITfContext* context, WPARAM wParam, LPARAM lParam, BOOL* eaten) override;
    STDMETHODIMP OnKeyUp(ITfContext*, WPARAM, LPARAM, BOOL* eaten) override;
    STDMETHODIMP OnPreservedKey(ITfContext*, REFGUID, BOOL* eaten) override;

    // ITfCompositionSink
    STDMETHODIMP OnCompositionTerminated(TfEditCookie cookie, ITfComposition* composition) override;

    // ITfDisplayAttributeProvider
    STDMETHODIMP EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo** enumerator) override;
    STDMETHODIMP GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo** info) override;

    // ITfCompartmentEventSink
    STDMETHODIMP OnChange(REFGUID compartment) override;

private:
    struct KeyInput {
        keys::KeyAction action = keys::KeyAction::PassThrough;
        keys::Modifiers modifiers;
        std::wstring typedText;
    };

    ~TextService();

    KeyInput ReadKey(ITfContext* context, WPARAM virtualKey, LPARAM lParam);
    bool IsComposing() const;
    bool IsFieldPrivate(ITfContext* context);
    InputField ReadInputField(ITfContext* context);

    void HandleKey(ITfContext* context, WPARAM virtualKey, const KeyInput& input, BOOL* eaten);
    void ApplySnapshot(ITfContext* context, const protocol::Snapshot& snapshot, DWORD sessionFlags);
    void InsertText(ITfContext* context, const std::wstring& text, DWORD sessionFlags);
    // Ends the current composition, leaving `confirm ? converter's commit : visible preedit`.
    void FinishComposition(bool confirm, DWORD sessionFlags);
    void ShowPage(ITfContext* context, int delta);
    // Pointer actions from the candidate panel; they are not key events, so
    // their edits may reach the document later.
    void ApplyPointerChoice(std::optional<protocol::Snapshot> snapshot);
    void ShowCandidates(const protocol::Snapshot& snapshot, const std::optional<CompositionGeometry>& geometry);
    bool TreeCandidatesEnabled();
    void HideCandidates();
    void CreateCandidateElement();
    ITfContext* CompositionContext() const;  // AddRef'd, or nullptr

    bool IsInputOpen();
    void SetInputOpen(bool open);
    DWORD AdviseCompartment(const GUID& compartment);
    void UnadviseCompartment(const GUID& compartment, DWORD cookie);
    void RegisterClauseAttributes();

    LONG references_ = 1;
    ITfThreadMgr* threadManager_ = nullptr;
    TfClientId clientId_ = TF_CLIENTID_NULL;
    DWORD threadManagerSinkCookie_ = TF_INVALID_COOKIE;
    DWORD openCloseSinkCookie_ = TF_INVALID_COOKIE;
    DWORD conversionSinkCookie_ = TF_INVALID_COOKIE;
    bool keyEventSinkAdvised_ = false;
    bool updatingCompartments_ = false;

    ITfComposition* composition_ = nullptr;
    ClauseAttributeAtoms clauseAtoms_;
    std::unique_ptr<ConverterClient> converter_;
    std::unique_ptr<CandidatePanel> candidatePanel_;
    CandidateListElement* candidateElement_ = nullptr;  // COM object; the application may hold it too
    std::string lastPlacementSide_;  // Core keeps the popup on this side while it still fits
    std::optional<protocol::PresentationSettings> presentationSettings_;  // read again after a focus change
    protocol::Snapshot snapshot_;  // last state written to the document

    // Password fields are detected once per focused context.
    ITfContext* privacyCheckedContext_ = nullptr;
    bool privateField_ = false;
};

}  // namespace azookey::tsf
