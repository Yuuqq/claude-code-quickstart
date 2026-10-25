# McpManager.ps1 - MCP Server CRUD 管理 + 凭据 Vault
# 作者: 哈雷酱 (本小姐的 MCP 管理杰作！)
# 功能: 状态查看、禁用/启用、删除、凭据持久化、腐败恢复

#Requires -Version 7.0
Set-StrictMode -Version Latest

# 导入依赖模块
. "$PSScriptRoot\Ui.ps1"
. "$PSScriptRoot\Process.ps1"
. "$PSScriptRoot\Profile.ps1"
. "$PSScriptRoot\Net.ps1"

# ─── 常量 ─────────────────────────────────────────────────────────────────────

$script:McpMetaFileName = "mcp-meta.json"
$script:McpMetaSchemaVersion = 1
$script:McpMaxCorruptBackups = 5
$script:McpMutexName = "Global\CCQ.Mcp.Lock"
$script:McpMutexTimeoutMs = 30000

# ─── MCP Rules 分类配置 ─────────────────────────────────────────────────────

$script:McpRulesCategories = @{
    "Search" = @{
        FileName = "ccq-mcp-search.md"
        Title    = "搜索工具"
        Desc     = "联网搜索和内容提取。"
        Chains   = @(
            @{
                Scenario = "联网搜索"
                Steps    = @(
                    @{ McpId = "exa";    Tool = "mcp__exa__web_search_exa" }
                    @{ McpId = "tavily"; Tool = "mcp__tavily__tavily_search" }
                )
                Fallback = "WebSearch"
            }
            @{
                Scenario = "深度研究"
                Steps    = @( @{ McpId = "tavily"; Tool = "mcp__tavily__tavily_research" } )
            }
            @{
                Scenario = "URL 内容提取"
                Steps    = @( @{ McpId = "tavily"; Tool = "mcp__tavily__tavily_extract" } )
            }
            @{
                Scenario = "网站爬取/结构映射"
                Steps    = @(
                    @{ McpId = "tavily"; Tool = "mcp__tavily__tavily_crawl" }
                    @{ McpId = "tavily"; Tool = "mcp__tavily__tavily_map" }
                )
            }
            @{
                Scenario = "公司研究"
                Steps    = @( @{ McpId = "exa"; Tool = "mcp__exa__company_research_exa" } )
            }
            @{
                Scenario = "代码示例搜索"
                Steps    = @( @{ McpId = "exa"; Tool = "mcp__exa__get_code_context_exa" } )
            }
        )
    }
    "Documentation" = @{
        FileName = "ccq-mcp-docs.md"
        Title    = "文档检索工具"
        Desc     = "库文档和开源项目文档检索。"
        Chains   = @(
            @{
                Scenario = "库官方文档"
                Steps    = @( @{ McpId = "context7"; Tool = "mcp__context7__resolve-library-id → mcp__context7__query-docs" } )
            }
            @{
                Scenario = "GitHub 开源项目"
                Steps    = @( @{ McpId = "deepwiki"; Tool = "mcp__deepwiki__ask_question / read_wiki_structure / read_wiki_contents" } )
            }
        )
        Tips = @(
            "context7 先 resolve-library-id 再 query-docs"
            "deepwiki 用于理解 GitHub 项目架构"
        )
    }
    "Development" = @{
        FileName = "ccq-mcp-code.md"
        Title    = "代码检索工具"
        Desc     = "代码语义搜索和上下文检索。"
        Chains   = @(
            @{
                Scenario = "代码语义检索"
                Steps    = @(
                    @{ McpId = "ace-tool"; Tool = "mcp__ace-tool__search_context" }
                )
                Fallback = "Grep + Glob"
            }
        )
        StaticRows = @(
            @{ Scenario = "精确字符串/正则";  Tool = "Grep" }
            @{ Scenario = "文件名匹配";      Tool = "Glob" }
            @{ Scenario = "深度代码库探索";   Tool = "Agent + subagent_type=Explore" }
            @{ Scenario = "技术方案规划";     Tool = "EnterPlanMode / Agent + subagent_type=Plan" }
        )
        Tips = @(
            "语义理解用 ace-tool，精确匹配用 Grep"
        )
    }
}

# ─── MCP 注册模板（从 steps/Mcp.ps1 迁移） ───────────────────────────────────

# 默认运行时依赖
$script:DefaultMcpRuntimeDeps = @(
    @{
        Name = "Node.js LTS"
        Command = "node"
        MinVersion = "20.0.0"
        WingetId = "OpenJS.NodeJS.LTS"
        ManualUrl = "https://nodejs.org/"
    }
    @{
        Name = "npm"
        Command = "npm"
        MinVersion = "10.0.0"
        WingetId = "OpenJS.NodeJS.LTS"
        ManualUrl = "https://nodejs.org/"
    }
)

# MCP Server 配置定义
$script:McpServers = [ordered]@{
    "context7" = @{
        Name = "Context7"
        Description = "库文档和代码示例检索，支持最新的开发框架文档"
        McpType = "stdio"
        Command = "npx"
        Args = @("-y", "@upstash/context7-mcp")
        CredentialType = "none"
        RuntimeDeps = $script:DefaultMcpRuntimeDeps
        Category = "Documentation"
        Priority = 1
        Recommended = $true
    }
    "deepwiki" = @{
        Name = "DeepWiki"
        Description = "GitHub 仓库 AI 文档生成和问答"
        McpType = "http"
        Url = "https://mcp.deepwiki.com/mcp"
        CredentialType = "none"
        Category = "Documentation"
        Priority = 2
        Recommended = $true
    }
    "tavily" = @{
        Name = "Tavily"
        Description = "AI 驱动的实时网络搜索、抓取和研究"
        McpType = "http"
        UrlTemplate = "https://mcp.tavily.com/mcp/?tavilyApiKey={TAVILY_API_KEY}"
        CredentialType = "url-embedded"
        Credentials = @(
            @{
                Name = "TAVILY_API_KEY"
                Label = "Tavily API Key"
                Secret = $true
                Required = $true
                Url = "https://app.tavily.com/home"
            }
        )
        Category = "Search"
        Priority = 3
        Recommended = $false
    }
    # TODO: ContextWeaver 需要 Python 环境，待 Python 安装步骤实现后启用
    # "contextweaver" = @{
    #     Name = "ContextWeaver"
    #     Description = "语义代码检索引擎，基于 Tree-sitter 和向量搜索"
    #     McpType = "stdio"
    #     Command = "contextweaver"
    #     Args = @("mcp")
    #     CredentialType = "env-file"
    #     RuntimeDeps = $script:DefaultMcpRuntimeDeps
    #     PreInstall = @{
    #         Type = "npm-global"
    #         Package = "@hsingjui/contextweaver"
    #         CommandCheck = "contextweaver"
    #         InitCommand = "contextweaver init"
    #         InitializedPath = "$env:USERPROFILE\.contextweaver"
    #     }
    #     EnvFile = @{
    #         Path = "$env:USERPROFILE\.contextweaver\.env"
    #         DefaultProvider = "SiliconFlow"
    #         ProviderUrl = "https://cloud.siliconflow.cn/account/ak"
    #         SharedCredentialName = "SILICONFLOW_API_KEY"
    #         SharedKeyLabel = "SiliconFlow API Key (Embedding + Rerank 共用)"
    #         SharedKeyFields = @("EMBEDDINGS_API_KEY", "RERANK_API_KEY")
    #         Fields = @(
    #             @{ Key = "EMBEDDINGS_API_KEY"; Required = $true; Secret = $true }
    #             @{ Key = "EMBEDDINGS_BASE_URL"; Default = "https://api.siliconflow.cn/v1/embeddings" }
    #             @{ Key = "EMBEDDINGS_MODEL"; Default = "BAAI/bge-m3" }
    #             @{ Key = "EMBEDDINGS_DIMENSIONS"; Default = "1024" }
    #             @{ Key = "RERANK_API_KEY"; Required = $true; Secret = $true }
    #             @{ Key = "RERANK_BASE_URL"; Default = "https://api.siliconflow.cn/v1/rerank" }
    #             @{ Key = "RERANK_MODEL"; Default = "BAAI/bge-reranker-v2-m3" }
    #             @{ Key = "RERANK_TOP_N"; Default = "20" }
    #         )
    #     }
    #     Category = "Development"
    #     Priority = 4
    #     Recommended = $true
    # }
    "playwright" = @{
        Name = "Playwright"
        Description = "Microsoft 官方网页自动化，基于可访问性树交互"
        McpType = "stdio"
        Command = "npx"
        Args = @("-y", "@playwright/mcp@latest")
        CredentialType = "none"
        RuntimeDeps = $script:DefaultMcpRuntimeDeps
        Category = "Automation"
        Priority = 5
        Recommended = $true
    }
    "exa" = @{
        Name = "Exa Search"
        Description = "AI 原生高质量网络搜索和内容提取"
        McpType = "stdio"
        Command = "npx"
        Args = @("-y", "exa-mcp-server")
        CredentialType = "single-key"
        ApiKeyName = "EXA_API_KEY"
        ApiKeyUrl = "https://dashboard.exa.ai/api-keys"
        RuntimeDeps = $script:DefaultMcpRuntimeDeps
        Category = "Search"
        Priority = 6
        Recommended = $true
    }
    "ace-tool" = @{
        Name = "ACE Tool"
        Description = "代码上下文检索、语义搜索"
        McpType = "stdio"
        Command = "npx"
        Args = @("-y", "ace-tool@latest")
        CredentialType = "args-multi"
        ArgsCredentials = @(
            @{
                ArgName = "--base-url"
                Label = "ACE Backend URL"
                Secret = $false
                Required = $true
                Url = "https://github.com/eastxiaodong/ace-tool"
            }
            @{
                ArgName = "--token"
                Label = "ACE Token"
                Secret = $true
                Required = $true
            }
        )
        RuntimeDeps = $script:DefaultMcpRuntimeDeps
        Category = "Development"
        Priority = 7
        Recommended = $false
    }
    "mastergo" = @{
        Name = "MasterGo"
        Description = "MasterGo 设计稿解析和代码生成 (需团队版)"
        McpType = "stdio"
        Command = "npx"
        Args = @("-y", "@mastergo/magic-mcp", "--url=https://mastergo.com")
        CredentialType = "args-token"
        TokenArg = "--token"
        TokenLabel = "MasterGo API Token"
        TokenUrl = "https://mastergo.com/help/MG/MCP"
        RuntimeDeps = $script:DefaultMcpRuntimeDeps
        Category = "Design"
        Priority = 8
        Recommended = $false
    }
    "figma" = @{
        Name = "Figma"
        Description = "Figma 官方设计稿代码生成和变量提取"
        McpType = "http"
        Url = "https://mcp.figma.com/mcp"
        CredentialType = "none"
        Note = "首次使用时会弹出 OAuth 认证流程，无需手动配置 API Key"
        Category = "Design"
        Priority = 10
        Recommended = $false
    }
    "chrome-devtools" = @{
        Name = "Chrome DevTools"
        Description = "Chrome 浏览器自动化控制、网络监控和性能分析"
        McpType = "stdio"
        Command = "npx"
        Args = @("-y", "chrome-devtools-mcp@latest")
        CredentialType = "none"
        RuntimeDeps = $script:DefaultMcpRuntimeDeps
        Category = "Automation"
        Priority = 11
        Recommended = $false
    }
}

# ─── MCP Rules 渲染函数 ─────────────────────────────────────────────────────

function Get-McpRulesDir {
    <#
    .SYNOPSIS
    获取 MCP Rules 目录路径（~/.claude/rules）
    #>
    $rulesDir = Join-Path (Get-UserHome) ".claude/rules"
    if (-not (Test-Path $rulesDir)) {
        New-Item -Path $rulesDir -ItemType Directory -Force | Out-Null
    }
    return $rulesDir
}

