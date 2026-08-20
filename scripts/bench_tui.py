#!/usr/bin/env python3
# Interactive A/B bench TUI — tails events.jsonl, writes control.jsonl. Component C of P5.
from __future__ import annotations

import argparse
import asyncio
import json
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

try:
    from textual.app import App, ComposeResult
    from textual.binding import Binding
    from textual.containers import Horizontal, Vertical
    from textual.screen import ModalScreen
    from textual.widgets import DataTable, Footer, Header, RichLog, Static, Tree
except ImportError:
    sys.stderr.write("textual not installed; run: pip install -r requirements-tui.txt\n")
    sys.exit(2)

PHASE_GLYPH = {
    "queued": "·", "waiting_port": "…", "warming": "🔥", "running": "⚙",
    "ok": "✓", "failed": "✗", "skipped": "⊘", "stopped": "⊘", "warning": "⚠",
}
TERMINAL = {"ok", "failed", "skipped", "stopped"}
LOG_COLORS = {
    "ok": "green", "failed": "red", "warning": "yellow",
    "waiting_port": "yellow", "warming": "magenta", "running": "cyan",
    "queued": "dim", "skipped": "dim", "stopped": "dim",
}


@dataclass
class SideState:
    label: str = ""
    port: Optional[int] = None
    runs_done: int = 0
    runs_total: int = 0
    last_tok_s: Optional[float] = None
    median: Optional[float] = None
    min_v: Optional[float] = None
    max_v: Optional[float] = None
    phase: str = "queued"


@dataclass
class JobState:
    job_id: str
    group: str = ""
    phase: str = "queued"
    a: SideState = field(default_factory=SideState)
    b: SideState = field(default_factory=SideState)
    error: str = ""


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def derive_group(job_id: str) -> str:
    return job_id.split("-", 1)[0] if "-" in job_id else job_id


class HelpScreen(ModalScreen):
    BINDINGS = [Binding("escape,q,question_mark", "app.pop_screen", "close")]

    def compose(self) -> ComposeResult:
        yield Static(
            "[b]Keybinds[/b]\n\n"
            "↑/↓     navigate tree\n"
            "Enter   expand/collapse group\n"
            "s       stop selected job\n"
            "r       start/run selected job\n"
            "k       skip selected job\n"
            "q       quit TUI (runner keeps running)\n"
            "?       this help\n\n"
            "[dim]press esc to close[/dim]",
            id="help-box",
        )


