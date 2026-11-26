#!/usr/bin/env node
// Suite: the clipboard gateway's pure projection and owner wiring (batch C).
//
// The no-leak rule is enforced in ClipboardLib's helper layer, so it is
// exercised directly with synthetic rows: protected entries, safe previews,
// fixed markers and strict indices. The QML half is checked structurally for
// one closure per catalog row, bucket-only resolution and the public-text
// bridge without echo suppression.

import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, contains, notContains, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const CL = loadLib(path.join(SHELL_DIR, 'features/clipboard/ClipboardLib.js'))
const CATALOG = loadLib(path.join(SHELL_DIR, 'common/text/IpcCatalog.js'))
const read = (...parts) => fs.readFileSync(path.join(SHELL_DIR, ...parts), 'utf8')
const SRC = read('features', 'clipboard', 'Clipboard.qml')
const PANEL = read('features', 'clipboard', 'ClipboardPanel.qml')

suite('clipboard-ipc', 'safe projections, protected rows and gateway owners')

section('strict index')
group('only nonnegative decimal tokens resolve', () => {
  eq('zero', CL.ipcIndex('0'), 0)
  eq('leading zeros', CL.ipcIndex('007'), 7)
  eq('a negative is a miss', CL.ipcIndex('-1'), null)
  eq('a trailing junk is a miss', CL.ipcIndex('1abc'), null)
  eq('a fraction is a miss', CL.ipcIndex('1.5'), null)
  eq('empty is a miss', CL.ipcIndex(''), null)
  eq('null is a miss', CL.ipcIndex(null), null)
  eq('a huge value is a miss', CL.ipcIndex('999999999999999999999999'), null)
})

section('protected rows')
group('every protection form is the same miss', () => {
  eq('a plain text row is safe', CL.isIpcProtected({ type: 'text', mime: 'text/plain' }), false)
  eq('a secret type is protected', CL.isIpcProtected({ type: 'secret', mime: 'text/plain' }), true)
  eq('a secret handle is protected', CL.isIpcProtected({ type: 'text', secretHandle: 'clipboard:2' }), true)
  eq('a credential MIME is protected', CL.isIpcProtected({ type: 'text', mime: 'x-keepassxc' }), true)
  eq('a missing row is protected', CL.isIpcProtected(null), true)
})

section('safe previews')
group('control characters, whitespace and the code-point cap', () => {
  eq('runs fold to one space', CL.safePreview('  a\t\n b   c '), 'a b c')
  eq('controls become spaces', CL.safePreview('a\u0001b\u007fc'), 'a b c')
  eq('short text is unchanged', CL.safePreview('hello'), 'hello')
  const long = '😀'.repeat(100)
  const out = CL.safePreview(long)
  eq('astral glyphs count as one point', Array.from(out).length, 80)
  eq('the last point is the ellipsis', Array.from(out)[79], '…')
  eq('the cap includes the ellipsis', out, '😀'.repeat(79) + '…')
  eq('an explicit cap', Array.from(CL.safePreview('abcdefgh', 4)).length, 4)
})

section('content markers')
group('non-text entries never expose a path or MIME', () => {
  eq('image', CL.ipcContent({ type: 'image', filePaths: ['/secret/a.png'], mime: 'image/png' }), '<image>')
  eq('file', CL.ipcContent({ type: 'file', filePaths: ['/secret/a'] }), '<file>')
  eq('folder', CL.ipcContent({ type: 'folder', filePaths: ['/secret'] }), '<folder>')
  eq('archive', CL.ipcContent({ type: 'archive', filePaths: ['/secret.zip'] }), '<archive>')
  eq('binary', CL.ipcContent({ type: 'binary' }), '<binary>')
  eq('a local network path is a file', CL.ipcContent({ type: 'network', filePaths: ['/secret/a'] }), '<file>')
  eq('a remote URL previews safely', CL.ipcContent({ type: 'url', raw: 'https://x  y' }), 'https://x y')
  eq('text uses the safe preview', CL.ipcContent({ type: 'text', raw: 'hello\nworld' }), 'hello world')
})

