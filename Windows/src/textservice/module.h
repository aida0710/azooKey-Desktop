// Process-wide state of the text service DLL: its module handle and the count
// of live COM objects and server locks that keeps it loaded.
#pragma once

#include <windows.h>

#include <string>

namespace azookey::tsf {

HINSTANCE ModuleInstance();
void SetModuleInstance(HINSTANCE instance);

void AddModuleReference();
void ReleaseModuleReference();
bool CanUnloadModule();

std::wstring ModulePath();
std::wstring ModuleDirectory();

}  // namespace azookey::tsf
