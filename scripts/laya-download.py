#!/usr/bin/env python3
"""Download and verify the pinned Laya agent-workflow checkpoint."""
import hashlib
from pathlib import Path
from huggingface_hub import snapshot_download

REPO_ID = "convaiinnovations/laya-typed-decisions"
REVISION = "e929ae5cf69bc34259cd2f95c9e91145b818b1f0"
WEIGHTS_SHA256 = "4fa56de72383a9d3efa9cfa78955733c81b9fc8067a587ca4beb82c78107a24e"

if __name__ == "__main__":
    checkpoint = Path(snapshot_download(REPO_ID, revision=REVISION))
    weights = checkpoint / "model.safetensors"
    with weights.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if weights.stat().st_size != 842609220 or digest != WEIGHTS_SHA256:
        raise SystemExit("Laya weight size or SHA-256 mismatch")
    print(f"Verified Laya checkpoint: {checkpoint}")
    print(f"model.safetensors: {weights.stat().st_size} bytes; SHA-256 {digest}")
