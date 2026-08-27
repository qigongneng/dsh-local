/**
 * @deepseek-ai/dsh-host-history-lite — host plugin that shrinks history
 * payloads before they leave the server.
 *
 * The core `session.history` implementation returns every raw
 * `assistant/chunk` delta inside the selected message window. A long
 * reasoning/streaming turn can therefore turn a 50-message page into tens of
 * thousands of tiny JSON events, which is slow to serialize, transfer, parse,
 * and assemble on the client.
 *
 * This plugin registers exact `/api/session.history` (and
 * `/api/subagent.history`) routes, which take precedence over the generic
 * `/api` prefix route. It calls the normal ApiProxy handler, then thins the
 * returned events:
 *
 * - finalized steps keep only their final `assistant/message`, the first token
 *   delta, and usage chunks;
 * - in-progress / interrupted steps keep all chunks so partial rendering and
 *   the trajectory view remain intact.
 *
 * Live streaming is not touched: this only changes what the history RPC sends
 * when replaying already-recorded events.
 *
 * @module @deepseek-ai/dsh-host-history-lite
 */

import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-host-webserver'
import type { WebRoute } from '@deepseek-ai/dsh-host-webserver'
import type {} from '@deepseek-ai/dsh-host-apiproxy'
import { toFetchHandler } from '@deepseek-ai/dsh-host-apiproxy'
import type { IncomingMessage, ServerResponse } from 'node:http'

/** Cordis plugin name. */
export const name = 'history-lite'

/** Required services: the HTTP server and the core API gateway. */
export const inject = ['webServer', 'apiProxy']

/** Chunk delta types that count as a visible first token. */
function isTokenDelta(chunk: { type?: string; text?: string; argumentsDelta?: string; name?: unknown } | undefined): boolean {
  if (chunk === undefined) return false
  switch (chunk.type) {
    case 'text-delta':
    case 'reasoning-delta':
      return typeof chunk.text === 'string' && chunk.text !== ''
    case 'tool-call-delta':
      return chunk.argumentsDelta !== '' || chunk.name !== undefined
    default:
      return false
  }
}

interface WireEntry {
  event: {
    type?: string
    data?: {
      turn?: number
      step?: number
      chunk?: { type?: string; text?: string; argumentsDelta?: string; name?: unknown; usage?: unknown }
    }
  }
  view?: unknown
}

/**
 * Compact one history page.
 *
 * For each step that already has an `assistant/message`, all non-essential
 * `assistant/chunk` deltas are dropped. Steps without a final message are kept
 * whole because the client still needs the chunk stream to reconstruct an
 * in-progress or interrupted partial.
 */
export function slimHistoryEvents(entries: readonly WireEntry[]): WireEntry[] {
  const finalizedSteps = new Set<string>()
  for (const entry of entries) {
    const event = entry.event
    if (event?.type !== 'assistant/message') continue
    const turn = event.data?.turn
    const step = event.data?.step
    if (typeof turn === 'number' && typeof step === 'number') {
      finalizedSteps.add(`${turn}:${step}`)
    }
  }

  const firstTokenSeen = new Set<string>()
  const kept: WireEntry[] = []
  for (const entry of entries) {
    const event = entry.event
    if (event?.type !== 'assistant/chunk') {
      kept.push(entry)
      continue
    }

    const turn = event.data?.turn
    const step = event.data?.step
    const key = `${String(turn)}:${String(step)}`
    const chunk = event.data?.chunk

    // Unfinished steps: preserve the full stream for partial/trajectory replay.
    if (typeof turn !== 'number' || typeof step !== 'number' || !finalizedSteps.has(key)) {
      kept.push(entry)
      continue
    }

    // Token accounting is needed even after the final message.
    if (chunk?.type === 'usage') {
      kept.push(entry)
      continue
    }

    // The first visible token delta preserves TTFT / first-token timing.
    if (isTokenDelta(chunk) && !firstTokenSeen.has(key)) {
      firstTokenSeen.add(key)
      kept.push(entry)
      continue
    }

    // Everything else (text/reasoning/tool deltas, block-start/end, finish) is
    // redundant once the step has a final assistant/message.
  }

  return kept
}

/** Read a full node request body as a Buffer. */
async function readBody(req: IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = []
  for await (const chunk of req) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
  }
  return Buffer.concat(chunks)
}

/** Build a WHATWG Request from a node IncomingMessage. */
function toRequest(req: IncomingMessage, body: Buffer): Request {
  const url = new URL(req.url ?? '/', 'http://dsh.internal')
  const headers = new Headers()
  for (const [key, value] of Object.entries(req.headers)) {
    if (typeof value === 'string') headers.set(key, value)
  }
  return new Request(url, {
    method: req.method ?? 'GET',
    headers,
    ...(body.length > 0 ? { body: new Uint8Array(body) } : {}),
    signal: AbortSignal.timeout(60_000),
  })
}

/** Write a JSON Response to the node server. */
function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const data = JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(data),
    'cache-control': 'no-store',
  })
  res.end(data)
}

/** Create one exact-route handler for a history RPC path. */
function historyRoute(ctx: Context): WebRoute['handler'] {
  return async (req, res) => {
    try {
      const body = await readBody(req)
      const request = toRequest(req, body)
      const response = await toFetchHandler(ctx.apiProxy).fetch(request)
      const text = await response.text()

      let envelope: unknown
      try {
        envelope = JSON.parse(text)
      } catch {
        // Non-JSON carrier failure: pass through unchanged.
        res.writeHead(response.status, Object.fromEntries(response.headers.entries()))
        res.end(text)
        return
      }

      const result = (envelope as { result?: { ok?: boolean; value?: { events?: WireEntry[] } } }).result
      if (result?.ok === true && result.value !== undefined) {
        const events = result.value.events
        if (Array.isArray(events)) {
          result.value.events = slimHistoryEvents(events)
        }
      }

      sendJson(res, response.status, envelope)
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error)
      sendJson(res, 500, { type: 'server-response', rpcId: 'history-lite-error', result: { ok: false, error: { code: 'internal', message, details: {} } } })
    }
  }
}

/**
 * Plugin body: mount exact routes for history RPCs.
 * @param ctx - Cordis context carrying `webServer` and `apiProxy`.
 */
export function apply(ctx: Context): void {
  ctx.effect(() => {
    const disposers = [
      ctx.webServer.register({ kind: 'exact', path: '/api/session.history', handler: historyRoute(ctx) }),
      ctx.webServer.register({ kind: 'exact', path: '/api/subagent.history', handler: historyRoute(ctx) }),
    ]
    return () => {
      for (const dispose of disposers) dispose()
    }
  }, 'history-lite: exact history routes')
}
