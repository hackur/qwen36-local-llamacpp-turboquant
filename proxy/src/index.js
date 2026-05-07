// Entrypoint. Wires config + clients + server together and starts listening.
import pino from "pino";
import { loadConfig } from "./config.js";
import { UpstreamClient } from "./upstream.js";
import { TokenizerClient } from "./tokenizer.js";
import { JsonlLogger } from "./jsonl-logger.js";
import { createProxyServer } from "./server.js";
import { createEngine } from "./hooks/engine.js";
import { resolveHandler } from "./hooks/registry.js";

async function main() {
  const config = loadConfig();
  const logger = pino({ level: config.log_level });

  logger.info(
    {
      listen: config.listen,
      upstream: config.upstream.base_url,
      mode: config.mode,
      config_path: config.config_path,
    },
    "qwen-compact-proxy starting",
  );

  const upstream = new UpstreamClient({
    baseUrl: config.upstream.base_url,
    logger,
  });
  await upstream.loadProps();

  const tokenizer = new TokenizerClient({
    baseUrl: config.upstream.base_url,
    cacheEntries: config.tokenizer.cache_entries,
    logger,
  });

  const jsonl = new JsonlLogger({ cacheDir: config.cache_dir });

  // Hook engine — only built when config.hooks.enabled. Empty registry =
  // pass-through (byte-identical) per docs/hooks-middleware.md §12.
  let hooks = null;
  if (config.hooks?.enabled && Array.isArray(config.hooks.handlers)) {
    hooks = createEngine({ logger });
    for (const h of config.hooks.handlers) {
      if (!h?.handler || !h?.phase) continue;
      try {
        const fn = await resolveHandler(h.handler);
        hooks.register(h.phase, {
          id: h.id || h.handler,
          handler: fn,
          filter: h.filter || null,
          priority: h.priority,
          timeout_ms: h.timeout_ms ?? config.hooks.default_timeout_ms,
          config: h.config || {},
        });
      } catch (err) {
        logger.warn({ err: err.message, handler: h.handler }, "hook registration failed");
      }
    }
  }

  const server = createProxyServer({
    config,
    upstream,
    tokenizer,
    jsonl,
    logger,
    hooks,
  });

  server.listen(config.listen.port, config.listen.host, () => {
    logger.info(
      `listening on http://${config.listen.host}:${config.listen.port}`,
    );
  });

  const shutdown = (sig) => {
    logger.info({ sig }, "shutting down");
    server.close(() => {
      jsonl.closeAll();
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 5000).unref();
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

main().catch((err) => {
  console.error("fatal:", err.stack || err.message);
  process.exit(1);
});