section('list projection')
group('only index and content leave the owner', () => {
  const rows = [
    { id: 1, type: 'text', raw: 'first' },
    { id: 2, type: 'secret', secretHandle: 'clipboard:2', raw: 'hidden' },
    { id: 3, type: 'image', filePaths: ['/secret/3.png'], mime: 'image/png' },
    { id: 4, type: 'text', mime: 'x-password', raw: 'hidden' },
  ]
  const out = CL.ipcProject(rows)
  eq('protected rows are skipped', out.length, 2)
  eq('positions do not shift', out.map(r => r.index), [0, 2])
  eq('exact shape', Object.keys(out[0]).sort(), ['content', 'index'])
  eq('projected values', out.map(r => r.content), ['first', '<image>'])
  const text = JSON.stringify(out)
  for (const leak of ['/secret', 'hidden', 'secretHandle', 'image/png', 'x-password']) {
    notContains(`no ${leak} in the reply`, text, leak)
  }
})

section('owner registration')
group('every clipboard row has one constant closure', () => {
  const registered = new Set()
  for (const m of SRC.matchAll(/IpcRouter\.register\([\s\S]*?\}\)\s*(?:\n|$)/g)) {
    for (const id of m[0].matchAll(/"(clipboard\.[A-Za-z0-9_.]+)"/g)) registered.add(id[1])
  }
  const expected = CATALOG.findTarget('clipboard').rows
    .filter(r => r.route === 'gateway' && r.helpOnly !== true).map(r => r.id)
    .concat(['clipboard.status', 'clipboard.ping']).sort()
  eq('no clipboard route is unowned', expected.filter(id => !registered.has(id)), [])
  eq('no clipboard closure is unlisted', [...registered].filter(id => !expected.includes(id)).sort(), [])
  contains('unregister retires by owner identity', SRC, 'IpcRouter.unregister("clipboard", root)')
  notContains('no native clipboard handler', SRC, 'target: "clipboard"')
})

