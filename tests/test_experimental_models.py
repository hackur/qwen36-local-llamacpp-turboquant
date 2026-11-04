"""Behavioral checks without model downloads, running servers, or Metal."""

from contextlib import redirect_stderr, redirect_stdout
import errno
import importlib.util
import io
import os
from pathlib import Path
import shlex
import socket
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/experimental-models.py"
SPEC = importlib.util.spec_from_file_location("experimental_models", SCRIPT)
runtime = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runtime
SPEC.loader.exec_module(runtime)


class ExperimentalModelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="experimental models ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "project with spaces"
        self.home = Path(self.temp.name) / "home with spaces"
        self.profiles = runtime.profiles(self.root, self.home)
        for profile in self.profiles.values():
            profile.model.parent.mkdir(parents=True, exist_ok=True)
            profile.model.write_bytes(b"GGUF")
            profile.engine.parent.mkdir(parents=True, exist_ok=True)
            profile.engine.write_text("#!/bin/sh\nexit 97\n")
            profile.engine.chmod(0o755)

    def invoke(self, *args):
        output, error = io.StringIO(), io.StringIO()
        with redirect_stdout(output), redirect_stderr(error):
            code = runtime.main(args, repo_root=self.root, home=self.home)
        return code, output.getvalue(), error.getvalue()

    def dry_run(self, profile, *args):
        with patch.object(runtime.os, "execve") as launch:
            code, output, error = self.invoke("start", profile, "--dry-run", *args)
        launch.assert_not_called()
        self.assertEqual(code, 0, error)
        return shlex.split(output)

    def test_each_profile_selects_exact_existing_file_and_expected_engine(self):
        self.assertEqual(set(self.profiles), {
            "lfm3-1.7b", "crow-9b", "mimo-9b", "journalist-9b",
        })
        for name, profile in self.profiles.items():
            with self.subTest(name=name):
                command = self.dry_run(name)
                self.assertEqual(command[0], str(profile.engine))
                self.assertEqual(command[command.index("--model") + 1], str(profile.model))
                self.assertEqual(command[command.index("--alias") + 1], profile.alias)
                self.assertIn("with spaces", command[0])
                self.assertIn("with spaces", str(profile.model))

    def test_explicit_defaults_do_not_inherit_primary_runtime_values(self):
        with patch.dict(os.environ, {
            "PORT": "10501", "CTX": "262144", "MODEL_NAME": "qwen3.8-local",
            "AGENT": "1", "MTP": "1", "MMPROJ_FILE": "/unexpected/projector.gguf",
        }):
            command = self.dry_run("lfm3-1.7b")
        for flag, expected in {
            "--host": "127.0.0.1", "--port": "10502", "--ctx-size": "4096",
            "--threads": "2", "--threads-batch": "2", "--prio": "-1", "--parallel": "1",
            "--cache-type-k": "f16", "--cache-type-v": "f16",
            "--reasoning": "auto",
        }.items():
            self.assertEqual(command[command.index(flag) + 1], expected)
        self.assertIn("--jinja", command)
        self.assertIn("--offline", command)
        for flag in ("--agent", "--mcp-servers-config", "--mmproj", "--spec-type",
                     "--rope-scaling", "--chat-template", "--hf-repo"):
            self.assertNotIn(flag, command)
        self.assertNotIn("qwen3.8-local", command)

    def test_profile_specific_sampling(self):
        lfm = self.dry_run("lfm3-1.7b")
        qwen = self.dry_run("crow-9b")
        for command, temp, top_k, repeat in (
            (lfm, "0.1", "50", "1.1"), (qwen, "0.6", "20", "1.0"),
        ):
            self.assertEqual(command[command.index("--temp") + 1], temp)
            self.assertEqual(command[command.index("--top-k") + 1], top_k)
            self.assertEqual(command[command.index("--repeat-penalty") + 1], repeat)

    def test_explicit_port_context_and_engine_overrides(self):
        engine = Path(self.temp.name) / "custom engine with spaces"
        engine.write_text("#!/bin/sh\nexit 97\n")
        engine.chmod(0o755)
        command = self.dry_run("lfm3-1.7b", "--port", "10503", "--ctx", "8192",
                               "--engine", str(engine))
        self.assertEqual(command[0], str(engine.resolve()))
        self.assertEqual(command[command.index("--port") + 1], "10503")
        self.assertEqual(command[command.index("--ctx-size") + 1], "8192")

    def test_unknown_profile_is_rejected_before_launch(self):
        with patch.object(runtime.os, "execve") as launch:
            with self.assertRaises(SystemExit) as error:
                self.invoke("start", "../../another-profile")
        self.assertEqual(error.exception.code, 2)
        launch.assert_not_called()

    def test_missing_model_is_rejected_before_engine_execution(self):
        self.profiles["lfm3-1.7b"].model.unlink()
        with patch.object(runtime.os, "execve") as launch:
            code, _, error = self.invoke("start", "lfm3-1.7b")
        self.assertEqual(code, 1)
        self.assertIn("model file is missing", error)
        launch.assert_not_called()

    def test_missing_engine_is_rejected_before_launch(self):
        self.profiles["lfm3-1.7b"].engine.unlink()
        with patch.object(runtime.os, "execve") as launch:
            code, _, error = self.invoke("start", "lfm3-1.7b")
        self.assertEqual(code, 1)
        self.assertIn("engine is missing or not executable", error)
        launch.assert_not_called()

    def test_occupied_port_is_rejected_without_launch_or_eviction(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            port = listener.getsockname()[1]
            with patch.object(runtime.os, "execve") as launch:
                code, _, error = self.invoke("start", "lfm3-1.7b", "--port", str(port))
            self.assertEqual(code, 1)
            self.assertIn("port", error)
            self.assertIn("unavailable", error)
            launch.assert_not_called()
            self.assertEqual(listener.getsockname()[1], port)

    def test_recently_closed_connection_does_not_prevent_restart(self):
        # Actively close the accepted server connection first, leaving its
        # local port in TIME_WAIT after the listener has gone away.
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            address = listener.getsockname()
            with self.assertRaises(ValueError):
                runtime.require_free_port(address[1])
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
                client.settimeout(2)
                client.connect(address)
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(2)
                    connection.shutdown(socket.SHUT_WR)
                    self.assertEqual(client.recv(1), b"")
                    client.shutdown(socket.SHUT_WR)
                    self.assertEqual(connection.recv(1), b"")
        # Prove the fixture exposes the previous bug: a plain bind still
        # fails, while the reusable-address probe permits this quick restart.
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as plain_probe:
            with self.assertRaises(OSError) as error:
                plain_probe.bind(address)
            self.assertEqual(error.exception.errno, errno.EADDRINUSE)
        runtime.require_free_port(address[1])

    def test_start_replaces_launcher_and_passes_sanitized_environment(self):
        with patch.dict(os.environ, {
            "LLAMA_ARG_AGENT": "1", "LLAMA_ARG_HF_REPO": "remote/model",
            "LLAMA_ARG_PORT": "10501", "LLAMA_ARG_MCP_SERVERS_CONFIG": "/tmp/tools.json",
            "EXPERIMENT_TEST_KEEP": "retained",
        }):
            with patch.object(runtime, "require_free_port") as port_check:
                with patch.object(runtime.os, "execve") as launch:
                    code, _, error = self.invoke("start", "lfm3-1.7b")
        self.assertEqual(code, 0, error)
        port_check.assert_called_once_with(10502)
        launch.assert_called_once()
        executable, command, launched_env = launch.call_args.args
        self.assertEqual(executable, str(self.profiles["lfm3-1.7b"].engine))
        self.assertEqual(command[0], executable)
        self.assertFalse(any(key.startswith("LLAMA_ARG_") for key in launched_env))
        self.assertEqual(launched_env["EXPERIMENT_TEST_KEEP"], "retained")

    def test_exec_failure_returns_a_clear_error(self):
        with patch.object(runtime, "require_free_port"):
            with patch.object(runtime.os, "execve", side_effect=OSError("exec failed")):
                code, _, error = self.invoke("start", "lfm3-1.7b")
        self.assertEqual(code, 1)
        self.assertIn("exec failed", error)

    def test_context_and_port_bounds_fail_before_launch(self):
        for flag, value in (("--ctx", "255"), ("--ctx", "32769"),
                            ("--port", "0"), ("--port", "65536")):
            with self.subTest(flag=flag, value=value):
                with patch.object(runtime.os, "execve") as launch:
                    with self.assertRaises(SystemExit) as error:
                        self.invoke("start", "lfm3-1.7b", flag, value)
                self.assertEqual(error.exception.code, 2)
                launch.assert_not_called()

    def test_list_reports_missing_artifacts_without_executing_engine(self):
        self.profiles["lfm3-1.7b"].model.unlink()
        with patch.object(runtime.os, "execve") as launch:
            code, output, error = self.invoke("list")
        self.assertEqual(code, 0, error)
        self.assertIn("lfm3-1.7b: model=missing, engine=ready", output)
        self.assertIn("crow-9b: model=present, engine=ready", output)
        launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
