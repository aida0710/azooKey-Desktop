#!/usr/bin/python3
"""Guest-only manual IBus test: native Qt and Chromium-backed editing widgets."""
import sys
from PyQt6.QtWidgets import QApplication, QMainWindow, QTabWidget, QTextEdit
from PyQt6.QtWebEngineWidgets import QWebEngineView
app = QApplication(sys.argv)
window = QMainWindow()
window.setWindowTitle('azooKey input test — Qt / Chromium')
tabs = QTabWidget()
editor = QTextEdit()
editor.setPlaceholderText('Qt: 日本語を入力し、候補クリック後も入力できることを確認')
tabs.addTab(editor, 'Qt')
web = QWebEngineView()
web.setHtml('<!doctype html><meta charset="utf-8"><style>body{font:20px sans-serif;padding:20px}textarea{width:90%;height:220px;font:24px sans-serif}</style><p>Chromium / QtWebEngine</p><textarea aria-label="日本語入力テスト"></textarea>')
tabs.addTab(web, 'Chromium')
window.setCentralWidget(tabs)
window.resize(800, 500)
window.show()
sys.exit(app.exec())
