/**
 * dsh-test-window — host half.
 *
 * Lets the user pin a display in Settings → 测试窗口, then starts a test program
 * (a Godot game, a preview server window, an editor …) and moves its window onto
 * that display, so a window the agent opens never lands on top of the dsh window.
 *
 * Two PowerShell helpers do the Windows work:
 *   - `displays.ps1`     enumerates the physical monitors (DPI-aware, physical pixels)
 *   - `watch-window.ps1` waits for the spawned process' window, moves it, maximizes
 *                        it, and keeps re-asserting the rectangle while the app
 *                        settles (engines restore their own saved geometry)
 *
 * Everything is exposed twice: as loopback-only JSON routes (the settings page)
 * and as the `open_test_window` tool (the agent), so a single choice in Settings
 * governs both paths.
 *
 * @module dsh-test-window
 */

import { execFile, spawn } from 'node:child_process'
import { existsSync, mkdirSync, openSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Plugin name used by the loader row. */
export const name = 'dsh-test-window'

/** Services this plugin needs mounted before its body runs. */
export const inject = ['webServer', 'tools']

/** Route prefix of the host API. */
const API_PREFIX = '/api/dsh-test-window'

/** Bumped whenever the persisted config shape changes. */
const CONFIG_VERSION = 1

/** Directory holding the two PowerShell helpers. */
const SCRIPT_DIR = join(dirname(fileURLToPath(import.meta.url)), 'scripts')

/** Defaults used until the user saves something else. */
const DEFAULT_CONFIG = {
  version: CONFIG_VERSION,
  displayIndex: 0,
  device: '',
  maximize: true,
  topMost: false,
  foreground: true,
  timeoutMs: 20000,
  // How long the watcher keeps re-asserting the rectangle after the window
  // appears. Editors such as Godot 4 restore their own saved geometry for a few
  // hundred milliseconds, so one placement is not enough.
  settleMs: 6000,
  lastCommand: '',
  lastCwd: '',
}

/** Resolve the DSH home directory. */
function dshHome() {
  const fromEnv = process.env.DSH_HOME
  if (typeof fromEnv === 'string' && fromEnv.trim() !== '') return fromEnv.trim()
  return join(homedir(), '.dsh')
}

/** Directory holding this plugin's persisted state. */
function stateDir() {
  const dir = join(dshHome(), 'dsh-test-window')
  mkdirSync(dir, { recursive: true })
  return dir
}

/** Marker written on mount so an outside health check can see the host half is live. */
function markerPath() {
  return join(stateDir(), 'applied.json')
}

/**
 * Best-effort mount marker: diagnostic only, never fatal.
 * @param {string} stage where the host half currently is
 * @param {object} [extra] extra diagnostics
 */
function writeMarker(stage, extra = {}) {
  try {
    writeFileSync(markerPath(), JSON.stringify({
      pid: process.pid,
      at: new Date().toISOString(),
      version: '0.1.0',
      stage,
      node: process.versions.node,
      ...extra,
    }, null, 2))
  } catch {
    // Diagnostic only.
  }
}

/** Where the selected display and the launch defaults are stored. */
function configPath() {
  return join(stateDir(), 'config.json')
}

/** Read the persisted config, falling back to the defaults. */
function readConfig() {
  try {
    const raw = JSON.parse(readFileSync(configPath(), 'utf8'))
    if (!raw || typeof raw !== 'object') return { ...DEFAULT_CONFIG }
    return { ...DEFAULT_CONFIG, ...raw, version: CONFIG_VERSION }
  } catch {
    return { ...DEFAULT_CONFIG }
  }
}

/**
 * Merge a patch into the persisted config.
 * @param {object} patch partial config
 * @returns {object} the stored config
 */
function writeConfig(patch) {
  const next = { ...readConfig(), ...patch, version: CONFIG_VERSION }
  writeFileSync(configPath(), JSON.stringify(next, null, 2))
  return next
}

/** Full path of the bundled Windows PowerShell, falling back to PATH. */
function powershellExe() {
  const root = process.env.SystemRoot || 'C:\\Windows'
  const full = join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  return full
}

/**
 * Run one PowerShell helper and parse its single JSON line.
 * @param {string} script file name inside `scripts/`
 * @param {string[]} args helper arguments
 * @param {number} timeoutMs hard limit for the helper process
 * @returns {Promise<object>} parsed helper output
 */
function runHelper(script, args, timeoutMs) {
  return new Promise((resolve, reject) => {
    execFile(
      powershellExe(),
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', join(SCRIPT_DIR, script), ...args],
      { windowsHide: true, timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 },
      (error, stdout, stderr) => {
        const text = String(stdout || '').trim()
        const lastLine = text.split(/\r?\n/).filter(line => line.trim() !== '').pop() || ''
        let parsed = null
        if (lastLine.startsWith('{') || lastLine.startsWith('[')) {
          try {
            parsed = JSON.parse(lastLine)
          } catch {
            parsed = null
          }
        }
        if (parsed) {
          resolve(parsed)
          return
        }
        if (error) {
          reject(new Error(`helper ${script} failed: ${error.message}${stderr ? ` :: ${String(stderr).slice(0, 400)}` : ''}`))
          return
        }
        reject(new Error(`helper ${script} returned no JSON: ${text.slice(0, 400)}`))
      },
    )
  })
}

/**
 * Enumerate the physical displays.
 * @returns {Promise<object[]>} normalized display records
 */
async function listDisplays() {
  const raw = await runHelper('displays.ps1', [], 20000)
  const items = Array.isArray(raw) ? raw : [raw]
  return items
    .filter(item => item && typeof item === 'object')
    .map(item => ({
      index: Number(item.index) || 0,
      device: String(item.device || ''),
      primary: Boolean(item.primary),
      x: Number(item.x) || 0,
      y: Number(item.y) || 0,
      width: Number(item.width) || 0,
      height: Number(item.height) || 0,
      workX: Number(item.workX) || 0,
      workY: Number(item.workY) || 0,
      workWidth: Number(item.workWidth) || 0,
      workHeight: Number(item.workHeight) || 0,
    }))
    .sort((a, b) => a.index - b.index)
}

/** Windows still running from this plugin, keyed by the launcher pid. */
const running = new Map()

/** Whether the caller comes from this machine. */
function isLocalRequest(req) {
  const address = req.socket && req.socket.remoteAddress
  if (!address) return false
  return address === '127.0.0.1'
    || address === '::1'
    || address === '::ffff:127.0.0.1'
    || address === 'localhost'
}

/** Write one JSON response. */
function writeJson(res, status, body) {
  const payload = JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'referrer-policy': 'no-referrer',
  })
  res.end(payload)
}

