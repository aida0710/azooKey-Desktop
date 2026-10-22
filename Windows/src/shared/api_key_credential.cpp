#include "api_key_credential.h"

#include <windows.h>
#include <wincred.h>

#include "text_encoding.h"

namespace azookey::credentials {

bool StoreApiKey(const std::wstring& target, const std::wstring& key) {
    std::string bytes = text::Utf16ToUtf8(key);
    CREDENTIALW credential{};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = const_cast<wchar_t*>(target.c_str());
    credential.CredentialBlobSize = static_cast<DWORD>(bytes.size());
    credential.CredentialBlob = reinterpret_cast<BYTE*>(bytes.data());
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    credential.UserName = const_cast<wchar_t*>(L"azooKey Tree");
    bool stored = CredWriteW(&credential, 0) != FALSE;
    SecureZeroMemory(bytes.data(), bytes.size());
    return stored;
}

std::optional<std::wstring> ReadApiKey(const std::wstring& target) {
    PCREDENTIALW credential = nullptr;
    if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) return std::nullopt;
    std::string bytes(reinterpret_cast<const char*>(credential->CredentialBlob), credential->CredentialBlobSize);
    CredFree(credential);
    std::wstring key = text::Utf8ToUtf16(bytes);
    SecureZeroMemory(bytes.data(), bytes.size());
    return key;
}

bool DeleteApiKey(const std::wstring& target) {
    return CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0) || GetLastError() == ERROR_NOT_FOUND;
}

}  // namespace azookey::credentials