function Get-EnabledMcpIdsByCategory {
    <#
    .SYNOPSIS
    获取各分类下已启用的 MCP Server ID 列表
    .PARAMETER McpStatus
    从 Get-McpStatus 获取的 MCP 状态数组（hashtable[]）
    .RETURNS
    Hashtable：{ CategoryName = @(McpId1, McpId2, ...) }
    #>
    param([Parameter(Mandatory)][array]$McpStatus)

    # 将数组转换为 Id -> Status 的映射表
    $statusById = @{}
    foreach ($item in $McpStatus) {
        if ($item -is [hashtable] -and $item.ContainsKey("Id")) {
            $id = [string]$item["Id"]
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                $statusById[$id] = [string]$item["Status"]
            }
        }
    }

    $result = @{}
    foreach ($catName in $script:McpRulesCategories.Keys) {
        $cat = $script:McpRulesCategories[$catName]
        $enabledIds = [System.Collections.ArrayList]::new()

        foreach ($chain in $cat.Chains) {
            foreach ($step in $chain.Steps) {
                $mcpId = $step.McpId
                # 检查是否启用（Active 状态）
                if ($statusById.ContainsKey($mcpId) -and $statusById[$mcpId] -eq "Active") {
                    if (-not $enabledIds.Contains($mcpId)) {
                        [void]$enabledIds.Add($mcpId)
                    }
                }
            }
        }
        $result[$catName] = @($enabledIds)
    }
    return $result
}