/**
 * Read a JSON request body.
 * @param {object} req incoming request
 * @param {number} [limit] maximum accepted size in bytes
 * @returns {Promise<object>} parsed body
 */
function readJsonBody(req, limit = 65536) {
  return new Promise((resolve, reject) => {
    let size = 0
    const chunks = []
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > limit) {
        reject(new Error('request body too large'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8').trim()
      if (text === '') {
        resolve({})
        return
      }
      try {
        resolve(JSON.parse(text))
      } catch (error) {
        reject(new Error(`invalid JSON body: ${error instanceof Error ? error.message : String(error)}`))
      }
    })
    req.on('error', reject)
  })
}

/**
 * Pick the display a launch should use.
 * @param {object[]} displays known displays
 * @param {object} config persisted config
 * @param {number|undefined} requested explicit index from the caller
 * @returns {object|undefined} the display to use
 */
function pickDisplay(displays, config, requested) {
  if (displays.length === 0) return undefined
  // Display indices are 1-based (that is what Settings shows and the tool
  // documents), so 0 or a negative number means "not specified".
  const wanted = Number.isFinite(requested) && Number(requested) >= 1
    ? Number(requested)
    : Number(config.displayIndex)
  const byIndex = displays.find(item => item.index === wanted)
  if (byIndex) return byIndex
  const byDevice = displays.find(item => item.device === config.device)
  if (byDevice) return byDevice
  return displays.find(item => item.primary) || displays[0]
}

