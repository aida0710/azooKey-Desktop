#!/usr/bin/python3
import argparse
import gi
gi.require_version("IBus", "1.0")
gi.require_version("Gtk", "3.0")
from gi.repository import IBus, Gtk
from azookey.engine import Engine
from azookey.async_bridge import AsyncBridge


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ibus", action="store_true")
    parser.add_argument("--setup", action="store_true")
    arguments = parser.parse_args()
    if arguments.setup:
        from azookey.settings import run
        run()
        return
    IBus.init()
    bus = IBus.Bus()
    bus.connect("disconnected", lambda _bus: Gtk.main_quit())
    factory = IBus.Factory.new(bus.get_connection())
    factory.add_engine("azookey-tree", Engine)
    if arguments.ibus:
        bus.request_name("org.freedesktop.IBus.AzooKeyTree", 0)
    else:
        component = IBus.Component.new("org.freedesktop.IBus.AzooKeyTree", "azooKey Tree", "0.1.0", "MIT", "azooKey contributors", "https://github.com/aida0710/azooKey-Desktop", "", "")
        component.add_engine(IBus.EngineDesc.new("azookey-tree", "azooKey Tree", "Japanese input with candidate paths", "ja", "MIT", "azooKey contributors", "", "default"))
        bus.register_component(component)
    try:
        Gtk.main()
    finally:
        AsyncBridge.close_shared()


if __name__ == "__main__":
    main()
