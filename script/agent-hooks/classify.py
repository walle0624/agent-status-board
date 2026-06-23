#!/usr/bin/env python3
"""classify.py <source> <session_id> [transcript_path]

Runs in the background after a session's turn ends. Reads the conversation tail,
asks an LLM whether the session is now waiting for the user (needs_input) plus a
one-line summary, and writes the result back into the session-state file.

This mirrors how Claude's own "Sessions / Needs input" view works: an LLM reads
the transcript and classifies it — there is no plain status flag for it.

Backends (auto-selected, see resolve order below):
  • OpenAI-compatible HTTP API  — RECOMMENDED, portable. Works with almost any
    provider: Aliyun DashScope (compatible-mode), OpenAI, DeepSeek, Moonshot,
    OpenRouter, Ollama, vLLM, ... Needs base_url + api_key + model.
  • Local `bl` CLI (Aliyun Model Studio) — no key needed if it's installed and
    logged in. Handy on the author's machine; not portable to others.

Config resolution (first usable wins):
  1. ~/.agent-status-board/classify.json, e.g.
       {"provider":"openai","base_url":"https://.../v1","api_key":"sk-...","model":"qwen-plus"}
     provider "openai" → OpenAI-compatible HTTP; provider "bl" → local CLI.
  2. Environment overrides: ASB_LLM_PROVIDER / ASB_LLM_BASE_URL /
     ASB_LLM_API_KEY / ASB_LLM_MODEL.
  3. Fallback: if no HTTP config is present but `bl` is on PATH, use `bl`.
If nothing is configured and `bl` is absent, the feature is silently off.

Only the Python standard library is used (urllib) — no pip install required.
"""
import json
import os
import re
import sys
import glob
import shutil
import subprocess
import urllib.request
import urllib.error

HOME = os.path.expanduser("~")
BASE = os.path.join(HOME, ".agent-status-board")
SESS = os.path.join(BASE, "sessions")
ACT = os.path.join(BASE, "activity.jsonl")
CONFIG = os.path.join(BASE, "classify.json")


def load_config():
    """Merge classify.json with ASB_LLM_* env overrides (env wins)."""
    cfg = {}
    try:
        with open(CONFIG) as f:
            loaded = json.load(f)
            if isinstance(loaded, dict):
                cfg = loaded
    except (OSError, ValueError):
        cfg = {}
    env = os.environ.get
    for key, name in (("provider", "ASB_LLM_PROVIDER"),
                      ("base_url", "ASB_LLM_BASE_URL"),
                      ("api_key", "ASB_LLM_API_KEY"),
                      ("model", "ASB_LLM_MODEL")):
        v = env(name)
        if v:
            cfg[key] = v
    return cfg


def find_bl():
    p = shutil.which("bl")
    if p:
        return p
    for cand in (
        os.path.join(HOME, ".local/npm/bin/bl"),
        "/usr/local/bin/bl",
        "/opt/homebrew/bin/bl",
    ):
        if os.path.exists(cand):
            return cand
    return None


def bl_model(cfg):
    m = (cfg.get("model") or "").strip()
    if m:
        return m
    try:
        m = open(os.path.join(BASE, "classify-model")).read().strip()
        if m:
            return m
    except OSError:
        pass
    return "qwen3.7-max"


def cc_transcript_tail(path, limit=9000):
    """Extract the recent user/assistant text from a Claude Code transcript."""
    out = []
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return ""
    for line in lines[-120:]:
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if o.get("type") not in ("user", "assistant"):
            continue
        msg = o.get("message", {})
        content = msg.get("content", "")
        text = ""
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            parts = []
            for b in content:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text":
                    parts.append(b.get("text", ""))
                elif b.get("type") == "tool_use":
                    parts.append(f"[used tool: {b.get('name','')}]")
            text = " ".join(p for p in parts if p)
        text = text.strip()
        if text:
            out.append(f"{o['type'].upper()}: {text}")
    return ("\n".join(out))[-limit:]


def codex_transcript_tail(sid, limit=9000):
    """Best-effort: pull recent text strings from the matching Codex rollout."""
    matches = glob.glob(os.path.join(HOME, ".codex/sessions/*/*/*/rollout-*-%s.jsonl" % sid))
    if not matches:
        return ""
    path = max(matches, key=os.path.getmtime)
    out = []
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return ""
    for line in lines[-200:]:
        try:
            o = json.loads(line)
        except ValueError:
            continue
        blob = json.dumps(o, ensure_ascii=False)
        for m in re.findall(r'"text"\s*:\s*"((?:[^"\\]|\\.){2,})"', blob):
            try:
                out.append(json.loads('"%s"' % m))
            except ValueError:
                pass
    return ("\n".join(out))[-limit:]


