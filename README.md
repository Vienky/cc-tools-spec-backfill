# cc-tools-spec-backfill

> [English](#english) · [中文](#中文)

<a name="english"></a>

Fixes a 400 error that rejects Claude Code's `/goal` Stop-hook evaluator (and any
internal request that **replays the conversation transcript to a judge model**)
when traffic goes through **cc-switch + a strict third-party relay**:

```
Hook evaluator API error: API Error: 400 Provider API error:
历史消息含 tool_use 或 tool_result，但顶层 tools 字段为空。
请补全 tools 字段后重发（每个 history 引用的工具都需有对应 spec）
```

## Why it happens

Claude Code's `/goal` asks a "judge" model whether the goal is met. It forwards
the whole transcript (including `tool_use` / `tool_result` blocks) but sends **no
top-level `tools` field** — the judge needs no tools to answer.

- Real `api.anthropic.com`: **tolerates** this and responds normally.
- Some strict gateways / third-party relays: **reject** it whenever history
  references a tool but the top-level `tools` is empty — the 400 above.

So the `/goal` Stop hook can never evaluate its condition and stays stuck.

## What this patch does

It's an extension for the [`claude-code-cache-fix`](https://github.com/cnighswonger/claude-code-cache-fix)
proxy. Before forwarding a request it:

1. Scans history for every tool name referenced by `tool_use` blocks;
2. If the top-level `tools` is missing/empty, appends a **placeholder spec**
   (`input_schema: {type: object}`) for each name;
3. If `tools` exists but lacks some names, backfills only the gaps.

The judge model is answering a text question and never actually calls these
tools, so the placeholder only has to satisfy the gateway's "every referenced
tool has a spec" check — it need not match the tool's real input shape.

**Fail-safe:** no-op when there are no `tool_use` blocks; forwards byte-identical
when all tools already have specs; only appends, never overwrites. Zero impact
on normal traffic.

## Requirements

- macOS
- [`claude-code-cache-fix`](https://github.com/cnighswonger/claude-code-cache-fix)
  installed globally (`npm i -g claude-code-cache-fix`)
- cc-switch (or similar) pointing `ANTHROPIC_BASE_URL` in `~/.claude/settings.json`
  at a local port (auto-detected, default `:15721`)

## Install / Uninstall / Test

```bash
bash install.sh      # install (backs up settings, installs a launchd proxy)
node test.mjs        # zero-dependency unit tests
bash uninstall.sh    # revert everything
```

After install the path becomes:

```
/goal judge request → :15723 (this patch, backfills tools) → :15721 (cc-switch) → relay  ✅
```

The currently running session is unaffected; **new** Claude Code sessions pick it up.

Custom ports: `PROXY_PORT=15999 UPSTREAM_PORT=15721 bash install.sh`

## License

MIT. Usable standalone or as a PR back to `claude-code-cache-fix` (also MIT).

---

<a name="中文"></a>

# 中文

修复 Claude Code `/goal`(以及任何"重放对话历史给裁判模型"的内部请求)在**经过 cc-switch + 国内中转站**时被 400 拒绝的问题:

```
Hook evaluator API error: API Error: 400 Provider API error:
历史消息含 tool_use 或 tool_result，但顶层 tools 字段为空。
请补全 tools 字段后重发（每个 history 引用的工具都需有对应 spec）
```

## 原因

Claude Code 的 `/goal` 会让一个"裁判 AI"判断目标是否达成。它把整段对话历史(含 `tool_use` / `tool_result` 块)发给裁判,但**请求顶层不带 `tools` 字段**——因为裁判本身不需要调用工具。

- 官方 `api.anthropic.com`:**容忍**这种请求,正常返回。
- 部分国内中转站 / 第三方网关:**严格校验**,只要历史里引用了工具而顶层 `tools` 为空,就报上面那句 400。

于是 `/goal` 的 Stop hook 永远评估不了条件,一直卡住。

## 本补丁怎么修

它是 [`claude-code-cache-fix`](https://github.com/cnighswonger/claude-code-cache-fix) 代理的一个扩展插件。在请求转发前:

1. 扫描历史里 `tool_use` 引用到的所有工具名;
2. 如果顶层 `tools` 缺失或为空,就为这些工具名补上**占位 spec**(`input_schema: {type: object}`);
3. 如果 `tools` 已存在但缺了某些名字,只补缺口。

裁判模型在答一道文本判断题,根本不会真去调这些工具,所以占位 spec 只要让网关的"每个被引用工具都有 spec"校验通过即可,无需匹配工具的真实参数结构。

**Fail-safe 设计**:没有 `tool_use` 时完全 no-op;所有工具已有 spec 时原样转发;只追加、绝不覆盖已有 spec。正常流量零影响。

## 前置条件

- macOS
- 已全局安装 [`claude-code-cache-fix`](https://github.com/cnighswonger/claude-code-cache-fix)(`npm i -g claude-code-cache-fix`)
- 使用 cc-switch 或类似方式,把 `~/.claude/settings.json` 的 `ANTHROPIC_BASE_URL` 指向一个本地端口(默认探测 `:15721`)

## 安装

```bash
bash install.sh
```

脚本会:把插件放进 cache-fix 扩展目录并注册 → 装一个 launchd 常驻代理(默认 `:15723`,上游自动指向你当前的 cc-switch 端口)→ 做健康检查与端到端验证 → 把 `settings.json` 的 `ANTHROPIC_BASE_URL` 指向该代理(**自动备份原文件**)。

链路变为:

```
/goal 裁判请求 → :15723(本补丁,补 tools)→ :15721(cc-switch)→ 中转站  ✅
```

> 当前正在跑的会话不受影响;**新开**的 Claude Code 会话起生效。

自定义端口:

```bash
PROXY_PORT=15999 UPSTREAM_PORT=15721 bash install.sh
```

## 卸载

```bash
bash uninstall.sh
```

停服务、删插件、把 `settings.json` 改回原上游端口(同样带备份)。

## 测试

```bash
node test.mjs
```

零依赖纯 Node 单元测试,覆盖补全/no-op/部分补全/不改原数组等用例。

## 手动验证补丁是否生效

```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:15723/v1/messages \
  -H "content-type: application/json" -H "anthropic-version: 2023-06-01" \
  --data '{"model":"claude-haiku-4-5","max_tokens":16,"messages":[
    {"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]},
    {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"x"}]},
    {"role":"user","content":[{"type":"text","text":"OK?"}]}]}'
# 直发 :15721 是 400;经 :15723 应为 200
```

## 许可

MIT。本插件可独立使用,也可作为 PR 贡献回 `claude-code-cache-fix`(其本身亦为 MIT)。
