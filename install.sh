#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# install.sh — 一键安装 tools-spec-backfill 补丁
#
# 解决的问题:用 cc-switch + 国内中转站跑 Claude Code 时,/goal 的裁判 AI
# 请求会被中转站以 400 拒绝:
#   "历史消息含 tool_use 或 tool_result,但顶层 tools 字段为空…"
# 本补丁在请求转发前自动补上缺失的工具 spec,使该请求被接受。
#
# 做了什么(全部可回滚,见 uninstall.sh):
#   1. 把 tools-spec-backfill.mjs 放进 claude-code-cache-fix 的扩展目录
#   2. 在该包的 extensions.json 注册插件(order 450)
#   3. 装一个 launchd 常驻代理(默认 :15723),上游指向你当前的 cc-switch 端口
#   4. 把 ~/.claude/settings.json 的 ANTHROPIC_BASE_URL 指向该代理(带备份)
#
# 用法:  bash install.sh
# 环境变量(可选):
#   PROXY_PORT       本补丁代理监听端口(默认 15723)
#   UPSTREAM_PORT    cc-switch 端口(默认自动探测 settings.json 里的当前值)
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SRC="$SCRIPT_DIR/tools-spec-backfill.mjs"
SETTINGS="$HOME/.claude/settings.json"
PLIST_LABEL="com.kangyu.cachefix-tools-backfill"
PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
PROXY_PORT="${PROXY_PORT:-15723}"

say() { printf "\033[1;36m▶ %s\033[0m\n" "$*"; }
ok()  { printf "\033[1;32m  ✓ %s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m  ! %s\033[0m\n" "$*"; }
die() { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

# ── 0. 前置检查 ──────────────────────────────────────────────────────────
command -v node >/dev/null || die "未找到 node,请先安装 Node.js"
command -v npm  >/dev/null || die "未找到 npm"
NODE_BIN="$(command -v node)"
[ -f "$PLUGIN_SRC" ] || die "找不到补丁源文件: $PLUGIN_SRC"

# ── 1. 定位 cache-fix 包 ───────────────────────────────────────────────────
say "定位 claude-code-cache-fix 包"
NPM_ROOT="$(npm root -g 2>/dev/null)"
PKG_DIR="$NPM_ROOT/claude-code-cache-fix"
EXT_DIR="$PKG_DIR/proxy/extensions"
EXT_JSON="$PKG_DIR/proxy/extensions.json"
SERVER_MJS="$PKG_DIR/proxy/server.mjs"
[ -d "$EXT_DIR" ]    || die "未找到扩展目录: $EXT_DIR (是否已全局安装 claude-code-cache-fix?)"
[ -f "$SERVER_MJS" ] || die "未找到代理 server.mjs: $SERVER_MJS"
ok "包路径: $PKG_DIR"

# ── 2. 安装插件文件 ────────────────────────────────────────────────────────
say "安装插件到扩展目录"
cp "$PLUGIN_SRC" "$EXT_DIR/tools-spec-backfill.mjs"
ok "已复制 -> $EXT_DIR/tools-spec-backfill.mjs"

# ── 3. 注册到 extensions.json ─────────────────────────────────────────────
say "注册插件到 extensions.json"
if [ -f "$EXT_JSON" ]; then
  cp "$EXT_JSON" "$EXT_JSON.bak-toolsfix"
  node -e '
    const fs=require("fs"); const p=process.argv[1];
    const j=JSON.parse(fs.readFileSync(p,"utf8"));
    j["tools-spec-backfill"]={enabled:true,order:450};
    fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
  ' "$EXT_JSON"
  ok "已注册 (order 450),原文件备份为 extensions.json.bak-toolsfix"
else
  warn "extensions.json 不存在;插件默认 enabled,通常仍会被加载"
fi

# ── 4. 探测 cc-switch(上游)端口 ──────────────────────────────────────────
say "探测上游 (cc-switch) 端口"
if [ -n "${UPSTREAM_PORT:-}" ]; then
  :
elif [ -f "$SETTINGS" ]; then
  UPSTREAM_PORT="$(node -e '
    try{const j=require(process.argv[1]); const u=j?.env?.ANTHROPIC_BASE_URL||"";
    const m=u.match(/:(\d+)/); process.stdout.write(m?m[1]:"");}catch(e){}
  ' "$SETTINGS")"
fi
UPSTREAM_PORT="${UPSTREAM_PORT:-15721}"
# 若 settings 里已经是本补丁端口(重装场景),别把上游指向自己
if [ "$UPSTREAM_PORT" = "$PROXY_PORT" ]; then
  warn "settings 当前端口 = 补丁端口 ($PROXY_PORT),说明可能已安装过"
  warn "请用环境变量 UPSTREAM_PORT 显式指定真正的 cc-switch 端口后重跑"
  die  "中止以避免把代理上游指向自己"
fi
ok "上游 = http://127.0.0.1:$UPSTREAM_PORT  (本补丁代理 = :$PROXY_PORT)"

# ── 5. 安装 launchd 常驻服务 ───────────────────────────────────────────────
say "安装 launchd 常驻服务"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NODE_BIN</string>
        <string>$SERVER_MJS</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CACHE_FIX_PROXY_PORT</key>
        <string>$PROXY_PORT</string>
        <key>CACHE_FIX_PROXY_BIND</key>
        <string>127.0.0.1</string>
        <key>CACHE_FIX_PROXY_UPSTREAM</key>
        <string>http://127.0.0.1:$UPSTREAM_PORT</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/cachefix-tools-backfill.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/cachefix-tools-backfill.log</string>
</dict>
</plist>
PLISTEOF
plutil -lint "$PLIST" >/dev/null || die "生成的 plist 语法错误"
launchctl unload "$PLIST" 2>/dev/null || true
sleep 0.3
launchctl load "$PLIST"
sleep 1.8
if launchctl list | grep -q "$PLIST_LABEL"; then
  ok "服务已加载 ($PLIST_LABEL)"
else
  die "服务未能加载,检查 /tmp/cachefix-tools-backfill.log"
fi

# ── 6. 健康检查 + 端到端验证 ───────────────────────────────────────────────
say "健康检查与端到端验证"
HEALTH="$(curl -sS -m 3 "http://127.0.0.1:$PROXY_PORT/health" 2>&1 || true)"
echo "    /health -> $HEALTH"
echo "$HEALTH" | grep -q '"status":"ok"' || die "代理健康检查失败"

REPRO='{"model":"claude-haiku-4-5","max_tokens":32,"messages":[
  {"role":"user","content":[{"type":"text","text":"run ls"}]},
  {"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"ls"}}]},
  {"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_1","content":"file.txt"}]},
  {"role":"user","content":[{"type":"text","text":"Reply with the single word OK."}]}]}'
