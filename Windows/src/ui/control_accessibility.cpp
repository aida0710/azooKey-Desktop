#include "control_accessibility.h"

#include <initguid.h>
#include <oleacc.h>
#include <uiautomation.h>

namespace azookey::ui {
namespace {

// IAccPropServices annotates standard controls without subclassing them.
IAccPropServices* PropertyServices() {
    static IAccPropServices* services = [] {
        IAccPropServices* created = nullptr;
        CoCreateInstance(CLSID_AccPropServices, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&created));
        return created;
    }();
    return services;
}

void SetString(HWND control, const MSAAPROPID& property, const std::wstring& value) {
    if (IAccPropServices* services = PropertyServices()) {
        services->SetHwndPropStr(control, static_cast<DWORD>(OBJID_CLIENT), CHILDID_SELF, property, value.c_str());
    }
}

}  // namespace

void SetAccessibleName(HWND control, const std::wstring& name) { SetString(control, PROPID_ACC_NAME, name); }

void SetAccessibleDescription(HWND control, const std::wstring& description) {
    SetString(control, PROPID_ACC_DESCRIPTION, description);
}

void MakeLiveRegion(HWND control) {
    if (IAccPropServices* services = PropertyServices()) {
        VARIANT polite{};
        polite.vt = VT_I4;
        polite.lVal = Polite;
        services->SetHwndProp(control, static_cast<DWORD>(OBJID_CLIENT), CHILDID_SELF, LiveSetting_Property_GUID, polite);
    }
}

void AnnounceText(HWND liveRegion, const std::wstring& text) {
    SetWindowTextW(liveRegion, text.c_str());
    NotifyWinEvent(EVENT_OBJECT_LIVEREGIONCHANGED, liveRegion, OBJID_CLIENT, CHILDID_SELF);
}

}  // namespace azookey::ui
