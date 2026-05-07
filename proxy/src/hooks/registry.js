// Built-in hook registry per docs/hooks-middleware.md §6.5.
//
// Static map of `built-in:<id>` -> { module, exportName }. Resolves both
// built-in IDs and `./relative.js#exportName` paths relative to this file.

import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import * as tagBashRead from "./tag-bash-read-elisions.js";
import * as ctxPressure from "./context-pressure-reminder.js";
import * as proseSummarize from "./prose-summarize.js";
import * as oncePerSession from "./once-per-session.js";
import * as sessionHintLoader from "./session-hint-loader.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

const BUILTINS = {
  "tag-bash-read-elisions": tagBashRead,
  "context-pressure-reminder": ctxPressure,
  "prose-summarize": proseSummarize,
  "once-per-session": oncePerSession,
  "session-hint-loader": sessionHintLoader,
};

// Resolve a YAML `handler:` (or `predicate_module:`) string to a function.
// Accepts `built-in:<id>` and `./relative.js#exportName`. Throws on miss.
export async function resolveHandler(spec) {
  if (typeof spec !== "string") {
    throw new Error(`hook handler spec must be a string, got ${typeof spec}`);
  }
  if (spec.startsWith("built-in:")) {
    const id = spec.slice("built-in:".length);
    const mod = BUILTINS[id];
    if (!mod) throw new Error(`unknown built-in hook id: ${id}`);
    const fn = mod.handler || mod.default;
    if (typeof fn !== "function") {
      throw new Error(`built-in '${id}' has no handler/default export`);
    }
    return fn;
  }
  if (spec.startsWith("./") || spec.startsWith("../")) {
    const [path, exportName = "default"] = spec.split("#");
    const abs = resolve(__dirname, path);
    const mod = await import(pathToFileURL(abs).href);
    const fn = mod[exportName];
    if (typeof fn !== "function") {
      throw new Error(`module ${path} has no '${exportName}' export`);
    }
    return fn;
  }
  throw new Error(`unrecognized handler spec: ${spec}`);
}

export function listBuiltinIds() {
  return Object.keys(BUILTINS);
}
