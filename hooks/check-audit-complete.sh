#!/usr/bin/env bash
# audit-loop Stop Hook — 防止审计未完成时退出主会话
# 触发: 主 Agent (编排者) 完成响应后
# 退出码: 0 = 可以停止, 2 = 阻止停止（审计未完成）
#
# 验证逻辑:
#   1. 无活跃审计 → 放行
#   2. 有活跃审计但未完成 → 阻止 Stop，强制编排者继续
#      - 检查 checklist 是否存在
#      - 检查最终报告是否已生成
#      - 检查退出裁决是否已执行

set -euo pipefail

# C-8 fix: source 共享 helper 库（_jf + 递归守卫 + 状态读取），消除 4 Hook 重复（PERF-2/PERF-3 fix）
source "$(dirname "$0")/audit-state.sh" || exit 0
_audit_loop_guard || exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_FILE="${PLUGIN_ROOT}/.audit-state.json"

# ===== 1. 判断是否有活跃审计 =====
if [ ! -f "$STATE_FILE" ]; then
    exit 0  # 无审计状态文件，放行
fi

# 检查状态文件是否在有效期内
MTIME=$(stat -c %Y "$STATE_FILE" 2>/dev/null || stat -f %m "$STATE_FILE" 2>/dev/null || echo 0)
NOW=$(date +%s 2>/dev/null || echo 0)
if [ "$NOW" -gt 0 ] && [ "$MTIME" -gt 0 ] && [ $((NOW - MTIME)) -gt 7200 ]; then
    exit 0  # 超过 2 小时，视为已过期，放行
fi

# ===== 2. 读取审计状态（P1-2: 用 _jf helper 替代 python -c，消除注入风险）=====
ACTIVE=$(_jf "$STATE_FILE" active false)
if [ "$ACTIVE" != "True" ] && [ "$ACTIVE" != "true" ]; then
    exit 0  # 审计已标记为非活跃，放行
fi

INSTANCE_DIR=$(_jf "$STATE_FILE" instance_dir "")
PHASE=$(_jf "$STATE_FILE" phase "")
# P0-3 fix: 读取 pending_user_confirmation（AP-13 区分"等待用户确认"vs"报告未生成"）
PENDING_CONFIRMATION=$(_jf "$STATE_FILE" pending_user_confirmation false)

if [ -z "$INSTANCE_DIR" ] || [ ! -d "$INSTANCE_DIR" ]; then
    exit 0  # 实例目录无效，放行
fi

# ===== 3. 检查审计完成度 =====

# 审计完成的标志（任一满足即可）:
COMPLETE=false

# 标志 1: 最终报告已生成
if [ -f "${INSTANCE_DIR}/audit-final-report.md" ]; then
    COMPLETE=true
fi

# 标志 2: 退出裁决已执行
if [ -f "${INSTANCE_DIR}/exit-verdict.json" ]; then
    VERDICT=$(_jf "${INSTANCE_DIR}/exit-verdict.json" verdict "")
    if [ -n "$VERDICT" ]; then
        COMPLETE=true
    fi
fi

# 标志 3: 用户已选择「停止（仅报告）」— checklist 存在但无 fix_attempted
if [ -f "${INSTANCE_DIR}/checklist-round-1.json" ]; then
    # P1-2: jq 优先判断 has_fix，python sys.argv 回退（消除 shell 插值）
    if command -v jq >/dev/null 2>&1; then
        USER_STOPPED=$(jq -r '
            (.issues // .findings // []) as $issues |
            ([$issues[] | select(.status == "fix_attempted" or .status == "fixed")] | length > 0) as $has_fix |
            if ($has_fix | not) and ($issues | length > 0) then "stopped" else "fixing" end
        ' "${INSTANCE_DIR}/checklist-round-1.json" 2>/dev/null || echo "unknown")
    else
        USER_STOPPED=$(python - "${INSTANCE_DIR}/checklist-round-1.json" << 'PYEOF' 2>/dev/null || echo "unknown"
import json, sys
d = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
issues = d.get('issues', d.get('findings', []))
has_fix = any(i.get('status') in ('fix_attempted', 'fixed') for i in issues)
print('stopped' if not has_fix and len(issues) > 0 else 'fixing')
PYEOF
        )
    fi
    if [ "$USER_STOPPED" = "stopped" ]; then
        COMPLETE=true  # 用户选择停止仅报告，允许退出
    fi
fi

# ===== 4. 决定（P0-3 fix: 双保险 — JSON decision:block + exit 2）=====
if [ "$COMPLETE" = true ]; then
    # 审计已完成，清理状态文件
    rm -f "$STATE_FILE"
    exit 0
fi

# 确定阻止原因（AP-13: 区分"等待用户确认"vs"步骤未完成"，编排者勿将此误判为催促信号）
BLOCK_REASON=""
if [ "$PENDING_CONFIRMATION" = "True" ] || [ "$PENDING_CONFIRMATION" = "true" ]; then
    BLOCK_REASON="⏸️ 等待用户选择「继续修复」/「停止（仅报告）」——此非催促信号，编排者请勿自动推进，必须等用户明确输入。当前阶段: ${PHASE:-未知}"
elif [ ! -f "${INSTANCE_DIR}/checklist-round-1.json" ]; then
    BLOCK_REASON="Round 1 未完成（checklist 不存在）。当前阶段: ${PHASE:-未知}"
elif [ ! -f "${INSTANCE_DIR}/exit-verdict.json" ]; then
    BLOCK_REASON="退出裁决未执行。当前阶段: ${PHASE:-未知}"
elif [ ! -f "${INSTANCE_DIR}/audit-final-report.md" ]; then
    BLOCK_REASON="最终报告未生成。当前阶段: ${PHASE:-未知}"
else
    BLOCK_REASON="审计未完成。当前阶段: ${PHASE:-未知}"
fi

# 主：结构化 JSON 输出（规避 Issue #10412 — 插件安装时 exit 2 可能失效）
# decision:block + reason 会被注入为下一个用户轮次，编排者能清晰看到阻止原因
# M-1 fix: 用 python json.dumps 构造 JSON，替代 sed 转义（原 sed 仅转义 $BLOCK_REASON，$INSTANCE_DIR/$PHASE 未转义可破坏 JSON 结构——注入风险）
python -c "
import json, sys
print(json.dumps({'decision':'block','reason':sys.argv[1],'instance_dir':sys.argv[2],'phase':sys.argv[3]}))
" "$BLOCK_REASON" "$INSTANCE_DIR" "${PHASE:-}"

# 兜底：stderr + exit 2（本地 skills/ 安装场景可靠）
printf '%s\n' "🚨 audit-loop Stop Hook: 审计未完成，阻止会话退出" >&2
printf '%s\n' "$BLOCK_REASON" >&2
printf '%s\n' "实例目录: ${INSTANCE_DIR}" >&2
exit 2
