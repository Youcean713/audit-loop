#!/usr/bin/env bash
# audit-loop 供应链检测脚本
# 用途: Step 0 检测依赖清单文件 → 生成简易 SBOM (包名+版本+许可证)
# 用法: bash scripts/detect-supply-chain.sh <project_root> <instance_dir>
# 退出码: 0 = 成功, 1 = 参数错误, 2 = 脚本错误

set -euo pipefail

PROJECT_ROOT="${1:-}"
INSTANCE_DIR="${2:-}"

if [ -z "$PROJECT_ROOT" ] || [ -z "$INSTANCE_DIR" ]; then
    printf '%s\n' "用法: bash scripts/detect-supply-chain.sh <project_root> <instance_dir>"
    exit 1
fi

if [ ! -d "$PROJECT_ROOT" ]; then
    printf '%s\n' "错误: 项目目录不存在: $PROJECT_ROOT"
    exit 2
fi

mkdir -p "$INSTANCE_DIR"

echo "=== audit-loop 供应链检测 ==="
echo "项目根目录: $PROJECT_ROOT"
echo ""

set +e
python -c "
import json, os, sys, re
from datetime import datetime, timezone

project_root = sys.argv[1]
instance_dir = sys.argv[2]

sbom = {
    'instance_id': os.path.basename(instance_dir),
    'detected_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'project_root': project_root,
    'ecosystems': [],
    'packages': [],
    'total_packages': 0,
    'cve_query_integration_points': []
}

def parse_package_json(path):
    packages = []
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    for section in ['dependencies', 'devDependencies', 'peerDependencies']:
        deps = data.get(section, {})
        for name, version in deps.items():
            # version 可能是 ^1.0.0 或 git+https://...
            clean_ver = re.sub(r'[\^~>=<]', '', str(version)).split(' ')[0]
            packages.append({
                'name': name,
                'version': clean_ver,
                'license': 'unknown',
                'ecosystem': 'npm',
                'source': 'package.json'
            })
    return packages

def parse_requirements_txt(path):
    packages = []
    with open(path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or line.startswith('-'):
                continue
            # 匹配 name==version 或 name>=version
            m = re.match(r'^([a-zA-Z0-9_\-\.\[\]]+)\s*[=<>!~]+\s*([0-9a-zA-Z\.\-]+)', line)
            if m:
                packages.append({
                    'name': m.group(1),
                    'version': m.group(2),
                    'license': 'unknown',
                    'ecosystem': 'pypi',
                    'source': 'requirements.txt'
                })
            else:
                packages.append({
                    'name': line,
                    'version': 'unknown',
                    'license': 'unknown',
                    'ecosystem': 'pypi',
                    'source': 'requirements.txt'
                })
    return packages

def parse_go_mod(path):
    packages = []
    in_require = False
    with open(path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line.startswith('require ('):
                in_require = True
                continue
            if in_require:
                if line == ')':
                    in_require = False
                    continue
                parts = line.split()
                if len(parts) >= 2:
                    packages.append({
                        'name': parts[0],
                        'version': parts[1].lstrip('v'),
                        'license': 'unknown',
                        'ecosystem': 'go',
                        'source': 'go.mod'
                    })
            elif line.startswith('require '):
                parts = line.split()
                if len(parts) >= 3:
                    packages.append({
                        'name': parts[1],
                        'version': parts[2].lstrip('v'),
                        'license': 'unknown',
                        'ecosystem': 'go',
                        'source': 'go.mod'
                    })
    return packages

def parse_cargo_toml(path):
    packages = []
    in_deps = False
    with open(path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line in ('[dependencies]', '[dev-dependencies]'):
                in_deps = True
                continue
            if line.startswith('['):
                in_deps = False
                continue
            if in_deps and '=' in line:
                parts = line.split('=', 1)
                name = parts[0].strip()
                version_part = parts[1].strip()
                # 提取版本号
                m = re.search(r'\"([0-9a-zA-Z\.\-]+)\"', version_part)
                version = m.group(1) if m else 'unknown'
                packages.append({
                    'name': name,
                    'version': version,
                    'license': 'unknown',
                    'ecosystem': 'cargo',
                    'source': 'Cargo.toml'
                })
    return packages

# 检测各生态依赖清单
ecosystems_found = []

pkg_json = os.path.join(project_root, 'package.json')
if os.path.exists(pkg_json):
    ecosystems_found.append('npm')
    pkgs = parse_package_json(pkg_json)
    sbom['packages'].extend(pkgs)
    sbom['cve_query_integration_points'].append({
        'ecosystem': 'npm',
        'query': 'https://registry.npmjs.org/-/v1/security/advisories',
        'package_count': len(pkgs)
    })

req_txt = os.path.join(project_root, 'requirements.txt')
if os.path.exists(req_txt):
    ecosystems_found.append('pypi')
    pkgs = parse_requirements_txt(req_txt)
    sbom['packages'].extend(pkgs)
    sbom['cve_query_integration_points'].append({
        'ecosystem': 'pypi',
        'query': 'https://pypi.org/pypi/{name}/json',
        'package_count': len(pkgs)
    })

go_mod = os.path.join(project_root, 'go.mod')
if os.path.exists(go_mod):
    ecosystems_found.append('go')
    pkgs = parse_go_mod(go_mod)
    sbom['packages'].extend(pkgs)
    sbom['cve_query_integration_points'].append({
        'ecosystem': 'go',
        'query': 'https://vuln.go.dev/ID/{vulnID}',
        'package_count': len(pkgs)
    })

cargo_toml = os.path.join(project_root, 'Cargo.toml')
if os.path.exists(cargo_toml):
    ecosystems_found.append('cargo')
    pkgs = parse_cargo_toml(cargo_toml)
    sbom['packages'].extend(pkgs)
    sbom['cve_query_integration_points'].append({
        'ecosystem': 'cargo',
        'query': 'https://crates.io/api/v1/crates/{name}',
        'package_count': len(pkgs)
    })

sbom['ecosystems'] = ecosystems_found
sbom['total_packages'] = len(sbom['packages'])

output_path = os.path.join(instance_dir, 'sbom.json')
with open(output_path, 'w', encoding='utf-8') as f:
    json.dump(sbom, f, ensure_ascii=False, indent=2)

if ecosystems_found:
    print(f'检测到 {len(ecosystems_found)} 个生态: {\", \".join(ecosystems_found)}')
    print(f'总依赖包数: {sbom[\"total_packages\"]}')
    for eco in ecosystems_found:
        count = sum(1 for p in sbom['packages'] if p['ecosystem'] == eco)
        print(f'  {eco}: {count} 个包')
    print(f'CVE 查询集成点: {len(sbom[\"cve_query_integration_points\"])} 个')
else:
    print('未检测到依赖清单文件（package.json/requirements.txt/go.mod/Cargo.toml）')
    print('跳过供应链审计范围')
print(f'输出: {output_path}')
sys.exit(0)
" "$PROJECT_ROOT" "$INSTANCE_DIR"

EXIT_CODE=$?
set -e
exit $EXIT_CODE
