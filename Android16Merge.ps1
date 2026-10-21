[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Continue'
$script:Root = $PSScriptRoot
$script:Adb = Join-Path $script:Root 'adb\adb.exe'
$script:Serial = $null
$script:Model = $null
$script:Patch = $null
$script:ForceAdoptableChanged = $false

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 58)) -ForegroundColor DarkGray
}

function Invoke-Adb {
    param([string[]]$Arguments)

    $output = & $script:Adb @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        Output = @($output | ForEach-Object { $_.ToString() })
        ExitCode = $exitCode
    }
}

function Initialize-Adb {
    if (-not (Test-Path -LiteralPath $script:Adb)) {
        throw "未找到 ADB：$script:Adb"
    }

    Invoke-Adb @('start-server') | Out-Null
}

function Find-Device {
    $result = Invoke-Adb @('devices')
    $lines = @($result.Output | Where-Object { $_ -match '^\s*\S+\s+device(?:\s|$)' })
    if ($lines.Count -eq 0) {
        return $false
    }

    if ($lines.Count -gt 1) {
        Write-Host '[错误] 检测到多台已授权设备，为避免选错手机，已停止操作。' -ForegroundColor Red
        $lines | ForEach-Object { Write-Host "  $($_.Trim())" }
        Write-Host '请只保留一台手机连接后重试。'
        return $false
    }

    $script:Serial = ([regex]::Match($lines[0], '^\s*(\S+)\s+device')).Groups[1].Value
    $script:Model = Get-DeviceProperty 'ro.product.model'
    $script:Patch = Get-DeviceProperty 'ro.build.version.security_patch'
    if ([string]::IsNullOrWhiteSpace($script:Model)) { $script:Model = '未知设备' }
    if ([string]::IsNullOrWhiteSpace($script:Patch)) { $script:Patch = '未知' }
    return $true
}

function Get-DeviceProperty {
    param([string]$Name)

    $result = Invoke-Adb @('-s', $script:Serial, 'shell', 'getprop', $Name)
    return (($result.Output -join "`n").Trim())
}

function Get-AndroidVersion {
    return Get-DeviceProperty 'ro.build.version.release'
}

function Find-AdoptableDisk {
    $script:ForceAdoptableChanged = $false

    $result = Invoke-Adb @('-s', $script:Serial, 'shell', 'sm', 'list-disks', 'adoptable')
    $disk = @($result.Output | Where-Object { $_.Trim() -match '^disk:\d+,\d+$' } | Select-Object -First 1)
    if ($disk.Count -gt 0) {
        return $disk[0].Trim()
    }

    # Android 16 can hide the adoptable filter until this test mode is enabled.
    Invoke-Adb @('-s', $script:Serial, 'shell', 'sm', 'set-force-adoptable', 'on') | Out-Null
    $script:ForceAdoptableChanged = $true
    Start-Sleep -Milliseconds 400

    $result = Invoke-Adb @('-s', $script:Serial, 'shell', 'sm', 'list-disks', 'adoptable')
    $disk = @($result.Output | Where-Object { $_.Trim() -match '^disk:\d+,\d+$' } | Select-Object -First 1)
    if ($disk.Count -gt 0) {
        return $disk[0].Trim()
    }

    # Some OEM builds reject the adoptable filter but still accept sm partition.
    $result = Invoke-Adb @('-s', $script:Serial, 'shell', 'sm', 'list-disks')
    $disk = @($result.Output | Where-Object { $_.Trim() -match '^disk:\d+,\d+$' } | Select-Object -First 1)
    if ($disk.Count -gt 0) {
        return $disk[0].Trim()
    }

    return $null
}

function Restore-AdbState {
    if ($script:Serial) {
        try {
            if ($script:ForceAdoptableChanged) {
                Invoke-Adb @('-s', $script:Serial, 'shell', 'sm', 'set-force-adoptable', 'default') | Out-Null
            }
        }
        catch {
        }
    }

    try {
        Invoke-Adb @('kill-server') | Out-Null
    }
    catch {
    }
}

function Write-DeviceSummary {
    param([string]$Disk)

    Write-Host "  设备型号 : $script:Model"
    Write-Host "  序列号   : $script:Serial"
    Write-Host "  Android  : $(Get-AndroidVersion)"
    Write-Host "  安全补丁 : $script:Patch"
    Write-Host "  可分区盘 : $Disk" -ForegroundColor Green
}

