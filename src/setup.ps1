<#
    「DeepSeek Harness 专属桌面版」安装程序。

    只需要提供三样东西：
      1. 仓库的本地路径   —— 你 clone 下来的 deepseek-harness 目录
      2. 自定义图标文件   —— 任意图片（png/jpg/bmp/gif/ico），建议正方形
      3. 安装位置         —— 桌面版的专属目录，默认 %LOCALAPPDATA%\dsh-desktop

    不给参数直接双击也能用：会用弹窗依次询问这三样。

    它不会往你的仓库里写任何文件，也不会改动仓库的 git 状态。
    卸载请用安装目录下的 dsh-web-uninstall.cmd。
#>
[CmdletBinding()]
param(
    # 仓库本地路径（deepseek-harness 的 clone 目录）。
    [string]$RepoPath,
    # 自定义图标文件；留空则用系统默认图标。
    [string]$IconFile,
    # 附带文件（启动器、配置、图标、浏览器数据）的存放目录；默认 %LOCALAPPDATA%\dsh-desktop。
    [string]$InstallDir,
    # 快捷方式放在哪个文件夹；默认桌面。与附带文件目录分开，互不影响。
    [string]$ShortcutDir,
    # 监听端口；同机装多个副本时用不同端口。
    [int]$Port = 3080,
    # 桌面快捷方式的名称。
    [string]$ShortcutName = 'DeepSeek Harness',
    # 覆盖已存在的启动器文件。
    [switch]$Force,
    # 装完不自动打开窗口。
    [switch]$NoLaunch,
    # 全部参数都给齐时用，避免任何交互。
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# 含中文的 .ps1 必须带 BOM，Windows PowerShell 5.1 才会按 UTF-8 解析
$utf8Bom   = New-Object System.Text.UTF8Encoding($true)

function Write-Head($text) { Write-Host ''; Write-Host $text -ForegroundColor Cyan }
function Write-Ok($text)   { Write-Host ('  [通过] ' + $text) -ForegroundColor Green }
function Write-Note($text) { Write-Host ('  [注意] ' + $text) -ForegroundColor Yellow }
function Write-Bad($text)  { Write-Host ('  [失败] ' + $text) -ForegroundColor Red }

# here-string 不保留结尾换行，编辑器还可能写出 CRLF，
# 统一成「LF 换行 + 末尾恰好一个换行」后再比较和落盘。
# .cmd 需要 CRLF：LF 换行的批处理在 cmd.exe 下有已知的边界问题。
function Get-NormalizedText($text, [switch]$Crlf) {
    $normalized = (($text -replace "`r`n", "`n").TrimEnd("`n")) + "`n"
    if ($Crlf) { return ($normalized -replace "`n", "`r`n") }
    return $normalized
}

# ── 内嵌文件：脚本单独一份即可完成安装 ────────────────────────────────────

$launcherSource = @'
@@DSH_LAUNCHER_MJS@@
'@

$vbsSource = @'
@@DSH_WEB_VBS@@
'@

$uninstallerSource = @'
@@DSH_UNINSTALL_PS1@@
'@

$uninstallerCmdSource = @'
@@DSH_UNINSTALL_CMD@@
'@

$docSource = @'
@@DSH_DOC_MD@@
'@

# ── 交互式选择 ────────────────────────────────────────────────────────────

$script:dialogsReady = $null

function Test-Dialogs {
    if ($null -ne $script:dialogsReady) { return $script:dialogsReady }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $script:dialogsReady = $true
    } catch {
        $script:dialogsReady = $false
    }
    return $script:dialogsReady
}

function Select-FolderPath([string]$Description) {
    if (Test-Dialogs) {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = $Description
        $dialog.ShowNewFolderButton = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.SelectedPath
        }
        return $null
    }
    return (Read-Host $Description).Trim('"', ' ')
}

function Select-IconPath {
    if (Test-Dialogs) {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = '选择自定义图标文件（建议正方形图片）'
        $dialog.Filter = '图片文件|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.ico|所有文件|*.*'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.FileName
        }
        return $null
    }
    return (Read-Host '自定义图标文件路径（直接回车跳过）').Trim('"', ' ')
}

