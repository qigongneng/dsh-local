import { toFetchHandler } from '@deepseek-ai/dsh-host-apiproxy'
import { slimHistoryEvents } from './slim.js'

export const name = 'history-lite-local'
export const inject = ['webServer', 'apiProxy']

async function readBody(req) {
  const chunks = []
  for await (const chunk of req) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
  }
  return Buffer.concat(chunks)
}

function toRequest(req, body) {
  const url = new URL(req.url ?? '/', 'http://dsh.internal')
  const headers = new Headers()
  for (const [key, value] of Object.entries(req.headers)) {
    if (typeof value === 'string') headers.set(key, value)
    else if (Array.isArray(value)) headers.set(key, value.join(', '))
  }

  return new Request(url, {
    method: req.method ?? 'GET',
    headers,
    ...(body.length > 0 ? { body: new Uint8Array(body) } : {}),
    signal: AbortSignal.timeout(60_000),
  })
}

function sendJson(res, status, body, metrics) {
  const data = JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(data),
    'cache-control': 'no-store',
    'x-dsh-history-lite': 'local.1',
    ...(metrics === undefined ? {} : {
      'x-dsh-history-lite-before': String(metrics.before),
      'x-dsh-history-lite-after': String(metrics.after),
    }),
  })
  res.end(data)
}

function historyRoute(ctx) {
  return async (req, res) => {
    try {
      const body = await readBody(req)
      const response = await toFetchHandler(ctx.apiProxy).fetch(toRequest(req, body))
      const text = await response.text()

      let envelope
      try {
        envelope = JSON.parse(text)
      } catch {
        res.writeHead(response.status, Object.fromEntries(response.headers.entries()))
        res.end(text)
        return
      }

      let metrics
      const result = envelope?.result
      if (result?.ok === true && Array.isArray(result.value?.events)) {
        const before = result.value.events.length
        result.value.events = slimHistoryEvents(result.value.events)
        metrics = { before, after: result.value.events.length }
      }

      sendJson(res, response.status, envelope, metrics)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      sendJson(res, 500, {
        type: 'server-response',
        rpcId: 'history-lite-error',
        result: {
          ok: false,
          error: { code: 'internal', message, details: {} },
        },
      })
    }
  }
}

export function apply(ctx) {
  ctx.effect(() => {
    const disposers = [
      ctx.webServer.register({
        kind: 'exact',
        path: '/api/session.history',
        handler: historyRoute(ctx),
      }),
      ctx.webServer.register({
        kind: 'exact',
        path: '/api/subagent.history',
        handler: historyRoute(ctx),
      }),
    ]

    return () => {
      for (const dispose of disposers) dispose()
    }
  }, 'history-lite-local: compact finalized history chunks')
}

export { slimHistoryEvents } from './slim.js'
