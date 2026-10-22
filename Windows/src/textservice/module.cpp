#include "module.h"

namespace azookey::tsf {
namespace {

HINSTANCE moduleInstance = nullptr;
LONG moduleReferences = 0;

}  // namespace

HINSTANCE ModuleInstance() { return moduleInstance; }
void SetModuleInstance(HINSTANCE instance) { moduleInstance = instance; }

void AddModuleReference() { InterlockedIncrement(&moduleReferences); }
void ReleaseModuleReference() { InterlockedDecrement(&moduleReferences); }
bool CanUnloadModule() { return moduleReferences == 0; }

std::wstring ModulePath() {
    wchar_t path[MAX_PATH];
    DWORD length = GetModuleFileNameW(moduleInstance, path, MAX_PATH);
    return std::wstring(path, length);
}

std::wstring ModuleDirectory() {
    std::wstring path = ModulePath();
    return path.substr(0, path.find_last_of(L'\\'));
}

}  // namespace azookey::tsf