function Render-McpToolChain {
    <#
    .SYNOPSIS
    渲染单个分类的 Markdown 文件内容
    .PARAMETER CategoryName
    分类名称（如 Search、Documentation 等）
    .PARAMETER EnabledMcpIds
    该分类下已启用的 MCP ID 数组
    .RETURNS
    Markdown 字符串
    #>
    param(
        [Parameter(Mandatory)][string]$CategoryName,
        [Parameter(Mandatory)][array]$EnabledMcpIds
    )

    $cat = $script:McpRulesCategories[$CategoryName]
    if (-not $cat) { return $null }

    $sb = [System.Text.StringBuilder]::new()

    # 头部
    [void]$sb.AppendLine("# $($cat.Title)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("> 自动生成，请勿手动编辑。由 MCP Manager 根据已启用的 MCP Server 动态渲染。")
    [void]$sb.AppendLine("")
    if ($cat.Desc) {
        [void]$sb.AppendLine($cat.Desc)
        [void]$sb.AppendLine("")
    }

    # 工具链表格
    [void]$sb.AppendLine("| 场景 | 工具链 |")
    [void]$sb.AppendLine("|------|--------|")

    foreach ($chain in $cat.Chains) {
        $scenario = $chain.Scenario
        $tools = [System.Collections.ArrayList]::new()

        foreach ($step in $chain.Steps) {
            $mcpId = $step.McpId
            if ($EnabledMcpIds -contains $mcpId) {
                [void]$tools.Add($step.Tool)
            }
        }

        # 添加 Fallback（如果有且前面的工具都不可用）
        if ($chain -is [hashtable] -and $chain.ContainsKey('Fallback') -and $chain['Fallback']) {
            [void]$tools.Add("$($chain['Fallback'])（兜底）")
        }

        if ($tools.Count -gt 0) {
            $toolChain = $tools -join " → "
            [void]$sb.AppendLine("| $scenario | ``$toolChain`` |")
        }
    }

    # 静态行（如 Development 的 Grep/Glob）
    if ($cat -is [hashtable] -and $cat.ContainsKey('StaticRows') -and $cat['StaticRows']) {
        foreach ($row in $cat['StaticRows']) {
            [void]$sb.AppendLine("| $($row.Scenario) | ``$($row.Tool)`` |")
        }
    }

    [void]$sb.AppendLine("")

    # Tips
    if ($cat -is [hashtable] -and $cat.ContainsKey('Tips') -and $cat['Tips'].Count -gt 0) {
        [void]$sb.AppendLine("**Tips**:")
        foreach ($tip in $cat['Tips']) {
            [void]$sb.AppendLine("- $tip")
        }
    }

    return $sb.ToString()
}

function Sync-McpCategoryRules {
    <#
    .SYNOPSIS
    同步单个分类的 MCP Rules 文件
    .PARAMETER CategoryName
    分类名称
    .PARAMETER McpStatus
    MCP 状态数组（hashtable[]）
    .RETURNS
    @{ Changed = $bool; FileName = $string }
    #>
    param(
        [Parameter(Mandatory)][string]$CategoryName,
        [Parameter(Mandatory)][array]$McpStatus
    )

    $cat = $script:McpRulesCategories[$CategoryName]
    if (-not $cat) {
        return @{ Changed = $false; FileName = "" }
    }

    $rulesDir = Get-McpRulesDir
    $filePath = Join-Path $rulesDir $cat.FileName

    # 获取该分类下的已启用 MCP
    $enabledByCategory = Get-EnabledMcpIdsByCategory -McpStatus $McpStatus
    $enabledIds = @($enabledByCategory[$CategoryName])

    # 如果该分类没有任何已启用的 MCP，删除对应文件
    if ($enabledIds.Count -eq 0) {
        if (Test-Path $filePath) {
            Remove-Item $filePath -Force
            return @{ Changed = $true; FileName = $cat.FileName; Action = "Deleted" }
        }
        return @{ Changed = $false; FileName = $cat.FileName }
    }

    # 渲染内容
    $content = Render-McpToolChain -CategoryName $CategoryName -EnabledMcpIds $enabledIds

    # 比较是否需要更新
    $existingContent = ""
    if (Test-Path $filePath) {
        $existingContent = Get-Content $filePath -Raw -ErrorAction SilentlyContinue
    }

    $contentNormalized = ($content -replace "`r`n", "`n").Trim()
    $existingNormalized = ($existingContent -replace "`r`n", "`n").Trim()

    if ($contentNormalized -ne $existingNormalized) {
        $writeOk = Write-FileAtomically -FilePath $filePath -Content $content
        if (-not $writeOk) {
            throw "写入 MCP Rules 文件失败: $($cat.FileName)"
        }
        return @{ Changed = $true; FileName = $cat.FileName; Action = "Updated" }
    }

    return @{ Changed = $false; FileName = $cat.FileName }
}

function Sync-AllMcpRules {
    <#
    .SYNOPSIS
    同步所有 MCP Rules 文件（根据当前 MCP 状态动态渲染）
    .DESCRIPTION
    遍历所有分类，根据已启用的 MCP Server 动态生成/更新/删除对应的 rules 文件。
    .RETURNS
    @{ Success = $bool; ChangedFiles = @(...); ErrorMessage = $string }
    #>

    $result = @{
        Success      = $false
        ChangedFiles = @()
        ErrorMessage = ""
    }

    try {
        # 获取当前 MCP 状态
        $mcpStatus = Get-McpStatus
        if (-not $mcpStatus) {
            $result.ErrorMessage = "无法获取 MCP 状态"
            return $result
        }

        $changedFiles = [System.Collections.ArrayList]::new()

        # 遍历所有分类
        foreach ($catName in $script:McpRulesCategories.Keys) {
            $syncResult = Sync-McpCategoryRules -CategoryName $catName -McpStatus $mcpStatus
            if ($syncResult.Changed) {
                [void]$changedFiles.Add($syncResult)
            }
        }

        $result.ChangedFiles = @($changedFiles)
        $result.Success = $true

        if ($changedFiles.Count -gt 0) {
            Write-UiSuccess "MCP Rules 已同步 ($($changedFiles.Count) 个文件变更)"
        }
    }
    catch {
        $result.ErrorMessage = $_.Exception.Message
        Write-UiWarning "MCP Rules 同步失败: $($result.ErrorMessage)"
    }

    return $result
}

# ─── 凭据同步 ──────────────────────────────────────────────────────────────

function Sync-McpCredentials {
    <#
    .SYNOPSIS
    同步 .claude.json 和 vault 之间的凭据（双向补缺）
    .DESCRIPTION
    场景 A: .claude.json 有 env 但 vault 无 credentials → 备份到 vault
    场景 B: vault 有 credentials 但 .claude.json env 缺失 → 恢复（仅限内置 MCP）
    .RETURNS
    @{ Success = $bool; SyncedCount = $int; Details = @() }
    #>

    $result = @{ Success = $true; SyncedCount = 0; Details = @() }

    try {
        # 读取 .claude.json（无需 vault 锁）
        $cjPath = "$(Get-UserHome)\.claude.json"
        if (-not (Test-Path $cjPath)) { return $result }
        $cj = Get-Content -Path $cjPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if (-not $cj -or -not $cj.ContainsKey("mcpServers") -or $cj["mcpServers"] -isnot [hashtable]) { return $result }

        # 共享状态（hashtable 引用类型，scriptblock 内修改对外可见）
        $sync = @{ VaultCount = 0; VaultDetails = @(); CjCount = 0; CjDetails = @(); CjChanged = $false }

        # vault 读改写在同一锁区间（与 Enable-McpServer 模式一致）
        $null = Invoke-WithMcpLock {
            $meta = Read-McpMeta
            $vaultChanged = $false

            foreach ($id in @($cj["mcpServers"].Keys)) {
                $config = $cj["mcpServers"][$id]
                if ($config -isnot [hashtable]) { continue }

                $cjHasEnv = $config.ContainsKey("env") -and
                            $config["env"] -is [hashtable] -and
                            $config["env"].Count -gt 0
                $vaultHasCred = $meta["servers"].ContainsKey($id) -and
                                $meta["servers"][$id] -is [hashtable] -and
                                $meta["servers"][$id].ContainsKey("credentials") -and
                                $meta["servers"][$id]["credentials"] -is [hashtable]
                $vaultHasValues = $vaultHasCred -and
                                  $meta["servers"][$id]["credentials"].ContainsKey("values") -and
                                  $meta["servers"][$id]["credentials"]["values"] -is [hashtable] -and
                                  $meta["servers"][$id]["credentials"]["values"].Count -gt 0

                # 场景 A: .claude.json 有 env, vault 无 → 备份到 vault
                if ($cjHasEnv -and -not $vaultHasValues) {
                    if (-not $meta["servers"].ContainsKey($id)) {
                        $meta["servers"][$id] = @{}
                    }
                    if ($meta["servers"][$id] -isnot [hashtable]) {
                        $meta["servers"][$id] = @{}
                    }
                    $meta["servers"][$id]["credentials"] = @{ values = $config["env"] }
                    $meta["servers"][$id]["updatedAt"] = (Get-Date).ToUniversalTime().ToString("o")
                    $vaultChanged = $true
                    $sync.VaultCount++
                    $sync.VaultDetails += "vault-backup::$id"
                    Write-UiDim "  凭据备份: $id → vault" -Level Detail
                }

                # 场景 B: vault 有 credentials, .claude.json env 缺失 → 恢复（仅限内置 MCP）
                if (-not $cjHasEnv -and $vaultHasValues) {
                    $isBuiltin = $script:McpServers -and $script:McpServers.ContainsKey($id)
                    if ($isBuiltin) {
                        $config["env"] = $meta["servers"][$id]["credentials"]["values"]
                        $sync.CjChanged = $true
                        $sync.CjCount++
                        $sync.CjDetails += "claude-restore::$id"
                        Write-UiDim "  凭据恢复: vault → $id" -Level Detail
                    }
                }
            }

            # vault 写入（同一锁区间内）
            if ($vaultChanged) {
                Write-McpMeta $meta
                Write-UiDim "vault 已更新" -Level Detail
            }
        }

        # vault 同步成功（锁区间无异常）→ 计入结果
        $result.SyncedCount += $sync.VaultCount
        $result.Details += $sync.VaultDetails

        # .claude.json 写入（无需 vault 锁）— 写入成功才计入同步数
        if ($sync.CjChanged) {
            $writeOk = Write-FileAtomically -FilePath $cjPath -Content @($cj | ConvertTo-Json -Depth 10)
            if ($writeOk) {
                $result.SyncedCount += $sync.CjCount
                $result.Details += $sync.CjDetails
            }
            else {
                Write-UiWarning "凭据恢复写入 .claude.json 失败"
            }
        }
    }
    catch {
        $result.Success = $false
        Write-UiWarning "凭据同步失败: $($_.Exception.Message)" -Level Detail
    }

    return $result
}

# ─── Task 2.1: 目录管理 + 文件骨架 ───────────────────────────────────────────

function Ensure-CcqMetaDir {
    <#
    .SYNOPSIS
    确保 ~/.ccq/ 目录存在（首次使用时自动创建）
    .RETURNS
    目录绝对路径
    #>
    $dir = Join-Path (Get-UserHome) ".ccq"
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    return $dir
}

function Get-McpMetaPath {
    <#
    .SYNOPSIS
    获取 mcp-meta.json 文件路径
    #>
    return Join-Path (Ensure-CcqMetaDir) $script:McpMetaFileName
}

function New-EmptyMcpMeta {
    <#
    .SYNOPSIS
    创建空的 v1 vault 结构
    .RETURNS
    hashtable - 合法的空 vault
    #>
    $now = (Get-Date).ToUniversalTime().ToString("o")
    return @{
        schemaVersion = $script:McpMetaSchemaVersion
        createdAt     = $now
        updatedAt     = $now
        servers       = @{}
    }
}

# ─── Task 2.2: Read-McpMeta + 腐败恢复 ──────────────────────────────────────

function Invoke-McpCorruptionRecovery {
    <#
    .SYNOPSIS
    vault 文件腐败恢复：重命名 + 清理旧备份 + 返回空 vault
    .PARAMETER FilePath
    损坏的 vault 文件路径
    .RETURNS
    hashtable - 新的空 vault
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $timestamp = (Get-Date).ToString("yyyyMMddHHmmss")
    $corruptName = "$FilePath.corrupt.$timestamp"

    try {
        Move-Item -Path $FilePath -Destination $corruptName -Force
        Write-UiWarning "Vault 文件损坏，已重命名为 $(Split-Path $corruptName -Leaf)，重新初始化"
    }
    catch {
        Write-UiWarning "Vault 文件损坏且无法重命名: $($_.Exception.Message)"
    }

    # 清理超出上限的 corrupt 备份
    $corruptFiles = @(Get-ChildItem -Path (Split-Path $FilePath -Parent) -Filter "*.corrupt.*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime)
    if ($corruptFiles.Count -gt $script:McpMaxCorruptBackups) {
        $toDelete = $corruptFiles | Select-Object -First ($corruptFiles.Count - $script:McpMaxCorruptBackups)
        foreach ($file in $toDelete) {
            Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    return New-EmptyMcpMeta
}

function Read-McpMeta {
    <#
    .SYNOPSIS
    读取 vault 文件（mcp-meta.json）+ 腐败恢复 + schema 校验
    .RETURNS
    hashtable - vault 数据
    #>

    $metaPath = Get-McpMetaPath

    # 文件不存在 → 返回空 vault（lazy create，不写入磁盘）
    if (-not (Test-Path $metaPath)) {
        return New-EmptyMcpMeta
    }

    # 读取 + 解析
    $meta = $null
    try {
        $raw = Get-Content -Path $metaPath -Raw -Encoding UTF8
        $meta = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        return Invoke-McpCorruptionRecovery -FilePath $metaPath
    }

    # Schema 校验：schemaVersion 必须是正整数（ConvertFrom-Json 可能返回 [int] 或 [long]）
    if (-not $meta -or
        -not $meta.ContainsKey("schemaVersion") -or
        ($meta["schemaVersion"] -isnot [int] -and $meta["schemaVersion"] -isnot [long]) -or
        $meta["schemaVersion"] -lt 1) {
        return Invoke-McpCorruptionRecovery -FilePath $metaPath
    }

    # Schema 校验：servers 必须是 hashtable
    if (-not $meta.ContainsKey("servers") -or $meta["servers"] -isnot [hashtable]) {
        return Invoke-McpCorruptionRecovery -FilePath $metaPath
    }

    # 高版本检测：可读取但标记只读
    if ($meta["schemaVersion"] -gt $script:McpMetaSchemaVersion) {
        $meta["_readOnly"] = $true
    }

    # 未知字段：保留（不删除）
    return $meta
}

# ─── Task 2.3: Write-McpMeta ────────────────────────────────────────────────

function Write-McpMeta {
    <#
    .SYNOPSIS
    原子写入 vault 文件 + 时间戳更新 + 版本检查
    .PARAMETER Meta
    vault 数据 hashtable
    .RETURNS
    $true 写入成功
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Meta
    )

    # 高版本检查
    if ($Meta.ContainsKey("schemaVersion") -and $Meta["schemaVersion"] -gt $script:McpMetaSchemaVersion) {
        throw "schema version too high: $($Meta['schemaVersion']) > $($script:McpMetaSchemaVersion)"
    }

    # 只读检查
    if ($Meta.ContainsKey("_readOnly") -and $Meta["_readOnly"]) {
        throw "vault is read-only (newer schema version)"
    }

    # 更新根 updatedAt
    $now = (Get-Date).ToUniversalTime().ToString("o")
    $Meta["updatedAt"] = $now

    # 确保根 updatedAt ≥ max(servers[*].updatedAt)
    if ($Meta.ContainsKey("servers") -and $Meta["servers"] -is [hashtable]) {
        foreach ($serverId in $Meta["servers"].Keys) {
            $server = $Meta["servers"][$serverId]
            if ($server -is [hashtable] -and $server.ContainsKey("updatedAt")) {
                if ([string]$server["updatedAt"] -gt [string]$Meta["updatedAt"]) {
                    $Meta["updatedAt"] = $server["updatedAt"]
                }
            }
        }
    }

    # 删除内部标记字段
    $cleanMeta = @{}
    foreach ($key in $Meta.Keys) {
        if ($key -notlike "_*") {
            $cleanMeta[$key] = $Meta[$key]
        }
    }

    # 序列化
    $json = $cleanMeta | ConvertTo-Json -Depth 10

    # 原子写入
    Ensure-CcqMetaDir | Out-Null
    $null = Write-FileAtomically -FilePath (Get-McpMetaPath) -Content $json

    return $true
}

# ─── Task 2.4: Mutex 包装 ───────────────────────────────────────────────────

function Invoke-WithMcpLock {
    <#
    .SYNOPSIS
    在 Mutex 保护下执行操作（防止并发写入）
    .PARAMETER Action
    要在锁内执行的脚本块
    .RETURNS
    脚本块的返回值
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    $mutex = [System.Threading.Mutex]::new($false, $script:McpMutexName)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne($script:McpMutexTimeoutMs)
        if (-not $acquired) {
            throw "无法获取 MCP 锁（另一个实例正在操作），请稍后重试"
        }
        return & $Action
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# ─── Task 2.5: Get-McpDefinitionHash ────────────────────────────────────────

function ConvertTo-CanonicalObject {
    <#
    .SYNOPSIS
    递归规范化对象：hashtable 键排序为 ordered，确保 JSON 序列化确定性
    #>
    param($Obj)

    if ($Obj -is [hashtable] -or $Obj -is [System.Collections.Specialized.OrderedDictionary]) {
        $sorted = [ordered]@{}
        foreach ($key in ($Obj.Keys | Sort-Object)) {
            $sorted[$key] = ConvertTo-CanonicalObject $Obj[$key]
        }
        return $sorted
    }
    elseif ($Obj -is [array]) {
        return @($Obj | ForEach-Object { ConvertTo-CanonicalObject $_ })
    }
    return $Obj
}

function Get-McpDefinitionHash {
    <#
    .SYNOPSIS
    计算 MCP Server 定义的哈希值（SHA-256 前 8 位）
    .PARAMETER ServerDef
    server 定义 hashtable
    .RETURNS
    8 字符哈希字符串
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ServerDef
    )

    # 排除非运行时字段，仅保留影响行为的字段
    $runtimeFields = @{}
    $excludeKeys = @("Description", "Category", "Priority", "Recommended", "Name", "RuntimeDeps")
    foreach ($key in $ServerDef.Keys) {
        if ($key -notin $excludeKeys) {
            $runtimeFields[$key] = $ServerDef[$key]
        }
    }

    # 递归规范化 hashtable 键排序以确保确定性（CONS-2）
    $canonical = ConvertTo-CanonicalObject $runtimeFields
    $json = $canonical | ConvertTo-Json -Depth 10 -Compress

    # 计算 SHA-256
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $hash = $sha256.ComputeHash($bytes)
        # 取前 8 位十六进制
        return ($hash[0..3] | ForEach-Object { $_.ToString("x2") }) -join ""
    }
    finally {
        $sha256.Dispose()
    }
}

# ─── CJK 显示宽度辅助函数（已迁移至 Ui.ps1 统一管理） ─────────────────────
# Get-StringDisplayWidth 和 Format-DisplayPad 由 Ui.ps1 提供（dot-source 加载顺序保证可用）

# ─── 版本工具（从 steps/Mcp.ps1 迁移） ───────────────────────────────────────

function ConvertTo-NormalizedVersion {
    param([string]$VersionText)

    if ([string]::IsNullOrWhiteSpace($VersionText)) {
        return $null
    }

    $match = [regex]::Match($VersionText, '\d+(\.\d+){0,3}')
    if (-not $match.Success) {
        return $null
    }

    $parts = @($match.Value.Split('.'))
    while ($parts.Count -lt 4) {
        $parts += "0"
    }

    try {
        return [version]::new([int]$parts[0], [int]$parts[1], [int]$parts[2], [int]$parts[3])
    }
    catch {
        return $null
    }
}

# ─── 凭据输入（从 steps/Mcp.ps1 迁移） ───────────────────────────────────────

function Read-McpCredentialValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [bool]$Secret = $true,
        [bool]$Required = $true,
        [string]$DefaultValue = "",
        [string]$Hint = ""
    )

    do {
        if (-not [string]::IsNullOrWhiteSpace($Hint)) {
            Write-UiInfo $Hint
        }

        if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
            Write-UiInfo "请输入 $Label（直接回车使用默认值）:"
        }
        else {
            Write-UiInfo "请输入 ${Label}:"
        }

        if ($Secret) {
            $secureValue = Read-Host -Prompt $Label -AsSecureString
            $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
            try {
                $value = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)
            }
            finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
            }
        }
        else {
            $value = Read-Host -Prompt $Label
        }

        if ($null -eq $value) {
            $value = ""
        }

        $value = $value.Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
                return $DefaultValue
            }

            if ($Required) {
                Write-UiDanger "$Label 不能为空，请重新输入"
                continue
            }

            return ""
        }

        return $value
    } while ($true)
}

# ─── Claude Settings 路径（从 steps/Mcp.ps1 迁移） ───────────────────────────

function Get-ClaudeSettingsPath {
    <#
    .SYNOPSIS
    获取 Claude Code settings.json 路径（HC-12: ~/.claude/settings.json）
    #>

    return "$(Get-UserHome)\.claude\settings.json"
}

# ─── 安装管道子函数（从 steps/Mcp.ps1 迁移） ─────────────────────────────────

