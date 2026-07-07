#!/usr/bin/env bash
# audit-loop SubagentStop Hook — 子 Agent 完成后验证输出产品
# 触发: 每次子 Agent 完成时
# 退出码: 0 = 输出有效, 2 = 输出缺失/无效（阻止编排者继续）
#
# 验证逻辑:
#   1. 非 audit-loop Agent → 放行
#   2. 识别 Agent 类型（从 stdin 上下文）
#   3. 检查对应输出文件是否存在且为有效 JSON
#   4. 输出缺失 → exit 2 阻止继续

set -euo pipefail

STDIN_DATA=$(cat)
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# ===== 1. 判断是否 audit-loop =====
if ! echo "$STDIN_DATA" | grep -qE '(audit-loop|lens-security|lens-architecture|lens-quality|lens-performance|merge-reviewer|verifier|perspective-recommender)' 2>/dev/null; then
    exit 0  # 非 audit-loop Agent，放行
fi

# ===== 2. 从状态文件获取 instance_dir =====
STATE_FILE="${PLUGIN_ROOT}/.audit-state.json"
INSTANCE_DIR=""
if [ -f "$STATE_FILE" ]; then
    INSTANCE_DIR=$(python -c "import json; d=json.load(open('$STATE_FILE','r',encoding='utf-8')); print(d.get('instance_dir',''))" 2>/dev/null || echo "")
fi

if [ -z "$INSTANCE_DIR" ] || [ ! -d "$INSTANCE_DIR" ]; then
    exit 0  # 无法确定 instance，放行（不阻塞非审计场景）
fi

# ===== 3. 按 Agent 类型验证输出 =====
STDIN_LOWER=$(echo "$STDIN_DATA" | tr '[:upper:]' '[:lower:]')

check_json_output() {
    local fpath="$1"
    local agent_name="$2"
    if [ ! -f "$fpath" ]; then
        printf '%s\n' "🚨 audit-loop SubagentStop Hook: ${agent_name} 输出缺失" >&2
        printf '%s\n' "预期文件: ${fpath}" >&2
        printf '%s\n' "Agent 可能未按输出契约写入文件，请检查 Agent prompt 中的输出路径指令" >&2
        return 2
    fi
    # 验证是否为有效 JSON
    if ! python -c "import json; json.load(open('$fpath','r',encoding='utf-8'))" 2>/dev/null; then
        printf '%s\n' "⚠️ audit-loop SubagentStop Hook: ${agent_name} 输出非有效 JSON" >&2
        printf '%s\n' "文件: ${fpath}" >&2
        printf '%s\n' "编排者应检查 Agent 输出并重试" >&2
        return 2
    fi
    return 0
}

# 安全透镜
if echo "$STDIN_LOWER" | grep -q 'lens-security'; then
    check_json_output "${INSTANCE_DIR}/lens-security.json" "lens-security"
fi

# 架构透镜
if echo "$STDIN_LOWER" | grep -q 'lens-architecture'; then
    check_json_output "${INSTANCE_DIR}/lens-architecture.json" "lens-architecture"
fi

# 质量透镜
if echo "$STDIN_LOWER" | grep -q 'lens-quality'; then
    check_json_output "${INSTANCE_DIR}/lens-quality.json" "lens-quality"
fi

# 性能透镜
if echo "$STDIN_LOWER" | grep -q 'lens-performance'; then
    check_json_output "${INSTANCE_DIR}/lens-performance.json" "lens-performance"
fi

# 视角透镜
if echo "$STDIN_LOWER" | grep -qE '(lens-perspective|视角透镜)'; then
    # 视角透镜输出文件名包含视角 ID
    for f in "${INSTANCE_DIR}"/lens-perspective-*.json; do
        if [ -f "$f" ]; then
            check_json_output "$f" "lens-perspective ($(basename "$f"))"
            break
        fi
    done
    # 如果没有任何 perspective 输出且 stdin 明确是 perspective agent
    if echo "$STDIN_LOWER" | grep -q 'perspective_id'; then
        printf '%s\n' "⚠️ audit-loop SubagentStop Hook: 视角透镜无输出文件" >&2
        printf '%s\n' "预期: ${INSTANCE_DIR}/lens-perspective-*.json" >&2
    fi
fi

# 合并审查官
if echo "$STDIN_LOWER" | grep -q 'merge-reviewer'; then
    check_json_output "${INSTANCE_DIR}/checklist-round-1.json" "merge-reviewer"
fi

# 验证 Agent
if echo "$STDIN_LOWER" | grep -qE '(verifier|验证 Agent)'; then
    FOUND=false
    for vf in verification-round-3.json verification-round-2.json; do
        if [ -f "${INSTANCE_DIR}/${vf}" ]; then
            check_json_output "${INSTANCE_DIR}/${vf}" "verifier (${vf})"
            FOUND=true
            break
        fi
    done
    if [ "$FOUND" = false ]; then
        printf '%s\n' "⚠️ audit-loop SubagentStop Hook: verifier 无输出文件" >&2
        printf '%s\n' "预期: ${INSTANCE_DIR}/verification-round-{2,3}.json" >&2
    fi
fi

# 视角推荐 Agent
if echo "$STDIN_LOWER" | grep -q 'perspective-recommender'; then
    # perspective-recommender 输出被编排者解析，不写入独立文件
    # 仅检查是否有 perspective JSON 输出
    if [ -f "${INSTANCE_DIR}/lens-perspective-recommender.json" ]; then
        check_json_output "${INSTANCE_DIR}/lens-perspective-recommender.json" "perspective-recommender"
    fi
fi

exit 0