SYSTEM = (
    "You inspect the tail of a coding-assistant session transcript and report its state. "
    "Decide needs_input: true ONLY if the assistant has stopped and is genuinely waiting for "
    "the user to answer a question, approve something, or decide a next step before work can "
    "continue; false if the task is finished or nothing is required from the user. "
    "Also write summary: one short line (<=80 chars, in the transcript's main language) of what "
    "happened and, if needs_input, what it is waiting for. "
    'Reply with ONLY a JSON object: {"needs_input": true|false, "summary": "..."}. No prose, no code fences.'
)

USER_PREFIX = "Transcript tail:\n\n"


def extract_json(text):
    if not text:
        return None
    text = text.strip()
    try:
        return json.loads(text)
    except ValueError:
        pass
    i, j = text.find("{"), text.rfind("}")
    if i != -1 and j > i:
        try:
            return json.loads(text[i:j + 1])
        except ValueError:
            return None
    return None


def call_openai_compatible(base_url, api_key, model, transcript):
    """POST to an OpenAI-compatible /chat/completions endpoint via stdlib only."""
    url = base_url.rstrip("/") + "/chat/completions"
    body = json.dumps({
        "model": model,
        "temperature": 0,
        "max_tokens": 500,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": USER_PREFIX + transcript},
        ],
    }).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer " + api_key,
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.loads(r.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, ValueError, OSError):
        return None
    try:
        content = data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        return None
    return extract_json(content)


def call_bl(bl, model, transcript):
    try:
        out = subprocess.run(
            [bl, "text", "chat", "--quiet", "--model", model,
             "--max-tokens", "500", "--system", SYSTEM,
             "--message", USER_PREFIX + transcript],
            capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return extract_json(out.stdout)


def classify(transcript):
    """Pick a backend from config and return the parsed {needs_input,summary}."""
    cfg = load_config()
    provider = (cfg.get("provider") or "").strip().lower()
    base_url = (cfg.get("base_url") or "").strip()
    api_key = (cfg.get("api_key") or "").strip()

    # Explicit local CLI.
    if provider == "bl":
        bl = find_bl()
        return call_bl(bl, bl_model(cfg), transcript) if bl else None

    # Explicit HTTP, or any config that carries base_url + api_key.
    if provider in ("openai", "http", "compatible") or (base_url and api_key):
        model = (cfg.get("model") or "").strip()
        if base_url and api_key and model:
            return call_openai_compatible(base_url, api_key, model, transcript)
        return None  # half-configured → stay off rather than guess

    # Nothing explicit: fall back to a local `bl` if present (author convenience).
    bl = find_bl()
    if bl:
        return call_bl(bl, bl_model(cfg), transcript)
    return None


def main():
    if len(sys.argv) < 3:
        return
    source, sid = sys.argv[1], sys.argv[2]
    tpath = sys.argv[3] if len(sys.argv) > 3 else ""

    transcript = cc_transcript_tail(tpath) if source == "claudeCode" else codex_transcript_tail(sid)
    if len(transcript) < 20:
        return

    try:
        result = classify(transcript)
    except Exception:
        return
    if not result:
        return

    needs = bool(result.get("needs_input"))
    summary = (result.get("summary") or "").strip()[:120]

    safe = re.sub(r"[^A-Za-z0-9._-]", "_", "%s-%s" % (source, sid))
    f = os.path.join(SESS, safe + ".json")
    try:
        rec = json.load(open(f))
    except (OSError, ValueError):
        return
    # Only act on a session that is still finished (user hasn't sent a new turn).
    if rec.get("status") != "done":
        return
    rec["summary"] = summary
    if needs:
        rec["status"] = "waitingReview"
    tmp = f + ".tmp"
    json.dump(rec, open(tmp, "w"), ensure_ascii=False)
    os.replace(tmp, f)

    if needs:
        try:
            with open(ACT, "a") as a:
                a.write(json.dumps({
                    "at": rec.get("updatedAt", ""),
                    "key": rec.get("key", ""),
                    "source": source,
                    "status": "waitingReview",
                    "title": rec.get("title", ""),
                    "cwd": rec.get("cwd", ""),
                }, ensure_ascii=False) + "\n")
        except OSError:
            pass


if __name__ == "__main__":
    main()
