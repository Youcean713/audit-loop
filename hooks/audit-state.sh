#!/usr/bin/env bash
# audit-loop Hook 共享 helper 库
# C-8 fix: 原文件声称"所有 Hook source 此文件"但无脚本实际 source（死代码）。
#          现重写为真正的共享库，提供 _jf（JSON 读取）+ 递归守卫 + 状态读取，
#          消除 4 个 Hook 中的 _jf/守卫重复（PERF-2/PERF-3 fix）。
# 用法: 在 Hook 脚本开头:
#   source "$(dirname "$0")/audit-state.sh" || exit 0
#   _audit_loop_guard || exit 0
# 然后即可调用 _jf / is_audit_active 等函数。

# === PLUGIN_ROOT 推导 ===
# Issue #136: CLAUDE_PLUGIN_ROOT 在 Bash 工具不可用，Hook command 中可用
_audit_loop_plugin_root() {
    printf '%s' "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
}

# === _jf: JSON 字段读取（jq 优先，python sys.argv 回退，无 shell 插值消除注入风险 M-6/S-1）===
# 用法: _jf <file> <key> [default]
_jf() {
    local file="$1" key="$2" default="${3:-}"
    if command -v jq >/dev/null 2>&1; then
        local v
        v=$(jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null) || v=""
        if [ -n "$v" ] && [ "$v" != "null" ]; then printf '%s' "$v"; else printf '%s' "$default"; fi
    else
        python -c "import json,sys; d=json.load(open(sys.argv[1],'r',encoding='utf-8')); v=d.get(sys.argv[2],sys.argv[3]); print(v if v is not None else sys.argv[3])" "$file" "$key" "$default" 2>/dev/null || printf '%s' "$default"
    fi
}

# === 递归守卫（Dich01 生产案例模式，防 Hook 在子 Agent 内循环触发）===
# 用法: _audit_loop_guard || exit 0  （在 Hook 开头调用，source 之后）
# 原理: 用 PID+脚本名生成守卫文件，已存在则返回 1（放行防递归），否则创建并 trap 清理
_AUDIT_LOOP_GUARD_FILE=""
_audit_loop_guard() {
    _AUDIT_LOOP_GUARD_FILE="/tmp/audit-loop-hook-$$-$(basename "$0")"
    if [ -f "$_AUDIT_LOOP_GUARD_FILE" ]; then
        return 1  # 已在执行，放行（防递归）
    fi
    touch "$_AUDIT_LOOP_GUARD_FILE"
    trap 'rm -f "$_AUDIT_LOOP_GUARD_FILE"' EXIT
    return 0
}

# === 状态文件路径 ===
_audit_loop_state_file() {
    printf '%s' "$(_audit_loop_plugin_root)/.audit-state.json"
}

# === 检查是否在审计上下文（状态文件存在且未过期 2h）===
is_audit_active() {
    local state_file
    state_file=$(_audit_loop_state_file)
    [ -f "$state_file" ] || return 1
    local mtime now
    mtime=$(stat -c %Y "$state_file" 2>/dev/null || stat -f %m "$state_file" 2>/dev/null || echo 0)
    now=$(date +%s 2>/dev/null || echo 0)
    if [ "$now" -gt 0 ] && [ "$mtime" -gt 0 ] && [ $((now - mtime)) -gt 7200 ]; then
        return 1
    fi
    return 0
}
