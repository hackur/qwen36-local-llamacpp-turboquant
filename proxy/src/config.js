// Loads proxy/config.yaml, applies env overrides, fills defaults.
import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import yaml from "js-yaml";

const __dirname = dirname(fileURLToPath(import.meta.url));

const DEFAULTS = {
  listen: { host: "127.0.0.1", port: 11500 },
  upstream: {
    base_url: "http://127.0.0.1:10501",
    request_timeout_ms: 600000,
  },
  mode: "passthrough",
  watermarks: {
    prompt_fraction: 0.7,
    tool_result_min_tokens: 2000,
    max_messages: 40,
    max_age_turns: 20,
  },
  cache_dir: "~/.cache/qwen-compact",
  tokenizer: { cache_entries: 4096 },
  log_level: "info",
  // Phase 2 recursive summarizer (Tier 3). Off by default — set
  // `summarizer.url` to enable. `mode` mirrors the main proxy modes:
  //   off         — never call (default).
  //   passthrough — never call (alias for off; symmetry with main proxy).
  //   shadow      — call, log the summary, but DON'T replace the tool result
  //                 (still falls through to Tier 1 stub).
  //   enforce     — call, replace the tool-result body with the summary.
  summarizer: {
    url: "",
    mode: "off",
    request_timeout_ms: 8000,
    max_tokens: 512,
    model: "qwen-compact-summarizer",
  },
};

const VALID_MODES = new Set(["passthrough", "shadow", "enforce"]);
const VALID_SUMMARIZER_MODES = new Set([
  "off",
  "passthrough",
  "shadow",
  "enforce",
]);

function expandHome(p) {
  if (!p) return p;
  if (p === "~") return homedir();
  if (p.startsWith("~/")) return resolve(homedir(), p.slice(2));
  return p;
}

function deepMerge(base, override) {
  if (override == null) return base;
  if (typeof base !== "object" || typeof override !== "object") return override;
  const out = Array.isArray(base) ? [...base] : { ...base };
  for (const k of Object.keys(override)) {
    out[k] = deepMerge(base[k], override[k]);
  }
  return out;
}

export function loadConfig(configPath) {
  const path =
    configPath || process.env.QWEN_COMPACT_CONFIG ||
    resolve(__dirname, "..", "config.yaml");

  let parsed = {};
  if (existsSync(path)) {
    parsed = yaml.load(readFileSync(path, "utf8")) || {};
  }
  const cfg = deepMerge(DEFAULTS, parsed);

  // Env overrides (handy for tests).
  if (process.env.QWEN_COMPACT_PORT) {
    cfg.listen.port = Number(process.env.QWEN_COMPACT_PORT);
  }
  if (process.env.QWEN_COMPACT_UPSTREAM) {
    cfg.upstream.base_url = process.env.QWEN_COMPACT_UPSTREAM;
  }
  if (process.env.QWEN_COMPACT_MODE) {
    cfg.mode = process.env.QWEN_COMPACT_MODE;
  }

  if (!VALID_MODES.has(cfg.mode)) {
    throw new Error(
      `invalid mode '${cfg.mode}'; must be one of ${[...VALID_MODES].join(", ")}`,
    );
  }
  // Env override for the summarizer URL (handy for tests and ad-hoc enable).
  if (process.env.QWEN_COMPACT_SUMMARIZER_URL) {
    cfg.summarizer = cfg.summarizer || {};
    cfg.summarizer.url = process.env.QWEN_COMPACT_SUMMARIZER_URL;
  }
  if (cfg.summarizer && !VALID_SUMMARIZER_MODES.has(cfg.summarizer.mode)) {
    throw new Error(
      `invalid summarizer.mode '${cfg.summarizer.mode}'; must be one of ${[...VALID_SUMMARIZER_MODES].join(", ")}`,
    );
  }
  // Phase 1: passthrough | shadow | enforce all wired. Tier 0 + Tier 1 only.

  cfg.cache_dir = expandHome(cfg.cache_dir);
  cfg.config_path = path;
  return cfg;
}
