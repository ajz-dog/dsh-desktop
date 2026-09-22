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
