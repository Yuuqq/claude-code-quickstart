# Bootstrap-ClaudeEnv.ps1 - CCQ 引导脚本
# 作者: 哈雷酱 (本小姐的引导脚本杰作！)
# 功能: PS5 兼容的引导脚本，安装前置条件并引导用户运行主安装脚本

#Requires -Version 5.1

# 修复 irm|iex 管道执行时的控制台编码，防止中文乱码。
# 仅设置 [Console]::OutputEncoding 不够：.NET 用 UTF-8 写字节，
# 但 Windows 控制台窗口仍用旧 OEM 代码页（如 936/437）解释字节，
# 两端不一致导致乱码。必须通过 kernel32 API 将控制台代码页也改为
# 65001（UTF-8），使两端完全对齐。
try {
    if (-not ([System.Management.Automation.PSTypeName]'_BootstrapKernel32Cp').Type) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public class _BootstrapKernel32Cp {
    [DllImport("kernel32.dll")] public static extern bool SetConsoleOutputCP(uint cp);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleCP(uint cp);
}
'@ -ErrorAction Stop
    }
    [_BootstrapKernel32Cp]::SetConsoleOutputCP(65001) | Out-Null
    [_BootstrapKernel32Cp]::SetConsoleCP(65001) | Out-Null
} catch { }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding  = [System.Text.Encoding]::UTF8

# 严格模式
Set-StrictMode -Version Latest

# 导入核心模块
# 用 try/catch 安全获取脚本根目录：
# Set-StrictMode -Version Latest 下，在 iex 管道场景中访问
# $MyInvocation.MyCommand.Path 会因属性不存在而直接抛异常，
# if 条件判断本身也无法阻止该异常，必须用 try/catch 捕获。
# 同时保存完整脚本路径（用于提权时 -ScriptPath 传递）
$script:BootstrapScriptPath = $null
$scriptRoot = try {
    $p = $MyInvocation.MyCommand.Path
    if ($p) {
        $script:BootstrapScriptPath = $p
        Split-Path -Parent $p
    } else { $null }
} catch {
    $null  # iex 管道场景，依赖已内联，无需本地路径
}
# dot-source 核心模块（加 try-catch 防止提权后初始化异常导致窗口闪退）
try {
    . "$scriptRoot\core\Admin.ps1"
    . "$scriptRoot\core\Ui.ps1"
    . "$scriptRoot\core\Process.ps1"
} catch {
    Write-Host "✗ 核心模块加载失败: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  脚本路径: $scriptRoot" -ForegroundColor Gray
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        Write-Host "" ; Write-Host "按任意键退出..." -ForegroundColor Gray
        try { $null = [Console]::ReadKey($true) } catch { }
    }
    exit 1
}

# 全局配置
$script:MinWindowsVersion = [Version]"10.0.18362"  # Windows 10 1903
$script:RequiredPowerShellVersion = [Version]"7.0"

function Test-WindowsVersion {
    <#
    .SYNOPSIS
    检测 Windows 版本是否满足要求
    .RETURNS
    版本检测结果对象
    #>
    param()

    $result = @{
        IsSupported = $false
        CurrentVersion = $null
        RequiredVersion = $script:MinWindowsVersion
        VersionString = ""
        ErrorMessage = ""
    }

    try {
        # 获取 Windows 版本
        $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $versionString = $osInfo.Version
        $result.CurrentVersion = [Version]$versionString
        $result.VersionString = "$($osInfo.Caption) (版本 $versionString)"

        # 检查版本是否满足要求
        if ($result.CurrentVersion -ge $result.RequiredVersion) {
            $result.IsSupported = $true
            Write-UiSuccess "✓ Windows 版本检查通过: $($result.VersionString)"
        } else {
            $result.ErrorMessage = "Windows 版本过低，需要 Windows 10 1903 或更高版本"
            Write-UiDanger "✗ $($result.ErrorMessage)"
            Write-UiDanger "  当前版本: $($result.VersionString)"
            Write-UiDanger "  最低要求: Windows 10 1903 (10.0.18362)"
        }

    } catch {
        $result.ErrorMessage = "无法检测 Windows 版本: $($_.Exception.Message)"
        Write-UiDanger "✗ $($result.ErrorMessage)"
    }

    return $result
}

