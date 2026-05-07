// Hook engine — docs/hooks-middleware.md v0.2.
//
// Minimal MVP: in-memory phase -> handler list, priority-sorted. Empty-registry
// dispatch is a fast no-op (`hasHooksFor`). Action verbs operate on a
// per-request context object built by `createContext`. Error isolation per §6.
//
// Scope: request:* phases only. Stream/response phases not yet wired.

const KNOWN_PHASES = new Set([
  "request:received",
  "request:before-rewrite",
  "request:after-rewrite",
  "request:before-upstream-send",
  "stream:context-trigger",
  "response:end",
  "response:after-log",
]);

export class HookPhaseClosedError extends Error {
  constructor(action) {
    super(`hook phase closed for action ${action}`);
    this.name = "HookPhaseClosedError";
  }
}

export function createEngine({ logger } = {}) {
  /** @type {Map<string, Array<object>>} */
  const phases = new Map();
  const log = logger || { warn() {}, info() {}, debug() {} };

  function register(phase, entry) {
    if (!KNOWN_PHASES.has(phase)) {
      throw new Error(`unknown hook phase: ${phase}`);
    }
    if (typeof entry?.handler !== "function") {
      throw new Error(`hook ${entry?.id || "?"}: handler must be a function`);
    }
    const list = phases.get(phase) || [];
    if (entry.id && list.some((e) => e.id === entry.id)) {
      throw new Error(`duplicate hook id '${entry.id}' in phase ${phase}`);
    }
    list.push({
      id: entry.id || `hook-${list.length}`,
      handler: entry.handler,
      filter: entry.filter || null,
      predicate: entry.predicate || null,
      priority: typeof entry.priority === "number" ? entry.priority : 100,
      timeout_ms: entry.timeout_ms ?? 50,
      config: entry.config || {},
    });
    list.sort((a, b) => a.priority - b.priority);
    phases.set(phase, list);
  }

  function hasHooksFor(phase) {
    const l = phases.get(phase);
    return !!l && l.length > 0;
  }

  // Evaluate the (very small) declarative filter DSL needed for MVP.
  // Phase-irrelevant keys evaluate false; unknown keys throw at registration
  // (not enforced in MVP — programmatic registrations only).
  function filterMatches(filter, ctx) {
    if (!filter) return true;
    if (filter.has_tag && !ctx.tags.has(filter.has_tag)) return false;
    if (filter.tool_name && ctx.toolName !== filter.tool_name) return false;
    if (
      filter.prompt_token_fraction_gt != null &&
      !(ctx.promptTokenFraction > filter.prompt_token_fraction_gt)
    ) {
      return false;
    }
    if (filter.any && Array.isArray(filter.any)) {
      if (!filter.any.some((f) => filterMatches(f, ctx))) return false;
    }
    if (filter.all && Array.isArray(filter.all)) {
      if (!filter.all.every((f) => filterMatches(f, ctx))) return false;
    }
    return true;
  }

  async function dispatch(phase, ctx) {
    const list = phases.get(phase);
    if (!list || list.length === 0) return;
    ctx._currentPhase = phase;
    for (const entry of list) {
      if (ctx._aborted) break;
      if (!filterMatches(entry.filter, ctx)) continue;
      if (entry.predicate && !entry.predicate(ctx, entry.config)) continue;
      ctx._currentHookId = entry.id;
      const start = Date.now();
      let timer = null;
      try {
        await Promise.race([
          Promise.resolve(entry.handler(ctx, entry.config)),
          new Promise((_, rej) => {
            timer = setTimeout(
              () => rej(new Error(`hook timeout ${entry.timeout_ms}ms`)),
              entry.timeout_ms,
            );
          }),
        ]);
      } catch (err) {
        log.warn?.(
          { hookId: entry.id, phase, err: err.message, requestId: ctx.requestId },
          "hook error; continuing",
        );
        ctx.hookErrors.push({ id: entry.id, phase, message: err.message });
      } finally {
        if (timer) clearTimeout(timer);
      }
      const ms = Date.now() - start;
      ctx.hookTimingsMs[entry.id] =
        (ctx.hookTimingsMs[entry.id] || 0) + ms;
    }
    ctx._currentHookId = null;
    ctx._currentPhase = null;
  }

  return { register, hasHooksFor, dispatch, _phases: phases };
}