CODE="$(curl -sS -m 30 -o /tmp/toolsfix-verify.txt -w "%{http_code}" \
  "http://127.0.0.1:$PROXY_PORT/v1/messages" \
  -H "content-type: application/json" -H "anthropic-version: 2023-06-01" \
  --data "$REPRO" 2>/dev/null || echo "000")"
if [ "$CODE" = "200" ]; then
  ok "端到端验证通过:评估器型请求返回 200(补丁生效)"
else
  warn "端到端验证返回 HTTP $CODE(若上游需鉴权,正式会话仍会注入 token;只要不再是那句中文 400 即可)"
  head -c 300 /tmp/toolsfix-verify.txt 2>/dev/null; echo
fi
rm -f /tmp/toolsfix-verify.txt

# ── 7. 切换 settings.json 的 ANTHROPIC_BASE_URL ──────────────────────────────
say "切换 ~/.claude/settings.json -> 本补丁代理"
[ -f "$SETTINGS" ] || die "未找到 $SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-before-toolsfix-$(date +%Y%m%d%H%M%S)"
node -e '
  const fs=require("fs"); const p=process.argv[1]; const port=process.argv[2];
  const j=JSON.parse(fs.readFileSync(p,"utf8"));
  j.env=j.env||{};
  j.env.ANTHROPIC_BASE_URL="http://127.0.0.1:"+port;
  fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
' "$SETTINGS" "$PROXY_PORT"
ok "ANTHROPIC_BASE_URL 已指向 http://127.0.0.1:$PROXY_PORT(原文件已备份)"

echo
printf "\033[1;32m🎉 安装完成。\033[0m\n"
echo "  · 新开的 Claude Code 会话起就会走补丁代理(当前会话不受影响)。"
echo "  · 日志: /tmp/cachefix-tools-backfill.log"
echo "  · 卸载: bash \"$SCRIPT_DIR/uninstall.sh\""
