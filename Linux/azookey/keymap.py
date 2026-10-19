"""Translate X11/IBus key values into the existing Core key event contract."""
SPECIAL = {
    0xFF08: 51, 0xFF09: 48, 0xFF0D: 36, 0xFF1B: 53,
    0xFF51: 123, 0xFF53: 124, 0xFF54: 125, 0xFF52: 126,
    0xFFC3: 97, 0xFFC4: 98, 0xFFC5: 100, 0xFFC6: 101, 0xFFC7: 109,
    0xFF22: 102, 0xFF23: 104, 0xFF25: 104, 0x20: 49,
}
DIGITS = dict(zip("1234567890", [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]))


def translate(keyval, state):
    if state & (1 << 30):  # Key release is never another insertion.
        return None
    modifiers = (1 if state & 1 else 0) | (2 if state & 4 else 0)
    modifiers |= 4 if state & 8 else 0
    modifiers |= 8 if state & ((1 << 26) | (1 << 6)) else 0
    scalar = keyval & 0xFFFFFF if keyval & 0xFF000000 == 0x01000000 else keyval
    text = chr(scalar) if 0x20 <= scalar < 0xFF00 or 0x10000 <= scalar <= 0x10FFFF else None
    if scalar in range(0xD800, 0xE000):
        text = None
    return {
        "keyCode": SPECIAL.get(keyval, DIGITS.get(text, 0xFFFF)),
        "characters": text,
        "charactersIgnoringModifiers": text.lower() if text else None,
        "modifierFlags": modifiers,
    }
