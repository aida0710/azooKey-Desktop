"""Preserve pending literal input for IBus focus-out without guessing candidates."""
from .graphemes import cursor_boundaries


SHIFT = 1
CONTROL = 2
OPTION = 4
COMMAND = 8
ENTER_KEYS = (36, 76)
SELECTION_STATES = ("previewing", "selecting", "replaceSuggestion")
CONTROL_KEYS = {"h": 51, "m": 36, "p": 126, "n": 125, "f": 124, "i": 123, "o": 124}


def is_core_input(event):
    """Text and language keys are consumed in either language after Reset."""
    modifiers = event.get("modifierFlags", 0)
    return (bool(event.get("characters")) and modifiers in (0, SHIFT)
            or event.get("keyCode") in (102, 104) and modifiers == 0)


def is_native_key(event, snapshot):
    """Whether an idle key can use the application's original native event."""
    if snapshot.get("preedit") or snapshot.get("inputState", "none") != "none":
        return False
    modifiers = event.get("modifierFlags", 0)
    key = event.get("keyCode")
    if modifiers & COMMAND:
        return True
    if modifiers & CONTROL:
        logical = event.get("charactersIgnoringModifiers")
        # These two shortcuts can start an IME operation even with no preedit.
        return not ((modifiers == CONTROL and logical == "s")
                    or (modifiers == (CONTROL | SHIFT) and logical == "u"))
    if modifiers & OPTION:
        return False
    if key in (48, 51, 53, 97, 98, 100, 101, 109, 115, 117, 119, 123, 124, 125, 126, *ENTER_KEYS):
        return True
    if key == 0xFFFF and not event.get("characters"):
        return True
    return snapshot.get("language") == "english" and (
        key == 49 or bool(event.get("characters")) and event.get("characters") not in ("\\", "¥")
    )


class InputPreview:
    """A recovery buffer, not a second kana/kanji conversion implementation.

    Confirmed preedit and literal pending input are kept separately from text
    already submitted by a pending Enter. Conversion/navigation never invents
    a candidate; a focus change preserves the last visible text or its reading.
    """
    def __init__(self, snapshot, *, settings=None):
        self.settings = settings or {}
        self.live_conversion = self.settings.get("live", True)
        self.prefix = ""
        self.text = snapshot.get("preedit", "")
        self.cursor = min(snapshot.get("cursor", len(self.text)), len(self.text))
        self.reading = snapshot.get("reading", self.text)
        self.reading_cursor = snapshot.get("readingCursor", len(self.reading))
        self.language = snapshot.get("language", "japanese")
        self.state = snapshot.get("inputState", "composing" if self.text else "none")
        self.discarded = False
        self.restored_reading = False

    @property
    def visible_text(self):
        return self.prefix + self.text

    @property
    def visible_cursor(self):
        return len(self.prefix) + self.cursor

    def apply(self, event):
        """Apply a representable edit; False asks the caller to return native keys."""
        modifiers = event.get("modifierFlags", 0)
        key = event.get("keyCode")
        shifted = bool(modifiers & SHIFT)
        if key == 53 and modifiers & (CONTROL | OPTION | COMMAND):
            return True
        if modifiers & COMMAND:
            return False
        if modifiers & CONTROL:
            logical = event.get("charactersIgnoringModifiers")
            key = CONTROL_KEYS.get(logical)
            shifted = shifted or logical in ("i", "o")
            if key is None:
                # Core consumes unknown Control shortcuts during composition.
                return self.state != "none"
        if modifiers & OPTION:
            # Core consumes Option+Escape/navigation while composing. An
            # Option character/dead-key must be resolved by Core, not guessed.
            return self.state != "none" and key in (53, 123, 124, 125, 126)
        if key == 53:
            self._escape()
        elif key in ENTER_KEYS:
            if self.state != "none":
                self.prefix += self.text
                self._clear_composition()
            else:
                self._insert("\n")
        elif key == 49:
            self._space(shifted)
        elif key == 51:
            return self._delete(backward=True)
        elif key == 117:
            return self._delete(backward=False)
        elif key in (123, 124, 115, 119):
            return self._move(key, shifted)
        elif key in (125, 126):
            if self.state != "none":
                if key == 125:
                    self.state = "selecting"
            else:
                return False
        elif key in (102, 104):
            self.language = "english" if key == 102 else "japanese"
        elif key in (97, 98, 100, 101, 109, 48):
            # Preserve the last actual text while conversion/prediction runs.
            return self.state != "none"
        elif event.get("characters"):
            if self.state == "replaceSuggestion":
                self._restore_reading()
                self.state = "composing"
            elif self.state in SELECTION_STATES:
                self.prefix += self.text
                self._clear_composition()
            self._insert(event["characters"])
            if self.state == "none" and self.language == "japanese":
                self.state = "composing"
        else:
            return False
        return True

    def _insert(self, characters):
        if self.state == "composing" and self.text != self.reading:
            self._restore_reading()
        self.text = self.text[:self.cursor] + characters + self.text[self.cursor:]
        self.cursor += len(characters)
        self.reading = self.text
        self.reading_cursor = self.cursor

    def _clear_composition(self):
        self.text = self.reading = ""
        self.cursor = self.reading_cursor = 0
        self.state = "none"

    def _restore_reading(self):
        self.text = self.reading
        self.cursor = min(self.reading_cursor, len(self.reading))
        self.restored_reading = True

    def _escape(self):
        if self.state == "selecting" and not self.live_conversion:
            self.state = "previewing"
        elif self.state in SELECTION_STATES:
            self._restore_reading()
            self.cursor = len(self.text)
            self.state = "composing"
        elif self.state != "none":
            self._clear_composition()
            self.discarded = True

    def _space(self, shifted):
        if self.state == "none":
            half = self.settings.get("halfSpace", False)
            full = self.language != "english" and half == shifted
            self._insert("　" if full else " ")
        elif self.language == "english":
            self._insert(" ")
        else:
            self.state = "selecting" if self.live_conversion or self.state != "composing" else "previewing"

    def _move(self, key, shifted):
        if key in (115, 119) and self.state != "none":
            self._restore_reading()
            self.state = "composing"
        elif shifted:
            if self.state != "none":
                self.state = "selecting"
                return True
            return False
        elif self.state in SELECTION_STATES:
            return True
        if self.state != "none":
            self._restore_reading()
        boundaries = cursor_boundaries(self.text)
        if key == 115:
            self.cursor = 0
        elif key == 119:
            self.cursor = len(self.text)
        elif key == 123:
            previous = [offset for offset in boundaries if offset < self.cursor]
            if not previous:
                return self.state != "none"
            self.cursor = previous[-1]
        else:
            following = [offset for offset in boundaries if offset > self.cursor]
            if not following:
                return self.state != "none"
            self.cursor = following[0]
        self.reading_cursor = self.cursor
        return True

    def _delete(self, *, backward):
        if self.state != "none":
            self._restore_reading()
            self.state = "composing"
        boundaries = cursor_boundaries(self.text)
        previous = [offset for offset in boundaries if offset < self.cursor]
        following = [offset for offset in boundaries if offset > self.cursor]
        if backward:
            if not previous:
                return self.state != "none"
            start, end = previous[-1], self.cursor
        else:
            if not following:
                return self.state != "none"
            start, end = self.cursor, following[0]
        self.text = self.text[:start] + self.text[end:]
        self.cursor = start
        self.reading, self.reading_cursor = self.text, self.cursor
        if not self.text:
            self.state = "none"
        return True
