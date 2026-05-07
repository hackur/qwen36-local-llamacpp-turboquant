// Phase 3 — Session keying + stable-prefix discipline (instrumented).
//
// This module is intentionally minimal: it computes a stable session key for
// every chat request and identifies the longest "stable" prefix of messages
// (system + initial user) so a future commit can wire it to llama.cpp's
// `/slots/<id>/save` and `/slots/<id>/restore` endpoints. Until that wire-up
// lands, loadSlot/saveSlot are no-ops — Phase 3 ships as instrumentation only,
// gated by `session.enabled`. When the gate is off, callers don't invoke any
// of this and request bytes are forwarded byte-identically.
//
// Session-key algorithm (deterministic, no state required):
//   1. user identity        := authorizedUser || 'anon'
//      (currently the proxy has no authn — placeholder for future plumbing.)
//   2. body hint            := body.user (OpenAI-spec optional field) if a
//                              non-empty string, else the request header named
//                              by `session.key_header` (default x-session-id),
//                              else a SHA-256 hash of JSON(messages[0]) when
//                              messages exist, else 'no-messages'.
//   3. sessionKey           := sha256(`${userIdentity}::${bodyHint}`) hex,
//                              truncated to 32 hex chars (128 bits).
// The 128-bit truncation is enough to make collisions astronomically unlikely
// across a single host's lifetime while keeping logs readable.
//
// Stable-prefix algorithm:
//   - Walk messages from index 0.
//   - Accept role==='system' messages.
//   - Accept the first role==='user' message after the system block.
//   - Stop at the first message that is not part of that pattern (assistant,
//     tool, second user, etc.) — those are dynamic.
// The returned hash is sha256(JSON(prefix)) so two requests sharing the exact
// same opening can be detected without storing the prefix itself.

import { createHash } from "node:crypto";

const SESSION_KEY_BITS_HEX = 32; // 128 bits

function sha256Hex(s) {
  return createHash("sha256").update(s).digest("hex");
}

export function keyForRequest(req, body, { keyHeader = "x-session-id", authorizedUser = null } = {}) {
  const user = authorizedUser || "anon";
  let hint = "";
  if (body && typeof body.user === "string" && body.user.length > 0) {
    hint = `body.user:${body.user}`;
  } else if (req && req.headers && typeof req.headers[keyHeader] === "string" && req.headers[keyHeader]) {
    hint = `hdr:${req.headers[keyHeader]}`;
  } else if (body && Array.isArray(body.messages) && body.messages.length > 0) {
    hint = `msg0:${sha256Hex(JSON.stringify(body.messages[0]))}`;
  } else {
    hint = "no-messages";
  }
  return sha256Hex(`${user}::${hint}`).slice(0, SESSION_KEY_BITS_HEX);
}

// Approximate token count for the prefix. We avoid awaiting the upstream
// /tokenize endpoint here — extractStablePrefix is called synchronously on
// request entry and the value is purely instrumentation. ~4 chars/token is the
// conventional rough conversion for English JSON payloads.
function approximateTokens(prefix) {
  return Math.ceil(JSON.stringify(prefix).length / 4);
}

export function extractStablePrefix(messages) {
  if (!Array.isArray(messages) || messages.length === 0) {
    return { prefix: [], prefixHash: sha256Hex("[]"), prefixTokens: 0 };
  }
  const prefix = [];
  let sawUser = false;
  for (const m of messages) {
    if (!m || typeof m.role !== "string") break;
    if (m.role === "system" && !sawUser) {
      prefix.push(m);
      continue;
    }
    if (m.role === "user" && !sawUser) {
      prefix.push(m);
      sawUser = true;
      continue;
    }
    break;
  }
  const serialized = JSON.stringify(prefix);
  return {
    prefix,
    prefixHash: sha256Hex(serialized),
    prefixTokens: approximateTokens(prefix),
  };
}

// In-memory session registry. Keyed by sessionKey. TTL eviction is lazy —
// touched by every operation. A future commit may persist this to disk; for
// now it is per-process state and we don't care if it dies with the proxy.
//
// Visible for test injection: clock defaults to Date.now but tests can pass a
// stub via createSessionStore({ clock }).
export function createSessionStore({ ttlSeconds = 3600, clock = Date.now, logger = null } = {}) {
  const map = new Map();
  const ttlMs = ttlSeconds * 1000;

  function evict(now) {
    for (const [k, v] of map) {
      if (now - v.lastSeen > ttlMs) map.delete(k);
    }
  }

  function touch(sessionKey, patch = {}) {
    const now = clock();
    evict(now);
    const prev = map.get(sessionKey) || {};
    const next = { ...prev, ...patch, lastSeen: now };
    map.set(sessionKey, next);
    return next;
  }

  // No-op stubs: documented contract is that they NEVER do I/O until a future
  // commit wires `session.slot_endpoint_base` to llama.cpp /slots/*. Returning
  // null mirrors "no slot loaded".
  async function loadSlot(sessionKey) {
    if (logger) logger.debug({ sessionKey }, "session.loadSlot stub");
    const rec = map.get(sessionKey);
    if (rec) touch(sessionKey);
    return null;
  }

  async function saveSlot(sessionKey, prefixHash) {
    if (logger) logger.debug({ sessionKey, prefixHash }, "session.saveSlot stub");
    touch(sessionKey, { prefixHash });
    return null;
  }

  return {
    map,
    touch,
    loadSlot,
    saveSlot,
    size: () => map.size,
    _evictNow: () => evict(clock()),
  };
}
