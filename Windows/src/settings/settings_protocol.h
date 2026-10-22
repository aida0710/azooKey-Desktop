// Requests and replies of Core's settings operations (DesktopSettingsController
// in Core/Sources/DesktopBridge): reading the definition and the file, saving,
// recovering a damaged file, and resetting the learning data.
#pragma once

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "../shared/json.h"

namespace azookey::settings {

// A message key with its arguments, as Core reports a refused operation.
struct Problem {
    std::string code;        // invalidValue, changed, recoveryRequired, ...
    std::string messageKey;  // a key of the shared message catalog
    std::vector<std::pair<std::wstring, std::wstring>> arguments;
};

struct FileState {
    std::wstring path;
    std::string stamp;  // opaque; a save sends it back so Core can refuse a file changed since
    bool exists = false;
    std::optional<Problem> problem;  // the file is damaged; Core uses the last good values
};

struct SaveReport {
    std::wstring recoveredPath;  // where a recovery kept the damaged file
    bool lastGoodSaved = true;   // false: saved, but the last good copy was not
};

// One reply to a settings operation.
struct SettingsReply {
    std::optional<json::Value> values;  // "settings": every value Core uses now
    std::optional<FileState> file;
    std::optional<SaveReport> saved;
    std::optional<Problem> error;  // Core refused the operation
    // The bridge or the host could not run the operation ("invalid_request",
    // "converter_unavailable"), or no reply arrived at all ("no_reply").
    std::string failure;

    bool succeeded() const { return failure.empty() && !error && values.has_value(); }
};

// The bridge session the settings screen uses for operations that need one;
// the host closes it when the screen disconnects.
inline constexpr char kSettingsContext[] = "azookey-settings";

std::string SchemaRequest();
std::string LoadRequest();
// `values` is the whole settings document; `expectedStamp` is the stamp of the
// file the screen shows, so a file changed elsewhere is not overwritten.
std::string SaveRequest(const json::Value& values, const std::string& expectedStamp);
// Replaces a damaged file with the last good values, or with input and display
// defaults when `useDefaults` is true. The damaged file is kept under a new name.
std::string RecoverRequest(const std::string& expectedStamp, bool useDefaults);
std::string ResetLearningRequest();

// `reply` is nullopt when nothing arrived.
SettingsReply ParseSettingsReply(const std::optional<json::Value>& reply);
// True when a reset-learning reply reports success.
bool ResetLearningSucceeded(const std::optional<json::Value>& reply);

// Returns `values` with `key` set to `value`.
json::Value WithValue(const json::Value& values, const std::string& key, json::Value value);

}  // namespace azookey::settings
