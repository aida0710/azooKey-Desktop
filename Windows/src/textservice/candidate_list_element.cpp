#include "candidate_list_element.h"

#include "guids.h"
#include "module.h"

namespace azookey::tsf {
namespace {

// Pages follow Core's number keys: nine candidates each.
constexpr UINT kPageSize = 9;

}  // namespace

CandidateListElement::CandidateListElement(ITfThreadMgr* threadManager, Actions actions)
    : threadManager_(threadManager), actions_(std::move(actions)) {
    threadManager_->AddRef();
    AddModuleReference();
}

CandidateListElement::~CandidateListElement() {
    threadManager_->Release();
    ReleaseModuleReference();
}

ITfUIElementMgr* CandidateListElement::ElementManager() const {
    ITfUIElementMgr* manager = nullptr;
    threadManager_->QueryInterface(IID_ITfUIElementMgr, reinterpret_cast<void**>(&manager));
    return manager;
}

bool CandidateListElement::Update(const protocol::Snapshot& snapshot) {
    std::vector<std::wstring> candidates;
    for (const auto& candidate : snapshot.candidates) candidates.push_back(candidate.text);
    UINT selection = snapshot.selection ? static_cast<UINT>(*snapshot.selection) : 0;
    updatedFlags_ = 0;
    if (candidates != candidates_) updatedFlags_ |= TF_CLUIE_COUNT | TF_CLUIE_STRING | TF_CLUIE_PAGEINDEX;
    if (selection != selection_) updatedFlags_ |= TF_CLUIE_SELECTION | TF_CLUIE_CURRENTPAGE;
    candidates_ = std::move(candidates);
    selection_ = selection;
    ITfUIElementMgr* manager = ElementManager();
    if (!manager) return true;
    if (!started_) {
        BOOL show = TRUE;
        if (SUCCEEDED(manager->BeginUIElement(this, &show, &elementId_))) {
            started_ = true;
            shown_ = show != FALSE;
        }
    } else if (updatedFlags_ != 0) {
        manager->UpdateUIElement(elementId_);
    }
    manager->Release();
    return shown_;
}

void CandidateListElement::End() {
    if (!started_) return;
    if (ITfUIElementMgr* manager = ElementManager()) {
        manager->EndUIElement(elementId_);
        manager->Release();
    }
    started_ = false;
    shown_ = true;
    elementId_ = TF_INVALID_UIELEMENTID;
    candidates_.clear();
}

STDMETHODIMP CandidateListElement::QueryInterface(REFIID riid, void** object) {
    if (!object) return E_INVALIDARG;
    *object = nullptr;
    if (riid == IID_IUnknown || riid == IID_ITfUIElement || riid == IID_ITfCandidateListUIElement ||
        riid == IID_ITfCandidateListUIElementBehavior) {
        *object = static_cast<ITfCandidateListUIElementBehavior*>(this);
        AddRef();
        return S_OK;
    }
    return E_NOINTERFACE;
}

STDMETHODIMP_(ULONG) CandidateListElement::AddRef() { return InterlockedIncrement(&references_); }

STDMETHODIMP_(ULONG) CandidateListElement::Release() {
    LONG remaining = InterlockedDecrement(&references_);
    if (remaining == 0) delete this;
    return remaining;
}

STDMETHODIMP CandidateListElement::GetDescription(BSTR* description) {
    if (!description) return E_INVALIDARG;
    *description = SysAllocString(L"azooKey Tree の変換候補");
    return *description ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP CandidateListElement::GetGUID(GUID* guid) {
    if (!guid) return E_INVALIDARG;
    *guid = kCandidateListElementGuid;
    return S_OK;
}

STDMETHODIMP CandidateListElement::Show(BOOL show) {
    shown_ = show != FALSE;
    if (actions_.showPanel) actions_.showPanel(shown_);
    return S_OK;
}

STDMETHODIMP CandidateListElement::IsShown(BOOL* shown) {
    if (!shown) return E_INVALIDARG;
    *shown = shown_ ? TRUE : FALSE;
    return S_OK;
}

STDMETHODIMP CandidateListElement::GetUpdatedFlags(DWORD* flags) {
    if (!flags) return E_INVALIDARG;
    *flags = updatedFlags_;
    return S_OK;
}

STDMETHODIMP CandidateListElement::GetDocumentMgr(ITfDocumentMgr** documentManager) {
    if (!documentManager) return E_INVALIDARG;
    return threadManager_->GetFocus(documentManager);
}

STDMETHODIMP CandidateListElement::GetCount(UINT* count) {
    if (!count) return E_INVALIDARG;
    *count = static_cast<UINT>(candidates_.size());
    return S_OK;
}

STDMETHODIMP CandidateListElement::GetSelection(UINT* index) {
    if (!index) return E_INVALIDARG;
    *index = selection_;
    return S_OK;
}

STDMETHODIMP CandidateListElement::GetString(UINT index, BSTR* text) {
    if (!text) return E_INVALIDARG;
    if (index >= candidates_.size()) return E_INVALIDARG;
    *text = SysAllocString(candidates_[index].c_str());
    return *text ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP CandidateListElement::GetPageIndex(UINT* pages, UINT size, UINT* pageCount) {
    if (!pageCount) return E_INVALIDARG;
    UINT count = static_cast<UINT>((candidates_.size() + kPageSize - 1) / kPageSize);
    *pageCount = count;
    if (pages) {
        for (UINT page = 0; page < count && page < size; ++page) pages[page] = page * kPageSize;
    }
    return S_OK;
}

// Pages are fixed by the number keys; applications cannot re-paginate them.
STDMETHODIMP CandidateListElement::SetPageIndex(UINT*, UINT) { return E_NOTIMPL; }

STDMETHODIMP CandidateListElement::GetCurrentPage(UINT* page) {
    if (!page) return E_INVALIDARG;
    *page = selection_ / kPageSize;
    return S_OK;
}

STDMETHODIMP CandidateListElement::SetSelection(UINT index) {
    if (index >= candidates_.size()) return E_INVALIDARG;
    if (actions_.selectCandidate) actions_.selectCandidate(static_cast<int>(index));
    return S_OK;
}

STDMETHODIMP CandidateListElement::Finalize() {
    if (actions_.confirmSelection) actions_.confirmSelection();
    return S_OK;
}

STDMETHODIMP CandidateListElement::Abort() {
    if (actions_.cancel) actions_.cancel();
    return S_OK;
}

}  // namespace azookey::tsf
