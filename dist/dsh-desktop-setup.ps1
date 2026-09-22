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
// Launcher for the DeepSeek Harness Web GUI.
//
// Starts `pnpm dsh web` in the Harness repository, captures the authenticated
// URL it prints, and hands it to Chrome in --app mode so the GUI gets a
// chromeless window instead of a browser tab. Started hidden by dsh-web.vbs;
// never run this file by double-clicking (a console window would appear).
//
// The repository is the directory named by the sibling dsh-web.config.json.
// Without that file the launcher's own directory is the repository, which is
// how an in-repo install (no installer involved) keeps working.
//
// Lifecycle: whichever launcher starts the server supervises it and stops it
// when the app window closes. A second launch while that window is open just
// brings it to the front. An orphaned server left by a crashed launcher is
// reclaimed on the next launch, but a `dsh web` started outside this shortcut
// is never touched.

import { spawn } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))

/**
 * Read the optional sidecar written by the desktop installer.
 * Any unreadable or malformed config degrades to an empty one rather than
 * failing the launch, so a broken config cannot make the app unopenable.
 */
function readConfig() {
  try {
    // A BOM survives a Notepad round-trip and would make JSON.parse throw.
    const text = readFileSync(join(HERE, 'dsh-web.config.json'), 'utf8').replace(/^\uFEFF/u, '')
    const parsed = JSON.parse(text)
    return typeof parsed === 'object' && parsed !== null ? parsed : {}
  } catch {
    return {}
  }
}

const CONFIG = readConfig()
const REPO_DIR = typeof CONFIG.repoPath === 'string' && CONFIG.repoPath.trim() !== ''
  ? CONFIG.repoPath
  : HERE
const PORT = Number.isInteger(CONFIG.port) && CONFIG.port > 0 ? CONFIG.port : 3080
const ORIGIN = `http://127.0.0.1:${String(PORT)}`
const LOCK_PATH = join(HERE, '.dsh-web.lock')
const LOG_PATH = join(HERE, 'dsh-web.log')
const LOCAL = process.env.LOCALAPPDATA ?? HERE
const PROFILE_DIR = typeof CONFIG.profileDir === 'string' && CONFIG.profileDir.trim() !== ''
  ? CONFIG.profileDir
  : join(LOCAL, 'dsh-web-app', 'chrome-profile')

/** A Chrome child that dies faster than this handed its window to a running browser. */
const HANDOFF_MS = 4000
/** `pnpm dsh web` compiles through tsx on a cold start; give it room. */
const BOOT_TIMEOUT_MS = 300_000

const URL_PATTERN = /dsh web:\s*(http:\/\/[^\s)]+)/u

function say(message) {
  try {
    appendFileSync(LOG_PATH, `[${new Date().toISOString()}] ${message}\n`)
  } catch {
    // A missing log file must never be the reason the app fails to start.
  }
}

function tellUser(message) {
  const box = join(LOCAL, 'Temp', 'dsh-web-message.txt')
  try {
    writeFileSync(box, `${message}\n\n日志：${LOG_PATH}\n`)
    const script = 'Add-Type -AssemblyName System.Windows.Forms; '
      + `$m = Get-Content -Raw -LiteralPath '${box}'; `
      + "[System.Windows.Forms.MessageBox]::Show($m, 'DeepSeek Harness', 'OK', 'Error') | Out-Null"
    const child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], {
      stdio: 'ignore',
      windowsHide: true,
    })
    child.on('error', () => {})
  } catch {
    // Reporting a failure is best effort; the log line below is the record.
  }
  say(`FAILED: ${message}`)
}

