// The candidate list exposed as a TSF UI element. Applications that draw
// candidates themselves (full-screen games) answer BeginUIElement with
// "do not show"; they then read the list through this object and drive it,
// and the IME keeps its own panel hidden.
#pragma once

#include <msctf.h>

#include <functional>
#include <vector>

#include "shared/bridge_protocol.h"

namespace azookey::tsf {

class CandidateListElement final : public ITfCandidateListUIElementBehavior {
public:
    struct Actions {
        std::function<void(bool shown)> showPanel;  // the application decides whether our panel appears
        std::function<void(int candidateIndex)> selectCandidate;
        std::function<void()> confirmSelection;
        std::function<void()> cancel;
    };

    CandidateListElement(ITfThreadMgr* threadManager, Actions actions);

    // Starts, updates or ends the element for the current candidate list.
    // Returns whether the application lets the IME draw its own panel.
    bool Update(const protocol::Snapshot& snapshot);
    void End();

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** object) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    // ITfUIElement
    STDMETHODIMP GetDescription(BSTR* description) override;
    STDMETHODIMP GetGUID(GUID* guid) override;
    STDMETHODIMP Show(BOOL show) override;
    STDMETHODIMP IsShown(BOOL* shown) override;

    // ITfCandidateListUIElement
    STDMETHODIMP GetUpdatedFlags(DWORD* flags) override;
    STDMETHODIMP GetDocumentMgr(ITfDocumentMgr** documentManager) override;
    STDMETHODIMP GetCount(UINT* count) override;
    STDMETHODIMP GetSelection(UINT* index) override;
    STDMETHODIMP GetString(UINT index, BSTR* text) override;
    STDMETHODIMP GetPageIndex(UINT* pages, UINT size, UINT* pageCount) override;
    STDMETHODIMP SetPageIndex(UINT* pages, UINT pageCount) override;
    STDMETHODIMP GetCurrentPage(UINT* page) override;

    // ITfCandidateListUIElementBehavior
    STDMETHODIMP SetSelection(UINT index) override;
    STDMETHODIMP Finalize() override;
    STDMETHODIMP Abort() override;

private:
    ~CandidateListElement();
    ITfUIElementMgr* ElementManager() const;

    LONG references_ = 1;
    ITfThreadMgr* threadManager_;
    Actions actions_;
    DWORD elementId_ = TF_INVALID_UIELEMENTID;
    bool started_ = false;
    bool shown_ = true;
    DWORD updatedFlags_ = 0;
    std::vector<std::wstring> candidates_;
    UINT selection_ = 0;
};

}  // namespace azookey::tsf
