"""Every message key in Core's settings definitions resolves in the Linux catalog."""
import os
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))


@unittest.skipUnless(os.environ.get("AZOOKEY_BRIDGE"), "requires the Swift bridge")
class SettingsSchemaMessageTests(unittest.TestCase):
    def test_labels_descriptions_choices_pages_and_reasons_have_japanese_text(self):
        from azookey.bridge import Bridge
        from azookey.i18n import text
        from azookey import settings_client
        bridge = Bridge()
        try:
            schema = settings_client.schema(bridge)
        finally:
            bridge.close()
        keys = []
        for item in schema["items"]:
            keys += [item["labelKey"], item.get("descriptionKey"), item.get("unavailableReasonKey")]
            keys += [choice["labelKey"] for choice in item.get("choices", [])]
        for page in schema["pages"]:
            keys.append(page["titleKey"])
            for element in page["elements"]:
                keys.append(element.get("textKey"))
                action = element.get("action", {})
                keys += [action.get("labelKey"), action.get("unavailableReasonKey")]
                secret = element.get("secret", {})
                keys += [secret.get("labelKey"), secret.get("placeholderKey"), secret.get("descriptionKey")]
        keys += ["settings.unavailable.marisa_windows", "ai.scope.processing-windows"]
        for key in filter(None, keys):
            with self.subTest(key=key):
                self.assertTrue(text(key, count=0))

    def test_every_problem_core_reports_has_japanese_text(self):
        from azookey.i18n import text
        # DesktopSettingsProblem.Code.messageKey in Core.
        keys = ["invalid_value", "unknown_key", "invalid_json", "invalid_structure", "read_failed", "engine_rejected",
                "changed", "recovery_required", "busy", "write_failed", "backend_recovery_failed"]
        for key in keys:
            with self.subTest(key=key):
                self.assertTrue(text("settings." + key, field="live", line="1", column="2"))


if __name__ == "__main__":
    unittest.main()
