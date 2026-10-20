"""Track one inline composition without reading the client's document.

IBus exposes a caret rectangle, not character rectangles or the client font.
For a single line, calibrate Pango's prefix widths with the observed caret
advance. Wrapped or otherwise uncertain geometry falls back to the caret.
"""


class PreeditAnchor:
    def __init__(self, measure):
        self.measure = measure
        self.location = None
        self.start = None
        self.text = ""
        self.cursor = 0
        self.scale = 1.0
        self.awaiting_location = False

    def update(self, text, cursor, committed=False):
        if not text:
            self.start = None
            self.scale = 1.0
        elif not self.text:
            self.start = self.location
        if committed:
            # A partial commit can move the remaining composition's start.
            self.start = None
        self.awaiting_location = (text, cursor) != (self.text, self.cursor)
        self.text, self.cursor = text, max(0, min(cursor, len(text)))

    def locate(self, location):
        previous = self.location
        self.location = location
        if previous == location:
            return
        if self.start and self.text and previous != location:
            # Switching from a Latin provisional letter to Japanese often
            # changes fallback-font ascent and line height without wrapping.
            same_line = abs(location[1] - self.start[1]) <= max(2, min(location[3], self.start[3]) / 3)
            if not same_line or not self.awaiting_location or location[0] < self.start[0]:
                self.start = None
            elif self.cursor:
                measured = self.measure(self.text[:self.cursor])
                advance = location[0] - self.start[0]
                if measured > 0 and advance > 0:
                    scale = advance / measured
                    if 0.5 <= scale <= 3:
                        self.scale = scale
                        self.start = (self.start[0], location[1], location[2], location[3])
                    else:
                        self.start = None
        self.awaiting_location = False

    @property
    def position(self):
        return self.start or self.location or (0, 0, 0, 0)

    def geometry(self, words):
        if not self.start or not words or "".join(words) != self.text:
            return None
        prefix, previous, widths = "", 0, []
        for word in words:
            prefix += word
            end = self.measure(prefix) * self.scale
            widths.append(end - previous)
            previous = end
        if any(width < 6 for width in widths):
            return None
        return {"widths": widths, "fontSize": min(24, max(10, 40 / 3 * self.scale))}
