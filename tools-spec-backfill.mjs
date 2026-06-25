// tools-spec-backfill — satisfy strict upstreams that require a `tools` spec
// for every tool_use referenced in history.
//
// PROBLEM:
// Claude Code's `/goal` evaluator (and any other internal sub-request that
// replays the conversation transcript to a judge model) forwards the message
// history — which contains assistant `tool_use` blocks and user `tool_result`
// blocks — but sends NO top-level `tools` field, because the judge call itself
// needs no tools. The real Anthropic API tolerates this. Some Anthropic-
// compatible gateways (e.g. a cc-switch upstream / third-party relay) validate
// strictly and reject with:
//   400 历史消息含 tool_use 或 tool_result，但顶层 tools 字段为空。
//       请补全 tools 字段后重发(每个 history 引用的工具都需有对应 spec)
// That 400 bubbles up to the Stop hook as "Hook evaluator API error" and
// blocks the hook from ever evaluating its condition.
//
// FIX (fail-safe, minimal):
// Before forwarding, scan messages for the set of tool names referenced by
// `tool_use` blocks. If that set is non-empty AND the top-level `tools` is
// missing/empty, synthesize a placeholder spec per name. If `tools` is present
// but missing some referenced names, backfill only the gaps. Specs use a
// permissive `{ type: "object" }` schema — the judge model will not actually
// CALL these tools (it's answering a text question), so the schema only has to
// satisfy the gateway's "every referenced tool has a spec" check; it never has
// to match the original tool's real input shape.
//
// SAFETY:
// - Never overwrites or mutates existing tool specs — only appends missing ones.
// - No-ops entirely when there are no tool_use blocks (normal first-turn
//   requests, bootstrap, etc. are untouched).
// - No-ops when every referenced name already has a spec (the overwhelmingly
//   common case — real CC requests always carry their tools), so normal
//   traffic pays only a cheap scan and is forwarded byte-identical.
// - Builds new arrays/objects; does not mutate the caller's body in place
//   beyond reassigning body.tools.

const SKIP = process.env.CACHE_FIX_SKIP_TOOLS_SPEC_BACKFILL === "1";

// Collect the set of tool names referenced by tool_use blocks across all
// messages. Only assistant messages carry tool_use, but we scan defensively
// regardless of role. tool_result blocks reference a tool_use_id (not a name),
// so they need no spec of their own — covering every tool_use name is
// sufficient for the gateway's validation.
function collectReferencedToolNames(messages) {
  const names = new Set();
  if (!Array.isArray(messages)) return names;
  for (const msg of messages) {
    if (!msg || !Array.isArray(msg.content)) continue;
    for (const block of msg.content) {
      if (
        block &&
        typeof block === "object" &&
        block.type === "tool_use" &&
        typeof block.name === "string" &&
        block.name.length > 0
      ) {
        names.add(block.name);
      }
    }
  }
  return names;
}

function existingToolNames(tools) {
  const names = new Set();
  if (!Array.isArray(tools)) return names;
  for (const t of tools) {
    if (t && typeof t === "object" && typeof t.name === "string") {
      names.add(t.name);
    }
  }
  return names;
}

function makePlaceholderSpec(name) {
  return {
    name,
    description:
      "Placeholder spec backfilled by cache-fix tools-spec-backfill so a " +
      "transcript replay (e.g. /goal evaluator) passes strict-gateway " +
      "tool-spec validation. Not intended to be invoked.",
    input_schema: { type: "object", properties: {}, additionalProperties: true },
  };
}

// Pure core, exported for unit testing. Returns { tools, stats } where `tools`
// is the (possibly unchanged) tools array to forward and `stats` is null when
// nothing was backfilled.
function backfillTools(body) {
  if (!body || typeof body !== "object") return { tools: body?.tools, stats: null };

  const referenced = collectReferencedToolNames(body.messages);
  if (referenced.size === 0) return { tools: body.tools, stats: null };

  const present = existingToolNames(body.tools);
  const missing = [...referenced].filter((n) => !present.has(n));
  if (missing.length === 0) return { tools: body.tools, stats: null };

  const base = Array.isArray(body.tools) ? body.tools.slice() : [];
  for (const name of missing) base.push(makePlaceholderSpec(name));

  return {
    tools: base,
    stats: {
      referenced: referenced.size,
      present: present.size,
      backfilled: missing.length,
      names: missing,
    },
  };
}

export { collectReferencedToolNames, existingToolNames, backfillTools };

export default {
  name: "tools-spec-backfill",
  description:
    "Synthesize placeholder tool specs for tool_use names referenced in history when the top-level tools field is missing/empty, so strict upstreams accept transcript-replay requests (e.g. the /goal Stop-hook evaluator)",
  enabled: true,
  // Run late: after any extension that might strip or rewrite tools, so we see
  // the final tools array that will actually be forwarded.
  order: 450,

  async onRequest(ctx) {
    if (SKIP) return;
    if (!ctx || !ctx.body) return;

    const { tools, stats } = backfillTools(ctx.body);
    if (!stats) return;

    ctx.body.tools = tools;
    ctx.meta = ctx.meta || {};
    ctx.meta.toolsSpecBackfillStats = stats;
    process.stderr.write(
      `[tools-spec-backfill] backfilled ${stats.backfilled} tool spec(s) ` +
        `(${stats.names.join(", ")}) — referenced=${stats.referenced} present=${stats.present}\n`,
    );
  },
};