/**
 * Poll until a path exists (used for the watcher's ready handshake).
 * @param {string} path file to wait for
 * @param {number} timeoutMs max wait
 * @returns {Promise<boolean>} true when the file showed up
 */
function waitForFile(path, timeoutMs) {
  return new Promise((resolve) => {
    const deadline = Date.now() + timeoutMs
    const tick = () => {
      if (existsSync(path)) {
        resolve(true)
        return
      }
      if (Date.now() >= deadline) {
        resolve(false)
        return
      }
      setTimeout(tick, 20)
    }
    tick()
  })
}

/**
 * Read the JSON the watcher writes once it placed the window.
 * @param {string} path result file
 * @param {number} timeoutMs max wait
 * @returns {Promise<object>} parsed result
 */
function readWatcherResult(path, timeoutMs) {
  return new Promise((resolve) => {
    const deadline = Date.now() + timeoutMs
    const tick = () => {
      if (existsSync(path)) {
        try {
          const text = readFileSync(path, 'utf8').replace(/^\uFEFF/, '').trim()
          const parsed = JSON.parse(text)
          if (parsed && typeof parsed === 'object') {
            resolve(parsed)
            return
          }
        } catch { /* still being written */ }
      }
      if (Date.now() >= deadline) {
        resolve({ ok: false, reason: 'watcher-timeout' })
        return
      }
      setTimeout(tick, 40)
    }
    tick()
  })
}

/**
 * Add engine hints so the window is created on the target display instead of
 * being moved there after its first paint (which is what causes the flash).
 * @param {string} command shell command
 * @param {object} display display descriptor
 * @param {unknown} enabled per-call override
 * @returns {string} command, possibly with extra flags
 */
function withDisplayHint(command, display, enabled) {
  if (enabled === false) return command
  const isGodot = /\bgodot[\w.-]*\.exe\b|\bgodot\b/i.test(command)
  if (!isGodot) return command
  const extras = []
  if (!/--position\b/.test(command)) extras.push(`--position "${display.workX},${display.workY}"`)
  if (!/--resolution\b/.test(command)) extras.push(`--resolution "${display.workWidth}x${display.workHeight}"`)
  if (extras.length === 0) return command
  return `${command} ${extras.join(' ')}`
}

/**
 * Start a command and move its window onto the configured display.
 * @param {object} input launch options
 * @returns {Promise<object>} launch result
 */
