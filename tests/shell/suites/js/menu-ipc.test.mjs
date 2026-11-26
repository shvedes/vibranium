#!/usr/bin/env node
// Suite: MenuIpc.js + MenuState.js - the pure half of the menu gateway.
//
// These tests never load QML. They pin the recognition and projection rules
// that the singleton and the UI both call, so a change to a guard verdict, a
// ref generation or a shell-template slot cannot quietly drift between the
// two callers.

import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, ne, is, match, notMatch, throws, noThrow, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

suite('menu-ipc')

const M = loadLib(path.join(SHELL_DIR, 'features/menu/MenuIpc.js'))
const S = loadLib(path.join(SHELL_DIR, 'features/menu/MenuState.js'))
const L = loadLib(path.join(SHELL_DIR, 'features/menu/MenuLib.js'))

section('safe shell templates')
group('substituteQuoted recognition only accepts standalone unquoted slots', () => {
  eq('simple command', M.safeShellTemplate('echo %v'), true)
  eq('leading slot', M.safeShellTemplate('%v --flag'), true)
  eq('trailing slot', M.safeShellTemplate('cmd --value %v'), true)
  eq('two slots', M.safeShellTemplate('cmd %v %v'), true)
  eq('static template', M.safeShellTemplate('echo ready'), true)
  eq('quoted slot', M.safeShellTemplate('cmd "%v"'), false)
  eq('single quoted slot', M.safeShellTemplate("cmd '%v'"), false)
  eq('adjacent prefix', M.safeShellTemplate('cmd --value=%v'), false)
  eq('adjacent suffix', M.safeShellTemplate('cmd %v.txt'), false)
  eq('pipe', M.safeShellTemplate('echo %v | cat'), false)
  eq('redirect', M.safeShellTemplate('echo %v > out'), false)
  eq('command substitution', M.safeShellTemplate('echo $(%v)'), false)
  eq('dollar', M.safeShellTemplate('echo %v$x'), false)
  eq('backtick', M.safeShellTemplate('echo `%v`'), false)
  eq('backslash', M.safeShellTemplate('echo \\%v'), false)
  eq('ampersand', M.safeShellTemplate('echo %v &'), false)
  eq('semicolon', M.safeShellTemplate('echo %v; whoami'), false)
  eq('newline', M.safeShellTemplate('echo %v\necho hi'), false)
  eq('unterminated quote', M.safeShellTemplate("echo 'abc %v"), false)
  eq('quoted literal around another slot', M.safeShellTemplate("echo 'a b' %v"), true)
  eq('non string', M.safeShellTemplate(null), false)
})

group('accepted templates use the quoted substitution, never the raw one', () => {
  eq('one word', M.quoteShellValue('notify %v', 'hello'), L.substituteQuoted('notify %v', 'hello'))
  eq('multi word is one atom', M.quoteShellValue('notify %v', 'a b'), "notify 'a b'")
  eq('metacharacter stays literal', M.quoteShellValue('notify %v', '$(id)'), "notify '$(id)'")
  eq('static template unchanged', M.quoteShellValue('notify', 'x'), 'notify')
})

section('result and guard vocabulary')
group('typed results are frames, not strings', () => {
  eq('ok', JSON.stringify(M.ok({ a: 1 })), '{"v":1,"ok":true,"data":{"a":1}}')
  eq('silent success has no data field', JSON.stringify(M.silent()), '{"v":1,"ok":true}')
  eq('accepted is silent', JSON.stringify(M.accepted()), '{"v":1,"ok":true}')
  eq('error code', M.fail('refused', 'no').error.code, 'refused')
  eq('error message defaults', M.fail('busy').error.message, 'busy')
})

group('ordinary guard vetoes a row or any ancestor', () => {
  const blocked = (r) => r.uid === 'bad'
  eq('no verdict for a good row', M.ordinaryGuard({ type: 'action' }, [], blocked), null)
  eq('a disabled row is refused', M.ordinaryGuard({ type: 'action', enabled: false }, [], blocked), 'refused')
  eq('a blocked row is refused', M.ordinaryGuard({ type: 'action', uid: 'bad' }, [], blocked), 'refused')
  eq('a blocked ancestor is refused', M.ordinaryGuard({ type: 'action' }, [{ uid: 'bad' }], blocked), 'refused')
  eq('layout chrome is unsupported', M.ordinaryGuard({ type: 'separator' }, [], blocked), 'unsupported')
  eq('a missing row is not-found', M.ordinaryGuard(null, [], blocked), 'not-found')
  eq('guard errors map to vocabulary', M.guardResult('refused').error.code, 'refused')
  eq('null guard has no error', M.guardResult(null), null)
})

