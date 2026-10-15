#!/usr/bin/env python3
"""Offline regression suite for install.sh / uninstall.sh editing ~/.codex/config.toml.

Every run uses a throwaway HOME. Fixtures mimic what Codex and Computer Use
really write (multi-line chained notify, "double-quoted" hooks without our
markers, [hooks.state] followed by more tables). Results are checked with the
Codex CLI when it is installed (override with CODEX_CLI=/path/to/codex).
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
HOOKS = Path(__file__).resolve().parents[1] / "agent-hooks"
sys.path.insert(0, str(HOOKS))
import codex_toml  # noqa: E402

INSTALL, UNINSTALL = HOOKS / "install.sh", HOOKS / "uninstall.sh"
CODEX_CLI = os.environ.get(
    "CODEX_CLI", "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
EVENTS = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PreCompact", "PostCompact",
          "PermissionRequest", "Stop"]
MARK, END = "# >>> agent-status-board hooks >>>", "# <<< agent-status-board hooks <<<"
ROOT = 'model = "gpt-5"\nsandbox_mode = "workspace-write"\n'
TABLES = '''
[projects."/Users/example/project"]
trust_level = "trusted"

[features]
multi_agent = true
'''
TAIL = '''
[shell_environment_policy]
inherit = "core"

[shell_environment_policy.set]
EXAMPLE = "1"

[[skills.config]]
path = "/Users/example/.codex/skills/example/SKILL.md"
enabled = false

[mcp_servers.example]
command = "/usr/bin/true"
args = ["mcp"]

[mcp_servers.example.env]
EXAMPLE_ENV = "1"
'''


class CodexConfigTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name)
        (self.home / ".codex").mkdir()
        (self.home / ".claude").mkdir()
        self.cfg = self.home / ".codex/config.toml"
        self.orig = self.home / ".agent-status-board/codex-notify-original.json"
        bin_dir = self.home / ".agent-status-board/bin"
        self.hook, self.wrapper = f"{bin_dir}/codex-hook.sh", f"{bin_dir}/codex-notify.sh"
        self.sky = (f"{self.home}/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/"
                    "SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient")

    def tearDown(self):
        self._tmp.cleanup()

    # --- fixtures -------------------------------------------------------------
    def chained_notify(self):
        """Computer Use's rewrite: it runs first, then our wrapper (JSON-escaped)."""
        return ('notify = [\n    "%s",\n    "turn-ended",\n    "--previous-notify",\n'
                "    '[\"%s\"]',\n]\n") % (self.sky, self.wrapper.replace("/", "\\/"))

    def unchained_notify(self):
        """What uninstall makes of chained_notify() when no original notify was saved."""
        return 'notify = ["%s", "turn-ended"]\n' % self.sky

    def codex_saved_hooks(self, events=EVENTS):
        """Our hooks as Codex re-saves them: "double quotes", marker comments gone."""
        return "".join('\n[[hooks.%s]]\n\n[[hooks.%s.hooks]]\ntype = "command"\n'
                       'command = "%s %s"\ntimeout = 10\n' % (e, e, self.hook, e) for e in events)

    def hooks_state(self):
        return ('\n[hooks.state]\n\n[hooks.state."%s/.codex/config.toml:stop:0:0"]\n'
                'trusted_hash = "sha256:%s"\n') % (self.home, "0" * 64)

    def legacy_fenced_hooks(self):
        """What install.sh <= v1.31 wrote, with Codex's trust table inside the fence."""
        lines = [MARK]
        for e in EVENTS:
            lines += ["[[hooks.%s]]" % e, "[[hooks.%s.hooks]]" % e, 'type = "command"',
                      "command = '%s %s'" % (self.hook, e), "timeout = 10", ""]
        return "\n" + "\n".join(lines) + self.hooks_state() + END + "\n"

    # --- helpers --------------------------------------------------------------
    def write(self, text):
        self.cfg.write_text(text)
        return text

    def run_script(self, script):
        env = dict(os.environ, HOME=str(self.home), PYTHONDONTWRITEBYTECODE="1")
        result = subprocess.run(["/bin/bash", str(script)], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                env=env, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def backups(self):
        return sorted(self.cfg.parent.glob("config.toml.bak.*"))

    def notify_args(self, text):
        stmts = codex_toml.statements(text)
        self.assertEqual([s.head for s in stmts if s.head == "notify"], ["notify"])
        return codex_toml.str_array(codex_toml.root_key(stmts, "notify").value)

    def assert_codex_loads(self, text):
        self.assertEqual(codex_toml.duplicates(codex_toml.statements(text)), [])
        if not os.access(CODEX_CLI, os.X_OK):
            return
        with tempfile.TemporaryDirectory() as codex_home:
            Path(codex_home, "config.toml").write_text(text)
            result = subprocess.run([CODEX_CLI, "mcp", "list"], stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=120,
                                    env=dict(os.environ, CODEX_HOME=codex_home))
            self.assertEqual(result.returncode, 0, result.stderr)

    def assert_wired_once(self, text):
        self.assertIn("codex-notify.sh", "".join(self.notify_args(text)))
        commands = [codex_toml.toml_str(s.value) for s in codex_toml.statements(text)
                    if s.head == "command"]
        for e in EVENTS:
            self.assertEqual(commands.count(f"{self.hook} {e}"), 1, e)
        self.assert_codex_loads(text)

    # --- install --------------------------------------------------------------
    def test_codex_and_computer_use_rewrites_count_as_wired(self):
        before = self.write(ROOT + self.chained_notify() + TABLES + self.codex_saved_hooks()
                            + self.hooks_state() + TAIL)
        out = self.run_script(INSTALL)
        self.assertIn("Codex hooks 已就绪，未改动", out)
        self.assertEqual(self.cfg.read_text(), before)
        self.assertEqual(self.backups(), [])
        self.assertFalse(self.orig.exists())

    def test_legacy_fenced_install_counts_as_wired(self):
        before = self.write(ROOT + 'notify = ["%s"]\n' % self.wrapper + TABLES + TAIL
                            + self.legacy_fenced_hooks())
        self.assertIn("Codex hooks 已就绪，未改动", self.run_script(INSTALL))
        self.assertEqual(self.cfg.read_text(), before)

    def test_fresh_config_gets_one_notify_and_one_set_of_hooks(self):
        self.write(ROOT + TABLES + TAIL)
        self.assertIn("wired Codex hooks", self.run_script(INSTALL))
        wired = self.cfg.read_text()
        self.assert_wired_once(wired)
        self.assertEqual(self.notify_args(wired), [self.wrapper])
        self.assertEqual(len(self.backups()), 1)

        self.assertIn("已就绪", self.run_script(INSTALL))           # idempotent
        self.assertEqual(self.cfg.read_text(), wired)
        self.assertEqual(len(self.backups()), 1)

        # Codex drops our markers on save; Computer Use chains our notify.
        resaved = wired.replace(MARK + "\n", "").replace(END + "\n", "")
        resaved = self.write(re.sub(r"(?m)^notify = .*\n", lambda _: self.chained_notify(), resaved))
        self.assertIn("已就绪", self.run_script(INSTALL))
        self.assertEqual(self.cfg.read_text(), resaved)

    def test_missing_hooks_are_appended_without_touching_the_rest(self):
        before = self.write(ROOT + self.chained_notify() + TABLES
                            + self.codex_saved_hooks(EVENTS[:-1]) + self.hooks_state() + TAIL)
        self.run_script(INSTALL)
        after = self.cfg.read_text()
        self.assertTrue(after.startswith(before.rstrip()))
        self.assertEqual(re.findall(r"\[\[hooks\.(\w+)\]\]", after[len(before.rstrip()):]), ["Stop"])
        self.assert_wired_once(after)

    def test_existing_notify_is_saved_and_wrapped(self):
        cases = {
            "single line": ('notify = ["%s", "turn-ended"]\n' % self.sky, [self.sky, "turn-ended"]),
            "multi-line": ('notify = [\n  "/usr/local/bin/notifier",  # ] in a comment\n'
                           "  '--flag=[x]',\n]\n", ["/usr/local/bin/notifier", "--flag=[x]"]),
        }
        for name, (notify, original) in cases.items():
            with self.subTest(name):
                self.write(ROOT + notify + TABLES)
                self.run_script(INSTALL)
                wired = self.cfg.read_text()
                self.assertEqual(self.notify_args(wired), [self.wrapper])
                self.assertEqual(json.loads(self.orig.read_text()), original)
                self.assert_wired_once(wired)

    def test_already_broken_config_is_left_alone(self):
        before = self.write(ROOT + self.chained_notify() + 'notify = ["%s"]\n' % self.wrapper
                            + TABLES + TAIL + TAIL)
        out = self.run_script(INSTALL)
        self.assertIn("不是合法 TOML", out)
        self.assertEqual(self.cfg.read_text(), before)
        self.assertEqual(self.backups(), [])

    # --- uninstall ------------------------------------------------------------
    def test_uninstall_removes_what_a_fresh_install_added(self):
        before = self.write(ROOT + TABLES + TAIL)
        self.run_script(INSTALL)
        self.run_script(UNINSTALL)
        after = self.cfg.read_text()
        self.assertNotIn("notify", after)
        self.assertNotIn("codex-hook.sh", after)
        heads = lambda t: [s.head for s in codex_toml.statements(t) if s.value is None]
        self.assertEqual(heads(after), heads(before))
        self.assert_codex_loads(after)

    def test_uninstall_restores_notify(self):
        sky = [self.sky, "turn-ended"]
        cases = [   # (notify in config, saved original, expected notify)
            ("chained", None, sky),
            ("chained", sky, sky),
            ("chained", ["/usr/local/bin/notifier"],
             sky + ["--previous-notify", '["/usr/local/bin/notifier"]']),
            ("wrapper", sky, sky),
        ]
        for kind, original, expected in cases:
            with self.subTest(kind=kind, original=original):
                notify = (self.chained_notify() if kind == "chained"
                          else 'notify = ["%s"]\n' % self.wrapper)
                self.write(ROOT + notify + TABLES + self.codex_saved_hooks() + TAIL)
                if original:
                    self.orig.parent.mkdir(parents=True, exist_ok=True)
                    self.orig.write_text(json.dumps(original))
                elif self.orig.exists():
                    self.orig.unlink()
                self.run_script(UNINSTALL)
                after = self.cfg.read_text()
                self.assertEqual(self.notify_args(after), expected)
                self.assert_codex_loads(after)

    def test_uninstall_keeps_a_notify_that_is_not_ours(self):
        self.orig.parent.mkdir(parents=True)
        self.orig.write_text(json.dumps([self.sky, "turn-ended"]))
        before = self.write(ROOT + 'notify = [\n  "/usr/local/bin/other",\n]\n' + TABLES)
        self.run_script(UNINSTALL)
        self.assertEqual(self.cfg.read_text(), before)

    def test_uninstall_removes_hooks_codex_resaved_without_markers(self):
        self.write(ROOT + self.chained_notify() + TABLES + self.codex_saved_hooks()
                   + self.hooks_state() + TAIL)
        self.assertIn("removed 7 Codex hooks", self.run_script(UNINSTALL))
        after = self.cfg.read_text()
        self.assertEqual(after, ROOT + self.unchained_notify() + TABLES + self.hooks_state() + TAIL)
        self.assert_codex_loads(after)

    def test_uninstall_keeps_foreign_tables_inside_the_fence(self):
        # Codex appends new tables before a trailing comment, i.e. inside our old fence.
        added = '\n[mcp_servers.added_later]\ncommand = "/usr/bin/true"\n'
        self.write(ROOT + self.chained_notify() + TABLES + TAIL
                   + self.legacy_fenced_hooks().replace(END, added + END))
        self.assertIn("removed 7 Codex hooks", self.run_script(UNINSTALL))
        after = self.cfg.read_text()
        self.assertEqual(after, ROOT + self.unchained_notify() + TABLES + TAIL + self.hooks_state() + added)
        self.assert_codex_loads(after)

    def test_uninstall_keeps_other_tools_hooks_for_the_same_event(self):
        own_group = ('\n[[hooks.Stop]]\n\n[[hooks.Stop.hooks]]\ntype = "command"\n'
                     'command = "/opt/other/on-stop.sh"\ntimeout = 30\n')
        shared = '\n[[hooks.PreToolUse]]\nmatcher = "Bash"\n'
        ours = ('\n[[hooks.PreToolUse.hooks]]\ntype = "command"\ncommand = "%s PreToolUse"\n'
                'timeout = 10\n') % self.hook
        theirs = '\n[[hooks.PreToolUse.hooks]]\ntype = "command"\ncommand = "/opt/other/guard.sh"\n'
        rest = self.codex_saved_hooks([e for e in EVENTS if e != "PreToolUse"])
        self.write(ROOT + self.chained_notify() + TABLES + shared + ours + theirs + rest
                   + own_group + self.hooks_state() + TAIL)
        self.assertIn("removed 7 Codex hooks", self.run_script(UNINSTALL))
        after = self.cfg.read_text()
        self.assertEqual(after, ROOT + self.unchained_notify() + TABLES + shared + theirs
                         + own_group + self.hooks_state() + TAIL)
        self.assert_codex_loads(after)


if __name__ == "__main__":
    unittest.main(verbosity=2)
