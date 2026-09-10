# Claude Code Quickstart (CCQ)

Windows 平台的 Claude Code 开发环境自动化安装器。

> 目标：把「装环境」变成「跑脚本」——从 PowerShell 5.1 到 PowerShell 7、从基础依赖到 MCP/工作流，一次完成。

---

## 目录

- [为什么用 CCQ](#为什么用-ccq)
- [核心特性](#核心特性)
- [系统要求](#系统要求)
- [快速开始](#快速开始)
  - [方式一：云端直接执行](#方式一云端直接执行推荐)
  - [方式二：下载单文件执行](#方式二下载单文件执行)
  - [方式三：从源码运行](#方式三从源码运行开发者)
- [安装内容（13 步）](#安装内容13-步)
- [Manage 管理脚本](#manage-管理脚本)
- [第三方供应商](#第三方供应商)
- [MCP Server](#mcp-server)
- [项目结构](#项目结构)
- [常见问题](#常见问题)
- [License](#license)
- [友情链接](#友情链接)

---

## 为什么用 CCQ

在 Windows 上搭 Claude Code 环境，经常会遇到这些问题：

- PowerShell 版本和编码问题
- Node.js / npm / Git / CLI 工具安装顺序复杂
- 第三方供应商配置分散
- MCP Server 凭据重复录入
- 组件升级后配置漂移

CCQ 通过双阶段脚本 + 实时检测机制，把这些问题统一收敛到一个安装/管理入口。

---

## 核心特性

- **双阶段架构**：PS 5.1 引导脚本 + PS 7 安装/管理脚本
- **实时检测**：每次运行都检测当前状态，已安装组件自动跳过
- **分组安装**：基础环境（必装）+ 进阶扩展（可选/按需）
- **统一管理入口**：更新管理、供应商管理、MCP 管理
- **供应商 Profile 化**：供应商配置持久化到 `~/.claude/providers/`
- **MCP 凭据 Vault**：凭据持久化到 `~/.ccq/mcp-meta.json`
- **更新安全机制**：更新前自动快照备份，支持失败后回滚

---

## 系统要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 10 1903 (18362)+ / Windows 11 |
| 权限 | 管理员权限（建议） |
| 网络 | 可访问 GitHub、npm registry |
| PowerShell | 5.1 可启动，引导脚本会自动准备 PS 7 |

---

## 快速开始

### 方式一：云端直接执行（推荐）

#### 1) 引导脚本（PS 5.1+，管理员）

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
[Text.Encoding]::UTF8.GetString((New-Object Net.WebClient).DownloadData('https://github.com/Yuuqq/claude-code-quickstart/releases/latest/download/Bootstrap-ClaudeEnv.built.ps1')) | iex
```

#### 2) 安装脚本（PS 7+）

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
irm 'https://github.com/Yuuqq/claude-code-quickstart/releases/latest/download/Install-ClaudeEnv.built.ps1' | iex
```

#### 3) 管理脚本（PS 7+）

新增快捷指令入口（历史安装用户需重新执行一次安装脚本的基础环境）：

```powershell
ccq
```

旧入口：

```powershell
irm 'https://github.com/Yuuqq/claude-code-quickstart/releases/latest/download/Manage-ClaudeEnv.built.ps1' | iex
```

---

### 方式二：下载单文件执行

从 [Releases](../../releases) 下载：

- `Bootstrap-ClaudeEnv.built.ps1`
- `Install-ClaudeEnv.built.ps1`
- `Manage-ClaudeEnv.built.ps1`

执行示例：

```powershell
# 引导（PS 5.1+，管理员）
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
.\Bootstrap-ClaudeEnv.built.ps1

# 安装（PS 7+）
.\Install-ClaudeEnv.built.ps1

# 管理（PS 7+）
.\Manage-ClaudeEnv.built.ps1
```

---

### 方式三：从源码运行（开发者）

```powershell
git clone https://github.com/Yuuqq/claude-code-quickstart.git
cd claude-code-quickstart

# 引导（PS 5.1+）
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
.\installer\Bootstrap-ClaudeEnv.ps1

# 安装（PS 7+）
.\installer\Install-ClaudeEnv.ps1

# 管理（PS 7+）
.\installer\Manage-ClaudeEnv.ps1
```

模拟 `irm | iex`（可传参，如 `-OutputMode Developer` 全量输出）：

```powershell
& ([scriptblock]::Create((Get-Content "installer/build/dist/Install-ClaudeEnv.built.ps1" -Raw))) -OutputMode Developer
```

---

## 安装内容（13 步）

### 基础环境（必装）

1. Node.js
2. Git
3. Claude Code
4. 第三方供应商配置

### 进阶扩展（按需）

5. CCometixLine
6. Claude 基础配置
7. CLAUDE.md 配置
8. MCP Server 配置
9. CCG 工作流
10. OpenSpec CLI
11. cc-switch（可选）
12. Codex CLI（可选）
13. Gemini CLI（可选）

---

## Manage 管理脚本

`Manage-ClaudeEnv.ps1` 提供统一管理入口：

### 1) 更新管理（Update）

- 检测可更新组件
- 支持交互多选更新
- 更新前自动快照备份
- 指纹预检（模板未变更自动跳过）

### 2) 供应商管理（Provider）

- 供应商 Profile 的新增 / 编辑 / 删除 / 切换
- 支持从 settings.json 同步历史配置

### 3) MCP 管理（Mcp）

- 查看状态（Active / Disabled / Missing）
- 启用 / 禁用 / 删除
- 凭据通过 vault 持久化

---

## 第三方供应商

支持内置供应商：

- 智谱 GLM（zhipu）
- MiniMax（minimax）
- Kimi / Moonshot（moonshot）
- 阿里云百炼（bailian）
- 自定义供应商（custom）

配置会写入 `~/.claude/settings.json`（`env`，包含供应商认证/Base URL 与可选模型环境键），并将 Profile 保存到 `~/.claude/providers/`。

---

## MCP Server

当前内置 MCP：

- Context7
- DeepWiki
- Tavily
- Playwright
- Exa Search
- ACE Tool
- MasterGo
- Figma
- Chrome DevTools

> 不同 MCP 的凭据类型不同（none / single-key / args-token / url-embedded 等），安装时会按需提示。

---

## 项目结构

```text
claude-code-quickstart/
├── installer/
│   ├── Bootstrap-ClaudeEnv.ps1
│   ├── Install-ClaudeEnv.ps1
│   ├── Manage-ClaudeEnv.ps1
│   ├── build/
│   │   ├── Build-SingleFile.ps1
│   │   └── dist/
│   ├── core/
│   │   ├── Ui.ps1
│   │   ├── Process.ps1
│   │   ├── Profile.ps1
│   │   ├── Admin.ps1
│   │   ├── Net.ps1
│   │   ├── Registry.ps1
│   │   ├── Bootstrap.ps1
│   │   ├── McpManager.ps1
│   │   └── Provider.ps1
│   └── steps/
└── test-syntax.ps1
```

---

## 常见问题

### Q1：安装失败怎么办？

直接重新运行安装脚本即可。CCQ 会实时检测并跳过已安装项。

### Q2：提示找不到`ccq`怎么办？

按你的场景分两种处理：

1. **之前执行过 install（历史安装用户）**
   - 重新执行一次安装脚本的基础环境，让 `ccq` 写入 `$profile`

2. **刚刚执行完 install（本次安装用户）**
   - 先新开一个终端再试：

   ```powershell
   ccq
   ```

   - 如果当前终端也想立即可用，可执行：

   ```powershell
   . $PROFILE
   ccq
   ```

---

## License

[MIT](LICENSE)

---

## 友情链接

- [LINUX DO](https://linux.do/)