# ── 图标生成：任意图片 -> 多尺寸 .ico（纯 .NET，不依赖 Python）────────────

function New-MultiSizeIcon {
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$TargetPath
    )
    Add-Type -AssemblyName System.Drawing

    # 已经是 .ico 就直接用，不再重新编码
    if ([System.IO.Path]::GetExtension($SourceFile).ToLowerInvariant() -eq '.ico') {
        Copy-Item -LiteralPath $SourceFile -Destination $TargetPath -Force
        return 'copied'
    }

    $sizes = @(16, 24, 32, 48, 64, 128, 256)
    $source = [System.Drawing.Image]::FromFile($SourceFile)
    try {
        # 居中裁成正方形：非正方形图片会被系统拉伸变形
        $side  = [Math]::Min($source.Width, $source.Height)
        $cropX = [int](($source.Width - $side) / 2)
        $cropY = [int](($source.Height - $side) / 2)
        $crop  = New-Object System.Drawing.Rectangle($cropX, $cropY, $side, $side)

        $blobs = @()
        foreach ($size in $sizes) {
            $bitmap   = New-Object System.Drawing.Bitmap($size, $size)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $graphics.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $target = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
                $graphics.DrawImage($source, $target, $crop, [System.Drawing.GraphicsUnit]::Pixel)
            } finally {
                $graphics.Dispose()
            }
            $stream = New-Object System.IO.MemoryStream
            try {
                $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
                $blobs += ,$stream.ToArray()
            } finally {
                $stream.Dispose()
                $bitmap.Dispose()
            }
        }

        # ICO 容器：6 字节文件头 + 每张 16 字节目录项 + 各尺寸 PNG 数据
        $out    = New-Object System.IO.MemoryStream
        $writer = New-Object System.IO.BinaryWriter($out)
        try {
            $writer.Write([uint16]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]$blobs.Count)
            $offset = 6 + 16 * $blobs.Count
            for ($i = 0; $i -lt $blobs.Count; $i++) {
                $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
                $writer.Write([byte]$dim)
                $writer.Write([byte]$dim)
                $writer.Write([byte]0)
                $writer.Write([byte]0)
                $writer.Write([uint16]1)
                $writer.Write([uint16]32)
                $writer.Write([uint32]$blobs[$i].Length)
                $writer.Write([uint32]$offset)
                $offset += $blobs[$i].Length
            }
            foreach ($blob in $blobs) { $writer.Write($blob) }
            $writer.Flush()
            [System.IO.File]::WriteAllBytes($TargetPath, $out.ToArray())
        } finally {
            $writer.Dispose()
            $out.Dispose()
        }
        return ('generated:' + $side)
    } finally {
        $source.Dispose()
    }
}

# ── 开工 ──────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host 'DeepSeek Harness 专属桌面版 - 安装程序' -ForegroundColor Cyan
Write-Host '需要三样东西：仓库路径、自定义图标、安装位置。' -ForegroundColor DarkGray

# 1) 仓库路径
Write-Head '第 1 步：Harness 仓库的本地路径'
if (-not $RepoPath) {
    $RepoPath = Select-FolderPath '选择你 clone 的 deepseek-harness 目录（内含 package.json）'
}
if (-not $RepoPath) { Write-Bad '没有选择仓库路径，安装中止。'; exit 1 }
$RepoPath = [System.IO.Path]::GetFullPath($RepoPath)
if (-not (Test-Path -LiteralPath $RepoPath)) { Write-Bad ('路径不存在：' + $RepoPath); exit 1 }

