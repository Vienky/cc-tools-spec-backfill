#!/usr/bin/env node
// 自包含单元测试,零依赖。运行: node test.mjs
import { backfillTools } from "./tools-spec-backfill.mjs";

let pass = 0, fail = 0;
function assert(cond, msg) {
  if (cond) { pass++; console.log("  ok:", msg); }
  else { fail++; console.error("  FAIL:", msg); }
}

// C1: 历史有 tool_use,无顶层 tools -> 补全
{
  const b = { messages: [
    { role: "assistant", content: [{ type: "tool_use", id: "a", name: "Bash", input: {} }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "a", content: "out" }] },
    { role: "assistant", content: [{ type: "tool_use", id: "b", name: "Read", input: {} }] },
  ]};
  const r = backfillTools(b);
  assert(r.stats && r.stats.backfilled === 2, "C1 补全 2 个 (Bash, Read)");
  assert(Array.isArray(r.tools) && r.tools.length === 2, "C1 tools 数组长度 2");
  assert(r.tools.every(t => t.name && t.input_schema?.type === "object"), "C1 spec 结构合法");
}

// C2: 所有引用的工具已有 spec -> no-op
{
  const b = { tools: [{ name: "Bash", input_schema: { type: "object" } }], messages: [
    { role: "assistant", content: [{ type: "tool_use", id: "a", name: "Bash", input: {} }] },
  ]};
  const r = backfillTools(b);
  assert(r.stats === null, "C2 全部已存在时 no-op");
  assert(r.tools === b.tools, "C2 tools 引用不变");
}

// C3: 部分缺失 -> 只补缺口,不动原数组
{
  const b = { tools: [{ name: "Bash", input_schema: { type: "object" } }], messages: [
    { role: "assistant", content: [
      { type: "tool_use", id: "a", name: "Bash", input: {} },
      { type: "tool_use", id: "b", name: "Grep", input: {} },
    ]},
  ]};
  const r = backfillTools(b);
  assert(r.stats && r.stats.backfilled === 1 && r.stats.names[0] === "Grep", "C3 只补 Grep");
  assert(r.tools.length === 2, "C3 最终 tools 长度 2");
  assert(b.tools.length === 1, "C3 未改动原 tools 数组");
}

// C4: 没有任何 tool_use -> no-op(普通首轮请求)
{
  const b = { messages: [{ role: "user", content: [{ type: "text", text: "hi" }] }] };
  const r = backfillTools(b);
  assert(r.stats === null && r.tools === undefined, "C4 无 tool_use 时 no-op");
}

// C5: tools:[] 空数组 + 有 tool_use -> 补全
{
  const b = { tools: [], messages: [{ role: "assistant", content: [{ type: "tool_use", id: "a", name: "X", input: {} }] }] };
  const r = backfillTools(b);
  assert(r.stats && r.stats.backfilled === 1, "C5 空 tools 数组也补全");
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
