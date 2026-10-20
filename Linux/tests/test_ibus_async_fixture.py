"""Check fixture failures using the real Field.key and GLib callback delivery."""
import unittest

try:
    import gi
except ModuleNotFoundError:
    Field = None
else:
    from ibus_async_integration import Field, GLib


# Match the hardware keycode used by the existing IBus integration fixture.
TEST_KEYCODE = 38


class QueuedCompletionContext:
    def __init__(self):
        self.consumed = True
        self.completion_count = 1
        self.completion_error = None
        self.finish_count = 0
        self.sources = []

    def process_key_event_async(self, _keyval, _keycode, _state, _timeout,
                                _cancellable, completed, user_data):
        def deliver():
            completed(self, object(), user_data)
            return False

        for _ in range(self.completion_count):
            self.sources.append(GLib.idle_add(deliver))

    def process_key_event_async_finish(self, _response):
        self.finish_count += 1
        if self.completion_error:
            raise self.completion_error
        return self.consumed

    def close(self):
        for source_id in self.sources:
            source = GLib.MainContext.default().find_source_by_id(source_id)
            if source:
                source.destroy()


@unittest.skipIf(Field is None, "requires IBus GI bindings")
class IBusAsyncFixtureTests(unittest.TestCase):
    def setUp(self):
        self.context = QueuedCompletionContext()
        # The field's callback handling remains real; no engine is needed to
        # exercise an original reply or propagate its callback failure.
        self.field = object.__new__(Field)
        self.field.context = self.context
        self.field.key_reply_timings = []
        self.field.native_reply_timings = []
        self.field.native = []
        self.field.document = ""
        self.field.cursor = 0
        self.field.measure_engine_response = lambda: None

    def tearDown(self):
        self.context.close()

    def test_consumed_original_reply_completes_without_delivering_native_text(self):
        self.field.key(ord("a"))
        self.assertEqual(self.context.finish_count, 1)
        self.assertEqual(len(self.field.key_reply_timings), 1)
        self.assertEqual(self.field.native, [])
        self.assertEqual(self.field.document, "")

    def test_unconsumed_original_reply_delivers_native_text_once(self):
        self.context.consumed = False
        self.field.key(ord("a"))
        self.assertEqual(self.field.native, [(ord("a"), TEST_KEYCODE, 0)])
        self.assertEqual(self.field.document, "a")
        self.assertEqual(self.context.finish_count, 1)

    def test_duplicate_completion_raises_in_the_calling_test(self):
        self.context.completion_count = 2
        with self.assertRaisesRegex(AssertionError, "an original key must complete only once"):
            self.field.key(ord("a"))
        self.assertEqual(self.context.finish_count, 1)

    def test_original_reply_failure_raises_in_the_calling_test(self):
        self.context.completion_error = RuntimeError("synthetic original reply failure")
        with self.assertRaisesRegex(RuntimeError, "synthetic original reply failure"):
            self.field.key(ord("a"))
        self.assertEqual(self.field.native, [])
        self.assertEqual(self.field.key_reply_timings, [])


if __name__ == "__main__":
    unittest.main()
