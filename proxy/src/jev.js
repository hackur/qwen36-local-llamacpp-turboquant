// Optional classifier client. This module does not start Laya or register a
// model tool. rewrite.js calls it only when jev.local_url is configured;
// research.js can call it independently from the manual research script.
import { readFileSync, existsSync } from "node:fs";

function loadKey() {
  if (process.env.TYPESAFE_API_KEY) return process.env.TYPESAFE_API_KEY;
  const candidates = [
    new URL("../../.env", import.meta.url).pathname,
    new URL("../../../.env", import.meta.url).pathname,
  ];
  for (const p of candidates) {
    try {
      if (!existsSync(p)) continue;
      const text = readFileSync(p, "utf8");
      const m = text.match(/^TYPESAFE_API_KEY=(.+)$/m);
      if (m) return m[1].trim();
    } catch {}
  }
  return null;
}
function loadLocalUrl() {
  if (process.env.LAYA_URL) return process.env.LAYA_URL;
  return null;
}

async function postLocal(baseUrl, state, questions, opts, timeoutMs) {
  const url = String(baseUrl).replace(/\/+$/, "") + "/v1/systemone";
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const headers = { "content-type": "application/json" };
    const key = process.env.LAYA_API_KEY;
    if (key) headers.authorization = `Bearer ${key}`;
    const res = await fetch(url, { method: "POST", headers, body: JSON.stringify({ state, questions }), signal: controller.signal });
    if (!res.ok) return null;
    const json = await res.json();
    if (!json || typeof json !== "object" || !json.answers) return null;
    json._source = "local";
    return json;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function postCloud(apiKey, state, questions, opts, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const cloudBase = String(opts.cloudUrl ?? "https://api.typesafe.ai").replace(/\/+$/, "");
    const res = await fetch(cloudBase + "/v1/systemone", {
      method: "POST",
      headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({ model: opts.model ?? "jev-latest", state, questions }),
      signal: controller.signal,
    });
    if (!res.ok) return null;
    const json = await res.json();
    if (!json || typeof json !== "object" || !json.answers) return null;
    json._source = "cloud";
    return json;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

export async function jevEvaluate(state, questions, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? 4000;
  const localUrl = opts.localUrl ?? loadLocalUrl();
  const apiKey = opts.apiKey ?? loadKey();
  const mode = opts.mode ?? (localUrl ? "local-first" : "cloud-only");
  if (mode === "local-only") {
    if (!localUrl) return null;
    return postLocal(localUrl, state, questions, opts, timeoutMs);
  }
  if (mode === "cloud-only") {
    if (!apiKey) return null;
    return postCloud(apiKey, state, questions, opts, timeoutMs);
  }
  if (mode === "cloud-first") {
    if (apiKey) {
      const c = await postCloud(apiKey, state, questions, opts, timeoutMs);
      if (c) return c;
    }
    if (localUrl) return postLocal(localUrl, state, questions, opts, timeoutMs);
    return null;
  }
  if (mode === "parallel-race") {
    const makers = [];
    if (localUrl) makers.push(() => postLocal(localUrl, state, questions, opts, timeoutMs));
    if (apiKey) makers.push(() => postCloud(apiKey, state, questions, opts, timeoutMs));
    if (!makers.length) return null;
    const pendings = makers.map((fn) => fn().then((v) => { if (v) return v; return new Promise(() => {}); }));
    const timer = new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), timeoutMs * 2 + 500));
    try {
      return await Promise.race([...pendings, timer]);
    } catch {
      return null;
    }
  }
  if (localUrl) {
    const l = await postLocal(localUrl, state, questions, opts, timeoutMs);
    if (l) return l;
  }
  if (apiKey) return postCloud(apiKey, state, questions, opts, timeoutMs);
  return null;
}

export async function routeLocalRequest(stateText, opts = {}) {
  const out = await jevEvaluate(
    stateText,
    {
      needs_thinking: {
        type: "noul",
        instructions: "Needs deep reasoning vs direct lookup?",
      },
      route: {
        type: "choice",
        instructions: "Pick handler",
        criteria: {
          local_direct: "Lookup, extract, small edit, no thinking",
          local_think: "Arch, debug, multi-step",
          compact: "Context too long, summarize first",
        },
      },
      risk: {
        type: "score",
        instructions: "Tool-call danger",
        criteria: ["safe", "sensitive", "dangerous"],
      },
    },
    opts
  );
  if (!out) return null;
  return {
    raw: out,
    source: out._source ?? "unknown",
    needsThinking: out.answers?.needs_thinking?.noul ?? 0.5,
    route: out.answers?.route?.choice ?? "local_think",
    routeConfidence: out.answers?.route?.confidence ?? 0,
    risk: out.answers?.risk?.score ?? 0,
  };
}
