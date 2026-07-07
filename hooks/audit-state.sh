#!/usr/bin/env bash
# audit-loop Hook 共享状态读取器
# 所有 Hook 脚本 source 此文件获取当前审计状态
# 状态文件由编排者通过 SKILL.md Step 0 写入

# 查找最近的审计状态文件
# 优先级: .audit-state.json (插件根) > 最新 instance_dir 下的 state
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_FILE="${PLUGIN_ROOT}/.audit-state.json"

get_audit_state() {
    if [ -f "$STATE_FILE" ]; then
        python - "$STATE_FILE" << 'PYEOF' 2>/dev/null
import json, sys, os
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        state = json.load(f)
    print(f"INSTANCE_DIR={state.get('instance_dir', '')}")
    print(f"PHASE={state.get('phase', '')}")
    print(f"ROUND={state.get('round', '')}")
    print(f"ACTIVE={state.get('active', False)}")
except Exception:
    print("ACTIVE=False")
PYEOF
    else
        echo "ACTIVE=False"
    fi
}

# 检查是否在审计上下文中
is_audit_active() {
    if [ ! -f "$STATE_FILE" ]; then
        return 1
    fi
    # 检查状态文件是否过期（超过 2 小时视为过期）
    local mtime
    mtime=$(stat -c %Y "$STATE_FILE" 2>/dev/null || stat -f %m "$STATE_FILE" 2>/dev/null || echo 0)
    local now
    now=$(date +%s 2>/dev/null || echo 0)
    if [ "$now" -gt 0 ] && [ "$mtime" -gt 0 ] && [ $((now - mtime)) -gt 7200 ]; then
        return 1
    fi
    return 0
}

# 检查 stdin 是否来自 audit-loop Agent（通过检查 Agent prompt 中的特征标记）
# 用于 PreToolUse 和 SubagentStop Hook 判断是否需要介入
is_audit_loop_agent() {
    local stdin_data
    stdin_data=$(cat)

    # 检查是否包含 audit-loop 特征标记
    echo "$stdin_data" | grep -qE '(audit-loop|INSTANCE_DIR|instance_dir.*audit-|lens-security|lens-architecture|lens-quality|lens-performance|merge-reviewer|perspective-recommender)' 2>/dev/null
    return $?
}
