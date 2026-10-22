#include "settings_reload.h"

#include "../shared/json.h"
#include "../shared/text_encoding.h"

namespace azookey::host {
namespace {

constexpr char kLoadRequest[] = "{\"operation\":\"settings-load\"}";
constexpr char kReloadRequest[] = "{\"operation\":\"settings-reload\"}";

}  // namespace

bool SettingsReload::FileVersion::operator==(const FileVersion& other) const {
    return exists == other.exists && size == other.size && CompareFileTime(&lastWrite, &other.lastWrite) == 0;
}

SettingsReload::FileVersion SettingsReload::ReadVersion(const std::wstring& path) {
    FileVersion version;
    WIN32_FILE_ATTRIBUTE_DATA attributes{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attributes)) return version;
    version.exists = true;
    version.size = (static_cast<ULONGLONG>(attributes.nFileSizeHigh) << 32) | attributes.nFileSizeLow;
    version.lastWrite = attributes.ftLastWriteTime;
    return version;
}

// The settings file's path comes from Core's settings-load reply, so the host
// never decides the location on its own.
bool SettingsReload::LearnPath(const Send& send) {
    auto reply = send(kLoadRequest);
    auto parsed = reply ? json::Parse(*reply) : std::nullopt;
    if (!parsed) return false;
    const std::string& path = (*parsed)["settingsResult"]["file"]["path"].AsString();
    if (path.empty()) return false;
    path_ = text::Utf8ToUtf16(path);
    return true;
}

void SettingsReload::BeforeRequest(const Send& send, unsigned bridgeStarts) {
    if (path_.empty() && !LearnPath(send)) return;
    // Read the version before Core reads the file: a change made while Core
    // reloads then differs from the recorded version and is reloaded next time.
    FileVersion version = ReadVersion(path_);
    if (reloadedVersion_ && *reloadedVersion_ == version && reloadedBridgeStarts_ == bridgeStarts) return;
    if (!send(kReloadRequest)) return;
    reloadedVersion_ = version;
    reloadedBridgeStarts_ = bridgeStarts;
}

}  // namespace azookey::host
