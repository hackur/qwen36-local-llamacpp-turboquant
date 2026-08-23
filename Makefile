# Local-only Qwen3.8 operations. No target creates or depends on hosted CI.
SHELL := bash
.DEFAULT_GOAL := help

.PHONY: help build upgrade model-link preflight check start start-foreground \
	start-offline start-baseline stop status info bench bench-suite bench-tui \
	bench-venv \
	needle quality vision demo open proxy-install proxy-test proxy-start \
	proxy-smoke analyze-watermarks privacy-scan prepush quarterly-audit \
	audit-offline install-launchd uninstall-launchd clean

help:
	@awk 'BEGIN{FS=":.*##"; printf "Targets:\n"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build pinned mainline and TurboQuant llama.cpp engines with Metal
	./scripts/build-llama.sh

upgrade: ## Fetch current engine branch tips, rebuild, and print candidate pins
	./scripts/upgrade.sh

model-link: ## Link only Qwen3.8 Q8_0 weights and its BF16 projector
	./scripts/symlink-models.sh

preflight: ## Validate tools, engines, model artifacts, and required server flags
	./scripts/preflight.sh

check: ## Run all local static and unit checks without starting the model
	./scripts/static-check.sh

start: ## Start the complete Qwen3.8 runtime in the background on :10501
	@if curl -sf --max-time 1 http://127.0.0.1:10501/health >/dev/null 2>&1; then \
		echo "Qwen3.8 is already running on :10501"; \
	else \
		mkdir -p logs; \
		./scripts/start-turboquant.sh > logs/qwen38.log 2>&1 & \
		echo "starting Qwen3.8; log -> logs/qwen38.log"; \
	fi

start-foreground: ## Start the complete Qwen3.8 runtime in the foreground
	./scripts/start-turboquant.sh

start-offline: ## Start Qwen3.8 without agent tools or the WebUI MCP proxy
	AGENT=0 ./scripts/start-turboquant.sh

start-baseline: ## Start the same Qwen3.8 model on mainline with f16 KV and no MTP
	PORT=10500 CTX=32768 ./scripts/start-baseline.sh

stop: ## Stop llama-server processes launched from this repository
	./scripts/stop-all.sh

status: ## Show Qwen3.8 full and baseline server status
	./scripts/status.sh

info: ## Show the full local runtime dashboard
	./scripts/info.sh

bench: ## Benchmark the running Qwen3.8 server on :10501
	python3 scripts/bench.py 10501 "qwen38-full"

bench-venv: ## Create/update the isolated benchmark TUI environment
	python3 -m venv .venv
	.venv/bin/pip install -r requirements-tui.txt

bench-suite: ## Run the Qwen3.8 feature suite headlessly
	@SUITE="$${SUITE:-benchmarks/suites/qwen38-features.yaml}"; \
	.venv/bin/python scripts/bench_runner.py run "$$SUITE"

bench-tui: ## Run or attach to the Qwen3.8 benchmark TUI
	@if [[ -n "$$RUN_DIR" ]]; then \
		.venv/bin/python scripts/bench_tui.py "$$RUN_DIR"; \
	else \
		SUITE="$${SUITE:-benchmarks/suites/qwen38-features.yaml}"; \
		.venv/bin/python scripts/bench_tui.py "$$SUITE" --spawn; \
	fi

needle: ## Run a 50K-token long-context recall probe against Qwen3.8
	python3 scripts/needle.py 50000

quality: ## Run deterministic text quality checks against Qwen3.8
	./scripts/quality-check.sh

vision: ## Run the multimodal smoke test against the unified Qwen3.8 server
	./scripts/test-vision.sh

demo: ## Open the terminal chat client against Qwen3.8
	PORT=10501 ./scripts/demo-chat.sh

open: ## Open the bundled browser client
	open http://127.0.0.1:10501/

proxy-install: ## Install compaction proxy dependencies
	cd proxy && npm install

proxy-test: ## Run all compaction proxy tests
	cd proxy && npm test

proxy-start: ## Start the compaction proxy on :11500
	cd proxy && npm start

proxy-smoke: ## Run proxy integration checks against the live Qwen3.8 runtime
	./proxy/tests/integration.sh

analyze-watermarks: ## Analyze compaction telemetry
	python3 scripts/analyze-watermarks.py

privacy-scan: ## Check tracked public content for private paths or credentials
	./scripts/privacy-scan.sh

prepush: ## Run the complete local pre-push gate
	./scripts/static-check.sh && cd proxy && npm test

quarterly-audit: ## Revalidate model links, engine pins, and offline behavior
	./scripts/quarterly-audit.sh

audit-offline: ## Report non-loopback sockets held by the running server
	./scripts/info.sh --audit-offline

install-launchd: ## Install the Qwen3.8 full runtime as a login agent
	@mkdir -p "$$HOME/Library/LaunchAgents"
	sed "s|__REPO__|$(CURDIR)|g" configs/launchd-plist.template > "$$HOME/Library/LaunchAgents/com.local.qwen3-8.turboquant.plist"
	launchctl unload "$$HOME/Library/LaunchAgents/com.local.qwen3-8.turboquant.plist" 2>/dev/null || true
	launchctl load "$$HOME/Library/LaunchAgents/com.local.qwen3-8.turboquant.plist"

uninstall-launchd: ## Remove the Qwen3.8 login agent
	launchctl unload "$$HOME/Library/LaunchAgents/com.local.qwen3-8.turboquant.plist" 2>/dev/null || true
	trash "$$HOME/Library/LaunchAgents/com.local.qwen3-8.turboquant.plist" 2>/dev/null || true

clean: ## Move generated engine builds to the Trash
	trash vendor/llama.cpp-mainline/build vendor/llama-cpp-turboquant/build
