#!/usr/bin/python3
"""Qt fixture; records actual widget hints without claiming an IBus mapping."""
from PyQt6.QtCore import QEvent, Qt, QT_VERSION_STR, QTimer
from PyQt6.QtWidgets import QApplication, QLabel, QLineEdit, QVBoxLayout, QWidget

from protected_fixture_state import (
    FIELD_LABELS, READ_ONLY_TEXT, WINDOW_HEIGHT, WINDOW_WIDTH,
    ProtectedFixtureRecorder,
)


class ProtectedLineEdit(QLineEdit):
    def __init__(self, *, field_id, recorder, changed):
        super().__init__()
        self.field_id = field_id
        self.recorder = recorder
        self.changed = changed
        self.preedit = ""

    def inputMethodEvent(self, event):
        self.recorder.events.append(
            "input-method", fieldId=self.field_id, commit=event.commitString(),
            preedit=event.preeditString(), replacementStartUTF16=event.replacementStart(),
            replacementLengthUTF16=event.replacementLength(),
        )
        self.preedit = event.preeditString()
        super().inputMethodEvent(event)
        self.changed()

    def keyPressEvent(self, event):
        # Observe the key and native result without consuming or rewriting it.
        self.recorder.events.append(
            "key-press", fieldId=self.field_id, key=event.key(),
            modifiers=event.modifiers().value, text=event.text(),
        )
        super().keyPressEvent(event)
        self.changed()


class ProtectedInputWindow(QWidget):
    def __init__(self, *, application, recorder):
        super().__init__()
        self.application = application
        self.recorder = recorder
        self.editors = {}
        self.setWindowTitle("azooKey protected input — Qt")
        self.resize(WINDOW_WIDTH, WINDOW_HEIGHT)
        layout = QVBoxLayout(self)
        layout.addWidget(QLabel("Synthetic text only. Tab / Shift+Tab moves between fields."))
        for field_id, label in FIELD_LABELS.items():
            editor = ProtectedLineEdit(field_id=field_id, recorder=recorder, changed=self.record)
            editor.setAccessibleName(label)
            if field_id in ("password", "pin"):
                editor.setEchoMode(QLineEdit.EchoMode.Password)
                if field_id == "pin":
                    editor.setInputMethodHints(
                        editor.inputMethodHints() | Qt.InputMethodHint.ImhDigitsOnly
                    )
            elif field_id == "private":
                editor.setInputMethodHints(Qt.InputMethodHint.ImhSensitiveData)
            elif field_id == "read-only":
                editor.setText(READ_ONLY_TEXT)
                editor.setReadOnly(True)
            self.editors[field_id] = editor
            editor.textChanged.connect(self.record)
            editor.cursorPositionChanged.connect(self.record)
            editor.selectionChanged.connect(self.record)
            layout.addWidget(QLabel(label))
            layout.addWidget(editor)
        application.focusChanged.connect(self.record)
        application.focusWindowChanged.connect(self.record)
        self.show()
        self.editors["normal"].setFocus()
        self.record()

    def changeEvent(self, event):
        super().changeEvent(event)
        if event.type() == QEvent.Type.ActivationChange:
            QTimer.singleShot(0, self.record)

    def record(self, *_arguments):
        fields = []
        for field_id, editor in self.editors.items():
            selected = editor.hasSelectedText()
            start = editor.selectionStart() if selected else editor.cursorPosition()
            end = editor.selectionEnd() if selected else editor.cursorPosition()
            fields.append({
                "id": field_id,
                "label": FIELD_LABELS[field_id],
                "text": editor.text(),
                "focused": self.isActiveWindow() and editor.hasFocus(),
                "preedit": editor.preedit,
                "cursorUTF16": editor.cursorPosition(),
                "selection": {"startUTF16": start, "endUTF16": end},
                "attributes": {
                    "editable": not editor.isReadOnly(),
                    "echoMode": editor.echoMode().name,
                    "inputHints": editor.inputMethodHints().value,
                    "sensitiveDataHint": bool(
                        editor.inputMethodHints() & Qt.InputMethodHint.ImhSensitiveData
                    ),
                    "inputMethodEnabled": editor.inputMethodQuery(Qt.InputMethodQuery.ImEnabled),
                },
            })
        self.recorder.record(
            fields=fields, window_active=self.isActiveWindow(),
            toolkit={
                "name": "Qt", "version": QT_VERSION_STR,
                "platform": self.application.platformName(),
            },
        )


def main():
    recorder = ProtectedFixtureRecorder.from_arguments()
    application = QApplication([])
    window = ProtectedInputWindow(application=application, recorder=recorder)
    application.aboutToQuit.connect(window.record)
    return application.exec()


if __name__ == "__main__":
    raise SystemExit(main())
