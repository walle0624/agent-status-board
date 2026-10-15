"""codex_toml.py — just enough TOML awareness for install.sh / uninstall.sh to
edit ~/.codex/config.toml without breaking it (macOS python3 is 3.9: no tomllib).

Line regexes were not enough: Codex Computer Use rewrites `notify` as a
multi-line array whose strings hold `[`, `]` and `\\/`, and Codex re-saves the
file in its own style ("double quotes", comments dropped). So this scans the
top-level statements the way TOML does — basic / literal / multi-line strings,
comments, values spanning lines inside [ ] / { } — and nothing more.
Install-time helper only: it is not copied to ~/.agent-status-board/bin.
"""
import json
from collections import namedtuple

# One top-level statement. start/end: offsets in the text (end excludes any
# trailing comment). head: the "[table]" / "[[array.table]]" header, or the key
# of `key = value`. value: the raw value text — None for a header.
Stmt = namedtuple("Stmt", "start end head value")


def _eol(t, i):
    j = t.find("\n", i)
    return len(t) if j < 0 else j


def _str_end(t, i):
    """t[i] opens a string; return the offset just past its closing quote."""
    q = t[i]
    delim = q * 3 if t.startswith(q * 3, i) else q
    j = i + len(delim)
    while j < len(t):
        if q == '"' and t[j] == "\\":
            j += 2
        elif t.startswith(delim, j):
            j += len(delim)
            while len(delim) == 3 and t[j:j + 1] == q:   # """a"""" — content may end in quotes
                j += 1
            return j
        elif len(delim) == 1 and t[j] == "\n":
            break
        else:
            j += 1
    raise ValueError("unterminated string at offset %d" % i)


def statements(t):
    """All top-level statements of TOML text t, in file order."""
    out, i, n = [], 0, len(t)
    while i < n:
        if t[i] in " \t\r\n":
            i += 1
            continue
        if t[i] == "#":
            i = _eol(t, i)
            continue
        start, depth, eq = i, 0, None
        while i < n:
            c = t[i]
            if c in "\"'":
                i = _str_end(t, i)
                continue
            if c == "#" or (c == "\n" and depth == 0):
                if depth == 0:
                    break
                i = _eol(t, i)                  # comment inside a multi-line array
                continue
            if c == "=" and depth == 0 and eq is None:
                eq = i
            depth += (c in "[{") - (c in "]}")
            i += 1
        end = start + len(t[start:i].rstrip())
        if t[start] == "[":
            out.append(Stmt(start, end, t[start:end], None))
        elif eq is not None:
            out.append(Stmt(start, end, t[start:eq].strip(), t[eq + 1:end].strip()))
        else:
            out.append(Stmt(start, end, t[start:end], ""))
        i = _eol(t, i)
    return out


def duplicates(stmts):
    """Tables / keys defined twice — a TOML error that makes Codex refuse to start."""
    seen, keys, dups = set(), set(), []
    for s in stmts:
        if s.value is None:                     # a header opens a new table
            keys = set()
            if not s.head.startswith("[["):     # [[array.table]] headers may repeat
                if s.head in seen:
                    dups.append(s.head)
                seen.add(s.head)
        elif s.head in keys:
            dups.append(s.head)
        else:
            keys.add(s.head)
    return dups


def root_key(stmts, key):
    """The top-level `key = ...` statement (before the first [table]), or None."""
    for s in stmts:
        if s.value is None:
            return None
        if s.head.strip("\"'") == key:
            return s
    return None


def first_table(stmts):
    """The first [table] / [[array.table]] header statement, or None."""
    return next((s for s in stmts if s.value is None), None)


def toml_str(tok):
    """Value of a single-line TOML string token, else None."""
    if len(tok) >= 2 and tok[0] == tok[-1] == "'" and not tok.startswith("'''"):
        return tok[1:-1]
    if len(tok) >= 2 and tok[0] == tok[-1] == '"' and not tok.startswith('"""'):
        try:
            return json.loads(tok, strict=False)   # TOML basic-string escapes are JSON's
        except ValueError:
            return None
    return None


def str_array(v):
    """List from a TOML array of strings (may span lines, hold comments and a
    trailing comma), else None."""
    v = (v or "").strip()
    if not (v.startswith("[") and v.endswith("]")):
        return None
    out, i = [], 1
    try:
        while i < len(v) - 1:
            c = v[i]
            if c in " \t\r\n,":
                i += 1
            elif c == "#":
                i = _eol(v, i)
            elif c in "\"'":
                j = _str_end(v, i)
                s = toml_str(v[i:j])
                if s is None:
                    return None
                out.append(s)
                i = j
            else:
                return None
    except ValueError:
        return None
    return out


def toml_string(s):
    """s as a TOML basic string (JSON's escapes are all valid TOML)."""
    return json.dumps(str(s), ensure_ascii=False)
