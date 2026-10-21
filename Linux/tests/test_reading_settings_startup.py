"""Bootstrap must precede input while candidate startup remains independent."""
from copy import deepcopy
import unittest

from candidate_fixture import WAIT_SECONDS
from reading_coordinator_fixture import event
from worker_settings_fixture import ReadingSettingsTestCase, settings_values


class ReadingSettingsStartupTests(ReadingSettingsTestCase):
    def offer_defaults(self, defaults=None, *, error=False):
        fields = ({"defaultSettingsError": "invalid_worker_defaults"} if error else
                  {"defaultSettings": defaults if defaults is not None else settings_values()})

        def include_defaults(operation, reply):
            return {**reply, **deepcopy(fields)} if operation == "hello" else reply

        self.reader.rewrite = include_defaults

    def test_saved_settings_are_applied_before_queued_focus_and_keys_without_waiting_for_candidates(self):
        self.offer_defaults(settings_values(live=True))
        configuration = self.reader.gate("configure-settings")
        startup = self.converter.gate("settings")
        provided = []

        def saved_settings(defaults):
            provided.append(deepcopy(defaults))
            return {**defaults, "live": False, "inputStyle": "defaultAZIK"}

        self.start(settings_provider=saved_settings)
        self.focus()
        self.coordinator.key("field", event("a"), token="original",
                             finish=lambda *reply: self.finished.append(reply))
        self.until(lambda: provided)
        self.assertTrue(configuration.entered.wait(WAIT_SECONDS))
        self.assertTrue(startup.entered.wait(WAIT_SECONDS))
        self.assertEqual(self.finished, [])
        self.assertFalse(any(name == "open" for name, _ in self.reader.calls))
        configuration.proceed.set()
        self.until(lambda: self.finished)
        self.assertEqual(self.finished, [("original", True)])
        self.assertEqual(self.reader.values["inputStyle"], "defaultAZIK")
        self.assertEqual(self.panels, [])
        self.assertEqual(len(provided), 1)
        self.assertTrue(provided[0]["live"])
        startup.proceed.set()
        self.agreed()
        self.assertEqual(self.converter.values, self.reader.values)

    def test_unavailable_defaults_finish_original_reply_once_without_applying_keys_or_guesses(self):
        self.offer_defaults(error=True)
        provided = []
        self.start(settings_provider=lambda values: provided.append(values))
        self.focus()
        self.coordinator.key("field", event("a"), token="original",
                             finish=lambda *reply: self.finished.append(reply))
        self.until(lambda: self.finished)
        self.assertEqual(provided, [])
        self.assertEqual(self.finished, [("original", True)])
        self.assertEqual(self.inputs, [])
        self.assertFalse(any(name in ("configure-settings", "open", "key") for name, _ in self.reader.calls))
        self.assertTrue(all(notice.code == "reading_settings_unavailable" for notice in self.notices))
        self.coordinator.close()
        self.assertEqual(self.finished, [("original", True)])

    def test_unsupported_preferences_get_a_specific_error_and_are_not_sent_to_either_process(self):
        self.offer_defaults(settings_values(live=True))
        self.start(settings_provider=lambda values: values)
        self.focus()
        self.until(lambda: self.coordinator._broken)
        self.assertTrue(self.notices)
        self.assertTrue(all(notice.code == "reading_settings_unsupported" for notice in self.notices))
        self.assertFalse(any(name == "configure-settings" for name, _ in self.reader.calls))
        self.assertFalse(any(name == "configure-settings" for _, name, _ in self.converter.calls))

    def test_old_worker_without_defaults_is_not_mistaken_for_current_python_defaults(self):
        self.start(settings_provider=lambda _: settings_values())
        self.focus()
        self.until(lambda: self.coordinator._broken)
        self.assertTrue(all(notice.code == "reading_settings_unavailable" for notice in self.notices))
        self.assertIsNone(self.reader.values)

    def test_reentrant_input_waits_until_the_provider_has_finished_the_configuration_payload(self):
        self.offer_defaults()

        def provider(defaults):
            self.coordinator.key("field", event("a"), token="reentrant",
                                 finish=lambda *reply: self.finished.append(reply))
            self.assertIsNone(self.coordinator._active)
            return {**defaults, "halfSpace": True}

        self.start(settings_provider=provider)
        self.focus()
        self.until(lambda: self.finished)
        self.assertEqual(self.finished, [("reentrant", True)])
        self.assertTrue(self.reader.values["halfSpace"])
        self.assertEqual(self.inputs[-1].snapshot["preedit"], "a")

    def test_unexpected_provider_exception_finishes_queued_original_input_without_replay(self):
        self.offer_defaults()

        def unavailable(_defaults):
            raise LookupError("injected provider failure")

        self.start(settings_provider=unavailable)
        self.focus()
        self.coordinator.key("field", event("a"), token="original",
                             finish=lambda *reply: self.finished.append(reply))
        self.until(lambda: self.finished)
        self.assertEqual(self.finished, [("original", True)])
        self.assertEqual(self.inputs, [])
        self.assertTrue(all(notice.code == "reading_settings_unavailable" for notice in self.notices))
        self.assertFalse(any(name == "configure-settings" for name, _ in self.reader.calls))

    def test_provider_closing_the_coordinator_cannot_revive_queued_input(self):
        self.offer_defaults()

        def close(defaults):
            self.coordinator.close()
            return defaults

        self.start(settings_provider=close)
        self.focus()
        self.coordinator.key("field", event("a"), token="original",
                             finish=lambda *reply: self.finished.append(reply))
        self.until(lambda: self.finished)
        self.assertEqual(self.finished, [("original", True)])
        self.assertTrue(self.coordinator._closed)
        self.assertEqual(self.inputs, [])
        self.assertFalse(any(name == "configure-settings" for name, _ in self.reader.calls))


if __name__ == "__main__":
    unittest.main()
