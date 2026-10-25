# CcSwitch.ps1 - CC-Switch 安装 - CCQ
# 作者: 哈雷酱 (本小姐的 CC-Switch 安装杰作！)
# 功能: CC-Switch GitHub Release 下载 + MSI 静默安装

#Requires -Version 5.1

Set-StrictMode -Version Latest

# 依赖: Process.ps1, Ui.ps1, Admin.ps1, Net.ps1（由入口脚本 dot-source 加载）

# 配置
$script:CcSwitchRepo = "farion1231/cc-switch"
$script:CcSwitchApiUrl = "https://api.github.com/repos/$script:CcSwitchRepo/releases/latest"
# 解析 $env:TEMP 为长路径，避免 8.3 短路径导致 msiexec 失败
$script:TempDownloadDir = try {
    # 多重策略解析长路径，避免 8.3 短路径
    $tempLong = $env:TEMP
    try {
        if (Test-Path $tempLong) {
            $tempLong = (Get-Item $tempLong).FullName
        }
    } catch { }
    # 回退：通过 GetFullPath 解析
    if ($tempLong -match '~') {
        try {
            $tempLong = [System.IO.Path]::GetFullPath($tempLong)
        } catch { }
    }
    # 最终回退：构建无短路径的临时目录
    if ($tempLong -match '~') {
        $tempLong = Join-Path $env:LOCALAPPDATA "Temp"
        if (-not (Test-Path $tempLong)) {
            $tempLong = $env:TEMP
        }
    }
    Join-Path $tempLong "CcSwitchInstall"
} catch {
    "$env:TEMP\CcSwitchInstall"
}

