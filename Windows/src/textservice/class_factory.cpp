#include "class_factory.h"

#include <new>

#include "module.h"
#include "text_service.h"

namespace azookey::tsf {

STDMETHODIMP ClassFactory::QueryInterface(REFIID riid, void** object) {
    if (!object) return E_INVALIDARG;
    if (riid == IID_IUnknown || riid == IID_IClassFactory) {
        *object = static_cast<IClassFactory*>(this);
        AddRef();
        return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
}

// The factory is a static object; its lifetime is the module's.
STDMETHODIMP_(ULONG) ClassFactory::AddRef() {
    AddModuleReference();
    return 2;
}

STDMETHODIMP_(ULONG) ClassFactory::Release() {
    ReleaseModuleReference();
    return 1;
}

STDMETHODIMP ClassFactory::CreateInstance(IUnknown* outer, REFIID riid, void** object) {
    if (!object) return E_INVALIDARG;
    *object = nullptr;
    if (outer) return CLASS_E_NOAGGREGATION;
    auto* service = new (std::nothrow) TextService();
    if (!service) return E_OUTOFMEMORY;
    HRESULT result = service->QueryInterface(riid, object);
    service->Release();
    return result;
}

STDMETHODIMP ClassFactory::LockServer(BOOL lock) {
    if (lock) AddModuleReference();
    else ReleaseModuleReference();
    return S_OK;
}

}  // namespace azookey::tsf
