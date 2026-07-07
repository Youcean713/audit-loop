#!/usr/bin/env bash
# audit-loop 透镜 Spawn 前置检查脚本（AP-16 fix）
# 用途: spawn 透镜 Agent 前，验证上下文齐全 + 注入上轮未修复 issue 列表
# 用法: bash scripts/check-pre-lens.sh <instance_dir> <round_num>
# 输出: 若有上一轮未修复 issue，输出 prompt 注入文本
# 退出码: 0 = 通过, 1 = 上下文缺失, 2 = 无 Round 1 数据

set -euo pipefail

INSTANCE_DIR="${1:-}"
ROUND_NUM="${2:-1}"

if [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/check-pre-lens.sh <instance_dir> [round_num]"
    exit 1
fi
if [ ! -d "$INSTANCE_DIR" ]; then
    printf '%s\n' "错误: 实例目录不存在: $INSTANCE_DIR" >&2
    exit 2
fi

# 验证必要上下文文件
MISSING=0
if [ ! -f "$INSTANCE_DIR/asset-inventory.json" ]; then
    printf '%s\n' "⚠️  asset-inventory.json 缺失（资产分类上下文）"
    MISSING=$((MISSING + 1))
fi
if [ ! -f "$INSTANCE_DIR/sbom.json" ]; then
    printf '%s\n' "⚠️  sbom.json 缺失（供应链上下文）"
fi

if [ "$MISSING" -gt 0 ]; then
    printf '%s\n' "❌ 上下文缺失，请先运行 classify-assets.sh"
    exit 1
fi

# Round 2+: 注入上一轮未修复 issue 列表
if [ "$ROUND_NUM" -ge 2 ]; then
    PREV_CHECKLIST="$INSTANCE_DIR/checklist-round-1.json"
    if [ ! -f "$PREV_CHECKLIST" ]; then
        printf '%s\n' "❌ 上一轮 checklist 不存在"
        exit 2
    fi

    # 提取未修复 C/H/M issue
    # S-1 fix: 用环境变量传递路径，避免单引号包裹未转义导致 Python 注入
    export PREV_CHECKLIST
    PROMPT_INJECTION=$(python3 << 'PYEOF'
import json, os
prev_path = os.environ['PREV_CHECKLIST']
with open(prev_path, 'r', encoding='utf-8') as f:
    cl = json.load(f)

unfixed = []
for issue in cl.get('issues', cl.get('findings', [])):
    sev = issue.get('severity', '').lower()
    status = issue.get('status', 'open')
    if sev in ('critical', 'high', 'medium') and status not in ('fix_attempted', 'requires_human'):
        unfixed.append({
            'id': issue.get('id', '?'),
            'severity': sev,
            'file': issue.get('file', ''),
            'description': issue.get('description', '')[:100]
        })

if unfixed:
    print(f'## 上一轮未修复 issue（共 {len(unfixed)} 项）')
    print('')
    print('| ID | 严重度 | 文件 | 描述 |')
    print('|----|:-----:|------|------|')
    for i in unfixed:
        print(f'| {i["id"]} | {i["severity"]} | {i["file"]} | {i["description"]} |')
    print('')
    print('**审计要求**: 重新验证这些 issue 是否仍然存在。已修复的在 findings 中标注"上轮问题已自然修复"，仍然存在的继续上报。')
else:
    print('OK: 上一轮无未修复 issue')
PYEOF
)
    if [ "$PROMPT_INJECTION" != "OK: 上一轮无未修复 issue" ]; then
        echo ""
        echo "=== 上一轮未修复 issue 注入文本（复制到透镜 prompt）==="
        echo "$PROMPT_INJECTION"
        echo "=== 注入结束 ==="
    else
        echo "✅ 上一轮无未修复 issue，无需注入"
    fi
fi

echo "✅ 透镜 spawn 前置条件通过（Round $ROUND_NUM）"
exit 0
