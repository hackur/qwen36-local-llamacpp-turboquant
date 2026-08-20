#!/usr/bin/env python3
# Suite loader/validator for A/B bench jobs: parses YAML, enforces schema, merges defaults.
from __future__ import annotations
import os, re, sys
from typing import Any, Dict, List

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

import yaml

# kebab-case: lowercase tokens (digits + underscores allowed inside, e.g. "q8_0")
# joined by single hyphens. No leading/trailing/double hyphens.
KEBAB_RE = re.compile(r"^[a-z0-9_]+(-[a-z0-9_]+)*$")


class SuiteError(Exception):
    pass


def load(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise SuiteError(f"{path}: top-level YAML must be a mapping")
    return data


def _check_port(p: Any, where: str) -> None:
    if not isinstance(p, int) or isinstance(p, bool):
        raise SuiteError(f"{where}: port must be int, got {type(p).__name__}")
    if p < 1 or p > 65535:
        raise SuiteError(f"{where}: port {p} out of range 1-65535")


def _check_prompt_file(pf: Any, where: str) -> None:
    if not isinstance(pf, str) or not pf:
        raise SuiteError(f"{where}.prompt_file: must be non-empty str")
    resolved = pf if os.path.isabs(pf) else os.path.join(_REPO_ROOT, pf)
    if not (os.path.isfile(resolved) and os.access(resolved, os.R_OK)):
        raise SuiteError(f"{where}.prompt_file: not found or unreadable: {pf}")


def _check_side(side: Any, where: str) -> None:
    if not isinstance(side, dict):
        raise SuiteError(f"{where}: must be a mapping with label+port")
    for k in ("label", "port"):
        if k not in side:
            raise SuiteError(f"{where}: missing '{k}'")
    if not isinstance(side["label"], str) or not side["label"]:
        raise SuiteError(f"{where}.label: must be non-empty str")
    _check_port(side["port"], f"{where}.port")


def validate(suite: Dict[str, Any]) -> None:
    name = suite.get("name")
    if not isinstance(name, str) or not name:
        raise SuiteError("suite: 'name' required (non-empty str)")
    if not KEBAB_RE.match(name):
        raise SuiteError(f"suite.name '{name}': must be kebab-case")

    defaults = suite.get("defaults", {}) or {}
    if not isinstance(defaults, dict):
        raise SuiteError("suite.defaults: must be a mapping")
    if "n" in defaults and (not isinstance(defaults["n"], int) or defaults["n"] < 1):
        raise SuiteError("defaults.n: must be int >= 1")
    if "max_tokens" in defaults and (not isinstance(defaults["max_tokens"], int) or defaults["max_tokens"] < 1):
        raise SuiteError("defaults.max_tokens: must be int >= 1")
    if "prompt" in defaults and "prompt_file" in defaults:
        raise SuiteError("defaults: set only one of prompt or prompt_file")
    if "prompt_file" in defaults:
        _check_prompt_file(defaults["prompt_file"], "defaults")

    jobs = suite.get("jobs")
    if not isinstance(jobs, list) or not jobs:
        raise SuiteError("suite.jobs: required non-empty list")

    seen_ids = set()
    for i, job in enumerate(jobs):
        where = f"jobs[{i}]"
        if not isinstance(job, dict):
            raise SuiteError(f"{where}: must be a mapping")
        jid = job.get("id")
        if not isinstance(jid, str) or not jid:
            raise SuiteError(f"{where}.id: required non-empty str")
        if not KEBAB_RE.match(jid):
            raise SuiteError(f"{where}.id '{jid}': must be kebab-case")
        if jid in seen_ids:
            raise SuiteError(f"{where}.id: duplicate '{jid}'")
        seen_ids.add(jid)

        if "a" not in job or "b" not in job:
            raise SuiteError(f"{where} ({jid}): both 'a' and 'b' required")
        _check_side(job["a"], f"{where}({jid}).a")
        _check_side(job["b"], f"{where}({jid}).b")
        if job["a"]["port"] == job["b"]["port"]:
            raise SuiteError(f"{where} {jid}: a.port == b.port == {job['a']['port']}")

        if "n" in job and (not isinstance(job["n"], int) or job["n"] < 1):
            raise SuiteError(f"{where} ({jid}).n: must be int >= 1")
        if "max_tokens" in job and (not isinstance(job["max_tokens"], int) or job["max_tokens"] < 1):
            raise SuiteError(f"{where} ({jid}).max_tokens: must be int >= 1")
        if "prompt" in job and "prompt_file" in job:
            raise SuiteError(f"{where} ({jid}): set only one of prompt or prompt_file")
        if "prompt_file" in job:
            _check_prompt_file(job["prompt_file"], f"{where} ({jid})")


def merge_defaults(job: Dict[str, Any], defaults: Dict[str, Any]) -> Dict[str, Any]:
    d = dict(defaults or {})
    j = dict(job)
    # If job sets either prompt source, drop both default prompt keys.
    if "prompt" in j or "prompt_file" in j:
        d.pop("prompt", None)
        d.pop("prompt_file", None)
    out = {**d, **j}
    out.setdefault("n", 5)
    out.setdefault("max_tokens", 500)
    return out


# --- CLI ---------------------------------------------------------------------

def _cmd_validate(paths: List[str]) -> int:
    rc = 0
    for p in paths:
        try:
            s = load(p)
            validate(s)
            print(f"OK {os.path.basename(p)} ({len(s['jobs'])} jobs)")
        except (SuiteError, yaml.YAMLError, OSError) as e:
            print(f"FAIL {p}: {e}", file=sys.stderr)
            rc = 1
    return rc


def _cmd_selftest() -> int:
    cases = [
        ("duplicate id", {
            "name": "x", "jobs": [
                {"id": "a", "a": {"label": "A", "port": 1}, "b": {"label": "B", "port": 2}},
                {"id": "a", "a": {"label": "A", "port": 3}, "b": {"label": "B", "port": 4}},
            ]}, "duplicate"),
        ("missing port", {
            "name": "x", "jobs": [
                {"id": "a", "a": {"label": "A"}, "b": {"label": "B", "port": 2}},
            ]}, "missing 'port'"),
        ("port collision", {
            "name": "x", "jobs": [
                {"id": "a", "a": {"label": "A", "port": 5}, "b": {"label": "B", "port": 5}},
            ]}, "a.port == b.port == 5"),
        ("same-port A/B", {
            "name": "x", "jobs": [
                {"id": "j1", "a": {"label": "A", "port": 8080}, "b": {"label": "B", "port": 2}},
                {"id": "j2", "a": {"label": "A", "port": 9090}, "b": {"label": "B", "port": 9090}},
            ]}, "jobs[1] j2: a.port == b.port == 9090"),
        ("missing prompt_file", {
            "name": "x", "jobs": [
                {"id": "a", "prompt_file": "does/not/exist.txt",
                 "a": {"label": "A", "port": 1}, "b": {"label": "B", "port": 2}},
            ]}, "prompt_file: not found"),
        ("n=0", {
            "name": "x", "defaults": {"n": 0}, "jobs": [
                {"id": "a", "a": {"label": "A", "port": 1}, "b": {"label": "B", "port": 2}},
            ]}, "defaults.n"),
        ("both prompt and prompt_file", {
            "name": "x", "jobs": [
                {"id": "a", "prompt": "x", "prompt_file": "y",
                 "a": {"label": "A", "port": 1}, "b": {"label": "B", "port": 2}},
            ]}, "only one of prompt"),
    ]
    rc = 0
    for label, suite, needle in cases:
        try:
            validate(suite)
        except SuiteError as e:
            if needle in str(e):
                print(f"PASS {label}: {e}")
            else:
                print(f"FAIL {label}: wrong error: {e}")
                rc = 1
        else:
            print(f"FAIL {label}: validate() did not raise")
            rc = 1
    return rc


def main(argv: List[str]) -> int:
    if len(argv) < 2:
        print("usage: bench_suite.py validate <file>... | selftest", file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "validate":
        if len(argv) < 3:
            print("usage: bench_suite.py validate <file>...", file=sys.stderr)
            return 2
        return _cmd_validate(argv[2:])
    if cmd == "selftest":
        return _cmd_selftest()
    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
