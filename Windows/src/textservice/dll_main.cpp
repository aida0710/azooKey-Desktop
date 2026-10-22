// Entry points that COM, regsvr32 and TSF call on the text service DLL.
#include <windows.h>

#include "candidate_panel.h"
#include "class_factory.h"
#include "guids.h"
#include "module.h"
#include "notice_window.h"
#include "registration.h"

namespace {

azookey::tsf::ClassFactory classFactory;

}  // namespace

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        azookey::tsf::SetModuleInstance(instance);
        DisableThreadLibraryCalls(instance);
    } else if (reason == DLL_PROCESS_DETACH) {
        azookey::tsf::CandidatePanel::UnregisterWindowClass();
        azookey::tsf::NoticeWindow::UnregisterWindowClass();
    }
    return TRUE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, void** object) {
    if (!object) return E_INVALIDARG;
    *object = nullptr;
    if (clsid != azookey::tsf::kTextServiceClsid) return CLASS_E_CLASSNOTAVAILABLE;
    return classFactory.QueryInterface(riid, object);
}

STDAPI DllCanUnloadNow() { return azookey::tsf::CanUnloadModule() ? S_OK : S_FALSE; }

STDAPI DllRegisterServer() { return azookey::tsf::RegisterTextService(); }

STDAPI DllUnregisterServer() { return azookey::tsf::UnregisterTextService(); }