function Test-CcSwitchInstalled {
    <#
    .SYNOPSIS
    检测 CC-Switch 是否已安装
    .RETURNS
    标准检测结果 hashtable（IsInstalled, Version, Data, Message）
    #>

    return Invoke-UnifiedCheck -StepId "CcSwitch" -DisplayName "CC-Switch" `
        -CustomVerify {
            # 检查注册表中的 CC-Switch 安装信息
            $uninstallKeys = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
            )

            foreach ($keyPath in $uninstallKeys) {
                try {
                    $items = @(Get-ItemProperty $keyPath -ErrorAction SilentlyContinue | Where-Object {
                        $_.DisplayName -like "*CC-Switch*" -or
                        $_.DisplayName -like "*CC Switch*" -or
                        $_.DisplayName -like "*Claude Code Switch*" -or
                        $_.Publisher -like "*ccswitch*" -or
                        $_.Publisher -like "*Anthropic*"
                    })

                    if ($items.Count -gt 0) {
                        $item = $items[0]
                        Write-UiInfo "  名称: $($item.DisplayName)" -Level Detail
                        if ($item.DisplayVersion) {
                            Write-UiInfo "  版本: $($item.DisplayVersion)" -Level Detail
                            return $item.DisplayVersion
                        }
                        return $true
                    }
                } catch { }
            }

            # 检查常见安装路径
            $commonPaths = @(
                "$env:LOCALAPPDATA\Programs\CC Switch",
                "$env:LOCALAPPDATA\Programs\CC-Switch",
                "$env:ProgramFiles\CC-Switch",
                "$env:ProgramFiles\CC Switch",
                "$env:ProgramFiles\Anthropic\CC-Switch",
                "${env:ProgramFiles(x86)}\CC-Switch",
                "${env:ProgramFiles(x86)}\CC Switch",
                "${env:ProgramFiles(x86)}\Anthropic\CC-Switch",
                "$env:LOCALAPPDATA\Programs\cc-switch"
            )

            foreach ($path in $commonPaths) {
                if (Test-Path $path) {
                    $exeFiles = @(Get-ChildItem -Path $path -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue)
                    if ($exeFiles.Count -gt 0) {
                        Write-UiInfo "  安装目录: $path" -Level Detail
                        return $true
                    }
                }
            }

            return $false
        } -UseCache
}

function Install-CcSwitch {
    <#
    .SYNOPSIS
    安装 CC-Switch
    .RETURNS
    安装结果对象
    #>
    param()

    Write-UiPrimary "=== CC-Switch 安装 ===" -Level Detail

    $result = @{
        Success      = $false
        ErrorMessage = ""
        Data         = @{}
    }

    try {
        # 1. 检查前置条件
        Write-UiDim "1. 检查前置条件..." -Level Detail

        if (-not (Test-CommandAvailable -Command "claude")) {
            throw "Claude Code 未安装，请先完成 ClaudeCode 步骤"
        }

        Write-UiSuccess "✓ 前置条件检查完成" -Level Detail

        # 2. 检查 CC-Switch 是否已安装
        Write-UiDim "2. 检查 CC-Switch 安装状态..." -Level Detail

        $ccSwitchTest = Test-CcSwitchInstalled
        if ($ccSwitchTest.IsInstalled) {
            Write-UiSuccess "✓ CC-Switch 已安装，跳过" -Level Detail
            $result.Success = $true
            $result.Data["Skipped"] = $true
            return $result
        } else {
            # 未检测到安装，提醒用户检测机制的限制
            Write-UiWarning "  未检测到 CC-Switch 安装" -Level Detail
            Write-UiDim "  注意: 当前仅支持检测 MSI 安装方式" -Level Detail
            Write-UiDim "  如果您已通过便携版/自定义方式安装，可选择跳过" -Level Detail
            $response = Read-Host "是否继续安装 CC-Switch？[Y/n]"
            if ($response -match "^[Nn]") {
                Write-UiDim "跳过 CC-Switch 安装" -Level Detail
                $result.Success = $true
                $result.Data["Skipped"] = $true
                return $result
            }
        }

        # 3. 检查安装权限（非硬性要求，per-user 安装不需要管理员）
        Write-UiDim "3. 检查安装权限..." -Level Detail

        $isAdmin = Test-IsAdministrator
        if (-not $isAdmin) {
            Write-UiDim "  当前非管理员权限，将优先尝试 per-user 安装" -Level Detail
        } else {
            Write-UiSuccess "✓ 管理员权限确认" -Level Detail
        }

        # 4. 获取最新版本信息
        Write-UiDim "4. 获取 CC-Switch 最新版本信息..." -Level Detail

        $releaseInfo = Get-LatestCcSwitchRelease
        if (-not $releaseInfo) {
            throw "无法获取 CC-Switch 最新版本信息"
        }

        Write-UiSuccess "✓ 最新版本: $($releaseInfo.Version)" -Level Detail
        Write-UiDim "  发布时间: $($releaseInfo.PublishedAt)" -Level Detail
        Write-UiDim "  下载地址: $($releaseInfo.DownloadUrl)" -Level Debug

        # 5. 下载 CC-Switch 安装包
        Write-UiDim "5. 下载 CC-Switch 安装包..." -Level Detail

        $installerPath = Download-CcSwitchInstaller -DownloadUrl $releaseInfo.DownloadUrl -Version $releaseInfo.Version -ExpectedHash $releaseInfo.ExpectedHash

        if (-not $installerPath -or -not (Test-Path $installerPath)) {
            throw "CC-Switch 安装包下载失败"
        }

        Write-UiSuccess "✓ 安装包下载成功: $installerPath" -Level Detail

        # 6. 验证安装包
        Write-UiDim "6. 验证安装包..." -Level Detail

        $fileInfo = Get-Item $installerPath
        Write-UiDim "  文件大小: $([math]::Round($fileInfo.Length / 1MB, 2)) MB" -Level Detail

        # 检查文件类型
        if ($installerPath -notmatch "\.(msi|exe)$") {
            throw "不支持的安装包格式: $installerPath"
        }

        Write-UiSuccess "✓ 安装包验证通过" -Level Detail

        # 7. 执行静默安装
        Write-UiDim "7. 执行 CC-Switch 静默安装..." -Level Detail

        $installResult = Install-CcSwitchPackage -InstallerPath $installerPath

        if (-not $installResult.Success) {
            throw "CC-Switch 安装失败: $($installResult.ErrorMessage)"
        }

        Write-UiSuccess "✓ CC-Switch 安装成功" -Level Detail

        # 8. 验证安装
        Write-UiDim "8. 验证 CC-Switch 安装..." -Level Detail

        # 等待安装完成
        Start-Sleep -Seconds 3

        $verifyTest = Test-CcSwitchInstalled
        if (-not $verifyTest.IsInstalled) {
            Write-UiWarning "⚠ CC-Switch 安装验证失败，但安装过程成功"
            Write-UiDim "  可能需要重启系统或重新登录才能完全生效" -Level Detail
        } else {
            Write-UiSuccess "✓ CC-Switch 安装验证成功" -Level Detail
        }

        # 9. 清理临时文件
        Write-UiDim "9. 清理临时文件..." -Level Detail

        try {
            if (Test-Path $script:TempDownloadDir) {
                Remove-Item $script:TempDownloadDir -Recurse -Force
                Write-UiSuccess "✓ 临时文件清理完成" -Level Detail
            }
        } catch {
            Write-UiWarning "⚠ 临时文件清理失败，但不影响使用: $($_.Exception.Message)" -Level Debug
        }

        # 10. 使用提示
        Write-UiDim "10. 使用提示..." -Level Detail
        Write-UiPrimary "  CC-Switch 已安装完成" -Level Detail
        Write-UiDim "  CC-Switch 是 Claude Code 的辅助工具，提供以下功能:" -Level Detail
        Write-UiDim "    - 快速切换 Claude Code 配置" -Level Detail
        Write-UiDim "    - 项目环境管理" -Level Detail
        Write-UiDim "    - 工作流程优化" -Level Detail
        Write-UiSuccess "✓ CC-Switch 安装完成" -Level Detail

        $result.Success = $true
        $result.Data["Version"] = $releaseInfo.Version
        $result.Data["InstallerPath"] = $installerPath

        return $result

    } catch {
        $result.ErrorMessage = "CC-Switch 安装失败: $($_.Exception.Message)"
        Write-UiDanger "✗ $($result.ErrorMessage)"

        # 清理临时文件
        try {
            if (Test-Path $script:TempDownloadDir) {
                Remove-Item $script:TempDownloadDir -Recurse -Force
            }
        } catch { }

        return $result
    }
}

function Get-LatestCcSwitchRelease {
    <#
    .SYNOPSIS
    获取 CC-Switch 最新版本信息
    .RETURNS
    包含版本信息的对象
    #>
    param()

    try {
        Write-UiDim "  正在获取 GitHub Release 信息..." -Level Detail

        # 强制使用 TLS 1.2+（GitHub API 要求，防止 PS 5.1 默认 TLS 1.0 导致连接失败）
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

        # 使用 Invoke-RestMethod 获取最新版本信息
        $headers = @{
            "User-Agent" = "ClaudeEnvInstaller/1.0"
            "Accept" = "application/vnd.github.v3+json"
        }

        $release = Invoke-RestMethod -Uri $script:CcSwitchApiUrl -Headers $headers -TimeoutSec 30

        if (-not $release) {
            throw "无法获取 Release 信息"
        }

        # 查找 Windows MSI 安装包
        $msiAsset = $release.assets | Where-Object {
            $_.name -match "\.(msi|exe)$" -and
            $_.name -match "(windows|win|x64|amd64)" -and
            $_.content_type -match "(application/x-msi|application/octet-stream|application/x-msdownload)"
        } | Select-Object -First 1

        if (-not $msiAsset) {
            # 如果没找到明确的 Windows 安装包，尝试查找任何 MSI/EXE 文件
            $msiAsset = $release.assets | Where-Object {
                $_.name -match "\.(msi|exe)$"
            } | Select-Object -First 1
        }

        if (-not $msiAsset) {
            throw "未找到适用于 Windows 的安装包"
        }

        $expectedHash = $null
        $ymlAsset = $release.assets | Where-Object { $_.name -eq "latest.yml" -or $_.name -match "\.(sha512|sha256)$" } | Select-Object -First 1
        if ($ymlAsset) {
            try {
                $ymlContent = Invoke-RestMethod -Uri $ymlAsset.browser_download_url -Headers $headers -TimeoutSec 30
                if ($ymlContent -match 'sha512:\s*([a-zA-Z0-9+/=]+)') {
                    $expectedHash = $matches[1]
                } elseif ($ymlContent -match '([a-fA-F0-9]{64,128})') {
                    $expectedHash = $matches[1]
                }
            } catch {
                Write-UiWarning "⚠ 无法获取最新 release 的校验哈希" -Level Debug
            }
        }

        return @{
            Version = $release.tag_name -replace '^v', ''
            TagName = $release.tag_name
            PublishedAt = $release.published_at
            DownloadUrl = $msiAsset.browser_download_url
            FileName = $msiAsset.name
            FileSize = $msiAsset.size
            ExpectedHash = $expectedHash
        }

    } catch {
        Write-UiDanger "  获取版本信息失败: $($_.Exception.Message)"
        return $null
    }
}

function Download-CcSwitchInstaller {
    <#
    .SYNOPSIS
    下载 CC-Switch 安装包
    .PARAMETER DownloadUrl
    下载地址
    .PARAMETER Version
    版本号
    .PARAMETER ExpectedHash
    预期的哈希值 (可选)
    .RETURNS
    下载的文件路径
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string] $DownloadUrl,

        [Parameter(Mandatory = $true)]
        [string] $Version,

        [string] $ExpectedHash
    )

    try {
        # 创建临时下载目录
        if (Test-Path $script:TempDownloadDir) {
            Remove-Item $script:TempDownloadDir -Recurse -Force
        }
        New-Item -Path $script:TempDownloadDir -ItemType Directory -Force | Out-Null

        # 确定文件名和路径
        $fileName = Split-Path $DownloadUrl -Leaf
        if (-not $fileName -or $fileName -notmatch "\.(msi|exe)$") {
            $fileName = "cc-switch-$Version.msi"
        }

        $filePath = Join-Path $script:TempDownloadDir $fileName

        # 使用统一的下载函数
        $downloadResult = Invoke-FileDownload -Url $DownloadUrl -OutputPath $filePath -Description "CC-Switch $Version"

        if (-not $downloadResult.Success) {
            throw $downloadResult.ErrorMessage
        }

        if ($ExpectedHash) {
            Write-UiDim "  🔍 正在校验哈希..." -Level Detail
            $fileHashObj = Get-FileHash -Path $filePath -Algorithm SHA512
            $fileHashHex = $fileHashObj.Hash

            $expectedHex = $ExpectedHash
            if ($ExpectedHash -match '^[a-zA-Z0-9+/=]+$') {
                try {
                    $bytes = [System.Convert]::FromBase64String($ExpectedHash)
                    $expectedHex = [System.BitConverter]::ToString($bytes) -replace '-'
                } catch { }
            }
            if ($fileHashHex -ne $expectedHex -and $ExpectedHash -match '^[a-fA-F0-9]+$') {
                 $fileHashObj256 = Get-FileHash -Path $filePath -Algorithm SHA256
                 if ($fileHashObj256.Hash -ne $ExpectedHash -and $fileHashHex -ne $ExpectedHash) {
                     Remove-Item $filePath -Force
                     throw "安装包哈希校验失败！预计: $ExpectedHash"
                 }
            } elseif ($expectedHex -and $fileHashHex -ne $expectedHex) {
                Remove-Item $filePath -Force
                throw "安装包哈希校验失败！预计: $expectedHex, 实际: $fileHashHex"
            }
            Write-UiSuccess "  ✓ 下载及哈希校验完成" -Level Detail
        } else {
            Write-UiWarning "  ⚠ 未获取到哈希，跳过校验" -Level Detail
        }

        return $filePath

    } catch {
        Write-UiDanger "  下载失败: $($_.Exception.Message)"
        return $null
    }
}

function Get-MsiLogErrors {
    <#
    .SYNOPSIS
    从 MSI 安装日志中提取错误信息
    #>
    $errorDetails = ""
    $logFiles = @(
        "$script:TempDownloadDir\install.log",
        "$script:TempDownloadDir\install-peruser.log"
    )
    foreach ($logPath in $logFiles) {
        if (Test-Path $logPath) {
            try {
                $logContent = Get-Content $logPath -Tail 30 -ErrorAction SilentlyContinue
                $errorLines = $logContent | Where-Object { $_ -match "(error|failed|exception)" }
                if ($errorLines) {
                    $errorDetails += "`n$([System.IO.Path]::GetFileName($logPath)): $($errorLines[-3..-1] -join '; ')"
                }
            } catch { }
        }
    }
    return $errorDetails
}

