// Tests for tier2-index.js. Run with `node --test tests/`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { buildToolCallIndex } from "../src/tier2-index.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

test("OpenAI shape: assistant tool_calls + tool result", () => {
  const messages = [
    {
      role: "assistant",
      content: null,
      tool_calls: [
        {
          id: "call_abc123",
          type: "function",
          function: {
            name: "Read",
            arguments: JSON.stringify({ file_path: "src/auth.py" }),
          },
        },
      ],
    },
    {
      role: "tool",
      tool_call_id: "call_abc123",
      content: "line1\nline2\nline3\n",
    },
  ];
  const out = buildToolCallIndex(messages);
  assert.equal(out.indexLines.length, 1);
  assert.match(out.indexLines[0], /Read/);
  assert.match(out.indexLines[0], /path=src\/auth\.py/);
  assert.match(out.indexLines[0], /→/);
  assert.deepEqual(out.coveredMessageIndices, [0, 1]);
  assert.ok(out.tokenEstimate > 0);
});

test("Anthropic shape: tool_use + tool_result content blocks", () => {
  const messages = [
    {
      role: "assistant",
      content: [
        { type: "text", text: "Let me check that." },
        {
          type: "tool_use",
          id: "toolu_xyz789",
          name: "Bash",
          input: { command: "pytest tests/auth/" },
        },
      ],
    },
    {
      role: "user",
      content: [
        {
          type: "tool_result",
          tool_use_id: "toolu_xyz789",
          content: [{ type: "text", text: "exit code: 1\n3 failures" }],
          is_error: true,
        },
      ],
    },
  ];
  const out = buildToolCallIndex(messages);
  assert.equal(out.indexLines.length, 1);
  assert.match(out.indexLines[0], /Bash/);
  assert.match(out.indexLines[0], /cmd="pytest tests\/auth\/"/);
  assert.match(out.indexLines[0], /exit=1/);
  assert.match(out.indexLines[0], /error/);
});

test("mixed batch with multiple tools", () => {
  const messages = [
    {
      role: "assistant",
      tool_calls: [
        {
          id: "call_1",
          function: { name: "Read", arguments: '{"file_path":"a.py"}' },
        },
        {
          id: "call_2",
          function: {
            name: "Edit",
            arguments: JSON.stringify({
              file_path: "a.py",
              old_string: "x\ny\nz",
              new_string: "q",
            }),
          },
        },
      ],
    },
    { role: "tool", tool_call_id: "call_1", content: "100 lines of file" },
    { role: "tool", tool_call_id: "call_2", content: "applied" },
    {
      role: "assistant",
      content: [
        {
          type: "tool_use",
          id: "toolu_3",
          name: "Grep",
          input: { pattern: "TODO", path: "src/" },
        },
      ],
    },
    {
      role: "user",
      content: [
        {
          type: "tool_result",
          tool_use_id: "toolu_3",
          content: "found 7 matches",
        },
      ],
    },
  ];
  const out = buildToolCallIndex(messages);
  assert.equal(out.indexLines.length, 3);
  assert.match(out.indexLines[0], /Read/);
  assert.match(out.indexLines[1], /Edit/);
  assert.match(out.indexLines[1], /\(3 lines\)/);
  assert.match(out.indexLines[2], /Grep/);
  assert.match(out.indexLines[2], /pattern="TODO"/);
  assert.deepEqual(out.coveredMessageIndices, [0, 1, 2, 3, 4]);
});

test("stable id generation: same input -> same id", () => {
  const make = () => [
    {
      role: "assistant",
      // No id provided — should hash to a stable value.
      tool_calls: [
        {
          function: { name: "Read", arguments: '{"file_path":"x.py"}' },
        },
      ],
    },
  ];
  const a = buildToolCallIndex(make());
  const b = buildToolCallIndex(make());
  assert.deepEqual(a.indexLines, b.indexLines);
  // Hashed id format: [tXXXXXX]
  assert.match(a.indexLines[0], /^\[t[0-9a-f]{6}\] /);
});

test("stable id generation: existing id is preserved/normalized", () => {
  const messages = [
    {
      role: "assistant",
      tool_calls: [
        {
          id: "call_DEADBE",
          function: { name: "Read", arguments: '{"file_path":"x"}' },
        },
      ],
    },
  ];
  const out = buildToolCallIndex(messages);
  assert.match(out.indexLines[0], /^\[tDEADBE\]/);
});

