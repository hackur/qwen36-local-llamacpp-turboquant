#!/usr/bin/env python3
"""Download and verify the pinned Laya agent-workflow checkpoint.

Default mode downloads the pinned revision and verifies the weights.
--verify-only works fully offline: it re-hashes the checkpoint already in
the local huggingface_hub cache and exits non-zero if it is absent, the
revision differs, or the weights do not match the pinned size/SHA-256.
"""
import argparse
import hashlib
from pathlib import Path
from huggingface_hub import snapshot_download

REPO_ID = "convaiinnovations/laya-typed-decisions"
REVISION = "e929ae5cf69bc34259cd2f95c9e91145b818b1f0"
WEIGHTS_SHA256 = "4fa56de72383a9d3efa9cfa78955733c81b9fc8067a587ca4beb82c78107a24e"
WEIGHTS_SIZE = 842609220


def verify_weights(weights: Path) -> str:
    with weights.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if weights.stat().st_size != WEIGHTS_SIZE or digest != WEIGHTS_SHA256:
        raise SystemExit("Laya weight size or SHA-256 mismatch")
    return digest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="verify the cached checkpoint without any network access",
    )
    args = parser.parse_args()

    checkpoint = Path(
        snapshot_download(REPO_ID, revision=REVISION, local_files_only=args.verify_only)
    )
    weights = checkpoint / "model.safetensors"
    if not weights.exists():
        raise SystemExit(
            f"Laya checkpoint incomplete in cache: {weights} is missing\n"
            "run without --verify-only (network required) to fetch it"
        )
    digest = verify_weights(weights)
    print(f"Verified Laya checkpoint: {checkpoint}")
    print(f"model.safetensors: {weights.stat().st_size} bytes; SHA-256 {digest}")
