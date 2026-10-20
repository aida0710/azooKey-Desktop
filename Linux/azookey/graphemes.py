"""Unicode cursor boundaries from the Pango library already required by GTK."""
import ctypes


class _LogAttr(ctypes.Structure):
    # Pango's public C struct is a guint bit field. PyGObject cannot reliably
    # expose these bit fields, so use the same ABI directly, without font I/O.
    _fields_ = [
        ("is_line_break", ctypes.c_uint, 1),
        ("is_mandatory_break", ctypes.c_uint, 1),
        ("is_char_break", ctypes.c_uint, 1),
        ("is_white", ctypes.c_uint, 1),
        ("is_cursor_position", ctypes.c_uint, 1),
        ("remaining_flags", ctypes.c_uint, 27),
    ]


_pango = ctypes.CDLL("libpango-1.0.so.0")
_pango.pango_get_log_attrs.argtypes = [
    ctypes.c_char_p, ctypes.c_int, ctypes.c_int, ctypes.c_void_p,
    ctypes.POINTER(_LogAttr), ctypes.c_int,
]
_pango.pango_get_log_attrs.restype = None


def cursor_boundaries(text):
    """Return scalar offsets at extended grapheme boundaries (UAX #29)."""
    encoded = text.encode("utf-8")
    attributes = (_LogAttr * (len(text) + 1))()
    _pango.pango_get_log_attrs(encoded, len(encoded), -1, None, attributes, len(attributes))
    return [index for index, attribute in enumerate(attributes) if attribute.is_cursor_position]
