/**
 * Chunk types known to be reconstructible from the final assistant/message.
 * Unknown types are deliberately preserved for forward compatibility.
 */
const DROPPABLE_FINALIZED_CHUNK_TYPES = new Set([
  'block-start',
  'block-end',
  'text-delta',
  'reasoning-delta',
  'tool-call-delta',
  'finish',
])

function isVisibleTokenDelta(chunk) {
  if (chunk === undefined || chunk === null || typeof chunk !== 'object') return false
  switch (chunk.type) {
    case 'text-delta':
    case 'reasoning-delta':
      return typeof chunk.text === 'string' && chunk.text.length > 0
    case 'tool-call-delta':
      return (typeof chunk.argumentsDelta === 'string' && chunk.argumentsDelta.length > 0)
        || chunk.name !== undefined
    default:
      return false
  }
}

/**
 * Compact a history page without mutating the caller's event array.
 *
 * Completed steps retain their final assistant/message, usage information,
 * first visible token (for timing), and all unknown chunk kinds. Incomplete or
 * malformed steps remain byte-for-byte represented by their original entries.
 */
export function slimHistoryEvents(entries) {
  const finalizedSteps = new Set()

  for (const entry of entries) {
    const event = entry?.event
    if (event?.type !== 'assistant/message') continue
    const turn = event.data?.turn
    const step = event.data?.step
    if (typeof turn === 'number' && typeof step === 'number') {
      finalizedSteps.add(`${turn}:${step}`)
    }
  }

  const firstTokenSeen = new Set()
  const kept = []

  for (const entry of entries) {
    const event = entry?.event
    if (event?.type !== 'assistant/chunk') {
      kept.push(entry)
      continue
    }

    const turn = event.data?.turn
    const step = event.data?.step
    if (typeof turn !== 'number' || typeof step !== 'number') {
      kept.push(entry)
      continue
    }

    const key = `${turn}:${step}`
    if (!finalizedSteps.has(key)) {
      kept.push(entry)
      continue
    }

    const chunk = event.data?.chunk
    if (chunk?.type === 'usage') {
      kept.push(entry)
      continue
    }

    if (isVisibleTokenDelta(chunk) && !firstTokenSeen.has(key)) {
      firstTokenSeen.add(key)
      kept.push(entry)
      continue
    }

    if (!DROPPABLE_FINALIZED_CHUNK_TYPES.has(chunk?.type)) {
      kept.push(entry)
    }
  }

  return kept
}