$manifestPath = Join-Path $RepoPath 'package.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Bad ('这个目录里没有 package.json，看起来不是仓库根目录：' + $RepoPath)
    exit 1
}
try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Bad 'package.json 无法解析，安装中止。'
    exit 1
}
$cliEntry = Join-Path $RepoPath 'apps\cli\src\bin.ts'
if ($manifest.scripts.dsh -and (Test-Path -LiteralPath $cliEntry)) {
    Write-Ok ('仓库：' + $RepoPath + '（' + $manifest.name + ' ' + $manifest.version + '）')
} else {
    Write-Bad '这个目录缺少 dsh 启动脚本或 apps/cli/src/bin.ts，不是 deepseek-harness 仓库'
    exit 1
}

# 2) 环境检查
Write-Head '第 2 步：检查运行环境'
$blockers = @()

$nodeExe = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $nodeExe) {
    Write-Bad 'PATH 里找不到 node'
    $blockers += '安装 Node.js 22.19+ 或 24+：https://nodejs.org/'
} else {
    $rawVersion = (& node -v) 2>$null
    $nodeVersion = [version]$rawVersion.TrimStart('v', 'V')
    if (($nodeVersion.Major -ge 24) -or ($nodeVersion.Major -eq 22 -and $nodeVersion.Minor -ge 19)) {
        Write-Ok ("node $rawVersion")
    } else {
        Write-Bad ("node $rawVersion 版本过低（需要 22.19+ 或 24+）")
        $blockers += '升级 Node.js 到 22.19+ 或 24+'
    }
}

$pnpmExe = Get-Command pnpm -ErrorAction SilentlyContinue
if ($null -eq $pnpmExe) {
    Write-Bad 'PATH 里找不到 pnpm'
    $blockers += '安装 pnpm：npm install -g pnpm'
} else {
    # 必须在仓库目录里问：package.json 的 packageManager 会决定 pnpm 用哪个版本
    Push-Location $RepoPath
    try { $pnpmVersion = (& pnpm -v) 2>$null } finally { Pop-Location }
    Write-Ok ('pnpm ' + $pnpmVersion)
}

$browserCandidates = New-Object System.Collections.Generic.List[string]
foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
    if (-not [string]::IsNullOrWhiteSpace($base)) {
        $browserCandidates.Add((Join-Path $base 'Google\Chrome\Application\chrome.exe'))
    }
}
foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
    if (-not [string]::IsNullOrWhiteSpace($base)) {
        $browserCandidates.Add((Join-Path $base 'Microsoft\Edge\Application\msedge.exe'))
    }
}
$browser = $browserCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($browser) {
    Write-Ok ('浏览器：' + $browser)
} else {
    Write-Bad '没有找到 Chrome 或 Edge'
    $blockers += '安装 Google Chrome 或 Microsoft Edge'
}

# 仓库必须已经构建过：dsh web 直接用构建产物，不会自动重新构建
$distIndex = Join-Path $RepoPath 'apps\web\dist\index.html'
$hostLib   = Join-Path $RepoPath 'packages\bundle\web-app\lib\index.js'
if ((Test-Path -LiteralPath $distIndex) -and (Test-Path -LiteralPath $hostLib)) {
    Write-Ok '仓库构建产物齐全'
} else {
    Write-Bad '仓库还没构建（缺少 apps/web/dist 或 packages/bundle/web-app/lib）'
    $blockers += ('在仓库目录依次执行：pnpm install，然后 pnpm run build')
}

if ($blockers.Count -gt 0) {
    Write-Head '还差这些，先处理完再运行本安装程序：'
    $blockers | ForEach-Object { Write-Host ('  · ' + $_) }
    Write-Host ''
    exit 1
}

# 3) 附带文件存放目录（程序文件）
Write-Head '第 3 步：附带文件存放目录（启动器、配置、图标、浏览器数据）'
if (-not $InstallDir) {
    if ($Silent) {
        $InstallDir = Join-Path $env:LOCALAPPDATA 'dsh-desktop'
    } else {
        $chosen = Select-FolderPath ('选择附带文件存放目录（默认 ' + (Join-Path $env:LOCALAPPDATA 'dsh-desktop') + '）')
        $InstallDir = if ($chosen) { $chosen } else { Join-Path $env:LOCALAPPDATA 'dsh-desktop' }
    }
}
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)