class BenchTUI(App):
    CSS = """
    #left { width: 30%; border: solid grey; }
    #right { width: 70%; }
    #table { height: 60%; border: solid grey; }
    #log { height: 40%; border: solid grey; }
    #status { dock: bottom; height: 1; background: $accent; color: $text; }
    #help-box { width: 60; height: auto; border: thick $accent; padding: 1 2; background: $surface; }
    """
    BINDINGS = [
        Binding("s", "ctrl_stop", "stop"),
        Binding("r", "ctrl_start", "start"),
        Binding("k", "ctrl_skip", "skip"),
        Binding("q", "quit", "quit"),
        Binding("question_mark", "help", "help"),
    ]

    def __init__(self, run_dir: Path):
        super().__init__()
        self.run_dir = run_dir
        self.events_path = run_dir / "events.jsonl"
        self.control_path = run_dir / "control.jsonl"
        self.jobs: dict[str, JobState] = {}
        self.group_nodes: dict[str, object] = {}
        self.job_nodes: dict[str, object] = {}
        self.selected_job: Optional[str] = None
        self.running_job: Optional[str] = None

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal():
            with Vertical(id="left"):
                tree: Tree = Tree("jobs", id="tree")
                tree.root.expand()
                yield tree
            with Vertical(id="right"):
                yield DataTable(id="table")
                yield RichLog(id="log", highlight=False, markup=True, max_lines=200)
        yield Static("waiting for events…", id="status")
        yield Footer()

    def on_mount(self) -> None:
        tbl: DataTable = self.query_one("#table", DataTable)
        tbl.add_columns("side", "label", "port", "runs (k/N)", "last tok/s", "median", "min", "max", "phase")
        self._prefill_from_suite()
        self.refresh_tree()
        self.refresh_table()
        self.set_status("Waiting for runner…")
        self.query_one("#tree", Tree).focus()
        asyncio.create_task(self.tail_events())

    def _prefill_from_suite(self) -> None:
        sf = self.run_dir / "suite_files.txt"
        if not sf.exists():
            return
        try:
            import yaml  # type: ignore
        except ImportError:
            return
        for line in sf.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            p = Path(line)
            if not p.exists():
                continue
            try:
                doc = yaml.safe_load(p.read_text()) or {}
            except Exception as e:
                msg = f"[warning] suite load failed: {type(e).__name__}: {str(e)[:80]}"
                self.call_after_refresh(self._warn_log, msg)
                continue
            group = doc.get("name") or p.stem
            defaults = doc.get("defaults") or {}
            default_n = int(defaults.get("n", 0) or 0)
            for jd in doc.get("jobs", []) or []:
                jid = jd.get("id")
                if not jid:
                    continue
                js = self.jobs.setdefault(jid, JobState(job_id=jid, group=group))
                js.group = group
                a = jd.get("a") or {}
                b = jd.get("b") or {}
                js.a.label = a.get("label", "")
                js.a.port = a.get("port")
                js.b.label = b.get("label", "")
                js.b.port = b.get("port")
                n = int(jd.get("n", default_n) or default_n)
                js.a.runs_total = js.b.runs_total = n

    def refresh_tree(self) -> None:
        tree: Tree = self.query_one("#tree", Tree)
        groups: dict[str, list[JobState]] = {}
        for j in self.jobs.values():
            grp = j.group or derive_group(j.job_id)
            groups.setdefault(grp, []).append(j)
        # rebuild from scratch (simple, small N)
        tree.clear()
        self.group_nodes.clear()
        self.job_nodes.clear()
        for grp in sorted(groups):
            gn = tree.root.add(grp, expand=True)
            self.group_nodes[grp] = gn
            for js in sorted(groups[grp], key=lambda x: x.job_id):
                glyph = PHASE_GLYPH.get(js.phase, "?")
                node = gn.add_leaf(f"{glyph} {js.job_id}", data=js.job_id)
                self.job_nodes[js.job_id] = node

    def refresh_table(self) -> None:
        tbl: DataTable = self.query_one("#table", DataTable)
        tbl.clear()
        jid = self.selected_job
        if jid is None or jid not in self.jobs:
            return
        js = self.jobs[jid]
        for side_name, s in (("A", js.a), ("B", js.b)):
            tbl.add_row(
                side_name,
                s.label or "",
                str(s.port) if s.port is not None else "",
                f"{s.runs_done}/{s.runs_total}",
                f"{s.last_tok_s:.2f}" if s.last_tok_s is not None else "",
                f"{s.median:.2f}" if s.median is not None else "",
                f"{s.min_v:.2f}" if s.min_v is not None else "",
                f"{s.max_v:.2f}" if s.max_v is not None else "",
                s.phase,
            )

    def set_status(self, msg: Optional[str] = None) -> None:
        st: Static = self.query_one("#status", Static)
        n_total = len(self.jobs)
        n_done = sum(1 for j in self.jobs.values() if j.phase in TERMINAL)
        running = self.running_job or "—"
        base = f"run-id {self.run_dir.name} · jobs: {n_done}/{n_total} · running: {running}"
        if msg:
            base = f"{base} · {msg}"
        st.update(base)

    def on_tree_node_selected(self, event) -> None:
        data = getattr(event.node, "data", None)
        if isinstance(data, str):
            self.selected_job = data
            self.refresh_table()

    def on_tree_node_highlighted(self, event) -> None:
        data = getattr(event.node, "data", None)
        if isinstance(data, str):
            self.selected_job = data
            self.refresh_table()

    # ---------- event tail ----------
    async def tail_events(self) -> None:
        path = self.events_path
        log: RichLog = self.query_one("#log", RichLog)
        f = None
        inode = None
        while True:
            try:
                if f is None:
                    if not path.exists():
                        await asyncio.sleep(0.1)
                        continue
                    f = path.open("r", encoding="utf-8")
                    try:
                        inode = path.stat().st_ino
                    except OSError:
                        inode = None
                line = f.readline()
                if not line:
                    # check rotation
                    try:
                        cur_inode = path.stat().st_ino
                        if inode is not None and cur_inode != inode:
                            f.close()
                            f = None
                            continue
                    except OSError:
                        pass
                    await asyncio.sleep(0.1)
                    continue
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                self.handle_event(ev, log)
            except Exception as e:
                log.write(f"[red]tail error: {e}[/red]")
                if f is not None:
                    try:
                        f.close()
                    except Exception:
                        pass
                    f = None
                await asyncio.sleep(0.5)

    def handle_event(self, ev: dict, log: RichLog) -> None:
        phase = ev.get("phase", "")
        jid = ev.get("job", "")
        if not jid:
            return
        js = self.jobs.get(jid)
        if js is None:
            js = JobState(job_id=jid, group=derive_group(jid))
            self.jobs[jid] = js
            self.refresh_tree()
        js.phase = phase or js.phase
        side = ev.get("side")
        side_state: Optional[SideState] = None
        if side == "A":
            side_state = js.a
        elif side == "B":
            side_state = js.b
        if side_state is not None:
            side_state.phase = phase or side_state.phase
            if "port" in ev and ev["port"] is not None:
                try:
                    side_state.port = int(ev["port"])
                except (TypeError, ValueError):
                    pass
            if phase == "running":
                if "run" in ev:
                    try:
                        side_state.runs_done = max(side_state.runs_done, int(ev["run"]))
                    except (TypeError, ValueError):
                        pass
                if "tok_s" in ev:
                    try:
                        side_state.last_tok_s = float(ev["tok_s"])
                    except (TypeError, ValueError):
                        pass
        if phase == "ok":
            summary = ev.get("summary") or {}
            for key, dst in (("a", js.a), ("b", js.b)):
                s = summary.get(key) or {}
                if "median" in s:
                    dst.median = s.get("median")
                if "min" in s:
                    dst.min_v = s.get("min")
                if "max" in s:
                    dst.max_v = s.get("max")
                if "n" in s:
                    try:
                        dst.runs_total = max(dst.runs_total, int(s["n"]))
                        dst.runs_done = max(dst.runs_done, int(s["n"]))
                    except (TypeError, ValueError):
                        pass
                dst.phase = "ok"
        if phase == "failed":
            js.error = ev.get("error", "")
        # running-job tracking
        if phase in ("warming", "running", "waiting_port"):
            self.running_job = jid
        elif phase in TERMINAL and self.running_job == jid:
            self.running_job = None
        # update widgets
        self._update_tree_label(jid)
        if jid == self.selected_job:
            self.refresh_table()
        color = LOG_COLORS.get(phase, "white")
        ts = ev.get("ts", now_iso())
        extra = ""
        if phase == "running" and "tok_s" in ev:
            extra = f" run={ev.get('run')} tok/s={ev.get('tok_s')}"
        elif phase == "failed":
            extra = f" error={ev.get('error','')}"
        elif phase == "waiting_port":
            extra = f" port={ev.get('port')} state={ev.get('state')}"
        elif phase == "ok":
            extra = " (done)"
        log.write(f"[dim]{ts}[/dim] [{color}]{phase:<13}[/{color}] {jid}{extra}")
        self.set_status()

    def _warn_log(self, msg: str) -> None:
        try:
            log: RichLog = self.query_one("#log", RichLog)
            log.write(f"[yellow]{msg}[/yellow]")
        except Exception:
            pass

    def _update_tree_label(self, jid: str) -> None:
        node = self.job_nodes.get(jid)
        if node is None:
            self.refresh_tree()
            return
        js = self.jobs[jid]
        glyph = PHASE_GLYPH.get(js.phase, "?")
        try:
            node.set_label(f"{glyph} {jid}")
        except Exception:
            pass

    # ---------- control writes ----------
    def write_control(self, action: str) -> None:
        if not self.selected_job:
            self.set_status("no job selected")
            return
        self.control_path.parent.mkdir(parents=True, exist_ok=True)
        rec = {"ts": now_iso(), "action": action, "job": self.selected_job}
        with self.control_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")
        log: RichLog = self.query_one("#log", RichLog)
        log.write(f"[bold yellow]→ control[/bold yellow] {action} {self.selected_job}")

    def action_ctrl_stop(self) -> None:
        self.write_control("stop")

    def action_ctrl_start(self) -> None:
        self.write_control("start")

    def action_ctrl_skip(self) -> None:
        self.write_control("skip")

    def action_help(self) -> None:
        self.push_screen(HelpScreen())


