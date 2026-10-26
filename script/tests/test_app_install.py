#!/usr/bin/env python3
"""Offline packaging/install tests. All process and launchd commands are stubs.

Real filesystem operations and zip creation stay inside a temporary project and
HOME. No installed user app, compiler, debugger, or GUI is invoked.
"""
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUNDLE_ID = "ai.linkingdigital.AgentStatusBoard"
STUB = '''#!/usr/bin/env python3
import json, os, pathlib, plistlib, subprocess, sys
tool, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ["FAKE_COMMAND_LOG"], "a") as out:
    out.write(json.dumps({"tool": tool, "args": args}) + "\\n")
running = pathlib.Path(os.environ["FAKE_RUNNING"])
installed = pathlib.Path(os.environ["FAKE_INSTALLED"])
def start():
    if os.environ.get("FAKE_FAIL_START"):
        return
    version = plistlib.loads((installed / "Contents/Info.plist").read_bytes()).get("CFBundleShortVersionString")
    if version != os.environ.get("FAKE_FAIL_START_VERSION"):
        running.write_text(str(installed / "Contents/MacOS/AgentStatusBoard"))
if tool == "swift":
    if os.environ.get("FAKE_BUILD_RC"):
        sys.exit(int(os.environ["FAKE_BUILD_RC"]))
    if "--show-bin-path" in args:
        print(os.environ["FAKE_SWIFT_BIN"])
elif tool == "codesign":
    sys.exit(int(os.environ.get("FAKE_SIGN_RC", "0")))
elif tool == "cp":
    sys.exit(int(os.environ["FAKE_COPY_RC"]) if os.environ.get("FAKE_COPY_RC") else
             subprocess.run(["/bin/cp", *args]).returncode)
elif tool == "pkill":
    running.unlink(missing_ok=True)
elif tool == "pgrep":
    if running.exists():
        print("9001")
    if os.environ.get("FAKE_FOREIGN_RUNNING"):
        print("9002")
    sys.exit(0 if running.exists() or os.environ.get("FAKE_FOREIGN_RUNNING") else 1)
elif tool == "ps":
    pid = args[args.index("-p") + 1]
    if pid == "9001" and running.exists():
        print(running.read_text())
    elif pid == "9002":
        print(os.environ["FAKE_FOREIGN_RUNNING"])
    else:
        sys.exit(1)
elif tool == "launchctl":
    if args[0] == "print":
        sys.exit(0)
    if args[0] == "bootout":
        running.unlink(missing_ok=True)
    elif args[0] in ("kickstart", "bootstrap", "load"):
        start()
elif tool == "open":
    start()
# log/lldb/sleep deliberately do nothing.
'''


class AppInstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.project = self.root / "project 'board'"
        self.home = self.root / "home 'board' & team"
        self.home.mkdir()
        self.log = self.root / "commands.jsonl"
        self.stubs = self.root / "stubs"
        self.stubs.mkdir()
        for tool in ["swift", "codesign", "cp", "pkill", "pgrep", "ps", "launchctl", "open", "log", "lldb", "sleep"]:
            p = self.stubs / tool
            p.write_text(STUB)
            p.chmod(0o755)
        for rel in ["script/build_and_run.sh", "script/agent-hooks/autostart.sh"]:
            target = self.project / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, target)
        (self.project / "VERSION").write_text("1.34\n")
        self.swift_bin = self.root / "swift-bin"
        self.swift_bin.mkdir()
        binary = self.swift_bin / "AgentStatusBoard"
        binary.write_text("#!/bin/bash\nexit 0\n")
        binary.chmod(0o755)
        self.running = self.root / "running"
        self.env = dict(os.environ, HOME=str(self.home), PATH=f"{self.stubs}:{os.environ['PATH']}",
                        FAKE_COMMAND_LOG=str(self.log), FAKE_RUNNING=str(self.running),
                        FAKE_SWIFT_BIN=str(self.swift_bin),
                        FAKE_INSTALLED=str(self.home / "Applications/AgentStatusBoard.app"))
        # Never inherit self-update-only settings from a developer's shell.
        for key in ["ASB_LEGACY_CHECKOUT_DIR", "ASB_UPDATE_STATUS_FILE", "APP_VERSION", "XPC_SERVICE_NAME"]:
            self.env.pop(key, None)
        self.staging = self.project / ".build/packaging/AgentStatusBoard.app"
        self.installed = self.home / "Applications/AgentStatusBoard.app"
        self.legacy = self.project / "dist/AgentStatusBoard.app"

    def tearDown(self):
        self.tmp.cleanup()

    def app(self, path, *, bundle_id=BUNDLE_ID, version="1.0"):
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle_id, "CFBundleShortVersionString": version}))
        binary = path / "Contents/MacOS/AgentStatusBoard"
        binary.write_text("#!/bin/bash\n# " + version + "\n")
        binary.chmod(0o755)

    def invoke(self, script, argument, *, rc=0, extra_env=None):
        result = subprocess.run(["/bin/bash", str(self.project / script), argument],
                                cwd=self.project, env=dict(self.env, **(extra_env or {})),
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=30)
        self.assertEqual(result.returncode, rc, result.stdout)
        return result

    def events(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_package_is_hidden_and_zip_remains_public(self):
        self.invoke("script/build_and_run.sh", "package")
        self.assertTrue(self.staging.is_dir())
        self.assertFalse(self.legacy.exists())
        self.assertFalse(self.installed.exists())
        archive = self.project / "dist/AgentStatusBoard-1.34.zip"
        with zipfile.ZipFile(archive) as z:
            self.assertIn("AgentStatusBoard.app/Contents/Info.plist", z.namelist())
        self.assertFalse(any(e["tool"] in ("pkill", "launchctl", "open") for e in self.events()))

    def test_all_launch_modes_use_stable_installation(self):
        for mode in ["run", "logs", "telemetry", "verify", "debug"]:
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                self.invoke("script/build_and_run.sh", mode)
                events = self.events()
                tools = [e["tool"] for e in events]
                self.assertLess(tools.index("swift"), tools.index("pkill"))
                self.assertLess(tools.index("codesign"), tools.index("pkill"))
                opens = [e["args"] for e in events if e["tool"] == "open"]
                if mode == "debug":
                    self.assertEqual(opens, [])
                    self.assertEqual([e["args"] for e in events if e["tool"] == "lldb"],
                                     [["--", str(self.installed / "Contents/MacOS/AgentStatusBoard")]])
                    self.assertNotIn("launchctl", tools)
                else:
                    self.assertEqual(opens, [[str(self.installed)]])
                plist = self.home / "Library/LaunchAgents/com.linkingdigital.agentstatusboard.plist"
                data = plistlib.loads(plist.read_bytes())
                self.assertEqual(data["ProgramArguments"], [str(self.installed / "Contents/MacOS/AgentStatusBoard")])

    def test_updater_is_bundled_for_future_git_install_updates(self):
        updater = self.project / "script/update.sh"
        updater.write_text("#!/bin/bash\n# current bundled updater\n")
        self.invoke("script/build_and_run.sh", "package")
        self.assertEqual((self.staging / "Contents/Resources/update.sh").read_bytes(), updater.read_bytes())

    def test_success_only_removes_verified_legacy_bundle(self):
        self.app(self.staging)
        self.app(self.legacy)
        dist = self.project / "dist"
        for name in ["AgentStatusBoard-1.31.zip", "business-notes.txt"]:
            (dist / name).write_text("keep " + name)
        self.app(dist / "Other.app", bundle_id="example.other")
        self.invoke("script/agent-hooks/autostart.sh", "on")
        self.assertFalse(self.legacy.exists())
        self.assertEqual((dist / "AgentStatusBoard-1.31.zip").read_text(), "keep AgentStatusBoard-1.31.zip")
        self.assertEqual((dist / "business-notes.txt").read_text(), "keep business-notes.txt")
        self.assertTrue((dist / "Other.app").exists())
        self.assertTrue(self.running.exists())

    def test_downloaded_build_can_clean_only_verified_original_checkout_bundle(self):
        self.app(self.staging)
        checkout = self.root / "original checkout 'board'"
        legacy = checkout / "dist/AgentStatusBoard.app"
        self.app(legacy)
        (legacy.parent / "keep.zip").write_bytes(b"unchanged")
        self.invoke("script/agent-hooks/autostart.sh", "on",
                    extra_env={"ASB_LEGACY_CHECKOUT_DIR": str(checkout)})
        self.assertFalse(legacy.exists())
        self.assertEqual((legacy.parent / "keep.zip").read_bytes(), b"unchanged")

    def test_foreign_legacy_bundle_is_preserved(self):
        self.app(self.staging)
        self.app(self.legacy, bundle_id="example.business")
        self.invoke("script/agent-hooks/autostart.sh", "on")
        self.assertTrue(self.legacy.is_dir())

    def test_invalid_legacy_plist_is_preserved(self):
        self.app(self.staging)
        self.app(self.legacy)
        (self.legacy / "Contents/Info.plist").write_text("business data")
        self.invoke("script/agent-hooks/autostart.sh", "on")
        self.assertTrue(self.legacy.is_dir())

    def test_legacy_bundle_symlink_is_preserved(self):
        self.app(self.staging)
        target = self.root / "outside.app"
        self.app(target)
        self.legacy.parent.mkdir()
        self.legacy.symlink_to(target, target_is_directory=True)
        self.invoke("script/agent-hooks/autostart.sh", "on")
        self.assertTrue(self.legacy.is_symlink())
        self.assertTrue(target.is_dir())

    def test_dist_symlink_is_preserved(self):
        self.app(self.staging)
        target = self.root / "outside-dist"
        self.app(target / "AgentStatusBoard.app")
        (self.project / "dist").symlink_to(target, target_is_directory=True)
        self.invoke("script/agent-hooks/autostart.sh", "on")
        self.assertTrue(self.legacy.exists())

    def test_failed_start_restores_previous_bundle_and_keeps_legacy(self):
        self.app(self.staging, version="new")
        self.app(self.installed, version="old")
        self.app(self.legacy)
        self.invoke("script/agent-hooks/autostart.sh", "on", rc=1, extra_env={"FAKE_FAIL_START_VERSION": "new"})
        data = plistlib.loads((self.installed / "Contents/Info.plist").read_bytes())
        self.assertEqual(data["CFBundleShortVersionString"], "old")
        self.assertTrue(self.legacy.is_dir())
        self.assertEqual(self.running.read_text(), str(self.installed / "Contents/MacOS/AgentStatusBoard"))
        starts = [e["args"][0] for e in self.events() if e["tool"] == "launchctl"]
        self.assertEqual(starts[-2:], ["bootout", "bootstrap"])
        self.assertFalse(list((self.home / "Applications").glob(".asb-install.*")))

    def test_legacy_same_job_rollback_uses_stable_open_without_bootout(self):
        self.app(self.staging, version="new")
        self.app(self.installed, version="old")
        self.invoke("script/agent-hooks/autostart.sh", "on", rc=1,
                    extra_env={"FAKE_FAIL_START_VERSION": "new", "XPC_SERVICE_NAME": "com.linkingdigital.agentstatusboard"})
        self.assertEqual(self.running.read_text(), str(self.installed / "Contents/MacOS/AgentStatusBoard"))
        self.assertFalse(any(e["tool"] == "launchctl" and e["args"][0] == "bootout" for e in self.events()))
        opens = [e["args"] for e in self.events() if e["tool"] == "open"]
        self.assertTrue(opens)
        self.assertTrue(all(args == [str(self.installed)] for args in opens))

    def test_failed_rollback_start_is_reported_with_failure_exit(self):
        self.app(self.staging, version="new")
        self.app(self.installed, version="old")
        result = self.invoke("script/agent-hooks/autostart.sh", "on", rc=1, extra_env={"FAKE_FAIL_START": "1"})
        self.assertIn("rollback: previous app restored", result.stdout)
        self.assertFalse(self.running.exists())
        self.assertEqual(plistlib.loads((self.installed / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"], "old")

    def test_foreign_process_with_matching_name_does_not_count_as_success(self):
        self.app(self.staging)
        self.app(self.legacy)
        self.invoke("script/agent-hooks/autostart.sh", "on", rc=1,
                    extra_env={"FAKE_FAIL_START": "1",
                               "FAKE_FOREIGN_RUNNING": str(self.legacy / "Contents/MacOS/AgentStatusBoard")})
        self.assertTrue(self.legacy.exists())
        self.assertFalse(self.running.exists())
        self.assertIn("ps", [e["tool"] for e in self.events()])

    def test_copy_failure_keeps_previous_app_and_process(self):
        self.app(self.staging)
        self.app(self.installed, version="old")
        self.running.touch()
        self.invoke("script/agent-hooks/autostart.sh", "on", rc=71, extra_env={"FAKE_COPY_RC": "71"})
        self.assertTrue(self.running.exists())
        self.assertNotIn("pkill", [e["tool"] for e in self.events()])
        self.assertEqual(plistlib.loads((self.installed / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"], "old")

    def test_invalid_staging_never_stops_previous_app(self):
        self.app(self.staging, bundle_id="example.foreign")
        self.running.touch()
        self.invoke("script/agent-hooks/autostart.sh", "on", rc=1)
        self.assertTrue(self.running.exists())
        self.assertNotIn("pkill", [e["tool"] for e in self.events()])

    def test_missing_staging_never_falls_back_to_legacy(self):
        self.app(self.legacy)
        self.invoke("script/agent-hooks/autostart.sh", "on", rc=1)
        self.assertTrue(self.legacy.exists())
        self.assertFalse(self.installed.exists())
        self.assertEqual(self.events(), [])

    def test_build_or_sign_failure_never_stops_previous_app(self):
        for key, rc in [("FAKE_BUILD_RC", 42), ("FAKE_SIGN_RC", 44)]:
            with self.subTest(key=key):
                self.log.unlink(missing_ok=True)
                self.running.touch()
                self.invoke("script/build_and_run.sh", "run", rc=rc, extra_env={key: str(rc)})
                self.assertTrue(self.running.exists())
                self.assertNotIn("pkill", [e["tool"] for e in self.events()])
                self.assertFalse(self.installed.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
