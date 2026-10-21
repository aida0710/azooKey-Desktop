"""Synthetic IBus document with selection and surrounding-text support."""
from ibus_native_field import Field, IBus, wait_for


class SurroundingField(Field):
    def __init__(self, bus, name):
        super().__init__(bus, name)
        self.anchor = 0
        self.auxiliary = ""
        self.context.set_capabilities(
            IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.FOCUS
            | IBus.Capabilite.SURROUNDING_TEXT | IBus.Capabilite.AUXILIARY_TEXT,
        )
        self.context.connect("require-surrounding-text", lambda *_: self.surrounding())
        self.context.connect("delete-surrounding-text", self.delete)
        self.context.connect("update-auxiliary-text", self.auxiliary_changed)

    def focus(self):
        super().focus()
        wait_for(self.context.needs_surrounding_text)
        self.surrounding()

    def surrounding(self):
        self.context.set_surrounding_text(
            IBus.Text.new_from_string(self.document), self.cursor, self.anchor,
        )

    def insert(self, text):
        start, end = sorted((self.cursor, self.anchor))
        self.document = self.document[:start] + text + self.document[end:]
        self.cursor = self.anchor = start + len(text)
        self.surrounding()

    def deliver_native(self, keyval, state, *, route):
        super().deliver_native(keyval, state, route=route)
        self.anchor = self.cursor
        self.surrounding()

    def auxiliary_changed(self, _context, text, visible):
        self.auxiliary = text.get_text() if visible else ""

    def delete(self, _context, offset, count):
        # Each test decides whether to accept, defer, or ignore the deletion.
        raise NotImplementedError