group('row-type matrix', () => {
  eq('toggle supports set', M.supports('toggle', 'set'), true)
  eq('progress does not activate', M.supports('progress', 'activate'), false)
  eq('separator has no options', M.supports('separator', 'options'), false)
  eq('unsupported operation error', M.operationError('progress', 'activate'), 'unsupported')
  eq('layout type separator', M.isLayoutType('separator'), true)
  eq('layout type header', M.isLayoutType('header'), true)
  eq('layout type spacer', M.isLayoutType('spacer'), true)
  eq('action is not layout', M.isLayoutType('action'), false)
})

section('typed arguments and option identity')
group('JSON argument types must match the row type exactly', () => {
  eq('toggle wants bool', M.valueKind({ type: 'toggle' }), 'bool')
  eq('range wants number', M.valueKind({ type: 'range' }), 'number')
  eq('text wants text', M.valueKind({ type: 'text' }), 'text')
  eq('select wants a JSON value', M.valueKind({ type: 'select' }), 'value')
  eq('bool accepts true', M.validValue('bool', true), true)
  eq('bool refuses a string', M.valueError({ type: 'toggle' }, 'true'), 'invalid-argument')
  eq('number refuses a numeric string', M.valueError({ type: 'number' }, '1'), 'invalid-argument')
  eq('number refuses NaN', M.valueError({ type: 'number' }, NaN), 'invalid-argument')
  eq('number accepts a finite value', M.valueError({ type: 'number' }, 1.5), null)
  eq('text refuses a number', M.valueError({ type: 'text' }, 3), 'invalid-argument')
  eq('select accepts null', M.valueError({ type: 'select' }, null), null)
  eq('flow select kind maps to value', M.valueErrorForKind('select', 'x'), null)
  eq('flow range kind maps to number', M.valueErrorForKind('range', 2), null)
  eq('unknown kind', M.valueErrorForKind('action', 2), 'unsupported')
})

group('option ids are positional and exact', () => {
  eq('id from index', M.optionId(2), 'o2')
  eq('index from id', M.optionIndex('o2'), 2)
  eq('title is not an id', M.optionIndex('B'), -1)
  eq('prefix is not an id', M.optionIndex('option2'), -1)
})

section('references')
group('a ref encodes four generations and retires when any changes', () => {
  const ref = M.ref('123-abc', 2, 3, 4)
  eq('ref text', ref, 'r123-abc.2.3.4')
  const parsed = M.parseRef(ref)
  eq('incarnation', parsed.incarnation, '123-abc')
  eq('open generation', parsed.open, 2)
  eq('page ordinal', parsed.page, 3)
  eq('row ordinal', parsed.row, 4)
  eq('generation match', M.refMatches(ref, '123-abc', 2) !== null, true)
  eq('wrong generation', M.refMatches(ref, '123-abc', 3), null)
  eq('wrong incarnation', M.refMatches(ref, 'other', 2), null)
  eq('dots in incarnation are folded', M.ref('a.b', 1, 1, 0), 'ra-b.1.1.0')
  eq('malformed ref', M.parseRef('r1.1.1'), null)
  eq('numeric overflow is stale', M.parseRef('r1.1.1.999999999999999999999'), null)
})

section('protected data')
group('protected rows are discovered but redacted', () => {
  eq('explicit sensitive row', M.isProtectedRow({ sensitive: true }, null), true)
  eq('normalized marker', M.isProtectedRow({ _sensitive: true }, null), true)
  eq('sensitive flow stage', M.isProtectedRow({}, null, { sensitive: true }), true)
  eq('env projection binding', M.isProtectedRow({ var: 'shell.env.token' }, null), true)
  eq('ordinary row', M.isProtectedRow({ var: 'shell.volume' }, null), false)
  eq('pass menu page', M.isProtectedPage('pass-menu'), true)
  eq('pass vault page', M.isProtectedPage('pass-vault'), true)
  eq('ordinary page', M.isProtectedPage('settings'), false)
  eq('page boundary marks its rows', M.isProtectedRow({}, { id: 'pass-vault' }), true)
  eq('secret value is null', M.safeValue({}, { value: 'x' }, true), null)
  eq('ordinary value survives', M.safeValue({}, { value: 'x' }, false), 'x')
  eq('non scalar value is dropped', M.safeValue({}, { value: { a: 1 } }, false), null)
})

