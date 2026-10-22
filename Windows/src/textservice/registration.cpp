#include "registration.h"

#include <msctf.h>
#include <shlwapi.h>

#include <string>

#include "guids.h"
#include "module.h"

namespace azookey::tsf {
namespace {

// Categories tell TSF what the IME supports. Without IMMERSIVESUPPORT Store
// applications do not offer it; without INPUTMODECOMPARTMENT the taskbar
// cannot show あ/A. SECUREMODE is deliberately absent: on the sign-in screen
// the IME would run as SYSTEM without the user's converter.
const GUID* const kCategories[] = {
    &GUID_TFCAT_TIP_KEYBOARD,
    &GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER,
    &GUID_TFCAT_TIPCAP_UIELEMENTENABLED,
    &GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT,
    &GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT,
    &GUID_TFCAT_TIPCAP_INPUTMODECOMPARTMENT,
    &GUID_TFCAT_TIPCAP_COMLESS,
};

std::wstring ClsidKeyPath() {
    wchar_t clsid[64];
    StringFromGUID2(kTextServiceClsid, clsid, ARRAYSIZE(clsid));
    return std::wstring(L"CLSID\\") + clsid;
}

LSTATUS SetStringValue(HKEY key, const wchar_t* name, const std::wstring& value) {
    return RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()),
                          static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
}

HRESULT RegisterComServer() {
    HKEY clsidKey = nullptr;
    if (RegCreateKeyExW(HKEY_CLASSES_ROOT, ClsidKeyPath().c_str(), 0, nullptr, 0, KEY_WRITE, nullptr, &clsidKey,
                        nullptr) != ERROR_SUCCESS) {
        return E_ACCESSDENIED;
    }
    SetStringValue(clsidKey, nullptr, kDisplayName);
    HKEY serverKey = nullptr;
    LSTATUS status = RegCreateKeyExW(clsidKey, L"InprocServer32", 0, nullptr, 0, KEY_WRITE, nullptr, &serverKey, nullptr);
    if (status == ERROR_SUCCESS) {
        SetStringValue(serverKey, nullptr, ModulePath());
        SetStringValue(serverKey, L"ThreadingModel", L"Apartment");
        RegCloseKey(serverKey);
    }
    RegCloseKey(clsidKey);
    return status == ERROR_SUCCESS ? S_OK : E_ACCESSDENIED;
}

HRESULT RegisterProfile() {
    ITfInputProcessorProfileMgr* profiles = nullptr;
    HRESULT result = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                                      IID_ITfInputProcessorProfileMgr, reinterpret_cast<void**>(&profiles));
    if (FAILED(result)) return result;
    std::wstring iconFile = ModulePath();
    result = profiles->RegisterProfile(kTextServiceClsid, kJapaneseLanguage, kProfileGuid, kDisplayName,
                                       static_cast<ULONG>(wcslen(kDisplayName)), iconFile.c_str(),
                                       static_cast<ULONG>(iconFile.size()), 0, nullptr, 0, TRUE, 0);
    profiles->Release();
    return result;
}

HRESULT RegisterCategories() {
    ITfCategoryMgr* categories = nullptr;
    HRESULT result = CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_ITfCategoryMgr,
                                      reinterpret_cast<void**>(&categories));
    if (FAILED(result)) return result;
    for (const GUID* category : kCategories) {
        result = categories->RegisterCategory(kTextServiceClsid, *category, kTextServiceClsid);
        if (FAILED(result)) break;
    }
    categories->Release();
    return result;
}

}  // namespace

HRESULT RegisterTextService() {
    HRESULT result = RegisterComServer();
    if (SUCCEEDED(result)) result = RegisterProfile();
    if (SUCCEEDED(result)) result = RegisterCategories();
    if (FAILED(result)) UnregisterTextService();
    return result;
}

HRESULT UnregisterTextService() {
    ITfCategoryMgr* categories = nullptr;
    if (SUCCEEDED(CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_ITfCategoryMgr,
                                   reinterpret_cast<void**>(&categories)))) {
        for (const GUID* category : kCategories) categories->UnregisterCategory(kTextServiceClsid, *category, kTextServiceClsid);
        categories->Release();
    }
    ITfInputProcessorProfileMgr* profiles = nullptr;
    if (SUCCEEDED(CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                                   IID_ITfInputProcessorProfileMgr, reinterpret_cast<void**>(&profiles)))) {
        profiles->UnregisterProfile(kTextServiceClsid, kJapaneseLanguage, kProfileGuid, 0);
        profiles->Release();
    }
    SHDeleteKeyW(HKEY_CLASSES_ROOT, ClsidKeyPath().c_str());
    return S_OK;
}

}  // namespace azookey::tsf
