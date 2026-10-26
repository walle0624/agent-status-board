#!/usr/bin/env python3
"""Offline regression suite: the in-app self-update (script/update.sh) never rewrites a git checkout.

On 2026-10-15 a release made the installed app self-update, and update.sh rsynced
the downloaded main over the dev clone with --delete: every uncommitted edit and
every untracked and ignored file was lost. Each test runs a temp copy of update.sh
the way UpdateChecker does, against a temp checkout with a throwaway HOME. curl is
a stub. It serves a local zip of a fake release (built with `git archive`, as
GitHub builds it). That release's build_and_run.sh / autostart.sh only log that
they ran: no network, no swift build, no launchctl. Set UPDATE_SH=/path/to/update.sh
to run the suite against another copy of the script.
"""
import os
import json
import signal
import shutil
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

UPDATE = Path(os.environ.get("UPDATE_SH") or Path(__file__).resolve().parents[1] / "update.sh")
OWNER, REPO = "example", "agent-status-board"
VERSION_URL = f"https://raw.githubusercontent.com/{OWNER}/{REPO}/main/VERSION"
ZIP_URL = f"https://codeload.github.com/{OWNER}/{REPO}/zip/refs/heads/main"
SKIPPED = "源码未刷新"
SOURCE_JSON = '{"owner": "%s", "repo": "%s", "branch": "main"}\n' % (OWNER, REPO)
FAKE_CURL = r'''#!/bin/bash
# Stub curl: serves VERSION and the source zip from local fixtures, nothing else.
python3 - "$@" <<'PY'
import json, os, sys
with open(os.environ['FAKE_CURL_ARGS'], 'a') as out:
    out.write(json.dumps(sys.argv[1:]) + '\n')
PY
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
echo "curl $url" >> "$FAKE_LOG"
case "$url" in
  */VERSION)
    [ "${FAKE_VERSION_RC:-0}" = 0 ] || exit "$FAKE_VERSION_RC"
    if [ -n "${FAKE_VERSION_BODY:-}" ]; then printf '%s' "$FAKE_VERSION_BODY"; else cat "$FAKE_NEW/VERSION"; fi ;;
  */zip/refs/heads/*)
    [ "${FAKE_ARCHIVE_RC:-0}" = 0 ] || exit "$FAKE_ARCHIVE_RC"
    if [ "${FAKE_BLOCK_ARCHIVE:-0}" = 1 ]; then
      touch "$FAKE_BLOCKED"
      while [ ! -e "$FAKE_RELEASE" ]; do sleep 0.02; done
    fi
    cp "$FAKE_ZIP" "$out" ;;
  *) exit 22 ;;
esac
'''
LOGGER = '#!/bin/bash\necho "%s $*" >> "$FAKE_LOG"\nexit "${%s:-0}"\n'
RELEASE = {   # what the downloaded main contains
    "VERSION": "1.32\n",
    "update-source.json": SOURCE_JSON,
    "Package.swift": "// swift-tools-version:5.9\n",
    "Sources/App.swift": "// released in 1.32\n",
    "docs/guide.md": "released guide\n",
    "script/build_and_run.sh": LOGGER % ("build", "FAKE_BUILD_RC"),
    "script/agent-hooks/autostart.sh": LOGGER % ("autostart", "FAKE_INSTALL_RC"),
    "script/agent-hooks/record.sh": "#!/bin/bash\n# record.sh 1.32\n",
}
COMMITTED = {   # the dev clone at its last commit
    "VERSION": "1.31\n",
    "update-source.json": SOURCE_JSON,
    "Package.swift": "// swift-tools-version:5.9\n",
    ".gitignore": "PROJECT_MEMORY.md\n.build/\ndist/\n",
    "Sources/App.swift": "// committed in 1.31\n",
    "docs/guide.md": "committed guide\n",
}


class SelfUpdateTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name).resolve()     # /var -> /private/var, as git sees it
        self.home, self.log = self.root / "home", self.root / "fake.log"
        self.status = self.root / "status.json"
        self.lock = self.home / ".agent-status-board/update.lock"
        self.processes = []
        (self.root / "tmp").mkdir()
        # The app starts the updater from launchd, with no LANG/LC_*: match that.
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("GIT_", "LANG", "LC_")) and "proxy" not in k.lower()}
        env.update(HOME=str(self.home), TMPDIR=str(self.root / "tmp"),
                   PATH=f"{self.root / 'stubs'}:{os.environ['PATH']}",
                   FAKE_LOG=str(self.log), FAKE_NEW=str(self.root / "new"),
                   FAKE_ZIP=str(self.root / "src.zip"),
                   FAKE_CURL_ARGS=str(self.root / "curl-args.jsonl"),
                   FAKE_BLOCKED=str(self.root / "blocked"), FAKE_RELEASE=str(self.root / "release"),
                   ASB_UPDATE_STATUS_FILE=str(self.status),
                   GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
                   GIT_CEILING_DIRECTORIES=str(self.root),
                   GIT_AUTHOR_NAME="test", GIT_AUTHOR_EMAIL="test@example.invalid",
                   GIT_COMMITTER_NAME="test", GIT_COMMITTER_EMAIL="test@example.invalid",
                   # git archive stamps the commit time on every file. With a fixed time the
                   # release never shares a size+mtime with a fixture file (rsync would skip it).
                   GIT_AUTHOR_DATE="2026-10-15T15:04:56+08:00", GIT_COMMITTER_DATE="2026-10-15T15:04:56+08:00")
        # If a real curl ever ran, it would fail here instead of reaching GitHub.
        env.update(dict.fromkeys(["http_proxy", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"],
                                 "http://127.0.0.1:9"))
        self.env = env
        self.make_tree(self.root / "stubs", {"curl": FAKE_CURL})
        self.repo(self.root / "new", RELEASE)
        self.git(self.root / "new", "archive", "--format=zip", f"--prefix={REPO}-main/",
                 "-o", str(self.root / "src.zip"), "HEAD")
        self.make_tree(self.home / ".agent-status-board/bin", {"record.sh": "#!/bin/bash\n# record.sh 1.31\n"})

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=10)
        self._tmp.cleanup()

    # --- helpers --------------------------------------------------------------
    def make_tree(self, root, files):
        for rel, text in files.items():
            p = root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
            if text.startswith("#!"):
                p.chmod(0o755)

    def git(self, cwd, *args):
        return subprocess.run(["git", "-C", str(cwd), *args], env=self.env, check=True,
                              stdout=subprocess.PIPE, text=True).stdout

    def repo(self, root, files):
        self.make_tree(root, files)
        self.git(root, "init", "-q")
        self.git(root, "add", "-A")
        self.git(root, "commit", "-qm", "fixture")

    def files(self, root, skip=(".git",)):
        """{path: (bytes, mode, mtime_ns)} for every file under root, minus top-level dirs in skip."""
        out = {}
        for p in sorted(root.rglob("*")):
            rel = p.relative_to(root)
            if p.is_file() and rel.parts[0] not in skip:
                st = p.stat()
                out[str(rel)] = (p.read_bytes(), stat.S_IMODE(st.st_mode), st.st_mtime_ns)
        return out

    def state(self, checkout):
        """Every file outside .git, plus git's view: HEAD, the index, status with ignored files."""
        return (self.files(checkout), self.git(checkout, "rev-parse", "HEAD"),
                self.git(checkout, "ls-files", "--stage"),
                self.git(checkout, "status", "--porcelain", "--ignored", "--untracked-files=all"))

    def run_update(self, checkout, *, expected_rc=0, extra_args=(), env=None):
        script = self.root / "asb-update.sh"     # UpdateChecker runs a temp copy, passing the checkout
        shutil.copy(UPDATE, script)
        result = subprocess.run(["/bin/bash", str(script), str(checkout), *extra_args], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                env=env or self.env, encoding="utf-8", timeout=120)
        self.assertEqual(result.returncode, expected_rc, result.stdout)
        return result

    def update(self, checkout):
        result = self.run_update(checkout)
        self.assertIn("✅ 已更新到 1.32", result.stdout)
        return result.stdout

    def checkout(self, name="AgentStatusBoard"):
        checkout = self.root / name
        self.repo(checkout, COMMITTED)
        return checkout

    def assert_status(self, phase, *, rc=None, failed_phase=None, path=None):
        path = path or self.status
        status = json.loads(path.read_text())
        self.assertEqual(status["phase"], phase)
        self.assertGreater(status["updatedAt"], time.time() - 120)
        self.assertGreater(status["pid"], 0)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        if rc is not None:
            self.assertEqual(status["exitCode"], rc)
        else:
            self.assertNotIn("exitCode", status)
        if failed_phase:
            self.assertEqual(status["failedPhase"], failed_phase)
        self.assertFalse(list(path.parent.glob(".asb-update-*")))
        return status

    def start_blocked_update(self, checkout):
        script = self.root / "blocking-update.sh"
        shutil.copy(UPDATE, script)
        env = dict(self.env, FAKE_BLOCK_ARCHIVE="1")
        process = subprocess.Popen(["/bin/bash", str(script), str(checkout)], env=env,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, start_new_session=True)
        self.processes.append(process)
        deadline = time.monotonic() + 10
        while not Path(env["FAKE_BLOCKED"]).exists():
            if process.poll() is not None or time.monotonic() > deadline:
                self.fail("fixture did not reach download phase")
            time.sleep(0.01)
        return process

    def assert_installed(self):
        """The release was fetched from the stub, built, installed, and its hook copies refreshed."""
        self.assertEqual(self.log.read_text().splitlines(),
                         [f"curl {VERSION_URL}", f"curl {ZIP_URL}", "build package", "autostart on"])
        self.assertEqual((self.home / ".agent-status-board/bin/record.sh").read_text(),
                         RELEASE["script/agent-hooks/record.sh"])

    # --- tests ----------------------------------------------------------------
    def test_dirty_git_checkout_survives(self):
        checkout = self.root / "AgentStatusBoard"
        self.repo(checkout, COMMITTED)
        (checkout / "Sources/App.swift").write_text("// uncommitted edit\n")
        self.make_tree(checkout, {"Sources/Staged.swift": "// staged, not committed\n",
                                  "Tests/NewTests.swift": "// untracked\n",
                                  "PROJECT_MEMORY.md": "ignored local memory\n"})
        self.git(checkout, "add", "Sources/Staged.swift")
        (checkout / "docs/guide.md").unlink()     # the release still has it
        before = self.state(checkout)
        for line in (" M Sources/App.swift", "A  Sources/Staged.swift", " D docs/guide.md",
                     "?? Tests/NewTests.swift", "!! PROJECT_MEMORY.md"):
            self.assertIn(line, before[3].splitlines())

        out = self.update(checkout)
        self.assertEqual(self.state(checkout), before)
        self.assertIn(SKIPPED, out)
        self.assert_installed()

    def test_checkout_inside_another_work_tree_survives(self):
        # No .git of its own: only `git rev-parse --is-inside-work-tree` can tell.
        outer = self.root / "dotfiles"
        self.repo(outer, {"README.md": "outer repo\n"})
        checkout = outer / "tools/agent-status-board"
        self.make_tree(checkout, {"VERSION": "1.31\n", "update-source.json": SOURCE_JSON,
                                  "Package.swift": "// swift-tools-version:5.9\n",
                                  "Sources/App.swift": "// local edit\n", "notes.md": "local only\n"})
        before = self.state(checkout)

        out = self.update(checkout)
        self.assertEqual(self.state(checkout), before)
        self.assertIn(SKIPPED, out)
        self.assert_installed()

    def test_zip_install_is_still_refreshed(self):
        checkout = self.root / "agent-status-board"
        self.make_tree(checkout, {"VERSION": "1.31\n", "update-source.json": SOURCE_JSON,
                                  "Package.swift": "// swift-tools-version:5.9\n",
                                  "Sources/App.swift": "// 1.31\n",
                                  "Sources/Dropped.swift": "// removed in 1.32\n",
                                  ".build/release/cache": "kept\n", "dist/AgentStatusBoard.app/Info.plist": "kept\n"})

        self.assertNotIn(SKIPPED, self.update(checkout))
        # Mirrors the release, stale files deleted, build dirs kept: same as before the fix.
        def content(root, skip):
            return {k: (data, bool(mode & 0o100)) for k, (data, mode, _) in self.files(root, skip).items()}
        self.assertEqual(content(checkout, (".build", "dist")), content(self.root / "new", (".git",)))
        self.assertEqual((checkout / ".build/release/cache").read_text(), "kept\n")
        self.assertEqual((checkout / "dist/AgentStatusBoard.app/Info.plist").read_text(), "kept\n")
        self.assert_installed()


    def test_status_and_bounded_download_arguments(self):
        self.update(self.checkout())
        status = self.assert_status("completed")
        self.assertEqual(status["version"], "1.32")
        self.assertFalse(self.lock.exists())
        calls = [json.loads(line) for line in (self.root / "curl-args.jsonl").read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        for args, maximum in zip(calls, ["30", "180"]):
            self.assertEqual(args[args.index("--connect-timeout") + 1], "10")
            self.assertEqual(args[args.index("--max-time") + 1], maximum)
            self.assertEqual(args[args.index("--retry") + 1], "2")
            self.assertGreater(int(args[args.index("--retry-max-time") + 1]), 0)

    def test_version_failure_is_not_up_to_date(self):
        result = self.run_update(self.checkout(), expected_rc=28, extra_args=("--check",),
                                 env=dict(self.env, FAKE_VERSION_RC="28"))
        self.assertNotIn("up-to-date", result.stdout)
        self.assert_status("failed", rc=28, failed_phase="checking")
        self.assertFalse(self.lock.exists())

    def test_invalid_version_fails_check(self):
        self.run_update(self.checkout(), expected_rc=65,
                        env=dict(self.env, FAKE_VERSION_BODY="<html>proxy error</html>"))
        self.assert_status("failed", rc=65, failed_phase="checking")
        self.assertNotIn("build package", self.log.read_text())

    def test_archive_download_failure_keeps_checkout(self):
        checkout = self.checkout()
        before = self.state(checkout)
        self.run_update(checkout, expected_rc=22, env=dict(self.env, FAKE_ARCHIVE_RC="22"))
        self.assert_status("failed", rc=22, failed_phase="downloading")
        self.assertEqual(self.state(checkout), before)
        self.assertNotIn("build package", self.log.read_text())
        self.assertFalse(self.lock.exists())

    def test_build_failure_never_installs(self):
        checkout = self.checkout()
        old = self.home / "Applications/AgentStatusBoard.app/old-binary"
        old.parent.mkdir(parents=True)
        old.write_text("working version")
        self.run_update(checkout, expected_rc=42, env=dict(self.env, FAKE_BUILD_RC="42"))
        self.assert_status("failed", rc=42, failed_phase="building")
        self.assertNotIn("autostart on", self.log.read_text())
        self.assertEqual(old.read_text(), "working version")
        self.assertFalse(self.lock.exists())

    def test_install_failure_does_not_refresh_hooks_or_checkout(self):
        checkout = self.checkout()
        before = self.state(checkout)
        self.run_update(checkout, expected_rc=43, env=dict(self.env, FAKE_INSTALL_RC="43"))
        self.assert_status("failed", rc=43, failed_phase="installing")
        self.assertEqual(self.state(checkout), before)
        self.assertIn("record.sh 1.31", (self.home / ".agent-status-board/bin/record.sh").read_text())
        self.assertFalse(self.lock.exists())

    def test_refresh_failure_is_reported(self):
        self.make_tree(self.root / "stubs", {"cp": '''#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = "$HOME/.agent-status-board/bin/record.sh" ]; then exit 73; fi
done
exec /bin/cp "$@"
'''})
        self.run_update(self.checkout(), expected_rc=73)
        self.assert_status("failed", rc=73, failed_phase="refreshing")
        self.assertFalse(self.lock.exists())

    def test_paths_with_spaces_and_quotes(self):
        status = self.root / "progress 'board'" / "update 'one'.json"
        checkout = self.checkout("Agent's status board")
        before = self.state(checkout)
        self.run_update(checkout, env=dict(self.env, ASB_UPDATE_STATUS_FILE=str(status)))
        self.assert_status("completed", path=status)
        self.assertEqual(self.state(checkout), before)

    def test_status_file_is_optional(self):
        env = dict(self.env)
        env.pop("ASB_UPDATE_STATUS_FILE")
        self.run_update(self.checkout(), env=env)
        self.assertFalse(self.status.exists())
        self.assertFalse(self.lock.exists())

    def test_active_updater_is_busy_and_cannot_release_owner_lock(self):
        checkout = self.checkout()
        first = self.start_blocked_update(checkout)
        owner = (self.lock / "owner.json").read_text()
        second_status = self.root / "busy.json"
        self.run_update(checkout, expected_rc=75,
                        env=dict(self.env, ASB_UPDATE_STATUS_FILE=str(second_status)))
        self.assert_status("failed", rc=75, failed_phase="checking", path=second_status)
        self.assertEqual((self.lock / "owner.json").read_text(), owner)
        self.assertEqual(json.loads(owner)["pid"], first.pid)
        Path(self.env["FAKE_RELEASE"]).touch()
        output = first.communicate(timeout=20)[0]
        self.assertEqual(first.returncode, 0, output)
        self.assert_status("completed")
        self.assertFalse(self.lock.exists())
        self.assertEqual(self.log.read_text().count("build package"), 1)

    def test_dead_owner_lock_is_recovered(self):
        dead = subprocess.Popen(["/bin/bash", "-c", "exit 0"])
        dead.wait()
        self.lock.mkdir()
        (self.lock / "owner.json").write_text(json.dumps({"pid": dead.pid, "token": "old"}))
        self.update(self.checkout())
        self.assertFalse(self.lock.exists())

    def test_abandoned_empty_lock_is_recovered(self):
        self.lock.mkdir()
        os.utime(self.lock, (time.time() - 60, time.time() - 60))
        self.update(self.checkout())
        self.assertFalse(self.lock.exists())

    def test_term_reports_real_signal_code_and_releases_lock(self):
        process = self.start_blocked_update(self.checkout())
        os.killpg(process.pid, signal.SIGTERM)
        output = process.communicate(timeout=10)[0]
        self.assertEqual(process.returncode, 143, output)
        self.assert_status("failed", rc=143, failed_phase="downloading")
        self.assertFalse(self.lock.exists())

    def test_broken_git_link_still_protects_source(self):
        checkout = self.root / "broken-worktree"
        self.make_tree(checkout, COMMITTED)
        (checkout / ".git").symlink_to(self.root / "missing-git-dir")
        before = self.files(checkout)
        self.assertIn(SKIPPED, self.update(checkout))
        self.assertEqual(self.files(checkout), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