group('row and item projections are safe, stable shapes', () => {
  const r = M.rowRecord({ ref: 'r1.1.1.0', uid: 'p#a', id: 'a', page: 'p', depth: 1,
    type: 'toggle', label: 'A', available: true, expanded: true, actions: ['set'] })
  eq('row keys', Object.keys(r).join(','),
    'ref,uid,id,page,parent,depth,type,label,available,expanded,actions')
  eq('row ref', r.ref, 'r1.1.1.0')
  eq('row actions', r.actions.join(','), 'set')
  const chrome = M.rowRecord({ type: 'separator', ref: 'r1.1.1.1', actions: ['set'] })
  eq('chrome has no ref', chrome.ref, null)
  eq('chrome has no actions', chrome.actions.length, 0)
  const item = M.itemDetail({ type: 'toggle', value: 1, state: { value: true, checked: true },
    item: { type: 'toggle' }, confirm: { stages: 2 }, flow: null, options: [] })
  eq('item has checked', item.checked, true)
  eq('item has value', item.value, true)
  eq('item has limits field', 'limits' in item, true)
  eq('confirmation projected', item.confirmation.stages, 2)
  const locked = M.itemDetail({ type: 'text', protected: true,
    state: { value: 'secret' }, item: { type: 'text' } })
  eq('locked value', locked.value, null)
  eq('locked checked', locked.checked, null)
  eq('locked flag', locked.protected, true)
})

group('options, flow and confirm status are projections only', () => {
  const opts = M.optionsProjection([
    { value: 'a', label: 'A' }, { value: 'b', label: 'B', enabled: false }
  ], 'a', false)
  eq('option ids', opts.map(o => o.id).join(','), 'o0,o1')
  eq('selected option', opts[0].selected, true)
  eq('disabled option', opts[1].enabled, false)
  const locked = M.optionsProjection([{ value: 'secret' }], 'secret', true)
  eq('protected option value', locked[0].value, null)
  eq('idle confirm', JSON.stringify(M.confirmStatus(null, 0, null)),
    '{"kind":null,"stage":0,"total":0}')
  const flow = M.flowStatus({ active: true, index: 1, values: { 0: 'a' }, ready: false }, 'text', false)
  eq('flow step', flow.step, 1)
  eq('flow kind', flow.kind, 'text')
  eq('flow values', flow.values['0'], 'a')
  eq('protected flow values', M.flowStatus({ active: true, values: { 0: 'x' } }, '', true).values, null)
  eq('closed snapshot', JSON.stringify(M.closedSnapshot(7)),
    '{"open":false,"page":null,"depth":0,"scope":"none","revision":7,"row":null,"pending":false}')
  eq('scope global', M.scopeOf(true, false), 'global')
  eq('scope scoped', M.scopeOf(false, true), 'scoped')
  eq('scope none', M.scopeOf(false, false), 'none')
})

section('MenuState modal fields')
group('blank and initial state carry the shared modal flags', () => {
  const b = S.blankState()
  eq('blank prompt', b.promptOpen, false)
  eq('blank confirm kind', b.confirmKind, '')
  eq('blank confirm stage', b.confirmStage, 0)
  const i = S.initialState({ var: '' }, () => undefined)
  eq('initial prompt', i.promptOpen, false)
  eq('initial confirm kind', i.confirmKind, '')
  eq('initial confirm stage', i.confirmStage, 0)
  eq('initial checked still works', i.checked, false)
})

group('flow state has one record with visited, ready and draft', () => {
  const f = S.blankFlow()
  eq('flow index', f.index, 0)
  eq('flow visited', f.visited.join(','), '0')
  eq('flow ready', f.ready, false)
  eq('draft bit', f.draft.set, false)
  const restored = S.withFlow({ index: 2, values: { 0: 'x' }, visited: [0, 2], ready: true,
    draft: { set: true, value: 'y' } })
  eq('restored index', restored.index, 2)
  eq('restored visited', restored.visited.join(','), '0,2')
  eq('restored ready', restored.ready, true)
  eq('restored draft', restored.draft.value, 'y')
  eq('ragged record is healed', S.withFlow({ index: 1 }).visited.join(','), '1')
})

finish()
