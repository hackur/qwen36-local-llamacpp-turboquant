#!/usr/bin/env python3
"""Common foreground entry point; keep compatible engines and flags per profile."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PROFILES = ('qwen38', 'lfm3-1.7b', 'crow-9b', 'mimo-9b', 'journalist-9b')


def command(profile, dry_run=False):
    if profile not in PROFILES:
        raise ValueError('unknown model profile')
    if profile == 'qwen38':
        return ['bash', str(ROOT / 'scripts/start-turboquant.sh'), '--dry-run' if dry_run else 'foreground']
    argv = [sys.executable, str(ROOT / 'scripts/experimental-models.py'), 'start', profile]
    return argv + (['--dry-run'] if dry_run else [])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='action', required=True)
    sub.add_parser('list')
    start = sub.add_parser('start', aliases=['load'])
    start.add_argument('profile', choices=PROFILES)
    start.add_argument('--dry-run', action='store_true')
    a = p.parse_args()
    if a.action == 'list':
        print('qwen38: primary TurboQuant/MTP engine; lifecycle managed by service.sh when installed')
        return subprocess.call([sys.executable, str(ROOT / 'scripts/experimental-models.py'), 'list'])
    argv = command(a.profile, a.dry_run)
    # A common control surface does not imply the same binary or model flags.
    # Never stop a running service to make space; unload foreground runs with Ctrl+C.
    os.execvpe(argv[0], argv, os.environ.copy())


if __name__ == '__main__':
    raise SystemExit(main())
