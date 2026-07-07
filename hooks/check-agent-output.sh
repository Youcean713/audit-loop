#!/usr/bin/env bash
# audit-loop SubagentStop Hook — 子 Agent 完成后验证输出产品
# 触发: 每次子 Agent 完成时
# 退出码: 0 = 输出有效, 2 = 输出缺失/无效（阻止编排者继续）
#
# P0-1 fix: 改用 stdin 的 agent_type 字段精确匹配（替代 prompt 子串 grep）
#   - 彻底消除 C-1/M-1/M-4 子串误匹配
#   - agent_type 格式: audit-loop:lens-security（带插件前缀）

set -euo pipefail

# P1-3: 递归守卫，防 Hook 在子 Agent 内部循环触发（Dich01 生产案例模式）
_GUARD="/tmp/audit-loop-hook-$$-$(basename "$0")"
[ -f "$_GUARD" ] && exit 0
touch "$_GUARD"
trap 'rm -f "$_GUARD"' EXIT

# P1-2: JSON 字段读取 helper（jq 优先，python sys.argv 回退，无 shell 插值消除注入风险 M-6/S-1）
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

STDIN_DATA=$(cat)
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# ===== 1. 从 stdin 读取 agent_type（官方字段，零误匹配）=====
# 优先 jq，回退 python（P1-2 将统一迁移到 jq）
if command -v jq >/dev/null 2>&1; then
    AGENT_TYPE=$(echo "$STDIN_DATA" | jq -r '.agent_type // ""' 2>/dev/null || echo "")
else
    AGENT_TYPE=$(echo "$STDIN_DATA" | python -c "import json,sys; print(json.load(sys.stdin).get('agent_type',''))" 2>/dev/null || echo "")
fi

# 无 agent_type 或非 audit-loop 前缀 → 放行（非审计场景）
case "$AGENT_TYPE" in
    audit-loop:*) ;;  # 继续校验
    *) exit 0 ;;
esac

# ===== 2. 从状态文件获取 instance_dir（P1-2: 用 _jf helper 替代 python -c）=====
STATE_FILE="${PLUGIN_ROOT}/.audit-state.json"
INSTANCE_DIR=""
if [ -f "$STATE_FILE" ]; then
    INSTANCE_DIR=$(_jf "$STATE_FILE" instance_dir "")
fi

if [ -z "$INSTANCE_DIR" ] || [ ! -d "$INSTANCE_DIR" ]; then
    exit 0  # 无法确定 instance，放行（不阻塞非审计场景）
fi

# ===== 3. JSON 输出校验函数（P3-2: 增加必填字段校验）=====
check_json_output() {
    local fpath="$1"
    local agent_name="$2"
    if [ ! -f "$fpath" ]; then
        printf '%s\n' "🚨 audit-loop SubagentStop Hook: ${agent_name} 输出缺失" >&2
        printf '%s\n' "预期文件: ${fpath}" >&2
        printf '%s\n' "Agent 可能未按输出契约写入文件，请检查 Agent prompt 中的输出路径指令" >&2
        return 2
    fi
    # 验证是否为有效 JSON（P1-2: jq empty 优先，python sys.argv 回退，消除 $fpath 插值注入风险）
    if command -v jq >/dev/null 2>&1; then
        if ! jq empty "$fpath" 2>/dev/null; then
            printf '%s\n' "⚠️ audit-loop SubagentStop Hook: ${agent_name} 输出非有效 JSON" >&2
            printf '%s\n' "文件: ${fpath}" >&2
            return 2
        fi
    else
        if ! python -c "import json,sys; json.load(open(sys.argv[1],'r',encoding='utf-8'))" "$fpath" 2>/dev/null; then
            printf '%s\n' "⚠️ audit-loop SubagentStop Hook: ${agent_name} 输出非有效 JSON" >&2
            printf '%s\n' "文件: ${fpath}" >&2
            return 2
        fi
    fi
    # P3-2: 必填字段校验（按 agent_name 推断，防透镜输出缺字段破坏下游脚本）
    local required_field=""
    case "$agent_name" in
        lens-security|lens-architecture|lens-quality|lens-performance|lens-perspective|perspective-recommender)
            required_field="findings" ;;
        merge-reviewer) required_field="issues" ;;
    esac
    if [ -n "$required_field" ]; then
        if command -v jq >/dev/null 2>&1; then
            local field_type
            field_type=$(jq -r --arg f "$required_field" '.[$f] | type' "$fpath" 2>/dev/null) || field_type=""
            if [ "$field_type" != "array" ]; then
                printf '%s\n' "⚠️ audit-loop SubagentStop Hook: ${agent_name} 缺少必填字段 '${required_field}'（应为数组）" >&2
                printf '%s\n' "文件: ${fpath}" >&2
                return 2
            fi
        else
            if ! python -c "import json,sys; d=json.load(open(sys.argv[1],'r',encoding='utf-8')); assert isinstance(d.get(sys.argv[2]), list)" "$fpath" "$required_field" 2>/dev/null; then
                printf '%s\n' "⚠️ audit-loop SubagentStop Hook: ${agent_name} 缺少必填字段 '${required_field}'（应为数组）" >&2
                printf '%s\n' "文件: ${fpath}" >&2
                return 2
            fi
        fi
    fi
    return 0
}

# ===== 4. 按 agent_type 精确匹配校验输出 =====
case "$AGENT_TYPE" in
    audit-loop:lens-security)
        check_json_output "${INSTANCE_DIR}/lens-security.json" "lens-security"
        ;;
    audit-loop:lens-architecture)
        check_json_output "${INSTANCE_DIR}/lens-arch.json" "lens-architecture"
        ;;
    audit-loop:lens-quality)
        check_json_output "${INSTANCE_DIR}/lens-quality.json" "lens-quality"
        ;;
    audit-loop:lens-performance)
        check_json_output "${INSTANCE_DIR}/lens-perf.json" "lens-performance"
        ;;
    audit-loop:merge-reviewer)
        check_json_output "${INSTANCE_DIR}/checklist-round-1.json" "merge-reviewer"
        ;;
    audit-loop:verifier)
        # verifier 输出 verification-round-{2,3}.json
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
        ;;
    audit-loop:perspective-recommender)
        # perspective-recommender 输出被编排者 inline 解析，不强制写文件
        # 若存在文件则校验，否则放行
        if [ -f "${INSTANCE_DIR}/lens-perspective-recommender.json" ]; then
            check_json_output "${INSTANCE_DIR}/lens-perspective-recommender.json" "perspective-recommender"
        fi
        ;;
    audit-loop:lens-perspective)
        # 视角透镜输出 lens-perspective-{perspective_id}.json
        FOUND_PERSP=false
        for f in "${INSTANCE_DIR}"/lens-perspective-*.json; do
            if [ -f "$f" ]; then
                check_json_output "$f" "lens-perspective ($(basename "$f"))"
                FOUND_PERSP=true
                break
            fi
        done
        if [ "$FOUND_PERSP" = false ]; then
            printf '%s\n' "⚠️ audit-loop SubagentStop Hook: 视角透镜无输出文件" >&2
            printf '%s\n' "预期: ${INSTANCE_DIR}/lens-perspective-*.json" >&2
        fi
        ;;
    audit-loop:code-auditor)
        # code-auditor 独立使用，输出由调用者处理，不强制校验
        ;;
    *)
        # 未知 audit-loop Agent，保守放行
        ;;
esac

exit 0
