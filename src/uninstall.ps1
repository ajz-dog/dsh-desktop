<#
    卸载「DeepSeek Harness 专属桌面版」。

    只删除本安装目录及其桌面快捷方式，不会碰 Harness 仓库、也不会碰 ~/.dsh
    里的会话与设置。卸载后仓库的命令行用法（pnpm dsh web）照常可用。
#>
[CmdletBinding()]
param(
    # 跳过确认提示，直接执行。
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$installDir  = $PSScriptRoot
$configPath  = Join-Path $installDir 'dsh-web.config.json'
$lockFile    = Join-Path $installDir '.dsh-web.lock'

# 配置由安装脚本写入；读不到就退化成默认值，不影响卸载。
# 必须显式按 UTF-8 读：配置文件是无 BOM 的 UTF-8，而 PowerShell 5.1 的
# Get-Content 默认按系统 ANSI 代码页解码——路径里只要含中文就会读成乱码，
# 解析失败后安全闸会拒绝卸载，等于安装目录带中文就卸不掉。
$config = @{}
if (Test-Path -LiteralPath $configPath) {
    try {
        $parsed = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $parsed.PSObject.Properties) { $config[$property.Name] = $property.Value }
    } catch {
        Write-Host '  （配置文件无法解析，将按默认路径处理）' -ForegroundColor Yellow
    }
}

$shortcutPath = if ($config['shortcutPath']) { $config['shortcutPath'] }
                else { Join-Path ([Environment]::GetFolderPath('Desktop')) 'DeepSeek Harness.lnk' }
$profileDir   = if ($config['profileDir']) { $config['profileDir'] }
                else { Join-Path $env:LOCALAPPDATA 'dsh-web-app' }
$repoPath     = $config['repoPath']

