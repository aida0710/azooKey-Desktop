"""Keep IBus input effects inside the reply to the original ProcessKeyEvent."""
import gi

gi.require_version("IBus", "1.0")
from gi.repository import GLib, IBus

from .native_key_reply import NativeKeyReply


def dispatch_native_key(engine, arguments):
    connection, _sender, _path, interface, method, parameters, _invocation = arguments
    if (method != "ProcessKeyEvent" or interface != "org.freedesktop.IBus.Engine"
            or connection != engine.get_connection()):
        IBus.Engine.do_service_method_call(engine, *arguments)
        return
    reply = NativeKeyReply(lambda consumed: finish_native_key(engine, consumed, arguments))
    previous, engine.native_key_reply = engine.native_key_reply, reply
    try:
        consumed = engine.emit("process-key-event", *parameters.unpack())
        if not reply.deferred:
            reply.finish(consumed)
    finally:
        engine.native_key_reply = previous


def finish_native_key(engine, consumed, arguments):
    if consumed:
        arguments[-1].return_value(GLib.Variant("(b)", (True,)))
        return
    # Let the public IBus dispatcher retain its extension filtering and native
    # event semantics, without creating a second synthetic ForwardKeyEvent.
    previous, engine.native_key_passthrough = engine.native_key_passthrough, True
    try:
        IBus.Engine.do_service_method_call(engine, *arguments)
    finally:
        engine.native_key_passthrough = previous