function Install-McpRuntimeDeps {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Server
    )

    # 确保 fnm 环境已初始化（前置步骤可能已安装 fnm 但当前会话未加载）
    if ((Test-CommandAvailable -Command "fnm") -and -not (Test-CommandAvailable -Command "node")) {
        Write-UiPrimary "初始化 fnm 环境..."
        try {
            $fnmEnvOutput = & fnm env --json --use-on-cd 2>&1 | Out-String
            if ($fnmEnvOutput -and $LASTEXITCODE -eq 0) {
                $envVars = $fnmEnvOutput | ConvertFrom-Json
                foreach ($prop in $envVars.psobject.properties) {
                    Set-Item -Path "Env:$($prop.Name)" -Value $prop.Value
                }
            } elseif ($fnmEnvOutput) {
                # Fallback to regex parsing if --json isn't supported (older fnm)
                $lines = $fnmEnvOutput -split "`r?`n"
                foreach ($line in $lines) {
                    if ($line -match '^\$env:([a-zA-Z0-9_]+)="([^"]*)"$') {
                        Set-Item -Path "Env:$($matches[1])" -Value $matches[2]
                    } elseif ($line -match '^\$env:PATH="([^"]*)" \+ \[IO\.Path\]::PathSeparator \+ \$env:PATH$') {
                        $env:PATH = $matches[1] + [IO.Path]::PathSeparator + $env:PATH
                    }
                }
            }
            Refresh-SessionPath
        } catch {
            Write-UiWarning "fnm 环境初始化失败: $($_.Exception.Message)"
        }
    }

    $deps = @()
    if ($Server.ContainsKey("RuntimeDeps") -and $Server["RuntimeDeps"]) {
        $deps = @($Server["RuntimeDeps"])
    }
    if ($deps.Count -eq 0) {
        return @{ Success = $true; Installed = @() }
    }

    $installedDeps = @()
    foreach ($dep in $deps) {
        $depName = if ($dep.Name) { $dep.Name } else { $dep.Command }
        $command = [string]$dep.Command
        $needsInstall = $false

        if (-not (Test-CommandAvailable -Command $command)) {
            $needsInstall = $true
            Write-UiWarning "$depName 未检测到，准备安装"
        }
        elseif ($dep.MinVersion) {
            $installedVersionText = Get-CommandVersion -Command $command
            $installedVersion = ConvertTo-NormalizedVersion -VersionText $installedVersionText
            $minVersion = ConvertTo-NormalizedVersion -VersionText ([string]$dep.MinVersion)

            if ($installedVersion -and $minVersion -and $installedVersion -lt $minVersion) {
                $needsInstall = $true
                Write-UiWarning "$depName 版本过低: $installedVersionText < $($dep.MinVersion)"
            }
        }

        if ($needsInstall) {
            if (-not $dep.WingetId) {
                $manualHint = if ($dep.ManualUrl) { "，请手动安装: $($dep.ManualUrl)" } else { "" }
                throw "依赖 $depName 缺少自动安装配置$manualHint"
            }

            if (-not (Test-CommandAvailable -Command "winget")) {
                $manualHint = if ($dep.ManualUrl) { "`n  手动安装: $($dep.ManualUrl)" } else { "" }
                throw "winget 不可用，无法自动安装依赖 $depName。请先运行「基础环境」安装，或手动安装后重试。$manualHint"
            }

            Invoke-WingetInstall -PackageId $dep.WingetId -PackageName $depName -AcceptLicense -Silent | Out-Null
            Refresh-SessionPath

            if (-not (Test-CommandAvailable -Command $command)) {
                throw "依赖 $depName 安装后仍不可用"
            }

            $installedDeps += $depName
        }
    }

    return @{ Success = $true; Installed = $installedDeps }
}

function Invoke-McpPreInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerId,
        [Parameter(Mandatory = $true)]
        [hashtable]$Server
    )

    if (-not $Server.ContainsKey("PreInstall") -or -not $Server["PreInstall"]) {
        return @{ Success = $true; Message = "无需预安装" }
    }

    $pre = [hashtable]$Server["PreInstall"]
    switch ($pre.Type) {
        "npm-global" {
            $commandCheck = if ($pre.CommandCheck) { [string]$pre.CommandCheck } else { [string]$Server.Command }
            if (-not (Test-CommandAvailable -Command $commandCheck)) {
                Write-UiInfo "预安装 $($Server.Name): npm 全局安装 $($pre.Package)"

                try {
                    Invoke-NpmGlobalInstall -PackageName $pre.Package | Out-Null
                    Refresh-SessionPath
                }
                catch {
                    Write-UiWarning "标准安装失败，尝试清理 npm 缓存后重试..."

                    # 清理 npm 缓存
                    $cleanResult = Invoke-ExternalCommand -Command "npm" -Arguments @("cache", "clean", "--force") -TimeoutSeconds 60 -SuppressOutput
                    if ($cleanResult.Success) {
                        Write-UiPrimary "npm 缓存已清理，重新尝试安装..."

                        # 重试安装，使用 --force 参数
                        $retryResult = Invoke-ExternalCommand -Command "npm" -Arguments @("install", "-g", $pre.Package, "--force") -TimeoutSeconds 300
                        if (-not $retryResult.Success) {
                            throw "重试安装失败: $($retryResult.Error)"
                        }

                        Refresh-SessionPath
                        Write-UiSuccess "✓ $($pre.Package) 重试安装成功"
                    }
                    else {
                        throw "npm 缓存清理失败: $($cleanResult.Error)"
                    }
                }
            }

            if ($pre.InitCommand) {
                $initializedPath = [string]$pre.InitializedPath
                if (-not [string]::IsNullOrWhiteSpace($initializedPath) -and (Test-Path $initializedPath)) {
                    Write-UiDim "$($Server.Name) 已完成初始化，跳过 init"
                }
                else {
                    Write-UiPrimary "执行初始化命令: $($pre.InitCommand)"
                    $tokens = @($pre.InitCommand -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    if ($tokens.Count -eq 0) {
                        throw "初始化命令为空: $($pre.InitCommand)"
                    }

                    $command = $tokens[0]
                    $arguments = @()
                    if ($tokens.Count -gt 1) {
                        $arguments = @($tokens[1..($tokens.Count - 1)])
                    }

                    $initResult = Invoke-ExternalCommand -Command $command -Arguments $arguments -TimeoutSeconds 180
                    if (-not $initResult.Success) {
                        throw "初始化命令执行失败: $($pre.InitCommand)"
                    }
                }
            }

            return @{ Success = $true; Message = "预安装完成" }
        }
        default {
            throw "不支持的预安装类型: $($pre.Type)"
        }
    }
}

function Get-McpCredentials {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerId,
        [Parameter(Mandatory = $true)]
        [hashtable]$Server,
        [Parameter(Mandatory = $true)]
        [hashtable]$SharedCredentials
    )

    $result = @{
        Success = $true
        Values = @{}
        EnvFileValues = @{}
        Shared = @{}
        Skipped = $false
    }

    $credentialType = if ($Server.CredentialType) { [string]$Server.CredentialType } else { "none" }
    switch ($credentialType) {
        "none" {
            return $result
        }
        "single-key" {
            $apiKeyName = [string]$Server.ApiKeyName
            $apiKeyValue = Read-McpCredentialValue -Label $apiKeyName -Secret $true -Required $true
            $result.Values[$apiKeyName] = $apiKeyValue
        }
        "url-embedded" {
            foreach ($credential in @($Server.Credentials)) {
                $value = Read-McpCredentialValue `
                    -Label ([string]$credential.Label) `
                    -Secret ([bool]$credential.Secret) `
                    -Required ([bool]$credential.Required)

                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $result.Values[[string]$credential.Name] = $value
                }
            }
        }
        "multi-field" {
            foreach ($field in @($Server.Credentials)) {
                $fieldName = [string]$field.Name
                if ([string]::IsNullOrWhiteSpace($fieldName)) {
                    continue
                }

                $sharedFrom = if ($field.ContainsKey("SharedFrom")) { [string]$field.SharedFrom } else { "" }
                if (-not [string]::IsNullOrWhiteSpace($sharedFrom) -and $SharedCredentials.ContainsKey($sharedFrom)) {
                    $result.Values[$fieldName] = [string]$SharedCredentials[$sharedFrom]
                    continue
                }

                $defaultValue = if ($field.ContainsKey("Default")) { [string]$field.Default } else { "" }
                $required = if ($field.ContainsKey("Required")) { [bool]$field.Required } else { $false }
                $secret = if ($field.ContainsKey("Secret")) { [bool]$field.Secret } else { $false }
                $fieldLabel = if ($field.ContainsKey("Label") -and $field.Label) { [string]$field.Label } else { $fieldName }

                $value = Read-McpCredentialValue `
                    -Label $fieldLabel `
                    -Secret $secret `
                    -Required $required `
                    -DefaultValue $defaultValue

                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $result.Values[$fieldName] = $value
                    if ($field.ContainsKey("Shared") -and [bool]$field.Shared) {
                        $result.Shared[$fieldName] = $value
                    }
                }
            }
        }
        "args-multi" {
            foreach ($argCredential in @($Server.ArgsCredentials)) {
                if ($argCredential.ContainsKey("Url") -and $argCredential["Url"]) {
                    Write-UiInfo "$($argCredential.Label) 获取地址: $($argCredential["Url"])"
                }

                $value = Read-McpCredentialValue `
                    -Label ([string]$argCredential.Label) `
                    -Secret ([bool]$argCredential.Secret) `
                    -Required ([bool]$argCredential.Required)

                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $result.Values[[string]$argCredential.ArgName] = $value
                }
            }
        }
        "args-token" {
            $tokenLabel = if ($Server.TokenLabel) { [string]$Server.TokenLabel } else { "Token" }
            $tokenValue = Read-McpCredentialValue -Label $tokenLabel -Secret $true -Required $true
            $result.Values["token"] = $tokenValue
        }
        "env-file" {
            $envFile = $Server.EnvFile
            if (-not $envFile) {
                throw "$($Server.Name) 缺少 EnvFile 配置"
            }

            $sharedCredentialName = if ($envFile.ContainsKey("SharedCredentialName")) { [string]$envFile.SharedCredentialName } else { "" }
            $sharedKeyValue = ""

            if (-not [string]::IsNullOrWhiteSpace($sharedCredentialName) -and $SharedCredentials.ContainsKey($sharedCredentialName)) {
                $sharedKeyValue = [string]$SharedCredentials[$sharedCredentialName]
                Write-UiSuccess "复用共享凭据: $sharedCredentialName"
            }
            else {
                $sharedLabel = if ($envFile.SharedKeyLabel) { [string]$envFile.SharedKeyLabel } else { "共享 API Key" }
                $sharedKeyValue = Read-McpCredentialValue -Label $sharedLabel -Secret $true -Required $true
                if (-not [string]::IsNullOrWhiteSpace($sharedCredentialName)) {
                    $result.Shared[$sharedCredentialName] = $sharedKeyValue
                }
            }

            foreach ($sharedKeyField in @($envFile.SharedKeyFields)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$sharedKeyField)) {
                    $result.EnvFileValues[[string]$sharedKeyField] = $sharedKeyValue
                }
            }

            foreach ($field in @($envFile.Fields)) {
                $fieldKey = [string]$field.Key
                if ([string]::IsNullOrWhiteSpace($fieldKey)) {
                    continue
                }

                if ($result.EnvFileValues.ContainsKey($fieldKey)) {
                    continue
                }

                $defaultValue = if ($field.ContainsKey("Default")) { [string]$field.Default } else { "" }
                $required = if ($field.ContainsKey("Required")) { [bool]$field.Required } else { $false }
                $secret = if ($field.ContainsKey("Secret")) { [bool]$field.Secret } else { $false }
                $fieldLabel = if ($field.ContainsKey("Label") -and $field.Label) { [string]$field.Label } else { $fieldKey }

                $fieldValue = Read-McpCredentialValue -Label $fieldLabel -Secret $secret -Required $required -DefaultValue $defaultValue
                if (-not [string]::IsNullOrWhiteSpace($fieldValue)) {
                    $result.EnvFileValues[$fieldKey] = $fieldValue
                }
            }
        }
        default {
            throw "不支持的凭据类型: $credentialType"
        }
    }

    return $result
}