# ── 安全闸 ────────────────────────────────────────────────────────────────
# 本脚本靠「清空并删除安装目录」工作，所以必须先确认这里确实是本桌面版的
# 安装目录。若安装目录被误设为桌面、主目录之类的位置，没有这道闸就会把那些
# 目录连同里面的文件一起删掉。
$verified = $false
if ((Test-Path -LiteralPath $configPath) -and
    (Test-Path -LiteralPath (Join-Path $installDir 'dsh-web-launcher.mjs')) -and
    (Test-Path -LiteralPath (Join-Path $installDir 'dsh-web.vbs'))) {
    $declared = $config['installDir']
    if ($declared -and ($declared.TrimEnd('\') -ieq $installDir.TrimEnd('\'))) { $verified = $true }
}

$alsoForbidden = @(
    [Environment]::GetFolderPath('Desktop')
    [Environment]::GetFolderPath('UserProfile')
    [Environment]::GetFolderPath('MyDocuments')
    $HOME
    $env:SystemRoot
    $env:ProgramFiles
    ${env:ProgramFiles(x86)}
    $env:ProgramData
)
foreach ($bad in $alsoForbidden) {
    if ($bad -and ($installDir.TrimEnd('\') -ieq $bad.TrimEnd('\'))) { $verified = $false }
}
if ($installDir.TrimEnd('\') -match '^[A-Za-z]:$') { $verified = $false }

if (-not $verified) {
    Write-Host ''
    Write-Host '拒绝卸载：无法确认这是本桌面版的安装目录。' -ForegroundColor Red
    Write-Host ''
    Write-Host ('  当前所在目录：' + $installDir)
    Write-Host '  本脚本会清空并删除它所在的整个目录，因此只有在能确认'
    Write-Host '  （配置文件存在、且其中记录的安装目录就是这里）时才继续。'
    Write-Host ''
    Write-Host '  如果这个目录确实是本桌面版的安装目录，但文件已不完整，'
    Write-Host '  请手动删除该目录，不会影响 Harness 仓库和 ~/.dsh 里的数据。'
    Write-Host ''
    exit 1
}

Write-Host ''
Write-Host '卸载「DeepSeek Harness 专属桌面版」' -ForegroundColor Cyan
Write-Host ''
Write-Host '将删除：'
Write-Host ('  {0} {1}   (桌面快捷方式)' -f $(if (Test-Path -LiteralPath $shortcutPath) { '[删除]    ' } else { '[已不存在]' }), $shortcutPath)
Write-Host ('  [删除]     {0}   (安装目录：启动器、配置、卸载脚本自身)' -f $installDir)
Write-Host ('  {0} {1}   (独立浏览器配置目录)' -f $(if (Test-Path -LiteralPath $profileDir) { '[删除]    ' } else { '[已不存在]' }), $profileDir)
Write-Host ''
Write-Host '不会碰：' -ForegroundColor Green
if ($repoPath) { Write-Host ('  - Harness 仓库：' + $repoPath) }
Write-Host ('  - {0}（会话记录、设置、凭据）' -f (Join-Path $HOME '.dsh'))
Write-Host '  - 命令行用法：在仓库目录执行 pnpm dsh web 即可'
Write-Host ''

if (-not $Force) {
    # 删除不可逆，所以"输入被重定向/管道"不算确认——只有在真实控制台里
    # 看到提示并输入 y 才算。否则一次被截断的管道调用就可能静默卸载。
    if ([Console]::IsInputRedirected) {
        Write-Host ''
        Write-Host '拒绝卸载：当前不是交互式运行，无法完成确认。' -ForegroundColor Red
        Write-Host '  请在资源管理器里双击同目录的 dsh-web-uninstall.cmd；'
        Write-Host '  确实要无人值守执行时，显式加 -Force 参数。'
        Write-Host ''
        exit 1
    }
    $answer = Read-Host '确认卸载？输入 y 回车继续，其他任意键取消'
    if ($answer -notmatch '^(y|Y|yes|YES)$') {
        Write-Host ''
        Write-Host '已取消，未做任何改动。' -ForegroundColor Yellow
        exit 1
    }
}

Write-Host ''
Write-Host '正在停止运行中的窗口与服务...' -ForegroundColor Cyan

# 关掉本安装开的窗口。窗口一关，监管它的启动器会自行停掉服务。
$marker = if ($profileDir) { Split-Path -Leaf $profileDir } else { 'dsh-web-app' }
$windows = @(
    Get-CimInstance Win32_Process -Filter "name='chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like ('*' + $profileDir + '*') -or $_.CommandLine -like ('*' + $marker + '*') }
)
foreach ($window in $windows) {
    Stop-Process -Id $window.ProcessId -Force -ErrorAction SilentlyContinue
}
if ($windows.Count -gt 0) {
    Write-Host ('  已关闭 {0} 个应用窗口，等待服务自行退出...' -f $windows.Count)
    Start-Sleep -Seconds 3
}

# 兜底：只回收本安装启动过的服务（记录在锁文件里的进程），
# 不碰用户在终端里手动起 dsh web。
if (Test-Path -LiteralPath $lockFile) {
    $lock = Get-Content -LiteralPath $lockFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue | ConvertFrom-Json
    foreach ($candidate in @($lock.pid, $lock.serverPid)) {
        if (-not $candidate) { continue }
        if (Get-Process -Id $candidate -ErrorAction SilentlyContinue) {
            Write-Host ('  结束遗留进程 PID {0}' -f $candidate)
            & taskkill /PID $candidate /T /F 2>$null | Out-Null
        }
    }
}

Write-Host ''
Write-Host '正在删除快捷方式与安装目录...' -ForegroundColor Cyan

if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
    Write-Host ('  已删除 ' + $shortcutPath)
}

if (Test-Path -LiteralPath $profileDir) {
    Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ('  已删除 ' + $profileDir)
}

# 安装目录最后删：此刻脚本自身正在其中运行，先清理其余内容，
# 再把自删交给外层的 .cmd 处理。
Get-ChildItem -LiteralPath $installDir -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'dsh-web-uninstall.cmd' -and $_.Name -ne 'dsh-web-uninstall.ps1' } |
    ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
Write-Host ('  已清空 ' + $installDir + '（残留的卸载脚本与空目录随后自动清除）')

# 留下"正在移除"标记。脱离的清理脚本必须看到这个标记才肯删目录：
# 它最多轮询一分钟，如果这期间有人在同一路径重新安装，安装脚本会清掉这个标记，
# 清理脚本随即放弃——不会把刚装好的内容吃棹。缺少这道保险时，一次"卸载后马上重装"
# 就可能被仍在轮询的旧清理进程删掉。
$markerPath = Join-Path $installDir '.dsh-web-removing'
[System.IO.File]::WriteAllText($markerPath, (Get-Date).ToString('s'), $utf8NoBom)

# 本脚本和它的 .cmd 都住在安装目录里，进程无法删除自己所在的目录：
#   · rd 不带 /s 只能删空目录，而目录里还有正在运行的 .cmd
#   · rd /s /q 能删掉，但会让 cmd.exe 之后读不到脚本、吐出一行报错
# 所以交给一个脱离的临时脚本轮询：等外层 .cmd 退出后再删掉整个目录。
try {
    $cleanupPath = Join-Path $env:TEMP ('dsh-cleanup-' + [guid]::NewGuid().ToString('N') + '.cmd')
    $cleanupBody = @"
@echo off
set /a tries=0
:wait
set /a tries+=1
if not exist "$markerPath" goto :done
rd /s /q "$installDir" 2>nul
if not exist "$installDir" goto :done
if %tries% geq 60 goto :done
ping -n 2 127.0.0.1 >nul
goto :wait
:done
(goto) 2>nul & del /f /q "%~f0"
"@
    # 批处理文件必须用 CRLF：cmd.exe 在 ( ) 代码块里遇到 LF 换行会解析错乱。
    # 同时按系统 ANSI 代码页写出，中文路径才能被 cmd 正确读取。
    $cleanupText = $cleanupBody -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($cleanupPath, $cleanupText, [System.Text.Encoding]::Default)
    # 关键：工作目录必须设在安装目录之外。否则这个清理进程自己就会占住
    # 安装目录（它是继承来的工作目录），rd 永远报"另一个程序正在使用此文件"。
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') `
        -ArgumentList '/c', $cleanupPath -WorkingDirectory $env:TEMP -WindowStyle Hidden | Out-Null
} catch {
    Write-Host ('  自动清理安装目录失败，请手动删除：' + $installDir) -ForegroundColor Yellow
}

Write-Host ''
Write-Host '卸载完成。' -ForegroundColor Green
if ($repoPath) {
    Write-Host ('仓库未受影响：cd "' + $repoPath + '" 后执行 pnpm dsh web 即可。')
}
Write-Host ''
exit 0
