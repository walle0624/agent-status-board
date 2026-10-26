#!/usr/bin/env bash
# Generate a long-lived Claude token without exposing credentials in terminal/logs.
# ASB_CLAUDE_BIN overrides discovery; ASB_TOKEN_SETUP_TIMEOUT defaults to 900 seconds.
# See cc-token-setup.md for interactive use and the offline regression suite.
set -euo pipefail

# Preserve the caller's stdin separately: Python reads this program from stdin.
exec python3 - "$HOME/.agent-status-board" 3<&0 <<'PY'
import codecs
import errno
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import tty
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

BASE = Path(sys.argv[1])
INPUT_FD = 3
ANSI = re.compile(r"\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-_]")
TOKEN = re.compile(r"(?<![A-Za-z0-9_.-])(sk-ant-oat[A-Za-z0-9_.-]+)")
URL = re.compile(r"https://[^\s<>\"'\x00-\x20]+")
VERSION = re.compile(r"\b(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?")
AUTH_HOSTS = {"claude.ai", "console.anthropic.com", "platform.claude.com"}
AUTH_KEYS = {"client_id", "response_type", "redirect_uri", "scope", "code",
             "code_challenge", "code_challenge_method", "state", "login_hint",
             "organization_uuid", "orgUUID", "prompt"}
MAX_OUTPUT = 4 * 1024 * 1024


def say(message, error=False):
    print(message, file=sys.stderr if error else sys.stdout, flush=True)


def choose_claude():
    override = os.environ.get("ASB_CLAUDE_BIN")
    if override:
        candidate = Path(override).expanduser()
        if not candidate.is_file() or not os.access(candidate, os.X_OK):
            raise ValueError("ASB_CLAUDE_BIN 不是可执行文件。")
        return str(candidate.resolve()), "指定 CLI"

    candidates = []
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        candidates.append((Path(entry or ".") / "claude", "PATH"))
    desktop = Path.home() / "Library/Application Support/Claude/claude-code"
    # Desktop layouts vary by release; recursively find the executable, not just
    # one version directory. Never infer a version from directory names or mtime.
    for directory, dirs, files in os.walk(desktop):
        dirs.sort()
        if "claude" in files:
            candidates.append((Path(directory) / "claude", "桌面内置 CLI"))

    seen, versions = set(), []
    for candidate, source in candidates:
        if not candidate.is_file() or not os.access(candidate, os.X_OK):
            continue
        resolved = str(candidate.resolve())
        if resolved in seen:
            continue
        seen.add(resolved)
        try:
            result = subprocess.run([resolved, "--version"], stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=5, check=False)
            match = VERSION.search(ANSI.sub("", result.stdout.decode("utf-8", "replace")))
            if result.returncode == 0 and match:
                # Prefer a stable release over a prerelease of the same version.
                version = tuple(int(match.group(i)) for i in (1, 2, 3))
                versions.append((version + (not bool(match.group(4)),), resolved,
                                 source, match.group(0)))
        except (OSError, subprocess.TimeoutExpired):
            continue
    if not versions:
        raise ValueError("找不到能报告版本的 Claude CLI；请安装 CLI 或设置 ASB_CLAUDE_BIN。")
    best = max(versions, key=lambda item: item[0])
    return best[1], best[2] + " " + best[3]


def authorization_urls(clean):
    for match in URL.finditer(clean):
        # A chunk can end halfway through state/challenge; wait for a delimiter.
        if match.end() == len(clean):
            continue
        url = match.group(0).rstrip(").,;│┃")
        try:
            parsed = urlsplit(url)
            query_items = parse_qsl(parsed.query, keep_blank_values=True)
            query = dict(query_items)
            if (parsed.netloc not in AUTH_HOSTS or parsed.path.rstrip("/") != "/oauth/authorize"
                    or parsed.fragment or len(query) != len(query_items)
                    or not set(query).issubset(AUTH_KEYS)
                    or not {"client_id", "response_type", "code_challenge", "state"}.issubset(query)
                    or query["response_type"] != "code"
                    or not all(query[key] for key in ("client_id", "code_challenge", "state"))
                    or ("code" in query and query["code"].lower() not in {"true", "false", "1", "0"})
                    or "sk-ant-" in url):
                continue
        except ValueError:
            continue
        yield url


DIAGNOSTICS = (
    ("oauth authentication is currently not allowed for this organization", "当前组织不允许 OAuth 认证。"),
    ("eaddrinuse", "localhost 回调端口已被占用。"),
    ("address already in use", "localhost 回调端口已被占用。"),
    ("econnrefused", "ECONNREFUSED：连接被拒绝，请检查网络或代理。"),
    ("etimedout", "ETIMEDOUT：连接超时，请检查网络或代理。"),
    ("enotfound", "ENOTFOUND：DNS 解析失败。"),
    ("eai_again", "EAI_AGAIN：DNS 解析暂时失败。"),
    ("econnreset", "ECONNRESET：连接被重置。"),
    ("certificate", "TLS 证书校验失败，请检查系统时间、证书或代理。"),
    ("fetch failed", "网络请求失败，请检查连接或代理。"),
    ("invalid_grant", "授权 code 无效或已过期。"),
    ("invalid authorization code", "授权 code 无效或已过期。"),
    ("not logged in", "CLI 尚未登录。"),
)


