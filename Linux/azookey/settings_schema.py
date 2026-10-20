"""Validate the Linux settings document before it reaches Core or UI widgets."""
import copy
import urllib.parse
import uuid

from .i18n import text
from .graphemes import cursor_boundaries


BOOLEAN_KEYS = frozenset({
    "tree", "live", "halfSpace", "backslash", "optionDirect", "predictiveTyping",
    "typoCorrection", "debug", "aiEnabled", "includeContext",
})
STRING_KEYS = frozenset({"profile", "aiModel", "aiEndpoint", "customTable"})
CHOICES = {
    "inputStyle": {"default", "defaultAZIK", "defaultKanaJIS", "defaultKanaUS", "custom"},
    "learning": {"inputAndOutput", "onlyOutput", "nothing"},
    "personalization": {"off", "soft", "normal", "hard"},
    "candidateTextSize": {"standard", "large"},
}
KNOWN_KEYS = BOOLEAN_KEYS | STRING_KEYS | CHOICES.keys() | {
    "punctuation", "inferenceLimit", "transformShortcut", "userDictionary",
}
MAX_INFERENCE_LIMIT = 100
MAX_PROFILE_LENGTH = 4096
SHORTCUT_MODIFIER_MASK = 15

# Reset only input/display preferences. Persistent dictionaries, custom tables,
# learning mode, personalization, profile and AI settings remain the user's.
INPUT_DEFAULTS = {
    "tree": True, "live": True, "halfSpace": False, "backslash": False,
    "optionDirect": False, "inputStyle": "default", "candidateTextSize": "standard",
    "punctuation": 1, "inferenceLimit": 5, "predictiveTyping": False,
    "typoCorrection": False, "debug": False,
}
PRESERVED_SETTINGS = frozenset({
    "userDictionary", "customTable", "learning", "personalization", "profile",
    "aiEnabled", "aiModel", "aiEndpoint", "includeContext", "transformShortcut",
})


def invalid_setting(field):
    return ValueError(text("settings.invalid_value", field=field))


def _mapping(value, fields, *, path):
    if type(value) is not dict:
        raise invalid_setting(path)
    unknown = value.keys() - fields
    if unknown:
        raise ValueError(text("settings.unknown_key", field=f"{path}{next(iter(unknown))}"[:100]))


def _text(value, *, path, nonempty=False):
    if type(value) is not str or nonempty and not value:
        raise invalid_setting(path)
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise invalid_setting(path) from error


def _shortcut(value):
    _mapping(value, {"key", "modifiers"}, path="transformShortcut.")
    _text(value.get("key"), path="transformShortcut.key", nonempty=True)
    modifiers = value.get("modifiers")
    if type(modifiers) is not int or modifiers < 0 or modifiers & ~SHORTCUT_MODIFIER_MASK:
        raise invalid_setting("transformShortcut.modifiers")


def _dictionary(value):
    _mapping(value, {"items"}, path="userDictionary.")
    if type(value.get("items")) is not list:
        raise invalid_setting("userDictionary.items")
    identifiers = set()
    for index, entry in enumerate(value["items"]):
        path = f"userDictionary.items[{index}]."
        _mapping(entry, {"id", "reading", "word", "hint"}, path=path)
        for key in ("id", "reading", "word"):
            _text(entry.get(key), path=path + key, nonempty=True)
        try:
            identifier = uuid.UUID(entry["id"])
        except ValueError as error:
            raise invalid_setting(path + "id") from error
        if identifier in identifiers:
            raise invalid_setting(path + "id")
        identifiers.add(identifier)
        if entry.get("hint") is not None:
            _text(entry["hint"], path=path + "hint")


def validate_settings(document, *, defaults=None):
    """Merge older partial documents into known values, rejecting unknown data."""
    _mapping(document, KNOWN_KEYS, path="")
    # Check the bounded schema before copying potentially recursive input.
    values = {**(defaults or {}), **document}
    _mapping(values, KNOWN_KEYS, path="")
    for key, value in values.items():
        if key in BOOLEAN_KEYS and type(value) is not bool:
            raise invalid_setting(key)
        if key in STRING_KEYS:
            _text(value, path=key)
        if key in CHOICES and (type(value) is not str or value not in CHOICES[key]):
            raise invalid_setting(key)
    if "punctuation" in values and (type(values["punctuation"]) is not int or values["punctuation"] not in range(1, 5)):
        raise invalid_setting("punctuation")
    if "inferenceLimit" in values:
        limit = values["inferenceLimit"]
        if type(limit) is not int or not 1 <= limit <= MAX_INFERENCE_LIMIT:
            raise invalid_setting("inferenceLimit")
    # Core counts Swift Characters, so combining sequences count as one.
    if len(cursor_boundaries(values.get("profile", ""))) - 1 > MAX_PROFILE_LENGTH:
        raise invalid_setting("profile")
    if "aiEndpoint" in values:
        try:
            endpoint = urllib.parse.urlparse(values["aiEndpoint"])
            if endpoint.scheme not in ("http", "https") or not endpoint.hostname:
                raise invalid_setting("aiEndpoint")
        except ValueError as error:
            raise invalid_setting("aiEndpoint") from error
    if "transformShortcut" in values:
        _shortcut(values["transformShortcut"])
    if "userDictionary" in values:
        _dictionary(values["userDictionary"])
    if values.get("inputStyle") == "custom" and not values.get("customTable"):
        raise invalid_setting("customTable")
    return copy.deepcopy(values)


def input_defaults(values):
    return validate_settings({**copy.deepcopy(values), **INPUT_DEFAULTS})
