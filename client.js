/**
 * dsh-turn-notify 的浏览器半边。
 *
 * 它不渲染任何东西：只把"当前主题的真实色值"和"你正看着哪条会话 / 窗口是否在前台"
 * 报给宿主插件，宿主据此决定弹不弹、弹成什么颜色。
 */
window.__ModuleLoader__.load({
  id: '@local/dsh-turn-notify',
  factory(require) {
    const React = require('react')
    const ENDPOINT = '/turn-notify/state'

    function post(payload) {
      try {
        fetch(ENDPOINT, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(payload),
          keepalive: true,
        }).catch(() => {})
      } catch {}
    }

    function parseColor(value) {
      if (typeof value !== 'string') return null
      const text = value.trim()
      if (!text) return null

      let match = /^#([0-9a-f]{3})$/i.exec(text)
      if (match) {
        const [r, g, b] = match[1].split('').map((c) => parseInt(c + c, 16))
        return { r, g, b, a: 1 }
      }

      match = /^#([0-9a-f]{6})([0-9a-f]{2})?$/i.exec(text)
      if (match) {
        const n = parseInt(match[1], 16)
        return {
          r: (n >> 16) & 255,
          g: (n >> 8) & 255,
          b: n & 255,
          a: match[2] ? parseInt(match[2], 16) / 255 : 1,
        }
      }

      match = /^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:[,\s/]+([\d.]+%?))?\s*\)$/i.exec(text)
      if (match) {
        let alpha = 1
        if (match[4] !== undefined) {
          alpha = match[4].endsWith('%') ? parseFloat(match[4]) / 100 : parseFloat(match[4])
        }
        return { r: +match[1], g: +match[2], b: +match[3], a: alpha }
      }

      return null
    }

    function solid(value, backdrop) {
      const base = parseColor(backdrop) ?? { r: 31, g: 31, b: 35 }
      const color = parseColor(value)
      if (!color) return backdrop
      const blend = (front, back) => Math.round(color.a * front + (1 - color.a) * back)
      const hex = [blend(color.r, base.r), blend(color.g, base.g), blend(color.b, base.b)]
        .map((n) => Math.max(0, Math.min(255, n)).toString(16).padStart(2, '0'))
        .join('')
      return `#${hex}`
    }

    function token(name) {
      try {
        const body = getComputedStyle(document.body).getPropertyValue(name)
        if (body && body.trim()) return body.trim()
        const root = getComputedStyle(document.documentElement).getPropertyValue(name)
        return root ? root.trim() : ''
      } catch {
        return ''
      }
    }

    function pickFont(snapshot) {
      const families = snapshot && snapshot.fontFamilies
      if (families && typeof families === 'object') {
        const first = families.base || families.primary || Object.values(families).find((v) => typeof v === 'string')
        if (typeof first === 'string' && first) return first.split(',')[0].replace(/["']/g, '').trim()
      }
      return 'Microsoft YaHei UI'
    }

    function pickSize(snapshot) {
      const sizes = snapshot && snapshot.fontSizes
      if (sizes && typeof sizes === 'object') {
        const first = sizes.base || sizes.primary || Object.values(sizes).find((v) => typeof v === 'number')
        if (typeof first === 'number' && first > 0) return first
      }
      return 14
    }

    function mixHex(first, second, weight) {
      const a = parseColor(first)
      const b = parseColor(second)
      if (!a || !b) return first
      const mix = (x, y) => Math.round(weight * x + (1 - weight) * y)
      return `#${[mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b)]
        .map((n) => Math.max(0, Math.min(255, n)).toString(16).padStart(2, '0'))
        .join('')}`
    }

    function themeSnapshot(ctx) {
      let snapshot = null
      try {
        snapshot = ctx.theme.getTheme()
      } catch {}

      const card = solid(token('--dsw-alias-bg-overlay'), '#1f1f23')
      const primary = solid(token('--dsw-alias-label-primary'), '#f2f2f5')
      const secondary = solid(token('--dsw-alias-label-secondary'), '#c8c8d1')
      const success = solid(token('--dsw-alias-state-success-primary'), '#4ade80')
      const warn = solid(token('--dsw-alias-state-warn-primary'), '#fbbf24')
      const error = solid(token('--dsw-alias-state-error-primary'), '#f87171')

      return {
        theme: {
          card,
          border: solid(token('--dsw-alias-border-l1'), card),
          // 标题用主题的红 + 黄混出来的橘红，正文用主题自己的主文字色（鹅黄），
          // 脚注才降到次级灰 —— 弹窗上不出现"大段低对比文字"。
          title: mixHex(error, warn, 0.5),
          body: primary,
          meta: secondary,
          success,
          warn,
          error,
          font: pickFont(snapshot),
          fontSize: pickSize(snapshot),
          scheme: snapshot?.active?.colorScheme ?? 'dark',
        },
      }
    }

    function VisibleSession(props) {
      const sessionId = props && typeof props.sessionId === 'string' ? props.sessionId : null
      React.useEffect(() => {
        post({ type: 'visible', sessionId })
        return () => post({ type: 'visible', sessionId: null })
      }, [sessionId])
      return null
    }

    return {
      inject: ['theme', 'slots'],
      apply(ctx) {
        let lastSignature = ''
        const sendTheme = () => {
          const snapshot = themeSnapshot(ctx)
          const signature = JSON.stringify(snapshot)
          if (signature === lastSignature) return
          lastSignature = signature
          post({ type: 'state', ...snapshot, focused: document.hasFocus() })
        }
        sendTheme()

        ctx.effect(() => ctx.on('theme/change', sendTheme))

        // Belt and braces: some theme switches do not surface as theme/change
        // (e.g. a plugin re-registering the active theme). Poll cheaply.
        const poll = setInterval(sendTheme, 2000)
        ctx.effect(() => () => clearInterval(poll))

        const onFocus = () => post({ type: 'focus', focused: true })
        const onBlur = () => post({ type: 'focus', focused: false })
        window.addEventListener('focus', onFocus)
        window.addEventListener('blur', onBlur)
        ctx.effect(() => () => {
          window.removeEventListener('focus', onFocus)
          window.removeEventListener('blur', onBlur)
        })

        ctx.slots.inject('conversation.composer.dock', () =>
          ctx.slots.register(
            { name: 'conversation.composer.dock', id: 'turn-notify-session', order: 90 },
            VisibleSession,
          ),
        )
      },
    }
  },
})