function New-McpSettingsEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerId,
        [Parameter(Mandatory = $true)]
        [hashtable]$Server,
        [Parameter(Mandatory = $true)]
        [hashtable]$Credentials
    )

    $mcpType = if ($Server.McpType) { [string]$Server.McpType } else { "stdio" }
    $credentialType = if ($Server.CredentialType) { [string]$Server.CredentialType } else { "none" }

    switch ($mcpType) {
        "software" {
            return $null
        }
        "http" {
            if ($credentialType -eq "url-embedded") {
                if (-not $Server.UrlTemplate) {
                    throw "$ServerId 缺少 UrlTemplate"
                }

                $resolvedUrl = [string]$Server.UrlTemplate
                foreach ($credentialName in $Credentials.Keys) {
                    $placeholder = "{0}{1}{2}" -f "{", $credentialName, "}"
                    $escapedValue = [System.Uri]::EscapeDataString([string]$Credentials[$credentialName])
                    $resolvedUrl = $resolvedUrl -replace [regex]::Escape($placeholder), $escapedValue
                }

                if ($resolvedUrl -match "\{[A-Za-z0-9_]+\}") {
                    # HC-M10: 掩码凭据值，避免异常消息泄露敏感信息
                    $maskedUrl = $resolvedUrl
                    foreach ($credName in $Credentials.Keys) {
                        $escapedVal = [System.Uri]::EscapeDataString([string]$Credentials[$credName])
                        if ($escapedVal) {
                            $maskedUrl = $maskedUrl -replace [regex]::Escape($escapedVal), "***"
                        }
                    }
                    throw "$ServerId 的 URL 仍包含未替换占位符: $maskedUrl"
                }

                return @{
                    type = "http"
                    url = $resolvedUrl
                }
            }

            if (-not $Server.Url) {
                throw "$ServerId 缺少 Url"
            }

            return @{
                type = "http"
                url = [string]$Server.Url
            }
        }
        "stdio" {
            if (-not $Server.Command) {
                throw "$ServerId 缺少 Command"
            }

            $args = @()
            foreach ($arg in @($Server.Args)) {
                $args += [string]$arg
            }

            $entry = @{
                command = [string]$Server.Command
                args = $args
            }

            switch ($credentialType) {
                "single-key" {
                    $apiKeyName = [string]$Server.ApiKeyName
                    if (-not $Credentials.ContainsKey($apiKeyName)) {
                        throw "$ServerId 缺少凭据: $apiKeyName"
                    }

                    $entry["env"] = @{
                        $apiKeyName = [string]$Credentials[$apiKeyName]
                    }
                }
                "multi-field" {
                    $envMap = @{}
                    foreach ($credentialKey in $Credentials.Keys) {
                        $credentialValue = [string]$Credentials[$credentialKey]
                        if (-not [string]::IsNullOrWhiteSpace($credentialValue)) {
                            $envMap[$credentialKey] = $credentialValue
                        }
                    }
                    if ($envMap.Count -gt 0) {
                        $entry["env"] = $envMap
                    }
                }
                "args-multi" {
                    foreach ($argCredential in @($Server.ArgsCredentials)) {
                        $argName = [string]$argCredential.ArgName
                        $required = if ($argCredential.ContainsKey("Required")) { [bool]$argCredential.Required } else { $false }

                        if (-not $Credentials.ContainsKey($argName)) {
                            if ($required) {
                                throw "$ServerId 缺少参数凭据: $argName"
                            }
                            continue
                        }

                        $argValue = [string]$Credentials[$argName]
                        if ($required -and [string]::IsNullOrWhiteSpace($argValue)) {
                            throw "$ServerId 参数凭据为空: $argName"
                        }

                        if (-not [string]::IsNullOrWhiteSpace($argValue)) {
                            $entry["args"] += @($argName, $argValue)
                        }
                    }
                }
                "args-token" {
                    if (-not $Credentials.ContainsKey("token")) {
                        throw "$ServerId 缺少 token"
                    }

                    $tokenValue = [string]$Credentials["token"]
                    if ([string]::IsNullOrWhiteSpace($tokenValue)) {
                        throw "$ServerId token 为空"
                    }

                    $entry["args"] += "$($Server.TokenArg)=$tokenValue"
                }
            }

            return $entry
        }
        default {
            throw "不支持的 MCP 类型: $mcpType"
        }
    }
}

function Install-McpSoftware {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerId,
        [Parameter(Mandatory = $true)]
        [hashtable]$Server
    )

    $result = @{
        Success = $true
        Method = "none"
        Message = ""
    }

    if ($Server.McpType -ne "software") {
        return $result
    }

    $install = $Server.SoftwareInstall
    if (-not $install) {
        throw "$ServerId 缺少 SoftwareInstall 配置"
    }

    if (Test-CommandAvailable -Command "winget") {
        try {
            if ($install.WingetSearch) {
                $wingetArgs = @(
                    "install",
                    "--name", $install.WingetSearch,
                    "-e",
                    "--accept-package-agreements",
                    "--accept-source-agreements",
                    "--disable-interactivity"
                )
                $wingetResult = Invoke-ExternalCommand -Command "winget" -Arguments $wingetArgs -TimeoutSeconds 300
                if (-not $wingetResult.Success) {
                    throw "winget 按名称安装失败"
                }
            }
            else {
                throw "未配置 WingetSearch"
            }

            $result.Method = "winget"
            $result.Message = "winget 安装成功"
            return $result
        }
        catch {
            Write-UiWarning "$($Server.Name) winget 安装失败，将尝试下载方式: $($_.Exception.Message)"
        }
    }

    if ($install.DownloadUrl) {
        try {
            $downloadDir = "$env:TEMP\ClaudeEnvInstaller"
            if (-not (Test-Path $downloadDir)) {
                New-Item -Path $downloadDir -ItemType Directory -Force | Out-Null
            }

            $fileName = Split-Path -Path ([string]$install.DownloadUrl) -Leaf
            if ([string]::IsNullOrWhiteSpace($fileName)) {
                $fileName = "$ServerId-installer.exe"
            }
            $downloadPath = Join-Path $downloadDir $fileName

            # 使用统一的下载函数
            $downloadResult = Invoke-FileDownload -Url $install.DownloadUrl -OutputPath $downloadPath -Description "$($Server.Name) 安装程序"

            if (-not $downloadResult.Success) {
                throw "下载失败: $($downloadResult.ErrorMessage)"
            }

            $process = Start-Process -FilePath $downloadPath -PassThru -Wait

            if ($process -and $process.ExitCode -ne 0) {
                throw "安装程序退出码非 0: $($process.ExitCode)"
            }

            $result.Method = "download"
            $result.Message = "下载安装成功"
            return $result
        }
        catch {
            Write-UiWarning "$($Server.Name) 下载安装失败，将进入引导安装: $($_.Exception.Message)"
        }
    }

    Write-UiPrimary "请手动安装 $($Server.Name)"
    if ($install.GuideUrl) {
        Write-UiInfo "安装指引: $($install.GuideUrl)"
    }
    Read-Host "安装完成后按回车继续..."

    $result.Method = "guide"
    $result.Message = "已切换为引导安装"
    return $result
}

function Write-McpEnvFile {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Server,
        [Parameter(Mandatory = $true)]
        [hashtable]$EnvValues
    )

    try {
        if (-not $Server.EnvFile) {
            throw "缺少 EnvFile 配置"
        }

        $envPath = [string]$Server.EnvFile.Path
        if ([string]::IsNullOrWhiteSpace($envPath)) {
            throw "EnvFile.Path 为空"
        }

        $envDir = Split-Path -Path $envPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($envDir) -and -not (Test-Path $envDir)) {
            New-Item -Path $envDir -ItemType Directory -Force | Out-Null
        }

        $lines = @()
        if (Test-Path $envPath) {
            $existingLines = Get-Content -Path $envPath -ErrorAction SilentlyContinue
            if ($null -ne $existingLines) {
                $lines = @($existingLines)
            }
        }

        $keyLineIndex = @{}
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
                $keyLineIndex[$matches[1]] = $i
            }
        }

        foreach ($key in $EnvValues.Keys) {
            $value = [string]$EnvValues[$key]
            $value = $value -replace "`r", "" -replace "`n", ""
            if ([string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            $line = "$key=$value"
            if ($keyLineIndex.ContainsKey($key)) {
                $lines[[int]$keyLineIndex[$key]] = $line
            }
            else {
                $lines += $line
            }
        }

        $writeOk = Write-FileAtomically -FilePath $envPath -Content $lines
        if (-not $writeOk) {
            throw "env 文件原子写入失败: $envPath"
        }

        return @{ Success = $true; Path = $envPath }
    }
    catch {
        return @{
            Success = $false
            Path = ""
            ErrorMessage = $_.Exception.Message
        }
    }
}

# ─── Task 2.6: Get-McpStatus + Show-McpStatusTable ──────────────────────────

function Get-McpStatus {
    <#
    .SYNOPSIS
    计算所有 MCP Server 的状态列表（ADR-06 优先级）
    .RETURNS
    hashtable[] - @{ Id; Name; Status; McpType; Category; HasCredentials }
    #>

    # 读取 .claude.json
    $claudeJsonPath = "$(Get-UserHome)\.claude.json"
    $claudeServers = @{}
    if (Test-Path $claudeJsonPath) {
        try {
            $claudeJson = Get-Content -Path $claudeJsonPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($claudeJson -and $claudeJson.ContainsKey("mcpServers") -and $claudeJson["mcpServers"]) {
                $claudeServers = $claudeJson["mcpServers"]
            }
        } catch { }
    }

    # 读取 vault
    $meta = Read-McpMeta

    # 收集所有 server ID（union）
    $allIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $claudeServers.Keys) { [void]$allIds.Add($id) }
    if ($script:McpServers) {
        foreach ($id in $script:McpServers.Keys) { [void]$allIds.Add($id) }
    }
    foreach ($id in $meta["servers"].Keys) { [void]$allIds.Add($id) }

    # 判定每个 server 的状态
    $results = @()
    foreach ($id in $allIds) {
        $inClaudeJson = $claudeServers.ContainsKey($id)
        $inMcpServers = ($script:McpServers -and $script:McpServers.Contains($id))
        $inMeta = $meta["servers"].ContainsKey($id)
        $isDisabled = ($inMeta -and $meta["servers"][$id] -is [hashtable] -and
                       $meta["servers"][$id].ContainsKey("disabled") -and $meta["servers"][$id]["disabled"])

        # ADR-06 优先级：Custom > Disabled > Active > Missing
        $status = if ($inClaudeJson -and -not $inMcpServers) { "Custom" }
                  elseif ($isDisabled) { "Disabled" }
                  elseif ($inClaudeJson -and $inMcpServers) { "Active" }
                  elseif ($inMcpServers -and -not $inClaudeJson -and -not $isDisabled) { "Missing" }
                  else { "Unknown" }

        # 获取名称和类型
        $name = $id
        $mcpType = ""
        $category = ""
        $hasCredentials = $false

        if ($inMcpServers) {
            $def = $script:McpServers[$id]
            $name = if ($def.Name) { $def.Name } else { $id }
            $mcpType = if ($def.McpType) { $def.McpType } else { "" }
            $category = if ($def.Category) { $def.Category } else { "" }
            $hasCredentials = ($def.CredentialType -ne "none")
        }
        elseif ($inMeta -and $meta["servers"][$id] -is [hashtable]) {
            $hasCredentials = $meta["servers"][$id].ContainsKey("credentials") -and $meta["servers"][$id]["credentials"]
        }

        $results += @{
            Id             = $id
            Name           = $name
            Status         = $status
            McpType        = $mcpType
            Category       = $category
            HasCredentials = $hasCredentials
        }
    }

    # 按状态排序：Custom → Active → Disabled → Missing → Unknown
    $statusOrder = @{ "Custom" = 0; "Active" = 1; "Disabled" = 2; "Missing" = 3; "Unknown" = 4 }
    $results = @($results | Sort-Object { $statusOrder[$_.Status] })

    return $results
}

