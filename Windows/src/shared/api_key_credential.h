// The AI API key lives in Windows Credential Manager, never in the settings
// file. The settings screen writes it; the AI requests read it.
#pragma once

#include <optional>
#include <string>

namespace azookey::credentials {

// The generic credential that holds the key of the OpenAI-compatible API.
inline constexpr wchar_t kApiKeyTarget[] = L"azooKey Tree/openai-compatible";

// The key is stored as UTF-8 bytes and kept on this machine only
// (CRED_PERSIST_LOCAL_MACHINE), as the AI page tells the user.
bool StoreApiKey(const std::wstring& target, const std::wstring& key);
// nullopt when no key is stored.
std::optional<std::wstring> ReadApiKey(const std::wstring& target);
// True when the key is gone afterwards, including when there was none.
bool DeleteApiKey(const std::wstring& target);

}  // namespace azookey::credentials