test("extractor: Read with offset/limit", () => {
  const out = buildToolCallIndex([
    {
      role: "assistant",
      tool_calls: [
        {
          id: "call_r",
          function: {
            name: "Read",
            arguments: JSON.stringify({ file_path: "f.py", offset: 88, limit: 14 }),
          },
        },
      ],
    },
  ]);
  assert.match(out.indexLines[0], /path=f\.py L88-L102/);
});

test("extractor: Bash quotes command", () => {
  const out = buildToolCallIndex([
    {
      role: "assistant",
      tool_calls: [
        {
          id: "call_b",
          function: { name: "Bash", arguments: '{"command":"ls -la"}' },
        },
      ],
    },
  ]);
  assert.match(out.indexLines[0], /cmd="ls -la"/);
});

test("extractor: Write reports byte size", () => {
  const out = buildToolCallIndex([
    {
      role: "assistant",
      tool_calls: [
        {
          id: "call_w",
          function: {
            name: "Write",
            arguments: JSON.stringify({ file_path: "out.txt", content: "hello world" }),
          },
        },
      ],
    },
  ]);
  assert.match(out.indexLines[0], /path=out\.txt 11B/);
});

test("extractor: Glob", () => {
  const out = buildToolCallIndex([
    {
      role: "assistant",
      tool_calls: [
        {
          id: "call_g",
          function: {
            name: "Glob",
            arguments: JSON.stringify({ pattern: "**/*.js", path: "src" }),
          },
        },
      ],
    },
  ]);
  assert.match(out.indexLines[0], /Glob/);
  assert.match(out.indexLines[0], /pattern="\*\*\/\*\.js"/);
  assert.match(out.indexLines[0], /path=src/);
});

test("extractor: WebFetch", () => {
  const out = buildToolCallIndex([
    {
      role: "assistant",
      tool_calls: [
        {
          id: "call_wf",
          function: {
            name: "WebFetch",
            arguments: JSON.stringify({ url: "https://example.com/foo" }),
          },
        },
      ],
    },
  ]);
  assert.match(out.indexLines[0], /WebFetch/);
  assert.match(out.indexLines[0], /url=https:\/\/example\.com\/foo/);
});

test("generic fallback for unknown tool", () => {
  const out = buildToolCallIndex([
    {
      role: "assistant",
      tool_calls: [
        {
          id: "call_u",
          function: {
            name: "MysteryTool",
            arguments: JSON.stringify({ alpha: "one", beta: 2, gamma: "three" }),
          },
        },
      ],
    },
  ]);
  // Only first 1-2 keys, joined.
  assert.match(out.indexLines[0], /MysteryTool/);
  assert.match(out.indexLines[0], /alpha=/);
});

test("call without result reports (no result)", () => {
  const out = buildToolCallIndex([
    {
      role: "assistant",
      tool_calls: [
        { id: "call_x", function: { name: "Read", arguments: '{"file_path":"a"}' } },
      ],
    },
  ]);
  assert.match(out.indexLines[0], /\(no result\)/);
});

test("custom toolNamePad and tokenizer", () => {
  const out = buildToolCallIndex(
    [
      {
        role: "assistant",
        tool_calls: [
          { id: "c1", function: { name: "Read", arguments: '{"file_path":"a"}' } },
        ],
      },
    ],
    { toolNamePad: 10, tokenizer: (s) => s.length },
  );
  // "Read" padded to 10 chars before the args.
  assert.match(out.indexLines[0], /\[tc1\] Read {6} path=a/);
  assert.equal(out.tokenEstimate, out.indexLines[0].length);
});

test("empty input returns empty result", () => {
  const out = buildToolCallIndex([]);
  assert.deepEqual(out.indexLines, []);
  assert.deepEqual(out.coveredMessageIndices, []);
  assert.equal(out.tokenEstimate, 0);
});

// ---------- realistic-session sanity check ---------------------------------

