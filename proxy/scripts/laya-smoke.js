// Live acceptance: requires the real pinned local Laya service, never a stub.
import assert from "node:assert/strict";
import { jevEvaluate, routeLocalRequest } from "../src/jev.js";
const opts = { localUrl: "http://127.0.0.1:18000", mode: "local-only", model: "typed-decisions", timeoutMs: 10000 };
const state = "We were billed twice for March. Please refund the duplicate today or we will cancel our plan.";
const start = performance.now();
const result = await jevEvaluate(state, {
  department: { type: "choice", instructions: "Which department should handle this?",
    criteria: { billing: "invoices, payments, refunds", technical: "bugs, outages, system errors", other: "everything else" } },
  urgency: { type: "score", instructions: "How urgent is this?", criteria: ["not urgent", "soon", "blocking"] },
  churn_risk: { type: "noul", instructions: "Does the user threaten to cancel or leave?" },
}, opts);
assert.ok(result, "real local inference must succeed");
assert.equal(result._source, "local");
assert.equal(result.answers.department.choice, "billing");
assert.ok(result.answers.churn_risk.noul > 0.5, "explicit cancellation threat must be recognized");
assert.ok(Number.isFinite(result.answers.urgency.score));
assert.equal(result.usage.output_tokens, 0);
const route = await routeLocalRequest("Please extract the invoice number INV-123 from this sentence.", opts);
assert.ok(route && route.source === "local", "proxy route client must use the local checkpoint");
assert.ok(["local_direct", "local_think", "compact"].includes(route.route));
console.log(JSON.stringify({ elapsed_ms: Math.round(performance.now()-start), model: result.model,
  answers: result.answers, usage: result.usage, proxy_route: route.route,
  proxy_route_confidence: route.routeConfidence }, null, 2));
