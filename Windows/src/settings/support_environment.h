// The Windows environment values Core's support report may include
// (SupportDiagnostics.WindowsEnvironment). Core keeps only recognized values.
#pragma once

#include <string>

#include "../shared/message_catalog_data.h"

namespace azookey::settings {

// The request for Core's report. `buildInfoPath` is the package's build-info.txt.
std::string SupportDiagnosticsRequest(bool treeEnabled, const std::wstring& buildInfoPath, messages::Language language);

}  // namespace azookey::settings
