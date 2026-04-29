# Convenience targets. `make` (no args) prints help.
SHELL := bash
.DEFAULT_GOAL := help

.PHONY: help build start stop status bench demo open install-launchd uninstall-launchd clean

help:
	@awk 'BEGIN{FS=":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build mainline + TurboQuant llama.cpp (Metal). Idempotent.
	./scripts/build-llama.sh

start: ## Start TurboQuant server in background (port 10501)
	@if curl -sf --max-time 1 http://127.0.0.1:10501/health >/dev/null 2>&1; then \
		echo "already up on :10501"; \
	else \
		./scripts/start-turboquant.sh > logs/turboquant.log 2>&1 & \
		echo "starting; log → logs/turboquant.log"; \
	fi

start-baseline: ## Start mainline f16 baseline (port 10500)
	./scripts/start-baseline.sh > logs/baseline.log 2>&1 &

models: ## List all available model aliases
	./scripts/list-models.sh

start-tiny: ## Start TinyLlama 1.1B (smoke test, ~700 MB) — turbo3 unsupported, uses q8_0
	MODEL=tiny CTX=2048 KV=q8_0 ./scripts/start-turboquant.sh > logs/turboquant.log 2>&1 &

start-nemotron: ## Start Nemotron-3 Nano 4B (~2.8 GB)
	MODEL=nemotron-4b CTX=8192 ./scripts/start-turboquant.sh > logs/turboquant.log 2>&1 &

start-crow: ## Start Crow-9B (Qwen3.5 distill, ~5 GB)
	MODEL=crow-9b CTX=16384 ./scripts/start-turboquant.sh > logs/turboquant.log 2>&1 &

start-gemma4-e4b: ## Start Gemma 4 E4B (small, ~8 GB)
	MODEL=gemma4-e4b CTX=16384 ./scripts/start-turboquant.sh > logs/turboquant.log 2>&1 &

start-qwen35-9b: ## Start Qwen 3.5 9B Q8_0 (~9.5 GB)
	MODEL=qwen35-9b CTX=32768 ./scripts/start-turboquant.sh > logs/turboquant.log 2>&1 &

start-gpt-oss: ## Start GPT-OSS 20B MXFP4 — turbo3 unsupported on MXFP4 weights, uses q8_0
	MODEL=gpt-oss-20b CTX=32768 KV=q8_0 ./scripts/start-turboquant.sh > logs/turboquant.log 2>&1 &

start-gemma4-26b: ## Start Gemma 4 26B-A4B (~17 GB MoE)
	MODEL=gemma4-26b CTX=32768 ./scripts/start-turboquant.sh > logs/turboquant.log 2>&1 &

start-qwen36-27b: ## Start Qwen 3.6 27B IQ2_XXS (~9 GB dense)
	MODEL=qwen36-27b CTX=32768 ./scripts/start-turboquant.sh > logs/turboquant.log 2>&1 &

stop: ## Stop all llama-server processes from this repo
	./scripts/stop-all.sh

status: ## What's running and where (terse)
	./scripts/status.sh

info: ## Full one-shot info dashboard (env, server, memory, network, disk, launchd, last bench)
	./scripts/info.sh

info-watch: ## Same as `info`, refreshing every 2 s
	./scripts/info.sh --watch

bench: ## Run A/B benchmark (assumes both servers up)
	python3 scripts/bench.py 10500 "baseline" || true
	python3 scripts/bench.py 10501 "turboquant" || true

needle: ## Long-context recall test on TurboQuant
	python3 scripts/needle.py 50000

demo: ## Terminal chat REPL
	PORT=10501 ./scripts/demo-chat.sh

open: ## Open the web demo in your browser
	open clients/web-demo.html

install-launchd: ## Install launchd auto-start (always-on offline)
	sed "s|__REPO__|$(CURDIR)|g" configs/launchd-plist.template \
		> ~/Library/LaunchAgents/com.local.qwen3-6.turboquant.plist
	launchctl load ~/Library/LaunchAgents/com.local.qwen3-6.turboquant.plist
	@echo "✓ installed. server will start at login. status: launchctl list | grep qwen"

uninstall-launchd: ## Remove launchd auto-start
	launchctl unload ~/Library/LaunchAgents/com.local.qwen3-6.turboquant.plist 2>/dev/null || true
	rm -f ~/Library/LaunchAgents/com.local.qwen3-6.turboquant.plist
	@echo "✓ uninstalled"

clean: ## Wipe build artifacts (does NOT delete vendor/ source)
	rm -rf vendor/llama.cpp-mainline/build vendor/llama-cpp-turboquant/build
	@echo "✓ build dirs removed. run 'make build' to rebuild."

audit-offline: ## Confirm llama-server has zero non-localhost sockets
	@PID=$$(pgrep -f vendor/llama-cpp-turboquant.*llama-server | head -1); \
	if [[ -z "$$PID" ]]; then echo "no turboquant server running"; exit 1; fi; \
	echo "▶ checking PID $$PID"; \
	non_local=$$(lsof -nP -p $$PID 2>/dev/null | grep -E "TCP|UDP" | grep -vE "127\.0\.0\.1|\[::1\]" || true); \
	if [[ -z "$$non_local" ]]; then \
		echo "✓ zero non-localhost sockets — provably offline-clean"; \
	else \
		echo "✗ non-localhost sockets found:"; echo "$$non_local"; exit 1; \
	fi
