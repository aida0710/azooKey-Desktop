#!/usr/bin/env python3
"""Generate every platform's message tables from Shared/Messages.

Source layout: Shared/Messages/<Table>/<group>.json. Each file maps a message
key to an entry. Keys are unique within a table; groups only split files so
parallel edits touch different files.

    "candidate.position": {
        "ja": "変換候補 {position} / {total}",
        "en": "Candidates {position} / {total}",
        "macos": {"ja": "...", "en": "..."},   (optional platform wording)
        "gjs": "position",                     (optional candidateMessages.js name)
        "note": "..."                          (optional context for writers)
    }

`ja` and `en` are the wording for every platform unless a `macos`, `linux` or
`windows` block replaces both for that platform. Placeholders are `{name}`, or
`{name:d}` for an integer argument that macOS formats with %d. Every text of
an entry must use the same placeholders. Literal braces are not allowed.
"""
import argparse
import json
from dataclasses import dataclass, field
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRECTORY = ROOT / "Shared/Messages"
GENERATED_NOTICE = "Generated from Shared/Messages. Run Tools/generate-messages.py."
TABLES = ("Localizable", "UserDictionary")
LANGUAGES = ("ja", "en")
PLATFORMS = ("macos", "linux", "windows")
ENTRY_FIELDS = {*LANGUAGES, *PLATFORMS, "gjs", "note"}
KEY_PATTERN = re.compile(r"[A-Za-z0-9_.-]+")
GJS_NAME_PATTERN = re.compile(r"[A-Za-z][A-Za-z0-9]*")
PLACEHOLDER_PATTERN = re.compile(r"\{([A-Za-z][A-Za-z0-9_]*)(:d)?\}")


class CatalogError(Exception):
    pass


@dataclass(frozen=True)
class Placeholder:
    name: str
    is_integer: bool


@dataclass
class Message:
    key: str
    texts: dict  # language -> base text
    platform_texts: dict = field(default_factory=dict)  # platform -> language -> text
    gjs_name: str | None = None

    def text(self, platform, language):
        return self.platform_texts.get(platform, self.texts)[language]

    @property
    def placeholders(self):
        """Argument order for positional formats: first use in the base Japanese text."""
        return list(dict.fromkeys(placeholders_in(self.texts["ja"])))


def placeholders_in(text):
    without_placeholders = PLACEHOLDER_PATTERN.sub("", text)
    if "{" in without_placeholders or "}" in without_placeholders:
        raise CatalogError(f"unsupported brace in {text!r}; use {{name}} or {{name:d}}")
    return [Placeholder(match.group(1), match.group(2) is not None) for match in PLACEHOLDER_PATTERN.finditer(text)]


def parse_texts(value, location):
    if not isinstance(value, dict) or set(value) != set(LANGUAGES):
        raise CatalogError(f"{location}: needs exactly the languages {', '.join(LANGUAGES)}")
    if not all(isinstance(text, str) and text for text in value.values()):
        raise CatalogError(f"{location}: texts must be non-empty strings")
    return dict(value)


def parse_message(key, value, location):
    if not KEY_PATTERN.fullmatch(key):
        raise CatalogError(f"{location}: invalid key")
    if not isinstance(value, dict) or not set(LANGUAGES) <= set(value) or set(value) - ENTRY_FIELDS:
        raise CatalogError(f"{location}: fields must be ja, en and optionally {', '.join(sorted(ENTRY_FIELDS - set(LANGUAGES)))}")
    message = Message(key=key, texts=parse_texts({language: value[language] for language in LANGUAGES}, location))
    for platform in PLATFORMS:
        if platform in value:
            message.platform_texts[platform] = parse_texts(value[platform], f"{location} {platform}")
    if "gjs" in value:
        if not isinstance(value["gjs"], str) or not GJS_NAME_PATTERN.fullmatch(value["gjs"]):
            raise CatalogError(f"{location}: gjs must be a JavaScript property name")
        message.gjs_name = value["gjs"]
    if "note" in value and not isinstance(value["note"], str):
        raise CatalogError(f"{location}: note must be a string")
    expected = sorted(set(placeholders_in(message.texts["ja"])), key=lambda item: item.name)
    for platform in (None, *message.platform_texts):
        for language in LANGUAGES:
            text = message.text(platform, language)
            if sorted(set(placeholders_in(text)), key=lambda item: item.name) != expected:
                raise CatalogError(f"{location}: {platform or 'base'} {language} placeholders differ from base ja")
    return message


def load_catalog(directory=SOURCE_DIRECTORY):
    tables = {}
    for table in TABLES:
        messages = {}
        paths = sorted((directory / table).glob("*.json"))
        if not paths:
            raise CatalogError(f"{table}: no message files")
        for path in paths:
            document = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(document, dict):
                raise CatalogError(f"{path}: must contain one object")
            for key, value in document.items():
                location = f"{path.relative_to(directory)}: {key}"
                if key in messages:
                    raise CatalogError(f"{location}: duplicate key in table {table}")
                messages[key] = parse_message(key, value, location)
        tables[table] = dict(sorted(messages.items()))
    if any(message.gjs_name for message in tables["UserDictionary"].values()):
        raise CatalogError("gjs names are only supported in the Localizable table")
    gjs_names = [message.gjs_name for message in tables["Localizable"].values() if message.gjs_name]
    if len(gjs_names) != len(set(gjs_names)):
        raise CatalogError("gjs names must be unique")
    return tables


