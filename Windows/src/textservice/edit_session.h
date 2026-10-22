// TSF only lets a text service touch the document inside an edit session; this
// wraps a callable so each change is written where it is used.
#pragma once

#include <msctf.h>

#include <functional>
#include <new>

namespace azookey::tsf {

class EditSession final : public ITfEditSession {
public:
    explicit EditSession(std::function<void(TfEditCookie)> body) : body_(std::move(body)) {}

    STDMETHODIMP QueryInterface(REFIID riid, void** object) override {
        if (!object) return E_INVALIDARG;
        if (riid == IID_IUnknown || riid == IID_ITfEditSession) {
            *object = static_cast<ITfEditSession*>(this);
            AddRef();
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&references_); }
    STDMETHODIMP_(ULONG) Release() override {
        LONG remaining = InterlockedDecrement(&references_);
        if (remaining == 0) delete this;
        return remaining;
    }
    STDMETHODIMP DoEditSession(TfEditCookie cookie) override {
        body_(cookie);
        return S_OK;
    }

private:
    ~EditSession() = default;
    LONG references_ = 1;
    std::function<void(TfEditCookie)> body_;
};

// Runs `body` in a session on `context`. Inside key handling TSF allows a
// synchronous session; elsewhere (mouse clicks, focus changes) it may run later.
inline HRESULT RunEditSession(ITfContext* context, TfClientId client, DWORD flags,
                              std::function<void(TfEditCookie)> body) {
    auto* session = new (std::nothrow) EditSession(std::move(body));
    if (!session) return E_OUTOFMEMORY;
    HRESULT sessionResult = E_FAIL;
    HRESULT result = context->RequestEditSession(client, session, flags, &sessionResult);
    session->Release();
    return FAILED(result) ? result : sessionResult;
}

}  // namespace azookey::tsf
