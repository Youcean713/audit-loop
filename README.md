# audit-loop — 多模型多维度代码审计循环

> Plugin v2.0.0 | Claude Code 代码审计插件

## 安装

### GitHub / GitLab 用户

```bash
# 1. 添加市场
/plugin marketplace add <你的仓库URL>

# GitHub 用户:
/plugin marketplace add Youcean713/audit-loop

# GitLab 用户:
/plugin marketplace add https://gitlab.com/<用户名>/audit-loop

# 2. 安装插件
/plugin install audit-loop@audit-loop-marketplace
```

### 团队项目自动安装

在项目的 `.claude/settings.json` 中：

```json
{
  "extraKnownMarketplaces": {
    "audit-loop": {
      "source": {
        "source": "git",
        "url": "https://gitlab.com/<用户名>/audit-loop.git"
      }
    }
  },
  "enabledPlugins": {
    "audit-loop@audit-loop": true
  }
}
```

## 使用

```
/audit-loop:audit     → 启动审计（自动询问简单/全面模式）
/audit-loop:full      → 直接启动全面审计（20-25min）
/audit-loop:simple    → 直接启动简单审计（8-15min）
```

## 功能

- **四维度审计**: 安全（OWASP/CVE/CWE）、架构、质量、性能
- **多模型覆盖**: fable/opus/sonnet/haiku — 4 种模型覆盖 4 个透镜
- **双模式**: 简单审计（2 合并透镜）和全面审计（4 独立透镜 + 视角）
- **自动循环**: 发现 → 修复 → 验证 → 收敛自适应迭代
- **三层 Hook 强制执行**: PreToolUse（spawn 前置）+ SubagentStop（输出验证）+ Stop（完整性门控）
- **企业级输出**: 3 份角色报告 + SARIF + 证据链

## 许可

MIT
