#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# uninstall.sh — 卸载 tools-spec-backfill 补丁,恢复原状
#
# 做了什么:
#   1. 停止并移除 launchd 常驻服务
#   2. 把 ~/.claude/settings.json 的 ANTHROPIC_BASE_URL 改回原上游端口
#   3. 从 extensions.json 移除插件注册
#   4. 删除插件文件
#
# 用法:  bash uninstall.sh
# 环境变量(可选):
#   RESTORE_PORT   恢复后 ANTHROPIC_BASE_URL 指向的端口(默认从 plist 读上游)
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

SETTINGS="$HOME/.claude/settings.json"
PLIST_LABEL="com.kangyu.cachefix-tools-backfill"
PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
PROXY_PORT="${PROXY_PORT:-15723}"

say() { printf "\033[1;36m▶ %s\033[0m\n" "$*"; }
ok()  { printf "\033[1;32m  ✓ %s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m  ! %s\033[0m\n" "$*"; }

# ── 1. 读出原上游端口(切回它)──────────────────────────────────────────────
RESTORE_PORT="${RESTORE_PORT:-}"
if [ -z "$RESTORE_PORT" ] && [ -f "$PLIST" ]; then
  RESTORE_PORT="$(/usr/libexec/PlistBuddy -c \
    'Print :EnvironmentVariables:CACHE_FIX_PROXY_UPSTREAM' "$PLIST" 2>/dev/null \
    | grep -oE ':[0-9]+' | tr -d ':')"
fi
RESTORE_PORT="${RESTORE_PORT:-15721}"

# ── 2. 停止并移除 launchd 服务 ─────────────────────────────────────────────
say "停止并移除 launchd 服务"
if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  ok "已移除 $PLIST"
else
  warn "plist 不存在,跳过"
fi

# ── 3. settings.json 切回原上游 ───────────────────────────────────────────
say "恢复 ~/.claude/settings.json -> :$RESTORE_PORT"
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak-uninstall-$(date +%Y%m%d%H%M%S)"
  node -e '
    const fs=require("fs"); const p=process.argv[1]; const port=process.argv[2];
    const j=JSON.parse(fs.readFileSync(p,"utf8"));
    j.env=j.env||{};
    j.env.ANTHROPIC_BASE_URL="http://127.0.0.1:"+port;
    fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
  ' "$SETTINGS" "$RESTORE_PORT"
  ok "ANTHROPIC_BASE_URL 已改回 http://127.0.0.1:$RESTORE_PORT"
else
  warn "$SETTINGS 不存在,跳过"
fi

# ── 4. 从 extensions.json 移除注册 + 删插件文件 ──────────────────────────────
say "移除插件注册与文件"
NPM_ROOT="$(npm root -g 2>/dev/null)"
EXT_JSON="$NPM_ROOT/claude-code-cache-fix/proxy/extensions.json"
EXT_FILE="$NPM_ROOT/claude-code-cache-fix/proxy/extensions/tools-spec-backfill.mjs"
if [ -f "$EXT_JSON" ]; then
  node -e '
    const fs=require("fs"); const p=process.argv[1];
    const j=JSON.parse(fs.readFileSync(p,"utf8"));
    delete j["tools-spec-backfill"];
    fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
  ' "$EXT_JSON" && ok "已从 extensions.json 移除注册"
fi
[ -f "$EXT_FILE" ] && rm -f "$EXT_FILE" && ok "已删除插件文件"

echo
printf "\033[1;32m✓ 卸载完成。\033[0m 新开的会话将走回 :%s。\n" "$RESTORE_PORT"
warn "提示:若你之前用本补丁代理替换的就是 cc-switch,请确认 :$RESTORE_PORT 仍在运行。"
