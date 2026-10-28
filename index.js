/**
 * dsh-turn-notify — 对话完成 / 等待确认时的 Windows 右下角提示卡片。
 *
 * 宿主半边：
 *   - 监听 session/event 的 turn/end，按配置过滤（子代理、时长阈值、前台不打扰）
 *   - 组装标题 / 摘要 / 脚注，起一个 PowerShell 子进程画卡片
 *   - 监听 approval/request、user-questions/request，卡住时弹「等待你确认」
 *   - 注册一个本地路由，接收浏览器上报的主题色板和可见会话
 *
 * 不写会话日志、不进模型上下文。
 */
import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const TOAST_SCRIPT = join(HERE, 'notify.ps1')
const POWERSHELL = join(
  process.env.SystemRoot ?? 'C:\\Windows',
  'System32',
  'WindowsPowerShell',
  'v1.0',
  'powershell.exe',
)

const DEFAULTS = {
  enabled: true,
  minTurnSeconds: 30,
  seconds: 8,
  waitingSeconds: 20,
  sound: true,
  soundFile: 'Windows Notify System Generic.wav',
  skipWhenFocused: true,
  maxStack: 3,
  includeSubagents: false,
  showSnippet: true,
  width: 340,
  debounceMs: 800,
}

/** 值得打扰的结束原因：自己按停止、被 fork 掉的不打扰。 */
const REASONS = {
  completed: { label: '对话完成', tone: 'success' },
  error: { label: '出错了', tone: 'error' },
  'max-tokens': { label: '输出被截断', tone: 'warn' },
  blocked: { label: '已停止', tone: 'warn' },
}

const FALLBACK_THEME = {
  card: '#1f1f23',
  border: '#3a3a42',
  title: '#f0a07d',
  body: '#e8e8ee',
  meta: '#9a9aa4',
  success: '#4ade80',
  warn: '#fbbf24',
  error: '#f87171',
  font: 'Microsoft YaHei UI',
  fontSize: 14,
  scheme: 'dark',
}

const STACK_STEP = 96

