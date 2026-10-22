// Identities registered with COM and TSF. Changing them makes Windows treat
// the IME as a different product, so they are fixed for every release.
#pragma once

#include <windows.h>

namespace azookey::tsf {

// {DC2488F5-F672-4910-9FEA-6D97306B86DA}
inline constexpr CLSID kTextServiceClsid = {0xdc2488f5, 0xf672, 0x4910, {0x9f, 0xea, 0x6d, 0x97, 0x30, 0x6b, 0x86, 0xda}};
// {30051583-6CBB-49E0-AEAA-91AE64DCA550}
inline constexpr GUID kProfileGuid = {0x30051583, 0x6cbb, 0x49e0, {0xae, 0xaa, 0x91, 0xae, 0x64, 0xdc, 0xa5, 0x50}};
// Composition underline while typing (not converted yet).
// {86AECB09-5F18-4993-9C15-4FB5C9F12C87}
inline constexpr GUID kInputAttributeGuid = {0x86aecb09, 0x5f18, 0x4993, {0x9c, 0x15, 0x4f, 0xb5, 0xc9, 0xf1, 0x2c, 0x87}};
// The clause whose candidates are shown.
// {9B7C402F-8CF7-4B2C-84BE-B450A7EC5086}
inline constexpr GUID kTargetClauseAttributeGuid = {0x9b7c402f, 0x8cf7, 0x4b2c, {0x84, 0xbe, 0xb4, 0x50, 0xa7, 0xec, 0x50, 0x86}};
// Other converted clauses.
// {606C2F32-0046-4FD4-B462-995FA553D251}
inline constexpr GUID kConvertedClauseAttributeGuid = {0x606c2f32, 0x0046, 0x4fd4, {0xb4, 0x62, 0x99, 0x5f, 0xa5, 0x53, 0xd2, 0x51}};
// The candidate list as a TSF UI element, for applications that draw it themselves.
// {863CCDD5-722F-4B6D-959E-DE00B688DC82}
inline constexpr GUID kCandidateListElementGuid = {0x863ccdd5, 0x722f, 0x4b6d, {0x95, 0x9e, 0xde, 0x00, 0xb6, 0x88, 0xdc, 0x82}};

inline constexpr LANGID kJapaneseLanguage = MAKELANGID(LANG_JAPANESE, SUBLANG_JAPANESE_JAPAN);
inline constexpr wchar_t kDisplayName[] = L"azooKey Tree";

}  // namespace azookey::tsf
