# Local-only Qwen3.8 operations. No target creates or depends on hosted CI.
SHELL := bash
.DEFAULT_GOAL := help

# Ports come from configs/runtime.env (single source of truth). Sourced in a
# clean shell so an outer environment cannot skew the defaults.
PORT        ?= $(shell bash -c 'source configs/runtime.env 2>/dev/null; echo $$PORT')
PORT_BASELINE ?= $(shell bash -c 'source configs/runtime.env 2>/dev/null; echo $$PORT_BASELINE')
PORT_PROXY    ?= $(shell bash -c 'source configs/runtime.env 2>/dev/null; echo $$PORT_PROXY')
PORT_LAYA     ?= $(shell bash -c 'source configs/runtime.env 2>/dev/null; echo $$PORT_LAYA')

.PHONY: help build upgrade model-link preflight check start start-foreground \
	start-offline start-baseline switch stop status info bench bench-suite bench-tui \
	bench-venv \
	needle quality eval vision demo open proxy-install proxy-test proxy-start proxy-restart \
	proxy-status proxy-stop proxy-smoke analyze-watermarks privacy-scan prepush quarterly-audit \
	audit-offline install-launchd uninstall-launchd service-install service-status \
	service-register service-start service-stop service-restart service-unregister \
	restart restart-baseline start-all restart-all \
	laya-verify clean

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

start: ## Start the complete Qwen3.8 runtime in the background on :$(PORT)
	@if curl -sf --max-time 1 http://127.0.0.1:$(PORT)/health >/dev/null 2>&1; then \
		echo "Qwen3.8 is already running on :$(PORT)"; \
	else \
		mkdir -p logs; \
		./scripts/start-turboquant.sh >> logs/qwen38.log 2>&1 & \
		echo "starting Qwen3.8; log -> logs/qwen38.log"; \
		if scripts/_wait.sh $(PORT) 180; then \
			echo "Qwen3.8 healthy on :$(PORT)"; \
		else \
			echo "WARNING: Qwen3.8 not healthy on :$(PORT) within 180 s — check logs/qwen38.log"; \
		fi; \
	fi

start-foreground: ## Start the complete Qwen3.8 runtime in the foreground
	./scripts/start-turboquant.sh

start-offline: ## Start Qwen3.8 without agent tools or the WebUI MCP proxy
	AGENT=0 MCP_CONFIG= ./scripts/start-turboquant.sh

start-baseline: ## Start the same Qwen3.8 model on mainline with f16 KV and no MTP
	PORT=$(PORT_BASELINE) CTX=32768 ./scripts/start-baseline.sh

start-all: ## Start the model server + compaction proxy in the background
	./scripts/start-all.sh $(M)

restart-all: ## Stop everything, then start the model server + proxy in the background
	./scripts/stop-all.sh && ./scripts/start-all.sh $(M)

switch: ## Stop + start a model profile: make switch M=<crow-9b|qwen38> (default M=qwen38)
	./scripts/switch-model.sh $(M)

restart: ## Stop + background-start the model profile: make restart [M=<profile>]
	M=$(M) ./scripts/restart-turboquant.sh

restart-baseline: ## Stop + background-start the mainline baseline on :$(PORT_BASELINE)
	./scripts/stop-all.sh && ./scripts/start-baseline.sh background $(PORT_BASELINE) 32768

stop: ## Stop the launchd job and repository llama-server processes
	./scripts/stop-all.sh

status: ## Show model servers, compaction proxy, and classifier gate
	./scripts/status.sh

info: ## Show the full local runtime dashboard
	./scripts/info.sh

bench: ## Benchmark the running Qwen3.8 server on :$(PORT)
	python3 scripts/bench.py $(PORT) "qwen38-full" "$${RUNS:-5}"

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

quality: ## Run fixed prompts with official Qwen3.8 non-thinking sampling
	./scripts/quality-check.sh

eval: ## Run the ten-case pass/fail Qwen3.8 mini-evaluation
	python3 scripts/mini-eval.py $(PORT)

vision: ## Run the multimodal smoke test against the unified Qwen3.8 server
	./scripts/test-vision.sh

demo: ## Open the terminal chat client against Qwen3.8
	PORT=$(PORT) ./scripts/demo-chat.sh

open: ## Open the bundled browser client
	open http://127.0.0.1:$(PORT)/

proxy-install: ## Install compaction proxy dependencies
	cd proxy && npm install

proxy-test: ## Run all compaction proxy tests
	cd proxy && npm test

proxy-start: ## Start the compaction proxy in the background on :$(PORT_PROXY)
	./scripts/proxy.sh start

proxy-restart: ## Restart the compaction proxy
	./scripts/proxy.sh restart

proxy-status: ## Show compaction proxy state
	./scripts/proxy.sh status

proxy-stop: ## Stop the compaction proxy started from this repository
	./scripts/stop-proxy.sh

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

service-install: ## Verify build, register, load, and confirm the :$(PORT) listener
	./scripts/service.sh install

service-status: ## Show launchd registration, job, and model listener
	./scripts/service.sh status

service-register: ## Register and load the Qwen3.8 login agent
	./scripts/service.sh register

service-start: ## Start the registered Qwen3.8 login agent
	./scripts/service.sh start

service-stop: ## Stop the agent and model; retain its plist
	./scripts/service.sh stop

service-restart: ## Restart the registered login agent
	./scripts/service.sh restart

service-unregister: ## Stop the agent and remove its plist
	./scripts/service.sh unregister

install-launchd: service-register ## Alias for service-register

uninstall-launchd: service-unregister ## Alias for service-unregister

clean: ## Move generated engine builds to the Trash
	trash vendor/llama.cpp-mainline/build vendor/llama-cpp-turboquant/build

.PHONY: laya-install laya-download laya-start laya-stop laya-status laya-smoke
laya-install: ## Install pinned Laya runtime and download/verify its checkpoint
	./scripts/laya.sh install

laya-download: ## Download and SHA-256 verify the pinned Laya checkpoint
	./scripts/laya.sh download

laya-verify: ## Re-verify the cached Laya checkpoint (offline)
	./vendor/laya-venv/bin/python scripts/laya-download.py --verify-only

laya-restart: ## Restart the persistent local Laya classifier on :$(PORT_LAYA)
	./scripts/laya.sh restart

laya-start: ## Start the persistent local Laya classifier on :$(PORT_LAYA)
	./scripts/laya.sh start

laya-stop: ## Stop Laya while retaining its login service registration
	./scripts/laya.sh stop

laya-status: ## Query actual Laya checkpoint and device health
	./scripts/laya.sh status

laya-smoke: ## Test real typed decisions and the proxy classifier client
	node proxy/scripts/laya-smoke.js
