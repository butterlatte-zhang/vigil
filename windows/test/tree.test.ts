import { describe, expect, it } from 'vitest'
import { Tree, TreeError, makeNode } from '../src/core/domain.js'

function rootTree() {
  return new Tree(makeNode({ id: 'n0', role: 'manager', title: 'root' }))
}

describe('Tree invariants', () => {
  it('rejects a root with a parent', () => {
    expect(() => new Tree(makeNode({ id: 'n0', role: 'manager', parent: 'n1' }))).toThrow()
  })

  it('only managers may spawn, and ids are unique', () => {
    const t = rootTree()
    t.spawn('n0', makeNode({ id: 'n1', role: 'leaf', parent: null }))
    expect(() => t.spawn('n1', makeNode({ id: 'n2', role: 'leaf' }))).toThrow(TreeError)
    expect(() => t.spawn('n0', makeNode({ id: 'n1', role: 'leaf' }))).toThrow(TreeError)
  })

  it('refuses to kill the root', () => {
    const t = rootTree()
    expect(() => t.kill('n0')).toThrow(TreeError)
  })

  it('scopes kill to the caller subtree', () => {
    const t = rootTree()
    t.spawn('n0', makeNode({ id: 'n1', role: 'manager' }))
    t.spawn('n0', makeNode({ id: 'n2', role: 'manager' }))
    expect(() => t.kill('n2', 'n1')).toThrow(/not in your subtree/)
  })

  it('kill seals a whole subtree and returns only live ids', () => {
    const t = rootTree()
    t.spawn('n0', makeNode({ id: 'n1', role: 'manager' }))
    t.spawn('n1', makeNode({ id: 'n2', role: 'leaf' }))
    t.spawn('n1', makeNode({ id: 'n3', role: 'leaf' }))
    t.setStatus('n3', 'done')
    const live = t.kill('n1')
    expect(live).toEqual(['n1', 'n2'])
    expect(t.get('n1')?.status).toBe('killed')
    expect(t.get('n3')?.status).toBe('done')
    expect(t.count).toBe(4) // dead records stay in the tree
  })

  it('computes the unique tree path through the LCA', () => {
    const t = rootTree()
    t.spawn('n0', makeNode({ id: 'n1', role: 'manager' }))
    t.spawn('n1', makeNode({ id: 'n2', role: 'leaf' }))
    t.spawn('n1', makeNode({ id: 'n3', role: 'leaf' }))
    expect(t.path('n2', 'n3')).toEqual(['n2', 'n1', 'n3'])
    expect(t.lca('n2', 'n3')).toBe('n1')
  })

  it('freezes endedAt once and relaunch clears it', () => {
    const t = rootTree()
    t.spawn('n0', makeNode({ id: 'n1', role: 'leaf' }))
    t.setEnded('n1', 111)
    t.setEnded('n1', 222)
    expect(t.get('n1')?.endedAt).toBe(111)
    t.relaunch('n1', 'starting', 333)
    expect(t.get('n1')?.endedAt).toBeNull()
    expect(t.get('n1')?.startedAt).toBe(333)
  })
})
