// Keeps the converter on the settings file the user saved last. Before the
// host forwards a request, it compares the file's size and last write time with
// what it saw when it last asked Core to reload, and asks again only when they
// differ, as the Linux engine does with stat. Core decides where the file is.
#pragma once

#include <windows.h>

#include <functional>
#include <optional>
#include <string>

namespace azookey::host {

class SettingsReload {
public:
    // Sends one request line to the converter and returns its reply line.
    using Send = std::function<std::optional<std::string>(const std::string&)>;

    // Call before forwarding each request. `bridgeStarts` counts the converter
    // processes started so far: a new process has not applied the file yet.
    void BeforeRequest(const Send& send, unsigned bridgeStarts);

private:
    struct FileVersion {
        bool exists = false;
        ULONGLONG size = 0;
        FILETIME lastWrite{};
        bool operator==(const FileVersion& other) const;
    };

    static FileVersion ReadVersion(const std::wstring& path);
    bool LearnPath(const Send& send);

    std::wstring path_;
    std::optional<FileVersion> reloadedVersion_;
    std::optional<unsigned> reloadedBridgeStarts_;
};

}  // namespace azookey::host