function Show-RiskWarning {
    Write-Host ''
    Write-Host '  [高风险] 融卡会清空 SD 卡，并且可能改变系统启动依赖。' -ForegroundColor Yellow
    Write-Host '  原工具提示：安全补丁在 2022-07 及以后的设备，融卡后存在无限重启风险。'
    Write-Host "  当前设备安全补丁：$script:Patch" -ForegroundColor Yellow
    Write-Host '  若没有可恢复的刷机方案，不建议直接执行。'
}

function Invoke-Merge {
    param(
        [ValidateSet('mixed', 'private')]
        [string]$Mode = 'mixed',
        [int]$SdRatio = 0
    )

    Write-Section '自动融卡'
    Write-Host '- 正在启动 ADB...'
    Initialize-Adb

    if (-not (Find-Device)) {
        Write-Host '[错误] 未找到已授权的 ADB 设备。' -ForegroundColor Red
        Write-Host '请开启 USB 调试，并在手机上允许本电脑调试。'
        return $false
    }

    $disk = Find-AdoptableDisk
    if (-not $disk) {
        Write-Host '[错误] 仍未找到可采纳的外置磁盘。' -ForegroundColor Red
        Write-Host '请确认 SD 卡已插入且未被系统占用。'
        return $false
    }

    Write-Host ''
    Write-DeviceSummary $disk
    Show-RiskWarning
    Write-Host ''

    if ($Mode -eq 'private') {
        $operationText = "sm partition $disk private"
        $partitionArgs = @('private')
    }
    else {
        if ($SdRatio -lt 10 -or $SdRatio -gt 90) {
            Write-Host '[错误] mixed 模式的 SD 卡比例必须在 10-90 之间。' -ForegroundColor Red
            return $false
        }
        $operationText = "sm partition $disk mixed $SdRatio"
        $partitionArgs = @('mixed', "$SdRatio")
    }

    Write-Host "  即将执行：$operationText" -ForegroundColor Yellow
    if ($Mode -eq 'private') {
        Write-Host '  整张 SD 卡将作为内部存储使用，系统会自动选择文件系统。'
        Write-Host '  当前内核支持 f2fs，Android 对 MMC 设备的 auto 规则预计会选择 f2fs。'
        Write-Host '  整卡私用后不能在相机、电脑或其他手机上直接当普通 SD 卡读取。'
    }
    else {
        Write-Host "  SD 卡保留 $SdRatio% 便携空间，其余作为内部存储。"
    }
    Write-Host '  此操作会清空 SD 卡。'
    $confirm = Read-Host '  输入 AGREE 继续，直接回车取消'
    if ($confirm -cne 'AGREE') {
        Write-Host '  已取消，未修改 SD 卡。' -ForegroundColor Cyan
        return $true
    }

    Write-Host ''
    Write-Host "- 正在格式化 SD 卡：$disk ..." -ForegroundColor Yellow
    $adbArgs = @('-s', $script:Serial, 'shell', 'sm', 'partition', $disk) + $partitionArgs
    $result = Invoke-Adb $adbArgs
    $result.Output | ForEach-Object { Write-Host "  $_" }

    if ($result.ExitCode -ne 0) {
        Write-Host "[错误] sm partition 返回错误代码 $($result.ExitCode)。" -ForegroundColor Red
        return $false
    }

    Write-Host ''
    Write-Host '  分区命令已完成。设备可能需要重启后才能看到新的存储空间。' -ForegroundColor Green
    return $true
}

function Invoke-Diagnose {
    Write-Section '只读诊断'
    Write-Host '- 正在启动 ADB...'
    Initialize-Adb

    if (-not (Find-Device)) {
        Write-Host '[错误] 未找到已授权的 ADB 设备。' -ForegroundColor Red
        return $false
    }

    $allDisks = Invoke-Adb @('-s', $script:Serial, 'shell', 'sm', 'list-disks')
    $disk = Find-AdoptableDisk
    Write-Host ''
    Write-DeviceSummary $(if ($disk) { $disk } else { '未找到' })
    Write-Host ''
    Write-Host '  sm list-disks 原始输出：'
    $allDisks.Output | ForEach-Object { Write-Host "    $_" }

    if ($disk) {
        Write-Host ''
        Write-Host '  SD 卡检测成功。诊断模式没有格式化任何存储。' -ForegroundColor Green
        return $true
    }

    Write-Host ''
    Write-Host '  [错误] 未找到可分区磁盘。' -ForegroundColor Red
    return $false
}