function Test-WingetAvailability {
    <#
    .SYNOPSIS
    检测 winget 可用性
    .RETURNS
    winget 可用性检测结果对象
    #>
    param()

    $result = @{
        IsAvailable = $false
        Version = ""
        InstallationRequired = $false
        ErrorMessage = ""
    }

    try {
        Write-UiPrimary "🔍 检测 winget 可用性..."

        if (Test-CommandAvailable -Command "winget") {
            $version = Get-CommandVersion -Command "winget"
            $result.IsAvailable = $true
            $result.Version = $version
            Write-UiSuccess "✓ winget 已可用 (版本: $version)"
        } else {
            $result.InstallationRequired = $true
            Write-UiWarning "⚠ winget 不可用，需要安装"

            # 检查是否可以通过 Microsoft Store 安装
            try {
                $appxPackage = Get-AppxPackage -Name "Microsoft.DesktopAppInstaller" -ErrorAction SilentlyContinue
                if ($appxPackage) {
                    Write-UiInfo "检测到 App Installer，但 winget 命令不可用"
                    $result.ErrorMessage = "App Installer 已安装但 winget 命令不可用，可能需要更新"
                } else {
                    Write-UiInfo "未检测到 App Installer"
                    $result.ErrorMessage = "需要安装 Microsoft App Installer"
                }
            } catch {
                $result.ErrorMessage = "无法检测 App Installer 状态"
            }
        }

    } catch {
        $result.ErrorMessage = "winget 检测过程中发生错误: $($_.Exception.Message)"
        Write-UiDanger "✗ $($result.ErrorMessage)"
    }

    return $result
}

function Install-WindowsTerminal {
    <#
    .SYNOPSIS
    安装 Windows Terminal（软性推荐）
    .RETURNS
    安装结果对象
    #>
    param()

    $result = @{
        Success = $false
        AlreadyInstalled = $false
        UserSkipped = $false
        ErrorMessage = ""
    }

    try {
        Write-UiPrimary "🖥️ 检查 Windows Terminal..."

        # 检查是否已安装（兼容不支持 Appx 的系统）
        try {
            $wtPackage = Get-AppxPackage -Name "Microsoft.WindowsTerminal" -ErrorAction Stop
            if ($wtPackage) {
                $result.Success = $true
                $result.AlreadyInstalled = $true
                Write-UiSuccess "✓ Windows Terminal 已安装"
                return $result
            }
        } catch {
            # 如果 Get-AppxPackage 不可用（如 Windows Server），跳过检查
            Write-UiInfo "无法检测 Windows Terminal（系统不支持 Appx），跳过安装"
            $result.Success = $true
            $result.UserSkipped = $true
            return $result
        }

        # 询问用户是否安装
        Write-UiInfo "Windows Terminal 可以提供更好的终端体验，包括："
        Write-UiDim "  • 更好的字体渲染和颜色支持"
        Write-UiDim "  • 多标签页和分屏功能"
        Write-UiDim "  • 更丰富的自定义选项"

        $options = @("安装 Windows Terminal（推荐）", "跳过，使用默认终端")
        $choice = Show-SingleSelectMenu -Title "是否安装 Windows Terminal？" -Options $options

        if ($choice -eq 0) {
            # 尝试使用 winget 安装
            if (Test-CommandAvailable -Command "winget") {
                try {
                    $installResult = Invoke-WingetInstall -PackageId "Microsoft.WindowsTerminal" -PackageName "Windows Terminal" -Silent -AcceptLicense
                    if ($installResult.Success) {
                        $result.Success = $true
                        Write-UiSuccess "✓ Windows Terminal 安装成功"
                    } else {
                        throw "winget 安装失败"
                    }
                } catch {
                    Write-UiWarning "⚠ 通过 winget 安装失败，尝试其他方法..."

                    # 尝试通过 Microsoft Store 安装
                    try {
                        Start-Process "ms-windows-store://pdp/?productid=9N0DX20HK701" -ErrorAction Stop
                        Write-UiInfo "已打开 Microsoft Store，请手动安装 Windows Terminal"
                        Write-UiInfo "安装完成后，请重新运行此脚本"
                        $result.Success = $true  # 认为用户会手动安装
                    } catch {
                        $result.ErrorMessage = "无法打开 Microsoft Store: $($_.Exception.Message)"
                        Write-UiWarning "⚠ $($result.ErrorMessage)"
                        $result.Success = $true  # 不强制要求 Windows Terminal
                    }
                }
            } else {
                $result.ErrorMessage = "winget 不可用，无法自动安装 Windows Terminal"
                Write-UiWarning "⚠ $($result.ErrorMessage)"
                $result.Success = $true  # 不强制要求 Windows Terminal
            }
        } else {
            $result.UserSkipped = $true
            $result.Success = $true
            Write-UiInfo "用户选择跳过 Windows Terminal 安装"
        }

    } catch {
        $result.ErrorMessage = "Windows Terminal 安装过程中发生错误: $($_.Exception.Message)"
        Write-UiWarning "⚠ $($result.ErrorMessage)"
        $result.Success = $true  # 不强制要求 Windows Terminal
    }

    return $result
}

