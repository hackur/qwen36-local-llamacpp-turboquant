#!/usr/bin/env python3
# bench_runner.py — sequential A/B llama.cpp bench runner with JSONL event/control protocol.
import argparse, atexit, json, os, signal, sys, socket, time, fcntl, statistics, urllib.request, urllib.error
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RUNS_DIR = REPO / "benchmarks" / "runs"
LOCK_PATH = RUNS_DIR / ".bench.lock"
PHASES = {"queued", "waiting_port", "warming", "running", "ok", "failed", "skipped", "stopped", "warning"}


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def is_listening(port, host="127.0.0.1", timeout=0.5):
    try:
        with socket.create_connection((host, port), timeout):
            return True
    except OSError:
        return False


class Events:
    def __init__(self, path):
        self.path = path
        self.path.touch()

    def emit(self, **ev):
        ev = {"ts": now_iso(), **ev}
        assert ev["phase"] in PHASES, ev["phase"]
        with self.path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(ev, ensure_ascii=False) + "\n")
        return ev


class Control:
    def __init__(self, path, offset_path):
        self.path = path
        self.offset_path = offset_path
        self.path.touch()
        self.offset = int(self.offset_path.read_text()) if self.offset_path.exists() else 0

    def drain(self):
        actions = []
        try:
            with self.path.open("r", encoding="utf-8") as f:
                f.seek(self.offset)
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            actions.append(json.loads(line))
                        except json.JSONDecodeError:
                            actions.append({"_bad": line})
                self.offset = f.tell()
            tmp = self.offset_path.with_suffix(self.offset_path.suffix + ".tmp")
            tmp.write_text(str(self.offset))
            os.replace(tmp, self.offset_path)
        except OSError:
            pass
        return actions


def http_chat(port, prompt, max_tokens, timeout=600):
    body = json.dumps({
        "model": "local",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "chat_template_kwargs": {"enable_thinking": False},
    }).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=body, headers={"Content-Type": "application/json"}, method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def wait_solo(want_port, other_port, events, job_id, side):
    state = None
    while True:
        a = is_listening(want_port)
        b = is_listening(other_port)
        if a and not b:
            return
        if a and b:
            new_state = "both_listening"
        elif not a:
            new_state = "want_down"
        else:
            new_state = "unknown"
        if new_state != state:
            events.emit(phase="waiting_port", job=job_id, side=side,
                        want_port=want_port, other_port=other_port, state=new_state)
            state = new_state
        time.sleep(2)


def bench_side(job, side_key, events, raw_runs, control, abort_flag):
    side = job[side_key]
    other = job["b" if side_key == "a" else "a"]
    label = side["label"]
    port = side["port"]
    other_port = other["port"]
    side_tag = "A" if side_key == "a" else "B"
    job_id = job["id"]
    n = job["n"]
    max_tokens = job["max_tokens"]
    prompt = job["prompt"]

    wait_solo(port, other_port, events, job_id, side_tag)

    events.emit(phase="warming", job=job_id, side=side_tag, label=label, port=port)
    try:
        http_chat(port, prompt, max_tokens)
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, json.JSONDecodeError) as e:
        raise RuntimeError(f"warmup failed on {side_tag} (:{port}): {e}")

    tps_list = []
    for i in range(1, n + 1):
        for act in control.drain():
            if act.get("action") == "stop" and act.get("job") == job_id:
                abort_flag["stopped"] = True
                return None
        try:
            resp = http_chat(port, prompt, max_tokens)
        except (urllib.error.URLError, urllib.error.HTTPError, OSError, json.JSONDecodeError) as e:
            raise RuntimeError(f"run {i} failed on {side_tag} (:{port}): {e}")
        timings = resp.get("timings", {}) or {}
        tps = float(timings.get("predicted_per_second") or 0.0)
        pn = int(timings.get("predicted_n") or 0)
        tps_list.append(tps)
        raw_runs.append({"side": side_tag, "label": label, "port": port, "run": i, "timings": timings})
        events.emit(phase="running", job=job_id, side=side_tag, label=label, port=port,
                    run=i, tok_s=round(tps, 2), predicted_n=pn)
    return {
        "median": round(statistics.median(tps_list), 2),
        "min": round(min(tps_list), 2),
        "max": round(max(tps_list), 2),
        "n": n,
    }


