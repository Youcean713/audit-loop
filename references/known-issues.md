# 已知平台限制与 Bug

> 本文件记录 audit-loop 插件开发中交叉验证的 Claude Code 平台限制和未修复 bug。
> Agent frontmatter 注释引用此文件。最后更新：2026-07-07（经本地知识库 + 联网 + claude-code-guide 三方交叉验证）。

---

## 1. 插件 Agent frontmatter 字段限制

**限制**：插件 Agent（`agents/*.md`）不支持 `hooks`、`mcpServers`、`permissionMode` 三个 frontmatter 字段，加载时被忽略。

**依据**：[Sub-agents docs](https://code.claude.com/docs/en/sub-agents) "plugin subagents do not support the `hooks`, `mcpServers`, or `permissionMode` frontmatter fields"。

**缓解**：
- `tools` / `disallowedTools` 字段**对插件 Agent 生效**（不在忽略列表中）
- 需要 hooks/mcpServers/permissionMode 时，将 Agent 文件复制到 `.claude/agents/`
- 插件级 Hook（`hooks/hooks.json`）作为替代，作用于所有 audit-loop Agent

---

## 2. Agent `tools` 字段的 3 个未修复 bug

**限制**：`tools` 字段设计上运行时强制，但存在 3 个已知 bug 导致可能被绕过：

| Issue | 状态 | 影响 |
|-------|:---:|------|
| [SDK #172](https://github.com/anthropics/claude-agent-sdk-typescript/issues/172) | 未修复 | CLI 未将 Agent `tools` 映射为子进程 `--allowedTools`，子 Agent 仍可调用被禁工具 |
| [claude-code #63762](https://github.com/anthropics/claude-code/issues/63762) | 未修复 | Dynamic workflow 忽略 `tools:`，总授予 Write/Edit |
| [claude-code #31292](https://github.com/anthropics/claude-code/issues/31292) | 设计局限 | `disallowedTools: [Write, Edit]` 可用 `sed -i`/`tee`/`awk` 绕过 |

**缓解**：
- `tools` 字段作为第一层防护（声明设计意图）
- PreToolUse Hook 作为第二层防护（拦截审计范围内的 Write/Edit，后续扩展）
- AP-12 强制 `subagent_type`：不用 subagent_type 时走 general-purpose 继承全部工具，`tools` 完全失效

---

## 3. Stop Hook 插件分发失效（Issue #10412）

**限制**：Stop Hook 的 `exit 2` 通过插件 marketplace 安装时可能失效（仅在 `.claude/hooks/` 本地安装或 `~/.claude/skills/` 自动发现时正常）。

**依据**：[Issue #10412](https://github.com/anthropics/claude-code/issues/10412)。

**缓解**：
- Stop Hook 采用双保险：`{decision:"block",reason:"..."}` JSON 输出（主）+ `exit 2`（兜底）
- 文档建议团队用 `git clone` 到 `~/.claude/skills/audit-loop/` 而非 marketplace 安装
- 等待 #10412 修复后可简化为单一 exit 2

---

## 4. `${CLAUDE_PLUGIN_ROOT}` 在 Bash 工具中不可用（Issue #136）

**限制**：`${CLAUDE_PLUGIN_ROOT}` 在 Hook command 字段中可用，但在 SKILL.md 指示编排者运行的 `bash scripts/xxx.sh` 命令中解析为空字符串（未导出到子进程）。

**依据**：[Issue #136](https://github.com/swt-labs/vibe-better-with-claude-code-vbw/issues/136)、[Issue #49](https://github.com/swt-labs/vibe-better-with-claude-code-vbw/issues/49)。

**缓解**：
- Hook command 中使用 `${CLAUDE_PLUGIN_ROOT}`（可靠）
- SKILL.md 中的脚本调用用相对路径 `bash scripts/xxx.sh`（依赖 cwd）
- 脚本内部定位自身目录用 `dirname "$0"` 推导，不用 `${CLAUDE_PLUGIN_ROOT}`
- SessionStart Hook 中也不可用（[Issue #27145](https://github.com/anthropics/claude-code/issues/27145)），需绝对路径

---

## 5. PreToolUse `updatedInput` 对 Agent 工具无效（Issue #44412）

**限制**：PreToolUse Hook 返回的 `updatedInput`（修改 `subagent_type` 或 `model`）对 Agent 工具无效，只能阻止或放行，不能自动修正参数。

**依据**：[Issue #44412](https://github.com/anthropics/claude-code/issues/44412)。

**缓解**：
- PreToolUse Hook 校验 `tool_input.subagent_type`，不合法则 `exit 2` 阻止
- 编排者必须自己传递正确的 `subagent_type`（AP-12 强制）

---

## 6. PreToolUse `permissionDecision` 争议（Issue #4669 / #59643）

**限制**：PreToolUse 的 `permissionDecision: "deny"` 有效性有争议——#4669 说无效（not planned），#59643 说是配置问题（not a bug）。

**依据**：[Issue #4669](https://github.com/anthropics/claude-code/issues/4669)、[Issue #59643](https://github.com/anthropics/claude-code/issues/59643)。

**缓解**：
- PreToolUse 阻止用 `exit 2`（最可靠）
- Stop Hook 用 `{decision:"block",reason:"..."}`（Stop 不支持 `permissionDecision`，用 `decision` 字段）

---

## 7. Hook 传播到子 Agent

**限制**：插件级 Hook（PreToolUse/SubagentStop）会传播到子 Agent 内部执行，可能导致循环触发。

**缓解**：
- 所有 Hook 脚本开头加递归守卫（临时标记文件 `/tmp/audit-loop-hook-$$`）
- SubagentStop matcher 用 `^audit-loop:` 精确匹配，避免误触发非审计 Agent

---

## 8. 第三方 marketplace 插件源不支持（Issue #41653）

**限制**：Claude Code v2.1.202 拒绝所有第三方 marketplace 插件源（`url`/`github`/`git` 等格式均失败）。

**依据**：[Issue #41653](https://github.com/anthropics/claude-code/issues/41653)。

**缓解**：
- 团队分发用 `git clone` 到 `~/.claude/skills/audit-loop/`（自动发现路径）
- marketplace.json 保留备用，等平台支持后启用

---

## 参考

- 本地知识库：`D:\YWX\Knowledge Base\wiki\concepts\Hooks 生命周期钩子.md`、`Subagents（子代理）.md`
- 架构文档：`D:\YWX\Knowledge Base\raw\repository\Dive-into-Claude-Code\docs\architecture_zh.md`
- 交叉验证记录：`audit-20260707-144448-e2de/issue-log.md`（AP-15/AP-16）