function chromeExecutable() {
  const pf = process.env.ProgramFiles ?? 'C:\\Program Files'
  const pf86 = process.env['ProgramFiles(x86)'] ?? 'C:\\Program Files (x86)'
  return [
    join(pf, 'Google', 'Chrome', 'Application', 'chrome.exe'),
    join(pf86, 'Google', 'Chrome', 'Application', 'chrome.exe'),
    join(LOCAL, 'Google', 'Chrome', 'Application', 'chrome.exe'),
    join(pf86, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
    join(pf, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
  ].find((candidate) => existsSync(candidate))
}

function pidAlive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

function readLock() {
  try {
    const parsed = JSON.parse(readFileSync(LOCK_PATH, 'utf8'))
    return typeof parsed?.pid === 'number' ? parsed : undefined
  } catch {
    return undefined
  }
}

function writeLock(serverPid) {
  try {
    writeFileSync(LOCK_PATH, JSON.stringify({ pid: process.pid, serverPid }))
  } catch {
    // Losing the lock file only costs orphan reclamation, not the launch.
  }
}

function releaseLock() {
  try {
    rmSync(LOCK_PATH, { force: true })
  } catch {
    // Best effort.
  }
}

/** Kill a process and its descendants (cmd.exe -> pnpm -> node). */
function killTree(pid) {
  return new Promise((resolve) => {
    const child = spawn('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true })
    child.on('error', () => resolve())
    child.on('exit', () => resolve())
  })
}

/**
 * Classify the port: our harness, free, or somebody else's.
 * The harness answers 401 to an unauthenticated root request and 200 once the
 * browser-session cookie is present, which no unrelated service imitates.
 */
async function probePort() {
  try {
    const response = await fetch(`${ORIGIN}/`, {
      redirect: 'manual',
      signal: AbortSignal.timeout(5000),
    })
    const status = response.status
    if (status === 200 || status === 401 || status === 303) return 'harness'
    return 'foreign'
  } catch {
    return 'free'
  }
}

async function waitForPortFree(timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (await probePort() === 'free') return true
    await new Promise((resolve) => setTimeout(resolve, 500))
  }
  return false
}

/** Folder name that identifies our dedicated Chrome profile in a process command line. */
const PROFILE_MARKER = 'dsh-web-app'

function powershell(script) {
  return new Promise((resolve) => {
    const child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], {
      windowsHide: true,
    })
    let out = ''
    child.stdout.on('data', (chunk) => { out += chunk.toString() })
    child.on('error', () => resolve(''))
    child.on('exit', () => resolve(out.trim()))
  })
}

/** PID of the app window's chrome.exe, matched by our profile and a visible window. */
async function appWindowPid() {
  const script = [
    'Get-CimInstance Win32_Process -Filter "name=\'chrome.exe\'"',
    `| Where-Object { $_.CommandLine -like '*${PROFILE_MARKER}*' }`,
    "| ForEach-Object { $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue; if ($p -and $p.MainWindowTitle -ne '') { $_.ProcessId } }",
  ].join(' ')
  const out = await powershell(script)
  const token = out.split(/\s+/u).find((part) => /^\d+$/u.test(part))
  return token === undefined ? undefined : Number.parseInt(token, 10)
}

/** Bring the running app window forward, waiting out a slow first boot. */
async function focusAppWindow(timeoutMs = 150_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const pid = await appWindowPid()
    if (pid !== undefined) {
      await powershell(`(New-Object -ComObject WScript.Shell).AppActivate(${String(pid)}) | Out-Null`)
      say(`已把窗口激活到前台（PID ${String(pid)}）`)
      return
    }
    await new Promise((resolve) => setTimeout(resolve, 2000))
  }
  say('等待窗口出现超时，未做任何改动')
}