test("realistic 30-turn session: index lines look healthy", () => {
  const fixturePath = join(__dirname, "fixtures", "realistic_session.json");
  const messages = JSON.parse(readFileSync(fixturePath, "utf8"));
  const out = buildToolCallIndex(messages);

  // Every tool call should produce a line.
  assert.equal(out.indexLines.length, 20);

  // Every line has the [tXXXXXX] id prefix and a → separator.
  for (const line of out.indexLines) {
    assert.match(line, /^\[t[A-Za-z0-9]{1,6}\]\s+\S/, `bad prefix: ${line}`);
    assert.ok(line.includes("→"), `missing arrow: ${line}`);
    // No raw newlines — all results should be inline-escaped.
    assert.ok(!line.includes("\n"), `embedded newline: ${line}`);
  }

  // Spot-check a few specific lines for informative args.
  const joined = out.indexLines.join("\n");
  assert.match(joined, /Read\s+path=src\/auth\.py L80-L120/);
  assert.match(joined, /Bash\s+cmd="pytest tests\/auth\/ -x"/);
  assert.match(joined, /Edit\s+path=src\/auth\.py \(3 lines\)/);
  assert.match(joined, /Write\s+path=tests\/auth\/conftest\.py 76B/);
  assert.match(joined, /Glob\s+pattern="\*\*\/\*\.py"/);
  assert.match(joined, /WebFetch url=https:\/\/pyjwt/);

  // Generic-fallback tools should still produce something useful — first 1–2
  // keys of args, joined.
  assert.match(joined, /MysteryTool alpha=one beta=2/);
  assert.match(joined, /ProjectScan include=/);

  // Result summarization signals must be lifted from tool results.
  assert.match(joined, /exit=1/);
  assert.match(joined, /exit=0/);
});

test("realistic session: token-budget compression is honest", () => {
  // Compression ratio depends entirely on how heavy the evicted tool results
  // are. The §6 doc claim of "5–20×" is the upper-bound range when tool
  // results dominate; on a fixture with terse results we measure ~3–4×.
  // We assert a floor of 2× so the test catches regressions but doesn't
  // over-promise.
  const fixturePath = join(__dirname, "fixtures", "realistic_session.json");
  const messages = JSON.parse(readFileSync(fixturePath, "utf8"));
  // qwen-ish ratio: ~3.5 chars per token.
  const tok = (s) => Math.ceil((s ? String(s).length : 0) / 3.5);
  const out = buildToolCallIndex(messages, { tokenizer: tok });

  const origTokens = tok(JSON.stringify(messages));
  const idxTokens = out.tokenEstimate;
  const ratio = origTokens / idxTokens;

  // Sanity: shrinkage is real.
  assert.ok(idxTokens > 0);
  assert.ok(ratio >= 2.0, `expected >=2x compression, got ${ratio.toFixed(2)}x`);
  // Documented measurement (informational): with terse tool outputs we see
  // ~3.9x. With realistic large outputs (Read of a 400-line file, pytest
  // verbose logs) the ratio rises into the 5–20x range claimed in §6.
});

// ---------- stable-id collision check at scale -----------------------------

test("stable id: 1000 distinct (role,name,args) tuples produce no collisions", () => {
  // Hash truncation to 6 hex chars = 16,777,216 buckets. By the birthday
  // bound, collision probability for n=1000 is approximately
  //     1 - exp(-n*(n-1)/(2*16777216)) ≈ 2.98%.
  // Using a deterministic PRNG, we expect zero collisions for *this* seed
  // run. The test asserts zero; if a future change to stableId narrows the
  // hash space or seeds change, this will catch it.
  function mulberry32(a) {
    return function () {
      a |= 0;
      a = (a + 0x6d2b79f5) | 0;
      let t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  const rand = mulberry32(0xC0DE);
  const tools = ["Read", "Bash", "Edit", "Write", "Grep", "Glob", "WebFetch", "Mystery"];
  // Only "assistant" so messages are unambiguously tool_calls (not results).
  // The point of this test is hash-collision coverage on stableId, not the
  // walker's role-dispatch logic.
  const messages = [];
  for (let i = 0; i < 1000; i++) {
    const name = tools[Math.floor(rand() * tools.length)];
    // Make args unique per i so tuples are distinct.
    const args = { idx: i, salt: Math.floor(rand() * 1e9), tag: `t-${i}` };
    messages.push({
      role: "assistant",
      tool_calls: [{ /* no id → forces hash path */ function: { name, arguments: JSON.stringify(args) } }],
    });
  }
  const out = buildToolCallIndex(messages);
  const ids = out.indexLines.map((l) => l.match(/^\[(t[^\]]+)\]/)[1]);
  const uniq = new Set(ids);
  assert.equal(uniq.size, ids.length, `collisions: ${ids.length - uniq.size}`);
});
