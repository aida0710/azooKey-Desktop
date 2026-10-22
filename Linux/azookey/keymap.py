"""Translate X11/IBus key values into the existing Core key event contract."""
SPECIAL = {
    0xFF08: 51, 0xFF09: 48, 0xFF0D: 36, 0xFF8D: 0x4C, 0xFF1B: 53,
    0xFF51: 123, 0xFF53: 124, 0xFF54: 125, 0xFF52: 126,
    0xFF50: 0x73, 0xFF57: 0x77, 0xFFFF: 0x75,
    0xFFC3: 97, 0xFFC4: 98, 0xFFC5: 100, 0xFFC6: 101, 0xFFC7: 109,
    0xFF22: 102, 0xFF23: 104, 0xFF25: 104, 0x20: 49,
}
DIGITS = dict(zip("1234567890", [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]))
# XKB modifier keysyms change keyboard state; their separate press events are
# not edits. Sending them to the recovery buffer would flush pending text.
NATIVE_MODIFIERS = frozenset(range(0xFFE1, 0xFFEF)) | {0xFF7F, 0xFE03, 0xFE11}


def translate(keyval, state, unicode_scalar=None):
    if state & (1 << 30):  # Key release is never another insertion.
        return None
    if keyval in NATIVE_MODIFIERS:
        return None
    modifiers = (1 if state & 1 else 0) | (2 if state & 4 else 0)
    modifiers |= 4 if state & 8 else 0
    modifiers |= 8 if state & ((1 << 26) | (1 << 6)) else 0
    encoded_unicode = keyval & 0xFF000000 == 0x01000000
    scalar = keyval & 0xFFFFFF if encoded_unicode else keyval
    printable = 0x20 <= scalar <= 0x10FFFF if encoded_unicode else 0x20 <= scalar <= 0xFF
    text = chr(scalar) if printable else None
    if unicode_scalar is not None:
        text = chr(unicode_scalar) if 0x20 <= unicode_scalar <= 0x10FFFF else None
        scalar = unicode_scalar
    if scalar in range(0xD800, 0xE000):
        text = None
    return {
        "keyCode": SPECIAL.get(keyval, DIGITS.get(text, 0xFFFF)),
        "characters": text,
        "charactersIgnoringModifiers": text.lower() if text else None,
        "modifierFlags": modifiers,
    }
