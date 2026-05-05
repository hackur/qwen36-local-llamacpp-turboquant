// Tests for tier2-index.js. Run with `node --test tests/`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildToolCallIndex } from "../src/tier2-index.js";

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