def pick_latest() -> Optional[Path]:
    base = Path("benchmarks/runs")
    if not base.exists():
        return None
    candidates = [p for p in base.iterdir() if p.is_dir() and not p.name.startswith(".")]
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_mtime)


def spawn_runner_stub(suite: Path) -> Path:
    # Minimal stub: create a fresh run dir and note the suite. Component B owns the real subprocess.
    base = Path("benchmarks/runs")
    base.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = base / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "suite_files.txt").write_text(str(suite.resolve()) + "\n")
    sys.stderr.write(f"[bench_tui] --spawn is a stub; created {run_dir}. Start bench_runner.py manually.\n")
    return run_dir


def main() -> int:
    ap = argparse.ArgumentParser(description="A/B bench TUI")
    ap.add_argument("target", nargs="?", help="run-dir or suite.yaml")
    ap.add_argument("--latest", action="store_true", help="auto-pick newest benchmarks/runs/*/")
    ap.add_argument("--spawn", action="store_true", help="(stub) spawn runner for given suite")
    args = ap.parse_args()

    run_dir: Optional[Path] = None
    if args.latest:
        run_dir = pick_latest()
        if run_dir is None:
            sys.stderr.write("no run directories under benchmarks/runs/\n")
            return 1
    elif args.target:
        p = Path(args.target)
        if p.is_dir():
            run_dir = p
        elif p.suffix in (".yaml", ".yml") and p.is_file():
            if args.spawn:
                run_dir = spawn_runner_stub(p)
            else:
                sys.stderr.write("suite file given without --spawn; pass a run-dir instead\n")
                return 2
        else:
            sys.stderr.write(f"target not found: {p}\n")
            return 1
    else:
        ap.print_help()
        return 2

    run_dir.mkdir(parents=True, exist_ok=True)
    app = BenchTUI(run_dir)
    app.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
