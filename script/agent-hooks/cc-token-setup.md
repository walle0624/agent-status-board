# Claude token setup

Run `bash ~/.agent-status-board/bin/cc-token-setup.sh` after installing the hooks,
or `bash script/agent-hooks/cc-token-setup.sh` from the repository. Requires
Python 3 and a Claude CLI. This script never installs or upgrades a CLI.

- `ASB_CLAUDE_BIN=/absolute/path/to/claude` selects a particular executable.
  Otherwise the script probes `claude --version` for executable candidates in
  `PATH` and recursively beneath
  `~/Library/Application Support/Claude/claude-code`, then chooses the highest
  reported numeric version. A stable release wins over a prerelease of the same
  version. Directory names and modification times never determine the version.
- `ASB_TOKEN_SETUP_TIMEOUT=900` sets the authorization timeout in seconds
  (default 900; greater than 0 and at most 3600). The
  `ASB_CC_TOKEN_TIMEOUT_SECONDS` alias is accepted when the main variable is unset.
- The CLI runs inside a wide PTY. A validated Claude OAuth authorization URL is
  printed immediately, including its challenge/state, so the browser can be
  opened manually. The script does not print the final token. Raw CLI output is
  retained only in memory; no raw credential log is created.
- In an interactive terminal, paste a manual authorization code and press Enter
  if the browser/CLI requests one. Input is forwarded to the CLI with terminal
  echo disabled and restored when the script exits. Ctrl-C cancels authorization.
  With noninteractive stdin, the script keeps waiting for the CLI's localhost
  callback. If that CLI/browser flow requires a manual code instead, rerun in an
  interactive terminal. The wrapper does not implement its own OAuth callback.
- Diagnostics preserve HTTP status, common network/OAuth error classes, and
  recognized English error words. Unknown values, account identifiers, ordinary
  URLs, authorization codes, and tokens are masked. This deliberately omits
  unrecognized error details to avoid leaking credentials, including short codes.

Only CLI exit 0 plus one distinct complete `sk-ant-oat…` token (over 60 characters)
permits a save. ANSI formatting and repeated copies of the same token are accepted;
conflicting tokens are rejected. A private temporary file in
`~/.agent-status-board/` is flushed and atomically replaces `cc-token.json` with
mode `0600`. `ASB_CC_TOKEN_SAVED` is emitted **after** replacement. Failures and
cancellation preserve the previous file's contents, permissions and modification
time. Saving a token does not prove that the organization permits a usage API.

Exit statuses:

| Status | Meaning |
| --- | --- |
| `0` | Token atomically saved; success marker emitted. |
| CLI nonzero status | Original CLI failure status is preserved. A CLI signal maps to `128 + signal`. |
| `1` | Discovery/configuration/I/O failure, no token, conflicting tokens, or output over the 4 MiB limit. |
| `124` | Authorization timeout; child process group is stopped. |
| `130` / `143` | Wrapper cancelled by SIGINT / SIGTERM; child process group is stopped. |

If retaining the wrapper's sanitized output, still use a private `0600` log,
since authorization URLs contain transient challenge/state values. Never copy
`cc-token.json` into the public repository.

## Offline regression suite

```sh
bash -n script/agent-hooks/cc-token-setup.sh
python3 script/tests/test_cc_token_setup.py
```

Tests use temporary homes and executable fake CLIs only: no real authorization,
external network, real account, or installed CLI is used. They cover atomic `0600`
saving, exact nonzero/signal statuses, missing/conflicting tokens, ANSI and split
output, credential redaction, streaming authorization URLs, manual-code forwarding,
timeout/cancellation cleanup, and numeric version selection across PATH/recursive
desktop layouts despite misleading modification times. The callback test uses a
local file to simulate completion while stdin is closed; real browser/localhost
OAuth interoperability still requires a separate authorized live check.