# Only known diagnostic words are relayed. A conventional "mask long strings"
# filter can miss short authorization codes and account names; unknown words,
# URL values, IDs and non-ASCII text must also be removed before printing.
SAFE_WORDS = set("""error api http https status statuscode oauth authentication
currently is not allowed for this organization permission_error invalid_request_error
invalid_grant invalid authorization code expired access denied forbidden unauthorized
request response failed failure unable cannot could to the a an and or but with from
in on at of was has have been be due token exchange refresh credential credentials
login logged out session callback localhost port address already use occupied server
network connection connect disconnected refused reset timeout timed timedout abort
aborted tls ssl certificate verification verify self signed issuer local get unable
resolve resolving dns host hostname proxy socket unexpected end file eof parse json
format missing required scope scopes rate limit exceeded too many requests retry
internal service unavailable bad gateway found invalid_request invalid_client
invalid_scope server_error access_denied temporarily_unavailable fetch type message
cause errno syscall etimedout econnrefused econnreset enotfound eai_again eaddrinuse
err_tls_cert_altname_invalid unable_to_verify_leaf_signature cert_has_expired
self_signed_cert_in_chain depth_zero_self_signed_cert""".split())


def safe_error_message(line):
    line = re.sub(r"https?://[^\s<>\"']+", "[redacted]", line)
    line = re.sub(r"[^\x00-\x7f]+", "[redacted]", line)
    def keep_known(match):
        word = match.group(0)
        return word if word.lower() in SAFE_WORDS else "[redacted]"
    line = re.sub(r"[A-Za-z0-9_.@/#+=-]+", keep_known, line)
    return re.sub(r"(?:\[redacted\][ ,;:]*){2,}", "[redacted] ", line).strip()[:500]


def exit_code(status):
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    return 128 + os.WTERMSIG(status)


