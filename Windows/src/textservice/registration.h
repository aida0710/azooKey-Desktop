// COM and TSF registration performed by regsvr32 (DllRegisterServer).
#pragma once

#include <windows.h>

namespace azookey::tsf {

HRESULT RegisterTextService();
HRESULT UnregisterTextService();

}  // namespace azookey::tsf
