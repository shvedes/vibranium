#!/usr/bin/env node
// Suite: 01D catalog rows - hyprlandSettings, idle, inhibitor, and the
// session lock-read gateway. Pure records and the shared grammar: no Qt
// engine and no live shell.
import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, finish, SHELL_DIR } from '../../lib/assert.mjs'

const C = loadLib(path.join(SHELL_DIR, 'common/text/IpcCatalog.js'))
const P = loadLib(path.join(SHELL_DIR, 'common/text/IpcProtocol.js'))

const D = ['hyprlandSettings', 'idle', 'inhibitor']

suite('ipc-d-targets', 'typed settings, idle, inhibitor and session lock rows')

section('catalog shape')

group('the three D targets exist with complete metadata', () => {
  for (const id of D) {
    const t = C.findTarget(id)
    eq(`${id}: target`, t !== null, true)
    for (const r of t.rows.filter(r => r.route !== 'injected')) {
      eq(`${r.id}: summary`, typeof r.summary === 'string' && r.summary.length > 0, true)
      eq(`${r.id}: output`, r.output && typeof r.output.kind === 'string', true)
      eq(`${r.id}: notes`, Array.isArray(r.notes), true)
      eq(`${r.id}: examples`, Array.isArray(r.examples), true)
      eq(`${r.id}: grammar compiles`, P.compile(r.words).ok, true)
    }
  }
  eq('hyprlandSettings.reload has no examples', C.findRow('hyprlandSettings.reload').examples, [])
})

function match(id, argv) {
  const row = C.findRow(id)
  eq(`${id}: row`, row !== null, true)
  return P.match(row.words, argv)
}

section('grammar')

group('hyprlandSettings toggle is a leaf, not a JSON string', () => {
  const value = C.findRow('hyprlandSettings.set.value')
  const toggle = C.findRow('hyprlandSettings.set.toggle')
  eq('set.value takes parsed JSON', P.match(value.words, ['set', 'k', 'true']).args.JSON, true)
  eq('set.toggle is its own row', toggle !== null, true)
  eq('set.toggle matches the literal', P.match(toggle.words, ['set', 'k', '--toggle']).ok, true)
  eq('set.value refuses the literal', P.match(value.words, ['set', 'k', '--toggle']).ok, false)
  eq('the JSON string is still data', P.match(value.words, ['set', 'k', '"--toggle"']).args.JSON, '--toggle')
  eq('set.value takes optional verbose', P.match(value.words,
    ['set', 'k', 'true', 'verbose']).ok, true)
  eq('set.toggle takes optional verbose', P.match(toggle.words,
    ['set', 'k', '--toggle', 'verbose']).ok, true)
  eq('verbose is not a JSON value', P.match(value.words,
    ['set', 'k', 'verbose']).ok, false)
  eq('get needs a key', P.match(C.findRow('hyprlandSettings.get').words, ['get']).ok, false)
})

group('idle seconds grammar', () => {
  eq('add takes integer seconds and one command atom',
    match('idle.add', ['add', '600', 'systemctl suspend']).args.COMMAND,
    'systemctl suspend')
  eq('add refuses a fractional second', match('idle.add', ['add', '1.5', 'x']).ok, false)
  eq('add refuses a unit suffix', match('idle.add', ['add', '10m', 'x']).ok, false)
  eq('add refuses an empty command', match('idle.add', ['add', '10', '']).ok, false)
  eq('remove takes a decimal id', match('idle.remove', ['remove', '0']).args.ID, 0)
  eq('class validates the enum', match('idle.class', ['class', '0', 'suspend']).args.CLASS, 'suspend')
  eq('class refuses a bad value', match('idle.class', ['class', '0', 'other']).ok, false)
})

group('inhibitor grammar', () => {
  eq('start takes unsigned seconds', match('inhibitor.start', ['start', '0']).args.SECONDS, 0)
  eq('start refuses a negative', match('inhibitor.start', ['start', '-1']).ok, false)
  const next = C.findRow('inhibitor.cycle.next')
  const back = C.findRow('inhibitor.cycle.back')
  eq('cycle next exists', next !== null, true)
  eq('cycle back exists', back !== null, true)
  eq('both cycle leaves are parent-hidden', next.parentHidden === true && back.parentHidden === true, true)
  eq('cycle next matches its branch words', P.match(next.words, ['cycle', 'next']).ok, true)
  eq('cycle back matches its branch words', P.match(back.words, ['cycle', 'back']).ok, true)
  eq('the cycle keyword is a help-only row', C.findRow('inhibitor.cycle').helpOnly, true)
  eq('the old cycleBackward spelling is gone', C.findRow('inhibitor.cycleBackward'), null)
  eq('isActive moved to status', C.findRow('inhibitor.isActive'), null)
  eq('cycle is not the retired toggle', C.findRow('inhibitor.toggle') === null, true)
})

group('the lockscreen target is gone and the lock read moved to session status', () => {
  eq('no lockscreen target', C.findTarget('lockscreen'), null)
  eq('not in the index ids', C.targetIds().includes('lockscreen'), false)
  eq('no lockscreen row survives', C.allRowIds().filter(id => id.startsWith('lockscreen.')), [])
  eq('no lock/unlock row survives under any target',
    C.allRowIds().filter(id => /lockscreen\.(lock|unlock|isLocked|status|ping)$/.test(id)), [])
  eq('the old isLocked verb is gone', C.findRow('session.isLocked'), null)
  const status = C.findRow('session.status')
  eq('status is the injected row', status.route, 'injected')
  eq('status stays unlisted on the session page', status.visible, undefined)
  eq('status carries the lock state', status.summary, 'Show session lock and power state')
  eq('status has one example', status.examples, ['vb-shell session status'])
  const firmware = C.findRow('session.reboot.firmware')
  eq('firmware reboot is an action row', firmware.route, 'compat')
  eq('firmware reboot matches reboot firmware',
    P.match(firmware.words, ['reboot', 'firmware']).ok, true)
  eq('firmware reboot refuses a bare reboot',
    P.match(firmware.words, ['reboot']).ok, false)
  eq('normal reboot keeps its own row', C.findRow('session.reboot').words[0], 'reboot')
})

section('shared invariants')

group('the new rows keep the common surface', () => {
  for (const id of D) {
    const t = C.findTarget(id)
    const injected = t.rows.filter(r => r.route === 'injected').map(r => r.id)
    eq(`${id}: common verbs injected once`, injected,
      [`${id}.help`, `${id}.status`, `${id}.ping`])
  }
  eq('target ids still sorted', C.targetIds(), [...C.Manifest.targets.map(t => t.id)].sort())
  // Retired native spellings must not be published by the catalog.
  const ids = C.publicRowIds()
  for (const retired of ['hyprlandSettings.toggle', 'inhibitor.toggle',
    'idle.setMinutes', 'idle.setEnabled', 'idle.set']) {
    eq(`${retired} absent`, ids.includes(retired), false)
  }
})

group('the documented source guards remain', () => {
  const idle = fs.readFileSync(path.join(SHELL_DIR, 'services/session/IdleDaemon.qml'), 'utf8')
  eq('the arm guard still rejects malformed rows', idle.includes('_armTimeout(row) < 0'), true)
  eq('the arm guard still requires own seconds', idle.includes('hasOwnProperty.call(row, "seconds")'), true)
  eq('no minutes arithmetic in arming', /timeout:\s*t\.minutes/.test(idle), false)
})

finish()
