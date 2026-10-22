"""Build the settings notebook from the pages Core defines."""
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk
from .i18n import text as message
from .labeled_controls import label_control
from .settings_controls import CONTROLS
from .support_page import SupportPage


def populate_settings_pages(window, book):
    items = {item["key"]: item for item in window.schema["items"]}
    builders = {
        "setting": lambda parent, element: add_setting(window, parent, items[element["key"]]),
        "note": lambda parent, element: add_note(parent, element["textKey"]),
        "action": lambda parent, element: add_action(window, parent, element["action"]),
        "secret": lambda parent, element: add_secret(window, parent, element["secret"]),
        "support": lambda parent, _element: parent.pack_start(SupportPage(lambda: window.values, window.bridge), True, True, 0),
    }
    for page in window.schema["pages"]:
        parent = window.page(book, message(page["titleKey"]))
        for element in page["elements"]:
            builders[element["kind"]](parent, element)


def add_setting(window, parent, item):
    if item["control"] == "dictionary":
        # The dictionary has its own editor and its own save.
        window.dictionary_button = Gtk.Button()
        window.dictionary_button.connect("clicked", window.edit_dictionary)
        window.refresh_dictionary_button()
        parent.pack_start(window.dictionary_button, False, False, 0)
        widget = window.dictionary_button
    else:
        control = CONTROLS[item["control"]](parent, item)
        control.show(window.values[item["key"]])
        window.controls[item["key"]] = control
        window.widgets[item["key"]] = widget = control.widget
    if item.get("descriptionKey"):
        add_note(parent, item["descriptionKey"])
    show_availability(parent, widget, item)


def add_note(parent, text_key):
    parent.pack_start(Gtk.Label(label=message(text_key), xalign=0, wrap=True), False, False, 0)


def add_action(window, parent, action):
    handlers = {
        "downloadTypoWeights": window.download_weights,
        "resetLearning": window.reset_learning,
        "importPersonalization": window.import_personalization,
    }
    button = Gtk.Button(label=message(action["labelKey"]))
    button.connect("clicked", handlers[action["id"]])
    parent.pack_start(button, False, False, 0)
    show_availability(parent, button, action)


def add_secret(window, parent, secret):
    # The API key lives in the keyring, never in the settings file.
    window.api_key = Gtk.Entry(visibility=False, placeholder_text=message(secret["placeholderKey"]))
    label_control(parent, window.api_key, message(secret["labelKey"]), mnemonic=secret["accessKey"])
    parent.pack_start(window.api_key, False, False, 0)
    add_note(parent, secret["descriptionKey"])


def show_availability(parent, widget, definition):
    if definition["available"]:
        return
    widget.set_sensitive(False)
    add_note(parent, definition["unavailableReasonKey"])