function Show-Menu {
    Clear-Host
    Write-Section '自动融卡 Android 16 修复版'
    Write-Host '  本工具会通过 ADB 将 SD 卡分区为内部存储和便携存储。'
    Write-Host '  SD 卡会被格式化，卡内所有数据都会丢失。'
    Write-Host ''
    Write-Host '  1 - 内部存储 25%，SD 卡 75%'
    Write-Host '  2 - 内部存储 50%，SD 卡 50%'
    Write-Host '  3 - 内部存储 75%，SD 卡 25%'
    Write-Host '  4 - 整张 SD 卡全部作为内部存储（整卡私用）'
    Write-Host '  5 - 自定义混合模式 SD 卡比例（10-90%）'
    Write-Host '  6 - 打开应用管理'
    Write-Host '  7 - 将 APK 安装至 SD 卡'
    Write-Host '  8 - 仅检测设备与 SD 卡（不格式化）'
    Write-Host '  0 - 退出'
    Write-Host ''
}

if ($Check) {
    try {
        $ok = Invoke-Diagnose
        if (-not $ok) { exit 1 }
        exit 0
    }
    catch {
        Write-Host ''
        Write-Host "[错误] $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    finally {
        Restore-AdbState
    }
}

try {
    while ($true) {
        Show-Menu
        $choice = Read-Host '请选择'

        switch ($choice) {
            '1' { Invoke-Merge -Mode mixed -SdRatio 75 | Out-Null; Read-Host '按回车返回菜单' | Out-Null }
            '2' { Invoke-Merge -Mode mixed -SdRatio 50 | Out-Null; Read-Host '按回车返回菜单' | Out-Null }
            '3' { Invoke-Merge -Mode mixed -SdRatio 25 | Out-Null; Read-Host '按回车返回菜单' | Out-Null }
            '4' { Invoke-Merge -Mode private | Out-Null; Read-Host '按回车返回菜单' | Out-Null }
            '5' {
                $ratio = Read-Host '请输入 SD 卡便携空间百分比（10-90）'
                $parsed = 0
                if ([int]::TryParse($ratio, [ref]$parsed) -and $parsed -ge 10 -and $parsed -le 90) {
                    Invoke-Merge -Mode mixed -SdRatio $parsed | Out-Null
                }
                else {
                    Write-Host '比例无效，应为 10-90 的整数。' -ForegroundColor Red
                }
                Read-Host '按回车返回菜单' | Out-Null
            }
            '6' {
                Initialize-Adb
                if (Find-Device) {
                    Invoke-Adb @('-s', $script:Serial, 'shell', 'am', 'start', 'com.android.settings/com.android.settings.applications.ManageApplications') | Out-Null
                    Write-Host '命令已发送。不同品牌的设置页面可能不支持此入口。'
                }
                else {
                    Write-Host '[错误] 未找到已授权的 ADB 设备。' -ForegroundColor Red
                }
                Read-Host '按回车返回菜单' | Out-Null
            }
            '7' {
                Initialize-Adb
                if (Find-Device) {
                    $apk = Read-Host '请拖入 APK 或输入完整路径'
                    if (-not [string]::IsNullOrWhiteSpace($apk)) {
                        $apk = $apk.Trim('"')
                        $result = Invoke-Adb @('-s', $script:Serial, 'install', '-s', '-r', $apk)
                        $result.Output | ForEach-Object { Write-Host "  $_" }
                    }
                }
                else {
                    Write-Host '[错误] 未找到已授权的 ADB 设备。' -ForegroundColor Red
                }
                Read-Host '按回车返回菜单' | Out-Null
            }
            '8' {
                Invoke-Diagnose | Out-Null
                Restore-AdbState
                Read-Host '按回车返回菜单' | Out-Null
            }
            '0' {
                exit 0
            }
            default {
                Write-Host '请输入 0-8。' -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }

        Restore-AdbState
    }
}
catch {
    Write-Host ''
    Write-Host "[错误] $($_.Exception.Message)" -ForegroundColor Red
    Read-Host '按回车退出' | Out-Null
    exit 1
}
finally {
    Restore-AdbState
}
