"""Native settings controls grouped by the task the user wants to perform."""
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk
from .i18n import text as message
from .labeled_controls import label_control
from .learning_settings import learning_choices
from .prompts import shortcut_text
from .support_page import SupportPage
from .candidate_layout_preferences import DEFAULT_VISIBLE_CANDIDATE_ROWS, VISIBLE_CANDIDATE_ROWS


def populate_settings_pages(window, book):
    pages = {key: window.page(book, message("settings.page." + key))
             for key in ("input", "conversion", "dictionary", "ai", "support")}
    populate_input_page(window, pages["input"])
    populate_conversion_page(window, pages["conversion"])
    populate_dictionary_page(window, pages["dictionary"])
    populate_ai_page(window, pages["ai"])
    pages["support"].pack_start(SupportPage(lambda: window.values), True, True, 0)


def add_checkboxes(window, parent, choices):
    for key, title in choices:
        button = Gtk.CheckButton(label=title, active=window.values[key])
        parent.pack_start(button, False, False, 0)
        window.widgets[key] = button


def populate_input_page(window, parent):
    add_checkboxes(window, parent, [("halfSpace", "スペースを半角にする"),
                               ("backslash", "円記号の代わりにバックスラッシュ"),
                               ("optionDirect", "Altキーで全角英数を直接入力")])
    window.combo(parent, "inputStyle", label="入力配列", choices=[("default", "ローマ字"), ("defaultAZIK", "AZIK"),
                 ("defaultKanaJIS", "かな JIS"), ("defaultKanaUS", "かな US"), ("custom", "カスタム")])
    window.combo(parent, "punctuation", label="句読点", choices=[(1, "、。"), (2, "，。"), (3, "、．"), (4, "，．")])
    window.custom_table = window.text_area(parent, window.values["customTable"], message("settings.custom-table"))


def populate_conversion_page(window, parent):
    add_checkboxes(window, parent, [("tree", "木構造の候補ウィンドウ"), ("live", "ライブ変換")])
    window.combo(parent, "candidateTextSize", label=message("candidate.textSize"),
                 choices=[("standard", message("candidate.textSize.standard")), ("large", message("candidate.textSize.large"))])
    window.values.setdefault("candidateVisibleRows", DEFAULT_VISIBLE_CANDIDATE_ROWS)
    window.combo(parent, "candidateVisibleRows", label=message("candidate.visibleRows"),
                 choices=[(count, message("candidate.visibleRows.count", count=count)) for count in VISIBLE_CANDIDATE_ROWS])
    add_checkboxes(window, parent, [("showRelativeScores", message("candidate.score.show"))])
    parent.pack_start(Gtk.Label(label=message("candidate.score.explanation"), xalign=0, wrap=True), False, False, 0)
    window.entry(parent, "inferenceLimit", "推論回数 (1–100)")
    add_checkboxes(window, parent, [("predictiveTyping", "予測入力（開発中）"),
                               ("typoCorrection", "入力訂正（開発中）"), ("debug", "デバッグ候補")])
    download = Gtk.Button(label="入力訂正モデルをダウンロード")
    download.connect("clicked", window.download_weights)
    parent.pack_start(download, False, False, 0)


def populate_dictionary_page(window, parent):
    window.combo(parent, "learning", label=message("learning.title"), choices=learning_choices())
    parent.pack_start(Gtk.Label(label=message("learning.retention"), xalign=0, wrap=True), False, False, 0)
    reset = Gtk.Button(label=message("learning.reset.action"))
    reset.connect("clicked", window.reset_learning)
    parent.pack_start(reset, False, False, 0)
    window.entry(parent, "profile", message("settings.profile"))
    window.combo(parent, "personalization", label=message("settings.personalization"),
                 choices=[("off", "オフ"), ("soft", "弱"), ("normal", "標準"), ("hard", "強")])
    parent.pack_start(Gtk.Label(label=message("settings.personalization.explanation"), xalign=0, wrap=True), False, False, 0)
    personal = Gtk.Button(label="Tunerの個人化モデルを読み込む…")
    personal.connect("clicked", window.import_personalization)
    parent.pack_start(personal, False, False, 0)
    window.dictionary_button = Gtk.Button()
    window.dictionary_button.connect("clicked", window.edit_dictionary)
    window.refresh_dictionary_button()
    parent.pack_start(window.dictionary_button, False, False, 0)
    parent.pack_start(Gtk.Label(label=message("settings.dictionary_separate_save"), xalign=0, wrap=True), False, False, 0)


def populate_ai_page(window, parent):
    add_checkboxes(window, parent, [("aiEnabled", message("ai.backend.external")),
                               ("includeContext", message("ai.scope.include-context"))])
    parent.pack_start(Gtk.Label(label=message("ai.scope.processing-linux"), xalign=0, wrap=True), False, False, 0)
    window.entry(parent, "aiModel", message("ai.model"))
    window.entry(parent, "aiEndpoint", message("ai.endpoint"))
    window.transform_shortcut = Gtk.Entry(text=shortcut_text(window.values["transformShortcut"]))
    label_control(parent, window.transform_shortcut, message("ai.shortcut"), mnemonic="S")
    parent.pack_start(window.transform_shortcut, False, False, 0)
    window.api_key = Gtk.Entry(visibility=False, placeholder_text=message("ai.api-key-placeholder"))
    label_control(parent, window.api_key, message("ai.api-key"), mnemonic="K")
    parent.pack_start(window.api_key, False, False, 0)
    parent.pack_start(Gtk.Label(label=message("ai.scope.api-key"), xalign=0, wrap=True), False, False, 0)
