"""Regression tests for scripts/stop-all.sh and scripts/stop-proxy.sh.

These tests exercise the *scanning* logic in isolation, never the kill
paths: stop-all's PID discovery (the ps/awk replacement for pgrep -f,
which cannot see llama-server's 700+ character command line) and
stop-proxy's port-anchored discovery (it must not match a process that
merely *references* port 11500, e.g. lsof itself).

Run: python3 -m unittest discover -s tests
Stdlib-only; does not start or stop any real process.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


class StopAllScannerTests(unittest.TestCase):
    """The awk program in stop-all.sh must select exactly the repo's model servers."""

    AWK_SOURCE_RE = re.compile(
        r"ps -axww -o pid=,command= \| awk -v repo=.*?\n(.*?)\n  ' \| sort -u",
        re.DOTALL,
    )

    def _awk_program(self):
        source = (REPO / "scripts" / "stop-all.sh").read_text()
        match = self.AWK_SOURCE_RE.search(source)
        self.assertIsNotNone(match, "stop-all.sh: ps/awk scanner not found")
        return match.group(1)

    def _scan(self, repo: str, ps_lines: list[str]) -> set[str]:
        # Mirror the shell pipeline: awk over 'pid command' lines, collect PIDs.
        program = self._awk_program()
        import subprocess
        import tempfile

        with tempfile.NamedTemporaryFile("w+", suffix=".ps", delete=False) as fh:
            fh.write("\n".join(ps_lines) + "\n")
            name = fh.name
        try:
            out = subprocess.run(
                ["awk", "-v", f"repo={repo}", program, name],
                capture_output=True,
                text=True,
            )
            self.assertEqual(out.returncode, 0, out.stderr)
            return set(out.stdout.split())
        finally:
            Path(name).unlink(missing_ok=True)

    def test_matches_full_command_line(self):
        # llama-server's real argv exceeds 700 chars; pgrep -f missed it.
        long_args = "".join(f"--flag{i} value{i} " for i in range(60))
        server = f"{REPO}/vendor/llama-cpp-turboquant/build/bin/llama-server {long_args}"
        self.assertGreater(len(server), 700)
        lines = [
            f"99901 {server}",
            "99902 -/usr/libexec/kernelmanager",  # unrelated noise
        ]
        self.assertEqual(self._scan(str(REPO), lines), {"99901"})

    def test_matches_mainline_variant(self):
        server = f"{REPO}/vendor/llama.cpp-mainline/build/bin/llama-server -m /x.gguf"
        self.assertEqual(self._scan(str(REPO), [f"12345 {server}"]), {"12345"})

    def test_does_not_match_other_repos(self):
        other = "/Volumes/OTHER/repo/vendor/llama-cpp-turboquant/build/bin/llama-server"
        self.assertEqual(self._scan(str(REPO), [f"777 {other}"]), set())

    def test_does_not_match_unrelated_llama_server(self):
        # Homebrew or another checkout must never be killed.
        unrelated = "/opt/homebrew/bin/llama-server -m model.gguf"
        self.assertEqual(self._scan(str(REPO), [f"555 {unrelated}"]), set())

    def test_multiple_servers_deduplicated_via_sort(self):
        a = f"{REPO}/vendor/llama-cpp-turboquant/build/bin/llama-server -m a.gguf"
        b = f"{REPO}/vendor/llama.cpp-mainline/build/bin/llama-server -m b.gguf"
        found = self._scan(str(REPO), ["11 " + a, "22 " + b, "33 " + a])
        # 33 is a second line for the same path; scanner reports both PIDs,
        # the shell's sort -u dedupes by PID, not path.
        self.assertEqual(found, {"11", "22", "33"})


class StopProxyScannerTests(unittest.TestCase):
    """stop-proxy.sh discovers the proxy by its LISTEN port, never argv."""

    def test_uses_lsof_listen_only(self):
        source = (REPO / "scripts" / "stop-proxy.sh").read_text()
        self.assertIn('lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t', source)
        # The discovery function must be lsof-only; node argv matching
        # (pgrep -f) cannot distinguish this proxy from any other node process.
        m = re.search(r"list_pids\(\) \{([^}]*)\}", source, re.DOTALL)
        self.assertIsNotNone(m, "list_pids function not found")
        self.assertNotIn("pgrep", m.group(1))
        self.assertNotIn("ps -ax", m.group(1))

    def test_port_matches_checked_in_config(self):
        # Keep the script's port in sync with proxy/config.yaml listen.port.
        script_port = int(re.search(r"^PORT=(\d+)", (REPO / "scripts" / "stop-proxy.sh").read_text(), re.M).group(1))
        import yaml  # available in the system python used by make check
        cfg = yaml.safe_load((REPO / "proxy" / "config.yaml").read_text())
        self.assertEqual(script_port, cfg["listen"]["port"])

    def test_two_phase_kill_discipline(self):
        source = (REPO / "scripts" / "stop-proxy.sh").read_text()
        self.assertIn("kill \"$pid\"", source)          # SIGTERM pass
        self.assertIn("kill -9 \"$pid\"", source)       # SIGKILL stragglers
        self.assertIn("survivors", source)              # loud failure report


if __name__ == "__main__":
    unittest.main()