def stop_child(pid):
    # pty.fork gives the child its own process group; also stop browser/callback
    # helpers that inherited the PTY, then reap the actual CLI process.
    try:
        os.killpg(pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        # macOS can return EPERM for a process group that has already vanished.
        return
    until = time.monotonic() + 1
    status = None
    while time.monotonic() < until:
        if status is None:
            try:
                waited, value = os.waitpid(pid, os.WNOHANG)
                if waited:
                    status = value
            except ChildProcessError:
                status = 0
        try:
            os.killpg(pid, 0)
        except (ProcessLookupError, PermissionError):
            return
        time.sleep(0.02)
    try:
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    if status is None:
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass


class Cancelled(Exception):
    def __init__(self, signum):
        self.code = 128 + signum


def run_claude(claude, timeout):
    interactive = os.isatty(INPUT_FD)
    if not interactive:
        say("非交互运行：等待浏览器 localhost 回调；若 CLI 要求粘贴 code，请在交互终端重跑。")
    say("正在运行 claude setup-token；授权链接出现后会立即显示。")
    pid, master = pty.fork()
    if pid == 0:
        try:
            os.close(INPUT_FD)
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 4000, 0, 0))
            os.environ["TERM"] = "xterm-256color"
            os.environ["COLUMNS"] = "4000"
            os.environ["LINES"] = "50"
            os.execv(claude, [claude, "setup-token"])
        except OSError:
            os._exit(127)

    transcript = ""
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    seen_urls, seen_diagnostics = set(), set()
    reported_lines = set()
    def report(clean, final=False):
        if final:
            clean += "\n"
        for url in authorization_urls(clean):
            if url not in seen_urls:
                seen_urls.add(url)
                say("请打开授权链接：\n" + url)
        lowered = clean.lower()
        for marker, message in DIAGNOSTICS:
            if marker in lowered and message not in seen_diagnostics:
                seen_diagnostics.add(message)
                say("CLI 诊断：" + message, error=True)
        for match in re.finditer(r"(?:http(?:/\d(?:\.\d)?)?|status(?:code)?|error)\s*[:=]?\s*([1-5]\d{2})\b", lowered):
            message = "CLI HTTP 状态：" + match.group(1)
            if message not in seen_diagnostics:
                seen_diagnostics.add(message)
                say(message, error=True)
        # Delay incomplete lines: codes/credentials may span PTY read chunks.
        lines = clean.splitlines(keepends=True)
        for line in lines:
            if not line.endswith(("\n", "\r")):
                continue
            if re.search(r"\b(error|failed|failure|invalid_grant|econnrefused|etimedout|enotfound)\b", line, re.I):
                message = safe_error_message(line)
                if message and message not in reported_lines:
                    reported_lines.add(message)
                    say("CLI 错误（已脱敏）：" + message, error=True)

    saved_terminal = None
    previous_handlers = {}
    status = None
    reaped_at = None
    finished = False
    deadline = time.monotonic() + timeout
    try:
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 4000, 0, 0))
        if interactive:
            saved_terminal = termios.tcgetattr(INPUT_FD)
            tty.setcbreak(INPUT_FD)
            attributes = termios.tcgetattr(INPUT_FD)
            attributes[3] &= ~termios.ECHO
            termios.tcsetattr(INPUT_FD, termios.TCSANOW, attributes)
            say("如需手动授权，请在此终端粘贴 code 后按 Enter（输入隐藏）；Ctrl-C 取消。")

        def cancel(signum, _frame):
            raise Cancelled(signum)
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous_handlers[signum] = signal.signal(signum, cancel)

        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                say("授权超时（退出码 124）；旧 token 文件保持不变。", error=True)
                return 124, None
            if status is None:
                waited, value = os.waitpid(pid, os.WNOHANG)
                if waited:
                    status, reaped_at = value, time.monotonic()
            # An unrelated descendant may keep the PTY open after CLI exit.
            if reaped_at is not None and time.monotonic() - reaped_at > 1:
                break
            readers = [master] + ([INPUT_FD] if interactive and status is None else [])
            ready, _, _ = select.select(readers, [], [], min(0.1, remaining))
            if INPUT_FD in ready:
                data = os.read(INPUT_FD, 4096)
                if data:
                    os.write(master, data)
                else:
                    interactive = False
            if master not in ready:
                continue
            try:
                data = os.read(master, 65536)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                break
            if not data:
                break
            transcript += decoder.decode(data)
            if len(transcript) > MAX_OUTPUT:
                say("CLI 输出超过安全上限；旧 token 文件保持不变。", error=True)
                return 1, None
            clean = ANSI.sub("", transcript)
            report(clean)

        if status is None:
            # EOF usually follows exit, but never block on waitpid indefinitely.
            while status is None:
                waited, value = os.waitpid(pid, os.WNOHANG)
                if waited:
                    status = value
                elif time.monotonic() >= deadline:
                    say("授权超时（退出码 124）；旧 token 文件保持不变。", error=True)
                    return 124, None
                else:
                    time.sleep(0.02)
        finished = True
        clean = ANSI.sub("", transcript + decoder.decode(b"", final=True))
        report(clean, final=True)
        code = exit_code(status)
        if code != 0:
            say("Claude CLI 退出码 %d；授权未完成，旧 token 文件保持不变。" % code, error=True)
            return code, None
        tokens = set(TOKEN.findall(clean))
        if len(tokens) != 1 or len(next(iter(tokens), "")) <= 60:
            say("Claude CLI 退出码 0，但未找到唯一完整 token；旧 token 文件保持不变。", error=True)
            return 1, None
        return 0, next(iter(tokens))
    except Cancelled as exc:
        say("授权已取消（退出码 %d）；旧 token 文件保持不变。" % exc.code, error=True)
        return exc.code, None
    finally:
        if saved_terminal is not None:
            termios.tcsetattr(INPUT_FD, termios.TCSANOW, saved_terminal)
        for signum, previous in previous_handlers.items():
            signal.signal(signum, previous)
        if not finished or reaped_at is not None:
            stop_child(pid)
        os.close(master)


def save_token(token):
    BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".cc-token-", dir=BASE)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump({"token": token}, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, BASE / "cc-token.json")
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    os.umask(0o077)
    try:
        timeout = float(os.environ.get("ASB_TOKEN_SETUP_TIMEOUT",
                                      os.environ.get("ASB_CC_TOKEN_TIMEOUT_SECONDS", "900")))
        if not 0 < timeout <= 3600:
            raise ValueError("ASB_TOKEN_SETUP_TIMEOUT 必须大于 0 且不超过 3600。")
        claude, source = choose_claude()
        say("使用 " + source + "。")
        code, token = run_claude(claude, timeout)
        if code:
            return code
        save_token(token)
        say("ASB_CC_TOKEN_SAVED：已安全保存 token 到 ~/.agent-status-board/cc-token.json（权限 600）。")
        return 0
    except ValueError as exc:
        # These errors contain only our fixed configuration/discovery messages.
        # float() errors can include input, so never print their original text.
        message = str(exc)
        if message.startswith(("ASB_", "找不到")):
            say(message, error=True)
        else:
            say("授权脚本配置无效；请检查超时设置。", error=True)
        return 1
    except OSError as exc:
        # OSError text can include filenames/output containing credentials.
        say("授权脚本发生本地 I/O 错误（errno %s）；未确认保存成功。" % exc.errno, error=True)
        return 1


sys.exit(main())
PY
