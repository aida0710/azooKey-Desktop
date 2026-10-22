// Registers the window classes of the settings app once per process.
#pragma once

#include <windows.h>

namespace azookey::settings {

// `icon` may be null (the screen tests have no icon resource).
void RegisterWindowClasses(HINSTANCE instance, HICON icon);

}  // namespace azookey::settings
