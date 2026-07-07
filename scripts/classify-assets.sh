#!/usr/bin/env bash
# audit-loop 资产分类脚本
# 用途: Step 0 扫描文件路径，按 risk-scoring.md 规则分类 PII/PCI/PHI/AUTH/ADMIN/API/CONFIG/BIZ/DOC
# 用法: bash scripts/classify-assets.sh <project_root> <instance_dir>
# 输出: <instance_dir>/asset-inventory.json
# 退出码: 0 = 成功, 1 = 参数错误, 2 = 脚本错误

set -euo pipefail

PROJECT_ROOT="${1:-}"
INSTANCE_DIR="${2:-}"

if [ -z "$PROJECT_ROOT" ] || [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/classify-assets.sh <project_root> <instance_dir>"
    printf '%s\n' "示例: bash scripts/classify-assets.sh /path/to/project .claude/cache/audit-context/audit-xxx"
    exit 1
fi

if [ ! -d "$PROJECT_ROOT" ]; then
    printf '%s\n' "错误: 项目目录不存在: $PROJECT_ROOT"
    exit 2
fi

mkdir -p "$INSTANCE_DIR"

echo "=== audit-loop 资产分类 ==="
echo "项目根目录: $PROJECT_ROOT"
echo ""

python -c "
import json, os, sys, re
from datetime import datetime, timezone

project_root = sys.argv[1]
instance_dir = sys.argv[2]

# 资产分类规则（来自 risk-scoring.md 3.1 节）
CLASSIFICATION_RULES = [
    # (分类, 关键词列表, criticality, 审计强度)
    ('PCI', ['payment', 'billing', 'charge', 'card', 'transaction', 'pos'], 10, 'L3'),
    ('PII', ['user', 'profile', 'email', 'phone', 'ssn', 'passport', 'dob', 'address', 'citizen'], 10, 'L3'),
    ('PHI', ['patient', 'health', 'medical', 'diagnosis', 'prescription', 'clinical', 'hipaa'], 10, 'L3'),
    ('AUTH', ['auth', 'login', 'session', 'token', 'jwt', 'oauth', 'sso', 'password', 'credential'], 7, 'L2'),
    ('ADMIN', ['admin', 'root', 'super', 'sudo', 'dashboard', 'manage'], 7, 'L2'),
    ('API', ['api', 'graphql', 'rest', 'grpc', 'webhook', 'endpoint'], 5, 'L2'),
    ('CONFIG', ['config', 'settings', 'secret', 'env', 'dockerfile', 'terraform', 'k8s', 'deploy'], 5, 'L1'),
    ('BIZ', ['service', 'handler', 'controller', 'model', 'repository', 'domain'], 3, 'L1'),
    ('DOC', ['readme', 'doc', 'wiki', 'guide', 'changelog', 'spec'], 1, 'L1'),
]

def classify_file(filepath):
    \"\"\"对单个文件路径执行分类匹配（首个匹配生效）\"\"\"
    lower_path = filepath.lower()
    for classification, keywords, criticality, intensity in CLASSIFICATION_RULES:
        for kw in keywords:
            if kw in lower_path:
                return classification, criticality, intensity
    # 默认分类
    return 'GENERIC', 1, 'L1'

# 收集所有文件（排除常见忽略目录）
IGNORE_DIRS = {'.git', 'node_modules', '__pycache__', '.cache', 'dist', 'build', '.superpowers', '.claude'}
IGNORE_EXTS = {'.pyc', '.class', '.o', '.so', '.dll', '.exe'}

assets = []
summary = {}
high_risk_count = 0

for root, dirs, files in os.walk(project_root):
    # 原地修改 dirs 以跳过忽略目录
    dirs[:] = [d for d in dirs if d not in IGNORE_DIRS]
    for fname in files:
        ext = os.path.splitext(fname)[1].lower()
        if ext in IGNORE_EXTS:
            continue
        full_path = os.path.join(root, fname)
        rel_path = os.path.relpath(full_path, project_root)
        # 转为正斜杠统一格式
        rel_path_uniform = rel_path.replace(os.sep, '/')

        classification, criticality, intensity = classify_file(rel_path_uniform)
        assets.append({
            'path': rel_path_uniform,
            'classification': classification,
            'criticality': criticality,
            'audit_intensity': intensity
        })
        summary[classification] = summary.get(classification, 0) + 1
        if criticality >= 7:
            high_risk_count += 1

# 生成 asset-inventory.json
inventory = {
    'instance_id': os.path.basename(instance_dir),
    'classified_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'project_root': project_root,
    'total_files': len(assets),
    'high_risk_files': high_risk_count,
    'assets': assets,
    'summary': summary,
    'audit_intensity_recommendation': 'L3' if high_risk_count > 0 else 'L2'
}

output_path = os.path.join(instance_dir, 'asset-inventory.json')
with open(output_path, 'w', encoding='utf-8') as f:
    json.dump(inventory, f, ensure_ascii=False, indent=2)

# 打印摘要
print(f'分类完成: {len(assets)} 个文件')
print(f'分类分布:')
for cls in ['PCI', 'PII', 'PHI', 'AUTH', 'ADMIN', 'API', 'CONFIG', 'BIZ', 'DOC', 'GENERIC']:
    if cls in summary:
        print(f'  {cls}: {summary[cls]}')
print(f'')
print(f'高风险文件 (criticality ≥ 7): {high_risk_count}')
if high_risk_count > 0:
    print(f'⚠️  建议提升审计强度为 L3')
print(f'输出: {output_path}')
" "$PROJECT_ROOT" "$INSTANCE_DIR"

exit $?
