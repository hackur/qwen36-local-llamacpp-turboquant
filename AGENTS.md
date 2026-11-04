# Local model harness instructions

This repository is the source of truth for local llama.cpp engines, model
profiles, proxy, classifier and agent workflows. Read docs/agent-harness.md
and docs/experimental-models.md before changing or switching runtimes.
Preserve existing uncommitted work, models, captured sources and services.
Keep per-model architecture, MTP, KV and projector capabilities explicit.

For browser work originating here, prefer the installed openclaw-gateway
skill and OpenClaw browser CLI where practical. Check gateway health first;
re-snapshot after navigation and use explicit tab/profile identifiers.
Do not automatically invoke paid agents, messaging, routing, cookie imports,
security changes or service restarts. Preserve existing authorization.

Archive complete supplied captures before preparing bounded handoffs using
scripts/collect-source.py. Keep raw bytes, URL, capture time, hashes,
coverage gaps and truncation reports. Remove script/style overhead from the
readable model view, never from the archived source. Collect pagination,
frames, lazy-loaded data and relevant API responses explicitly; snapshots
are navigation aids and cannot establish exhaustive coverage.

Use standard speed, regular High and bounded tests. Do not download large
artifacts on a hotspot without approval. Do not restart Qwen or poker services
to test changes. Run make check, make proxy-test and relevant dry-runs.
Check public content and history for secrets before pushing. Publish only
reviewed project changes; preserve ignored private artifacts locally.
