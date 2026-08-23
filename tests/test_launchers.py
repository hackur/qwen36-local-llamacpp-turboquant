import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


class LauncherDryRunTests(unittest.TestCase):
    """Behavioral coverage for launchers without loading a 27B model."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.model = root / "qwen38.gguf"
        self.mmproj = root / "qwen38.mmproj.gguf"
        self.model.touch()
        self.mmproj.touch()
        self.server = root / "llama-server"
        self.server.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ ${1:-} == --help ]]; then\n"
            "  echo 'turbo3 draft-mtp-adaptive --spec-chain --mmproj "
            "--image-min-tokens --reasoning-preserve --metrics --agent "
            "--mcp-servers-config'\n"
            "  exit 0\n"
            "fi\n"
            "echo 'fake server must never launch during a dry-run' >&2\n"
            "exit 97\n",
            encoding="utf-8",
        )
        self.server.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def run_launcher(self, script, **overrides):
        env = os.environ.copy()
        env.update(
            {
                "MODEL_FILE": str(self.model),
                "MMPROJ_FILE": str(self.mmproj),
                "TURBOQUANT_BIN": str(self.server),
                "MAINLINE_BIN": str(self.server),
            }
        )
        env.update(overrides)
        return subprocess.run(
            [str(REPO / "scripts" / script), "--dry-run"],
            cwd=REPO,
            env=env,
            check=True,
            text=True,
            capture_output=True,
        ).stdout

    def test_full_runtime_enables_every_qwen38_feature(self):
        output = self.run_launcher("start-turboquant.sh")
        expected = (
            "--mmproj",
            "--image-min-tokens 1024",
            "--ctx-size 262144",
            "--cache-type-k q8_0",
            "--cache-type-v turbo3",
            "--spec-type draft-mtp-adaptive",
            "--spec-draft-n-min-adaptive 3",
            "--spec-draft-n-max 8",
            "--spec-chain 8",
            "--reasoning-preserve",
            "--metrics",
            "--agent",
            "--alias qwen3.8-local",
        )
        for value in expected:
            with self.subTest(value=value):
                self.assertIn(value, output)

    def test_baseline_is_same_model_without_mtp_or_turboquant(self):
        output = self.run_launcher("start-baseline.sh")
        self.assertIn("--port 10500", output)
        self.assertIn("--ctx-size 32768", output)
        self.assertIn("--cache-type-k f16 --cache-type-v f16", output)
        self.assertIn("--mmproj", output)
        self.assertIn("--agent", output)
        self.assertNotIn("--spec-type", output)
        self.assertNotIn("turbo3", output)

    def test_offline_override_disables_agent_mode_only(self):
        output = self.run_launcher("start-turboquant.sh", AGENT="0")
        self.assertNotIn("--agent", output)
        self.assertIn("--spec-type draft-mtp-adaptive", output)
        self.assertIn("--mmproj", output)


if __name__ == "__main__":
    unittest.main()
