import assert from 'node:assert/strict'
import test from 'node:test'
import { slimHistoryEvents } from '../lib/slim.js'

function entry(seq, type, data, view) {
  return { event: { seq, type, data }, ...(view === undefined ? {} : { view }) }
}

test('completed steps retain final message, first token and usage', () => {
  const events = [
    entry(1, 'assistant/chunk', { turn: 1, step: 1, chunk: { type: 'block-start' } }),
    entry(2, 'assistant/chunk', { turn: 1, step: 1, chunk: { type: 'reasoning-delta', text: 'The' } }),
    entry(3, 'assistant/chunk', { turn: 1, step: 1, chunk: { type: 'reasoning-delta', text: ' rest' } }),
    entry(4, 'assistant/chunk', { turn: 1, step: 1, chunk: { type: 'usage', usage: { outputTokens: 2 } } }),
    entry(5, 'assistant/message', { turn: 1, step: 1, message: { content: [{ type: 'text', text: 'The rest' }] } }),
    entry(6, 'step/end', { turn: 1, step: 1 }),
  ]
  assert.deepEqual(slimHistoryEvents(events).map(item => item.event.seq), [2, 4, 5, 6])
})

test('unfinished steps retain the complete stream', () => {
  const events = [
    entry(1, 'assistant/chunk', { turn: 2, step: 1, chunk: { type: 'text-delta', text: 'a' } }),
    entry(2, 'assistant/chunk', { turn: 2, step: 1, chunk: { type: 'text-delta', text: 'b' } }),
    entry(3, 'step/end', { turn: 2, step: 1 }),
  ]
  assert.deepEqual(slimHistoryEvents(events), events)
})

test('unknown and malformed chunks are preserved for forward compatibility', () => {
  const events = [
    entry(1, 'assistant/chunk', { turn: 3, step: 1, chunk: { type: 'future-delta', payload: 'keep' } }, { marker: true }),
    entry(2, 'assistant/chunk', { turn: 3, step: 1 }),
    entry(3, 'assistant/message', { turn: 3, step: 1, message: { content: [] } }),
  ]
  assert.deepEqual(slimHistoryEvents(events), events)
})

test('empty tool-call deltas do not consume the first-token slot', () => {
  const events = [
    entry(1, 'assistant/chunk', { turn: 4, step: 1, chunk: { type: 'tool-call-delta', argumentsDelta: '' } }),
    entry(2, 'assistant/chunk', { turn: 4, step: 1, chunk: { type: 'tool-call-delta', name: 'shell' } }),
    entry(3, 'assistant/chunk', { turn: 4, step: 1, chunk: { type: 'tool-call-delta', argumentsDelta: '{' } }),
    entry(4, 'assistant/message', { turn: 4, step: 1, message: { content: [] } }),
  ]
  assert.deepEqual(slimHistoryEvents(events).map(item => item.event.seq), [2, 4])
})

test('input array and retained entries are not mutated', () => {
  const events = [
    entry(1, 'assistant/chunk', { turn: 5, step: 1, chunk: { type: 'text-delta', text: 'a' } }),
    entry(2, 'assistant/chunk', { turn: 5, step: 1, chunk: { type: 'text-delta', text: 'b' } }),
    entry(3, 'assistant/message', { turn: 5, step: 1, message: { content: [] } }),
  ]
  const snapshot = structuredClone(events)
  const kept = slimHistoryEvents(events)
  assert.deepEqual(events, snapshot)
  assert.equal(kept[0], events[0])
  assert.equal(kept.at(-1), events.at(-1))
})

test('large finalized pages shrink while every final message remains', () => {
  const events = []
  let seq = 0
  for (let turn = 1; turn <= 40; turn += 1) {
    for (let delta = 0; delta < 400; delta += 1) {
      events.push(entry(++seq, 'assistant/chunk', {
        turn,
        step: 1,
        chunk: { type: 'reasoning-delta', text: `token-${delta}` },
      }))
    }
    events.push(entry(++seq, 'assistant/chunk', { turn, step: 1, chunk: { type: 'usage', usage: {} } }))
    events.push(entry(++seq, 'assistant/message', { turn, step: 1, message: { content: [{ type: 'text', text: `final-${turn}` }] } }))
  }

  const kept = slimHistoryEvents(events)
  assert.equal(kept.length, 40 * 3)
  assert.equal(kept.filter(item => item.event.type === 'assistant/message').length, 40)
})