async function launch(input) {
  const config = readConfig()
  const command = String(input.command || config.lastCommand || '').trim()
  if (command === '') throw new Error('command is required: pass the program or shell command that opens the test window')
  const cwd = String(input.cwd || config.lastCwd || '').trim()
  const displays = await listDisplays()
  const display = pickDisplay(displays, config, input.displayIndex)
  if (!display) throw new Error('no display found on this machine')

  const maximize = input.maximize === undefined ? Boolean(config.maximize) : Boolean(input.maximize)
  const topMost = input.topMost === undefined ? Boolean(config.topMost) : Boolean(input.topMost)
  const foreground = input.foreground === undefined ? Boolean(config.foreground) : Boolean(input.foreground)
  const timeoutMs = Number.isFinite(input.timeoutMs) ? Number(input.timeoutMs) : Number(config.timeoutMs)
  const settleMs = Number.isFinite(input.settleMs)
    ? Math.max(0, Math.min(Number(input.settleMs), 15000))
    : Math.max(0, Math.min(Number(config.settleMs ?? 6000), 15000))
  const titleContains = String(input.titleContains || '')

  // Boot the watcher BEFORE the program: PowerShell needs ~400 ms to start, and
  // during that time Windows would happily paint the new window on the primary
  // display. The watcher writes a `.ready` file once it is polling, only then do
  // we spawn the program and hand over its process ids.
  const watchDir = join(stateDir(), 'watch')
  mkdirSync(watchDir, { recursive: true })
  const watchId = `${Date.now()}-${Math.round(Math.random() * 1e6)}`
  const pidFile = join(watchDir, `${watchId}.pids.json`)
  const outFile = join(watchDir, `${watchId}.result.json`)
  const readyFile = `${outFile}.ready`
  for (const path of [pidFile, outFile, readyFile]) {
    try { rmSync(path, { force: true }) } catch { /* ignore */ }
  }

  const finalCommand = withDisplayHint(command, display, input.displayHint)
  const watchArgs = [
    '-PidFile', pidFile,
    '-OutFile', outFile,
    '-X', String(display.workX),
    '-Y', String(display.workY),
    '-W', String(display.workWidth),
    '-H', String(display.workHeight),
    '-TimeoutMs', String(Math.max(1000, Math.min(timeoutMs, 120000))),
  ]
  if (maximize) watchArgs.push('-Maximize')
  if (topMost) watchArgs.push('-TopMost')
  if (foreground) watchArgs.push('-Foreground')
  // Give engines that restore their own saved geometry (Godot 4 editors) time
  // to do it before the watcher stops correcting the rectangle.
  watchArgs.push('-SettleMs', String(Math.round(settleMs)))
  if (titleContains !== '') watchArgs.push('-TitleContains', titleContains)
  // A launcher (cmd.exe, a game engine wrapper) rarely owns the window itself,
  // so the watcher always walks the descendant tree.
  watchArgs.push('-IncludeChildren')

  const watcher = spawn(
    powershellExe(),
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', join(SCRIPT_DIR, 'watch-window.ps1'), ...watchArgs],
    { windowsHide: true, stdio: ['ignore', openSync(join(watchDir, `${watchId}.log`), 'a'), openSync(join(watchDir, `${watchId}.log`), 'a')] },
  )
  watcher.unref()
  await waitForFile(readyFile, 8000)

  const child = spawn(finalCommand, {
    cwd: cwd !== '' ? cwd : undefined,
    shell: true,
    detached: true,
    stdio: 'ignore',
    windowsHide: false,
  })
  child.unref()
  const launcherPid = child.pid
  try {
    writeFileSync(pidFile, JSON.stringify({ pids: Number.isFinite(launcherPid) ? [launcherPid] : [] }), 'utf8')
  } catch { /* the watcher then falls back to any window */ }

  const startedAt = new Date().toISOString()
  const record = {
    launcherPid,
    command: finalCommand,
    cwd,
    startedAt,
    displayIndex: display.index,
    device: display.device,
    window: null,
  }

  let window = null
  try {
    window = await readWatcherResult(outFile, Math.max(15000, timeoutMs + 15000))
  } catch (error) {
    window = { ok: false, reason: 'helper-failed', error: error instanceof Error ? error.message : String(error) }
  }

  if (window && window.ok) {
    record.window = window
    running.set(String(launcherPid), record)
  }

  writeConfig({
    lastCommand: command,
    lastCwd: cwd,
    displayIndex: display.index,
    device: display.device,
  })

  return {
    ok: Boolean(window && window.ok),
    launcherPid,
    command: finalCommand,
    cwd,
    startedAt,
    display,
    window,
    note: window && window.ok && window.maximizeFellBack
      ? `窗口已经摆在显示器 ${display.index} 内，但这个程序会覆盖自己保存的最大化状态，所以用的是铺满工作区的普通窗口（${window.width}×${window.height} @ ${window.x},${window.y}）。`
      : window && window.ok && window.console
        ? `只找到了启动它的控制台窗口，已经摆到显示器 ${display.index}。如果程序自己打开了界面窗口，用 titleContains 指定那个窗口的标题。`
        : undefined,
    hint: window && window.ok
      ? undefined
      : window && window.reason === 'outside-target-display'
        ? `窗口已经打开，但没能在显示器 ${display.index} 内摆正（实际矩形 ${window.width}×${window.height} @ ${window.x},${window.y}，目标 ${display.workX},${display.workY} ${display.workWidth}×${display.workHeight}）。这个程序会覆盖自己保存的窗口位置；可以试试把设置里的「最大化」关掉，或换用 titleContains 命中它真正的主窗口。`
        : window && window.reason === 'window-closed'
          ? '窗口出现过，但随即关闭了——通常是程序启动失败或自己退出；可以先手动跑一遍这条命令看它报什么错。'
          : window && window.reason === 'watcher-timeout'
            ? `监听进程没有在 ${Math.round((timeoutMs + 15000) / 1000)} 秒内回报结果，可能是 PowerShell 被安全软件拦住。先手动跑一遍这条命令，看窗口是不是根本没起来。`
            : `命令已经启动，但在 ${Math.round(timeoutMs / 1000)} 秒内没有出现可见窗口。启动脚本（.bat / npm / steam:// 之类）常常在几秒后才拉起真正的程序，可以把 timeoutMs 调大；如果窗口的进程不属于这条命令（例如交给 explorer 打开），用 titleContains 按标题命中它。`,
  }
}