function Show-McpStatusTable {
    <#
    .SYNOPSIS
    格式化输出 MCP 状态表格（带 ANSI 着色）
    .PARAMETER StatusList
    Get-McpStatus 返回的状态数组
    #>
    param(
        [Parameter(Mandatory = $true)]
        [array]$StatusList
    )

    if ($StatusList.Count -eq 0) {
        Write-UiDim "没有 MCP Server"
        return
    }

    Write-Host ""
    Write-UiPrimary "MCP Server 状态："
    Write-Host ""

    # 列宽定义（按显示宽度，CJK 字符占 2 列）
    $colWidths = @(12, 20, 10, 15, 5)

    # 表头（使用 CJK 感知填充）
    $headerLine = "  " +
        (Format-DisplayPad "状态" $colWidths[0]) + " " +
        (Format-DisplayPad "名称" $colWidths[1]) + " " +
        (Format-DisplayPad "类型" $colWidths[2]) + " " +
        (Format-DisplayPad "分类" $colWidths[3]) + " " +
        (Format-DisplayPad "凭据" $colWidths[4])
    Write-UiInfo $headerLine
    $sepWidth = ($colWidths | Measure-Object -Sum).Sum + $colWidths.Count - 1
    Write-UiDim ("  " + [string]::new("-", $sepWidth))

    foreach ($item in $StatusList) {
        $statusText = "[$($item.Status)]"
        $credText = if ($item.HasCredentials) { "有" } else { "-" }

        $color = switch ($item.Status) {
            "Active"   { "Success" }
            "Disabled" { "Warning" }
            "Missing"  { "Dim" }
            "Custom"   { "Primary" }
            default    { "Info" }
        }

        $line = "  " +
            (Format-DisplayPad $statusText $colWidths[0]) + " " +
            (Format-DisplayPad "$($item.Name)" $colWidths[1]) + " " +
            (Format-DisplayPad "$($item.McpType)" $colWidths[2]) + " " +
            (Format-DisplayPad "$($item.Category)" $colWidths[3]) + " " +
            (Format-DisplayPad $credText $colWidths[4])
        Write-UiOutput $line -Type $color
    }
    Write-Host ""
}

# ─── Task 2.7: Disable-McpServer ────────────────────────────────────────────

function Disable-McpServer {
    <#
    .SYNOPSIS
    禁用 MCP Server：从 .claude.json 移除 + 保存到 vault + 清理 permissions
    .PARAMETER ServerId
    server ID
    .RETURNS
    @{ Success; ServerId; Status }
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerId
    )

    return Invoke-WithMcpLock {
        $claudeJsonPath = "$(Get-UserHome)\.claude.json"

        # 读取 .claude.json
        $claudeJson = @{}
        if (Test-Path $claudeJsonPath) {
            $claudeJson = Get-Content -Path $claudeJsonPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        if (-not $claudeJson) { $claudeJson = @{} }
        if (-not $claudeJson.ContainsKey("mcpServers")) { $claudeJson["mcpServers"] = @{} }

        # 检查 server 是否存在于 .claude.json
        if (-not $claudeJson["mcpServers"].ContainsKey($ServerId)) {
            # 检查 meta 是否已标记 disabled
            $meta = Read-McpMeta
            if ($meta["servers"].ContainsKey($ServerId) -and
                $meta["servers"][$ServerId] -is [hashtable] -and
                $meta["servers"][$ServerId].ContainsKey("disabled") -and
                $meta["servers"][$ServerId]["disabled"]) {
                # 已禁用，幂等返回
                return @{ Success = $true; ServerId = $ServerId; Status = "Disabled" }
            }
            Write-UiWarning "MCP Server '$ServerId' 未在 .claude.json 中找到"
            return @{ Success = $false; ServerId = $ServerId; Status = "NotFound" }
        }

        # 保存完整配置到 vault
        $existingConfig = $claudeJson["mcpServers"][$ServerId]
        $meta = Read-McpMeta

        # 提取凭据
        $credentials = @{}
        if ($existingConfig -is [hashtable] -and $existingConfig.ContainsKey("env") -and $existingConfig["env"]) {
            $credentials = $existingConfig["env"]
        }

        # 计算定义哈希
        $defHash = ""
        if ($script:McpServers -and $script:McpServers.Contains($ServerId)) {
            $defHash = Get-McpDefinitionHash $script:McpServers[$ServerId]
        }

        # 从 settings.json permissions 移除匹配项（保存到 vault 以便恢复）
        $settingsPath = "$(Get-UserHome)\.claude\settings.json"
        $removedPermissions = @()
        if (Test-Path $settingsPath) {
            $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue
            if ($settings -and $settings.ContainsKey("permissions") -and $settings["permissions"].ContainsKey("allow")) {
                $mcpPerm = "mcp__${ServerId}"
                if ($settings["permissions"]["allow"] -ccontains $mcpPerm) {
                    $removedPermissions = @($mcpPerm)
                }
                $settings["permissions"]["allow"] = @($settings["permissions"]["allow"] | Where-Object { $_ -cne $mcpPerm })
                # 原子写入 settings.json
                $settingsJson = $settings | ConvertTo-Json -Depth 10
                $null = Write-FileAtomically -FilePath $settingsPath -Content $settingsJson
            }
        }

        # 保存到 vault（$removedPermissions 已就绪）— 先写 vault 再删 .claude.json，确保数据不丢失
        $meta["servers"][$ServerId] = @{
            disabled       = $true
            credentials    = $credentials
            config         = $existingConfig
            permissions    = $removedPermissions
            definitionHash = $defHash
            updatedAt      = (Get-Date).ToUniversalTime().ToString("o")
        }
        $null = Write-McpMeta $meta

        # 从 .claude.json 移除（vault 已安全写入）
        $claudeJson["mcpServers"].Remove($ServerId)
        $claudeJsonContent = $claudeJson | ConvertTo-Json -Depth 10
        $null = Write-FileAtomically -FilePath $claudeJsonPath -Content $claudeJsonContent

        Write-UiSuccess "MCP Server '$ServerId' 已禁用"

        # 同步 MCP Rules 文件
        $null = Sync-AllMcpRules

        return @{ Success = $true; ServerId = $ServerId; Status = "Disabled" }
    }
}

# ─── Task 2.8: Enable-McpServer ─────────────────────────────────────────────

function Enable-McpServer {
    <#
    .SYNOPSIS
    启用 MCP Server：从 vault 恢复到 .claude.json + 恢复 permissions
    .PARAMETER ServerId
    server ID
    .RETURNS
    @{ Success; ServerId; Status }
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerId
    )

    return Invoke-WithMcpLock {
        $meta = Read-McpMeta

        # 检查是否处于禁用状态
        if (-not $meta["servers"].ContainsKey($ServerId) -or
            -not ($meta["servers"][$ServerId] -is [hashtable]) -or
            -not $meta["servers"][$ServerId].ContainsKey("disabled") -or
            -not $meta["servers"][$ServerId]["disabled"]) {
            # 非禁用状态，幂等返回
            return @{ Success = $true; ServerId = $ServerId; Status = "Active" }
        }

        $vaultEntry = $meta["servers"][$ServerId]

        # 检查 definitionHash 变更
        if ($script:McpServers -and $script:McpServers.Contains($ServerId)) {
            $currentHash = Get-McpDefinitionHash $script:McpServers[$ServerId]
            if ($vaultEntry.ContainsKey("definitionHash") -and
                $vaultEntry["definitionHash"] -ne "" -and
                $vaultEntry["definitionHash"] -ne $currentHash) {
                Write-UiWarning "MCP 定义已变更，使用最新定义恢复"
            }
        }

        # 获取凭据
        $credentials = @{}
        if ($vaultEntry.ContainsKey("credentials") -and $vaultEntry["credentials"] -is [hashtable]) {
            $credentials = $vaultEntry["credentials"]
        }

        # 重建 server 配置
        $serverConfig = $null
        if ($script:McpServers -and $script:McpServers.Contains($ServerId)) {
            # 使用最新定义 + vault 凭据重建
            try {
                $serverConfig = New-McpSettingsEntry -ServerId $ServerId -Server $script:McpServers[$ServerId] -Credentials $credentials
                # 恢复凭据到 env（仅在重建成功时）
                if ($serverConfig -and $credentials.Count -gt 0) {
                    if (-not $serverConfig.ContainsKey("env")) {
                        $serverConfig["env"] = @{}
                    }
                    foreach ($key in $credentials.Keys) {
                        $serverConfig["env"][$key] = $credentials[$key]
                    }
                }
            }
            catch {
                Write-UiWarning "重建 MCP 配置失败: $($_.Exception.Message)"
            }
            # 重建失败或返回 $null 时（如 software 类型），回退到 vault 保存的原始配置
            if (-not $serverConfig -and $vaultEntry.ContainsKey("config") -and $vaultEntry["config"]) {
                Write-UiPrimary "使用 vault 保存的原始配置恢复"
                $serverConfig = $vaultEntry["config"]
            }
        }
        elseif ($vaultEntry.ContainsKey("config") -and $vaultEntry["config"]) {
            # 使用 vault 中保存的原始配置
            $serverConfig = $vaultEntry["config"]
        }

        if (-not $serverConfig) {
            Write-UiDanger "无法恢复 MCP Server '$ServerId'：缺少配置信息"
            return @{ Success = $false; ServerId = $ServerId; Status = "Error" }
        }

        # 写入 .claude.json
        $claudeJsonPath = "$(Get-UserHome)\.claude.json"
        $claudeJson = @{}
        if (Test-Path $claudeJsonPath) {
            $claudeJson = Get-Content -Path $claudeJsonPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        if (-not $claudeJson) { $claudeJson = @{} }
        if (-not $claudeJson.ContainsKey("mcpServers")) { $claudeJson["mcpServers"] = @{} }

        $claudeJson["mcpServers"][$ServerId] = $serverConfig

        # 原子写入 .claude.json
        $claudeJsonContent = $claudeJson | ConvertTo-Json -Depth 10
        $null = Write-FileAtomically -FilePath $claudeJsonPath -Content $claudeJsonContent

        # 恢复 permissions（优先从 vault 恢复具体权限）
        $settingsPath = "$(Get-UserHome)\.claude\settings.json"
        if (Test-Path $settingsPath) {
            $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue
            if ($settings) {
                if (-not $settings.ContainsKey("permissions")) { $settings["permissions"] = @{} }
                if (-not $settings["permissions"].ContainsKey("allow")) { $settings["permissions"]["allow"] = @() }

                # 从 vault 恢复保存的具体权限
                $vaultPerms = @()
                if ($vaultEntry.ContainsKey("permissions") -and $vaultEntry["permissions"]) {
                    $vaultPerms = @($vaultEntry["permissions"])
                }

                $permChanged = $false
                if ($vaultPerms.Count -gt 0) {
                    foreach ($perm in $vaultPerms) {
                        if ($settings["permissions"]["allow"] -notcontains $perm) {
                            $settings["permissions"]["allow"] += $perm
                            $permChanged = $true
                        }
                    }
                } else {
                    # 无保存的权限记录，确保 Server 级权限存在
                    $mcpPerm = "mcp__${ServerId}"
                    if ($settings["permissions"]["allow"] -notcontains $mcpPerm) {
                        $settings["permissions"]["allow"] += $mcpPerm
                        $permChanged = $true
                    }
                }

                if ($permChanged) {
                    $settingsJson = $settings | ConvertTo-Json -Depth 10
                    $null = Write-FileAtomically -FilePath $settingsPath -Content $settingsJson
                }
            }
        }

        # 更新 vault
        $meta["servers"][$ServerId]["disabled"] = $false
        if ($script:McpServers -and $script:McpServers.Contains($ServerId)) {
            $meta["servers"][$ServerId]["definitionHash"] = Get-McpDefinitionHash $script:McpServers[$ServerId]
        }
        $meta["servers"][$ServerId]["updatedAt"] = (Get-Date).ToUniversalTime().ToString("o")
        $null = Write-McpMeta $meta

        Write-UiSuccess "MCP Server '$ServerId' 已启用"

        # 同步 MCP Rules 文件
        $null = Sync-AllMcpRules

        return @{ Success = $true; ServerId = $ServerId; Status = "Active" }
    }
}