function startServer() {
  const comspec = process.env.ComSpec ?? 'cmd.exe'
  return spawn(comspec, ['/d', '/s', '/c', `pnpm dsh web --no-open --port ${String(PORT)}`], {
    cwd: REPO_DIR,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
}

/** Resolve with the authenticated URL once the harness prints its startup line. */
function waitForUrl(child) {
  return new Promise((resolve, reject) => {
    let settled = false
    let buffer = ''
    const finish = (fn, value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      fn(value)
    }
    const timer = setTimeout(
      () => finish(reject, new Error(`启动超时（${String(BOOT_TIMEOUT_MS / 1000)} 秒内没有就绪）`)),
      BOOT_TIMEOUT_MS,
    )
    const onData = (chunk) => {
      const text = chunk.toString()
      buffer += text
      say(text.trimEnd())
      const match = URL_PATTERN.exec(buffer)
      if (match !== null) finish(resolve, match[1])
    }
    child.stdout.on('data', onData)
    child.stderr.on('data', onData)
    child.on('error', (error) => finish(reject, new Error(`无法启动服务：${error.message}`)))
    child.on('exit', (code) => finish(reject, new Error(`服务进程提前退出（exit ${String(code)}）`)))
  })
}

function openWindow(url) {
  const exe = chromeExecutable()
  if (exe === undefined) throw new Error('没有找到 Chrome 或 Edge，无法创建应用窗口')
  mkdirSync(PROFILE_DIR, { recursive: true })
  // The dedicated profile is what keeps the browser-session cookie across
  // restarts, so a later reuse launch does not need a fresh token.
  return spawn(exe, [
    `--app=${url}`,
    `--user-data-dir=${PROFILE_DIR}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--window-size=1400,900',
  ], { stdio: 'ignore', windowsHide: false })
}

function waitForExit(child) {
  return new Promise((resolve) => {
    child.on('error', () => resolve(0))
    child.on('exit', (code) => resolve(code ?? 0))
  })
}

async function main() {
  if (!existsSync(join(REPO_DIR, 'package.json'))) {
    tellUser(`找不到 Harness 仓库：${REPO_DIR}\n\n`
      + '请修正安装目录下 dsh-web.config.json 里的 repoPath，或重新运行安装脚本。')
    return
  }

  const lock = readLock()
  const supervisedWindowOpen = lock !== undefined && pidAlive(lock.pid)

  if (supervisedWindowOpen) {
    // Another launcher owns the running app. Reopening the clean URL here would
    // race the boot (and depend on a cookie that a first run may not have yet),
    // so surface the window that already exists instead.
    say('已有受管实例在运行，把窗口激活到前台')
    await focusAppWindow()
    return
  }

  // Reclaim a server only if we can prove this launcher started it.
  if (lock !== undefined && typeof lock.serverPid === 'number' && pidAlive(lock.serverPid)) {
    say(`回收上一次启动遗留的服务进程 ${String(lock.serverPid)}`)
    await killTree(lock.serverPid)
    await waitForPortFree()
  }

  const state = await probePort()
  if (state === 'foreign') {
    tellUser(`端口 ${String(PORT)} 被其他程序占用，请先释放该端口再启动。`)
    return
  }

  if (state === 'harness') {
    // Started outside this shortcut (for example from a terminal). Never stop it.
    say('检测到外部已运行的 dsh web，复用它并只开窗口')
    writeLock(null)
    await waitForExit(openWindow(`${ORIGIN}/`))
    releaseLock()
    return
  }

  const server = startServer()
  writeLock(server.pid)
  let url
  try {
    url = await waitForUrl(server)
  } catch (error) {
    tellUser(`${error.message}。请查看日志确认原因。`)
    await killTree(server.pid)
    releaseLock()
    return
  }
  say(`服务就绪：${url}`)

  const window = openWindow(url)
  const openedAt = Date.now()
  await waitForExit(window)
  const livedMs = Date.now() - openedAt

  if (livedMs < HANDOFF_MS) {
    // The window belongs to another browser process; keep the server for it.
    say(`窗口进程 ${String(livedMs)}ms 后退出（交给了已运行的浏览器），保留服务`)
  } else {
    say('窗口已关闭，停止服务')
    await killTree(server.pid)
  }
  releaseLock()
}

try {
  await main()
} catch (error) {
  tellUser(`启动失败：${error instanceof Error ? error.message : String(error)}`)
  process.exitCode = 1
}
'@

$vbsSource = @'
' Hidden starter for the DeepSeek Harness Web GUI.
'
' The shortcut targets this file through wscript.exe so no console window ever
' appears. Everything real happens in dsh-web-launcher.mjs next to it; keep the
' two files together.

Option Explicit

Dim shell, fso, here, nodeExe, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)

nodeExe = "C:\Program Files\nodejs\node.exe"
If Not fso.FileExists(nodeExe) Then
  nodeExe = "node.exe"
End If

command = """" & nodeExe & """ """ & here & "\dsh-web-launcher.mjs"""

shell.CurrentDirectory = here
' 0 = hidden window, False = do not wait for the launcher to finish.
shell.Run command, 0, False
'@

$uninstallerSource = @'
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
'@

$uninstallerCmdSource = @'
@echo off
rem Double-click entry point for dsh-web-uninstall.ps1.
rem ASCII only on purpose: the Chinese output comes from the PowerShell script,
rem which is written as UTF-8 with BOM so Windows PowerShell reads it correctly.
setlocal

rem Leave the install directory immediately: a directory that is some process's
rem current working directory cannot be removed, and the cleanup below has to
rem delete this one. Doing it before the pause also means the detached cleanup
rem never has to wait for a keypress.
cd /d "%TEMP%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-web-uninstall.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
pause

rem Keep both files when the run was cancelled or failed, so it can be retried.
if not "%RC%"=="0" exit /b

rem PowerShell can still hold the script handle for a moment after it exits, so retry.
set "PS1=%~dp0dsh-web-uninstall.ps1"
for /l %%i in (1,1,5) do (
  if exist "%PS1%" (
    del /f /q "%PS1%" 2>nul
    if exist "%PS1%" timeout /t 1 >nul
  )
)

rem The now-empty directory is removed by the detached cleanup script that
rem dsh-web-uninstall.ps1 scheduled, so no stray cmd error reaches the user.

(goto) 2>nul & del /f /q "%~f0"
'@

$docSource = @'
# DeepSeek Harness 桌面版

双击桌面上的 **DeepSeek Harness** 图标，即可在独立应用窗口中打开 Web 版对话界面，
不需要打开命令行 `cd` 到仓库再敲 `pnpm dsh web`。

## 这个目录里有什么

| 文件 | 作用 |
| --- | --- |
| `dsh-web.vbs` | 快捷方式实际调用的入口。用 `wscript.exe` 以隐藏窗口方式拉起启动器，全程不会闪现命令行黑框。 |
| `dsh-web-launcher.mjs` | 启动逻辑：起服务 → 抓取带 token 的 URL → 用 Chrome `--app` 模式开窗 → 关窗后停服务。 |
| `dsh-web.config.json` | 记录仓库路径、端口、浏览器数据目录、快捷方式位置。改端口或换仓库改这里即可。 |
| `icon.ico` | 快捷方式图标（安装时由你提供的图片生成）。 |
| `browser-data/` | 桌面版自己的浏览器数据（登录态 cookie 在这里，有效期 30 天），与日常用的 Chrome/Edge 完全隔离。 |
| `dsh-web-uninstall.cmd` / `.ps1` | 一键卸载。双击 `.cmd`，会先列出将删除的内容并要求确认。 |
| `dsh-web.log` | 运行日志。启动异常时先看这里。可随时删除，下次启动重建。 |

## 行为说明

- **启动**：首次启动需 20~45 秒（`dsh web` 会用 tsx 实时编译 TS），等待期间没有任何窗口，
  属于正常现象，不要重复点击。
- **窗口**：Chrome 应用窗口模式，没有地址栏、标签页和书签栏，看起来就是一个独立软件窗口。
- **关闭**：点窗口右上角 `×` 即等同于原来的 `Ctrl+C`——启动器会检测到窗口关闭并停掉服务。
  如果当时正在跑任务，任务会随之中断，和以前在终端里 `Ctrl+C` 的行为一致。
- **重复双击**：窗口已经开着时，再次双击只会把已有窗口激活到前台，
  不会重复起服务、也不会弹出端口占用错误。
- **不会动你手起的服务**：如果 `dsh web` 是你自己在终端里启动的，桌面版只会复用，不会杀掉它。

## 卸载

双击本目录下的 **`dsh-web-uninstall.cmd`**，输入 `y` 确认。

它删除的只有这个桌面版引入的内容：桌面快捷方式、本目录（含浏览器数据目录）。
它**不会碰**：

- Harness 仓库里的任何代码，也不改动仓库的 git 状态；
- Harness 数据目录 `~/.dsh`（会话记录、设置、凭据都在这里）；
- 命令行用法。卸载后 `pnpm dsh web` 照常可用。

> 卸载脚本带安全闸：只有在能确认"本目录确实是桌面版的安装目录"（配置文件存在且
> 其中记录的路径就是这里）时才执行删除，否则直接拒绝。所以即使误把它复制到别处运行，
> 也不会删掉无关文件。

## 重装 / 换端口 / 换仓库

- **换端口或换仓库**：编辑 `dsh-web.config.json`（`port` / `repoPath`）后重新双击图标。
- **重装**：运行安装程序 `dsh-desktop-setup.cmd`。它会依次询问四样：
  仓库路径 → 自定义图标 → **附带文件存放目录** → **快捷方式放哪个文件夹**。
  已存在的文件默认不覆盖，加 `-Force` 才强制重写。

  注意这两个位置是**分开的**：附带文件（本目录里这些）建议放在专属目录，
  例如 `%LOCALAPPDATA%\dsh-desktop`；快捷方式通常放桌面。把附带文件放在桌面会让
  桌面上多出一堆文件和一个浏览器数据目录，所以安装程序会拒绝把附带文件放进
  桌面、用户主目录、盘符根目录这类共享位置，但**快捷方式放桌面是完全正常的**。

## 排错

1. **看到错误弹窗**：弹窗会指明原因，详细信息在 `dsh-web.log` 里。
2. **窗口显示 `Unauthorized`**：浏览器配置里的 cookie 失效了。彻底关闭所有窗口后重新双击图标即可。
3. **提示找不到 Harness 仓库**：`dsh-web.config.json` 里的 `repoPath` 不对，
   或仓库被移动/删除了。修正后重新双击图标。
4. **端口被占用**：日志会写明。关闭占用该端口的程序，或改 `dsh-web.config.json` 里的端口。
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
