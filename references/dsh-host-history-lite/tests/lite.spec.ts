import { describe, expect, it } from 'vitest'
import { slimHistoryEvents } from '../src/index.ts'

function entry(seq: number, type: string, data: Record<string, unknown>): { event: { seq: number; type: string; data: unknown } } {
  return { event: { seq, type, data } }
}

describe('slimHistoryEvents', () => {
  it('keeps finalized assistant messages and only the first token/usage chunks', () => {
    const events = [
      entry(1, 'assistant/chunk', { turn: 1, step: 1, chunk: { type: 'block-start', index: 0, blockType: 'text' } }),
      entry(2, 'assistant/chunk', { turn: 1, step: 1, chunk: { type: 'reasoning-delta', index: 0, text: 'The' } }),
      entry(3, 'assistant/chunk', { turn: 1, step: 1, chunk: { type: 'reasoning-delta', index: 0, text: ' rest' } }),
      entry(4, 'assistant/chunk', { turn: 1, step: 1, chunk: { type: 'usage', usage: { outputTokens: 2 } } }),
      entry(5, 'assistant/message', { turn: 1, step: 1, message: { content: [{ type: 'text', text: 'The rest' }] } }),
      entry(6, 'step/end', { turn: 1, step: 1 }),
    ]
    const kept = slimHistoryEvents(events)
    expect(kept.map(item => item.event.seq)).toEqual([2, 4, 5, 6])
  })

  it('keeps all chunks for an unfinished step', () => {
    const events = [
      entry(1, 'assistant/chunk', { turn: 2, step: 1, chunk: { type: 'text-delta', index: 0, text: 'a' } }),
      entry(2, 'assistant/chunk', { turn: 2, step: 1, chunk: { type: 'text-delta', index: 0, text: 'b' } }),
      entry(3, 'step/end', { turn: 2, step: 1 }),
    ]
    const kept = slimHistoryEvents(events)
    expect(kept).toHaveLength(3)
  })

  it('keeps only one first token per finalized step', () => {
    const events = [
      entry(1, 'assistant/chunk', { turn: 1, step: 1, chunk: { type: 'text-delta', index: 0, text: 'a' } }),
      entry(2, 'assistant/chunk', { turn: 1, step: 1, chunk: { type: 'text-delta', index: 0, text: 'b' } }),
      entry(3, 'assistant/chunk', { turn: 1, step: 2, chunk: { type: 'text-delta', index: 0, text: 'c' } }),
      entry(4, 'assistant/message', { turn: 1, step: 1, message: { content: [] } }),
      entry(5, 'assistant/message', { turn: 1, step: 2, message: { content: [] } }),
    ]
    const kept = slimHistoryEvents(events)
    expect(kept.map(item => item.event.seq)).toEqual([1, 3, 4, 5])
  })
})
