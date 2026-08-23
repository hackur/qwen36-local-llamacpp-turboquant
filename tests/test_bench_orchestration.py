import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]


class BenchOrchestrationTests(unittest.TestCase):
    def test_qwen38_suite_validates_and_has_no_legacy_model(self):
        result = subprocess.run(
            [
                sys.executable,
                str(REPO / "scripts" / "bench_suite.py"),
                "validate",
                str(REPO / "benchmarks" / "suites" / "qwen38-features.yaml"),
            ],
            cwd=REPO,
            text=True,
            capture_output=True,
            check=True,
        )
        self.assertIn("OK qwen38-features.yaml", result.stdout)

    def test_spawn_runner_records_process_and_suite(self):
        sys.path.insert(0, str(REPO / "scripts"))
        import bench_spawn

        suite = REPO / "benchmarks" / "suites" / "qwen38-features.yaml"
        with tempfile.TemporaryDirectory() as tmp:
            # Exercise subprocess construction in an isolated current directory.
            old = Path.cwd()
            try:
                import os

                os.chdir(tmp)
                with patch.object(bench_spawn.subprocess, "Popen") as popen:
                    popen.return_value.pid = 4242
                    run_dir = bench_spawn.spawn_runner(suite, Path(tmp) / "runs")
                self.assertEqual("4242", (run_dir / "runner.pid").read_text().strip())
                self.assertEqual(str(suite.resolve()), (run_dir / "suite_files.txt").read_text().strip())
                args = popen.call_args.args[0]
                self.assertIn("bench_runner.py", " ".join(args))
                self.assertIn("--run-id", args)
            finally:
                os.chdir(old)


if __name__ == "__main__":
    unittest.main()