# ─── Task 2.9: Remove-McpServer ─────────────────────────────────────────────

function Remove-McpServer {
    <#
    .SYNOPSIS
    删除 MCP Server：从所有文件清理 + 确认提示
    .PARAMETER ServerId
    server ID
    .RETURNS
    @{ Success; ServerId; Status }
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerId
    )

    # 状态检查
    $statuses = Get-McpStatus
    $serverStatus = $statuses | Where-Object { $_.Id -eq $ServerId } | Select-Object -First 1

    if (-not $serverStatus) {
        Write-UiWarning "MCP Server '$ServerId' 不存在"
        return @{ Success = $false; ServerId = $ServerId; Status = "NotFound" }
    }

    if ($serverStatus.Status -eq "Missing") {
        # 检查 meta 中有无记录
        $meta = Read-McpMeta
        if ($meta["servers"].ContainsKey($ServerId)) {
            # 孤立记录也需确认（HC-M5）
            $orphanConfirm = Show-SingleSelectMenu `
                -Title "发现 '$ServerId' 的孤立元数据记录，确定要清理？" `
                -Options @("是，清理", "否，取消")

            if ($orphanConfirm -ne 0) {
                Write-UiDim "已取消清理"
                return @{ Success = $false; ServerId = $ServerId; Status = "Cancelled" }
            }

            return Invoke-WithMcpLock {
                $m = Read-McpMeta
                $m["servers"].Remove($ServerId)
                $null = Write-McpMeta $m
                Write-UiSuccess "已清理 '$ServerId' 的孤立元数据"
                return @{ Success = $true; ServerId = $ServerId; Status = "Removed" }
            }
        }
        Write-UiWarning "MCP Server '$ServerId' 未安装"
        return @{ Success = $false; ServerId = $ServerId; Status = "Missing" }
    }

    # Custom 类型额外确认
    if ($serverStatus.Status -eq "Custom") {
        Write-UiWarning "此 MCP 非 CCQ 管理，删除后无法通过 CCQ 恢复"
    }

    # 确认
    $confirmIndex = Show-SingleSelectMenu `
        -Title "确定要删除 $ServerId MCP Server？" `
        -Options @("是，删除", "否，取消")

    if ($confirmIndex -ne 0) {
        Write-UiDim "已取消删除"
        return @{ Success = $false; ServerId = $ServerId; Status = "Cancelled" }
    }

    return Invoke-WithMcpLock {
        $claudeJsonPath = "$(Get-UserHome)\.claude.json"
        $settingsPath = "$(Get-UserHome)\.claude\settings.json"

        # 1. 从 .claude.json 移除
        if (Test-Path $claudeJsonPath) {
            $claudeJson = Get-Content -Path $claudeJsonPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($claudeJson -and $claudeJson.ContainsKey("mcpServers") -and
                $claudeJson["mcpServers"].ContainsKey($ServerId)) {
                $claudeJson["mcpServers"].Remove($ServerId)
            }

            # 2. 从 permissions 移除匹配项
            if (Test-Path $settingsPath) {
                $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue
                if ($settings -and $settings.ContainsKey("permissions") -and
                    $settings["permissions"].ContainsKey("allow")) {
                    $mcpPerm = "mcp__${ServerId}"
                    $settings["permissions"]["allow"] = @($settings["permissions"]["allow"] | Where-Object { $_ -cne $mcpPerm })
                    $settingsJson = $settings | ConvertTo-Json -Depth 10
                    $null = Write-FileAtomically -FilePath $settingsPath -Content $settingsJson
                }
            }

            # 3. 原子写入 .claude.json
            $claudeJsonContent = $claudeJson | ConvertTo-Json -Depth 10
            $null = Write-FileAtomically -FilePath $claudeJsonPath -Content $claudeJsonContent
        }

        # 4. 从 vault 移除
        $meta = Read-McpMeta
        if ($meta["servers"].ContainsKey($ServerId)) {
            $meta["servers"].Remove($ServerId)
        }

        # 5. 写入 vault
        $null = Write-McpMeta $meta

        Write-UiSuccess "MCP Server '$ServerId' 已删除"

        # 同步 MCP Rules 文件
        $null = Sync-AllMcpRules

        return @{ Success = $true; ServerId = $ServerId; Status = "Removed" }
    }
}

# ─── Install-McpSingleServer（单服务器完整安装管道） ──────────────────────────

function Install-McpSingleServer {
    <#
    .SYNOPSIS
    安装单个 MCP Server（完整 5 阶段管道）
    被 Invoke-McpToggle（Missing + 需凭据）和 Install-Mcp（批量循环）调用
    .PARAMETER ServerId
    注册表中的 Server ID
    .RETURNS
    @{ Success; ServerId; Status; ErrorMessage }
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerId
    )

    if (-not $script:McpServers.Contains($ServerId)) {
        return @{ Success = $false; ServerId = $ServerId; Status = "Unknown"; ErrorMessage = "未在注册表中定义" }
    }

    $server = $script:McpServers[$ServerId]

    try {
        # Phase 1: 运行时依赖
        $depResult = Install-McpRuntimeDeps -Server $server
        if (@($depResult.Installed).Count -gt 0) {
            Write-UiSuccess "$($server.Name) 依赖安装完成: $(@($depResult.Installed) -join ', ')"
        }

        # Phase 2: 预安装
        $preResult = Invoke-McpPreInstall -ServerId $ServerId -Server $server
        if ($preResult.Message -and $preResult.Message -ne "无需预安装") {
            Write-UiSuccess "$($server.Name) $($preResult.Message)"
        }

        # Phase 3: 凭据收集（含 vault 历史凭据自动填充）
        $credentials = @{}
        $envFileValues = @{}
        $credentialType = if ($server.CredentialType) { [string]$server.CredentialType } else { "none" }

        if ($credentialType -ne "none") {
            # 先查 vault 历史凭据
            $useVaultCredentials = $false
            try {
                $meta = Read-McpMeta
                if ($meta.ContainsKey("servers") -and
                    $meta.servers -is [hashtable] -and
                    $meta.servers.ContainsKey($ServerId) -and
                    $meta.servers[$ServerId] -is [hashtable] -and
                    $meta.servers[$ServerId].ContainsKey("credentials") -and
                    $meta.servers[$ServerId].credentials -is [hashtable]) {

                    $vaultCred = $meta.servers[$ServerId].credentials
                    $hasValues = $vaultCred.ContainsKey("values") -and $vaultCred.values -is [hashtable] -and $vaultCred.values.Count -gt 0
                    $hasEnvValues = $vaultCred.ContainsKey("envFileValues") -and $vaultCred.envFileValues -is [hashtable] -and $vaultCred.envFileValues.Count -gt 0

                    if ($hasValues -or $hasEnvValues) {
                        $maskedKeys = @()
                        if ($hasValues) {
                            $maskedKeys += @($vaultCred.values.Keys | ForEach-Object { "$_=***" })
                        }
                        Write-UiInfo "检测到 $($server.Name) 的历史凭据 ($($maskedKeys -join ', '))"
                        Write-Host -NoNewline "  是否使用历史凭据？[Y/n]: "
                        $answer = Read-Host
                        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^[Yy]') {
                            if ($hasValues) { $credentials = $vaultCred.values }
                            if ($hasEnvValues) { $envFileValues = $vaultCred.envFileValues }
                            $useVaultCredentials = $true
                            Write-UiSuccess "$($server.Name) 已使用历史凭据"
                        }
                    }
                }
            }
            catch {
                Write-UiWarning "vault 读取失败，跳过历史凭据检测: $($_.Exception.Message)"
            }

            # 无历史则走交互式收集
            if (-not $useVaultCredentials) {
                $credentialResult = Get-McpCredentials -ServerId $ServerId -Server $server -SharedCredentials @{}
                $credentials = $credentialResult.Values
                $envFileValuesCount = if ($credentialResult.ContainsKey("EnvFileValues") -and $credentialResult.EnvFileValues) { @($credentialResult.EnvFileValues.Keys).Count } else { 0 }
                if ($envFileValuesCount -gt 0) {
                    $envFileValues = $credentialResult.EnvFileValues
                }
            }
        }

        # Phase 4: 软件安装（仅 software 类型）
        if ($server.McpType -eq "software") {
            Install-McpSoftware -ServerId $ServerId -Server $server | Out-Null
        }

        # Phase 5: 配置写入
        # 5a. env file（env-file 类型）
        if ($credentialType -eq "env-file" -and $envFileValues.Count -gt 0) {
            $envWriteResult = Write-McpEnvFile -Server $server -EnvValues $envFileValues
            if ($envWriteResult.Success) {
                Write-UiSuccess "已写入 $($server.Name) .env 文件: $($envWriteResult.Path)"
            }
            else {
                Write-UiWarning "$($server.Name) .env 写入失败: $($envWriteResult.ErrorMessage)"
            }
        }

        # 5b. .claude.json — New-McpSettingsEntry → 合并写入
        $entry = New-McpSettingsEntry -ServerId $ServerId -Server $server -Credentials $credentials
        if ($entry) {
            $cjPath = "$(Get-UserHome)\.claude.json"
            $cj = @{}
            if (Test-Path $cjPath) {
                $cj = Get-Content -Path $cjPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                if (-not $cj) { $cj = @{} }
            }
            if (-not $cj.ContainsKey("mcpServers")) { $cj["mcpServers"] = @{} }
            $cj["mcpServers"][$ServerId] = $entry
            $writeOk = Write-FileAtomically -FilePath $cjPath -Content ($cj | ConvertTo-Json -Depth 10)
            if (-not $writeOk) {
                throw "更新 .claude.json 失败"
            }
        }

        # 5c. settings.json — 补充 mcp__${ServerId} 权限
        $settingsPath = Get-ClaudeSettingsPath
        $settings = @{}
        if (Test-Path $settingsPath) {
            $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if (-not $settings) { $settings = @{} }
        }
        if (-not $settings.ContainsKey("permissions")) { $settings["permissions"] = @{} }
        if (-not $settings["permissions"].ContainsKey("allow")) { $settings["permissions"]["allow"] = @() }
        if (-not ($settings["permissions"]["allow"] -is [System.Collections.IList])) {
            $settings["permissions"]["allow"] = @($settings["permissions"]["allow"])
        }
        $mcpPerm = "mcp__${ServerId}"
        if ($settings["permissions"]["allow"] -notcontains $mcpPerm) {
            $settings["permissions"]["allow"] += $mcpPerm
            $settingsJson = $settings | ConvertTo-Json -Depth 10
            $writeOk = Write-FileAtomically -FilePath $settingsPath -Content @($settingsJson)
            if (-not $writeOk) {
                Write-UiWarning "settings.json 权限写入失败"
            }
        }

        # 5d. vault — 持久化凭据 + definitionHash
        try {
            $null = Invoke-WithMcpLock {
                $vaultMeta = Read-McpMeta
                $cred = @{}
                if ($credentials.Count -gt 0) { $cred["values"] = $credentials }
                if ($envFileValues.Count -gt 0) { $cred["envFileValues"] = $envFileValues }
                $vaultMeta.servers[$ServerId] = @{
                    disabled       = $false
                    credentials    = $cred
                    definitionHash = Get-McpDefinitionHash $server
                    updatedAt      = (Get-Date).ToUniversalTime().ToString("o")
                }
                Write-McpMeta $vaultMeta
            }
        }
        catch {
            Write-UiWarning "vault 写入失败（不影响 MCP 配置）: $($_.Exception.Message)"
        }

        # 5e. Sync-AllMcpRules
        $syncResult = Sync-AllMcpRules
        if (-not $syncResult.Success) {
            Write-UiWarning "MCP Rules 同步失败: $($syncResult.ErrorMessage)"
        }

        # 凭据清零（安全）
        foreach ($key in @($credentials.Keys)) { $credentials[$key] = $null }

        Write-UiSuccess "MCP Server '$ServerId' 安装完成"
        return @{ Success = $true; ServerId = $ServerId; Status = "Active" }
    }
    catch {
        Write-UiDanger "安装 MCP Server '$ServerId' 失败: $($_.Exception.Message)"
        return @{ Success = $false; ServerId = $ServerId; Status = "Failed"; ErrorMessage = $_.Exception.Message }
    }
}