export function apply(ctx, rawConfig = {}) {
  const opts = { ...DEFAULTS, ...rawConfig }
  if (opts.enabled === false) return
  if (!existsSync(TOAST_SCRIPT)) {
    console.error('[turn-notify] notify.ps1 不存在，插件不生效:', TOAST_SCRIPT)
    return
  }

  // ---- 客户端上报的状态 ------------------------------------------------
  const state = {
    theme: FALLBACK_THEME,
    focused: false,
    visibleSessionId: null,
  }

  const turnStart = new Map()
  const snippets = new Map()
  const pending = new Map()
  const slots = new Set()
  const waitingSeen = new Map()
  let lastSoundAt = 0

  // ---- 浏览器 → 宿主 的状态通道 ---------------------------------------
  let webServer = null
  try {
    webServer = ctx.get('webServer') ?? null
  } catch {
    webServer = null
  }

  if (webServer && typeof webServer.register === 'function') {
    ctx.effect(() =>
      webServer.register({
        kind: 'exact',
        path: '/turn-notify/state',
        handler: handleStateRequest,
      }),
    )
  }

  function handleStateRequest(req, res) {
    const reply = (code) => {
      try {
        res.statusCode = code
        res.end()
      } catch {}
    }
    if (req.method !== 'POST') return reply(405)
    const chunks = []
    let size = 0
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > 65536) {
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('error', () => {})
    req.on('end', () => {
      try {
        const body = JSON.parse(Buffer.concat(chunks).toString('utf8'))
        if (body && typeof body === 'object') {
          if (body.theme && typeof body.theme === 'object') {
            state.theme = { ...FALLBACK_THEME, ...body.theme }
          }
          if (typeof body.focused === 'boolean') state.focused = body.focused
          if (body.type === 'visible') {
            state.visibleSessionId = typeof body.sessionId === 'string' ? body.sessionId : null
          }
        }
      } catch {}
      reply(204)
    })
  }

  // ---- 会话事件 --------------------------------------------------------
  ctx.on('session/event', (session, event) => {
    if (!session || !event) return
    const id = String(session.id)

    if (event.type === 'turn/start') {
      cancelPending(id)
      turnStart.set(id, event.time)
      return
    }

    if (event.type === 'assistant/message') {
      const text = extractText(event.data?.message)
      if (text) snippets.set(id, text)
      return
    }

    if (event.type === 'turn/end') {
      const reason = event.data?.reason?.kind ?? 'completed'
      if (!REASONS[reason]) return
      if (!opts.includeSubagents && isSubagent(session)) return

      const started = turnStart.get(id)
      const duration = Number.isFinite(started) ? event.time - started : Number.POSITIVE_INFINITY
      if (duration < Number(opts.minTurnSeconds) * 1000) return

      cancelPending(id)
      const timer = setTimeout(() => {
        pending.delete(id)
        void notifyTurnEnd(session, reason, duration)
      }, Math.max(0, Number(opts.debounceMs) || 0))
      timer.unref?.()
      pending.set(id, timer)
    }
  })

  // ---- 卡住等你操作 ----------------------------------------------------
  ctx.on('approval/request', function (request, next) {
    try {
      maybeNotifyWaiting('approve', this, request)
    } catch {}
    return next()
  })

  ctx.on('user-questions/request', function (request, next) {
    try {
      maybeNotifyWaiting('question', this, request)
    } catch {}
    return next()
  })

  function maybeNotifyWaiting(kind, self, request) {
    if (opts.onWaiting === false) return
    const sessionId = firstString(
      self?.id,
      request?.agent?.id,
      request?.sessionId?.id,
      request?.sessionId,
    )
    if (!sessionId) return
    if (opts.skipWhenFocused && state.focused && state.visibleSessionId === sessionId) return

    const now = Date.now()
    const last = waitingSeen.get(sessionId) ?? 0
    if (now - last < 15000) return
    waitingSeen.set(sessionId, now)

    const theme = state.theme
    push({
      title: kind === 'approve' ? 'Harness · 等待你确认' : 'Harness · 等待你回答',
      body: kind === 'approve'
        ? '有一项操作需要你批准，Harness 停在这里等你。'
        : '有一个问题需要你回答，Harness 停在这里等你。',
      meta: '点一下关闭这张卡片',
      accent: theme.warn,
      seconds: Number(opts.waitingSeconds) || 20,
    })
  }

  // ---- 完成 → 组卡 -----------------------------------------------------
  async function notifyTurnEnd(session, reason, duration) {
    const id = String(session.id)
    if (opts.skipWhenFocused && state.focused && state.visibleSessionId === id) return

    const theme = state.theme
    const info = REASONS[reason]
    const cwdName = session.header?.cwd ? basename(session.header.cwd) : ''
    const title = (await readTitle(id)) || cwdName || 'Harness'
    const snippet = opts.showSnippet ? snippets.get(id) ?? '' : ''
    const metaParts = [info.label]
    const spent = formatDuration(duration)
    if (spent) metaParts.push(`用时 ${spent}`)
    if (cwdName) metaParts.push(cwdName)

    push({
      title: clip(title, 60),
      body: snippet ? clip(snippet, 120) : '这一轮已经结束，回到 Harness 查看结果。',
      meta: metaParts.join(' · '),
      accent: theme[info.tone] ?? theme.success,
      seconds: Number(opts.seconds) || 8,
      theme,
    })
  }

  async function readTitle(sessionId) {
    try {
      const query = ctx.get('sessionQuery')
      if (!query || typeof query.readTitle !== 'function') return ''
      const snapshot = await query.readTitle(sessionId)
      return typeof snapshot?.title === 'string' ? snapshot.title.trim() : ''
    } catch {
      return ''
    }
  }

  function cancelPending(sessionId) {
    const timer = pending.get(sessionId)
    if (timer) {
      clearTimeout(timer)
      pending.delete(sessionId)
    }
  }

  // ---- 起进程画卡片 ----------------------------------------------------
  function push(payload) {
    if (!existsSync(POWERSHELL)) {
      console.error('[turn-notify] 找不到 powershell.exe')
      return
    }
    const max = Math.max(1, Number(opts.maxStack) || 1)
    let slot = -1
    for (let i = 0; i < max; i += 1) {
      if (!slots.has(i)) {
        slot = i
        break
      }
    }
    if (slot < 0) return

    const now = Date.now()
    const playSound = opts.sound !== false && now - lastSoundAt > 1500
    if (playSound) lastSoundAt = now

    const theme = payload.theme ?? state.theme
    const body = {
      title: payload.title ?? 'Harness',
      body: payload.body ?? '',
      meta: payload.meta ?? '',
      accent: payload.accent ?? theme.success,
      seconds: payload.seconds ?? opts.seconds,
      sound: playSound,
      soundFile: opts.soundFile,
      width: Number(opts.width) || 340,
      slot,
      offset: slot * STACK_STEP,
      opacity: 1,
      // 不做淡入淡出：Opacity < 1 会把窗口变成分层窗口，文字会发虚。
      fade: false,
      font: theme.font,
      fontSize: theme.fontSize,
      colors: {
        card: theme.card,
        border: theme.border,
        title: theme.title,
        body: theme.body,
        meta: theme.meta,
      },
    }

    const encoded = Buffer.from(JSON.stringify(body), 'utf8').toString('base64')
    slots.add(slot)

    let child
    try {
      child = spawn(
        POWERSHELL,
        [
          '-NoProfile',
          '-NonInteractive',
          '-STA',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          TOAST_SCRIPT,
          '-PayloadB64',
          encoded,
        ],
        { windowsHide: true, stdio: 'ignore' },
      )
    } catch (error) {
      slots.delete(slot)
      console.error('[turn-notify] 启动提示进程失败:', error)
      return
    }

    const release = () => slots.delete(slot)
    child.on('exit', release)
    child.on('error', (error) => {
      release()
      console.error('[turn-notify] 提示进程出错:', error)
    })
  }
}

// ---- 小工具 ------------------------------------------------------------
function isSubagent(session) {
  const header = session.header
  if (!header) return false
  return header.origin === 'subagent' || Boolean(header.parentSession)
}

function extractText(message) {
  const content = message?.content
  if (!Array.isArray(content)) return ''
  const parts = []
  for (const block of content) {
    if (block && block.type === 'text' && typeof block.text === 'string') parts.push(block.text)
  }
  return parts.join('\n').trim()
}

function firstString(...values) {
  for (const value of values) {
    if (typeof value === 'string' && value) return value
  }
  return ''
}

function clip(text, max) {
  const flat = String(text).replace(/\s+/g, ' ').trim()
  if (flat.length <= max) return flat
  return `${flat.slice(0, max - 1)}…`
}

function formatDuration(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return ''
  const seconds = Math.round(ms / 1000)
  if (seconds < 60) return `${seconds} 秒`
  const minutes = Math.floor(seconds / 60)
  const rest = seconds % 60
  return rest ? `${minutes} 分 ${rest} 秒` : `${minutes} 分钟`
}
