#include "support_environment.h"

#include <windows.h>

#include <fstream>
#include <sstream>

#include "../shared/json.h"

namespace azookey::settings {
namespace {

using json::Value;

// GetVersionEx reports the version the program's manifest declares; the
// kernel's own query reports the version that is running.
std::string WindowsVersion() {
    using RtlGetVersionFunction = LONG(WINAPI*)(OSVERSIONINFOW*);
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    auto getVersion = ntdll ? reinterpret_cast<RtlGetVersionFunction>(GetProcAddress(ntdll, "RtlGetVersion")) : nullptr;
    OSVERSIONINFOW version{sizeof(version)};
    if (!getVersion || getVersion(&version) != 0) return {};
    return std::to_string(version.dwMajorVersion) + "." + std::to_string(version.dwMinorVersion) + "." +
           std::to_string(version.dwBuildNumber);
}

std::string Machine() {
    SYSTEM_INFO system{};
    GetNativeSystemInfo(&system);
    switch (system.wProcessorArchitecture) {
    case PROCESSOR_ARCHITECTURE_AMD64: return "x64";
    case PROCESSOR_ARCHITECTURE_ARM64: return "arm64";
    case PROCESSOR_ARCHITECTURE_INTEL: return "x86";
    default: return {};
    }
}

// A missing file is an unpackaged build; Core then reports the version as unknown.
std::string ReadFile(const std::wstring& path) {
    std::ifstream stream(path, std::ios::binary);
    std::ostringstream contents;
    contents << stream.rdbuf();
    return contents.str();
}

Value OptionalString(const std::string& text) { return text.empty() ? Value() : Value::MakeString(text); }

}  // namespace

std::string SupportDiagnosticsRequest(bool treeEnabled, const std::wstring& buildInfoPath, messages::Language language) {
    Value environment = Value::MakeObject({
        {"treeEnabled", Value::MakeBoolean(treeEnabled)},
        {"osVersion", OptionalString(WindowsVersion())},
        {"machine", OptionalString(Machine())},
        {"buildInfo", OptionalString(ReadFile(buildInfoPath))},
    });
    return json::Serialize(Value::MakeObject({
        {"operation", Value::MakeString("support-diagnostics")},
        {"supportEnvironment", environment},
        {"language", Value::MakeString(language == messages::Language::Japanese ? "ja" : "en")},
    }));
}

}  // namespace azookey::settings
