"""Only the current completed AI transformation may replace document text."""


class AITransformationPreview:
    def __init__(self):
        self._revision = 0
        self._pending_revision = None
        self._text = None

    @property
    def is_loading(self):
        return self._pending_revision is not None

    @property
    def applicable_text(self):
        return None if self.is_loading else self._text

    def begin(self):
        if self.is_loading:
            return None
        self._revision += 1
        self._pending_revision = self._revision
        self._text = None
        return self._revision

    def invalidate(self):
        self._revision += 1
        self._pending_revision = None
        self._text = None

    def complete(self, revision, text):
        if self._pending_revision is None or revision != self._pending_revision:
            return False
        self._pending_revision = None
        self._text = text or None
        return True
