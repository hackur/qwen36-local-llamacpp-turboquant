#!/usr/bin/env python3
"""Start bench_runner independently of the optional Textual UI dependency."""

from __future__ import annotations

import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent


def spawn_runner(suite: Path, base: Path | None = None) -> Path:
    """Create run metadata and launch a detached headless benchmark runner."""
    base = base or REPO / "benchmarks" / "runs"
    base.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = base / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    suite = suite.resolve()
    (run_dir / "suite_files.txt").write_text(f"{suite}\n", encoding="utf-8")
    log = (run_dir / "runner.log").open("a", encoding="utf-8")
    try:
        process = subprocess.Popen(
            [
                sys.executable,
                str(REPO / "scripts" / "bench_runner.py"),
                "run",
                str(suite),
                "--run-id",
                run_id,
            ],
            cwd=REPO,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    finally:
        log.close()
    (run_dir / "runner.pid").write_text(f"{process.pid}\n", encoding="utf-8")
    return run_dir