/**
 * Stop every window this plugin started.
 * @returns {Promise<object>} stop result
 */
async function stopAll() {
  const stopped = []
  for (const [key, record] of running.entries()) {
    const pid = record.launcherPid
    running.delete(key)
    if (!Number.isFinite(pid)) continue
    await new Promise((resolve) => {
      execFile('taskkill.exe', ['/PID', String(pid), '/T', '/F'], { windowsHide: true }, () => resolve())
    })
    stopped.push(pid)
  }
  return { ok: true, stopped }
}

/** Current state for the settings page. */
async function state() {
  const config = readConfig()
  let displays = []
  let error = null
  try {
    displays = await listDisplays()
  } catch (cause) {
    error = cause instanceof Error ? cause.message : String(cause)
  }
  if (displays.length > 0 && !displays.some(item => item.index === config.displayIndex)) {
    const fallback = displays.find(item => item.primary) || displays[0]
    config.displayIndex = fallback.index
    config.device = fallback.device
  }
  // Drop windows the user (or a crash) already closed, so the settings page does
  // not keep advertising processes that no longer exist.
  for (const [key, record] of running.entries()) {
    const pid = Number(record.launcherPid)
    if (!Number.isFinite(pid) || pid <= 0) { running.delete(key); continue }
    try {
      process.kill(pid, 0)
    } catch {
      running.delete(key)
    }
  }
  return {
    ok: error === null,
    error,
    config,
    displays,
    running: [...running.values()],
  }
}

/** The `/state` route. */
function stateRoute() {
  return {
    kind: 'exact',
    path: API_PREFIX + '/state',
    handler: async (req, res) => {
      if (!isLocalRequest(req)) {
        writeJson(res, 403, { ok: false, error: 'forbidden: loopback-only' })
        return
      }
      try {
        writeJson(res, 200, await state())
      } catch (error) {
        writeJson(res, 500, { ok: false, error: error instanceof Error ? error.message : String(error) })
      }
    },
  }
}

