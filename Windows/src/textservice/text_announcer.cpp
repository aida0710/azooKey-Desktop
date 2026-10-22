#include "text_announcer.h"

// WIN32_LEAN_AND_MEAN leaves out the COM declarations UI Automation needs.
#include <ole2.h>
#include <uiautomation.h>

#include "module.h"

namespace azookey::tsf {
namespace {

VARIANT StringVariant(const std::wstring& text) {
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_BSTR;
    value.bstrVal = SysAllocString(text.c_str());
    return value;
}

VARIANT IntegerVariant(LONG number) {
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_I4;
    value.lVal = number;
    return value;
}

}  // namespace

class TextAnnouncer::Provider final : public IRawElementProviderSimple {
public:
    explicit Provider(HWND window) : window_(window) { AddModuleReference(); }

    void SetText(const std::wstring& text) { text_ = text; }
    void Detach() { window_ = nullptr; }

    STDMETHODIMP QueryInterface(REFIID riid, void** object) override {
        if (!object) return E_INVALIDARG;
        *object = nullptr;
        if (riid != IID_IUnknown && riid != IID_IRawElementProviderSimple) return E_NOINTERFACE;
        *object = static_cast<IRawElementProviderSimple*>(this);
        AddRef();
        return S_OK;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&references_); }
    STDMETHODIMP_(ULONG) Release() override {
        LONG remaining = InterlockedDecrement(&references_);
        if (remaining == 0) delete this;
        return remaining;
    }

    STDMETHODIMP get_ProviderOptions(ProviderOptions* options) override {
        *options = ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading;
        return S_OK;
    }
    STDMETHODIMP GetPatternProvider(PATTERNID, IUnknown** provider) override {
        *provider = nullptr;
        return S_OK;
    }
    STDMETHODIMP GetPropertyValue(PROPERTYID property, VARIANT* value) override {
        VariantInit(value);
        if (!window_) return UIA_E_ELEMENTNOTAVAILABLE;
        if (property == UIA_ControlTypePropertyId) *value = IntegerVariant(UIA_TextControlTypeId);
        else if (property == UIA_NamePropertyId) *value = StringVariant(text_);
        else if (property == UIA_LiveSettingPropertyId) *value = IntegerVariant(Assertive);
        return S_OK;
    }
    STDMETHODIMP get_HostRawElementProvider(IRawElementProviderSimple** provider) override {
        if (!window_) return UIA_E_ELEMENTNOTAVAILABLE;
        return UiaHostProviderFromHwnd(window_, provider);
    }

private:
    ~Provider() { ReleaseModuleReference(); }
    LONG references_ = 1;
    HWND window_;
    std::wstring text_;
};

TextAnnouncer::TextAnnouncer(HWND window, std::wstring activity)
    : window_(window), activity_(std::move(activity)), provider_(new Provider(window)) {}

TextAnnouncer::~TextAnnouncer() {
    UiaDisconnectProvider(provider_);
    provider_->Detach();
    provider_->Release();
}

void TextAnnouncer::Announce(const std::wstring& text) {
    provider_->SetText(text);
    if (text == spoken_) return;
    spoken_ = text;
    if (text.empty() || !UiaClientsAreListening()) return;
    BSTR message = SysAllocString(text.c_str());
    BSTR activity = SysAllocString(activity_.c_str());
    UiaRaiseNotificationEvent(provider_, NotificationKind_Other, NotificationProcessing_ImportantMostRecent, message, activity);
    SysFreeString(activity);
    SysFreeString(message);
}

LRESULT TextAnnouncer::HandleGetObject(WPARAM wParam, LPARAM lParam) {
    if (static_cast<long>(lParam) != static_cast<long>(UiaRootObjectId)) return 0;
    return UiaReturnRawElementProvider(window_, wParam, lParam, provider_);
}

}  // namespace azookey::tsf
