#!/usr/bin/env bash
# audit-loop Blast-Radius 计算脚本（收敛自适应策略 Tier 2 用）
# 用途: 计算修复阶段的变更文件 + import 调用链 + 配置文件 → blast-radius 文件清单
# 用法: bash scripts/compute-blast-radius.sh <project_root> <instance_dir> [simple|comprehensive]
# 输出: <instance_dir>/blast-radius.json
# 退出码: 0 = 成功, 1 = 参数错误, 2 = 脚本错误

set -euo pipefail

PROJECT_ROOT="${1:-}"
INSTANCE_DIR="${2:-}"
MODE="${3:-comprehensive}"

if [ -z "$PROJECT_ROOT" ] || [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/compute-blast-radius.sh <project_root> <instance_dir> [simple|comprehensive]"
    exit 1
fi

if [ ! -d "$PROJECT_ROOT" ]; then
    printf '%s\n' "错误: 项目目录不存在: $PROJECT_ROOT"
    exit 2
fi

mkdir -p "$INSTANCE_DIR"

echo "=== audit-loop Blast-Radius 计算 ==="
echo "项目根目录: $PROJECT_ROOT"
echo "模式: $MODE"
echo ""

set +e
python -c "
import json, os, sys, subprocess
from datetime import datetime, timezone, timedelta

project_root = sys.argv[1]
instance_dir = sys.argv[2]
mode = sys.argv[3] if len(sys.argv) > 3 else 'comprehensive'

# === Step 1: 识别变更文件 ===
changed_files = []

# 方法 A: git diff（如果是 git 仓库）
is_git = os.path.isdir(os.path.join(project_root, '.git'))
if is_git:
    try:
        result = subprocess.run(
            ['git', '-C', project_root, 'diff', '--name-only', 'HEAD'],
            capture_output=True, text=True, timeout=10
        )
        for line in result.stdout.strip().split('\n'):
            if line and not line.startswith('.claude/cache/'):
                changed_files.append(line)
    except Exception:
        pass

# 方法 B: 非 git 或 git 失败 → mtime < 24h
if not changed_files:
    cutoff = datetime.now(timezone.utc) - timedelta(hours=24)
    cutoff_ts = cutoff.timestamp()
    IGNORE_DIRS = {'.git', 'node_modules', '__pycache__', '.cache', '.superpowers'}
    for root, dirs, files in os.walk(project_root):
        dirs[:] = [d for d in dirs if d not in IGNORE_DIRS]
        for fname in files:
            fpath = os.path.join(root, fname)
            try:
                mtime = os.path.getmtime(fpath)
                if mtime > cutoff_ts:
                    rel = os.path.relpath(fpath, project_root).replace(os.sep, '/')
                    if not rel.startswith('.claude/cache/'):
                        changed_files.append(rel)
            except OSError:
                pass

# === Step 2: import 调用链（仅 comprehensive 模式） ===
import_callers = []
if mode == 'comprehensive' and changed_files:
    # 收集所有可能含 import 的源文件
    SOURCE_EXTS = {'.py', '.js', '.ts', '.jsx', '.tsx', '.go', '.rs', '.java', '.rb', '.sh', '.md'}
    all_source_files = []
    for root, dirs, files in os.walk(project_root):
        dirs[:] = [d for d in dirs if d not in {'.git', 'node_modules', '__pycache__', '.cache', '.superpowers'}]
        for fname in files:
            ext = os.path.splitext(fname)[1].lower()
            if ext in SOURCE_EXTS:
                rel = os.path.relpath(os.path.join(root, fname), project_root).replace(os.sep, '/')
                all_source_files.append(rel)

    # 对每个变更文件，提取其模块名，grep 其他文件是否 import 它
    for changed in changed_files:
        # 提取模块名（去扩展名，取 basename）
        module_name = os.path.splitext(os.path.basename(changed))[0]
        if module_name in ('index', 'main', '__init__'):
            # 主入口文件——跳过反向追踪（太多调用者）
            continue
        for src in all_source_files:
            if src == changed:
                continue
            try:
                fpath_full = os.path.join(project_root, src)
                # H-3 fix: 文件大小限制——防止大文件 OOM 和注入载荷传播
                try:
                    fsize = os.path.getsize(fpath_full)
                except OSError:
                    continue
                if fsize > 1024 * 1024:  # 1MB 上限
                    continue
                with open(fpath_full, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                # 匹配常见 import 模式
                import_patterns = [
                    f'import {module_name}',
                    f'from {module_name}',
                    f'require(.*{module_name}',
                    f'include.*{module_name}',
                    f'use {module_name}',
                    f'#include.*{module_name}',
                ]
                for pat in import_patterns:
                    if pat in content:
                        if src not in import_callers and src not in changed_files:
                            import_callers.append(src)
                        break
            except OSError:
                pass

# === Step 3: 配置文件（config-aware） ===
config_files = []
CONFIG_PATTERNS = ['*.yaml', '*.yml', '*.json', '*.toml', '*.env', '*.ini', '*.cfg']
CONFIG_FILENAMES = ['Dockerfile', 'docker-compose.yml', '.github']
for root, dirs, files in os.walk(project_root):
    dirs[:] = [d for d in dirs if d not in {'.git', 'node_modules', '__pycache__', '.cache', '.superpowers'}]
    for fname in files:
        fpath = os.path.join(root, fname)
        rel = os.path.relpath(fpath, project_root).replace(os.sep, '/')
        # 扩展名匹配
        for pat in CONFIG_PATTERNS:
            if pat.startswith('*.'):
                if fname.endswith(pat[1:]):
                    if rel not in config_files and rel not in changed_files:
                        config_files.append(rel)
                    break
        # 文件名匹配
        for cn in CONFIG_FILENAMES:
            if cn in rel:
                if rel not in config_files and rel not in changed_files:
                    config_files.append(rel)

# === Step 4: 汇总 ===
# simple 模式: 变更文件 + 同目录配置文件（不扫 import 链）
# comprehensive 模式: 变更文件 + import 链 + 全部配置文件
if mode == 'simple':
    # simple: 只取变更文件同目录的配置文件
    simple_configs = []
    for changed in changed_files:
        changed_dir = os.path.dirname(changed)
        for cfg in config_files:
            if os.path.dirname(cfg) == changed_dir:
                if cfg not in simple_configs:
                    simple_configs.append(cfg)
    scan_files = list(set(changed_files + simple_configs))
    import_callers_filtered = []
else:
    scan_files = list(set(changed_files + import_callers + config_files))
    import_callers_filtered = import_callers

# 去重 + 排序
scan_files = sorted(set(scan_files))

blast_radius = {
    'instance_id': os.path.basename(instance_dir),
    'computed_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'mode': mode,
    'is_git': is_git,
    'change_detection': 'git-diff' if (is_git and changed_files) else 'mtime-24h',
    'changed_files': sorted(set(changed_files)),
    'import_callers': sorted(set(import_callers_filtered)) if mode == 'comprehensive' else [],
    'config_files': sorted(set(config_files)),
    'scan_files': scan_files,
    'summary': {
        'changed_count': len(set(changed_files)),
        'import_caller_count': len(set(import_callers_filtered)) if mode == 'comprehensive' else 0,
        'config_count': len(set(config_files)),
        'total_scan_count': len(scan_files)
    }
}

output_path = os.path.join(instance_dir, 'blast-radius.json')
with open(output_path, 'w', encoding='utf-8') as f:
    json.dump(blast_radius, f, ensure_ascii=False, indent=2)

print(f'变更文件: {blast_radius[\"summary\"][\"changed_count\"]} 个')
if mode == 'comprehensive':
    print(f'import 调用链: {blast_radius[\"summary\"][\"import_caller_count\"]} 个')
print(f'配置文件: {blast_radius[\"summary\"][\"config_count\"]} 个')
print(f'总扫描范围: {blast_radius[\"summary\"][\"total_scan_count\"]} 个文件')
print(f'检测方式: {blast_radius[\"change_detection\"]}')
print(f'输出: {output_path}')
sys.exit(0)
" "$PROJECT_ROOT" "$INSTANCE_DIR" "$MODE"

EXIT_CODE=$?
set -e
exit $EXIT_CODE
