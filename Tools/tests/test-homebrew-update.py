#!/usr/bin/env python3
"""Exercise the bundled helper with isolated receipts; never execute real Homebrew."""
import difflib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "azooKeyMac/Resources/HomebrewUpdate.command"
CASK = "aida0710/tap/azookey-tree"
BUNDLE_ID = "dev.ensan.inputmethod.azooKeyMac"
# This case deliberately exercises the production bounded wait without shortening it.
HELPER_TIMEOUT_SECONDS = 150
POLL_TIMEOUT_SECONDS = 10

FIXTURE_TOOL = r'''
import json,os,pathlib,plistlib,shutil,sys,time
root=pathlib.Path(os.environ["AZOOKEY_UPDATE_FIXTURE"])
configuration=json.loads((root/"configuration.json").read_text())
operation=sys.argv[1]
if operation=="plutil":
    arguments=sys.argv[2:]
    try:
        assert arguments[0]=="-extract" and arguments[2:4]==["raw","-expect"]
        output_arguments=[argument for argument in arguments[5:] if argument!="-n"]
        assert output_arguments[:2]==["-o","-"] and len(output_arguments)==3
        raw=pathlib.Path(output_arguments[2]).read_bytes()
        value=plistlib.loads(raw) if raw.lstrip().startswith((b"<?xml",b"bplist")) else json.loads(raw)
        for key in arguments[1].split("."):
            value=value[int(key)] if isinstance(value,list) else value[key]
        expected={"string":str,"integer":int,"array":list}[arguments[4]]
        assert type(value) is expected
        print(len(value) if expected is list else value,end="" if "-n" in arguments[5:] else "\n")
    except (AssertionError,KeyError,IndexError,ValueError,TypeError,OSError):
        sys.exit(1)
    sys.exit(0)
if operation=="uname":
    print(configuration.get("platform","Darwin"));sys.exit(0)
if operation=="open":
    assert sys.argv[2:]==[configuration["bundle"]]
    with (root/"open.jsonl").open("a") as stream: stream.write(json.dumps(sys.argv[2:])+"\n")
    sys.exit(configuration.get("openExit",0))
assert operation=="brew"
role=sys.argv[2]
arguments=sys.argv[3:]
with (root/"brew.jsonl").open("a") as stream:
    stream.write(json.dumps({"role":role,"arguments":arguments})+"\n")
assert arguments in (["info","--json=v2","--cask","aida0710/tap/azookey-tree"],
    ["--caskroom","aida0710/tap/azookey-tree"],["update"],
    ["upgrade","--cask","--no-ask","--require-sha","aida0710/tap/azookey-tree"]),arguments
settings={**configuration,**configuration.get("roles",{}).get(role,{})}
room=root/("caskroom-"+role)
if arguments[0]=="info":
    if settings.get("infoExit"): sys.exit(settings["infoExit"])
    if settings.get("invalidJSON"): print("not json");sys.exit(0)
    installed=settings.get("installed","0.1.0")
    if (root/"upgraded").exists() and not settings.get("unchanged"):
        installed=settings.get("latest","0.2.0")
    info={"casks":[{"tap":settings.get("tap","aida0710/tap"),"token":settings.get("token","azookey-tree"),
        "full_token":settings.get("fullToken","aida0710/tap/azookey-tree"),"installed":installed,
        "version":settings.get("latest","0.2.0"),"artifacts":settings.get("artifacts",[{"input_method":["azooKeyMac.app"]}])}]}
    print(json.dumps(info));sys.exit(0)
if arguments[0]=="--caskroom":
    print(room);sys.exit(0)
if arguments[0]=="update":
    (root/"update-started").touch()
    if settings.get("blockUpdate"):
        deadline=time.monotonic()+10
        while not (root/"release-update").exists():
            if time.monotonic()>deadline: sys.exit(20)
            time.sleep(.01)
    if settings.get("changeOnUpdate"):
        link=room/settings.get("installed","0.1.0")/"azooKeyMac.app"
        link.unlink();link.symlink_to(root/"other.app",target_is_directory=True)
    if settings.get("rewriteRequestOnUpdate"):
        request=pathlib.Path(configuration["request"])
        values=plistlib.loads(request.read_bytes());values["parentPID"]=1;values["bundlePath"]="/unrelated.app"
        request.write_bytes(plistlib.dumps(values))
        request.parent.parent.joinpath("latest.plist").unlink()
    sys.exit(settings.get("updateExit",0))
if settings.get("upgradeExit"): sys.exit(settings["upgradeExit"])
(root/"upgraded").touch()
if not settings.get("unchanged"):
    bundle=pathlib.Path(configuration["bundle"])
    # The old .command disappears just as it would during an app replacement.
    shutil.rmtree(bundle)
    (bundle/"Contents").mkdir(parents=True)
    version=settings.get("verifiedVersion",settings.get("latest","0.2.0"))
    bundle.joinpath("Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier":settings.get("verifiedBundleID","dev.ensan.inputmethod.azooKeyMac"),
        "CFBundleShortVersionString":version}))
    staged=room/settings.get("latest","0.2.0")/"azooKeyMac.app"
    staged.parent.mkdir(parents=True,exist_ok=True)
    staged.symlink_to(bundle,target_is_directory=True)
    if settings.get("badUpdatedLink"):
        staged.unlink();staged.symlink_to(root/"other.app",target_is_directory=True)
'''


class HomebrewUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="azookey-update-")
        self.directory = Path(self.temporary.name)
        self.home = self.directory / "home with spaces"
        self.bundle = self.directory / "Input Methods/azooKeyMac.app"
        self.resource = self.bundle / "Contents/Resources/HomebrewUpdate.command"
        self.resource.parent.mkdir(parents=True)
        self.configuration = {"bundle": str(self.bundle)}
        self.job_id = str(uuid.uuid4()).upper()
        self.update_root = self.home / "Library/Containers" / BUNDLE_ID / "Data/Library/Application Support/azooKey Tree/HomebrewUpdates"
        self.job = self.update_root / self.job_id
        self.job.mkdir(parents=True)
        self.request = {"jobID": self.job_id, "bundlePath": str(self.bundle),
                        "bundleVersion": "0.1.0", "parentPID": 2147483647, "language": "ja"}
        self.configuration["request"] = str(self.job / "request.plist")
        self.info("0.1.0")
        self.tools = self.directory / "fixture tools"
        self.tools.mkdir()
        self.tool_source = self.tools / "fixture.py"
        self.tool_source.write_text(FIXTURE_TOOL)
        self.brews = {role: self.tools / role / "brew" for role in ("arm", "intel", "path")}
        self.command(self.brews["arm"], "brew", "arm")
        self.staged("arm")
        replacements = {"/opt/homebrew/bin/brew": self.brews["arm"],
                        "/usr/local/bin/brew": self.brews["intel"],
                        "/usr/bin/open": self.command(self.tools / "open", "open"),
                        "/usr/bin/uname": self.command(self.tools / "uname", "uname")}
        if sys.platform != "darwin":
            replacements["/usr/bin/plutil"] = self.command(self.tools / "plutil", "plutil")
        original = SOURCE.read_text()
        transformed = original
        for command, fixture in replacements.items():
            self.assertIn(command, transformed)
            transformed = transformed.replace(command, shlex.quote(str(fixture)))
        self.assertNotIn("/opt/homebrew/bin/brew", transformed)
        self.assertNotIn("/usr/local/bin/brew", transformed)
        self.resource.write_text(transformed)
        self.resource.chmod(0o755)
        self.environment = {**os.environ, "HOME": str(self.home),
                            "PATH": str(self.brews["path"].parent) + ":/usr/bin:/bin",
                            "AZOOKEY_UPDATE_FIXTURE": str(self.directory)}
        self.evidence = {"test": self.id(), "nativePlutil": sys.platform == "darwin",
                         "sourceSHA256": hashlib.sha256(original.encode()).hexdigest(),
                         "fixtureSHA256": hashlib.sha256(transformed.encode()).hexdigest(),
                         "commandReplacements": {key: str(value) for key, value in replacements.items()},
                         "fixtureDiff": list(difflib.unified_diff(original.splitlines(), transformed.splitlines()))}

    def tearDown(self):
        if output := os.environ.get("AZOOKEY_HOMEBREW_TEST_ARTIFACTS"):
            destination = Path(output)
            destination.mkdir(parents=True, exist_ok=True)
            self.evidence["status"] = self.status()
            self.evidence["brewCalls"] = self.calls()
            (destination / (self._testMethodName + ".json")).write_text(json.dumps(self.evidence, indent=2) + "\n")
        self.temporary.cleanup()

    def command(self, path, *arguments):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexec " + " ".join(shlex.quote(value) for value in
                        (sys.executable, str(self.tool_source), *arguments)) + ' "$@"\n')
        path.chmod(0o755)
        return path

    def info(self, version, bundle_id=BUNDLE_ID):
        (self.bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle_id, "CFBundleShortVersionString": version}))

    def staged(self, role, *, target=None, version="0.1.0"):
        link = self.directory / ("caskroom-" + role) / version / "azooKeyMac.app"
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(target or self.bundle, target_is_directory=True)
        return link

    def prepare(self):
        (self.directory / "configuration.json").write_text(json.dumps(self.configuration))
        (self.update_root / "latest.plist").write_bytes(plistlib.dumps({"jobID": self.job_id}))
        (self.job / "request.plist").write_bytes(plistlib.dumps(self.request))

    def launch(self):
        self.prepare()
        return subprocess.Popen(["/bin/sh", str(self.resource)], env=self.environment,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def run_helper(self, expected=0):
        process = self.launch()
        stdout, stderr = process.communicate(timeout=HELPER_TIMEOUT_SECONDS)
        self.assertEqual(process.returncode, expected, (stdout, stderr, self.status()))
        return self.status()

    def status(self):
        path = self.job / "status.json"
        return json.loads(path.read_text()) if path.exists() else None

    def calls(self):
        path = self.directory / "brew.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def mutations(self):
        return [call for call in self.calls() if call["arguments"][0] in ("update", "upgrade")]

    def failed(self, code):
        status = self.run_helper(expected=1)
        self.assertEqual((status["phase"], status["code"]), ("failed", code))
        return status

    def wait_for(self, predicate):
        deadline = time.monotonic() + POLL_TIMEOUT_SECONDS
        while not predicate():
            if time.monotonic() >= deadline:
                self.fail("Fixture condition did not complete")
            time.sleep(.01)

    def test_managed_upgrade_verifies_replaced_app_then_restarts_only_that_bundle(self):
        status = self.run_helper()
        self.assertEqual((status["phase"], status["installedVersion"], status["targetVersion"]),
                         ("restarted", "0.2.0", "0.2.0"))
        self.assertIsInstance(status["helperPID"], int)
        self.assertEqual((self.job / "status.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.job / ".started").stat().st_mode & 0o777, 0o700)
        self.assertEqual(status["jobID"], self.job_id)
        self.assertEqual([call["arguments"] for call in self.mutations()], [
            ["update"], ["upgrade", "--cask", "--no-ask", "--require-sha", CASK]])
        self.assertFalse(self.resource.exists(), "The running helper must survive old Resources removal")
        self.assertEqual(json.loads((self.directory / "open.jsonl").read_text()), [str(self.bundle)])

    def test_current_version_finishes_without_upgrade_or_restart(self):
        self.configuration["latest"] = "0.1.0"
        status = self.run_helper()
        self.assertEqual((status["phase"], status["installedVersion"], status["targetVersion"]),
                         ("upToDate", "0.1.0", "0.1.0"))
        self.assertEqual([call["arguments"] for call in self.mutations()], [["update"]])
        self.assertFalse((self.directory / "open.jsonl").exists())

    def test_older_metadata_never_downgrades(self):
        self.configuration["latest"] = "0.0.9"
        self.assertEqual(self.run_helper()["phase"], "upToDate")
        self.assertEqual([call["arguments"] for call in self.mutations()], [["update"]])

    def test_minor_version_comparison_is_numeric(self):
        self.request["bundleVersion"] = "1.9.9"
        self.configuration.update(installed="1.9.9", latest="1.10.0")
        self.info("1.9.9"); self.staged("arm", version="1.9.9")
        self.assertEqual(self.run_helper()["installedVersion"], "1.10.0")

    def test_major_version_comparison_is_numeric(self):
        self.request["bundleVersion"] = "9.0.0"
        self.configuration.update(installed="9.0.0", latest="10.0.0")
        self.info("9.0.0"); self.staged("arm", version="9.0.0")
        self.assertEqual(self.run_helper()["installedVersion"], "10.0.0")

    def test_large_decimal_components_do_not_overflow(self):
        current, target = "1.99999999999999999999.0", "1.100000000000000000000.0"
        self.request["bundleVersion"] = current
        self.configuration.update(installed=current, latest=target)
        self.info(current); self.staged("arm", version=current)
        self.assertEqual(self.run_helper()["installedVersion"], target)

    def test_installed_null_is_unmanaged_and_does_not_mutate_homebrew(self):
        self.configuration["installed"] = None
        self.failed("unmanaged"); self.assertEqual(self.mutations(), [])

    def test_wrong_tap_is_unmanaged(self):
        self.configuration["tap"] = "other/tap"
        self.failed("unmanaged"); self.assertEqual(self.mutations(), [])

    def test_wrong_full_token_is_unmanaged(self):
        self.configuration["fullToken"] = "other/tap/azookey-tree"
        self.failed("unmanaged"); self.assertEqual(self.mutations(), [])

    def test_wrong_input_method_artifact_is_unmanaged(self):
        self.configuration["artifacts"] = [{"input_method": ["Another.app"]}]
        self.failed("unmanaged"); self.assertEqual(self.mutations(), [])

    def test_running_version_must_match_homebrew_installed_receipt(self):
        self.configuration["installed"] = "0.0.9"
        self.failed("unmanaged"); self.assertEqual(self.mutations(), [])

    def test_manual_bundle_replacement_is_not_managed(self):
        self.info("0.1.1")
        self.failed("unmanaged"); self.assertEqual(self.mutations(), [])

    def test_wrong_bundle_identifier_is_not_managed(self):
        self.info("0.1.0", "other.bundle")
        self.failed("unmanaged"); self.assertEqual(self.mutations(), [])

    def test_stale_or_non_symlink_staging_does_not_prove_management(self):
        link = self.directory / "caskroom-arm/0.1.0/azooKeyMac.app"
        link.unlink(); link.mkdir()
        self.failed("unmanaged"); self.assertEqual(self.mutations(), [])

    def test_symlink_to_a_different_app_is_not_managed(self):
        other = self.directory / "other.app"; other.mkdir()
        link = self.directory / "caskroom-arm/0.1.0/azooKeyMac.app"
        link.unlink(); link.symlink_to(other, target_is_directory=True)
        self.failed("unmanaged"); self.assertEqual(self.mutations(), [])

    def test_multiple_brews_choose_the_one_that_manages_this_bundle(self):
        self.configuration["roles"] = {"arm": {"tap": "other/tap"}}
        self.command(self.brews["intel"], "brew", "intel"); self.staged("intel")
        self.assertEqual(self.run_helper()["phase"], "restarted")
        self.assertEqual({call["role"] for call in self.mutations()}, {"intel"})

    def test_absolute_terminal_path_brew_is_a_supported_candidate(self):
        self.brews["arm"].unlink()
        self.command(self.brews["path"], "brew", "path"); self.staged("path")
        self.assertEqual(self.run_helper()["phase"], "restarted")
        self.assertEqual({call["role"] for call in self.mutations()}, {"path"})

    def test_no_homebrew_never_calls_any_real_executable(self):
        self.brews["arm"].unlink()
        self.failed("noHomebrew"); self.assertEqual(self.calls(), [])

    def test_malformed_metadata_fails_before_any_mutation(self):
        self.configuration["invalidJSON"] = True
        self.failed("checkFailed"); self.assertEqual(self.mutations(), [])

    def test_prerelease_target_is_refused(self):
        self.configuration["latest"] = "0.2.0-beta.1"
        self.failed("checkFailed"); self.assertEqual(self.mutations(), [])

    def test_request_version_with_trailing_newline_is_not_normalized_into_a_valid_version(self):
        self.request["bundleVersion"] = "0.1.0\n"
        self.failed("unsupported"); self.assertEqual(self.calls(), [])

    def test_artifact_with_trailing_newline_is_not_normalized_into_the_expected_app(self):
        self.configuration["artifacts"] = [{"input_method": ["azooKeyMac.app\n"]}]
        self.failed("unmanaged"); self.assertEqual(self.mutations(), [])

    def test_target_version_with_trailing_newline_is_refused_before_update(self):
        self.configuration["latest"] = "0.2.0\n"
        self.failed("checkFailed"); self.assertEqual(self.mutations(), [])

    def test_identity_changed_during_brew_update_blocks_upgrade(self):
        (self.directory / "other.app").mkdir()
        self.configuration["changeOnUpdate"] = True
        self.failed("changedInstallation")
        self.assertEqual([call["arguments"] for call in self.mutations()], [["update"]])

    def test_brew_update_failure_is_not_success(self):
        self.configuration["updateExit"] = 1
        self.failed("updateFailed")
        self.assertEqual([call["arguments"] for call in self.mutations()], [["update"]])

    def test_pinned_or_failed_upgrade_is_not_forced(self):
        self.configuration["upgradeExit"] = 1
        self.failed("updateFailed")
        self.assertEqual(self.mutations()[-1]["arguments"], ["upgrade", "--cask", "--no-ask", "--require-sha", CASK])

    def test_zero_exit_with_old_version_fails_verification(self):
        self.configuration["unchanged"] = True
        self.failed("verificationFailed")
        self.assertFalse((self.directory / "open.jsonl").exists())

    def test_wrong_updated_bundle_version_fails_verification(self):
        self.configuration["verifiedVersion"] = "0.1.0"
        self.failed("verificationFailed")

    def test_wrong_updated_symlink_fails_verification(self):
        (self.directory / "other.app").mkdir()
        self.configuration["badUpdatedLink"] = True
        self.failed("verificationFailed")

    def test_restart_failure_is_distinct_from_verified_update(self):
        self.configuration["openExit"] = 1
        status = self.failed("restartFailed")
        self.assertEqual((status["installedVersion"], status["targetVersion"]), ("0.2.0", "0.2.0"))

    def test_old_request_and_latest_are_not_reread_after_update_starts(self):
        self.configuration["rewriteRequestOnUpdate"] = True
        self.assertEqual(self.run_helper()["phase"], "restarted")

    def test_duplicate_terminal_launch_keeps_original_helper_status(self):
        self.configuration["blockUpdate"] = True
        first = self.launch()
        try:
            self.wait_for(lambda: (self.directory / "update-started").exists())
            before = (self.job / "status.json").read_bytes()
            second = subprocess.run(["/bin/sh", str(self.resource)], env=self.environment, capture_output=True, timeout=10)
            self.assertEqual(second.returncode, 0)
            self.assertEqual((self.job / "status.json").read_bytes(), before)
            (self.directory / "release-update").touch()
            first.communicate(timeout=HELPER_TIMEOUT_SECONDS)
            self.assertEqual(first.returncode, 0)
        finally:
            (self.directory / "release-update").touch()
            if first.poll() is None:
                first.kill(); first.communicate()

    def test_natural_parent_exit_after_verified_update_allows_restart(self):
        parent = subprocess.Popen([sys.executable, "-c", "import json,pathlib,sys,time; p=pathlib.Path(sys.argv[1]);\nwhile not p.exists() or json.loads(p.read_text()).get('phase')!='updated': time.sleep(.01)", str(self.job / "status.json")])
        reaper = threading.Thread(target=parent.wait)
        reaper.start()
        self.request["parentPID"] = parent.pid
        try:
            self.assertEqual(self.run_helper()["phase"], "restarted")
            reaper.join(timeout=5)
            self.assertFalse(reaper.is_alive())
            self.assertEqual(parent.returncode, 0)
        finally:
            if parent.poll() is None: parent.kill(); parent.wait()

    def test_non_exiting_parent_is_not_killed_or_restarted(self):
        self.request["parentPID"] = os.getpid()
        started = time.monotonic()
        status = self.failed("restartFailed")
        self.assertGreaterEqual(time.monotonic() - started, 120)
        self.assertEqual(status["installedVersion"], "0.2.0")
        self.assertFalse((self.directory / "open.jsonl").exists())

    def test_request_parent_pid_requires_an_integer(self):
        self.request["parentPID"] = "2147483647"
        self.failed("unsupported"); self.assertEqual(self.calls(), [])

    def test_unsupported_platform_does_not_call_homebrew(self):
        self.configuration["platform"] = "Linux"
        self.failed("unsupported"); self.assertEqual(self.calls(), [])

    def test_matching_nonsandbox_root_is_supported(self):
        self.update_root = self.home / "Library/Application Support/azooKey Tree/HomebrewUpdates"
        self.job = self.update_root / self.job_id
        self.job.mkdir(parents=True)
        self.configuration["request"] = str(self.job / "request.plist")
        self.assertEqual(self.run_helper()["phase"], "restarted")

    def test_two_matching_roots_are_ambiguous_and_never_execute_brew(self):
        other_root = self.home / "Library/Application Support/azooKey Tree/HomebrewUpdates"
        other_job = other_root / str(uuid.uuid4())
        other_job.mkdir(parents=True)
        values = {**self.request, "jobID": other_job.name}
        (other_job / "request.plist").write_bytes(plistlib.dumps(values))
        (other_root / "latest.plist").write_bytes(plistlib.dumps({"jobID": other_job.name}))
        self.run_helper(expected=1)
        self.assertIsNone(self.status()); self.assertEqual(self.calls(), [])

    def test_malicious_uuid_is_never_interpreted_as_a_path_or_shell_command(self):
        self.job_id = "../../$(touch injected)"
        # Keep the actual request in its original private directory.
        self.prepare()
        process = subprocess.run(["/bin/sh", str(self.resource)], env=self.environment, capture_output=True, timeout=10)
        self.assertEqual(process.returncode, 1)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.directory / "injected").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
