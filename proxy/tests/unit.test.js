// Unit tests. Run with `node --test tests/`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { LRU } from "../src/lru.js";
import { loadConfig } from "../src/config.js";

test("LRU evicts oldest", () => {
  const c = new LRU(2);
  c.set("a", 1);
  c.set("b", 2);
  c.set("c", 3);
  assert.equal(c.get("a"), undefined);
  assert.equal(c.get("b"), 2);
  assert.equal(c.get("c"), 3);
});

test("LRU promotes on get", () => {
  const c = new LRU(2);
  c.set("a", 1);
  c.set("b", 2);
  c.get("a"); // a is now most recent
  c.set("c", 3); // evicts b
  assert.equal(c.get("a"), 1);
  assert.equal(c.get("b"), undefined);
});

test("config defaults load with no override", () => {
  const cfg = loadConfig();
  assert.equal(cfg.mode, "passthrough");
  assert.equal(cfg.listen.port, 11500);
  assert.equal(cfg.upstream.base_url, "http://127.0.0.1:10501");
  assert.ok(cfg.cache_dir && !cfg.cache_dir.startsWith("~"));
});

test("config rejects unimplemented modes in Phase 0", () => {
  const prev = process.env.QWEN_COMPACT_MODE;
  process.env.QWEN_COMPACT_MODE = "enforce";
  assert.throws(() => loadConfig(), /not implemented in Phase 0/);
  if (prev === undefined) delete process.env.QWEN_COMPACT_MODE;
  else process.env.QWEN_COMPACT_MODE = prev;
});
