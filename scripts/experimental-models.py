#!/usr/bin/env python3
"""Run a selected local model in the foreground on its own localhost port.

Examples:
    python3 scripts/experimental-models.py list
    python3 scripts/experimental-models.py start lfm3-1.7b --dry-run
    python3 scripts/experimental-models.py start crow-9b --port 10502 --ctx 4096

Defaults: localhost:10502, 4096 tokens, two CPU threads, one request slot.
Context can be set between 256 and 32768 tokens. Ctrl+C stops the foreground
server. Existing model servers and login services are never stopped or changed.
"""

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import shlex
import socket
import sys
from typing import Dict, List, Mapping, Optional, Sequence


@dataclass(frozen=True)
class Profile:
    name: str
    model: Path
    engine: Path
    alias: str
    sampling: Sequence[str]


def profiles(repo_root: Path, home: Path) -> Dict[str, Profile]:
    """Keep weights in their existing location; never copy or fetch a model."""
    lmstudio = home / ".lmstudio" / "models"
    qwen_engine = repo_root / "vendor/llama.cpp-mainline/build/bin/llama-server"
    qwen_sampling = (
        "--temp", "0.6", "--top-k", "20", "--top-p", "0.95",
        "--min-p", "0", "--repeat-penalty", "1.0",
    )
    return {
        "lfm3-1.7b": Profile(
            "lfm3-1.7b",
            repo_root / "models/experimental/LFM3-1.7B-Q8_0.gguf",
            repo_root / "vendor/llama.cpp-lfm3/bin/llama-server",
            "lfm3-1.7b-local",
            (
                "--temp", "0.1", "--top-k", "50", "--top-p", "1.0",
                "--min-p", "0", "--repeat-penalty", "1.1",
            ),
        ),
        "crow-9b": Profile(
            "crow-9b",
            lmstudio / "mradermacher/Crow-9B-Opus-4.6-Distill-Heretic_Qwen3.5-GGUF"
            / "Crow-9B-Opus-4.6-Distill-Heretic_Qwen3.5.Q4_K_S.gguf",
            qwen_engine,
            "crow-9b-local",
            qwen_sampling,
        ),
        "mimo-9b": Profile(
            "mimo-9b",
            lmstudio / "Hikari07jp/MiMo-V2.6-Distill-Qwen-9B-Ablitrated"
            / "MiMo-V2.6-Distill-Qwen-9B-Ablitrated-Q4_K_M.gguf",
            qwen_engine,
            "mimo-9b-local",
            qwen_sampling,
        ),
        "journalist-9b": Profile(
            "journalist-9b",
            lmstudio / "tomvaillant/qwen3.5-9b-abliterated-journalist-GGUF"
            / "model-q4_k_m.gguf",
            qwen_engine,
            "journalist-9b-local",
            qwen_sampling,
        ),
    }


def bounded_int(label: str, minimum: int, maximum: int):
    def parse(value: str) -> int:
        try:
            result = int(value)
        except ValueError:
            raise argparse.ArgumentTypeError(f"{label} must be an integer")
        if not minimum <= result <= maximum:
            raise argparse.ArgumentTypeError(
                f"{label} must be between {minimum} and {maximum}"
            )
        return result
    return parse


def command_for(
    profile: Profile, *, port: int = 10502, ctx: int = 4096,
    engine: Optional[Path] = None,
) -> List[str]:
    """Validate artifacts and construct argv without executing the engine."""
    if not profile.model.is_file():
        raise ValueError(f"model file is missing: {profile.model}")
    selected_engine = engine if engine is not None else profile.engine
    if not selected_engine.is_file() or not os.access(selected_engine, os.X_OK):
        raise ValueError(f"engine is missing or not executable: {selected_engine}")
    return [
        str(selected_engine), "--model", str(profile.model),
        "--host", "127.0.0.1", "--port", str(port),
        "--ctx-size", str(ctx), "--threads", "2", "--threads-batch", "2", "--prio", "-1",
        "--parallel", "1", "--gpu-layers", "all",
        "--cache-type-k", "f16", "--cache-type-v", "f16",
        "--jinja", "--reasoning", "auto", "--offline", "--alias", profile.alias,
        *profile.sampling,
    ]


def engine_environment(environ: Mapping[str, str]) -> Dict[str, str]:
    """Prevent llama.cpp environment flags from changing the selected profile."""
    return {
        key: value for key, value in environ.items()
        if not key.startswith("LLAMA_ARG_")
    }


def require_free_port(port: int) -> None:
    """Check that this localhost endpoint is available; never evict a listener."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            # Match the server's restart behavior: recently closed connections
            # may remain in TIME_WAIT even though no listener owns this port.
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind(("127.0.0.1", port))
    except OSError as error:
        raise ValueError(f"localhost port {port} is unavailable: {error}") from error


def main(
    argv: Optional[Sequence[str]] = None, *,
    repo_root: Optional[Path] = None, home: Optional[Path] = None,
) -> int:
    repo_root = repo_root if repo_root is not None else Path(__file__).resolve().parents[1]
    home = home if home is not None else Path.home()
    available = profiles(repo_root, home)
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list", help="show profiles and artifact availability")
    start = commands.add_parser("start", help="run one model in the foreground")
    start.add_argument("profile", choices=tuple(available))
    start.add_argument("--dry-run", action="store_true",
                       help="validate local artifacts and print argv without running")
    start.add_argument("--port", type=bounded_int("port", 1, 65535), default=10502)
    start.add_argument("--ctx", type=bounded_int("context", 256, 32768), default=4096)
    start.add_argument("--engine", type=Path,
                       help="explicit path to a compatible llama-server executable")
    args = parser.parse_args(argv)
    if args.command == "list":
        for profile in available.values():
            model_status = "present" if profile.model.is_file() else "missing"
            engine_status = "ready" if (
                profile.engine.is_file() and os.access(profile.engine, os.X_OK)
            ) else "missing"
            print(f"{profile.name}: model={model_status}, engine={engine_status}")
            print(f"  model: {profile.model}\n  engine: {profile.engine}")
        return 0
    try:
        engine = args.engine.expanduser().resolve() if args.engine is not None else None
        command = command_for(available[args.profile], port=args.port,
                              ctx=args.ctx, engine=engine)
        if args.dry_run:
            print(shlex.join(command))
            return 0
        require_free_port(args.port)
        print(f"Starting {args.profile} at http://127.0.0.1:{args.port}; "
              "Ctrl+C stops this foreground server.", flush=True)
        # Replace this launcher so signals sent to its PID reach the engine
        # directly and cannot leave a model-server child behind.
        os.execve(command[0], command, engine_environment(os.environ))
        return 0  # Only reached when execve is mocked by the behavioral tests.
    except (ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