# ─── Task 2.10: Invoke-McpToggle ────────────────────────────────────────────

function Invoke-McpToggle {
    <#
    .SYNOPSIS
    批量 Toggle 禁用/启用
    .PARAMETER ServerIds
    要 toggle 的 server ID 数组
    .RETURNS
    @{ Results; SuccessCount; FailureCount }
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ServerIds
    )

    $results = @()
    $successCount = 0
    $failureCount = 0

    # 获取当前状态
    $statuses = Get-McpStatus
    $statusMap = @{}
    foreach ($s in $statuses) { $statusMap[$s.Id] = $s.Status }

    foreach ($id in $ServerIds) {
        try {
            $currentStatus = if ($statusMap.ContainsKey($id)) { $statusMap[$id] } else { "Unknown" }

            $toggleResult = switch ($currentStatus) {
                "Active"   { Disable-McpServer -ServerId $id }
                "Disabled" { Enable-McpServer -ServerId $id }
                "Missing"  {
                    # Missing = 注册表有定义但不在 .claude.json 也未禁用
                    if (-not $script:McpServers -or -not $script:McpServers.Contains($id)) {
                        Write-UiWarning "MCP Server '$id' 未在注册表中定义"
                        @{ Success = $false; ServerId = $id; Status = "Unknown" }
                        break
                    }

                    $serverDef = $script:McpServers[$id]
                    $needsCredentials = ($serverDef.CredentialType -and $serverDef.CredentialType -ne "none")

                    # 先检查 vault 是否有历史凭据（values + envFileValues）
                    $vaultCredentials = $null
                    $vaultEnvFileValues = $null
                    try {
                        $meta = Read-McpMeta
                        if ($meta.ContainsKey("servers") -and
                            $meta.servers -is [hashtable] -and
                            $meta.servers.ContainsKey($id) -and
                            $meta.servers[$id] -is [hashtable] -and
                            $meta.servers[$id].ContainsKey("credentials") -and
                            $meta.servers[$id].credentials -is [hashtable]) {
                            $vaultCred = $meta.servers[$id].credentials
                            if ($vaultCred.ContainsKey("values") -and
                                $vaultCred.values -is [hashtable] -and
                                $vaultCred.values.Count -gt 0) {
                                $vaultCredentials = $vaultCred.values
                            }
                            if ($vaultCred.ContainsKey("envFileValues") -and
                                $vaultCred.envFileValues -is [hashtable] -and
                                $vaultCred.envFileValues.Count -gt 0) {
                                $vaultEnvFileValues = $vaultCred.envFileValues
                            }
                        }
                    }
                    catch {
                        Write-UiWarning "vault 读取失败: $($_.Exception.Message)"
                    }

                    $hasVaultHistory = $vaultCredentials -or $vaultEnvFileValues
                    if (-not $needsCredentials -or $hasVaultHistory) {
                        # 无需凭据 或 vault 有历史 → 直接用 New-McpSettingsEntry 重建
                        $creds = if ($vaultCredentials) { $vaultCredentials } else { @{} }
                        $newConfig = New-McpSettingsEntry -ServerId $id -Server $serverDef -Credentials $creds
                        if ($newConfig) {
                            $cjPath = "$(Get-UserHome)\.claude.json"
                            $cj = @{}
                            if (Test-Path $cjPath) {
                                $cj = Get-Content -Path $cjPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                            }
                            if (-not $cj) { $cj = @{} }
                            if (-not $cj.ContainsKey("mcpServers")) { $cj["mcpServers"] = @{} }
                            $cj["mcpServers"][$id] = $newConfig
                            $writeOk = Write-FileAtomically -FilePath $cjPath -Content ($cj | ConvertTo-Json -Depth 10)
                            if (-not $writeOk) {
                                throw "更新 .claude.json 失败"
                            }

                            # env-file 类型：写回 env 文件
                            if ($vaultEnvFileValues -and $serverDef.CredentialType -eq "env-file") {
                                $envWriteResult = Write-McpEnvFile -Server $serverDef -EnvValues $vaultEnvFileValues
                                if ($envWriteResult.Success) {
                                    Write-UiSuccess "已恢复 $($serverDef.Name) .env 文件: $($envWriteResult.Path)"
                                }
                                else {
                                    Write-UiWarning "$($serverDef.Name) .env 恢复失败: $($envWriteResult.ErrorMessage)"
                                }
                            }

                            # 补充 settings.json 权限
                            $settingsPath = Get-ClaudeSettingsPath
                            $settings = @{}
                            if (Test-Path $settingsPath) {
                                $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                                if (-not $settings) { $settings = @{} }
                            }
                            if (-not $settings.ContainsKey("permissions")) { $settings["permissions"] = @{} }
                            if (-not $settings["permissions"].ContainsKey("allow")) { $settings["permissions"]["allow"] = @() }
                            if (-not ($settings["permissions"]["allow"] -is [System.Collections.IList])) {
                                $settings["permissions"]["allow"] = @($settings["permissions"]["allow"])
                            }
                            $mcpPerm = "mcp__${id}"
                            if ($settings["permissions"]["allow"] -notcontains $mcpPerm) {
                                $settings["permissions"]["allow"] += $mcpPerm
                                $settingsJson = $settings | ConvertTo-Json -Depth 10
                                $null = Write-FileAtomically -FilePath $settingsPath -Content @($settingsJson)
                            }

                            # vault 状态更新
                            try {
                                $null = Invoke-WithMcpLock {
                                    $vaultMeta = Read-McpMeta
                                    if (-not $vaultMeta.servers.ContainsKey($id)) {
                                        $credEntry = @{ values = $creds }
                                        if ($vaultEnvFileValues) { $credEntry["envFileValues"] = $vaultEnvFileValues }
                                        $vaultMeta.servers[$id] = @{
                                            disabled       = $false
                                            credentials    = $credEntry
                                            definitionHash = Get-McpDefinitionHash $serverDef
                                            updatedAt      = (Get-Date).ToUniversalTime().ToString("o")
                                        }
                                    }
                                    else {
                                        $vaultMeta.servers[$id].disabled = $false
                                        $vaultMeta.servers[$id].updatedAt = (Get-Date).ToUniversalTime().ToString("o")
                                    }
                                    Write-McpMeta $vaultMeta
                                }
                            }
                            catch {
                                Write-UiWarning "vault 更新失败: $($_.Exception.Message)"
                            }

                            Write-UiSuccess "MCP Server '$id' 已恢复"

                            # 同步 MCP Rules 文件
                            $syncResult = Sync-AllMcpRules
                            if (-not $syncResult.Success) {
                                Write-UiWarning "MCP Rules 同步失败: $($syncResult.ErrorMessage)"
                            }

                            @{ Success = $true; ServerId = $id; Status = "Active" }
                        }
                        else {
                            # software 类型返回 $null，走完整安装
                            $installResult = Install-McpSingleServer -ServerId $id
                            $installResult
                        }
                    }
                    else {
                        # 需凭据且无历史 → 走完整安装管道
                        $installResult = Install-McpSingleServer -ServerId $id
                        $installResult
                    }
                }
                default {
                    Write-UiWarning "MCP Server '$id' 状态为 $currentStatus，跳过 toggle"
                    @{ Success = $false; ServerId = $id; Status = $currentStatus }
                }
            }

            $results += $toggleResult
            if ($toggleResult.Success) { $successCount++ } else { $failureCount++ }
        }
        catch {
            Write-UiDanger "Toggle '$id' 失败: $($_.Exception.Message)"
            $results += @{ Success = $false; ServerId = $id; Status = "Error" }
            $failureCount++
        }
    }

    return @{
        Results      = $results
        SuccessCount = $successCount
        FailureCount = $failureCount
    }
}

# ─── Task 2.13: MCP 管理子菜单 ─────────────────────────────────────────────

function Show-McpManageMenu {
    <#
    .SYNOPSIS
    MCP 管理交互菜单（扁平化：状态总览 + 操作菜单）
    #>

    # 入口同步：凭据对齐 + Rules 渲染
    $syncResult = Sync-McpCredentials
    if ($syncResult.SyncedCount -gt 0) {
        Write-UiSuccess "已同步 $($syncResult.SyncedCount) 个 MCP 凭据"
    }
    Sync-AllMcpRules | Out-Null

    while ($true) {
        # 1. 获取并展示状态
        $statuses = @(Get-McpStatus)
        Show-McpStatusTable $statuses

        # 2. 动态构建操作菜单
        $toggleable = @($statuses | Where-Object { $_.Status -in @("Active", "Disabled", "Missing") })
        $removable  = @($statuses | Where-Object { $_.Status -ne "Missing" })

        $options = [System.Collections.ArrayList]::new()
        $actionMap = [System.Collections.ArrayList]::new()

        if ($toggleable.Count -gt 0) {
            [void]$options.Add("开启·禁用 ($($toggleable.Count))")
            [void]$actionMap.Add("toggle")
        }
        if ($removable.Count -gt 0) {
            [void]$options.Add("删除 MCP")
            [void]$actionMap.Add("delete")
        }

        # 非 ANSI 终端无 Esc 键，必须提供显式返回选项
        [void]$options.Add("返回")
        [void]$actionMap.Add("back")

        if ($toggleable.Count -eq 0 -and $removable.Count -eq 0) {
            Write-UiDim "没有可管理的 MCP Server"
            Write-UiDim "按任意键返回..."
            $null = [Console]::ReadKey($true)
            return
        }

        $choice = Show-SingleSelectMenu -Title "管理操作" -Options @($options) -DefaultIndex 0
        if ($choice -eq -1) { return }

        switch ($actionMap[$choice]) {
            "toggle" {
                $menuOptions = @($toggleable | ForEach-Object { "$($_.Name) [$($_.Status)]" })
                $defaultSelected = @()
                for ($i = 0; $i -lt $toggleable.Count; $i++) {
                    if ($toggleable[$i].Status -eq "Active") {
                        $defaultSelected += $i
                    }
                }

                $selections = Show-MultiSelectMenu -Title "切换 MCP 状态（空格切换，Active=已勾选）" -Options $menuOptions -DefaultSelected $defaultSelected
                if ($null -ne $selections) {
                    $selectedIndices = @($selections)
                    $toggleIds = @()
                    for ($i = 0; $i -lt $toggleable.Count; $i++) {
                        $wasActive = $toggleable[$i].Status -eq "Active"
                        $isSelected = $selectedIndices -contains $i
                        if (($wasActive -and -not $isSelected) -or (-not $wasActive -and $isSelected)) {
                            $toggleIds += $toggleable[$i].Id
                        }
                    }
                    if ($toggleIds.Count -gt 0) {
                        $result = Invoke-McpToggle $toggleIds
                        Write-UiSuccess "切换完成: $($result.SuccessCount) 成功, $($result.FailureCount) 失败"
                    }
                    else {
                        Write-UiDim "未更改任何状态"
                    }
                }
            }
            "delete" {
                $menuOptions = @($removable | ForEach-Object { "$($_.Name) [$($_.Status)]" })
                $selected = Show-SingleSelectMenu -Title "选择要删除的 MCP" -Options $menuOptions -DefaultIndex 0
                if ($selected -ge 0 -and $selected -lt $removable.Count) {
                    Remove-McpServer $removable[$selected].Id
                }
            }
            "back" {
                return
            }
        }

        Write-Host ""
        Write-UiDim "按任意键刷新..."
        $null = [Console]::ReadKey($true)
    }
}

# 注意：此脚本通过 dot-source 加载，不需要 Export-ModuleMember
# 所有函数在 dot-source 后自动可用