# 安全闸：卸载器靠「清空并删除安装目录」工作，所以安装目录必须是专属目录。
# 一旦把它指到桌面、主目录或盘符根目录，卸载就等于删掉那些目录里的全部文件。
$installTrimmed = $InstallDir.TrimEnd('\')
$forbidden = @(
    [Environment]::GetFolderPath('Desktop')
    [Environment]::GetFolderPath('UserProfile')
    [Environment]::GetFolderPath('MyDocuments')
    $HOME
    $env:SystemRoot
    $env:ProgramFiles
    ${env:ProgramFiles(x86)}
    $env:ProgramData
)
foreach ($bad in $forbidden) {
    if ($bad -and ($installTrimmed -ieq $bad.TrimEnd('\'))) {
        Write-Bad ('不能把安装目录设为 ' + $bad)
        Write-Host ''
        Write-Host '  卸载脚本会清空并删除整个安装目录，指向这类位置会连带删除里面的其他文件。'
        Write-Host ('  请另选一个专属目录，例如 ' + (Join-Path $env:LOCALAPPDATA 'dsh-desktop'))
        Write-Host ''
        exit 1
    }
}
if ($installTrimmed -match '^[A-Za-z]:$') {
    Write-Bad ('不能把安装目录设为盘符根目录：' + $InstallDir)
    Write-Host ('  请另选一个专属目录，例如 ' + (Join-Path $env:LOCALAPPDATA 'dsh-desktop'))
    exit 1
}

# 已存在的目录必须么是空的、要么已经是一个本桌面版安装，否则拒绝——
# 不然卸载时会连同里面原有的文件一起删掉。
if ((Test-Path -LiteralPath $InstallDir) -and ((Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)) {
    $looksLikeOurs = (Test-Path -LiteralPath (Join-Path $InstallDir 'dsh-web.config.json')) -and
                     (Test-Path -LiteralPath (Join-Path $InstallDir 'dsh-web-launcher.mjs')) -and
                     (Test-Path -LiteralPath (Join-Path $InstallDir 'dsh-web.vbs'))
    if (-not $looksLikeOurs) {
        Write-Bad ('安装目录不是空的，而且看起来不是本桌面版的安装目录：' + $InstallDir)
        Write-Host ''
        Write-Host '  卸载脚本会删除整个安装目录，装在非空目录里会连带删掉里面原有的文件，'
        Write-Host ('  所以拒绝继续。请换一个空目录，例如 ' + (Join-Path $env:LOCALAPPDATA 'dsh-desktop'))
        Write-Host ''
        Write-Host '  该目录现有内容（最多列出 10 项）：'
        Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue |
            Select-Object -First 10 | ForEach-Object { Write-Host ('    ' + $_.Name) }
        Write-Host ''
        exit 1
    }
}

if (-not (Test-Path -LiteralPath $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Write-Ok ('已创建附带文件目录：' + $InstallDir)
} else {
    Write-Ok ('附带文件目录：' + $InstallDir)
}

# 4) 快捷方式位置（与附带文件分开：快捷方式通常放桌面，程序文件不该堆在桌面上）
Write-Head '第 4 步：桌面快捷方式的位置'
if (-not $ShortcutDir) {
    if ($Silent) {
        $ShortcutDir = [Environment]::GetFolderPath('Desktop')
    } else {
        $chosen = Select-FolderPath ('选择快捷方式放在哪个文件夹（默认：桌面 ' + [Environment]::GetFolderPath('Desktop') + '）')
        $ShortcutDir = if ($chosen) { $chosen } else { [Environment]::GetFolderPath('Desktop') }
    }
}
$ShortcutDir = [System.IO.Path]::GetFullPath($ShortcutDir)
if (-not (Test-Path -LiteralPath $ShortcutDir)) {
    New-Item -ItemType Directory -Path $ShortcutDir -Force | Out-Null
    Write-Ok ('已创建并选用：' + $ShortcutDir)
} else {
    Write-Ok ('快捷方式位置：' + $ShortcutDir)
}

# 5) 图标
Write-Head '第 5 步：自定义桌面图标'
$iconTarget = Join-Path $InstallDir 'icon.ico'
if (-not $IconFile) {
    if (-not $Silent) { $IconFile = Select-IconPath }
}
if ($IconFile) {
    $IconFile = [System.IO.Path]::GetFullPath($IconFile)
    if (Test-Path -LiteralPath $IconFile) {
        try {
            $result = New-MultiSizeIcon -SourceFile $IconFile -TargetPath $iconTarget
            if ($result -eq 'copied') {
                Write-Ok ('图标：直接使用 ' + $IconFile)
            } else {
                Write-Ok ('图标：由 ' + (Split-Path -Leaf $IconFile) + ' 生成（源图短边 ' + $result.Split(':')[1] + 'px，居中裁成正方形）')
            }
        } catch {
            Write-Note ('图标处理失败（' + $_.Exception.Message + '），改用系统默认图标')
            $iconTarget = $null
        }
    } else {
        Write-Note ('图标文件不存在：' + $IconFile + '，改用系统默认图标')
        $iconTarget = $null
    }
} else {
    Write-Note '未提供图标，桌面快捷方式将使用系统默认图标'
    $iconTarget = $null
}

# 6) 写出文件
Write-Head '第 6 步：写入桌面版文件'

function Write-TextFile {
    param([string]$Path, [string]$Content, [string]$Label, [switch]$Crlf, [switch]$Bom)
    $wanted = Get-NormalizedText $Content -Crlf:$Crlf
    if ((Test-Path -LiteralPath $Path) -and (-not $Force)) {
        $existing = [System.IO.File]::ReadAllText($Path)
        $sameText = (Get-NormalizedText $existing -Crlf:$Crlf) -eq $wanted
        # 含中文的 .ps1 少了 BOM，Windows PowerShell 会按 ANSI 读，
        # 中文变乱码并直接语法报错，所以 BOM 状态也要校验并修正。
        $sameBom = (Test-HasBom $Path) -eq [bool]$Bom
        if ($sameText -and $sameBom) {
            Write-Ok ($Label + ' 已是最新')
            return
        }
        if (-not $sameText) {
            Write-Note ($Label + ' 已存在且内容不同，保留现有（加 -Force 可覆盖）')
            return
        }
        Write-Note ($Label + ' 编码缺少 BOM，正在修正（否则中文会变乱码）')
    }
    $encoding = if ($Bom) { $utf8Bom } else { $utf8NoBom }
    [System.IO.File]::WriteAllText($Path, $wanted, $encoding)
    Write-Ok ($Label + ' 已写入')
}

function Test-HasBom([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

$launcherPath  = Join-Path $InstallDir 'dsh-web-launcher.mjs'
$vbsPath       = Join-Path $InstallDir 'dsh-web.vbs'
$uninstallPs1  = Join-Path $InstallDir 'dsh-web-uninstall.ps1'
$uninstallCmd  = Join-Path $InstallDir 'dsh-web-uninstall.cmd'
$docPath       = Join-Path $InstallDir 'dsh-web-launcher.md'

# 清掉上一次卸载可能留下的"正在移除"标记。若还有旧的清理进程在轮询，标记消失会让它
# 放弃删除，从而不会把这次刚装好的内容吃掉（"卸载后立刻重装"的场景）。
$staleMarker = Join-Path $InstallDir '.dsh-web-removing'
if (Test-Path -LiteralPath $staleMarker) {
    Remove-Item -LiteralPath $staleMarker -Force -ErrorAction SilentlyContinue
}

Write-TextFile -Path $launcherPath -Content $launcherSource    -Label 'dsh-web-launcher.mjs'
Write-TextFile -Path $vbsPath      -Content $vbsSource         -Label 'dsh-web.vbs'
Write-TextFile -Path $uninstallPs1 -Content $uninstallerSource -Label 'dsh-web-uninstall.ps1' -Bom
Write-TextFile -Path $uninstallCmd -Content $uninstallerCmdSource -Label 'dsh-web-uninstall.cmd' -Crlf
Write-TextFile -Path $docPath      -Content $docSource         -Label 'dsh-web-launcher.md'

# 桌面版自己的浏览器数据目录，放在安装目录内，卸载时一并清除
$profileDir  = Join-Path $InstallDir 'browser-data'
$shortcutPath = Join-Path $ShortcutDir ($ShortcutName + '.lnk')

# 不带 BOM：Node 的 JSON.parse 不认 BOM
$config = [ordered]@{
    repoPath     = $RepoPath
    installDir   = $InstallDir
    port         = $Port
    profileDir   = $profileDir
    shortcutPath = $shortcutPath
    shortcutName = $ShortcutName
    installedAt  = (Get-Date).ToString('s')
}
[System.IO.File]::WriteAllText(
    (Join-Path $InstallDir 'dsh-web.config.json'),
    ($config | ConvertTo-Json),
    $utf8NoBom
)
Write-Ok 'dsh-web.config.json 已写入（仓库路径、端口、图标、快捷方式）'

# 7) 快捷方式
Write-Head '第 7 步：创建快捷方式'
$shell = New-Object -ComObject WScript.Shell

# 同名快捷方式若指向另一个安装，绝不能默默覆盖：那会毁掉别人装好的桌面版。
if (Test-Path -LiteralPath $shortcutPath) {
    $existingLink = $shell.CreateShortcut($shortcutPath)
    if ($existingLink.Arguments -and ($existingLink.Arguments -notlike ('*' + $vbsPath + '*'))) {
        Write-Note ('桌面上已有同名快捷方式，指向另一个安装：' + $existingLink.Arguments)
        $baseName = $ShortcutName
        $suffix = 2
        while ((Test-Path -LiteralPath $shortcutPath) -and ($suffix -le 99)) {
            $ShortcutName = $baseName + ' (' + [string]$suffix + ')'
            $shortcutPath = Join-Path $ShortcutDir ($ShortcutName + '.lnk')
            $suffix++
        }
        Write-Note ('为避免覆盖，本次使用名称：' + $ShortcutName)
        $config['shortcutPath'] = $shortcutPath
        $config['shortcutName'] = $ShortcutName
        [System.IO.File]::WriteAllText(
            (Join-Path $InstallDir 'dsh-web.config.json'),
            ($config | ConvertTo-Json),
            $utf8NoBom
        )
    }
}

$link  = $shell.CreateShortcut($shortcutPath)
$link.TargetPath       = Join-Path $env:SystemRoot 'System32\wscript.exe'
$link.Arguments        = '"' + $vbsPath + '"'
$link.WorkingDirectory = $InstallDir
$link.Description      = 'DeepSeek Harness Web GUI'
$link.WindowStyle      = 1
if ($iconTarget -and (Test-Path -LiteralPath $iconTarget)) {
    $link.IconLocation = $iconTarget + ',0'
}
$link.Save()
Write-Ok ('快捷方式：' + $shortcutPath)

# 8) 完成
Write-Head '安装完成'
Write-Host ('  快捷方式  : ' + $shortcutPath)
Write-Host ('  附带文件  : ' + $InstallDir)
Write-Host ('  仓库      : ' + $RepoPath)
Write-Host ('  端口      : ' + $Port + '   浏览器数据: ' + $profileDir)
Write-Host ''
Write-Host '  双击快捷方式即可使用。首次启动需要 20~45 秒（dsh web 要用 tsx 编译，'
Write-Host '  期间没有窗口，属正常）。关闭窗口等同于停掉服务。'
Write-Host ''
Write-Host ('  卸载：双击 ' + $uninstallCmd)
Write-Host '  改端口或换仓库：编辑 dsh-web.config.json 后重新双击图标即可。'
Write-Host ''

if (-not $NoLaunch) {
    Write-Host '  正在打开...'
    & wscript.exe $vbsPath
}

exit 0