/** The `/config` route. */
function configRoute() {
  return {
    kind: 'exact',
    path: API_PREFIX + '/config',
    handler: async (req, res) => {
      if (!isLocalRequest(req)) {
        writeJson(res, 403, { ok: false, error: 'forbidden: loopback-only' })
        return
      }
      if (req.method !== 'POST') {
        writeJson(res, 405, { ok: false, error: 'method not allowed' })
        return
      }
      try {
        const body = await readJsonBody(req)
        const patch = {}
        if (body.displayIndex !== undefined && Number.isFinite(Number(body.displayIndex))) patch.displayIndex = Number(body.displayIndex)
        if (typeof body.device === 'string') patch.device = body.device
        if (typeof body.maximize === 'boolean') patch.maximize = body.maximize
        if (typeof body.topMost === 'boolean') patch.topMost = body.topMost
        if (typeof body.foreground === 'boolean') patch.foreground = body.foreground
        if (Number.isFinite(Number(body.timeoutMs))) patch.timeoutMs = Math.max(1000, Math.min(Number(body.timeoutMs), 120000))
        if (Number.isFinite(Number(body.settleMs))) patch.settleMs = Math.max(0, Math.min(Number(body.settleMs), 15000))
        if (typeof body.lastCommand === 'string') patch.lastCommand = body.lastCommand
        if (typeof body.lastCwd === 'string') patch.lastCwd = body.lastCwd
        writeJson(res, 200, { ok: true, config: writeConfig(patch) })
      } catch (error) {
        writeJson(res, 400, { ok: false, error: error instanceof Error ? error.message : String(error) })
      }
    },
  }
}

/** The `/launch` route. */
function launchRoute() {
  return {
    kind: 'exact',
    path: API_PREFIX + '/launch',
    handler: async (req, res) => {
      if (!isLocalRequest(req)) {
        writeJson(res, 403, { ok: false, error: 'forbidden: loopback-only' })
        return
      }
      if (req.method !== 'POST') {
        writeJson(res, 405, { ok: false, error: 'method not allowed' })
        return
      }
      try {
        const body = await readJsonBody(req)
        writeJson(res, 200, await launch(body))
      } catch (error) {
        writeJson(res, 500, { ok: false, error: error instanceof Error ? error.message : String(error) })
      }
    },
  }
}

/** The `/stop` route. */
function stopRoute() {
  return {
    kind: 'exact',
    path: API_PREFIX + '/stop',
    handler: async (req, res) => {
      if (!isLocalRequest(req)) {
        writeJson(res, 403, { ok: false, error: 'forbidden: loopback-only' })
        return
      }
      if (req.method !== 'POST') {
        writeJson(res, 405, { ok: false, error: 'method not allowed' })
        return
      }
      try {
        writeJson(res, 200, await stopAll())
      } catch (error) {
        writeJson(res, 500, { ok: false, error: error instanceof Error ? error.message : String(error) })
      }
    },
  }
}