// Build a per-request mutable context with action verbs. The host (server.js)
// fills in fields per phase via `update(fields)`. Sealed top-level keys.
export function createContext(initial = {}) {
  const ctx = {
    requestId: initial.requestId || null,
    start: initial.start || Date.now(),
    rawBody: initial.rawBody || null,
    headers: initial.headers || {},
    compactOff: !!initial.compactOff,
    isStreaming: !!initial.isStreaming,
    model: initial.model || null,
    parsed: initial.parsed || null,
    messages: initial.messages || null,
    nCtx: initial.nCtx || 0,
    promptTokens: initial.promptTokens ?? null,
    promptTokenFraction: initial.promptTokenFraction ?? null,
    rewrite: null,
    outboundMessages: null,
    elidedIds: [],
    outboundBuf: null,
    sniffBuf: null,
    upstreamStatus: null,
    latencyMs: null,
    jsonlRecord: null,
    hookTimingsMs: {},
    hookErrors: [],
    totalHookTimeMs: 0,
    tags: new Set(),
    // Phase scratch
    triggerRatio: null,
    threshold: null,
    sessionHintPath: null,
    toolName: null,
    toolCallId: null,
    // Internal
    _currentPhase: null,
    _currentHookId: null,
    _aborted: false,
    _abortPayload: null,
    _replaceCalls: {}, // for tests
    _injectCalls: [],
    // Action verbs
    tag(name) {
      if (typeof name !== "string") return;
      const t = name.trim();
      if (!t) return;
      this.tags.add(t);
    },
    mutate(path, value) {
      // Dot-path set on a known top-level container: messages.* or
      // outboundMessages.*. MVP: just walk and assign.
      const parts = String(path).split(".");
      const root = parts.shift();
      const rootVal = root === "messages" ? this.messages : this[root];
      if (!rootVal) return;
      let obj = rootVal;
      while (parts.length > 1) {
        const k = parts.shift();
        if (obj[k] == null) return;
        obj = obj[k];
      }
      obj[parts[0]] = value;
    },
    replace(field, value) {
      this._replaceCalls[field] = value;
      if (field === "messages") {
        this.messages = value;
        if (this.parsed) this.parsed.messages = value;
      } else if (field === "outboundMessages") {
        this.outboundMessages = value;
      } else if (field === "outboundBuf") {
        this.outboundBuf = value;
      }
    },
    inject(roleOrPos, content, position) {
      // Two call shapes per spec: positional ('before'|'after', message) used
      // by `request:after-rewrite`, and (role, content, placement) used by
      // handler convenience. Normalize both.
      let entry;
      if (
        (roleOrPos === "before" || roleOrPos === "after") &&
        typeof content === "object"
      ) {
        entry = { position: roleOrPos, message: content };
      } else {
        entry = {
          position: position || "before-final-user",
          message: { role: roleOrPos, content: String(content || "") },
        };
      }
      this._injectCalls.push(entry);
      // Splice into outboundMessages when available with placement fallbacks.
      const list = this.outboundMessages || this.messages;
      if (Array.isArray(list)) {
        const msg = {
          ...entry.message,
          _hook_injected: true,
          _hook_id: this._currentHookId,
        };
        if (entry.position === "before" || entry.position === "before-final-user") {
          // Find last system, place after it; else before first user; else append.
          let idx = -1;
          for (let i = list.length - 1; i >= 0; i--) {
            if (list[i].role === "system") { idx = i; break; }
          }
          if (idx >= 0) list.splice(idx + 1, 0, msg);
          else {
            const firstUser = list.findIndex((m) => m.role === "user");
            if (firstUser >= 0) list.splice(firstUser, 0, msg);
            else list.push(msg);
          }
        } else if (entry.position === "after") {
          // Before final user turn, fallback to append.
          let idx = -1;
          for (let i = list.length - 1; i >= 0; i--) {
            if (list[i].role === "user") { idx = i; break; }
          }
          if (idx >= 0) list.splice(idx, 0, msg);
          else list.push(msg);
        } else {
          list.push(msg);
        }
      }
    },
    abort(statusCode, body) {
      this._aborted = true;
      this._abortPayload = { statusCode, body };
    },
  };
  return ctx;
}
