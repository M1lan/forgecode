#!/usr/bin/env python3
"""Differential conformance oracle for interactive forge shell plugins.

Drives a target shell (zsh now; bash/fish later) under pexpect with a pinned,
deterministic environment, feeds a named keystroke script (a "trace case"), and
captures two observables:

  (a) T1 -- the `forge` subprocess trace: argv + injected env + cwd, via a fake
      `forge` shim placed first on PATH ($FORGE_TRACE JSON lines).
  (b) T2 -- terminal protocol: the OSC-133 marker sequence emitted on the pty,
      plus the final pyte screen grid + cursor.

Scoring is DIFFERENTIAL: score(shell, case) compares (a)+(b) of a candidate
plugin against the REFERENCE zsh run of the same case. Per-capability T1/T2
gates (not one scalar). Exit non-zero if any MUST (T1) fails.

LLM-first: token-minimal, zero color, one JSON format, quiet success.

Usage:
  oracle.py run       --plugin <dir> [--cases cases.json] [--json]
  oracle.py diff      --ref <dir> --cand <dir> [--cases cases.json] [--json]
  oracle.py selfcheck --plugin <dir>            # ref vs ref, must be 100%
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

import pexpect
import pyte

HERE = Path(__file__).resolve().parent
FAKE_FORGE_DIR = HERE / "fake-forge"

COLS, ROWS = 80, 24
SETTLE = 0.45          # seconds to let a case + detached bg jobs settle
SPAWN_TIMEOUT = 20

# OSC-133 marker: printf '\e]133;%s\a'  ->  ESC ] 133 ; <payload> BEL
OSC133_RE = re.compile(rb"\x1b\]133;([^\x07\x1b]*)(?:\x07|\x1b\\)")

# Background-job argv signatures to drop from T1 (async, timing-nondeterministic).
# See helpers.zsh: detached `forge update --no-confirm` and `workspace sync/info`.
def is_background(argv: list[str]) -> bool:
    if argv[:1] == ["update"]:
        return True
    # background sync probes/uses an ABSOLUTE path; foreground uses "."
    if len(argv) >= 3 and argv[0] == "workspace" and argv[1] in ("info", "sync") \
            and argv[2].startswith("/"):
        return True
    return False


def build_env(trace_path: str) -> dict:
    env = dict(os.environ)
    env["PATH"] = f"{FAKE_FORGE_DIR}:{env.get('PATH','')}"
    env["FORGE_TRACE"] = trace_path
    # Pinned deterministic terminal identity.
    env["TERM"] = "xterm-256color"
    env["TERM_PROGRAM"] = "ghostty"       # -> OSC-133 auto-detect emits
    env["COLUMNS"] = str(COLS)
    env["LINES"] = str(ROWS)
    env["LC_ALL"] = "C"
    # Kill nondeterministic async: background sync gated off; update filtered.
    env["FORGE_SYNC_ENABLED"] = "false"
    # Neutralize any user rc influence + ambient color forcing so that only
    # plugin-injected FORCE_COLOR/CLICOLOR_FORCE appear in the trace.
    for k in ("ZDOTDIR", "RPROMPT", "RPS1", "FORCE_COLOR", "CLICOLOR_FORCE"):
        env.pop(k, None)
    return env


def run_case(plugin_dir: Path, keys: list[str]) -> dict:
    """Run one keystroke script in a FRESH zsh; return {trace, osc, screen, cursor}."""
    tf = tempfile.NamedTemporaryFile(prefix="forge-trace-", suffix=".jsonl",
                                     dir=str(Path.home() / "tmp"), delete=False)
    trace_path = tf.name
    tf.close()
    env = build_env(trace_path)
    plugin = plugin_dir / "forge.plugin.zsh"

    # zsh -f: no user rc. Interactive (attached to pty) so ZLE is active.
    child = pexpect.spawn(
        "/opt/homebrew/bin/zsh", ["-f"],
        env=env, dimensions=(ROWS, COLS), timeout=SPAWN_TIMEOUT, encoding=None,
    )
    raw = bytearray()

    def drain(t: float) -> None:
        end = time.time() + t
        while time.time() < end:
            try:
                chunk = child.read_nonblocking(4096, timeout=0.1)
                if chunk:
                    raw.extend(chunk)
            except pexpect.TIMEOUT:
                pass
            except pexpect.EOF:
                break

    def drain_idle(idle: float = 0.3, cap: float = 4.0) -> None:
        """Read until the pty is quiet for `idle` seconds (or `cap` elapses).
        Removes the capture race for cases that fire multiple forge subprocesses
        before the terminating OSC-133 D;A pair is emitted."""
        deadline = time.time() + cap
        last = time.time()
        while time.time() < deadline:
            try:
                chunk = child.read_nonblocking(4096, timeout=0.1)
                if chunk:
                    raw.extend(chunk)
                    last = time.time()
            except pexpect.TIMEOUT:
                if time.time() - last >= idle:
                    return
            except pexpect.EOF:
                return

    # Deterministic prompt sentinel; disable zle bracketed-paste noise from term.
    child.send(b"PROMPT='@@RDY@@ '\r")
    drain(0.4)
    child.send(f"source '{plugin}'\r".encode())
    drain(0.6)
    raw.clear()  # discard setup noise; only measure the case keystrokes

    def trace_size() -> int:
        try:
            return os.path.getsize(trace_path)
        except OSError:
            return 0

    def settle(quiet: float = 0.5, cap: float = 4.0) -> None:
        """Settle a case: read the pty AND wait until the trace file stops
        growing for `quiet` seconds. Guarantees every synchronous forge call the
        widget makes is on disk before we score (kills the capture race where a
        late `config set` line is dropped, yielding a false T1 match)."""
        deadline = time.time() + cap
        last_size = trace_size()
        last_change = time.time()
        while time.time() < deadline:
            try:
                chunk = child.read_nonblocking(4096, timeout=0.1)
                if chunk:
                    raw.extend(chunk)
            except pexpect.TIMEOUT:
                pass
            except pexpect.EOF:
                break
            sz = trace_size()
            if sz != last_size:
                last_size = sz
                last_change = time.time()
            elif time.time() - last_change >= quiet:
                return

    for line in keys:
        child.send(line.encode() + b"\r")
        drain_idle()

    settle()
    try:
        child.sendcontrol("d")
        child.close(force=True)
    except Exception:
        pass

    # Parse trace (foreground only).
    trace = []
    try:
        for ln in Path(trace_path).read_text().splitlines():
            ln = ln.strip()
            if not ln:
                continue
            obj = json.loads(ln)
            if not is_background(obj.get("argv", [])):
                trace.append(obj)
    finally:
        try:
            os.unlink(trace_path)
        except OSError:
            pass

    osc = [m.group(1).decode("latin-1") for m in OSC133_RE.finditer(bytes(raw))]

    # Feed raw bytes through pyte for the final screen grid + cursor.
    screen = pyte.Screen(COLS, ROWS)
    stream = pyte.ByteStream(screen)
    stream.feed(bytes(raw))
    grid = [screen.display[r].rstrip() for r in range(ROWS)]
    while grid and grid[-1] == "":
        grid.pop()
    cursor = [screen.cursor.x, screen.cursor.y]

    return {"trace": trace, "osc": osc, "screen": grid, "cursor": cursor}


# --- normalization ----------------------------------------------------------
def norm_trace(trace: list[dict]) -> list[dict]:
    """Strip known nondeterminism: cwd already pinned; timestamps in env removed."""
    out = []
    for o in trace:
        env = dict(o.get("forge_env", {}))
        # timestamps are wall-clock -> drop from the comparison
        env.pop("_FORGE_TERM_TIMESTAMPS", None)
        out.append({"argv": o.get("argv", []), "cwd": o.get("cwd", ""), "env": env})
    return out


def norm_osc(osc: list[str]) -> list[str]:
    return list(osc)


# --- scoring ----------------------------------------------------------------
def score_case(ref: dict, cand: dict) -> dict:
    rt, ct = norm_trace(ref["trace"]), norm_trace(cand["trace"])
    t1_pass = rt == ct
    t1_detail = "" if t1_pass else json.dumps({"ref": rt, "cand": ct}, sort_keys=True)

    ro, co = norm_osc(ref["osc"]), norm_osc(cand["osc"])
    t2_pass = ro == co
    t2_detail = "" if t2_pass else json.dumps({"ref": ro, "cand": co})

    score = round((int(t1_pass) + int(t2_pass)) / 2.0, 3)
    return {
        "t1": {"pass": t1_pass, "detail": t1_detail},
        "t2": {"pass": t2_pass, "detail": t2_detail},
        "score": score,
    }


def load_cases(path: Path) -> list[dict]:
    return json.loads(path.read_text())["cases"]


def do_diff(ref_dir: Path, cand_dir: Path, cases: list[dict], as_json: bool) -> int:
    results = []
    any_t1_fail = False
    for c in cases:
        ref = run_case(ref_dir, c["keys"])
        cand = run_case(cand_dir, c["keys"])
        sc = score_case(ref, cand)
        if not sc["t1"]["pass"]:
            any_t1_fail = True
        results.append({"case": c["name"], "cap": c["cap"], **sc})

    if as_json:
        print(json.dumps({"results": results}, separators=(",", ":")))
    else:
        for r in results:
            t1 = "PASS" if r["t1"]["pass"] else "FAIL"
            t2 = "PASS" if r["t2"]["pass"] else "FAIL"
            print(f"{r['case']:<20} cap={r['cap']:<28} t1={t1} t2={t2} score={r['score']}")
            if r["t1"]["detail"]:
                print(f"    T1 {r['t1']['detail']}")
            if r["t2"]["detail"]:
                print(f"    T2 {r['t2']['detail']}")
        n = len(results)
        t1ok = sum(r["t1"]["pass"] for r in results)
        t2ok = sum(r["t2"]["pass"] for r in results)
        print(f"summary: cases={n} t1={t1ok}/{n} t2={t2ok}/{n}")
    return 1 if any_t1_fail else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    for name in ("run", "selfcheck"):
        p = sub.add_parser(name)
        p.add_argument("--plugin", required=True)
        p.add_argument("--cases", default=str(HERE / "cases.json"))
        p.add_argument("--json", action="store_true")

    p = sub.add_parser("diff")
    p.add_argument("--ref", required=True)
    p.add_argument("--cand", required=True)
    p.add_argument("--cases", default=str(HERE / "cases.json"))
    p.add_argument("--json", action="store_true")

    a = ap.parse_args()
    (Path.home() / "tmp").mkdir(exist_ok=True)
    cases = load_cases(Path(a.cases))

    if a.cmd in ("run", "selfcheck"):
        # ref vs ref self-consistency.
        return do_diff(Path(a.plugin), Path(a.plugin), cases, a.json)
    return do_diff(Path(a.ref), Path(a.cand), cases, a.json)


if __name__ == "__main__":
    sys.exit(main())