function Install-CcSwitchPackage {
    <#
    .SYNOPSIS
    安装 CC-Switch 安装包
    .PARAMETER InstallerPath
    安装包路径
    .RETURNS
    安装结果对象
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string] $InstallerPath
    )

    try {
        # 解析 InstallerPath 为长路径，避免 8.3 短路径导致 msiexec 失败
        $InstallerPath = try {
            if (Test-Path $InstallerPath) {
                (Get-Item $InstallerPath).FullName
            } else {
                [System.IO.Path]::GetFullPath($InstallerPath)
            }
        } catch {
            $InstallerPath
        }

        $fileExtension = [System.IO.Path]::GetExtension($InstallerPath).ToLower()

        switch ($fileExtension) {
            ".msi" {
                Write-UiDim "  正在执行 MSI 安装..." -Level Detail

                # 策略 1：per-user 安装（不需要管理员权限）
                Write-UiDim "  尝试 per-user 安装模式..." -Level Debug
                $perUserArgs = @(
                    "/i", "`"$InstallerPath`"",
                    "/qn",
                    "ALLUSERS=2",
                    "MSIINSTALLPERUSER=1",
                    "REBOOT=ReallySuppress",
                    "/norestart",
                    "/l*v", "`"$script:TempDownloadDir\install-peruser.log`""
                )
                $perUserResult = Invoke-ExternalCommand -Command "msiexec" -Arguments $perUserArgs -TimeoutSeconds 300

                if ($perUserResult.Success -or $perUserResult.ExitCode -eq 3010) {
                    $rebootHint = if ($perUserResult.ExitCode -eq 3010) { "（需重启生效）" } else { "" }
                    Write-UiSuccess "  ✓ MSI per-user 安装完成$rebootHint" -Level Detail
                } else {
                    # 策略 2：全局静默安装（需要管理员）
                    Write-UiWarning "  per-user 安装失败 (退出码: $($perUserResult.ExitCode))，尝试全局安装..." -Level Debug
                    $globalArgs = @(
                        "/i", "`"$InstallerPath`"",
                        "/quiet",
                        "/norestart",
                        "/l*v", "`"$script:TempDownloadDir\install.log`""
                    )
                    $globalResult = Invoke-ExternalCommand -Command "msiexec" -Arguments $globalArgs -TimeoutSeconds 300

                    if ($globalResult.Success -or $globalResult.ExitCode -eq 3010) {
                        $rebootHint = if ($globalResult.ExitCode -eq 3010) { "（需重启生效）" } else { "" }
                        Write-UiSuccess "  ✓ MSI 全局安装完成$rebootHint" -Level Detail
                    } else {
                        # 策略 3：GUI 安装降级（让用户手动操作）
                        Write-UiWarning "  静默安装均失败，启动 GUI 安装..." -Level Debug
                        Write-UiPrimary "  请在弹出的安装向导中手动完成安装"
                        $guiResult = Invoke-ExternalCommand -Command "msiexec" -Arguments @("/i", "`"$InstallerPath`"") -TimeoutSeconds 600

                        if (-not $guiResult.Success -and $guiResult.ExitCode -ne 3010) {
                            $errorDetails = Get-MsiLogErrors
                            throw "MSI 安装失败（per-user: $($perUserResult.ExitCode), 全局: $($globalResult.ExitCode), GUI: $($guiResult.ExitCode)）$errorDetails"
                        }
                    }
                }
            }

            ".exe" {
                Write-UiDim "  正在执行 EXE 静默安装..." -Level Detail

                # 尝试常见的静默安装参数
                $silentArgs = @("/S", "/SILENT", "/VERYSILENT", "/quiet", "/q")
                $installSuccess = $false

                foreach ($arg in $silentArgs) {
                    try {
                        Write-UiDim "    尝试参数: $arg" -Level Debug
                        $result = Invoke-ExternalCommand -Command $InstallerPath -Arguments @($arg) -TimeoutSeconds 300

                        if ($result.Success) {
                            Write-UiSuccess "  ✓ EXE 安装完成 (参数: $arg)" -Level Detail
                            $installSuccess = $true
                            break
                        }
                    } catch {
                        continue
                    }
                }

                if (-not $installSuccess) {
                    throw "EXE 静默安装失败，尝试了所有常见参数"
                }
            }

            default {
                throw "不支持的安装包格式: $fileExtension"
            }
        }

        return @{
            Success = $true
            InstallerType = $fileExtension
            Message = "安装成功"
        }

    } catch {
        return @{
            Success = $false
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Verify-CcSwitch {
    <#
    .SYNOPSIS
    验证 CC-Switch 安装
    .RETURNS
    布尔值，表示验证是否成功
    #>
    param()

    $testResult = Test-CcSwitchInstalled
    return @{ Success = [bool]$testResult.IsInstalled; ErrorMessage = if (-not $testResult.IsInstalled) { $testResult.Message } else { "" } }
}

# 注意：此脚本通过 dot-source 加载，不需要 Export-ModuleMember
# 所有函数在 dot-source 后自动可用