group('Bound-component property declarations', () => {
  const assigned = new Set()
  for (const m of SRC.matchAll(/\broot\.(_[A-Za-z0-9_]+)\s*=[^=]/g)) assigned.add(m[1])
  const declared = new Set()
  for (const m of SRC.matchAll(/\bproperty\s+(?:(?:readonly)\s+)?[A-Za-z0-9_<>.,\s\[\]]+?\s(_[A-Za-z0-9_]+)\s*:/g)) declared.add(m[1])
  eq('every assigned private property is declared',
    [...assigned].filter(n => !declared.has(n)).sort(), [])
  eq('the registration verdict is declared', /property bool _ipcRegistered: false/.test(SRC), true)
  eq('the verdict is stored exactly once',
    (SRC.match(/root\._ipcRegistered\s*=\s*IpcRouter\.register\(/g) || []).length, 1)
  const EMOJI = read('features', 'pickers', 'emoji', 'EmojiPicker.qml')
  eq('the emoji owner declares its verdict too',
    /property bool _ipcRegistered: false/.test(EMOJI), true)
})

group('buckets and indices are resolved inside the owner', () => {
  contains('normal/pinned source selection', SRC, 'CL.selectEntries(root.history, bucket ? "pinned" : "normal", "")')
  contains('strict index at the boundary', SRC, 'CL.ipcIndex(token)')
  contains('protected rows and bad indices share a miss', SRC, 'code: "invalid-index", message: "invalid index"')
  contains('current list never changes the query', SRC, 'CL.ipcProject(root.filtered)')
  contains('purge uses the shared deletion path', SRC, 'root.requestDelete(row.entry.id, true)')
  contains('pin uses the shared toggle', SRC, 'root.togglePin(row.entry.id, true)')
  contains('clear is one implementation for both buckets', SRC, 'function clearBucket(pinned, quiet)')
  contains('normal clear delegates', SRC, 'function clearAll() { root.clearBucket(false) }')
  contains('status adds copyBusy', SRC, 'copyBusy: copyProc.running')
  notContains('status publishes no query', SRC, 'query: root.query')
  notContains('no MIME in a projected row', SRC, 'mime: e.mime')
})

group('IPC paths do not leak metadata into logs', () => {
  contains('pin passes an ipc flag', SRC, 'root.togglePin(row.entry.id, true)')
  contains('ipc pin has a MIME-free log line', SRC, 'Log.info("pinned entry " + slot + ", total pinned "')
  contains('ipc pin skips the debug record', SRC, 'if (ipc !== true && d.allows("debug"))')
  contains('purge passes an ipc flag', SRC, 'root.requestDelete(row.entry.id, true)')
  contains('ipc purge skips the per-row debug line', SRC,
    '!(root._ipcDeletes && root._ipcDeletes[id])')
  contains('clear passes a quiet flag', SRC, 'root.clearBucket(false, true)')
  contains('quiet clear skips the kind tally', SRC, 'quiet !== true && d.allows("debug")')
})

group('staged copy and public-text bridge', () => {
  contains('the clipboard registers for in-process callers', SRC,
    'Registry.register(root.tag, root)')
  contains('the clipboard retires its registration', SRC,
    'Registry.unregister(root.tag)')
  contains('staged echo state', SRC, 'const staged =')
  contains('restore on refused start', SRC, 'root._suppressHash = staged.hash')
  contains('promote only after admission', SRC, 'root._promote(entry.id)\n    return true')
  contains('copyEntry answers admission', SRC, 'function ipcCopyEntry(pinned, token)')
  contains('the emoji bridge is fixed', SRC, 'function writePublicText(text)')
  contains('it uses the public text command', SRC, 'CL.buildCopyTextCmd()')
  contains('it clears echo suppression', SRC, 'root._suppressHash = ""')
  notContains('the bridge never sets a suppression hash', SRC,
    'root._suppressHash = "text:" + glyph')
})

group('selection verifies the displayed row', () => {
  contains('the panel seat is verified by id', PANEL, 'row.id !== entry.id')
  contains('a pending renderer is busy', PANEL, 'list._inSwap === true')
  contains('another row’s confirm is closed', PANEL, 'confirmStage.key !== index')
  contains('the seat uses the click cause', PANEL, 'list.seat(index, "click")')
  notContains('seatTo is not used for row indexes', PANEL, 'list.seatTo(index')
})

section('pinned window additions')
const qmlBody = name => {
  const at = SRC.indexOf(`function ${name}(`)
  const open = SRC.indexOf('{', at)
  let depth = 0
  let close = open
  for (; close < SRC.length; close++) {
    if (SRC[close] === '{') depth++
    if (SRC[close] === '}' && --depth === 0) break
  }
  return SRC.slice(open + 1, close)
}
group('the initial list decides the escape', () => {
  contains('the owner records the initial list', SRC, 'property string initialList: persist.initialList')
  contains('a normal open records normal', SRC, 'root.initialList = "normal"')
  contains('a pinned open records pinned', SRC, 'root.initialList = "pinned"')
  contains('the panel routes pinned escape to the owner', PANEL, 'Clipboard.escapePinned()')
  const escape = initialList => {
    const calls = []
    new Function('root', qmlBody('escapePinned'))({
      initialList,
      close: () => calls.push('close'),
      exitPinned: () => calls.push('exit')
    })
    return calls
  }
  eq('a window opened pinned closes', escape('pinned'), ['close'])
  eq('a window opened normal steps back', escape('normal'), ['exit'])
})
group('toggle [pinned] opens pinned and still hides an open window', () => {
  contains('the toggle closure reads the pinned literal', SRC,
    'ctx.words.indexOf("pinned") >= 0 ? "togglePinned" : "toggle"')
  contains('toggle pinned hides an open window', SRC,
    'verb === "togglePinned") root.visible ? root.hidePanel() : root.showPinnedPanel()')
  const toggle = visible => {
    const calls = []
    new Function('root', 'verb', qmlBody('ipcWindow'))({
      visible,
      showPanel: () => calls.push('show'),
      hidePanel: () => calls.push('hide'),
      showPinnedPanel: () => calls.push('showPinned')
    }, 'togglePinned')
    return calls
  }
  eq('a closed window toggles open in the pinned view', toggle(false), ['showPinned'])
  eq('an open window toggles closed', toggle(true), ['hide'])
})

finish()