function Install-PowerShell7 {
    <#
    .SYNOPSIS
    安装 PowerShell 7（硬性前置）
    .RETURNS
    安装结果对象
    #>
    param()

    $result = @{
        Success = $false
        AlreadyInstalled = $false
        Version = ""
        ErrorMessage = ""
    }

    try {
        Write-UiPrimary "⚡ 检查 PowerShell 7..."

        # 检查是否已安装 PowerShell 7
        if (Test-CommandAvailable -Command "pwsh") {
            $version = Get-CommandVersion -Command "pwsh"

            # 检查版本是否有效
            if ($version -and $version -ne "未知" -and $version -ne "未安装") {
                # 提取版本号（移除非数字和点的字符）
                $versionString = $version -replace '[^\d\.].*$', ''

                # 确保版本字符串不为空
                if ($versionString) {
                    try {
                        $versionObj = [Version]$versionString

                        if ($versionObj -ge $script:RequiredPowerShellVersion) {
                            $result.Success = $true
                            $result.AlreadyInstalled = $true
                            $result.Version = $version
                            Write-UiSuccess "✓ PowerShell 7 已安装 (版本: $version)"
                            return $result
                        } else {
                            Write-UiWarning "⚠ PowerShell 7 版本过低 (当前: $version, 需要: $($script:RequiredPowerShellVersion))"
                        }
                    } catch {
                        Write-UiWarning "⚠ 无法解析 PowerShell 7 版本号: $version"
                    }
                } else {
                    Write-UiWarning "⚠ 无法提取 PowerShell 7 版本号: $version"
                }
            } else {
                Write-UiWarning "⚠ 无法获取 PowerShell 7 版本信息"
            }
        } else {
            Write-UiWarning "⚠ PowerShell 7 未安装"
        }

        Write-UiInfo "PowerShell 7 是运行主安装脚本的必要条件"

        # 尝试使用 winget 安装
        if (Test-CommandAvailable -Command "winget") {
            try {
                $installResult = Invoke-WingetInstall -PackageId "Microsoft.PowerShell" -PackageName "PowerShell 7" -Silent -AcceptLicense
                if ($installResult.Success) {
                    # 验证安装
                    Refresh-SessionPath
                    if (Test-CommandAvailable -Command "pwsh") {
                        $newVersion = Get-CommandVersion -Command "pwsh"
                        $result.Success = $true
                        $result.Version = $newVersion
                        Write-UiSuccess "✓ PowerShell 7 安装成功 (版本: $newVersion)"
                    } else {
                        throw "安装后 pwsh 命令仍不可用"
                    }
                } else {
                    throw "winget 安装失败"
                }
            } catch {
                $result.ErrorMessage = "PowerShell 7 安装失败: $($_.Exception.Message)"
                Write-UiDanger "✗ $($result.ErrorMessage)"

                # 提供手动安装指导
                Write-UiInfo "请手动安装 PowerShell 7："
                Write-UiDim "1. 访问: https://github.com/PowerShell/PowerShell/releases"
                Write-UiDim "2. 下载适合您系统的安装包"
                Write-UiDim "3. 安装完成后重新运行此脚本"
            }
        } else {
            $result.ErrorMessage = "winget 不可用，无法自动安装 PowerShell 7"
            Write-UiDanger "✗ $($result.ErrorMessage)"

            # 提供手动安装指导
            Write-UiInfo "请手动安装 PowerShell 7："
            Write-UiDim "1. 访问: https://github.com/PowerShell/PowerShell/releases"
            Write-UiDim "2. 下载适合您系统的安装包"
            Write-UiDim "3. 安装完成后重新运行此脚本"
        }

    } catch {
        $result.ErrorMessage = "PowerShell 7 安装过程中发生错误: $($_.Exception.Message)"
        Write-UiDanger "✗ $($result.ErrorMessage)"
    }

    return $result
}

