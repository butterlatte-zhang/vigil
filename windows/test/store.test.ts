import { describe, expect, it } from 'vitest'
import type { Effect, Resolution } from '../src/core/domain.js'
import { Tree, makeNode } from '../src/core/domain.js'
import { SessionStore } from '../src/core/store.js'

function harness() {
  const effects: Effect[] = []
  let now = 1000
  const store = new SessionStore(
    makeNode({ id: 'n0', role: 'manager', title: 'root' }),
    (e) => effects.push(e),
    { now: () => now },
  )
  const deliveries = () =>
    effects.filter((e): e is Extract<Effect, { type: 'deliver' }> => e.type === 'deliver')
  return {
    store,
    effects,
    deliveries,
    tick: (ms = 1) => {
      now += ms
    },
  }
}

describe('SessionStore', () => {
  it('opens and closes a turn through the hook commands', () => {
    const h = harness()
    h.store.send({ type: 'turnStarted', node: 'n0' })
    expect(h.store.tree.get('n0')?.status).toBe('running')
    h.store.send({ type: 'turnEnded', node: 'n0', gen: null })
    expect(h.store.tree.get('n0')?.status).toBe('idle')
  })

  it('discards a stale scrape verdict for an older turn generation', () => {
    const h = harness()
    h.store.send({ type: 'turnStarted', node: 'n0' })
    h.store.send({ type: 'turnStarted', node: 'n0' }) // gen 2
    h.store.send({ type: 'turnEnded', node: 'n0', gen: 1 })
    expect(h.store.tree.get('n0')?.status).toBe('running')
  })

  it('applies a spawn immediately and emits a spawnCell effect', () => {
    const h = harness()
    h.store.send({
      type: 'requestStruct',
      request: { type: 'spawn', parent: 'n0', role: 'leaf', task: 'do it', model: null, name: 'probe' },
      from: 'n0',
      replyID: 'r1',
    })
    expect(h.store.tree.get('n1')?.title).toBe('probe')
    expect(h.effects.some((e) => e.type === 'spawnCell' && e.node.id === 'n1')).toBe(true)
    const d = h.deliveries().find((x) => x.replyID === 'r1')
    expect(d?.resolution).toEqual({ type: 'structResult', result: { type: 'spawned', node: 'n1' } })
  })

  it('rejects a spawn requested from a leaf', () => {
    const h = harness()
    h.store.send({
      type: 'requestStruct',
      request: { type: 'spawn', parent: 'n0', role: 'leaf', task: 'a', model: null, name: null },
      from: 'n0',
      replyID: 'r1',
    })
    h.store.send({
      type: 'requestStruct',
      request: { type: 'spawn', parent: 'n1', role: 'leaf', task: 'b', model: null, name: null },
      from: 'n1',
      replyID: 'r2',
    })
    const d = h.deliveries().find((x) => x.replyID === 'r2')
    expect(d?.resolution.type).toBe('structResult')
    expect((d?.resolution as any).result.type).toBe('failed')
  })

  it('seals a killed subtree and reaps only live cells', () => {
    const h = harness()
    h.store.send({
      type: 'requestStruct',
      request: { type: 'spawn', parent: 'n0', role: 'manager', task: 'm', model: null, name: null },
      from: 'n0',
      replyID: 'r1',
    })
    h.store.send({
      type: 'requestStruct',
      request: { type: 'kill', node: 'n1' },
      from: 'n0',
      replyID: 'r2',
    })
    expect(h.store.tree.get('n1')?.status).toBe('killed')
    const kill = h.effects.find((e) => e.type === 'killCells') as Extract<Effect, { type: 'killCells' }>
    expect(kill.nodes).toEqual(['n1'])
    const d = h.deliveries().find((x) => x.replyID === 'r2')
    expect((d?.resolution as any).result).toEqual({ type: 'killed', nodes: ['n1'] })
  })

  it('rolls a report up to the direct parent along the tree edge', () => {
    const h = harness()
    h.store.send({
      type: 'requestStruct',
      request: { type: 'spawn', parent: 'n0', role: 'leaf', task: 'w', model: null, name: null },
      from: 'n0',
      replyID: 'r1',
    })
    h.store.send({ type: 'rollup', from: 'n1', summary: 'done' })
    expect(h.store.tree.get('n1')?.lastRollup).toBe('done')
    const route = h.effects.find((e) => e.type === 'route') as Extract<Effect, { type: 'route' }>
    expect(route.to).toBe('n0')
    expect(route.text).toBe('CHILD_ROLLUP:done')
  })

  it('never acks a send to a missing or terminal node as delivered', () => {
    const h = harness()
    h.store.send({ type: 'message', from: 'n0', to: 'n9', text: 'hi', replyID: 'a' })
    const a = h.deliveries().find((d) => d.replyID === 'a')?.resolution as Extract<Resolution, { type: 'sendAck' }>
    expect(a.delivered).toBe(false)
    expect(a.note).toContain('no such node')

    h.store.send({
      type: 'requestStruct',
      request: { type: 'spawn', parent: 'n0', role: 'leaf', task: 'w', model: null, name: null },
      from: 'n0',
      replyID: 'r1',
    })
    h.store.send({ type: 'nodeExited', node: 'n1', code: 0 })
    h.store.send({ type: 'message', from: 'n0', to: 'n1', text: 'hi', replyID: 'b' })
    const b = h.deliveries().find((d) => d.replyID === 'b')?.resolution as Extract<Resolution, { type: 'sendAck' }>
    expect(b.delivered).toBe(false)
    expect(b.note).toContain('done')
  })

  it('derives attention priority: waiting > stalled > errored > queued > idle', () => {
    const h = harness()
    h.store.send({ type: 'injectQueued', node: 'n0', pending: 1, epoch: 1 })
    expect(h.store.tree.get('n0')?.status).toBe('queued')
    h.store.send({ type: 'spawnStalled', node: 'n0' })
    expect(h.store.tree.get('n0')?.status).toBe('stalled')
    h.store.send({ type: 'turnErrored', node: 'n0' })
    expect(h.store.tree.get('n0')?.status).toBe('stalled')
    h.store.send({
      type: 'permRequested',
      from: 'n0',
      info: { toolName: 'Bash', text: 'Awaiting approval · Bash' },
    })
    expect(h.store.tree.get('n0')?.status).toBe('waiting')
    h.store.send({ type: 'clearNotices', node: 'n0' })
    expect(h.store.tree.get('n0')?.status).toBe('stalled')
  })

  it('drops out-of-order inject epochs', () => {
    const h = harness()
    h.store.send({ type: 'injectQueued', node: 'n0', pending: 1, epoch: 5 })
    h.store.send({ type: 'injectSettled', node: 'n0', epoch: 6 })
    h.store.send({ type: 'injectQueued', node: 'n0', pending: 2, epoch: 4 })
    expect(h.store.notices.some((n) => n.kind === 'inject-queued')).toBe(false)
  })

  it('resolves a permission card only on a matching tuple', () => {
    const h = harness()
    h.store.send({
      type: 'permRequested',
      from: 'n0',
      info: { promptID: 'p1', toolName: 'Bash', toolInput: '{"command":"ls"}', text: 'x' },
    })
    h.store.send({
      type: 'resolveNotice',
      from: 'n0',
      match: { promptID: 'p1', toolName: 'Edit', toolInput: '{}', toolUseID: 't1' },
      via: 'post-tool',
    })
    expect(h.store.notices.length).toBe(1)
    h.store.send({
      type: 'resolveNotice',
      from: 'n0',
      match: { promptID: 'p1', toolName: 'Bash', toolInput: '{"command":"ls"}', toolUseID: 't2' },
      via: 'post-tool',
    })
    expect(h.store.notices.length).toBe(0)
  })

  it('grafts an archived skeleton under the live root', () => {
    const h = harness()
    const archived = new Tree(makeNode({ id: 'n0', role: 'manager', title: 'root' }))
    archived.spawn('n0', makeNode({ id: 'n1', role: 'leaf', title: 'old worker', status: 'done' }))
    h.store.send({ type: 'restoreSkeleton', tree: archived })
    expect(h.store.tree.get('n1')?.title).toBe('old worker')
    expect(h.store.tree.get('n1')?.status).toBe('done')
  })
})
