#!/usr/bin/env bash
# audit-loop 合并审查官前置检查脚本
# 用途: spawn merge-reviewer 前，验证 4 个技术透镜 JSON 齐全
# 用法: bash scripts/check-pre-merge.sh <instance_dir>
# 退出码: 0 = 通过, 1 = 缺失透镜（编排者应拒绝 spawn merge-reviewer）

set -euo pipefail

INSTANCE_DIR="${1:-}"
if [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/check-pre-merge.sh <instance_dir>"
    exit 1
fi
if [ ! -d "$INSTANCE_DIR" ]; then
    printf '%s\n' "错误: 实例目录不存在: $INSTANCE_DIR" >&2
    exit 2
fi

MISSING=0
for lens in security arch quality perf; do
    fpath="$INSTANCE_DIR/lens-$lens.json"
    if [ ! -f "$fpath" ]; then
        printf '%s\n' "❌ 缺失技术透镜: lens-$lens.json"
        MISSING=$((MISSING + 1))
    elif [ ! -s "$fpath" ]; then
        printf '%s\n' "❌ 技术透镜为空: lens-$lens.json"
        MISSING=$((MISSING + 1))
    else
        # 验证 findings 字段
        # S-1 fix: 用环境变量传递路径，避免单引号包裹未转义导致 Python 注入
        if command -v python3 > /dev/null 2>&1; then
            export FPATH="$fpath"
            findings_count=$(python3 << 'PYEOF'
import json, os
try:
    with open(os.environ['FPATH'], 'r', encoding='utf-8') as f:
        d = json.load(f)
    findings = d.get('findings', [])
    print(len(findings))
except Exception as e:
    print('ERROR:' + str(e))
")
            if [ "$findings_count" = "0" ]; then
                printf '%s\n' "⚠️  lens-$lens.json: findings 为空（透镜未产出发现或执行失败）"
            elif [[ "$findings_count" == ERROR* ]]; then
                printf '%s\n' "❌ lens-$lens.json 解析失败: $findings_count"
                MISSING=$((MISSING + 1))
            else
                printf '%s\n' "✅ lens-$lens.json: $findings_count 条 finding"
            fi
        fi
    fi
done

# 检查视角透镜（软性要求，至少 1 个；缺失则降级警告）
PERSPECTIVE_COUNT=$(find "$INSTANCE_DIR" -name 'lens-perspective-*.json' 2>/dev/null | wc -l)
if [ "$PERSPECTIVE_COUNT" -eq 0 ]; then
    printf '%s\n' "⚠️  无视角透镜（将降级为纯技术审计）"
else
    printf '%s\n' "✅ 视角透镜: $PERSPECTIVE_COUNT 个"
fi

if [ "$MISSING" -gt 0 ]; then
    printf '%s\n' "❌ 检查失败: $MISSING 个技术透镜缺失或异常"
    exit 1
fi
printf '%s\n' "✅ merge-reviewer 前置条件通过"
exit 0