/** The `open_test_window` tool definition handed to the agent runtime. */
function openTestWindowTool() {
  return {
    name: 'open_test_window',
    description: 'Open a test window (a game, an editor, a preview) on the display the user picked in dsh Settings → 测试窗口, instead of letting it appear over the dsh window. Use it whenever a task needs a visible program window on this machine. The display choice, maximize/topmost/foreground and the timeout come from the user settings unless you pass them explicitly. Returns the display it moved the window to, or a hint when no window appeared.',
    parameters: {
      type: 'object',
      properties: {
        command: {
          type: 'string',
          description: 'Program or shell command that opens the window, for example "godot --path D:/GC/MyGame" or "npm run dev".',
        },
        cwd: {
          type: 'string',
          description: 'Optional working directory for the command.',
        },
        displayIndex: {
          type: 'number',
          description: 'Optional display index that overrides the user setting (1-based, as shown in Settings).',
        },
        titleContains: {
          type: 'string',
          description: 'Optional substring of the window title, needed when the command hands the window to another process (a browser opened through the shell).',
        },
        maximize: {
          type: 'boolean',
          description: 'Optional override: maximize the window after moving it.',
        },
        topMost: {
          type: 'boolean',
          description: 'Optional override: keep the window above other windows (always-on-top) after moving it.',
        },
        foreground: {
          type: 'boolean',
          description: 'Optional override: raise the window to the foreground after moving it.',
        },
        timeoutMs: {
          type: 'number',
          description: 'Optional override: how long to wait for the window to appear, in milliseconds.',
        },
        settleMs: {
          type: 'number',
          description: 'Optional override: how long to keep correcting the window rectangle after it appears, in milliseconds (default 6000). Raise it for slow engines that restore their own window geometry.',
        },
      },
      required: ['command'],
      additionalProperties: false,
    },
    output: {
      schema: { type: 'object' },
      render: (_args, value) => {
        const win = value && value.window ? value.window : null
        const display = value && value.display ? value.display : null
        if (win && win.ok) {
          const where = display
            ? `显示器 ${display.index}（${display.width}×${display.height} @ ${display.x},${display.y}）`
            : '目标显示器'
          const shape = win.zoomed
            ? '已最大化'
            : win.maximizeFellBack
              ? '已铺满工作区（最大化被程序覆盖）'
              : '普通窗口'
          const fit = win.inside === false ? '，但没能完全落在屏内' : '，已完全落在屏内'
          return [{
            type: 'text',
            text: `已在${where}打开「${win.title || '窗口'}」，${shape}，窗口矩形 ${win.width}×${win.height} @ ${win.x},${win.y}，进程 ${win.pid}${fit}${win.attempts > 1 ? `（校正 ${win.attempts} 次）` : ''}。`,
          }]
        }
        const reason = win && win.reason
        const why = reason === 'outside-target-display'
          ? '窗口起来了，但程序把自己的位置又改回去了。'
          : reason === 'window-closed'
            ? '窗口出现过又立刻关闭了，多半是程序自己启动失败。'
            : reason === 'no-window' || reason === 'watcher-timeout'
              ? '命令跑起来了，但没有等到可见窗口。'
              : ''
        return [{
          type: 'text',
          text: `没能把窗口摆到目标显示器。${why}${value && value.hint ? ` ${value.hint}` : ''}`,
        }]
      },
    },
    execute: async (args) => {
      const result = await launch(args || {})
      // The runtime rejects tool output that is not lossless JSON, and an
      // `undefined` field (our `hint` when the window did appear) is exactly
      // what a JSON round-trip drops. Round-trip deliberately.
      return JSON.parse(JSON.stringify(result))
    },
    presentCall: (args) => ({
      card: 'generic',
      kind: 'write',
      title: `Open test window: ${args && args.command ? args.command : 'command'}`,
    }),
  }
}

/**
 * Host body: mount the JSON routes and the agent tool, then remember the shell
 * command so the settings page can offer it again.
 * @param {object} ctx host root context
 */
export function apply(ctx) {
  writeMarker('apply-start')
  let disposers = []
  try {
    disposers = [stateRoute(), configRoute(), launchRoute(), stopRoute()].map(route => ctx.webServer.register(route))
  } catch (error) {
    writeMarker('register-failed', { error: error instanceof Error ? error.stack : String(error) })
    throw error
  }
  writeMarker('routes-registered')

  let toolDisposer = null
  try {
    if (ctx.tools && typeof ctx.tools.register === 'function') {
      toolDisposer = ctx.tools.register(openTestWindowTool())
      writeMarker('tool-registered')
    }
  } catch (error) {
    // The settings page still works without the tool; record why it is missing.
    writeMarker('tool-register-failed', { error: error instanceof Error ? error.stack : String(error) })
  }

  ctx.effect(() => () => {
    for (const dispose of disposers) {
      try {
        dispose()
      } catch {
        // Route already gone.
      }
    }
    if (typeof toolDisposer === 'function') {
      try {
        toolDisposer()
      } catch {
        // Tool already gone.
      }
    }
  }, 'dsh-test-window: routes and tool')
}
