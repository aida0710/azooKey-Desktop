#!/usr/bin/python3
"""Guest-only Qt/QtWebEngine fixture; records only its own synthetic input."""
import argparse
import json
import pathlib
import sys
import time
from fixture_events import FixtureEvents

from PyQt6.QtCore import QEvent, QTimer, QT_VERSION_STR
from PyQt6.QtWebEngineCore import QWebEnginePage
from PyQt6.QtWebEngineWidgets import QWebEngineView
from PyQt6.QtWidgets import QApplication, QMainWindow, QTabWidget, QTextEdit, QVBoxLayout, QWidget


parser = argparse.ArgumentParser()
parser.add_argument("--output", type=pathlib.Path)
parser.add_argument("--events", type=pathlib.Path)
arguments = parser.parse_args()
if arguments.output:
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
event_log = FixtureEvents(arguments.events)

class TestWindow(QMainWindow):
    def changeEvent(self, event):
        super().changeEvent(event)
        if event.type() == QEvent.Type.ActivationChange:
            # Observe after Qt finishes updating focus and active-window state.
            QTimer.singleShot(0, record)


application = QApplication(sys.argv)
window = TestWindow()
window.setWindowTitle("azooKey UX validation — Qt / QtWebEngine")
tabs = QTabWidget()
native_page = QWidget()
native_layout = QVBoxLayout(native_page)
editors = []
browser_fields = []
# The prefix distinguishes this fixture's events from Chromium diagnostics.
BROWSER_EVENT_PREFIX = "AZOOKEY_FIXTURE:"


def record():
    if arguments.output:
        state = {
            "observedAt": time.time(), "monotonicNS": time.monotonic_ns(),
            "windowActive": window.isActiveWindow(),
            "qt_version": QT_VERSION_STR,
            "platform": application.platformName(),
            "tab": tabs.currentIndex(),
            "fields": [
                {"text": editor.toPlainText(), "focused": window.isActiveWindow() and editor.hasFocus(),
                 "cursor": editor.textCursor().position(), "preedit": editor.preedit,
                 "selection": {"startUTF16": editor.textCursor().selectionStart(),
                               "endUTF16": editor.textCursor().selectionEnd()}}
                for editor in editors
            ],
            "browser_fields": browser_fields,
        }
        pending_output = arguments.output.with_suffix(arguments.output.suffix + ".pending")
        pending_output.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
        pending_output.replace(arguments.output)
        event_log.append("state", state=state)


class TestEditor(QTextEdit):
    preedit = ""

    def inputMethodEvent(self, event):
        # Observe the native event, then let QTextEdit apply it unchanged.
        event_log.append(
            "input-method", fieldIndex=self.field_index, commit=event.commitString(),
            preedit=event.preeditString(), replacementStartUTF16=event.replacementStart(),
            replacementLengthUTF16=event.replacementLength(),
        )
        self.preedit = event.preeditString()
        super().inputMethodEvent(event)
        record()


class TestPage(QWebEnginePage):
    def javaScriptConsoleMessage(self, level, message, line, source):
        global browser_fields
        if message.startswith(BROWSER_EVENT_PREFIX):
            browser_fields = json.loads(message[len(BROWSER_EVENT_PREFIX):])
            record()
        else:
            super().javaScriptConsoleMessage(level, message, line, source)


for index in range(2):
    editor = TestEditor()
    editor.field_index = index
    editor.setAccessibleName(f"Test input {index + 1}")
    editor.setPlaceholderText("日本語を入力し、候補クリック後に続けて入力")
    editor.setStyleSheet("font-size: 24px")
    editor.textChanged.connect(record)
    editor.cursorPositionChanged.connect(record)
    editor.selectionChanged.connect(record)
    editors.append(editor)
    native_layout.addWidget(editor)
tabs.addTab(native_page, "Qt")

browser = QWebEngineView()
browser.setPage(TestPage(browser))
browser.setHtml("""<!doctype html><html lang="ja"><meta charset="utf-8">
<style>
body {font:20px sans-serif;padding:12px}
textarea {display:block;width:95%;height:150px;font:24px sans-serif;margin:12px 0}
</style><p>Chromium / QtWebEngine — local synthetic input fixture</p>
<textarea aria-label="Test input 1"></textarea><textarea aria-label="Test input 2"></textarea>
<script>
const editors = [...document.querySelectorAll('textarea')];
function report() {
    console.log('AZOOKEY_FIXTURE:' + JSON.stringify(editors.map(editor => ({
        text: editor.value, focused: document.activeElement === editor,
        cursor: editor.selectionStart, selectionEnd: editor.selectionEnd
    }))));
}
for (const editor of editors) {
    for (const event of ['input', 'focus', 'blur', 'select', 'compositionend']) {
        editor.addEventListener(event, report);
    }
}
report();
</script></html>""")
tabs.addTab(browser, "QtWebEngine")
tabs.currentChanged.connect(record)
application.focusChanged.connect(lambda _old, _new: record())
application.focusWindowChanged.connect(lambda _window: record())
window.setCentralWidget(tabs)
window.resize(900, 600)
window.show()
editors[0].setFocus()
record()
sys.exit(application.exec())
