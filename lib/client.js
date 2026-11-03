/**
 * dsh-test-window — browser half.
 *
 * Seats one first-level settings section ("测试窗口") where the user picks the
 * display that test windows should open on, then optionally tries the choice
 * with a command. The host half owns display detection, process launch and the
 * window move; this bundle only drives the API and renders the result.
 *
 * Written as a hand-authored client module: the client module host loads it
 * through `window.__ModuleLoader__`, so no build step is involved.
 *
 * @module dsh-test-window/client
 */
window.__ModuleLoader__.load({
  id: 'dsh-test-window',
  factory: (require) => {
    var module = { exports: {} }
    var exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })

    const React = require('react')
    const h = React.createElement

    /** Locale namespace of the section. */
    const NS = 'dsh-test-window'

    /** Slot this section registers into, and its nav row id. */
    const SETTINGS_SECTION = 'settings.section'
    const SECTION_ID = 'dsh-test-window'

    /** Nav position: after the conversation usage section (152). */
    const SECTION_ORDER = 153

    /** Host API paths (document-relative: the GUI is served with `<base href="./">`). */
    const STATE_PATH = 'api/dsh-test-window/state'
    const CONFIG_PATH = 'api/dsh-test-window/config'
    const LAUNCH_PATH = 'api/dsh-test-window/launch'
    const STOP_PATH = 'api/dsh-test-window/stop'

    /** A launch waits for the window, so allow a generous request ceiling. */
    const FETCH_TIMEOUT_MS = 150000

    /** Locale dictionaries. */
    const dictionaries = {
      zh: { 'dsh-test-window.title': '测试窗口' },
      en: { 'dsh-test-window.title': 'Test window' },
    }

    // ---------------------------------------------------------------- helpers

    /**
     * Fetch JSON from the host half.
     * @param {string} path document-relative API path
     * @param {object} [options] fetch options
     * @returns {Promise<object>} parsed payload
     */
    async function apiFetch(path, options = {}) {
      const controller = typeof AbortController === 'function' ? new AbortController() : null
      const timer = controller ? setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS) : null
      try {
        const response = await fetch(path, {
          method: options.method || 'GET',
          headers: options.body ? { 'content-type': 'application/json' } : undefined,
          body: options.body ? JSON.stringify(options.body) : undefined,
          credentials: 'same-origin',
          signal: controller ? controller.signal : undefined,
        })
        const text = await response.text()
        let payload = null
        try {
          payload = text ? JSON.parse(text) : null
        } catch {
          payload = null
        }
        if (!response.ok) {
          const reason = payload && payload.error ? payload.error : `HTTP ${response.status}`
          throw new Error(reason)
        }
        return payload || {}
      } finally {
        if (timer) clearTimeout(timer)
      }
    }

    /**
     * Describe one display in a single line.
     * @param {object} display display record
     * @returns {string} summary text
     */
    function displaySummary(display) {
      return `${display.width} × ${display.height} · 位置 (${display.x}, ${display.y})`
    }

    // ----------------------------------------------------------------- styles

    const styles = {
      root: {
        display: 'flex',
        flexDirection: 'column',
        gap: '16px',
        padding: '4px 0 24px',
        maxWidth: '760px',
      },
      header: {
        display: 'flex',
        alignItems: 'flex-start',
        justifyContent: 'space-between',
        gap: '12px',
      },
      title: {
        fontSize: '15px',
        fontWeight: 600,
        lineHeight: 1.4,
      },
      subtitle: {
        marginTop: '4px',
        fontSize: '12px',
        opacity: 0.62,
        lineHeight: 1.6,
      },
      actionRow: {
        display: 'flex',
        alignItems: 'center',
        gap: '8px',
        flex: '0 0 auto',
      },
      ghostButton: {
        padding: '4px 10px',
        fontSize: '12px',
        lineHeight: '18px',
        borderRadius: '6px',
        border: '1px solid rgba(128,128,128,0.32)',
        background: 'transparent',
        color: 'inherit',
        cursor: 'pointer',
      },
      primaryButton: {
        padding: '5px 14px',
        fontSize: '13px',
        lineHeight: '18px',
        borderRadius: '6px',
        border: '1px solid transparent',
        background: '#5b8def',
        color: '#fff',
        cursor: 'pointer',
      },
      displayGrid: {
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))',
        gap: '10px',
      },
      displayCard: {
        position: 'relative',
        textAlign: 'left',
        padding: '12px 14px',
        borderRadius: '10px',
        border: '1px solid rgba(128,128,128,0.28)',
        background: 'transparent',
        color: 'inherit',
        cursor: 'pointer',
        lineHeight: 1.5,
      },
      displayCardActive: {
        border: '1px solid #5b8def',
        boxShadow: '0 0 0 1px rgba(91,141,239,0.35) inset',
      },
      displayName: {
        display: 'flex',
        alignItems: 'center',
        gap: '6px',
        fontSize: '13px',
        fontWeight: 600,
      },
      badge: {
        fontSize: '10px',
        fontWeight: 500,
        padding: '1px 6px',
        borderRadius: '999px',
        border: '1px solid rgba(128,128,128,0.4)',
        opacity: 0.75,
      },
      badgeActive: {
        border: '1px solid rgba(91,141,239,0.6)',
        color: '#5b8def',
        opacity: 1,
      },
      displayMeta: {
        marginTop: '4px',
        fontSize: '11.5px',
        opacity: 0.6,
      },
      group: {
        display: 'flex',
        flexDirection: 'column',
        gap: '10px',
        padding: '14px 16px',
        borderRadius: '10px',
        border: '1px solid rgba(128,128,128,0.2)',
      },
      groupTitle: {
        fontSize: '12px',
        fontWeight: 600,
        opacity: 0.7,
      },
      switchRow: {
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        gap: '12px',
        fontSize: '13px',
      },
      switchHint: {
        fontSize: '11.5px',
        opacity: 0.55,
        marginTop: '2px',
      },
      field: {
        display: 'flex',
        flexDirection: 'column',
        gap: '4px',
      },
      label: {
        fontSize: '12px',
        opacity: 0.7,
      },
      input: {
        width: '100%',
        boxSizing: 'border-box',
        padding: '6px 10px',
        fontSize: '13px',
        lineHeight: '20px',
        borderRadius: '6px',
        border: '1px solid rgba(128,128,128,0.32)',
        background: 'transparent',
        color: 'inherit',
        fontFamily: 'inherit',
      },
      checkbox: {
        width: '16px',
        height: '16px',
        accentColor: '#5b8def',
        cursor: 'pointer',
      },
      result: {
        fontSize: '12.5px',
        lineHeight: 1.6,
        padding: '10px 12px',
        borderRadius: '8px',
        border: '1px solid rgba(128,128,128,0.24)',
      },
      resultError: {
        border: '1px solid rgba(220,80,80,0.5)',
        color: '#d05050',
      },
      error: {
        fontSize: '12.5px',
        color: '#d05050',
      },
      muted: {
        fontSize: '12px',
        opacity: 0.55,
      },
    }

    // ------------------------------------------------------------------- view

    /**
     * The settings section body.
     * @returns {object} React element
     */
    function TestWindowPanel() {
      const [loading, setLoading] = React.useState(true)
      const [error, setError] = React.useState('')
      const [displays, setDisplays] = React.useState([])
      const [config, setConfig] = React.useState(null)
      const [running, setRunning] = React.useState([])
      const [command, setCommand] = React.useState('')
      const [cwd, setCwd] = React.useState('')
      const [busy, setBusy] = React.useState(false)
      const [result, setResult] = React.useState(null)

      /** Load displays plus the persisted choice. */
      const load = React.useCallback(async () => {
        setLoading(true)
        setError('')
        try {
          const payload = await apiFetch(STATE_PATH + '?refresh=1')
          setDisplays(Array.isArray(payload.displays) ? payload.displays : [])
          setConfig(payload.config || null)
          setRunning(Array.isArray(payload.running) ? payload.running : [])
          if (payload.error) setError(payload.error)
          if (payload.config) {
            setCommand(previous => previous !== '' ? previous : (payload.config.lastCommand || ''))
            setCwd(previous => previous !== '' ? previous : (payload.config.lastCwd || ''))
          }
        } catch (cause) {
          setError(cause instanceof Error ? cause.message : String(cause))
        } finally {
          setLoading(false)
        }
      }, [])

      React.useEffect(() => { load() }, [load])

      /**
       * Persist one config change.
       * @param {object} patch partial config
       */
      const saveConfig = React.useCallback(async (patch) => {
        setConfig(previous => previous ? { ...previous, ...patch } : previous)
        try {
          const payload = await apiFetch(CONFIG_PATH, { method: 'POST', body: patch })
          if (payload && payload.config) setConfig(payload.config)
        } catch (cause) {
          setError(cause instanceof Error ? cause.message : String(cause))
        }
      }, [])

      /** Select one display. */
      const chooseDisplay = React.useCallback((display) => {
        saveConfig({ displayIndex: display.index, device: display.device })
      }, [saveConfig])

      /** Launch the command entered above and move its window. */
      const launch = React.useCallback(async () => {
        const text = command.trim()
        if (text === '') {
          setResult({ ok: false, error: '请先填写启动命令' })
          return
        }
        setBusy(true)
        setResult(null)
        try {
          const payload = await apiFetch(LAUNCH_PATH, {
            method: 'POST',
            body: { command: text, cwd: cwd.trim() },
          })
          setResult(payload)
          if (payload && payload.display) {
            setConfig(previous => previous ? { ...previous, displayIndex: payload.display.index, device: payload.display.device } : previous)
          }
          if (payload && Array.isArray(payload.running)) setRunning(payload.running)
        } catch (cause) {
          setResult({ ok: false, error: cause instanceof Error ? cause.message : String(cause) })
        } finally {
          setBusy(false)
        }
      }, [command, cwd])

      /** Stop every window this plugin launched. */
      const stopAll = React.useCallback(async () => {
        setBusy(true)
        try {
          const payload = await apiFetch(STOP_PATH, { method: 'POST', body: {} })
          setResult({ ok: true, stopped: payload.stopped || [] })
          setRunning([])
        } catch (cause) {
          setResult({ ok: false, error: cause instanceof Error ? cause.message : String(cause) })
        } finally {
          setBusy(false)
        }
      }, [])

      const activeIndex = config ? Number(config.displayIndex) : -1

      const header = h('div', { style: styles.header }, [
        h('div', { key: 'text' }, [
          h('div', { key: 'title', style: styles.title }, '测试窗口显示位置'),
          h('div', { key: 'sub', style: styles.subtitle },
            '在这里选择测试窗口出现在哪块屏幕。Agent 通过 open_test_window 工具拉起的窗口会跟随这个设置，不会盖住 dsh 窗口。'),
        ]),
        h('div', { key: 'actions', style: styles.actionRow }, [
          h('button', {
            key: 'refresh',
            type: 'button',
            style: styles.ghostButton,
            onClick: load,
            disabled: loading,
          }, loading ? '刷新中…' : '刷新显示器'),
        ]),
      ])

      const displaySection = h('div', { key: 'displays', style: styles.displayGrid },
        displays.length === 0
          ? [h('div', { key: 'empty', style: styles.muted }, loading ? '正在读取显示器…' : '没有读到显示器')]
          : displays.map(display => {
            const active = display.index === activeIndex
            return h('button', {
              key: 'display-' + display.index,
              type: 'button',
              onClick: () => chooseDisplay(display),
              style: active ? { ...styles.displayCard, ...styles.displayCardActive } : styles.displayCard,
            }, [
              h('div', { key: 'name', style: styles.displayName }, [
                h('span', { key: 'n' }, `显示器 ${display.index}`),
                display.primary
                  ? h('span', { key: 'p', style: styles.badge }, '主屏')
                  : null,
                active
                  ? h('span', { key: 'a', style: { ...styles.badge, ...styles.badgeActive } }, '已选中')
                  : null,
              ]),
              h('div', { key: 'meta', style: styles.displayMeta }, displaySummary(display)),
              h('div', { key: 'dev', style: styles.displayMeta }, display.device),
            ])
          }))

      const optionSection = h('div', { key: 'options', style: styles.group }, [
        h('div', { key: 'title', style: styles.groupTitle }, '窗口行为'),
        h('label', { key: 'max', style: styles.switchRow }, [
          h('span', { key: 't' }, [
            h('div', { key: 'l' }, '启动后最大化'),
            h('div', { key: 'h', style: styles.switchHint }, '以最大化方式铺满所选显示器；程序自己覆盖最大化状态时，退化为铺满工作区的普通窗口'),
          ]),
          h('input', {
            key: 'i',
            type: 'checkbox',
            style: styles.checkbox,
            checked: Boolean(config && config.maximize),
            onChange: event => saveConfig({ maximize: event.target.checked }),
          }),
        ]),
        h('label', { key: 'top', style: styles.switchRow }, [
          h('span', { key: 't' }, [
            h('div', { key: 'l' }, '窗口置顶'),
            h('div', { key: 'h', style: styles.switchHint }, '保持在其它窗口之上'),
          ]),
          h('input', {
            key: 'i',
            type: 'checkbox',
            style: styles.checkbox,
            checked: Boolean(config && config.topMost),
            onChange: event => saveConfig({ topMost: event.target.checked }),
          }),
        ]),
        h('label', { key: 'focus', style: styles.field }, [
          h('span', { key: 'l', style: styles.label }, '窗口出来之后谁拿键盘焦点'),
          h('div', { key: 'h', style: styles.switchHint },
            '选「空闲时」：你正在打字或动鼠标时，新窗口只摆好位置不上前，不会被抢焦点打断；你停手了它才切到前面。'),
          h('select', {
            key: 'i',
            style: styles.input,
            value: config && config.focus ? config.focus : 'idle',
            onChange: event => saveConfig({ focus: event.target.value }),
          }, [
            h('option', { key: 'idle', value: 'idle' }, '空闲时才切到前台（推荐）'),
            h('option', { key: 'never', value: 'never' }, '从不抢焦点（只摆位置）'),
            h('option', { key: 'always', value: 'always' }, '总是切到前台'),
          ]),
        ]),
        h('label', { key: 'timeout', style: styles.field }, [
          h('span', { key: 'l', style: styles.label }, '等待窗口出现的超时（毫秒）'),
          h('input', {
            key: 'i',
            type: 'number',
            min: 1000,
            max: 120000,
            step: 1000,
            style: styles.input,
            value: config ? String(config.timeoutMs) : '',
            onChange: event => saveConfig({ timeoutMs: Number(event.target.value) || 20000 }),
          }),
        ]),
        h('label', { key: 'settle', style: styles.field }, [
          h('span', { key: 'l', style: styles.label }, '摆放校正时长（毫秒）'),
          h('div', { key: 'h', style: styles.switchHint },
            '窗口出现后继续纠正位置的时长。有些编辑器（如 Godot 4）会回写自己保存的窗口位置，时长太短会摆不正。'),
          h('input', {
            key: 'i',
            type: 'number',
            min: 0,
            max: 15000,
            step: 500,
            style: styles.input,
            value: config ? String(config.settleMs ?? 6000) : '',
            onChange: event => saveConfig({ settleMs: Number(event.target.value) }),
          }),
        ]),
      ])

      const launchSection = h('div', { key: 'launch', style: styles.group }, [
        h('div', { key: 'title', style: styles.groupTitle }, '试运行'),
        h('label', { key: 'cmd', style: styles.field }, [
          h('span', { key: 'l', style: styles.label }, '启动命令'),
          h('input', {
            key: 'i',
            type: 'text',
            style: styles.input,
            placeholder: '例如：godot --path D:/GC/MyGame  或  npm run dev',
            value: command,
            onChange: event => setCommand(event.target.value),
          }),
        ]),
        h('label', { key: 'cwd', style: styles.field }, [
          h('span', { key: 'l', style: styles.label }, '工作目录（可选）'),
          h('input', {
            key: 'i',
            type: 'text',
            style: styles.input,
            placeholder: '例如：D:/GC/MyGame',
            value: cwd,
            onChange: event => setCwd(event.target.value),
          }),
        ]),
        h('div', { key: 'actions', style: styles.actionRow }, [
          h('button', {
            key: 'go',
            type: 'button',
            style: styles.primaryButton,
            onClick: launch,
            disabled: busy,
          }, busy ? '处理中…' : '打开测试窗口'),
          h('button', {
            key: 'stop',
            type: 'button',
            style: styles.ghostButton,
            onClick: stopAll,
            disabled: busy,
          }, '停止我打开的窗口'),
          running.length > 0
            ? h('span', { key: 'n', style: styles.muted }, `正在运行 ${running.length} 个`)
            : null,
        ]),
      ])

      let resultNode = null
      if (result) {
        if (result.ok) {
          const parts = []
          const win = result.window || null
          if (result.display) parts.push(`已移动到 显示器 ${result.display.index}（${displaySummary(result.display)}）`)
          if (win && win.title) parts.push(`窗口标题：${win.title}`)
          if (win && win.width) parts.push(`矩形 ${win.width}×${win.height} @ ${win.x},${win.y}`)
          if (win && win.zoomed) parts.push('已最大化')
          else if (win && win.maximizeFellBack) parts.push('最大化被程序覆盖，改为铺满工作区')
          if (win && win.inside === false) parts.push('⚠ 没有完全落在屏内')
          if (win && win.attempts > 1) parts.push(`校正 ${win.attempts} 次`)
          if (win && win.pid) parts.push(`进程 ${win.pid}`)
          if (Array.isArray(result.stopped)) parts.push(`已停止 ${result.stopped.length} 个窗口`)
          if (result.note) parts.push(result.note)
          resultNode = h('div', { key: 'result', style: styles.result }, parts.join(' · ') || '完成')
        } else {
          const win = result.window || null
          const detail = win && win.width
            ? `（窗口矩形 ${win.width}×${win.height} @ ${win.x},${win.y}）`
            : ''
          resultNode = h('div', { key: 'result', style: { ...styles.result, ...styles.resultError } },
            (result.error || result.hint || '没有找到窗口') + detail)
        }
      }

      return h('div', { style: styles.root }, [
        header,
        error ? h('div', { key: 'err', style: styles.error }, error) : null,
        displaySection,
        config ? optionSection : null,
        launchSection,
        resultNode,
        h('div', { key: 'note', style: styles.muted },
          '选择会立即保存。Agent 调用 open_test_window 时如果没有显式指定显示器，就使用这里的设置。'),
      ])
    }

    // ------------------------------------------------------------------ mount

    /**
     * Seat the section, tolerating a slot host that is not ready yet.
     * @param {object} ctx client root context
     * @param {Function} label nav label resolver
     * @returns {() => void} disposer
     */
    function installSection(ctx, label) {
      let dispose
      let mounted = false
      const mount = () => {
        if (mounted || !ctx.slots) return
        try {
          if (typeof ctx.slots.spec === 'function' && ctx.slots.spec(SETTINGS_SECTION) === undefined) return
          dispose = ctx.slots.register({
            name: SETTINGS_SECTION,
            id: SECTION_ID,
            order: SECTION_ORDER,
            label,
            locale: NS,
            inject: () => ({}),
          }, TestWindowPanel)
          mounted = true
        } catch (cause) {
          // The loader may evaluate this bundle twice (combo row plus its own
          // row) or re-apply the plugin on a hot swap. A row already seated
          // under our id is the desired end state, not a mount failure.
          const message = cause && typeof cause.message === 'string' ? cause.message : ''
          if (message.includes('already has an entry with id')) {
            mounted = true
            return
          }
          console.warn('[dsh-test-window] section mount failed', cause)
        }
      }
      mount()
      if (!mounted && typeof ctx.on === 'function') {
        try {
          ctx.on('slots/changed', () => { if (!mounted) mount() })
        } catch {
          // Without the change feed the first attempt is all we get.
        }
      }
      return () => {
        if (typeof dispose === 'function') {
          try {
            dispose()
          } catch {
            // Already disposed.
          }
        }
        mounted = false
      }
    }

    /** Required services. */
    const inject = ['slots', 'locale']

    /**
     * Client plugin body: register the dictionary and seat the section.
     * @param {object} ctx client root context
     */
    function apply(ctx) {
      if (ctx && ctx.locale && typeof ctx.locale.register === 'function') {
        try {
          ctx.locale.register(NS, dictionaries)
        } catch {
          // A locale host that refuses the dictionary still gets a literal label.
        }
      }

      const label = () => {
        try {
          const translate = ctx.locale.bind(NS)
          const value = translate(NS + '.title')
          return typeof value === 'string' && value !== '' ? value : '测试窗口'
        } catch {
          return '测试窗口'
        }
      }

      const dispose = installSection(ctx, label)
      if (typeof ctx.effect === 'function') {
        ctx.effect(() => () => {
          try {
            dispose()
          } catch {
            // Section already gone.
          }
        }, 'dsh-test-window: settings section')
      }
    }

    exports.apply = apply
    exports.inject = inject
    return module.exports
  },
})
