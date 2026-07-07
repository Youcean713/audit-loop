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

# === 递归守卫（C-1 fix: 环境变量替代文件守卫，消除 CWE-377 可预测路径攻击面）===
# 用法: _audit_loop_guard || exit 0  （在 Hook 开头调用，source 之后）
# 原理: 用进程环境变量标记——bash 子进程继承 env，递归调用时已设置则跳过。
#       消除文件系统攻击面（/tmp 可预测路径、PID 回绕、符号链接攻击）。
_AUDIT_LOOP_GUARD_SET_ENV=""
_audit_loop_guard() {
    if [ "${_AUDIT_LOOP_GUARD_SET:-}" = "1" ]; then
        return 1  # 已在执行，放行（防递归）
    fi
    export _AUDIT_LOOP_GUARD_SET=1
    return 0
}

# === 状态文件路径 ===
_audit_loop_state_file() {
    printf '%s' "$(_audit_loop_plugin_root)/.audit-state.json"
}

# === 检查是否在审计上下文（状态文件存在且未过期 2h）===
# L-9 fix: 状态文件设计说明——编排者在各阶段迁移时写入 phase/round/pending_user_confirmation。
# Hook 消费者: check-audit-complete.sh（读取 phase + pending_user_confirmation 决定 block/静默），
# check-agent-spawn.sh（通过文件存在性推导审计上下文）。其余 Hook 通过 agent 输出路径推导阶段。
# 注意: 编排者每阶段写入是"推送"模式——Hook 不主动轮询，写多读少是设计选择（可靠写入 > Hook 轮询开销）。
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
