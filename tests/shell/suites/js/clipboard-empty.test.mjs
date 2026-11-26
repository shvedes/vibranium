#!/usr/bin/env node
// Suite: indexed clipboard commands distinguish an empty bucket from a bad index.
import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, contains, finish, SHELL_DIR } from '../../lib/assert.mjs'

const P = loadLib(path.join(SHELL_DIR, 'common/text/IpcProtocol.js'))
const SRC = fs.readFileSync(path.join(SHELL_DIR, 'features/clipboard/Clipboard.qml'), 'utf8')

function body(name) {
  const at = SRC.indexOf(`function ${name}(`)
  if (at < 0) return ''
  let depth = 0
  for (let i = SRC.indexOf('{', at); i < SRC.length; i++) {
    if (SRC[i] === '{') depth++
    if (SRC[i] === '}') {
      depth--
      if (depth === 0) return SRC.slice(SRC.indexOf('{', at) + 1, i)
    }
  }
  return ''
}

const miss = { v: 1, ok: false, error: { code: 'invalid-index', message: 'invalid index' } }
function makeRoot(bucket, filtered = []) {
  const entries = bucket.map((content, i) => ({ id: `e${i}`, content, type: 'text' }))
  return {
    open: true,
    history: entries,
    filtered,
    _entryList: entries,
    _ipcBucketSize: () => entries.length,
    _ipcResolve: () => (entries.length ? { index: 0, entry: entries[0] } : null),
    _ipcEmpty: pinned => ({ v: 1, ok: false, error: { code: 'empty',
      message: pinned ? 'Pinned list is empty. Ignoring.' : 'Clipboard list is empty. Ignoring.' } }),
    _ipcMiss: () => miss,
    _panels: [],
    togglePin: () => {},
    requestDelete: () => true,
    optimistic: { isPending: () => false },
    copyEntry: () => true
  }
}

function run(name, root, args) {
  const names = ['root', 'CL', ...Object.keys(args || {})]
  const values = [root, {
    selectEntries: () => root._entryList,
    ipcIndex: token => (/^\d+$/.test(String(token)) ? Number(token) : null),
    isIpcProtected: () => false
  }, ...Object.values(args || {})]
  return new Function(...names, body(name))(...values)
}

suite('clipboard-empty', 'empty-bucket errors and bad-index errors')

section('error vocabulary')
group('empty is RC 1', () => {
  eq('empty code is declared', P.ERRORS.empty, 1)
  contains('regular message', SRC, 'Clipboard list is empty. Ignoring.')
  contains('pinned message', SRC, 'Pinned list is empty. Ignoring.')
})

section('indexed operations')
group('empty buckets', () => {
  const empty = makeRoot([])
  eq('pin on empty regular', run('ipcPin', empty, { token: '0', pinned: false }).error.code, 'empty')
  eq('purge on empty pinned', run('ipcPurge', empty, { token: '0', pinned: true }).error.message,
    'Pinned list is empty. Ignoring.')
  eq('copy entry on empty regular', run('ipcCopyEntry', empty, { pinned: false, token: '0' }).error.code,
    'empty')
  eq('select with no filtered rows', run('ipcSelect', empty, { token: '0' }).error.code, 'empty')
})
group('populated buckets keep invalid-index', () => {
  const full = makeRoot(['one'])
  full._ipcResolve = () => null
  eq('purge bad index', run('ipcPurge', full, { token: '9', pinned: false }).error.code,
    'invalid-index')
  eq('pin bad index', run('ipcPin', full, { token: '9', pinned: false }).error.code,
    'invalid-index')
  eq('copy entry bad index', run('ipcCopyEntry', full, { pinned: false, token: '9' }).error.code,
    'invalid-index')
})

finish()
