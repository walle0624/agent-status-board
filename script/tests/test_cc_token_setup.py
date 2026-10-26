#!/usr/bin/env python3
"""Offline regression suite: every setup-token/--version call targets a fake CLI."""
import json
import os
import pty
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "agent-hooks/cc-token-setup.sh"
TOKEN = "sk-ant-oat01-" + "offline_TestToken_0123456789-" * 4
OTHER_TOKEN = "sk-ant-oat01-" + "offline_OtherToken_0123456789-" * 4
SECRET_CODE = "SHORTsecret42"
SECRET_ACCOUNT = "private.person@example.test"
AUTH_URL = ("https://claude.ai/oauth/authorize?client_id=fake-client&response_type=code"
            "&redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcallback&scope=user%3Aprofile"
            "&code_challenge=fake_challenge&code_challenge_method=S256&state=fake_state&code=true")
FAKE = r'''
import os, signal, sys, time
from pathlib import Path
if sys.argv[1:] == ["--version"]:
    print(os.environ.get("FAKE_VERSION", "2.4.0") + " (Claude Code)")
    sys.exit(0)
if sys.argv[1:] != ["setup-token"]:
    sys.exit(97)
mode = os.environ.get("FAKE_MODE", "success")
Path(os.environ["FAKE_PID_FILE"]).write_text(str(os.getpid()))
token = os.environ["FAKE_TOKEN"]
code = os.environ["FAKE_CODE"]
if mode == "timeout":
    Path(os.environ["FAKE_PID_FILE"]).write_text(str(os.getpid()))
    print("Error: request timed out " + code + " " + token, flush=True)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(30)
elif mode == "nonzero":
    print("Error: HTTP 403 OAuth authentication is currently not allowed for this organization. "
          + os.environ["FAKE_ACCOUNT"] + " authorization code=" + code, flush=True)
    print("Error: ECONNREFUSED https://example.test/callback?code=" + code, flush=True)
    print(token, flush=True)
    sys.exit(23)
elif mode == "signal":
    os.kill(os.getpid(), signal.SIGTERM)
elif mode == "no_token":
    print("Error: invalid_grant authorization code=" + code, flush=True)
elif mode == "no_newline_error":
    sys.stdout.write("Error: HTTP 401 invalid_grant " + code)
    sys.stdout.flush()
    sys.exit(7)
elif mode == "two_tokens":
    print(token, flush=True)
    print(os.environ["FAKE_OTHER_TOKEN"], flush=True)
elif mode == "ansi_chunks":
    # ANSI escapes and token characters cross PTY read boundaries; repeat token.
    content = "\x1b[32m" + token[:40] + "\x1b[0m" + token[40:] + "\n" + token + "\n"
    for char in content:
        os.write(1, char.encode())
        time.sleep(0.001)
elif mode == "callback":
    url = os.environ["FAKE_AUTH_URL"]
    for part in ("\x1b[36m" + url[:80], url[80:160], url[160:] + "\x1b[0m\n"):
        os.write(1, part.encode())
        time.sleep(0.02)
    flag = Path(os.environ["FAKE_CALLBACK_FILE"])
    while not flag.exists():
        time.sleep(0.01)
    print(token, flush=True)
elif mode == "manual":
    print("Paste authorization code:", flush=True)
    value = input()
    if value != code:
        sys.exit(24)
    print("Error: received authorization code=" + value, flush=True)
    print(token, flush=True)
elif mode == "unsafe_url":
    print(os.environ["FAKE_AUTH_URL"] + "&access_token=" + token, flush=True)
    print("https://claude.ai/oauth/authorize?client_id=fake&response_type=code"
          "&state=fake&code_challenge=fake&code=" + code, flush=True)
    print(token, flush=True)
else:
    print(os.environ["FAKE_AUTH_URL"], flush=True)
    print(token, flush=True)
'''


class TokenSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="asb-token-offline-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.fake = self.root / "fake-claude"
        self.write_fake(self.fake)
        self.target = self.home / ".agent-status-board/cc-token.json"
        self.target.parent.mkdir(mode=0o700)
        self.old_contents = b'{"token":"previous-placeholder"}\n'
        self.target.write_bytes(self.old_contents)
        self.target.chmod(0o600)
        self.old_stat = self.target.stat()
        self.env = dict(os.environ, HOME=str(self.home), ASB_CLAUDE_BIN=str(self.fake),
                        ASB_TOKEN_SETUP_TIMEOUT="3", FAKE_MODE="success", FAKE_TOKEN=TOKEN,
                        FAKE_OTHER_TOKEN=OTHER_TOKEN, FAKE_CODE=SECRET_CODE,
                        FAKE_ACCOUNT=SECRET_ACCOUNT, FAKE_AUTH_URL=AUTH_URL,
                        FAKE_PID_FILE=str(self.root / "pid"),
                        FAKE_CALLBACK_FILE=str(self.root / "callback"))

    def write_fake(self, path, version=None):
        path.parent.mkdir(parents=True, exist_ok=True)
        prefix = "#!" + sys.executable + "\n"
        if version is not None:
            prefix += "import os\nos.environ['FAKE_VERSION'] = " + repr(version) + "\n"
        path.write_text(prefix + FAKE)
        path.chmod(0o755)

    def run_script(self, mode, **overrides):
        env = dict(self.env, FAKE_MODE=mode, **overrides)
        result = subprocess.run(["/bin/bash", str(SCRIPT)], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                env=env, timeout=10, text=True)
        self.assert_private(result.stdout)
        return result

    def assert_private(self, output):
        for secret in (TOKEN, OTHER_TOKEN, SECRET_CODE, SECRET_ACCOUNT):
            self.assertNotIn(secret, output)
        self.assertNotIn("sk-ant-oat", output)

    def assert_old_unchanged(self):
        self.assertEqual(self.old_contents, self.target.read_bytes())
        now = self.target.stat()
        self.assertEqual(self.old_stat.st_ino, now.st_ino)
        self.assertEqual(self.old_stat.st_mtime_ns, now.st_mtime_ns)
        self.assertEqual(stat.S_IMODE(self.old_stat.st_mode), stat.S_IMODE(now.st_mode))
        self.assertEqual([], list(self.target.parent.glob(".cc-token-*")))

    def assert_saved(self):
        self.assertEqual({"token": TOKEN}, json.loads(self.target.read_text()))
        self.assertEqual(0o600, stat.S_IMODE(self.target.stat().st_mode))
        self.assertNotEqual(self.old_stat.st_ino, self.target.stat().st_ino)
        self.assertEqual([], list(self.target.parent.glob(".cc-token-*")))

    def test_success_atomically_saves_private_token(self):
        result = self.run_script("success")
        self.assertEqual(0, result.returncode, result.stdout)
        self.assertIn(AUTH_URL, result.stdout)
        self.assertIn("ASB_CC_TOKEN_SAVED", result.stdout)
        self.assert_saved()

    def test_nonzero_preserves_real_status_and_redacted_diagnosis(self):
        result = self.run_script("nonzero")
        self.assertEqual(23, result.returncode, result.stdout)
        self.assertIn("403", result.stdout)
        self.assertIn("ECONNREFUSED", result.stdout)
        self.assertIn("当前组织不允许 OAuth", result.stdout)
        self.assertIn("[redacted]", result.stdout)
        self.assertNotIn("ASB_CC_TOKEN_SAVED", result.stdout)
        self.assert_old_unchanged()

    def test_exit_zero_without_token_fails_cleanly(self):
        result = self.run_script("no_token")
        self.assertEqual(1, result.returncode, result.stdout)
        self.assertIn("CLI 退出码 0", result.stdout)
        self.assert_old_unchanged()

    def test_unterminated_error_line_still_has_safe_diagnostics(self):
        result = self.run_script("no_newline_error")
        self.assertEqual(7, result.returncode, result.stdout)
        self.assertIn("401", result.stdout)
        self.assertIn("invalid_grant", result.stdout)
        self.assertIn("[redacted]", result.stdout)
        self.assert_old_unchanged()

    def test_ansi_repeated_and_chunked_token_never_leaks(self):
        result = self.run_script("ansi_chunks")
        self.assertEqual(0, result.returncode, result.stdout)
        self.assert_saved()

    def test_conflicting_tokens_fail_without_overwriting(self):
        result = self.run_script("two_tokens")
        self.assertEqual(1, result.returncode, result.stdout)
        self.assert_old_unchanged()

    def test_timeout_kills_cli_and_keeps_previous_file(self):
        started = time.monotonic()
        result = self.run_script("timeout", ASB_TOKEN_SETUP_TIMEOUT="0.3")
        self.assertEqual(124, result.returncode, result.stdout)
        self.assertLess(time.monotonic() - started, 3)
        self.assert_old_unchanged()
        pid = int((self.root / "pid").read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_cli_signal_status_is_preserved(self):
        result = self.run_script("signal")
        self.assertEqual(143, result.returncode, result.stdout)
        self.assert_old_unchanged()

    def test_token_or_code_in_authorize_url_is_never_relayed(self):
        result = self.run_script("unsafe_url")
        self.assertEqual(0, result.returncode, result.stdout)
        self.assertNotIn("https://", result.stdout)
        self.assert_saved()

    def test_noninteractive_link_streams_before_callback_completion(self):
        env = dict(self.env, FAKE_MODE="callback")
        process = subprocess.Popen(["/bin/bash", str(SCRIPT)], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        try:
            output = self.read_until(process.stdout.fileno(), AUTH_URL.encode())
            self.assertIsNone(process.poll(), "CLI must still be waiting when URL is visible")
            Path(env["FAKE_CALLBACK_FILE"]).write_text("simulated callback complete")
            tail, _ = process.communicate(timeout=5)
            output += tail
            self.assertEqual(0, process.returncode, output.decode())
            self.assert_private(output.decode())
            self.assert_saved()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()

    def test_wrapper_cancellation_cleans_cli_and_keeps_previous_file(self):
        env = dict(self.env, FAKE_MODE="callback")
        process = subprocess.Popen(["/bin/bash", str(SCRIPT)], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   env=env, start_new_session=True)
        try:
            output = self.read_until(process.stdout.fileno(), AUTH_URL.encode())
            process.send_signal(signal.SIGTERM)
            tail, _ = process.communicate(timeout=5)
            output += tail
            self.assertEqual(143, process.returncode, output.decode())
            self.assert_private(output.decode())
            self.assert_old_unchanged()
            pid = int((self.root / "pid").read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()

    def test_interactive_manual_code_is_forwarded_without_echo(self):
        master, slave = pty.openpty()
        env = dict(self.env, FAKE_MODE="manual")
        process = subprocess.Popen(["/bin/bash", str(SCRIPT)], stdin=slave,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        os.close(slave)
        try:
            output = self.read_until(process.stdout.fileno(), "输入隐藏".encode())
            # The wrapper only announces this marker after disabling echo.
            os.write(master, SECRET_CODE.encode() + b"\n")
            tail, _ = process.communicate(timeout=5)
            output += tail
            self.assertEqual(0, process.returncode, output.decode())
            self.assert_private(output.decode())
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    self.assertNotIn(SECRET_CODE.encode(), os.read(master, 4096))
                except OSError:
                    pass
            self.assert_saved()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
            os.close(master)

    @staticmethod
    def read_until(fd, marker):
        output = b""
        deadline = time.monotonic() + 5
        while marker not in output:
            if time.monotonic() >= deadline:
                raise AssertionError("Expected safe streaming marker did not appear")
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                chunk = os.read(fd, 65536)
                if not chunk:
                    raise AssertionError("Process ended before safe streaming marker")
                output += chunk
        return output

    def test_default_discovery_selects_newer_recursive_desktop_version(self):
        path_bin = self.root / "path-bin"
        path_bin.mkdir()
        (path_bin / "python3").symlink_to(sys.executable)
        self.write_fake(path_bin / "claude", "2.9.0")
        desktop = self.home / "Library/Application Support/Claude/claude-code"
        older = desktop / "newest-looking-directory/claude.app/Contents/MacOS/claude"
        newer = desktop / "nested/releases/old-looking-directory/bin/claude"
        self.write_fake(older, "2.8.0")
        self.write_fake(newer, "2.10.0")
        os.utime(older, (time.time() + 1000,) * 2)
        os.utime(newer, (1, 1))
        self.env.pop("ASB_CLAUDE_BIN")
        result = self.run_script("success", PATH=str(path_bin))
        self.assertEqual(0, result.returncode, result.stdout)
        self.assertIn("桌面内置 CLI 2.10.0", result.stdout)
        self.assert_saved()

    def test_invalid_override_and_timeout_do_not_touch_token(self):
        for overrides in ({"ASB_CLAUDE_BIN": str(self.root / "missing")},
                          {"ASB_TOKEN_SETUP_TIMEOUT": "not-a-number"},
                          {"ASB_TOKEN_SETUP_TIMEOUT": "nan"}):
            with self.subTest(overrides=overrides):
                result = self.run_script("success", **overrides)
                self.assertEqual(1, result.returncode, result.stdout)
                self.assert_old_unchanged()


if __name__ == "__main__":
    unittest.main(verbosity=2)
