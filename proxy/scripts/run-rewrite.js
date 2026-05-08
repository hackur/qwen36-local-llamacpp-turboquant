#!/usr/bin/env node
// run-rewrite.js — A/B harness CLI shim around proxy/src/rewrite.js.
//
// Reads a fixture JSONL (one {role, content, tool_calls?} per line), turns it
// into an OpenAI-style request body, and runs `rewriteRequest()` with the
// variant's config knobs applied. Emits a single JSON line to stdout shaped
// for the harness METRIC_KEYS plus a `text` blob (the post-rewrite messages
// joined as plain text), used by the harness for needle / AGREED grading.
//
// This is NOT a substitute for an end-to-end harness run against a live
// proxy — it bypasses the HTTP layer, the tokenizer service, and the
// summarizer service. We pin a deterministic stub tokenizer (chars/4) so
// runs are reproducible and offline.
//
// Usage:
//   node proxy/scripts/run-rewrite.js \
//     --fixture proxy/eval/ab-harness/fixtures/tool-heavy.jsonl \
//     --variant tier0+tier1 [--config <yaml-not-yet-used>]
//
// Stdout: one JSON line.
// Stderr: free-form diagnostics.
// Exit 0 on success, non-zero on hard failure.
//
// No new node dependencies — node:fs / node:path / node:url only.

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";

import { rewriteRequest } from "../src/rewrite.js";
import { createEngine, createContext } from "../src/hooks/engine.js";
import { resolveHandler } from "../src/hooks/registry.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// ---- variant -> config knobs ------------------------------------------------
//
// Mirrors proxy/eval/ab-harness/variants.py. Kept inline so the shim has no
// dependency on the python harness file.
const VARIANTS = {
  "do-nothing": {
    mode: "passthrough",
    tier0: false,
    tier1: false,
    notes: false,
    sumy: false,
  },
  "caveman-self-compact": {
    mode: "passthrough",
    tier0: false,
    tier1: false,
    notes: false,
    sumy: false,
  },
  "tier0-only": {
    mode: "enforce",
    tier0: true,
    tier1: false,
    notes: false,
    sumy: false,
  },
  "tier1-only": {
    mode: "enforce",
    tier0: false,
    tier1: true,
    notes: false,
    sumy: false,
  },
  "tier0+tier1": {
    mode: "enforce",
    tier0: true,
    tier1: true,
    notes: false,
    sumy: false,
  },
  "tier1+hooks": {
    // Tier-1 plus the hook engine. Registers a small built-in handler set
    // and dispatches at request:before-rewrite + request:after-rewrite around
    // the rewriteRequest call. Surfaces hook_tags / hook_timings_ms /
    // hook_errors per cell.
    mode: "enforce",
    tier0: false,
    tier1: true,
    notes: false,
    sumy: false,
    hooks: true,
  },
};

function parseArgs(argv) {
  const out = {};
  for (let i = 2; i < argv.length; i += 2) {
    const k = argv[i];
    const v = argv[i + 1];
    if (!k || !k.startsWith("--")) {
      throw new Error(`bad arg: ${k}`);
    }
    out[k.slice(2)] = v;
  }
  return out;
}

function loadFixture(path) {
  const raw = readFileSync(path, "utf8");
  const rows = [];
  for (const line of raw.split("\n")) {
    const t = line.trim();
    if (!t) continue;
    rows.push(JSON.parse(t));
  }
  return rows;
}

function messageText(m) {
  if (!m) return "";
  if (typeof m.content === "string") return m.content;
  if (Array.isArray(m.content)) {
    return m.content
      .map((p) => {
        if (typeof p === "string") return p;
        if (p && typeof p.text === "string") return p.text;
        if (p && typeof p.content === "string") return p.content;
        return JSON.stringify(p ?? "");
      })
      .join("\n");
  }
  return "";
}

// Stub tokenizer: chars/4. Same shape as TokenizerClient (cache + countTokens).
class StubTokenizer {
  constructor() {
    this.cache = new Map();
    // proxy code reads tokenizer.cache.get(); shim a Map-with-get/set.
  }
  async countTokens(text) {
    if (!text) return 0;
    const cached = this.cache.get(text);
    if (typeof cached === "number") return cached;
    const n = Math.max(1, Math.ceil(String(text).length / 4));
    this.cache.set(text, n);
    return n;
  }
}