def run_job(job, run_dir, events, control):
    job_id = job["id"]
    raw_runs = []
    raw_path = run_dir / f"{job_id}.json"
    abort = {"stopped": False}
    try:
        for act in control.drain():
            if act.get("action") == "skip" and act.get("job") == job_id:
                events.emit(phase="skipped", job=job_id)
                return {"job": job_id, "phase": "skipped"}
            if act.get("action") == "stop" and act.get("job") == job_id:
                events.emit(phase="skipped", job=job_id, note="stop-while-queued")
                return {"job": job_id, "phase": "skipped"}
        a_summary = bench_side(job, "a", events, raw_runs, control, abort)
        if abort["stopped"]:
            raw_path.write_text(json.dumps(raw_runs, indent=2))
            events.emit(phase="stopped", job=job_id)
            return {"job": job_id, "phase": "stopped"}
        b_summary = bench_side(job, "b", events, raw_runs, control, abort)
        if abort["stopped"]:
            raw_path.write_text(json.dumps(raw_runs, indent=2))
            events.emit(phase="stopped", job=job_id)
            return {"job": job_id, "phase": "stopped"}
        summary = {"a": a_summary, "b": b_summary}
        raw_path.write_text(json.dumps(raw_runs, indent=2))
        events.emit(phase="ok", job=job_id, summary=summary)
        return {"job": job_id, "phase": "ok", "summary": summary}
    except Exception as e:
        try:
            raw_path.write_text(json.dumps(raw_runs, indent=2))
        except OSError:
            pass
        events.emit(phase="failed", job=job_id, error=str(e))
        return {"job": job_id, "phase": "failed", "error": str(e)}


def acquire_lock():
    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(LOCK_PATH), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        try:
            with open(LOCK_PATH) as f:
                pid = f.read().strip() or "?"
        except OSError:
            pid = "?"
        print(f"another bench runner is active (pid {pid}) — only one allowed (thermal).", file=sys.stderr)
        sys.exit(2)
    os.ftruncate(fd, 0)
    os.write(fd, f"{os.getpid()}\n".encode())

    def _release():
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            LOCK_PATH.unlink()
        except OSError:
            pass
    atexit.register(_release)
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    return fd


def load_suites(paths):
    try:
        import bench_suite
    except ImportError:
        print("bench_suite module missing — Component A (scripts/bench_suite.py) must exist.", file=sys.stderr)
        sys.exit(3)
    jobs = []
    for p in paths:
        suite = bench_suite.load(p)
        bench_suite.validate(suite)
        defaults = suite.get("defaults", {}) or {}
        for j in suite.get("jobs", []):
            jobs.append(bench_suite.merge_defaults(j, defaults))
    return jobs


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("suites", nargs="+")
    r.add_argument("--run-id")
    r.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    jobs = load_suites(args.suites)

    if args.dry_run:
        print(json.dumps(jobs, indent=2, default=str))
        return

    run_id = args.run_id or datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = RUNS_DIR / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    lock_fd = acquire_lock()

    events = Events(run_dir / "events.jsonl")
    control = Control(run_dir / "control.jsonl", run_dir / ".control.offset")

    for j in jobs:
        events.emit(phase="queued", job=j["id"])

    queue = list(jobs)
    results = []
    while queue:
        for act in control.drain():
            if act.get("action") == "start":
                tgt = act.get("job")
                for i, j in enumerate(queue):
                    if j["id"] == tgt and i > 0:
                        queue.insert(0, queue.pop(i))
                        break
            elif act.get("action") == "skip":
                tgt = act.get("job")
                for i, j in enumerate(queue):
                    if j["id"] == tgt:
                        events.emit(phase="skipped", job=tgt)
                        results.append({"job": tgt, "phase": "skipped"})
                        queue.pop(i)
                        break
            elif act.get("action") == "stop":
                tgt = act.get("job")
                for i, j in enumerate(queue):
                    if j["id"] == tgt:
                        events.emit(phase="skipped", job=tgt, note="stop-while-queued")
                        results.append({"job": tgt, "phase": "skipped"})
                        queue.pop(i)
                        break
            elif "_bad" in act:
                events.emit(phase="warning", note="malformed control line", raw=act["_bad"])
            elif act.get("action"):
                events.emit(phase="warning", note=f"unknown action: {act.get('action')}")
        if not queue:
            break
        job = queue.pop(0)
        results.append(run_job(job, run_dir, events, control))

    (run_dir / "summary.json").write_text(json.dumps({
        "run_id": run_id,
        "jobs": results,
    }, indent=2))


if __name__ == "__main__":
    main()
