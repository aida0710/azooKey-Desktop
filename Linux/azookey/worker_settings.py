"""Validate the settings shared by the reading and candidate processes."""
from copy import deepcopy

from .settings_schema import validate_settings


SETTINGS_FIELDS = frozenset((
    "tree", "candidateTextSize", "showRelativeScores", "live", "halfSpace",
    "backslash", "optionDirect", "inputStyle", "learning", "punctuation",
    "profile", "personalization", "inferenceLimit", "predictiveTyping",
    "typoCorrection", "debug", "aiEnabled", "transformShortcut", "customTable",
))
ACKNOWLEDGEMENT_FIELDS = frozenset((
    "settingsContract", "settings", "customInputTableRevisions", "unsupportedFeatures",
))
# These operations need a formal reading implementation before the new entry
# can use them. Never silently turn a saved preference off.
UNSUPPORTED_BOOLEAN_SETTINGS = ("live", "predictiveTyping", "aiEnabled", "debug")


def validated_settings(values):
    if type(values) is not dict or values.keys() != SETTINGS_FIELDS:
        raise ValueError("worker settings require the complete settings contract")
    validated = validate_settings(values)
    if any(validated[name] for name in UNSUPPORTED_BOOLEAN_SETTINGS):
        raise ValueError("unsupported worker settings")
    return validated


def acknowledgement(response, *, expected=None):
    if response.get("settingsContract") != "full":
        raise ValueError("worker requires the full settings contract")
    unsupported = response.get("unsupportedFeatures")
    if (type(unsupported) is not list or any(type(name) is not str for name in unsupported)
            or len(set(unsupported)) != len(unsupported)):
        raise ValueError("invalid unsupported worker features")
    tables = response.get("customInputTableRevisions")
    if type(tables) is not dict or any(type(name) is not str or type(revision) is not str
                                     for name, revision in tables.items()):
        raise ValueError("invalid worker input table revisions")
    if "settings" in response:
        values = validated_settings(response["settings"])
        if expected is not None and values != expected:
            raise ValueError("worker acknowledged different settings")
    elif expected is not None:
        raise ValueError("worker omitted applied settings")
    return deepcopy({key: response[key] for key in ACKNOWLEDGEMENT_FIELDS if key in response})
