#!/usr/bin/env python3
"""Serve the verified local checkpoint through upstream Laya's HTTP API."""
import os
from huggingface_hub import snapshot_download
from laya import Router
from laya.serve import create_app
import torch
import uvicorn
from importlib.util import spec_from_file_location, module_from_spec
from pathlib import Path

spec = spec_from_file_location("laya_download", Path(__file__).with_name("laya-download.py"))
checkpoint_config = module_from_spec(spec)
spec.loader.exec_module(checkpoint_config)


class LocalRouter(Router):
    """Keep unpinned Jev requests on the one installed checkpoint."""

    def route(self, state, questions=None, model=None, **kwargs):
        return super().route(state, questions, model=model or "typed-decisions", **kwargs)


if __name__ == "__main__":
    torch.set_num_threads(int(os.environ.get("LAYA_THREADS", "8")))
    try:
        checkpoint = snapshot_download(checkpoint_config.REPO_ID,
                                       revision=checkpoint_config.REVISION, local_files_only=True)
    except Exception as error:  # noqa: BLE001 - LaunchAgent log gets one clear line
        raise SystemExit(
            f"Laya checkpoint cache unavailable: {error}\n"
            f"expected: {checkpoint_config.REPO_ID} @ {checkpoint_config.REVISION}\n"
            "run 'make laya-download' (or 'make laya-install') first, then restart the service"
        ) from error
    if not (Path(checkpoint) / "model.safetensors").exists():
        raise SystemExit(
            f"Laya checkpoint incomplete in cache: {checkpoint}\n"
            "run 'make laya-download' (or 'make laya-install') first, then restart the service"
        )
    router = LocalRouter(models={"typed-decisions": checkpoint},
                    device=os.environ.get("LAYA_DEVICE", "cpu"),
                    default="typed-decisions", max_loaded=1,
                    sha256_digests={"typed-decisions": {
                        "model.safetensors": checkpoint_config.WEIGHTS_SHA256}})
    router.preload(["typed-decisions"])
    uvicorn.run(create_app(router), host="127.0.0.1", port=18000)