function Show-CompletionMessage {
    <#
    .SYNOPSIS
    显示引导脚本完成消息
    .PARAMETER PowerShellVersion
    安装的 PowerShell 版本
    #>
    param(
        [string]$PowerShellVersion
    )

    Write-Host ""

    Write-UiSuccess "🎉 引导脚本执行完成！"
    Write-Host ""

    Write-UiPrimary "📋 完成摘要："
    Write-UiInfo "  ✓ Windows 版本检查通过"
    Write-UiInfo "  ✓ PowerShell 7 已准备就绪 ($PowerShellVersion)"
    Write-UiInfo "  ✓ 基础环境配置完成"
    Write-Host ""

    Write-UiPrimary "🚀 下一步操作："
    Write-UiInfo "请用管理员打开 PowerShell 7 运行主安装脚本："
    Write-Host ""
    if ($scriptRoot) {
        # 本地文件模式：直接指向同目录的安装脚本
        Write-UiSuccess "  pwsh -File `"$scriptRoot\Install-ClaudeEnv.ps1`""
    } else {
        # iex 管道模式：PS7 原生支持 UTF-8，irm|iex 无需特殊处理
        Write-UiSuccess "  irm 'https://github.com/Yuuqq/claude-code-quickstart/releases/latest/download/Install-ClaudeEnv.built.ps1' | iex"
    }
    Write-Host ""

    Write-UiPrimary "💡 提示："
    Write-UiDim "• 如果您使用的是 Windows Terminal，建议在其中运行 PowerShell 7"
    Write-UiDim "• 主安装脚本提供基础环境和进阶扩展两级安装"
    Write-Host ""

    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        Write-UiDim "按任意键退出..."
        $null = [Console]::ReadKey($true)
    }
}

function Wait-KeyBeforeExit {
    <#
    .SYNOPSIS
    退出前等待用户按键，防止终端闪退（仅交互式终端生效）
    #>
    param()

    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        Write-Host ""
        Write-UiDim "按任意键退出..."
        try { $null = [Console]::ReadKey($true) } catch { }
    }
}

function Main {
    <#
    .SYNOPSIS
    引导脚本主函数
    #>
    param()

    try {
        # 显示欢迎信息
        Show-CcqLogo -Subtitle "Claude Code Quickstart - 引导脚本"

        Write-UiInfo "此引导脚本将为您准备安装环境..."
        Write-Host ""

        # 检查管理员权限
        # 显式传递 -ScriptPath 避免 $PSCommandPath 在 dot-source 函数中解析为 Admin.ps1
        Write-UiPrimary "🔐 检查权限..."
        $privilegeResult = Assert-StepPrivilege -StepName "引导脚本" -RequiresAdmin $true -ScriptPath $script:BootstrapScriptPath

        if (-not $privilegeResult) {
            Write-UiDanger "✗ 引导脚本需要管理员权限才能安装必要组件"
            Write-UiDanger "请以管理员身份运行此脚本"
            Wait-KeyBeforeExit
            exit 1
        }

        # 1. Windows 版本检查
        Write-UiPrimary "🖥️ 检查系统兼容性..."
        $windowsResult = Test-WindowsVersion
        if (-not $windowsResult.IsSupported) {
            Write-UiDanger "✗ 系统不兼容，无法继续安装"
            Wait-KeyBeforeExit
            exit 1
        }

        # 2. winget 可用性检查
        $wingetResult = Test-WingetAvailability
        if (-not $wingetResult.IsAvailable -and $wingetResult.InstallationRequired) {
            Write-UiWarning "⚠ winget 不可用，某些组件可能需要手动安装"
        }

        # 3. 安装 Windows Terminal（可选）
        $terminalResult = Install-WindowsTerminal

        # 4. 安装 PowerShell 7（必需）
        $ps7Result = Install-PowerShell7
        if (-not $ps7Result.Success) {
            Write-UiDanger "✗ PowerShell 7 安装失败，无法继续"
            Write-UiDanger "请手动安装 PowerShell 7 后重新运行此脚本"
            Wait-KeyBeforeExit
            exit 1
        }

        # 5. 显示完成消息
        Show-CompletionMessage -PowerShellVersion $ps7Result.Version

    } catch {
        Write-UiDanger "✗ 引导脚本执行失败: $($_.Exception.Message)"
        Write-UiDanger "请检查错误信息并重新运行脚本"
        Wait-KeyBeforeExit
        exit 1
    }
}

# 脚本入口点
if ($MyInvocation.InvocationName -ne '.') {
    Main
}