def plain_placeholders(text):
    """Python, GJS and C++ substitute names; the integer marker is macOS-only."""
    return PLACEHOLDER_PATTERN.sub(lambda match: "{" + match.group(1) + "}", text)


def apple_format(message, text):
    order = [placeholder.name for placeholder in message.placeholders]
    used = [placeholder.name for placeholder in placeholders_in(text)]
    if not order:
        return text
    sequential = used == order
    text = text.replace("%", "%%")

    def specifier(match):
        position = order.index(match.group(1)) + 1
        conversion = "d" if match.group(2) else "@"
        return f"%{conversion}" if sequential else f"%{position}${conversion}"
    return PLACEHOLDER_PATTERN.sub(specifier, text)


def apple_strings(messages, language):
    lines = [f"/* {GENERATED_NOTICE} */"]
    for message in messages.values():
        text = apple_format(message, message.text("macos", language))
        escaped = text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        lines.append(f'"{message.key}" = "{escaped}";')
    return "\n".join(lines) + "\n"


def python_table(messages):
    table = {message.key: plain_placeholders(message.text("linux", "ja")) for message in messages.values()}
    return json.dumps(table, ensure_ascii=False, indent=2) + "\n"


def javascript_template(text):
    escaped = text.replace("\\", "\\\\").replace("`", "\\`").replace("${", "\\${")
    return "`" + PLACEHOLDER_PATTERN.sub(lambda match: "${" + match.group(1) + "}", escaped) + "`"


def gjs_messages(messages):
    lines = [f"// {GENERATED_NOTICE}", "// User-facing strings are kept outside rendering and interaction code.",
             "export const messages = {"]
    for message in sorted((item for item in messages.values() if item.gjs_name), key=lambda item: item.gjs_name):
        text = message.text("linux", "ja")
        names = [placeholder.name for placeholder in message.placeholders]
        if not names:
            value = json.dumps(text, ensure_ascii=False)
        elif len(names) == 1:
            value = f"{names[0]} => {javascript_template(text)}"
        else:
            value = f"({', '.join(names)}) => {javascript_template(text)}"
        lines.append(f"    {message.gjs_name}: {value},")
    lines += ["};", ""]
    return "\n".join(lines)


def cpp_wide_literal(text):
    characters = []
    for character in plain_placeholders(text):
        code = ord(character)
        if character in '"\\':
            characters.append("\\" + character)
        elif character == "\n":
            characters.append("\\n")
        elif 0x20 <= code < 0x7F:
            characters.append(character)
        elif code <= 0xFFFF:
            characters.append(f"\\u{code:04X}")
        else:
            characters.append(f"\\U{code:08X}")
    return 'L"' + "".join(characters) + '"'


def cpp_header(tables):
    lines = [f"// {GENERATED_NOTICE}", "#pragma once", "", "namespace azookey::messages {", "",
             "// Texts keep \"{name}\" placeholders. Entries are sorted by key for binary search.",
             "struct MessageEntry {", "    const char* key;", "    const wchar_t* japanese;",
             "    const wchar_t* english;", "};"]
    for table, messages in tables.items():
        lines += ["", f"inline constexpr MessageEntry k{table}Messages[] = {{"]
        for message in messages.values():
            japanese = cpp_wide_literal(message.text("windows", "ja"))
            english = cpp_wide_literal(message.text("windows", "en"))
            lines.append(f'    {{"{message.key}", {japanese}, {english}}},')
        lines.append("};")
    lines += ["", "}  // namespace azookey::messages", ""]
    return "\n".join(lines)


def generated_sources(tables):
    sources = {}
    for language in LANGUAGES:
        for table, messages in tables.items():
            sources[f"Core/Sources/Core/Resources/{language}.lproj/{table}.strings"] = apple_strings(messages, language)
    sources["Linux/azookey/locales/ja.json"] = python_table(tables["Localizable"])
    sources["Linux/azookey/locales/user_dictionary.ja.json"] = python_table(tables["UserDictionary"])
    sources["Linux/gnome-extension/candidateMessages.js"] = gjs_messages(tables["Localizable"])
    sources["Windows/src/shared/message_catalog_data.h"] = cpp_header(tables)
    return sources


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail when a generated file differs from Shared/Messages")
    arguments = parser.parse_args()
    try:
        sources = generated_sources(load_catalog())
    except (CatalogError, json.JSONDecodeError) as error:
        parser.exit(2, f"Invalid message catalog: {error}\n")
    stale = []
    for relative, source in sources.items():
        path = ROOT / relative
        if arguments.check:
            if not path.exists() or path.read_text(encoding="utf-8") != source:
                stale.append(relative)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
    if stale:
        parser.exit(1, "Messages need regeneration with Tools/generate-messages.py: " + ", ".join(stale) + "\n")


if __name__ == "__main__":
    sys.exit(main())