async function main() {
  const args = parseArgs(process.argv);
  const fixturePath = args.fixture;
  const variantId = args.variant || "tier0+tier1";

  if (!fixturePath) {
    process.stderr.write("error: --fixture required\n");
    process.exit(2);
  }

  const knobs = VARIANTS[variantId];
  if (!knobs) {
    process.stderr.write(`error: unknown variant ${variantId}\n`);
    process.exit(2);
  }

  const messages = loadFixture(resolve(fixturePath));
  const body = { messages };

  // Build a config that flips the right tiers on/off. rewrite.js already
  // gates summarizer/notes/sumy on their own enabled flags. Tier 0 is the
  // verbatim window (always present) and Tier 1 is `applyTier1` (always
  // called); we approximate "tier0 off" by widening the verbatim keep so
  // nothing is evictable, and "tier1 off" by lifting min_tokens above any
  // realistic body so applyTier1 never stubs.
  const config = {
    watermarks: {
      verbatim_keep_turns: knobs.tier0 ? 8 : 10_000,
      verbatim_keep_tokens: knobs.tier0 ? 8000 : 100_000_000,
      tool_result_min_tokens: knobs.tier1 ? 2000 : 100_000_000,
      prompt_fraction: 0.7,
      max_messages: 40,
      max_age_turns: 20,
    },
    summarizer: { url: "", mode: "off" },
    notes: { enabled: knobs.notes },
    sumy: { enabled: knobs.sumy, target_sentences: 5 },
  };

  const tokenizer = new StubTokenizer();
  const cacheDir = "/tmp/ab-harness-shim-cache";

  // Optional hook engine. Mirrors the integration shape in proxy/src/server.js:
  //   - dispatch request:before-rewrite with prompt-token context populated
  //   - call rewriteRequest()
  //   - dispatch request:after-rewrite with rewrite + elidedIds populated
  // Built-in handlers registered: context-pressure-reminder (before) and
  // tag-bash-read-elisions (after). Filters/predicates kept null — the
  // handlers self-gate on context fields.
  let engine = null;
  let hookCtx = null;
  if (knobs.hooks) {
    engine = createEngine({
      logger: { warn() {}, info() {}, debug() {} },
    });
    const beforeHandler = await resolveHandler("built-in:context-pressure-reminder");
    const afterHandler = await resolveHandler("built-in:tag-bash-read-elisions");
    engine.register("request:before-rewrite", {
      id: "context-pressure-reminder",
      handler: beforeHandler,
      priority: 100,
      timeout_ms: 50,
      // Aggressive threshold for the harness so the hook actually fires on
      // the heavier fixtures even though the stub tokenizer underestimates.
      config: { threshold: 0.10 },
    });
    engine.register("request:after-rewrite", {
      id: "tag-bash-read-elisions",
      handler: afterHandler,
      priority: 100,
      timeout_ms: 50,
    });
  }

  const t0 = performance.now();
  let rewritten, stats, error = null;
  try {
    if (knobs.mode === "passthrough") {
      // Mirror server.js passthrough: don't call rewriteRequest at all.
      rewritten = body;
      // Still want orig_tokens for the report.
      let orig = 0;
      for (const m of messages) {
        orig += await tokenizer.countTokens(messageText(m));
      }
      stats = {
        orig_tokens: orig,
        rewritten_tokens: orig,
        elided_tool_result_ids: [],
      };
    } else {
      // Pre-count prompt tokens so the before-rewrite hook has something
      // meaningful in promptTokens / promptTokenFraction. Tokenizer cache
      // makes the second pass inside rewriteRequest a hash lookup.
      let promptTokens = 0;
      if (engine) {
        for (const m of messages) {
          promptTokens += await tokenizer.countTokens(messageText(m));
        }
        // Synthetic nCtx so promptTokenFraction is finite. The harness has
        // no model context window; pick something that mirrors a 32K llama.
        const nCtx = 32768;
        hookCtx = createContext({
          requestId: `ab-${Date.now()}`,
          parsed: body,
          messages,
          nCtx,
          promptTokens,
          promptTokenFraction: promptTokens / nCtx,
        });
        if (engine.hasHooksFor("request:before-rewrite")) {
          await engine.dispatch("request:before-rewrite", hookCtx);
          // Hook may have replaced/injected into messages; rewriteRequest
          // operates on body.messages, so sync.
          if (hookCtx.messages !== messages) {
            body.messages = hookCtx.messages;
          }
        }
      }

      const r = await rewriteRequest({
        body,
        tokenizer,
        config,
        cacheDir,
        nCtx: 0,
        logger: { info() {}, warn() {}, error() {}, debug() {} },
      });
      rewritten = r.rewrittenBody;
      stats = r.stats;

      if (engine && hookCtx && engine.hasHooksFor("request:after-rewrite")) {
        hookCtx.rewrite = r;
        hookCtx.outboundMessages = rewritten?.messages || null;
        hookCtx.elidedIds = stats?.elided_tool_result_ids || [];
        await engine.dispatch("request:after-rewrite", hookCtx);
      }
    }
  } catch (e) {
    error = e?.message || String(e);
  }
  const elapsed = performance.now() - t0;

  // Flatten rewritten messages to a text blob for needle/AGREED grading.
  let text = "";
  if (rewritten?.messages) {
    text = rewritten.messages.map(messageText).join("\n---\n");
  }

  const turnsCompleted = Array.isArray(rewritten?.messages)
    ? rewritten.messages.length
    : 0;

  // Cheap completion-token estimate: 1/8 of rewritten prompt, capped 256.
  const completionEstimate = Math.min(
    256,
    Math.max(16, Math.floor((stats?.rewritten_tokens || 0) / 8)),
  );

  const hookFields = hookCtx
    ? {
        hook_tags: [...hookCtx.tags],
        hook_timings_ms: hookCtx.hookTimingsMs,
        hook_errors: hookCtx.hookErrors,
        total_hook_time_ms: Object.values(hookCtx.hookTimingsMs)
          .reduce((a, b) => a + b, 0),
      }
    : {};

  process.stdout.write(JSON.stringify({
    variant: variantId,
    fixture: fixturePath,
    prompt_tokens: stats?.orig_tokens ?? 0,
    rewritten_tokens: stats?.rewritten_tokens ?? 0,
    completion_tokens: completionEstimate,
    latency_ms: Math.round(elapsed),
    turns_completed: turnsCompleted,
    elided_count: (stats?.elided_tool_result_ids || []).length,
    error,
    text,
    ...hookFields,
  }) + "\n");
}

main().catch((e) => {
  process.stderr.write(`fatal: ${e?.stack || e}\n`);
  process.exit(1);
});
