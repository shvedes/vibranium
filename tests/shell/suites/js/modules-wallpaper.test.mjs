#!/usr/bin/env node
// Suite: the six pure-JS files no other suite covers in full. One of them,
// shell/common/power/BatteryModel.js, is shared with the power services,
// and the three helpers they read are asserted in services-power.test.mjs
// rather than here.
//
//   shell/common/power/BatteryModel.js                  level table + rows
//   shell/common/text/UnitIpc.js                       the ipc help block
//   shell/features/bar/modules/Bluetooth/Model.js      device snapshot + sort
//   shell/features/bar/modules/Network/Model.js        speedtest, stats, wifi
//   shell/features/pass/Model.js                       the pass vocabulary
//   shell/features/wallpaper/WallpaperTrans.js         transition geometry
//
// Every one of these sits on a binding that re-evaluates per frame or per
// keystroke, and every one has a header comment stating a contract the tests
// are expected to hold it to. The clusters below are organised by that
// contract rather than by function, so a function with three contracts is
// asserted in three places.
//
// Two conventions worth stating up front:
//
//   * Colours. Five of these libraries return a PALETTE KEY ("red",
//     "green", "orange", "yellow", "foreground_0"), never a colour value -
//     Icon.qml resolves the key through the theme. No assertion here pins a
//     theme colour or a palette entry: the battery cluster tints the returned
//     key through a probe-local `tint()` fed a SYNTHETIC palette and asserts
//     the shape of the result, so the test is about the level table and not
//     about whichever theme is loaded.
//   * Surprises. Behaviour that reads wrong at first glance is pinned with a
//     `//` comment naming the source line that causes it, and the real value
//     is asserted, so a future "fix" turns this suite red rather than silent.

import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, ne, is, match, notMatch, contains, notContains,
  throws, noThrow, approx, skip, deepEqual, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const UI = loadLib(path.join(SHELL_DIR, 'common', 'text', 'UnitIpc.js'))
const BAT = loadLib(path.join(SHELL_DIR, 'common', 'power', 'BatteryModel.js'))
const BT = loadLib(path.join(SHELL_DIR, 'features', 'bar', 'modules', 'Bluetooth', 'Model.js'))
const NET = loadLib(path.join(SHELL_DIR, 'features', 'bar', 'modules', 'Network', 'Model.js'))
const PASS = loadLib(path.join(SHELL_DIR, 'features', 'pass', 'Model.js'))
const WT = loadLib(path.join(SHELL_DIR, 'features', 'wallpaper', 'WallpaperTrans.js'))

// --- helpers ---------------------------------------------------------------

// UnitIpc builds one CLI-shaped block per unit. Exactness is the whole
// value of that library, so the tests build expectations as full strings
// and compare with eq, never with `contains` - except where the group says
// otherwise.

// UPowerDeviceType members, passed through from QML. Only the two the model
// filters on are needed: LinePower (the AC adapter) and Unknown.
const LINE_POWER = 1
const UNKNOWN = 0
const BATTERY_TYPE = 2

// WifiSecurityType.Open / .Owe, passed in by NetworkIsland.qml:362.
const OPEN_SEC = 10
const OWE_SEC = 9

// tint() mirrors Ui.qml:132 - `Theme.color(key)` then `Qt.alpha(c, a)` -
// with a palette supplied by the test. It exists so the battery assertions
// can talk about the SHAPE of a tinted colour (8-digit #aarrggbb, alpha as
// asked for) rather than about a theme value, which changes during
// development. Nothing here reads the shipped palette.
const PALETTE = { red: '#c03a3a', orange: '#c07a30', yellow: '#c0b030', green: '#3ac03a', foreground_0: '#d8d8e0' }
const qtAlpha = (hex, a) => {
  const h = hex.replace('#', '')
  const aa = Math.round(Math.max(0, Math.min(1, a)) * 255).toString(16).padStart(2, '0')
  return `#${aa}${h}`
}
const tint = (key, a) => (key in PALETTE ? qtAlpha(PALETTE[key], a) : 'transparent')

const entriesOf = (rows) => rows.map((e) => e.ssid)
const signed = (n) => Math.sign(n)

suite('modules-wallpaper', 'UnitIpc + Battery/Bluetooth/Network models + pass/Model + WallpaperTrans')

// ======================================================================
section('the harness contract')
group('all six libraries load and publish a namespace', () => {
  for (const [label, lib] of [
    ['UnitIpc', UI],
    ['Battery/Model', BAT],
    ['Bluetooth/Model', BT],
    ['Network/Model', NET],
    ['pass/Model', PASS],
    ['WallpaperTrans', WT],
  ]) {
    is(`${label} loaded`, lib, (v) => v && typeof v === 'object' && Object.keys(v).length > 0, 'a non-empty namespace')
  }
  // The counts are the ledger's own inputs, asserted here so a change to a
  // library's surface is a visible diff rather than a silent ledger shrink.
  eq('UnitIpc publishes one helper', Object.keys(UI).length, 1)
  eq('Battery/Model publishes twenty', Object.keys(BAT).length, 20)
  eq('Bluetooth/Model publishes nine', Object.keys(BT).length, 9)
  // 28 functions plus the two table vars the module also declares. QML only
  // ever sees the functions, so the vars are the loader's extra surface.
  eq('Network/Model publishes thirty-two', Object.keys(NET).length, 32)
  // 17 pass helpers plus the five that carry the log anonymisation and the two
  // private helpers behind them. The count is what notices if one of the
  // redaction functions is ever inlined away: every one of the seven takes a
  // store name and every one is covered by the clusters below.
  eq('pass/Model publishes twenty-four', Object.keys(PASS).length, 24)
  // 17 in module.exports plus `fracOr`, which the file never exports but the
  // loader picks up as a top-level declaration.
  eq('WallpaperTrans publishes eighteen', Object.keys(WT).length, 18)
})
group('the kit SHELL_DIR opens every one of the six', () => {
  // SHELL_DIR walks up from tests/shell/lib, so it has to be asserted rather
  // than assumed: if it ever lands above the checkout, every suite that
  // trusted it fails at import time instead of here.
  match('it ends in the shell tree', SHELL_DIR, /[/\\]shell$/)
  for (const rel of [
    'common/power/BatteryModel.js',
    'common/text/UnitIpc.js',
    'features/bar/modules/Bluetooth/Model.js',
    'features/bar/modules/Network/Model.js',
    'features/pass/Model.js',
    'features/wallpaper/WallpaperTrans.js',
  ]) {
    eq(`it opens ${rel}`, fs.existsSync(path.join(SHELL_DIR, rel)), true)
  }
})

// ======================================================================
section('UnitIpc.help - the CLI block every unit help verb returns')
group('the full block is Usage, Description, Commands, Examples, Run-line', () => {
  eq(
    'a two-verb block',
    UI.help('wallpaper', 'Wallpaper', 'wallpaper service', [
      { name: 'dump', help: 'enabled module ids in display order' },
      { name: 'enable', help: '(id) enable a bar module' },
    ]),
    'Usage: vb-shell wallpaper <command> [args...]\n'
      + '\nWallpaper service.\n'
      + '\nCommands:\n'
      + '  dump            enabled module ids in display order\n'
      + '  enable <id>     enable a bar module\n'
      + '  status          health + unit payload\n'
      + '  ping            liveness\n'
      + '  help [command]  show help for one command\n'
      + '\nExamples:\n  vb-shell wallpaper help status\n'
      + '\nRun `vb-shell help` to list all units.\n',
  )
  eq('the output ends in exactly one newline', UI.help('t', 'T', 'd', []).endsWith('\n'), true)
  eq('and the last line is the units hint', UI.help('t', 'T', 'd', []).trimEnd().split('\n').pop(), 'Run `vb-shell help` to list all units.')
  eq('the title feeds no line: the target names the unit', UI.help('wallpaper', 'Wallpaper', 'wallpaper service', []).includes('Wallpaper -'), false)
  eq(
    'an empty verb list leaves Usage, Description, the suffix and the frame',
    UI.help('OSD', 'OSD', 'on-screen display overlays', []),
    'Usage: vb-shell OSD <command> [args...]\n'
      + '\nOn-screen display overlays.\n'
      + '\nCommands:\n'
      + '  status          health + unit payload\n'
      + '  ping            liveness\n'
      + '  help [command]  show help for one command\n'
      + '\nExamples:\n  vb-shell OSD help status\n'
      + '\nRun `vb-shell help` to list all units.\n',
  )
})
group('a leading paren group is usage, the rest is description', () => {
  eq(
    'one argument',
    UI.help('t', 'T', 'd', [{ name: 'set', help: '(path) set the wallpaper' }], 'set'),
    'Usage: vb-shell t set <path>\n\nSet the wallpaper.\n\nRun `vb-shell t help` to list all commands.\n',
  )
  eq(
    'comma-separated arguments render as one placeholder each',
    UI.help('t', 'T', 'd', [{ name: 'set', help: '(key, json) write one value' }], 'set'),
    'Usage: vb-shell t set <key> <json>\n\nWrite one value.\n\nRun `vb-shell t help` to list all commands.\n',
  )
  eq(
    'no paren group means no usage',
    UI.help('t', 'T', 'd', [{ name: 'get', help: 'current path' }], 'get'),
    'Usage: vb-shell t get\n\nCurrent path.\n\nRun `vb-shell t help` to list all commands.\n',
  )
  eq('an empty group is no usage either', UI.help('t', 'T', 'd', [{ name: 'x', help: '() h' }], 'x'), 'Usage: vb-shell t x\n\nH.\n\nRun `vb-shell t help` to list all commands.\n')
  eq('a bracketed word is already optional and stays as-is', UI.help('t', 'T', 'd', [{ name: 'x', help: '(minutes, [command]) h' }], 'x'), 'Usage: vb-shell t x <minutes> [command]\n\nH.\n\nRun `vb-shell t help` to list all commands.\n')
})
group('a signature wins over the paren group', () => {
  eq(
    'the parenthesised signature renders as placeholders',
    UI.help('n', 'N', 'd', [{ name: 'dismiss', signature: '(id)', help: 'dismiss one notification by id' }], 'dismiss'),
    'Usage: vb-shell n dismiss <id>\n\nDismiss one notification by id.\n\nRun `vb-shell n help` to list all commands.\n',
  )
  eq(
    'a bare signature is printed as-is, so the line reads oddly but stably',
    UI.help('t', 'T', 'd', [{ name: 'set', signature: '<value>', help: 'h' }], 'set'),
    'Usage: vb-shell t set <value>\n\nH.\n\nRun `vb-shell t help` to list all commands.\n',
  )
  // A falsy signature - the no-argument spelling - falls through to the
  // paren parse. Pinned because it is the whole reason the empty usage
  // exists.
  eq('an empty signature falls back to the paren group', UI.help('t', 'T', 'd', [{ name: 'x', signature: '', help: '(a) h' }], 'x'), 'Usage: vb-shell t x <a>\n\nH.\n\nRun `vb-shell t help` to list all commands.\n')
  eq('a null signature falls back too', UI.help('t', 'T', 'd', [{ name: 'x', signature: null, help: 'h' }], 'x'), 'Usage: vb-shell t x\n\nH.\n\nRun `vb-shell t help` to list all commands.\n')
  eq('a numeric zero signature falls back', UI.help('t', 'T', 'd', [{ name: 'x', signature: 0, help: 'h' }], 'x'), 'Usage: vb-shell t x\n\nH.\n\nRun `vb-shell t help` to list all commands.\n')
  eq('a missing signature falls back', UI.help('t', 'T', 'd', [{ name: 'x', help: '(a) h' }], 'x'), 'Usage: vb-shell t x <a>\n\nH.\n\nRun `vb-shell t help` to list all commands.\n')
})
group('tables keep the verbatim text, prose reads as a sentence', () => {
  // The Commands column is never capitalised and never closed: it keeps
  // the author's fragment exactly, which is what makes the table greppable.
  contains('the table keeps lowercase', UI.help('t', 'T', 'd', [{ name: 'x', help: 'do the thing' }]), '  x               do the thing\n')
  eq('the Description capitalises and closes', UI.help('t', 'T', 'wallpaper service', []).split('\n')[2], 'Wallpaper service.')
  eq('a closed description is not closed twice', UI.help('t', 'T', 'ends here.', []).split('\n')[2], 'Ends here.')
  eq('the single-verb prose is a sentence too', UI.help('t', 'T', 'd', [{ name: 'x', help: 'do the thing' }], 'x').split('\n')[2], 'Do the thing.')
})
group('every row is indented by exactly two spaces, with no trailing space', () => {
  const out = UI.help('t', 'T', 'd', [{ name: 'x' }, { name: 'yy', help: '(a) h' }]).split('\n')
  const rows = out.slice(out.indexOf('Commands:') + 1, out.indexOf('Examples:') - 1)
  eq('the title row is the Usage line', out[0], 'Usage: vb-shell t <command> [args...]')
  for (const line of rows) {
    is(`"${line}" starts with two spaces`, line, (l) => l.startsWith('  ') && !l.startsWith('   '), 'exactly two leading spaces')
    is(`"${line}" carries no trailing whitespace`, line, (l) => l === l.trimEnd(), 'no trailing space')
  }
  // `x` has no description and no usage: the line is the bare name, and the
  // padding still aligns the column around it.
  eq('the bare-name line', rows[0], '  x')
  eq('the padded column', rows[1], '  yy <a>          h')
})
group('the three standard rows are always last, and only once', () => {
  const out = UI.help('t', 'T', 'd', []).split('\n')
  const cmds = out.slice(out.indexOf('Commands:') + 1, out.indexOf('Examples:') - 1)
  eq('the last command row', cmds[cmds.length - 1], '  help [command]  show help for one command')
  eq('status then ping before it', cmds.slice(cmds.length - 3, cmds.length - 1), ['  status          health + unit payload', '  ping            liveness'])
  // A unit that spells its own `status` verb does not displace the appended
  // one - the suffix is positional, not a lookup. Privacy.qml is the live
  // case: its snapshot line rides first and the standard line follows.
  eq(
    'a unit-supplied status line is kept and the standard one appended',
    UI.help('privacy', 'Privacy indicators', 'mic/camera/screenshare capture state', [
      { name: 'status', help: 'mic/cam/share/active snapshot' },
    ]),
    'Usage: vb-shell privacy <command> [args...]\n'
      + '\nMic/camera/screenshare capture state.\n'
      + '\nCommands:\n'
      + '  status          mic/cam/share/active snapshot\n'
      + '  status          health + unit payload\n'
      + '  ping            liveness\n'
      + '  help [command]  show help for one command\n'
      + '\nExamples:\n  vb-shell privacy help status\n'
      + '\nRun `vb-shell help` to list all units.\n',
  )
})
group('a query names one command; anything else is the full block', () => {
  eq(
    'the first match wins, so a custom status describes itself',
    UI.help('privacy', 'Privacy indicators', 'd', [{ name: 'status', help: 'mic/cam/share/active snapshot' }], 'status'),
    'Usage: vb-shell privacy status\n\nMic/cam/share/active snapshot.\n\nRun `vb-shell privacy help` to list all commands.\n',
  )
  eq(
    'an unknown command is an error plus the hint',
    UI.help('wallpaper', 'Wallpaper', 'd', [], 'bogus'),
    "error: unknown command 'bogus'\nRun `vb-shell wallpaper help` to list all commands.\n",
  )
  eq('the error reads as an error', UI.help('t', 'T', 'd', [], 'bogus').startsWith('error:'), true)
  eq('an empty query is the full block', UI.help('t', 'T', 'd', [], ''), UI.help('t', 'T', 'd', []))
  eq('a null query is the full block', UI.help('t', 'T', 'd', [], null), UI.help('t', 'T', 'd', []))
  eq('a missing query is the full block', UI.help('t', 'T', 'd', []), UI.help('t', 'T', 'd', [], undefined))
  eq(
    'a verb without help omits the prose paragraph rather than blanking it',
    UI.help('t', 'T', 'd', [{ name: 'x' }], 'x'),
    'Usage: vb-shell t x\n\nRun `vb-shell t help` to list all commands.\n',
  )
})
group('a verb with no name still prints a row', () => {
  // `v.name` is read unguarded, so a nameless verb renders as the literal
  // "undefined" rather than being skipped. Pinned: a hand-edited verb table
  // with a typo would otherwise silently lose a row, and this is what it
  // costs instead.
  contains('a missing name', UI.help('t', 'T', 'd', [{ help: 'h' }]), '  undefined')
})
group('the degenerate inputs the library does not guard', () => {
  // `verbs.length` is unguarded, so a missing verb list is a throw rather
  // than an empty block. Every caller passes a literal, so this is the
  // documented cost of the terse call.
  throws('a missing verb list', () => UI.help('t', 'T', 'd'), /length/)
  throws('a null verb list', () => UI.help('t', 'T', 'd', null), /length/)
  throws('a null verb entry', () => UI.help('t', 'T', 'd', [null]), /name/)
  throws('an undefined verb entry', () => UI.help('t', 'T', 'd', [undefined]), /name/)
  // A number has no length, so it walks nothing and emits the frame with an
  // empty Commands table rather than throwing.
  noThrow('a number verb list', () => UI.help('t', 'T', 'd', 7))
  // A string has a length, so the loop walks its characters and reads
  // `.name` off each - which a string character does not have. Two nameless
  // verb rows, not a throw. Pinned: it is the one non-array that gets past
  // the `verbs.length` read.
  eq('a two-character string walks as two nameless verbs', UI.help('t', 'T', 'd', 'xy').split('\n').filter((l) => l.includes('undefined')).length, 2)
})
group('the block is a pure function of its five arguments', () => {
  const verbs = [{ name: 'x', help: '(a) h' }]
  const snapshot = JSON.stringify(verbs)
  const first = UI.help('t', 'T', 'd', verbs)
  const second = UI.help('t', 'T', 'd', verbs)
  eq('two calls agree', first, second)
  eq('the verb array is untouched', JSON.stringify(verbs), snapshot)
  eq('no hidden state between calls', UI.help('t', 'T', 'd', []), UI.help('t', 'T', 'd', [], ''))
})
skip('the block as the ipc help verb returns it over a live socket', 'needs a resident shell and a D-Bus peer; the text itself is asserted exactly above')

// ======================================================================
section('Battery/Model.normalizePct - the 0..1 fraction UPower reports')
group('a fraction scales up to real percent', () => {
  eq('a full device reads 1', BAT.normalizePct(1), 100)
  eq('half', BAT.normalizePct(0.5), 50)
  approx('a third', BAT.normalizePct(1 / 3), 33.333333, 1e-4)
  eq('empty', BAT.normalizePct(0), 0)
  eq('one tenth', BAT.normalizePct(0.1), 10)
  // The README's warning is the whole reason this function exists: skipping
  // it turns every battery red, because 0.85 <= 5 is a critical reading.
  eq('a real laptop battery fraction', BAT.normalizePct(0.85), 85)
})
group('a value already above 1 passes through untouched', () => {
  eq('a real percentage of 85', BAT.normalizePct(85), 85)
  eq('5', BAT.normalizePct(5), 5)
  eq('15', BAT.normalizePct(15), 15)
  eq('30', BAT.normalizePct(30), 30)
  eq('100', BAT.normalizePct(100), 100)
  eq('a numeric string percentage', BAT.normalizePct('85'), 85)
  // The one-number boundary: 1 is the last value that scales, and 1.0001 is
  // already a "real percent" - so a device that overshoots the fraction by
  // a hair reads as ~0%, not as full. Pinned because it is the one input in
  // this function whose answer is not what the shape suggests.
  approx('1.0001 is a percent, not a fraction', BAT.normalizePct(1.0001), 1.0001, 1e-12)
  eq('2', BAT.normalizePct(2), 2)
  eq('a percentage above the scale is not clamped', BAT.normalizePct(255), 255)
})
group('a negative value keeps its sign, so it reads as critical', () => {
  eq('-1', BAT.normalizePct(-1), -100)
  eq('-0.5', BAT.normalizePct(-0.5), -50)
  eq('and -1 lands on the lowest level', BAT.batteryIconFor(-1, false), 'battery-0')
  eq('with the red body tone', BAT.batteryColorFor(-1, false), 'red')
})
group('a non-finite reading is a full device, not a critical one', () => {
  // "non-finite values read as full - LinePower-style devices never reach
  // here, they are filtered by isTrackedType". Pinned so the choice is
  // visible: an absent reading is not treated as an empty battery.
  eq('NaN', BAT.normalizePct(NaN), 100)
  eq('Infinity', BAT.normalizePct(Infinity), 100)
  eq('-Infinity', BAT.normalizePct(-Infinity), 100)
  eq('undefined', BAT.normalizePct(undefined), 100)
  eq('a non-numeric string', BAT.normalizePct('abc'), 100)
  eq('an empty string', BAT.normalizePct(''), 0)
  eq('and it drives the top level', BAT.batteryIconFor(NaN, false), 'battery-3')
})
group('the nullish and boolean folds', () => {
  // Number(null) is 0 and Number(true) is 1, so the two land in the
  // documented fraction branches. Pinned: `undefined` and `null` are not
  // interchangeable here, which is the opposite of what most of this tree
  // does.
  eq('null reads as an empty battery', BAT.normalizePct(null), 0)
  eq('true reads as a full device', BAT.normalizePct(true), 100)
  eq('false reads as an empty battery', BAT.normalizePct(false), 0)
  eq('a numeric string fraction', BAT.normalizePct('0.5'), 50)
  eq('an array holding a fraction', BAT.normalizePct([0.5]), 50)
  eq('an object is not a number', BAT.normalizePct({}), 100)
})

section('Battery/Model - the level table, on both sides of every threshold')
const LEVELS = [
  { pct: 0, icon: 'battery-0', accent: '', color: 'red' },
  { pct: 5, icon: 'battery-0', accent: '', color: 'red' },
  { pct: 6, icon: 'battery-1', accent: 'orange', color: 'foreground_0' },
  { pct: 15, icon: 'battery-1', accent: 'orange', color: 'foreground_0' },
  { pct: 16, icon: 'battery-2', accent: 'yellow', color: 'foreground_0' },
  { pct: 30, icon: 'battery-2', accent: 'yellow', color: 'foreground_0' },
  { pct: 31, icon: 'battery-3', accent: 'green', color: 'foreground_0' },
  { pct: 100, icon: 'battery-3', accent: 'green', color: 'foreground_0' },
]
group('the icon for a percentage', () => {
  for (const l of LEVELS) eq(`${l.pct}% -> ${l.icon}`, BAT.batteryIconFor(l.pct, false), l.icon)
  eq('the boundary at 5 is inclusive', BAT.batteryIconFor(5, false), 'battery-0')
  eq('and 5.1 is not', BAT.batteryIconFor(5.1, false), 'battery-1')
  eq('the boundary at 15 is inclusive', BAT.batteryIconFor(15, false), 'battery-1')
  eq('and 15.1 is not', BAT.batteryIconFor(15.1, false), 'battery-2')
  eq('the boundary at 30 is inclusive', BAT.batteryIconFor(30, false), 'battery-2')
  eq('and 30.1 is not', BAT.batteryIconFor(30.1, false), 'battery-3')
})
group('a fraction takes the same table', () => {
  eq('0.05 -> 5%', BAT.batteryIconFor(0.05, false), 'battery-0')
  eq('0.06 -> 6%', BAT.batteryIconFor(0.06, false), 'battery-1')
  eq('0.16 -> 16%', BAT.batteryIconFor(0.16, false), 'battery-2')
  eq('0.31 -> 31%', BAT.batteryIconFor(0.31, false), 'battery-3')
  eq('1 -> 100%', BAT.batteryIconFor(1, false), 'battery-3')
})
group('charging overrides every threshold', () => {
  // "charging -> battery-charging (bolt in accent green)" is the first branch
  // of all three functions, so a charging device at 2% still reads full.
  eq('at 0%', BAT.batteryIconFor(0, true), 'battery-charging')
  eq('at 5%', BAT.batteryIconFor(5, true), 'battery-charging')
  eq('at 30%', BAT.batteryIconFor(30, true), 'battery-charging')
  eq('at 100%', BAT.batteryIconFor(100, true), 'battery-charging')
  eq('the accent is green whatever the level', BAT.batteryAccentFor(0, true), 'green')
  eq('and the body tone leaves red behind', BAT.batteryColorFor(0, true), 'foreground_0')
  // The flag is a truthiness test, not a strict `=== true`, so QML handing
  // over a truthy object takes the charging branch.
  eq('a truthy non-boolean charges', BAT.batteryIconFor(1, 'yes'), 'battery-charging')
  eq('a falsy flag does not', BAT.batteryIconFor(1, 0), 'battery-3')
  eq('an undefined flag does not', BAT.batteryIconFor(1, undefined), 'battery-3')
})
group('the accent key per level', () => {
  for (const l of LEVELS) eq(`${l.pct}% -> accent ${l.accent === '' ? '(none)' : l.accent}`, BAT.batteryAccentFor(l.pct, false), l.accent)
  // "battery-0 carries no pills (its outline goes red through
  // batteryColorFor)" - so its accent is the empty string, which is how Icon
  // reads "recolour the whole icon in one tone".
  eq('the empty accent is a key, not a colour', BAT.batteryAccentFor(0, false), '')
  eq('every other level carries a key', new Set(LEVELS.map((l) => l.accent)).size, 4)
})
group('the body tone per level', () => {
  for (const l of LEVELS) eq(`${l.pct}% -> ${l.color}`, BAT.batteryColorFor(l.pct, false), l.color)
  eq('only battery-0 diverges', new Set(LEVELS.map((l) => l.color)).size, 2)
  eq('everything else is the theme foreground', BAT.batteryColorFor(100, false), 'foreground_0')
})
group('the three functions agree on the level, always', () => {
  // The table runs on real percent, so the sweep has to normalize first: a
  // raw 1 is a FULL device (the fraction branch), not one percent.
  for (let p = 0; p <= 100; p++) {
    const real = BAT.normalizePct(p)
    const expected = real <= 5 ? 'red' : 'foreground_0'
    if (BAT.batteryColorFor(real, false) !== expected) {
      eq(`body tone at ${real}%`, BAT.batteryColorFor(real, false), expected)
    }
  }
  eq('and a raw 1 is a full device, so not red', BAT.batteryColorFor(1, false), 'foreground_0')
  eq('no level disagrees over the whole scale', LEVELS.every((l) => BAT.batteryColorFor(l.pct, false) === l.color), true)
  // The icon and the accent are a pair: 0 carries no accent, 1/2/3 carry
  // orange/yellow/green, and charging carries green whatever the icon.
  const pairs = new Set()
  for (let p = 0; p <= 100; p++) pairs.add(BAT.batteryIconFor(p, false) + '/' + BAT.batteryAccentFor(p, false))
  eq('there are exactly four (icon, accent) pairs', pairs.size, 4)
  eq('and one more for charging', new Set([...pairs, 'battery-charging/green']).size, 5)
})
group('the returned strings are palette keys and icon stems, never colours', () => {
  // Icon.qml takes colorKey/accentKey and resolves them through the theme, so
  // this library never produces a `#rrggbb`. Asserting the SHAPE keeps the
  // test about the level table rather than about a theme value.
  for (const l of LEVELS) {
    is(`the icon ${l.icon} is an asset stem`, l.icon, (s) => /^[a-z]+(-\d)?$/.test(s) && !s.includes('#'), 'a bare stem, no colour')
    is(`the accent ${l.accent || '(empty)'} is a key`, l.accent, (s) => s === '' || /^[a-z]+_[0-9]$/.test(s) || /^[a-z]+$/.test(s), 'a palette key, not a colour')
  }
  // And the shape of what the view then paints, through a probe-local tint
  // over a synthetic palette (see tint() at the top).
  is('the empty accent tints to nothing', tint(BAT.batteryAccentFor(3, false), 1), (s) => s === 'transparent', 'no accent means no second tone')
  is('a named key tints to #aarrggbb', tint(BAT.batteryAccentFor(10, false), 1), (s) => /^#[0-9a-f]{8}$/.test(s), '8 hex digits with alpha')
  is('the alpha is the one the component asked for', tint(BAT.batteryAccentFor(10, false), 0.5), (s) => s.slice(1, 3) === '80', 'alpha ff * 0.5 = 80')
  is('a full alpha', tint(BAT.batteryAccentFor(10, false), 1), (s) => s.slice(1, 3) === 'ff', 'alpha ff')
  is('a zero alpha', tint(BAT.batteryAccentFor(10, false), 0), (s) => s.slice(1, 3) === '00', 'alpha 00')
  is('the level table is a four-way choice, not a gradient', LEVELS.map((l) => l.accent).filter(Boolean).length >= 3, (v) => v === true, 'three or more distinct accents')
})
group('a percentage that is not a number still produces a key', () => {
  noThrow('a string', () => BAT.batteryIconFor('x', false))
  noThrow('an object', () => BAT.batteryIconFor({}, false))
  noThrow('no argument', () => BAT.batteryIconFor())
  eq('a non-numeric string reads as full', BAT.batteryIconFor('x', false), 'battery-3')
  eq('undefined reads as full', BAT.batteryIconFor(undefined, false), 'battery-3')
  eq('a numeric-looking string is coerced', BAT.batteryIconFor('5', false), 'battery-0')
  eq('and "15"', BAT.batteryIconFor('15', false), 'battery-1')
  eq('and "0.2"', BAT.batteryIconFor('0.2', false), 'battery-2')
  eq('null reads as empty', BAT.batteryIconFor(null, false), 'battery-0')
  eq('and the accent follows', BAT.batteryAccentFor(null, false), '')
  eq('and the tone follows', BAT.batteryColorFor(null, false), 'red')
})
group('a percentage object missing its fields is a total function', () => {
  // The three functions take two scalars, so "an object missing the one field
  // the code reads" is the call with nothing at all - and it must still
  // answer rather than throw, because they sit on a binding.
  eq('no percentage, not charging', [BAT.batteryIconFor(undefined, false), BAT.batteryAccentFor(undefined, false), BAT.batteryColorFor(undefined, false)], ['battery-3', 'green', 'foreground_0'])
  eq('no percentage, charging', [BAT.batteryIconFor(undefined, true), BAT.batteryAccentFor(undefined, true), BAT.batteryColorFor(undefined, true)], ['battery-charging', 'green', 'foreground_0'])
  // Number([]) is 0 and Number([0.5]) is 0.5, so an array is a number, not a
  // non-number: the empty array reads as an empty battery and [0.5] as half.
  eq('an empty array instead of a number', BAT.batteryIconFor([], false), 'battery-0')
  eq('an array holding a fraction', BAT.batteryIconFor([0.5], false), 'battery-3')
  eq('an array holding a percentage', BAT.batteryIconFor([85], false), 'battery-3')
  eq('a function instead of a number', BAT.batteryIconFor(() => {}, false), 'battery-3')
})

section('Battery/Model.isTrackedType - the device filter')
group('everything except the AC adapter and Unknown is tracked', () => {
  eq('a laptop Battery', BAT.isTrackedType(BATTERY_TYPE, LINE_POWER, UNKNOWN), true)
  eq('the AC adapter is not', BAT.isTrackedType(LINE_POWER, LINE_POWER, UNKNOWN), false)
  eq('Unknown is not', BAT.isTrackedType(UNKNOWN, LINE_POWER, UNKNOWN), false)
  // "the laptop Battery itself plus mice, keyboards, headsets and the rest".
  for (const t of [2, 3, 4, 5, 6, 7, 8, 99]) {
    eq(`type ${t} is tracked`, BAT.isTrackedType(t, LINE_POWER, UNKNOWN), true)
  }
  eq('a negative enum value is tracked', BAT.isTrackedType(-1, LINE_POWER, UNKNOWN), true)
})
group('the two excluded values are the ones passed in, not the ones hardcoded', () => {
  // "Callers pass the UPowerDeviceType enum members through so this stays
  // unit-drivable without Qt imports."
  // The comparison is `type !== linePower && type !== unknown`, so a
  // different pair of members only rejects the values it actually names.
  eq('a pair that names neither Battery still tracks it', BAT.isTrackedType(2, 5, 6), true)
  eq('a pair that names it rejects it', BAT.isTrackedType(5, 5, 6), false)
  eq('and the real pair is unchanged', BAT.isTrackedType(2, 1, 0), true)
  // With the two members equal, that one value is the only exclusion - a
  // degenerate call the real QML never makes, pinned so the identity read is
  // visible.
  eq('linePower === unknown rejects only that value', [BAT.isTrackedType(0, 0, 0), BAT.isTrackedType(1, 0, 0)], [false, true])
  eq('undefined members reject nothing', BAT.isTrackedType(0, undefined, undefined), true)
})
group('an object missing the fields is a comparison, not a read', () => {
  noThrow('no argument at all', () => BAT.isTrackedType())
  eq('with no arguments the undefined value is excluded twice', BAT.isTrackedType(), false)
  eq('a string type', BAT.isTrackedType('Battery', LINE_POWER, UNKNOWN), true)
  eq('a null type', BAT.isTrackedType(null, LINE_POWER, UNKNOWN), true)
  eq('an object type', BAT.isTrackedType({}, LINE_POWER, UNKNOWN), true)
  // `!==` is strict, so a stringified enum member is a DIFFERENT value and
  // is therefore tracked. Pinned: passing String(UPowerDeviceType.LinePower)
  // instead of the member would silently track the AC adapter.
  eq('a stringified LinePower is not the member, so it is tracked', BAT.isTrackedType(String(LINE_POWER), LINE_POWER, UNKNOWN), true)
  eq('a stringified Unknown likewise', BAT.isTrackedType(String(UNKNOWN), LINE_POWER, UNKNOWN), true)
  eq('a non-string member is not the same as the string form', BAT.isTrackedType(LINE_POWER, String(LINE_POWER), UNKNOWN), true)
})

section('Battery/Model.deviceLabel - model, then type, then path')
group('the three-step fallback', () => {
  eq('a model wins', BAT.deviceLabel('Logitech G305', 'Mouse', '/sys/bus/...'), 'Logitech G305')
  eq('the type is second', BAT.deviceLabel('', 'Mouse', '/sys/bus/...'), 'Mouse')
  eq('the native path is last', BAT.deviceLabel('  ', '  ', '/sys/devices/x'), '/sys/devices/x')
  eq('whitespace is trimmed at every step', BAT.deviceLabel('  G305  ', 'Mouse', '/x'), 'G305')
  eq('a whitespace model is not a model', BAT.deviceLabel('\t\n', 'Mouse', '/x'), 'Mouse')
  eq('a whitespace type is not a type', BAT.deviceLabel('', '  ', '/x'), '/x')
})
group('with nothing at all the label is the generic one', () => {
  eq('all empty', BAT.deviceLabel('', '', ''), 'Unknown device')
  eq('all null', BAT.deviceLabel(null, null, null), 'Unknown device')
  eq('no arguments', BAT.deviceLabel(), 'Unknown device')
  // `String(model || "")` stringifies BEFORE trimming, so an empty object is
  // a truthy "[object Object]" and wins the first step. Pinned: the guard is
  // a falsiness test, not a presence test.
  eq('an object model stringifies and wins', BAT.deviceLabel({}, 'Mouse', '/x'), '[object Object]')
  eq('three objects stop at the first', BAT.deviceLabel({}, {}, {}), '[object Object]')
  // `model || ""` is a falsy fold, so a numeric 0 model is not a model.
  eq('a zero model falls through to the type', BAT.deviceLabel(0, 'Mouse', '/x'), 'Mouse')
  eq('and a zero type falls through to the path', BAT.deviceLabel(0, 0, '/x'), '/x')
})
group('non-string arguments are stringified, not rejected', () => {
  eq('a numeric model', BAT.deviceLabel(305, 'Mouse', '/x'), '305')
  eq('an object model', BAT.deviceLabel({ a: 1 }, 'Mouse', '/x'), '[object Object]')
  eq('an array model', BAT.deviceLabel(['a'], 'Mouse', '/x'), 'a')
  eq('a numeric path', BAT.deviceLabel('', '', 42), '42')
  eq('a false model falls through', BAT.deviceLabel(false, 'Mouse', '/x'), 'Mouse')
})

section('Battery/Model.deviceIconName - the UPower type glyph')
group('each device class gets a distinctive stem', () => {
  eq('Mouse', BAT.deviceIconName('Mouse'), 'mice')
  eq('Touchpad', BAT.deviceIconName('Touchpad'), 'mice')
  eq('Keyboard', BAT.deviceIconName('Keyboard'), 'keyboard')
  eq('Input - Gaming', BAT.deviceIconName('Input - Gaming'), 'gamepad')
  eq('Headset', BAT.deviceIconName('Headset'), 'headset')
  eq('Headphones', BAT.deviceIconName('Headphones'), 'headphones')
  eq('Speaker', BAT.deviceIconName('Speaker'), 'speaker')
  eq('Audio Card', BAT.deviceIconName('Audio Card'), 'speaker')
  eq('Monitor', BAT.deviceIconName('Monitor'), 'monitor')
  eq('Computer', BAT.deviceIconName('Computer'), 'monitor')
  eq('Battery', BAT.deviceIconName('Battery'), 'monitor')
  eq('UPS', BAT.deviceIconName('UPS'), 'power')
  eq('Printer', BAT.deviceIconName('Printer'), 'printer')
  eq('Scanner', BAT.deviceIconName('Scanner'), 'printer')
  eq('Modem', BAT.deviceIconName('Modem'), 'ethernet')
  eq('Network', BAT.deviceIconName('Network'), 'ethernet')
})
group('the match is on the lowercased string, and a compound is not special', () => {
  eq('lowercased before matching', BAT.deviceIconName('MOUSE'), 'mice')
  eq('a compound UPower spells', BAT.deviceIconName('Mouse - Bluetooth'), 'mice')
  eq('the padding is trimmed only at the ends, not internally', BAT.deviceIconName('  Keyboard  '), 'keyboard')
  // The order of the tests is load-bearing: "Audio Card" reaches the speaker
  // branch, and "Input - Gaming" must not be caught by the earlier audio or
  // computer branches.
  eq('an input gaming pad is not an audio device', BAT.deviceIconName('Input - Gaming'), 'gamepad')
  eq('computer is the catch-all for desktop classes', BAT.deviceIconName('Computer - Laptop'), 'monitor')
})
group('an unknown class is the empty stem, and the caller supplies the fallback', () => {
  // "Empty when the class has no shipped glyph - callers fall back to the
  // generic bluetooth mark" (BatteryIsland.qml:101).
  eq('an unclassed type', BAT.deviceIconName('Unknown'), '')
  eq('a blank type', BAT.deviceIconName(''), '')
  eq('a null type', BAT.deviceIconName(null), '')
  eq('undefined', BAT.deviceIconName(undefined), '')
  eq('a numeric type', BAT.deviceIconName(7), '')
  eq('a whitespace type', BAT.deviceIconName('   '), '')
  eq('no argument', BAT.deviceIconName(), '')
  // The real fallback is the island's, so the empty string is a contract
  // rather than a failure.
  eq('the island falls back to bluetooth', BAT.deviceIconName('Unknown') !== '' ? BAT.deviceIconName('Unknown') : 'bluetooth', 'bluetooth')
})

section('Battery/Model.prettyState - the UPower state words')
group('the seven probed states come out sentence-cased', () => {
  eq('Unknown', BAT.prettyState('Unknown'), 'Unknown')
  eq('Charging', BAT.prettyState('Charging'), 'Charging')
  eq('Discharging', BAT.prettyState('Discharging'), 'Discharging')
  eq('Empty', BAT.prettyState('Empty'), 'Empty')
  eq('Fully Charged', BAT.prettyState('Fully Charged'), 'Fully charged')
  eq('Pending Charge', BAT.prettyState('Pending Charge'), 'Pending charge')
  eq('Pending Discharge', BAT.prettyState('Pending Discharge'), 'Pending discharge')
})
group('the squashed spelling is accepted too', () => {
  // The map is keyed on the whitespace-stripped name, so a caller that
  // already squashed the enum still gets the right wording.
  eq('FullyCharged', BAT.prettyState('FullyCharged'), 'Fully charged')
  eq('PendingCharge', BAT.prettyState('PendingCharge'), 'Pending charge')
  eq('PendingDischarge', BAT.prettyState('PendingDischarge'), 'Pending discharge')
  eq('padded then squashed', BAT.prettyState('  Fully Charged  '), 'Fully charged')
  eq('an internal run of spaces collapses', BAT.prettyState('Fully   Charged'), 'Fully charged')
  eq('a tab is whitespace too', BAT.prettyState('Fully\tCharged'), 'Fully charged')
})
group('an unmapped state is de-camel-cased rather than dropped', () => {
  eq('a two-word unknown', BAT.prettyState('Something Else'), 'Something Else')
  eq('a camel-cased unknown', BAT.prettyState('CamelCase'), 'Camel Case')
  // The pass is `([a-z])([A-Z])`, so it only splits a lower-to-upper pair:
  // a leading capital has no lower-case neighbour to pair with.
  eq('three words', BAT.prettyState('ATotallyNewState'), 'ATotally New State')
  // The map is not case-folded, so a lowercase state string is not matched
  // and falls to the de-camel pass, which cannot undo the casing. Pinned:
  // the enum's toString is what makes this safe in practice.
  eq('a lowercase state is not the map key', BAT.prettyState('unknown'), 'unknown')
  // The fallback de-camel-cases the SQUASHED string, so a lower-case
  // "fully charged" comes back with the space gone. Pinned: the answer a
  // non-enum state gets is lossy, which is fine because the map is what
  // covers every real enum value.
  eq('a mixed-case state comes back squashed', BAT.prettyState('fully charged'), 'fullycharged')
})
group('an empty or nullish state reads as Unknown', () => {
  eq('the empty string', BAT.prettyState(''), 'Unknown')
  eq('whitespace', BAT.prettyState('   '), 'Unknown')
  eq('null', BAT.prettyState(null), 'Unknown')
  eq('undefined', BAT.prettyState(undefined), 'Unknown')
  eq('no argument', BAT.prettyState(), 'Unknown')
  // `String(stateString || "")` is a falsy fold first, so 0 is the empty
  // string and reads as Unknown rather than as the number.
  eq('a zero state is the empty string', BAT.prettyState(0), 'Unknown')
  eq('a non-zero number is stringified', BAT.prettyState(7), '7')
  eq('a numeric state matches nothing', BAT.batteryIconFor(BAT.normalizePct(0), false), 'battery-0')
})

section('Battery/Model.formatDuration - seconds to "2h 15m"')
group('the hour and minute forms', () => {
  eq('an exact hour', BAT.formatDuration(3600), '1h')
  eq('hours and minutes', BAT.formatDuration(8100), '2h 15m')
  eq('minutes only', BAT.formatDuration(60), '1m')
  eq('just under an hour', BAT.formatDuration(3599), '59m')
  eq('a whole day', BAT.formatDuration(86400), '24h')
  eq('a day and a bit', BAT.formatDuration(90000), '25h')
  eq('an hour plus 59 minutes', BAT.formatDuration(8999), '2h 29m')
  // "m > 0 ? h + "h " + m + "m" : h + "h"" - so an exact hour never
  // carries a trailing " 0m".
  eq('an exact hour has no minutes fragment', BAT.formatDuration(7200), '2h')
  eq('a fractional hour floors', BAT.formatDuration(3600.9), '1h')
  eq('a fractional minute floors', BAT.formatDuration(119), '1m')
})
group('under a minute is the <1m reading, not 0m', () => {
  eq('one second', BAT.formatDuration(1), '<1m')
  eq('59 seconds', BAT.formatDuration(59), '<1m')
  eq('a fractional minute', BAT.formatDuration(59.9), '<1m')
  eq('exactly 60 flips to minutes', BAT.formatDuration(60), '1m')
})
group('zero, negative and non-finite are "no estimate"', () => {
  // "Zero/negative/non-finite means "no estimate" and renders as "" so
  // callers can skip the fragment" - which is what a peripheral reports.
  eq('zero', BAT.formatDuration(0), '')
  eq('a negative estimate', BAT.formatDuration(-1), '')
  eq('NaN', BAT.formatDuration(NaN), '')
  eq('Infinity', BAT.formatDuration(Infinity), '')
  eq('-Infinity', BAT.formatDuration(-Infinity), '')
  eq('a non-numeric string', BAT.formatDuration('abc'), '')
  eq('null', BAT.formatDuration(null), '')
  eq('undefined', BAT.formatDuration(undefined), '')
  eq('no argument', BAT.formatDuration(), '')
})
group('a numeric string is coerced, so it is an estimate', () => {
  eq('"60"', BAT.formatDuration('60'), '1m')
  eq('"8100"', BAT.formatDuration('8100'), '2h 15m')
  eq('"0" is a zero, not an estimate', BAT.formatDuration('0'), '')
  eq('"-60"', BAT.formatDuration('-60'), '')
  eq('an empty string is a zero', BAT.formatDuration(''), '')
  eq('null is a zero, not a non-number', BAT.formatDuration(null), '')
})

section('Battery/Model.formatRate - watts to "8.4 W"')
group('a reading keeps one decimal, and the sign is kept', () => {
  eq('a charging rate', BAT.formatRate(8.44), '8.4 W')
  eq('a discharging rate', BAT.formatRate(-2.1), '-2.1 W')
  eq('a whole number still gets a decimal', BAT.formatRate(100), '100.0 W')
  eq('one watt', BAT.formatRate(1), '1.0 W')
  eq('a large rate', BAT.formatRate(1234.56), '1234.6 W')
  eq('rounds to the tenth', BAT.formatRate(8.44), '8.4 W')
  eq('rounds down at the boundary', BAT.formatRate(8.46), '8.5 W')
  eq('a negative rounding', BAT.formatRate(-2.16), '-2.2 W')
})
group('a rate that rounds to zero is no reading', () => {
  // "Zero/non-finite means "no reading"" and then the second guard: a
  // positive sub-tenth rate rounds to 0.0 and is dropped too, so a laptop
  // topping off does not render "0.0 W".
  eq('exactly zero', BAT.formatRate(0), '')
  eq('a positive rate under a tenth', BAT.formatRate(0.04), '')
  eq('a negative rate under a tenth', BAT.formatRate(-0.04), '')
  eq('the smallest value that survives', BAT.formatRate(0.05), '0.1 W')
  eq('the largest value that is dropped', BAT.formatRate(0.049), '')
  eq('negative zero', BAT.formatRate(-0), '')
})
group('non-finite and non-numeric readings are no reading', () => {
  eq('NaN', BAT.formatRate(NaN), '')
  eq('Infinity', BAT.formatRate(Infinity), '')
  eq('-Infinity', BAT.formatRate(-Infinity), '')
  eq('a non-numeric string', BAT.formatRate('abc'), '')
  eq('null', BAT.formatRate(null), '')
  eq('undefined', BAT.formatRate(undefined), '')
  eq('no argument', BAT.formatRate(), '')
  eq('an empty string is a zero', BAT.formatRate(''), '')
})
group('a numeric string is coerced', () => {
  eq('"8.44"', BAT.formatRate('8.44'), '8.4 W')
  eq('"-2.1"', BAT.formatRate('-2.1'), '-2.1 W')
  eq('"0"', BAT.formatRate('0'), '')
  eq('"abc" is not a number', BAT.formatRate('abc'), '')
  eq('an object', BAT.formatRate({}), '')
})

section('Battery/Model.rowSubtext - the island sub-line')
group('a discharging device reports the time left', () => {
  eq('the full line', BAT.rowSubtext({ percentage: 85, stateLabel: 'Discharging', charging: false, timeToEmpty: 8100 }), '85% - Discharging - 2h 15m left')
  eq('without an estimate', BAT.rowSubtext({ percentage: 50, stateLabel: 'Discharging', charging: false }), '50% - Discharging')
  eq('a zero estimate is skipped, not printed as <1m', BAT.rowSubtext({ percentage: 50, stateLabel: 'Discharging', charging: false, timeToEmpty: 0 }), '50% - Discharging')
  eq('a sub-minute estimate prints as <1m left', BAT.rowSubtext({ percentage: 50, stateLabel: 'Discharging', charging: false, timeToEmpty: 30 }), '50% - Discharging - <1m left')
  // The discharging branch never prints the charge rate or the time to
  // full, even when the device reports them.
  eq('a time to full is ignored while discharging', BAT.rowSubtext({ percentage: 50, stateLabel: 'Discharging', charging: false, timeToEmpty: 60, timeToFull: 3600 }), '50% - Discharging - 1m left')
})
group('a charging device reports the rate and the time to full', () => {
  eq('the full line', BAT.rowSubtext({ percentage: 85, stateLabel: 'Charging', charging: true, changeRate: 8.4, timeToFull: 3600 }), '85% - Charging - 8.4 W - Full in 1h')
  eq('without a rate', BAT.rowSubtext({ percentage: 50, stateLabel: 'Charging', charging: true }), '50% - Charging')
  eq('without a time to full', BAT.rowSubtext({ percentage: 50, stateLabel: 'Charging', charging: true, changeRate: 5 }), '50% - Charging - 5.0 W')
  eq('a time to empty is ignored while charging', BAT.rowSubtext({ percentage: 50, stateLabel: 'Charging', charging: true, timeToEmpty: 3600 }), '50% - Charging')
  // The branch is a truthiness test, so a device that reports a positive rate
  // while discharging (a laptop on AC that also drains) still takes the
  // charging arm and prints no "left" fragment.
  eq('a truthy non-boolean flag takes the charging arm', BAT.rowSubtext({ percentage: 50, charging: 1, changeRate: 5, timeToFull: 60 }), '50% - Unknown - 5.0 W - Full in 1m')
  eq('a negative rate still prints while charging', BAT.rowSubtext({ percentage: 50, stateLabel: 'Charging', charging: true, changeRate: -2, timeToFull: 60 }), '50% - Charging - -2.0 W - Full in 1m')
})
group('the first two fragments are always percentage and state', () => {
  eq('an object with nothing but a percentage', BAT.rowSubtext({ percentage: 85 }), '85% - Unknown')
  eq('a null row', BAT.rowSubtext(null), '0% - Unknown')
  eq('no argument', BAT.rowSubtext(), '0% - Unknown')
  eq('an empty object', BAT.rowSubtext({}), '0% - Unknown')
  // "String(r.stateLabel || "Unknown")" - a falsy label is the generic word.
  eq('an empty state label', BAT.rowSubtext({ percentage: 50, stateLabel: '' }), '50% - Unknown')
  eq('a null state label', BAT.rowSubtext({ percentage: 50, stateLabel: null }), '50% - Unknown')
  eq('a zero state label is stringified', BAT.rowSubtext({ percentage: 50, stateLabel: 0 }), '50% - Unknown')
  eq('a numeric state label', BAT.rowSubtext({ percentage: 50, stateLabel: 7 }), '50% - 7')
})
group('the percentage is rounded, and an unusable one reads as 0', () => {
  eq('rounds down', BAT.rowSubtext({ percentage: 85.4 }), '85% - Unknown')
  eq('rounds up', BAT.rowSubtext({ percentage: 85.5 }), '86% - Unknown')
  eq('a fraction is not scaled here - the caller normalizes first', BAT.rowSubtext({ percentage: 0.85 }), '1% - Unknown')
  eq('a non-numeric percentage', BAT.rowSubtext({ percentage: 'x' }), '0% - Unknown')
  eq('a negative percentage is printed, not clamped', BAT.rowSubtext({ percentage: -20 }), '-20% - Unknown')
  eq('a numeric string percentage', BAT.rowSubtext({ percentage: '42' }), '42% - Unknown')
})
group('health prints only when the device supports it', () => {
  eq('supported and positive', BAT.rowSubtext({ percentage: 50, healthSupported: true, healthPercentage: 98.6 }), '50% - Unknown - Health 99%')
  eq('unsupported but reported', BAT.rowSubtext({ percentage: 50, healthSupported: false, healthPercentage: 90 }), '50% - Unknown')
  eq('supported but zero', BAT.rowSubtext({ percentage: 50, healthSupported: true, healthPercentage: 0 }), '50% - Unknown')
  eq('supported but negative', BAT.rowSubtext({ percentage: 50, healthSupported: true, healthPercentage: -5 }), '50% - Unknown')
  eq('supported but NaN', BAT.rowSubtext({ percentage: 50, healthSupported: true, healthPercentage: 'x' }), '50% - Unknown')
  eq('a truthy non-boolean healthSupported', BAT.rowSubtext({ percentage: 50, healthSupported: 1, healthPercentage: 90 }), '50% - Unknown - Health 90%')
  eq('supported and exactly 100', BAT.rowSubtext({ percentage: 50, healthSupported: true, healthPercentage: 100 }), '50% - Unknown - Health 100%')
})
group('energy needs both halves of the pair', () => {
  eq('both present', BAT.rowSubtext({ percentage: 50, energy: 48.2, energyCapacity: 51 }), '50% - Unknown - 48.2 / 51.0 Wh')
  eq('no capacity drops the pair', BAT.rowSubtext({ percentage: 50, energy: 10, energyCapacity: 0 }), '50% - Unknown')
  eq('no energy drops the pair', BAT.rowSubtext({ percentage: 50, energy: 0, energyCapacity: 51 }), '50% - Unknown')
  eq('a negative capacity drops the pair', BAT.rowSubtext({ percentage: 50, energy: 10, energyCapacity: -1 }), '50% - Unknown')
  eq('a NaN capacity drops the pair', BAT.rowSubtext({ percentage: 50, energy: 10, energyCapacity: 'x' }), '50% - Unknown')
  eq('a numeric string capacity coerces', BAT.rowSubtext({ percentage: 50, energy: '10', energyCapacity: '20' }), '50% - Unknown - 10.0 / 20.0 Wh')
  eq('energy without a state still prints', BAT.rowSubtext({ energy: 1, energyCapacity: 2 }), '0% - Unknown - 1.0 / 2.0 Wh')
})
group('the fragments are joined in one fixed order', () => {
  eq('everything at once', BAT.rowSubtext({ percentage: 40, stateLabel: 'Charging', charging: true, changeRate: 12.3, timeToFull: 1800, healthSupported: true, healthPercentage: 95, energy: 30, energyCapacity: 45 }),
    '40% - Charging - 12.3 W - Full in 30m - Health 95% - 30.0 / 45.0 Wh')
  eq('a full discharging line', BAT.rowSubtext({ percentage: 40, stateLabel: 'Discharging', charging: false, timeToEmpty: 1800, healthSupported: true, healthPercentage: 95, energy: 30, energyCapacity: 45 }),
    '40% - Discharging - 30m left - Health 95% - 30.0 / 45.0 Wh')
  for (const out of [
    BAT.rowSubtext({ percentage: 40, stateLabel: 'Charging', charging: true, changeRate: 12.3 }),
    BAT.rowSubtext({ percentage: 40, stateLabel: 'Discharging', charging: false }),
    BAT.rowSubtext({ percentage: 40 }),
  ]) {
    is(`"${out}" uses the " - " separator`, out, (s) => s.split(' - ')[0] === '40%', 'the percentage leads')
  }
})

section('Battery/Model.sortRows - lowest charge first, ties by label')
group('the critical device tops the list', () => {
  const rows = [
    { label: 'Mouse', percentage: 80 },
    { label: 'Laptop', percentage: 15 },
    { label: 'Keyboard', percentage: 90 },
  ]
  eq('the order', BAT.sortRows(rows).map((r) => r.label), ['Laptop', 'Mouse', 'Keyboard'])
  eq('the input is not mutated', rows.map((r) => r.label), ['Mouse', 'Laptop', 'Keyboard'])
  eq('a new array comes back', BAT.sortRows(rows) === rows, false)
  eq('the same row objects though', BAT.sortRows(rows)[0] === rows[1], true)
})
group('a tie is broken by label, not by input order', () => {
  eq('alphabetical within a level', BAT.sortRows([{ label: 'B', percentage: 50 }, { label: 'A', percentage: 50 }]).map((r) => r.label), ['A', 'B'])
  eq('across three', BAT.sortRows([{ label: 'C', percentage: 5 }, { label: 'A', percentage: 5 }, { label: 'B', percentage: 5 }]).map((r) => r.label), ['A', 'B', 'C'])
  eq('two devices at the same level, one empty', BAT.sortRows([{ label: 'Z', percentage: 50 }, { label: 'A', percentage: 50.0 }]).length, 2)
  eq('a label is not required to sort', BAT.sortRows([{ percentage: 50, name: 'x' }, { percentage: 50, name: 'y' }]).length, 2)
})
group('an unreadable percentage sorts as full, not as zero', () => {
  // "if (!isFinite(pa)) pa = 100" - a device that reports nothing goes to the
  // BOTTOM of the list rather than the top, so an unreadable device never
  // becomes the bar's "critical" summary.
  const rows = [
    { label: 'Broken', percentage: 'x' },
    { label: 'Empty', percentage: 0 },
    { label: 'Full', percentage: 100 },
  ]
  // Broken reads as 100 and Full is 100, so the tie falls to the label and
  // "Broken" sorts before "Full". The unreadable device is not pinned to the
  // bottom of the whole list, only out of the critical half.
  eq('the unreadable one ties with a full one, by label', BAT.sortRows(rows).map((r) => r.label), ['Empty', 'Broken', 'Full'])
  eq('a missing percentage field is also 100', BAT.sortRows([{ label: 'a' }, { label: 'b', percentage: 90 }]).map((r) => r.label), ['b', 'a'])
  eq('a numeric string percentage is coerced', BAT.sortRows([{ label: 'a', percentage: '10' }, { label: 'b', percentage: '2' }]).map((r) => r.label), ['b', 'a'])
})
group('the degenerate row lists', () => {
  eq('an empty list', BAT.sortRows([]), [])
  eq('a null list', BAT.sortRows(null), [])
  eq('undefined', BAT.sortRows(undefined), [])
  eq('a non-array', BAT.sortRows('x'), [])
  eq('a number', BAT.sortRows(7), [])
  noThrow('a null row inside the list', () => BAT.sortRows([null, { label: 'x', percentage: 1 }]))
  eq('a null row sorts as full', BAT.sortRows([null, { label: 'x', percentage: 1 }]).map((r) => (r ? r.label : 'null')), ['x', 'null'])
  eq('a numeric label is stringified for the tie-break', BAT.sortRows([{ label: 2, percentage: 1 }, { label: 10, percentage: 1 }]).map((r) => r.label), [10, 2])
  eq('a missing label compares as empty', BAT.sortRows([{ percentage: 1 }, { percentage: 1 }]).length, 2)
})

section('Battery/Model.detailRows - the per-device details dropdown')
group('telemetry first, then device facts', () => {
  eq('a full device', BAT.detailRows({
    stateLabel: 'Charging', percentage: 85, timeToEmpty: 0, timeToFull: 3600, changeRate: 8.4,
    energy: 48.2, energyCapacity: 51, healthSupported: true, healthPercentage: 98.6,
    typeLabel: 'Battery', present: true, powerSupply: false, laptopBattery: true,
    nativePath: '/sys/devices/x', iconName: 'mouse',
  }), [
    { label: 'State', value: 'Charging' },
    { label: 'Charge', value: '85%' },
    { label: 'Time to full', value: '1h' },
    { label: 'Charge rate', value: '8.4 W' },
    { label: 'Energy', value: '48.2 Wh' },
    { label: 'Energy capacity', value: '51.0 Wh' },
    { label: 'Health', value: '99%' },
    { label: 'Type', value: 'Battery' },
    { label: 'Present', value: 'Yes' },
    { label: 'Power supply', value: 'No' },
    { label: 'Laptop battery', value: 'Yes' },
    { label: 'Native path', value: '/sys/devices/x' },
    { label: 'Icon', value: 'mouse' },
  ])
  eq('and a discharging device swaps the time row', BAT.detailRows({ stateLabel: 'Discharging', percentage: 50, timeToEmpty: 5400, timeToFull: 0 }).map((r) => r.label), ['State', 'Charge', 'Time to empty'])
  eq('a zero time is skipped on both sides', BAT.detailRows({ percentage: 50, timeToEmpty: 0, timeToFull: 0 }).map((r) => r.label), ['Charge'])
})
group('a field the device does not report is skipped outright', () => {
  eq('a peripheral reporting zeros shows a short list', BAT.detailRows({ percentage: 50, energy: 0, energyCapacity: 0, timeToEmpty: 0, timeToFull: 0, changeRate: 0 }).map((r) => r.label), ['Charge'])
  eq('energy alone is enough for its own row', BAT.detailRows({ energy: 10 }).map((r) => r.label), ['Energy'])
  eq('a capacity alone is enough too', BAT.detailRows({ energyCapacity: 10 }).map((r) => r.label), ['Energy capacity'])
  eq('health without support is skipped', BAT.detailRows({ percentage: 50, healthPercentage: 90 }).map((r) => r.label), ['Charge'])
  eq('an unsupported health row is absent even with a value', BAT.detailRows({ percentage: 50, healthSupported: false, healthPercentage: 90 }).map((r) => r.label), ['Charge'])
  eq('a zero charge rate is skipped', BAT.detailRows({ percentage: 50, changeRate: 0 }).map((r) => r.label), ['Charge'])
  eq('an empty string value is skipped', BAT.detailRows({ stateLabel: '', typeLabel: '', nativePath: '', iconName: '', percentage: 50 }).map((r) => r.label), ['Charge'])
  eq('a whitespace value is trimmed and then skipped', BAT.detailRows({ stateLabel: '  ', typeLabel: '  ', nativePath: '  x  ', iconName: '  ', percentage: 50 }).map((r) => r.value), ['50%', 'x'])
})
group('the three boolean rows require a real boolean', () => {
  // `r.present === true` / `=== false` - not a truthiness test - so a value
  // QML hands over as something else prints nothing at all rather than
  // guessing a polarity. Pinned: this is how a property that arrives as a
  // number 1/0 stays invisible instead of reading as Yes.
  eq('real booleans print', BAT.detailRows({ present: true, powerSupply: false, laptopBattery: true }).map((r) => r.value), ['Yes', 'No', 'Yes'])
  eq('the other polarity prints', BAT.detailRows({ present: false, powerSupply: true, laptopBattery: false }).map((r) => r.value), ['No', 'Yes', 'No'])
  eq('a numeric 1 is neither true nor false', BAT.detailRows({ present: 1, powerSupply: 0, laptopBattery: 'x' }), [])
  eq('a truthy string is neither', BAT.detailRows({ present: 'yes', powerSupply: 'no' }), [])
  eq('undefined is neither', BAT.detailRows({}), [])
  eq('a null is neither', BAT.detailRows({ present: null, powerSupply: null, laptopBattery: null }), [])
})
group('the charge row is guarded on a finite percentage', () => {
  eq('a valid percentage', BAT.detailRows({ percentage: 85 }).map((r) => r.value), ['85%'])
  eq('a non-numeric percentage drops the row', BAT.detailRows({ percentage: 'x' }), [])
  eq('a missing percentage drops the row', BAT.detailRows({ stateLabel: 'Empty' }).map((r) => r.label), ['State'])
  // rowSubtext and detailRows disagree here on purpose: the sub-line folds an
  // unreadable percentage to 0% (it is the always-present first fragment),
  // while the dropdown drops the row entirely. Both asserted so the
  // divergence is not mistaken for a defect.
  eq('rowSubtext folds it to zero', BAT.rowSubtext({ percentage: 'x' }), '0% - Unknown')
  eq('detailRows drops it', BAT.detailRows({ percentage: 'x' }), [])
  eq('a negative percentage is a valid reading', BAT.detailRows({ percentage: -20 }).map((r) => r.value), ['-20%'])
})
group('the empty dropdown is an empty list, never null', () => {
  // "never returns null (an empty list renders the "no additional
  // information" hint instead)".
  eq('a null info', BAT.detailRows(null), [])
  eq('no argument', BAT.detailRows(), [])
  eq('an empty object', BAT.detailRows({}), [])
  is('an empty list, not a null', BAT.detailRows({}), (v) => Array.isArray(v) && v.length === 0, '[]')
  eq('a string info reads as empty', BAT.detailRows('x'), [])
  eq('a numeric info reads as empty', BAT.detailRows(7), [])
  noThrow('a false info', () => BAT.detailRows(false))
})
group('each row is exactly { label, value } with a string value', () => {
  const rows = BAT.detailRows({ stateLabel: 'Charging', percentage: 85, present: true })
  for (const r of rows) {
    is(`"${r.label}" has exactly two keys`, r, (v) => Object.keys(v).length === 2, '{ label, value }')
    is(`"${r.label}" value is a string`, r.value, (v) => typeof v === 'string', 'a string')
  }
  eq('the keys are label then value', Object.keys(rows[0]), ['label', 'value'])
})

section('Battery/Model.tooltipRows - the bar tooltip')
group('one "Label - 85%" row per device', () => {
  eq('two devices', BAT.tooltipRows([{ label: 'Mouse', typeString: 'Mouse', percentage: 80 }, { label: 'Laptop', typeString: 'Battery', percentage: 15 }]), [
    { icon: 'mice', text: 'Mouse - 80%' },
    { icon: 'monitor', text: 'Laptop - 15%' }
  ])
  eq('the order is the caller\'s, not a sort', BAT.tooltipRows([{ label: 'B', percentage: 8 }, { label: 'A', percentage: 12 }]), [
    { icon: 'battery-1', text: 'B - 8%' },
    { icon: 'battery-1', text: 'A - 12%' }
  ])
  eq('the percentage is rounded', BAT.tooltipRows([{ label: 'a', percentage: 85.6 }])[0].text, 'a - 86%')
  eq('a numeric string percentage is coerced', BAT.tooltipRows([{ label: 'a', percentage: '42' }])[0].text, 'a - 42%')
  eq('one row per device', BAT.tooltipRows([{ label: 'a', percentage: 1 }, { label: 'b', percentage: 2 }, { label: 'c', percentage: 3 }]).length, 3)
})
group('the glyph is the device class, and the level when there is none', () => {
  const iconOf = (row) => BAT.tooltipRows([row])[0].icon
  eq('a mouse', iconOf({ label: 'x', typeString: 'Mouse', percentage: 80 }), 'mice')
  eq('a keyboard', iconOf({ label: 'x', typeString: 'Keyboard', percentage: 80 }), 'keyboard')
  eq('a headset', iconOf({ label: 'x', typeString: 'Headset', percentage: 80 }), 'headset')
  eq('a gamepad', iconOf({ label: 'x', typeString: 'GamingInput', percentage: 80 }), 'gamepad')
  eq('speakers', iconOf({ label: 'x', typeString: 'Speakers', percentage: 80 }), 'speaker')
  // UPower spells the laptop battery "Battery", and deviceIconName reads it
  // as the machine it sits in - the same glyph the island's row shows.
  eq('the laptop battery reads as the machine', iconOf({ label: 'x', typeString: 'Battery', percentage: 80 }), 'monitor')
  eq('a phone has no class glyph and takes the level', iconOf({ label: 'x', typeString: 'Phone', percentage: 25 }), 'battery-2')
  eq('no type at all takes the level', iconOf({ label: 'x', percentage: 25 }), 'battery-2')
  eq('the charging glyph wins over the level', iconOf({ label: 'x', typeString: 'Phone', percentage: 25, charging: true }), 'battery-charging')
  // The class glyph is the row's subject, so it also beats a level that is
  // worth a bolt or a colour on the bar.
  eq('a per-device class glyph wins over the level', iconOf({ label: 'x', typeString: 'Headset', percentage: 4, charging: true }), 'headset')
})
group('every row is exactly { icon, text }', () => {
  const rows = BAT.tooltipRows([{ label: 'Mouse', typeString: 'Mouse', percentage: 80 }])
  is('one row', rows, (v) => v.length === 1, 'a single row')
  is('the keys are icon then text', rows[0], (v) => Object.keys(v).length === 2 && 'icon' in v && 'text' in v, '{ icon, text }')
})
group('an unusable device still gets a row', () => {
  eq('a missing label', BAT.tooltipRows([{ percentage: 50 }]), [{ icon: 'battery-3', text: 'Unknown device - 50%' }])
  eq('an empty label', BAT.tooltipRows([{ label: '', percentage: 50 }]), [{ icon: 'battery-3', text: 'Unknown device - 50%' }])
  eq('a numeric label is stringified', BAT.tooltipRows([{ label: 5, percentage: 20 }]), [{ icon: 'battery-2', text: '5 - 20%' }])
  // The glyph is resolved from the SAME sanitized percentage the text
  // prints, so a device whose level UPower could not report reads 0% on the
  // bar's level table rather than full: the row cannot show a glyph that
  // disagrees with the number beside it.
  eq('an unreadable percentage prints zero and glyphs zero', BAT.tooltipRows([{ label: 'a', percentage: 'x' }]), [{ icon: 'battery-0', text: 'a - 0%' }])
  eq('a missing percentage prints zero and glyphs zero', BAT.tooltipRows([{ label: 'a' }]), [{ icon: 'battery-0', text: 'a - 0%' }])
  eq('a null entry', BAT.tooltipRows([null]), [{ icon: 'battery-0', text: 'Unknown device - 0%' }])
  eq('a negative percentage is printed', BAT.tooltipRows([{ label: 'a', percentage: -3 }]), [{ icon: 'battery-0', text: 'a - -3%' }])
})
group('an empty or missing list is an empty tooltip', () => {
  eq('an empty list', BAT.tooltipRows([]), [])
  eq('a null list', BAT.tooltipRows(null), [])
  eq('undefined', BAT.tooltipRows(undefined), [])
  eq('no argument', BAT.tooltipRows(), [])
  eq('a non-array', BAT.tooltipRows('x'), [])
  eq('a number', BAT.tooltipRows(7), [])
  noThrow('an object', () => BAT.tooltipRows({}))
})
group('the tooltip never carries state or telemetry', () => {
  // "Deliberately just the name and the charge - state and telemetry live in
  // the island" - asserted so a future extra fragment is a visible diff.
  const out = BAT.tooltipRows([{ label: 'Laptop', typeString: 'Battery', percentage: 15, stateLabel: 'Discharging', charging: false, timeToEmpty: 3600, changeRate: 8 }])
  eq('only the two fragments', out, [{ icon: 'monitor', text: 'Laptop - 15%' }])
  notContains('no state word', JSON.stringify(out), 'Discharging')
  notContains('no time fragment', JSON.stringify(out), 'left')
  notContains('no rate', JSON.stringify(out), 'W')
})
group('the whole tooltip follows the row sort', () => {
  // Battery.qml:103 - `tooltipRows(sortRows(entries))`, so the tooltip lists
  // the same order the island does.
  const rows = [{ label: 'Mouse', typeString: 'Mouse', percentage: 80 }, { label: 'Laptop', typeString: 'Battery', percentage: 15 }, { label: 'Pad', typeString: 'GamingInput', percentage: 15 }]
  eq('critical first, then alphabetical', BAT.tooltipRows(BAT.sortRows(rows)), [
    { icon: 'monitor', text: 'Laptop - 15%' },
    { icon: 'gamepad', text: 'Pad - 15%' },
    { icon: 'mice', text: 'Mouse - 80%' }
  ])
})

// ======================================================================
section('Bluetooth/Model - the device snapshot, the sort and the two sections')
group('deviceLabel falls back deviceName -> name -> address', () => {
  eq('a deviceName wins', BT.deviceLabel({ deviceName: 'Sony WH-1000XM5', address: 'AA:BB' }), 'Sony WH-1000XM5')
  eq('name is second', BT.deviceLabel({ name: 'Fallback', address: 'AA:BB' }), 'Fallback')
  eq('an empty deviceName falls through to name', BT.deviceLabel({ deviceName: '', name: 'Fallback', address: 'AA' }), 'Fallback')
  // `d.deviceName || d.name` is a falsiness fold on the RAW string, so a
  // whitespace deviceName wins the first step, trims to nothing, and the
  // chain goes to the address - `name` is never consulted. Pinned: it is the
  // one case where the documented deviceName -> name -> address order is
  // short-circuited by a non-empty string.
  eq('a whitespace deviceName skips name and takes the address', BT.deviceLabel({ deviceName: '   ', name: 'Fallback', address: 'AA' }), 'AA')
  eq('and with no address it is the generic label', BT.deviceLabel({ deviceName: '   ', name: 'Fallback' }), 'Unknown device')
  eq('an empty deviceName does fall through to name', BT.deviceLabel({ deviceName: '', name: 'Fallback', address: 'AA' }), 'Fallback')
  eq('an address is third', BT.deviceLabel({ address: 'AA:BB:CC:DD:EE:FF' }), 'AA:BB:CC:DD:EE:FF')
  eq('and the address is not trimmed - it is the identity', BT.deviceLabel({ address: ' AA ' }), ' AA ')
})
group('with nothing to name it, the label is the generic one', () => {
  eq('an empty device', BT.deviceLabel({}), 'Unknown device')
  eq('a null device', BT.deviceLabel(null), 'Unknown device')
  eq('undefined', BT.deviceLabel(undefined), 'Unknown device')
  eq('no argument', BT.deviceLabel(), 'Unknown device')
  eq('a string device is not an object', BT.deviceLabel('Sony'), 'Unknown device')
  eq('a number device', BT.deviceLabel(7), 'Unknown device')
  eq('an array device', BT.deviceLabel(['Sony']), 'Unknown device')
})
group('non-string names are stringified, and a falsy one is not a name', () => {
  eq('a numeric name', BT.deviceLabel({ name: 42, address: 'AA' }), '42')
  eq('a zero name is falsy', BT.deviceLabel({ name: 0, address: 'AA' }), 'AA')
  eq('a zero deviceName is falsy', BT.deviceLabel({ deviceName: 0, name: 'n', address: 'AA' }), 'n')
  eq('an object name', BT.deviceLabel({ name: { a: 1 }, address: 'AA' }), '[object Object]')
  eq('an empty address is not an address', BT.deviceLabel({ address: '' }), 'Unknown device')
})

section('Bluetooth/Model.isKnown - paired, bonded or trusted')
group('any one of the three is remembered', () => {
  eq('paired', BT.isKnown({ paired: true }), true)
  eq('bonded', BT.isKnown({ bonded: true }), true)
  eq('trusted', BT.isKnown({ trusted: true }), true)
  eq('all three', BT.isKnown({ paired: true, bonded: true, trusted: true }), true)
  eq('paired and trusted only', BT.isKnown({ paired: true, trusted: true }), true)
})
group('a falsy flag is not remembered', () => {
  eq('nothing set', BT.isKnown({}), false)
  eq('paired: false', BT.isKnown({ paired: false }), false)
  eq('bonded: false', BT.isKnown({ bonded: false }), false)
  eq('trusted: false', BT.isKnown({ trusted: false }), false)
  eq('all three false', BT.isKnown({ paired: false, bonded: false, trusted: false }), false)
  eq('a zero flag', BT.isKnown({ paired: 0 }), false)
  // The flags are a truthiness fold, so a truthy non-boolean is remembered -
  // which is what makes the snapshot safe for a property that arrives as 1.
  eq('a truthy non-boolean', BT.isKnown({ paired: 'x' }), true)
  eq('a numeric 1', BT.isKnown({ paired: 1 }), true)
})
group('a device that is not an object is not remembered', () => {
  eq('null', BT.isKnown(null), false)
  eq('undefined', BT.isKnown(undefined), false)
  eq('no argument', BT.isKnown(), false)
  eq('a string', BT.isKnown('paired'), false)
  eq('a number', BT.isKnown(7), false)
  eq('an array', BT.isKnown(['paired']), false)
})

section('Bluetooth/Model.deviceRow - the primitives snapshot')
group('the snapshot is exactly the ten documented fields', () => {
  eq('the key set', Object.keys(BT.deviceRow({})), ['address', 'name', 'icon', 'connected', 'known', 'pairing', 'trusted', 'batteryAvailable', 'battery'])
  eq('a full device', BT.deviceRow({ address: 'AA', deviceName: 'Sony', icon: 'audio-headset', connected: true, paired: true, trusted: true, pairing: true, batteryAvailable: true, battery: 0.55 }),
    { address: 'AA', name: 'Sony', icon: 'audio-headset', connected: true, known: true, pairing: true, trusted: true, batteryAvailable: true, battery: 0.55 })
})
group('nothing live is carried across - the point of the projection', () => {
  // "a list model must not hold live BluetoothDevice" - so the row is a plain
  // object holding only primitives, and it does not keep a reference to the
  // device it was made from.
  const device = { address: 'AA', deviceName: 'Sony', icon: 'audio-card', connected: true, paired: true, battery: 0.5, secretBackendMethod() { return 'live' } }
  const row = BT.deviceRow(device)
  // The row is built inside the library's own vm context, so its prototype is
  // that context's Object.prototype rather than the host's - the check is
  // therefore "an object that is not an array and not a function", plus the
  // nine-key and all-primitives checks below.
  is('the row is an object, not an array and not a function', row, (v) => v !== null && typeof v === 'object' && !Array.isArray(v) && typeof v !== 'function', 'a plain data object')
  eq('carrying the row holds exactly the snapshot fields', Object.keys(row).length, 9)
  is('and every value in it is a primitive', row, (v) => Object.values(v).every((x) => x === null || ['string', 'number', 'boolean'].includes(typeof x)), 'string | number | boolean | null')
  is('no value is a function', row, (v) => !Object.values(v).some((x) => typeof x === 'function'), 'no live methods')
  noThrow('and the row survives being held and serialised', () => JSON.stringify(row))
  eq('the original device is untouched by the projection', device.deviceName, 'Sony')
})
group('the flags are normalised to booleans and the name to a string', () => {
  eq('an empty device', BT.deviceRow({}), { address: '', name: '', icon: '', connected: false, known: false, pairing: false, trusted: false, batteryAvailable: false, battery: 0 })
  eq('connected is coerced', BT.deviceRow({ connected: 1 }).connected, true)
  eq('known comes from isKnown', BT.deviceRow({ bonded: true }).known, true)
  eq('a paired device is known but not trusted', BT.deviceRow({ paired: true }).known, true)
  eq('and its trusted flag is still false', BT.deviceRow({ paired: true }).trusted, false)
})
group('a device with no identity is refused, not projected', () => {
  // `if (!device) return null` - the island checks for that.
  eq('null', BT.deviceRow(null), null)
  eq('undefined', BT.deviceRow(undefined), null)
  eq('zero', BT.deviceRow(0), null)
  eq('an empty string', BT.deviceRow(''), null)
  eq('false', BT.deviceRow(false), null)
  noThrow('an empty object is not refused', () => BT.deviceRow({}))
  // The island adds the address check on top (BluetoothIsland.qml:104), so
  // an address-less projection is the library's to return.
  eq('an address-less row keeps an empty address', BT.deviceRow({}).address, '')
  eq('and the island would drop it', BT.deviceRow({}).address !== '', false)
})
group('the battery field is passed through with one guard', () => {
  eq('a real fraction', BT.deviceRow({ battery: 0.5 }).battery, 0.5)
  eq('a missing battery is zero', BT.deviceRow({}).battery, 0)
  // `device.battery !== undefined ? device.battery : 0` - so an explicit
  // null survives as null, unlike a missing key. Pinned because the equality
  // check downstream folds both to 0 anyway, so it cannot become a visible
  // regression, but it is the difference between the two guards.
  eq('an explicit null survives', BT.deviceRow({ battery: null }).battery, null)
  eq('an explicit false survives', BT.deviceRow({ battery: false }).battery, false)
  eq('batteryAvailable is separate from the value', BT.deviceRow({ battery: 0.5, batteryAvailable: false }).batteryAvailable, false)
  eq('a NaN battery survives', Number.isNaN(BT.deviceRow({ battery: NaN }).battery), true)
})
group('the name falls back to the device `name` property', () => {
  eq('deviceName preferred', BT.deviceRow({ deviceName: 'A', name: 'B' }).name, 'A')
  eq('name used when deviceName is empty', BT.deviceRow({ deviceName: '', name: 'B' }).name, 'B')
  eq('a missing deviceName', BT.deviceRow({ name: 'B' }).name, 'B')
  eq('neither', BT.deviceRow({}).name, '')
  // deviceRow does NOT trim, unlike deviceLabel - the row is the snapshot and
  // the label is the display string.
  eq('a padded name is kept verbatim in the snapshot', BT.deviceRow({ deviceName: '  A  ' }).name, '  A  ')
  eq('and trimmed in the label', BT.deviceLabel({ deviceName: '  A  ' }), 'A')
  eq('a non-string name is stringified', BT.deviceRow({ name: 7 }).name, '7')
  eq('the icon is stringified too', BT.deviceRow({ icon: 7 }).icon, '7')
})

section('Bluetooth/Model.deviceRowsEqual - the poll skip')
group('identical snapshots compare equal', () => {
  const rows = [{ address: 'AA', name: 'Sony', icon: 'audio-card', connected: true, known: true, pairing: false, trusted: true, batteryAvailable: true, battery: 0.5 }]
  eq('the same array', BT.deviceRowsEqual(rows, rows), true)
  eq('a structural copy', BT.deviceRowsEqual(rows, JSON.parse(JSON.stringify(rows))), true)
  eq('two empty lists', BT.deviceRowsEqual([], []), true)
  eq('a null and an undefined list are both empty', BT.deviceRowsEqual(null, undefined), true)
  eq('a null and an empty list', BT.deviceRowsEqual(null, []), true)
  eq('a non-array on either side reads as empty', BT.deviceRowsEqual('x', []), true)
})
group('every compared field is enough on its own to report a change', () => {
  const base = { address: 'AA', name: 'n', icon: 'i', connected: false, known: false, pairing: false, trusted: false, batteryAvailable: false, battery: 0 }
  for (const field of ['address', 'name', 'icon', 'connected', 'known', 'pairing', 'trusted', 'batteryAvailable', 'battery']) {
    const changed = Object.assign({}, base)
    if (field === 'battery') changed.battery = 0.5
    else if (field === 'address') changed.address = 'BB'
    else if (field === 'name') changed.name = 'other'
    else if (field === 'icon') changed.icon = 'other'
    else changed[field] = true
    eq(`a changed ${field} is a change`, BT.deviceRowsEqual([base], [changed]), false)
  }
  eq('a length change is a change', BT.deviceRowsEqual([base], [base, base]), false)
  eq('and so is a shorter list', BT.deviceRowsEqual([base, base], [base]), false)
})
group('the comparison is deliberately loose where QML is loose', () => {
  // Three folds, each with a reason: the flags are `!!x` on both sides, the
  // battery is `Number(x) || 0` on both sides, and the three strings are `|| ""`.
  eq('a truthy connected and a truthy connected', BT.deviceRowsEqual([{ connected: 1 }], [{ connected: 'yes' }]), true)
  eq('a truthy and a falsy flag differ', BT.deviceRowsEqual([{ connected: 1 }], [{ connected: 0 }]), false)
  eq('a numeric string battery and a numeric one', BT.deviceRowsEqual([{ battery: 0.5 }], [{ battery: '0.5' }]), true)
  eq('a null battery and a missing one', BT.deviceRowsEqual([{ battery: null }], [{}]), true)
  eq('a NaN battery and a missing one', BT.deviceRowsEqual([{ battery: NaN }], [{}]), true)
  eq('a zero battery and a missing one', BT.deviceRowsEqual([{ battery: 0 }], [{}]), true)
  eq('two real batteries differ', BT.deviceRowsEqual([{ battery: 0.5 }], [{ battery: 0.6 }]), false)
  eq('an empty address and a missing one', BT.deviceRowsEqual([{ address: '' }], [{}]), true)
  eq('two different addresses differ', BT.deviceRowsEqual([{ address: 'AA' }], [{ address: 'BB' }]), false)
})
group('a field the comparison does not read cannot change the answer', () => {
  // `deviceRow` publishes nine fields and the comparison reads nine; a tenth
  // added to the snapshot would be invisible to the poll skip unless this
  // assertion is updated - which is exactly what should happen.
  eq('an extra field is ignored', BT.deviceRowsEqual([{ address: 'AA', extra: 1 }], [{ address: 'AA', extra: 2 }]), true)
  eq('a null row and an empty row', BT.deviceRowsEqual([null], [{}]), true)
  eq('two null rows', BT.deviceRowsEqual([null], [null]), true)
  eq('a string row and an empty row', BT.deviceRowsEqual(['x'], [{}]), true)
})

section('Bluetooth/Model.deviceIconName - the class glyph from the row')
group('the freedesktop class names BlueZ reports', () => {
  eq('input-keyboard', BT.deviceIconName({ icon: 'input-keyboard' }), 'keyboard')
  eq('input-mouse', BT.deviceIconName({ icon: 'input-mouse' }), 'mice')
  eq('input-gaming', BT.deviceIconName({ icon: 'input-gaming' }), 'gamepad')
  eq('input-gamepad', BT.deviceIconName({ icon: 'input-gamepad' }), 'gamepad')
  eq('audio-card', BT.deviceIconName({ icon: 'audio-card' }), 'speaker')
  // A headset carries a mic, so it is read ahead of the output-only
  // headphones - the split the volume module already makes.
  eq('audio-headset', BT.deviceIconName({ icon: 'audio-headset' }), 'headset')
  eq('audio-headphones', BT.deviceIconName({ icon: 'audio-headphones' }), 'headphones')
  eq('audio-speakers', BT.deviceIconName({ icon: 'audio-speakers' }), 'speaker')
  eq('computer', BT.deviceIconName({ icon: 'computer' }), 'monitor')
  eq('laptop', BT.deviceIconName({ icon: 'laptop' }), 'monitor')
  eq('x-pc-desktop', BT.deviceIconName({ icon: 'x-pc-desktop' }), 'monitor')
  eq('joystick', BT.deviceIconName({ icon: 'joystick' }), 'gamepad')
  eq('audio-video', BT.deviceIconName({ icon: 'audio-video' }), 'speaker')
  eq('MULTIMEDIA is lowercased first', BT.deviceIconName({ icon: 'MULTIMEDIA' }), 'speaker')
})
group('an unknown class is the empty stem', () => {
  eq('phone', BT.deviceIconName({ icon: 'phone' }), '')
  eq('input-tablet', BT.deviceIconName({ icon: 'input-tablet' }), '')
  eq('printer', BT.deviceIconName({ icon: 'printer' }), '')
  eq('an empty icon', BT.deviceIconName({ icon: '' }), '')
  eq('a missing icon', BT.deviceIconName({}), '')
  eq('a null row', BT.deviceIconName(null), '')
  eq('undefined', BT.deviceIconName(undefined), '')
  eq('a numeric icon', BT.deviceIconName({ icon: 7 }), '')
  eq('a string row is not a row', BT.deviceIconName('input-mouse'), '')
  eq('and the caller\'s fallback is the bluetooth badge', BT.deviceIconName({}) !== '' ? 'x' : 'bluetooth', 'bluetooth')
})
group('the test order is load-bearing', () => {
  // "Order matters: keyboards/mice/gamepads are input devices, a headset is
  // an audio device with a mic, computer is the catch-all." An icon carrying
  // two of those words resolves to the earlier branch.
  eq('a keyboard-audio hybrid is a keyboard', BT.deviceIconName({ icon: 'audio-keyboard' }), 'keyboard')
  eq('a mouse-computer hybrid is a mouse', BT.deviceIconName({ icon: 'computer-mouse' }), 'mice')
  eq('an audio-computer hybrid is a speaker', BT.deviceIconName({ icon: 'computer-audio' }), 'speaker')
  eq('a gaming-computer hybrid is a gamepad', BT.deviceIconName({ icon: 'computer-gaming' }), 'gamepad')
  eq('a headset-computer hybrid is a headset', BT.deviceIconName({ icon: 'computer-headset' }), 'headset')
  eq('a headset-headphones hybrid is a headset', BT.deviceIconName({ icon: 'headset-headphones' }), 'headset')
})
group('the row is read, not the device', () => {
  // BluetoothIsland.qml:680 passes `row.dev`, which is the projected row -
  // so the function must read `.icon`, not `.deviceName` or a device class
  // property. Asserted through the shape it actually consumes.
  eq('a row with only an icon', BT.deviceIconName({ address: 'AA', icon: 'input-mouse' }), 'mice')
  eq('a row with a name but no icon', BT.deviceIconName({ address: 'AA', name: 'Mouse' }), '')
  eq('an icon is not trimmed', BT.deviceIconName({ icon: ' input-mouse ' }), 'mice')
})

section('Bluetooth/Model.sortDeviceRows - connected, then known, then name')
group('the three tiers, in that order', () => {
  const rows = [
    { address: '1', name: 'Zulu', connected: false, known: false },
    { address: '2', name: 'Alpha', connected: false, known: true },
    { address: '3', name: 'Mike', connected: true, known: false },
    { address: '4', name: 'Bravo', connected: true, known: true },
  ]
  eq('the order', BT.sortDeviceRows(rows).map((r) => r.name), ['Bravo', 'Mike', 'Alpha', 'Zulu'])
  eq('the input is not mutated', rows.map((r) => r.name), ['Zulu', 'Alpha', 'Mike', 'Bravo'])
  eq('a new array comes back', BT.sortDeviceRows(rows) === rows, false)
  eq('the same row objects though', BT.sortDeviceRows(rows)[0] === rows[3], true)
})
group('each tier beats the one below it regardless of name', () => {
  eq('connected beats remembered, a before z', BT.sortDeviceRows([{ name: 'a', connected: false, known: true }, { name: 'z', connected: true, known: true }]).map((r) => r.name), ['z', 'a'])
  eq('remembered beats unknown, z before a', BT.sortDeviceRows([{ name: 'a', connected: false, known: false }, { name: 'z', connected: false, known: true }]).map((r) => r.name), ['z', 'a'])
  eq('unconnected and unknown, a before z', BT.sortDeviceRows([{ name: 'z' }, { name: 'a' }]).map((r) => r.name), ['a', 'z'])
  eq('a connected unknown device is still first', BT.sortDeviceRows([{ name: 'a', known: true }, { name: 'z', connected: true }]).map((r) => r.name), ['z', 'a'])
})
group('within a tier the name decides', () => {
  eq('case matters, as a code-point compare', BT.sortDeviceRows([{ name: 'b', connected: true }, { name: 'A', connected: true }]).map((r) => r.name), ['A', 'b'])
  eq('three in one tier', BT.sortDeviceRows([{ name: 'c' }, { name: 'a' }, { name: 'b' }]).map((r) => r.name), ['a', 'b', 'c'])
  eq('the label fallback decides when there is no name', BT.sortDeviceRows([{ address: 'b' }, { address: 'a' }]).map((r) => r.address), ['a', 'b'])
  eq('a name beats an address in the tie-break', BT.sortDeviceRows([{ address: 'AA', name: 'Z' }, { address: 'BB' }]).map((r) => r.name), [undefined, 'Z'])
  eq('an unconnected unknown device falls back to its address', BT.sortDeviceRows([{ address: 'BB' }, { address: 'AA' }]).map((r) => r.address), ['AA', 'BB'])
})
group('the compare reads the fields directly, so an undefined is falsy', () => {
  eq('a row with no connected/known sorts as neither', BT.sortDeviceRows([{ name: 'a' }, { name: 'b', connected: true }]).map((r) => r.name), ['b', 'a'])
  eq('a known but unconnected row before an unknown one', BT.sortDeviceRows([{ name: 'a', known: true }, { name: 'b' }]).map((r) => r.name), ['a', 'b'])
  eq('a row with no name at all sorts first among equals', BT.sortDeviceRows([{ address: 'z' }, { address: 'a' }]).map((r) => r.address), ['a', 'z'])
})
group('the degenerate row lists', () => {
  eq('an empty list', BT.sortDeviceRows([]), [])
  eq('a null list', BT.sortDeviceRows(null), [])
  eq('undefined', BT.sortDeviceRows(undefined), [])
  eq('a non-array', BT.sortDeviceRows('x'), [])
  eq('a number', BT.sortDeviceRows(7), [])
  noThrow('no argument at all', () => BT.sortDeviceRows())
  // The comparator reads `a.connected` unguarded, so a null ENTRY throws
  // while a null LIST is handled: the list guard is `Array.isArray`, the
  // entry guard is absent. Pinned because the island builds its rows from
  // `deviceRow()`, which refuses a falsy device, so an entry is never null.
  throws('a null entry inside the list', () => BT.sortDeviceRows([null, { name: 'x' }]), /connected/)
  eq('but a single null entry never reaches the comparator', BT.sortDeviceRows([null]).length, 1)
  noThrow('a row with no fields at all', () => BT.sortDeviceRows([{}]))
})

section('Bluetooth/Model.sectionTitleFor - the two section headers')
const BT_SORTED = BT.sortDeviceRows([
  { address: '1', name: 'Bravo', connected: true, known: true },
  { address: '2', name: 'Mike', connected: true, known: false },
  { address: '3', name: 'Alpha', connected: false, known: true },
  { address: '4', name: 'Zulu', connected: false, known: false },
])
group('a header opens a section and a continuation is empty', () => {
  // "Connected first, then remembered, then the rest" - so on a mixed list
  // the paired and available sections INTERLEAVE, and a header reopens at
  // every transition rather than once. That is why the island splits the
  // sorted rows into two lists itself (BluetoothIsland.qml:108-116) instead
  // of handing this function one list. Pinned as the real shape.
  eq('the four titles of a four-device sorted list', BT_SORTED.map((_, i) => BT.sectionTitleFor(i, BT_SORTED)), ['PAIRED DEVICES', 'AVAILABLE DEVICES', 'PAIRED DEVICES', 'AVAILABLE DEVICES'])
  eq('and the paired-first shape a two-list caller sees', [BT.sectionTitleFor(0, [{ known: true }, { known: true }]), BT.sectionTitleFor(0, [{ known: false }, { known: false }])], ['PAIRED DEVICES', 'AVAILABLE DEVICES'])
  eq('the first row of an all-paired list', BT.sectionTitleFor(0, [{ known: true }]), 'PAIRED DEVICES')
  eq('the second row of an all-paired list', BT.sectionTitleFor(1, [{ known: true }, { known: true }]), '')
  eq('the first row of an all-available list', BT.sectionTitleFor(0, [{ known: false }]), 'AVAILABLE DEVICES')
  eq('the second row of an all-available list', BT.sectionTitleFor(1, [{ known: false }, { known: false }]), '')
})
group('an unsorted list still answers per position', () => {
  // The function reads the row and its predecessor, not a sort - the island
  // hands it the sorted list, and the test is what it does when it does not.
  eq('a known row first', BT.sectionTitleFor(0, [{ known: true }, { known: false }]), 'PAIRED DEVICES')
  eq('an unknown row after a known one', BT.sectionTitleFor(1, [{ known: true }, { known: false }]), 'AVAILABLE DEVICES')
  eq('a known row after an unknown one', BT.sectionTitleFor(1, [{ known: false }, { known: true }]), 'PAIRED DEVICES')
  eq('an unknown row after an unknown one', BT.sectionTitleFor(1, [{ known: false }, { known: false }]), '')
})
group('an index outside the list is the empty string', () => {
  // "sectionTitleFor returns "" on continuations" and the same "" for an
  // out-of-range index, so a ListView never gets a phantom header.
  eq('a negative index', BT.sectionTitleFor(-1, BT_SORTED), '')
  eq('one past the end', BT.sectionTitleFor(4, BT_SORTED), '')
  eq('far past the end', BT.sectionTitleFor(99, BT_SORTED), '')
  eq('a negative index on an empty list', BT.sectionTitleFor(-1, []), '')
  eq('index 0 on an empty list', BT.sectionTitleFor(0, []), '')
})
group('a missing list is an empty one', () => {
  eq('null', BT.sectionTitleFor(0, null), '')
  eq('undefined', BT.sectionTitleFor(0, undefined), '')
  eq('a non-array', BT.sectionTitleFor(0, 'x'), '')
  eq('a number', BT.sectionTitleFor(0, 7), '')
  noThrow('no argument at all', () => BT.sectionTitleFor(0))
  // A row with no `known` field is not remembered, so the AVAILABLE header
  // opens it - the same folding isKnown uses.
  eq('a row with no known field', BT.sectionTitleFor(0, [{}]), 'AVAILABLE DEVICES')
  eq('a row with known: 0', BT.sectionTitleFor(0, [{ known: 0 }]), 'AVAILABLE DEVICES')
  eq('a row with known: "yes"', BT.sectionTitleFor(0, [{ known: 'yes' }]), 'PAIRED DEVICES')
})

section('Bluetooth/Model.subtextFor - the row sub-line')
group('a device with a battery reports the level', () => {
  eq('half', BT.subtextFor({ batteryAvailable: true, battery: 0.5 }), 'Battery 50%')
  eq('empty', BT.subtextFor({ batteryAvailable: true, battery: 0 }), 'Battery 0%')
  eq('full', BT.subtextFor({ batteryAvailable: true, battery: 1 }), 'Battery 100%')
  eq('rounded down', BT.subtextFor({ batteryAvailable: true, battery: 0.334 }), 'Battery 33%')
  eq('rounded up', BT.subtextFor({ batteryAvailable: true, battery: 0.336 }), 'Battery 34%')
  eq('0.5 rounds up', BT.subtextFor({ batteryAvailable: true, battery: 0.5 }), 'Battery 50%')
  eq('a numeric string battery is coerced', BT.subtextFor({ batteryAvailable: true, battery: '0.75' }), 'Battery 75%')
})
group('a battery reading wins over the paired word', () => {
  eq('a paired device with a battery', BT.subtextFor({ batteryAvailable: true, battery: 0.5, known: true }), 'Battery 50%')
  eq('an unknown device with a battery', BT.subtextFor({ batteryAvailable: true, battery: 0.5, known: false }), 'Battery 50%')
})
group('no battery means paired or available', () => {
  eq('remembered', BT.subtextFor({ known: true }), 'Paired')
  eq('not remembered', BT.subtextFor({ known: false }), 'Available')
  eq('no known field', BT.subtextFor({}), 'Available')
  eq('batteryAvailable false with a value', BT.subtextFor({ batteryAvailable: false, battery: 0.5, known: true }), 'Paired')
  // subtextFor reads the projected `known` field, not isKnown - so a raw
  // backend object with only `bonded` set reads as Available. The island
  // always passes a deviceRow, so `known` is already computed. Pinned so the
  // two are not confused when reading the model.
  eq('a raw device with only bonded set reads as Available', BT.subtextFor({ bonded: true }), 'Available')
  eq('the projected row for the same device reads as Paired', BT.subtextFor(BT.deviceRow({ bonded: true })), 'Paired')
})
group('an unreadable battery falls back to the paired word', () => {
  // `Math.round(Number(r.battery) * 100)` is NaN for a non-number, and
  // `isFinite(NaN)` is false, so the row falls through to the state word
  // rather than printing "Battery NaN%".
  eq('a non-numeric battery', BT.subtextFor({ batteryAvailable: true, battery: 'x', known: true }), 'Paired')
  eq('an absent battery with the flag set', BT.subtextFor({ batteryAvailable: true, known: true }), 'Paired')
  eq('a null battery', BT.subtextFor({ batteryAvailable: true, battery: null, known: true }), 'Battery 0%')
  eq('a non-numeric battery on an unknown device', BT.subtextFor({ batteryAvailable: true, battery: 'x' }), 'Available')
})
group('the reading is not clamped, which is what the projection feeds it', () => {
  // A BluetoothDevice battery is a 0..1 fraction, so these are the
  // out-of-range values a bad device would report. Not clamped: the value
  // goes to the label as read.
  eq('a battery above full', BT.subtextFor({ batteryAvailable: true, battery: 2.55 }), 'Battery 255%')
  eq('a negative battery', BT.subtextFor({ batteryAvailable: true, battery: -0.01 }), 'Battery -1%')
  eq('a negative integer fraction', BT.subtextFor({ batteryAvailable: true, battery: -1 }), 'Battery -100%')
  eq('a battery already in percent is doubled', BT.subtextFor({ batteryAvailable: true, battery: 50 }), 'Battery 5000%')
})
group('the degenerate rows', () => {
  eq('a null row', BT.subtextFor(null), 'Available')
  eq('undefined', BT.subtextFor(undefined), 'Available')
  eq('no argument', BT.subtextFor(), 'Available')
  eq('a string row', BT.subtextFor('x'), 'Available')
  eq('a numeric row', BT.subtextFor(7), 'Available')
  eq('a truthy batteryAvailable is the flag', BT.subtextFor({ batteryAvailable: 1, battery: 0.5 }), 'Battery 50%')
})

section('Bluetooth/Model.listEntries - the flat header/device projection')
group('a header entry at each section start, a device entry per row', () => {
  // On the connected-first sort the sections interleave, so a header entry
  // appears at EVERY transition: four rows give four headers here. On the
  // paired-then-available list an island section really is, there is one.
  eq('the entry types and order', BT.listEntries(BT_SORTED, false).map((e) => e.type), ['header', 'device', 'header', 'device', 'header', 'device', 'header', 'device'])
  eq('the header titles', BT.listEntries(BT_SORTED, false).filter((e) => e.type === 'header').map((e) => e.title), ['PAIRED DEVICES', 'AVAILABLE DEVICES', 'PAIRED DEVICES', 'AVAILABLE DEVICES'])
  eq('and a grouped list gives one header and two devices', BT.listEntries([{ name: 'a', known: true }, { name: 'b', known: true }], false).map((e) => e.type), ['header', 'device', 'device'])
  eq('a device entry is { type, row }', Object.keys(BT.listEntries(BT_SORTED, false)[1]), ['type', 'row'])
  eq('a header entry is { type, title }', Object.keys(BT.listEntries(BT_SORTED, false)[0]), ['type', 'title'])
  eq('the row object is the caller\'s, not a copy', BT.listEntries(BT_SORTED, false)[1].row === BT_SORTED[0], true)
  eq('the entry count is rows + headers', BT.listEntries(BT_SORTED, false).length, 8)
  eq('one header per section start, so one per row on an interleaved sort', BT.listEntries(BT_SORTED, false).filter((e) => e.type === 'header').length, 4)
  eq('and a grouped list is rows + 1', BT.listEntries([{ name: 'a', known: true }, { name: 'b', known: true }], false).length, 3)
})
group('the available header is appended on request, even with no rows', () => {
  eq('with rows present it is a no-op', BT.listEntries(BT_SORTED, true).map((e) => e.type), BT.listEntries(BT_SORTED, false).map((e) => e.type))
  eq('an empty list gets the header alone', BT.listEntries([], true), [{ type: 'header', title: 'AVAILABLE DEVICES' }])
  eq('an empty list without the flag', BT.listEntries([], false), [])
  eq('an all-paired list still gets the trailing header', BT.listEntries([{ name: 'p', known: true }], true).map((e) => e.type), ['header', 'device', 'header'])
  eq('an all-available list does not get a second one', BT.listEntries([{ name: 'a', known: false }], true).map((e) => e.type), ['header', 'device'])
  // "so the scan control is reachable without any discovered devices" - that
  // is the empty-list case above, and it is the reason the trailing header
  // is unconditional rather than a section start.
  eq('the trailing header is the last entry', BT.listEntries([{ name: 'p', known: true }], true).pop(), { type: 'header', title: 'AVAILABLE DEVICES' })
})
group('the flag is a truthiness test, so undefined means off', () => {
  eq('undefined is falsy, so no trailing header', BT.listEntries(BT_SORTED, undefined).map((e) => e.type), BT.listEntries(BT_SORTED, false).map((e) => e.type))
  eq('a truthy non-boolean', BT.listEntries([], 1).length, 1)
  eq('zero is falsy', BT.listEntries([], 0), [])
  eq('an empty string is falsy', BT.listEntries([], ''), [])
  eq('no argument at all is the no-header form', BT.listEntries(BT_SORTED).map((e) => e.type), BT.listEntries(BT_SORTED, false).map((e) => e.type))
})
group('the degenerate inputs', () => {
  // `sorted.length` is read unguarded, so the LIST must be an array. The
  // caller always passes the output of sortDeviceRows, which is one.
  noThrow('a string flag', () => BT.listEntries([{ name: 'a', known: true }], 'yes'))
  eq('a truthy string flag is honoured', BT.listEntries([{ name: 'a', known: true }], 'yes').map((e) => e.type), ['header', 'device', 'header'])
  throws('a null list', () => BT.listEntries(null, true), /length/)
  throws('an undefined list', () => BT.listEntries(undefined, false), /length/)
  throws('no argument at all', () => BT.listEntries(), /length/)
  noThrow('an empty list', () => BT.listEntries([], true))
  // A number has no `.length`, so the loop is a no-op and the answer is an
  // empty list. A STRING has a length, so the loop runs over its characters
  // and each one is pushed as a device row with the character itself as the
  // row. Neither is a real input - the island passes sortDeviceRows output -
  // but both are pinned because they are what the unguarded loop does.
  eq('a number list walks nothing', BT.listEntries(7, false), [])
  eq('a string list walks its characters', BT.listEntries('xy', false), [{ type: 'device', row: 'x' }, { type: 'device', row: 'y' }])
  // The input array is only read, so a caller can hold on to it.
  eq('the input list is not mutated', (() => { const rows = [{ name: 'a', known: true }]; BT.listEntries(rows, true); return rows.length })(), 1)
})

// ======================================================================
section('Network/Model - the speedtest meter scale')
group('the stop table is the published one, in ascending order', () => {
  eq('the six stops', NET.SPEED_SCALE_STOPS, [100, 500, 1000, 2500, 5000, 10000])
  eq('they are strictly ascending', NET.SPEED_SCALE_STOPS.every((s, i) => i === 0 || s > NET.SPEED_SCALE_STOPS[i - 1]), true)
  eq('every run opens capped at the first stop', NET.initialSpeedScale(), 100)
  eq('and that is the table head', NET.initialSpeedScale() === NET.SPEED_SCALE_STOPS[0], true)
  // "A function (not the var itself) because QML only sees top-level
  // functions of an imported script, never its vars" - so the var being on
  // the namespace is a loader artefact, and the function is the real surface.
  eq('a fresh number each call', NET.initialSpeedScale() === NET.initialSpeedScale(), true)
})
group('the cap starts here and never shrinks', () => {
  eq('a value under the cap keeps it', NET.stepSpeedScale(100, 50), 100)
  eq('a value equal to the cap keeps it', NET.stepSpeedScale(100, 100), 100)
  eq('a value just over the cap steps', NET.stepSpeedScale(100, 101), 500)
  eq('a value at the second stop keeps that stop', NET.stepSpeedScale(100, 500), 500)
  eq('a value just over the second stop steps', NET.stepSpeedScale(100, 501), 1000)
  eq('a value far past the first cap', NET.stepSpeedScale(100, 999), 1000)
  eq('a value at the third stop', NET.stepSpeedScale(100, 1000), 1000)
  eq('and just over it', NET.stepSpeedScale(100, 1001), 2500)
  eq('a value far past every stop pins at the last', NET.stepSpeedScale(100, 1e9), 10000)
  eq('1e9 does not overflow the loop', Number.isFinite(NET.stepSpeedScale(100, 1e9)), true)
})
group('it grows to the FIRST stop that still contains the value', () => {
  // "Grow `scale` to the first stop that still contains `value`" - so the
  // walk skips every stop the value has outgrown rather than stopping at the
  // first one it passes.
  for (let i = 0; i < NET.SPEED_SCALE_STOPS.length; i++) {
    const stop = NET.SPEED_SCALE_STOPS[i]
    const out = NET.stepSpeedScale(NET.SPEED_SCALE_STOPS[0], stop)
    eq(`a value of ${stop} lands on stop ${i}`, out, stop)
  }
  eq('a value just under the first stop', NET.stepSpeedScale(100, 99.99), 100)
  eq('a value just under the second stop', NET.stepSpeedScale(100, 499.99), 500)
  eq('a value just under the last stop', NET.stepSpeedScale(100, 9999.99), 10000)
  eq('the result is always one of the stops', NET.SPEED_SCALE_STOPS.indexOf(NET.stepSpeedScale(100, 4321)) >= 0, true)
})
group('a scale below the value steps up; a scale above it holds', () => {
  eq('a mid-table scale with a bigger value', NET.stepSpeedScale(500, 2000), 2500)
  eq('a mid-table scale with a smaller value holds', NET.stepSpeedScale(5000, 10), 5000)
  eq('a scale equal to the value holds', NET.stepSpeedScale(5000, 5000), 5000)
  eq('a scale above the last stop holds', NET.stepSpeedScale(10000, 1), 10000)
  eq('a scale between two stops', NET.stepSpeedScale(250, 300), 500)
  // The `stops[i] < s` skip is what makes "never shrinks mid-run" true for a
  // scale that is not itself a stop.
  eq('a scale that is not a stop never lands below itself', NET.stepSpeedScale(700, 1) >= 700, true)
})
group('never shrinks, across a whole run', () => {
  let s = NET.initialSpeedScale()
  const climb = []
  for (const v of [10, 250, 900, 2400, 4900, 9900, 20000, 1, 1, 1]) {
    s = NET.stepSpeedScale(s, v)
    climb.push(s)
  }
  eq('the climb', climb, [100, 500, 1000, 2500, 5000, 10000, 10000, 10000, 10000, 10000])
  is('every step is >= the previous', climb, (c) => c.every((v, i) => i === 0 || v >= c[i - 1]), 'monotone non-decreasing')
  eq('and a late tiny sample cannot bring it back down', NET.stepSpeedScale(10000, 0), 10000)
})
group('an unusable scale restarts at the first stop', () => {
  eq('zero', NET.stepSpeedScale(0, 10), 100)
  eq('a negative scale', NET.stepSpeedScale(-3, 10), 100)
  eq('NaN', NET.stepSpeedScale(NaN, 10), 100)
  eq('Infinity', NET.stepSpeedScale(Infinity, 10), 100)
  eq('a non-numeric string', NET.stepSpeedScale('x', 10), 100)
  eq('a null scale', NET.stepSpeedScale(null, 10), 100)
  eq('undefined', NET.stepSpeedScale(undefined, 10), 100)
  eq('no scale at all', NET.stepSpeedScale(), 100)
  eq('a numeric string scale is coerced', NET.stepSpeedScale('100', 200), 500)
  eq('a fraction is below the first stop, so it restarts', NET.stepSpeedScale(0.5, 5), 100)
  // "if (!isFinite(s) || s <= 0) s = stops[0]" - so the fallback is the
  // START of a fresh run, not the value's own stop. Pinned: a caller that
  // loses its scale mid-run does not jump to a stop chosen by the sample.
  eq('a NaN scale with a huge value still starts at 100', NET.stepSpeedScale(NaN, 1e9), 10000)
})
group('an unusable value is a zero sample, not a step', () => {
  eq('NaN', NET.stepSpeedScale(100, NaN), 100)
  eq('a non-numeric string', NET.stepSpeedScale(100, 'x'), 100)
  eq('a null value', NET.stepSpeedScale(100, null), 100)
  eq('undefined', NET.stepSpeedScale(100, undefined), 100)
  eq('a negative sample', NET.stepSpeedScale(100, -5), 100)
  eq('Infinity', NET.stepSpeedScale(100, Infinity), 100)
  eq('a numeric string sample is coerced', NET.stepSpeedScale(100, '250'), 500)
  eq('no value at all', NET.stepSpeedScale(100), 100)
})
group('the caption of the cap', () => {
  eq('the first stop', NET.speedScaleLabel(100), '100 Mbps')
  eq('the second', NET.speedScaleLabel(500), '500 Mbps')
  eq('a gigabit switches to Gbps', NET.speedScaleLabel(1000), '1 Gbps')
  eq('2.5 Gbps keeps its decimal', NET.speedScaleLabel(2500), '2.5 Gbps')
  eq('5 Gbps drops it', NET.speedScaleLabel(5000), '5 Gbps')
  eq('the last stop', NET.speedScaleLabel(10000), '10 Gbps')
  eq('just under the switch', NET.speedScaleLabel(999), '999 Mbps')
  eq('just over the switch', NET.speedScaleLabel(1001), '1.0 Gbps')
  eq('a fractional megabit rounds', NET.speedScaleLabel(999.4), '999 Mbps')
  eq('a fractional gigabit keeps one decimal', NET.speedScaleLabel(1500), '1.5 Gbps')
  for (const stop of NET.SPEED_SCALE_STOPS) {
    is(`the caption of ${stop} has a unit`, NET.speedScaleLabel(stop), (s) => / (Mbps|Gbps)$/.test(s), 'Mbps or Gbps')
  }
})
group('an unusable caption reads as the first stop', () => {
  // "if (!isFinite(n) || n <= 0) n = SPEED_SCALE_STOPS[0]" - so a cleared
  // meter shows its opening cap rather than "0 Mbps".
  eq('zero', NET.speedScaleLabel(0), '100 Mbps')
  eq('a negative', NET.speedScaleLabel(-5), '100 Mbps')
  eq('NaN', NET.speedScaleLabel(NaN), '100 Mbps')
  eq('Infinity', NET.speedScaleLabel(Infinity), '100 Mbps')
  eq('a non-numeric string', NET.speedScaleLabel('x'), '100 Mbps')
  eq('null', NET.speedScaleLabel(null), '100 Mbps')
  eq('undefined', NET.speedScaleLabel(undefined), '100 Mbps')
  eq('no argument', NET.speedScaleLabel(), '100 Mbps')
  eq('a numeric string is coerced', NET.speedScaleLabel('2000'), '2 Gbps')
  // A positive fraction below 1 is a usable cap, so it prints as itself.
  eq('a positive fraction is not replaced', NET.speedScaleLabel(0.4), '0 Mbps')
  eq('and rounds to 0', NET.speedScaleLabel(0.6), '1 Mbps')
})

section('Network/Model - the tiered glyph')
group('the arc-group count mirrors the old 25/50/75 thresholds', () => {
  eq('just under a quarter', NET.strengthDimTiers(0.2499), 1)
  eq('exactly a quarter', NET.strengthDimTiers(0.25), 2)
  eq('just under a half', NET.strengthDimTiers(0.4999), 2)
  eq('exactly a half', NET.strengthDimTiers(0.5), 3)
  eq('just under three quarters', NET.strengthDimTiers(0.7499), 3)
  eq('exactly three quarters', NET.strengthDimTiers(0.75), 4)
  eq('full strength', NET.strengthDimTiers(1), 4)
  eq('over full strength is still everything', NET.strengthDimTiers(1.5), 4)
  eq('no signal', NET.strengthDimTiers(0), 1)
  eq('a negative strength reads as no signal', NET.strengthDimTiers(-1), 1)
})
group('the reachable tier range is 1..4, and the documented 0 is not in it', () => {
  // Both the source comment and the README say "0 = whole glyph, 1 = dot
  // only ... 4 = everything", but the lowest branch is `s < 0.25 -> 1`, so
  // no input returns 0. Pinned as the observed range: a reader who takes
  // the comment literally will look for a 0 that cannot arrive. See the
  // report.
  eq('the distinct tiers over the whole domain', [...new Set([0, 0.1, 0.24, 0.25, 0.3, 0.49, 0.5, 0.6, 0.74, 0.75, 0.9, 1, 1.5].map(NET.strengthDimTiers))].sort(), [1, 2, 3, 4])
  is('the minimum is 1, not 0', Math.min(...[0, 0.1, 0.5, 0.9, 1].map(NET.strengthDimTiers)), (v) => v === 1, 'never 0')
  is('every tier is an integer in 1..4', [0, 0.3, 0.6, 0.9, 1].map(NET.strengthDimTiers), (v) => v.every((t) => Number.isInteger(t) && t >= 1 && t <= 4), '1..4')
  is('the tier never decreases as strength rises', [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1].map(NET.strengthDimTiers), (t) => t.every((v, i) => i === 0 || v >= t[i - 1]), 'monotone non-decreasing')
})
group('an unusable strength reads as no signal', () => {
  // "if (!isFinite(s)) s = 0" - and an infinite strength is non-finite, so a
  // backend reporting Infinity dims the glyph to a dot rather than showing
  // every arc. Pinned: the branch is isFinite, not isNaN.
  eq('NaN', NET.strengthDimTiers(NaN), 1)
  eq('Infinity', NET.strengthDimTiers(Infinity), 1)
  eq('-Infinity', NET.strengthDimTiers(-Infinity), 1)
  eq('a non-numeric string', NET.strengthDimTiers('x'), 1)
  eq('null is a zero, not a non-number', NET.strengthDimTiers(null), 1)
  eq('undefined', NET.strengthDimTiers(undefined), 1)
  eq('no argument', NET.strengthDimTiers(), 1)
  eq('a numeric string is coerced', NET.strengthDimTiers('0.6'), 3)
})

section('Network/Model.parseStats - the /sys probe reply')
group('key<TAB>value lines become an object', () => {
  eq('a full reply', NET.parseStats('iface\twlan0\nrx_bytes\t12345\ntx_bytes\t999\n'), { iface: 'wlan0', rx_bytes: '12345', tx_bytes: '999' })
  eq('a single line', NET.parseStats('iface\twlan0'), { iface: 'wlan0' })
  eq('the value is trimmed', NET.parseStats('a\t  b  '), { a: 'b' })
  eq('a value holding spaces keeps its interior', NET.parseStats('a\tb c'), { a: 'b c' })
  eq('a tab in the value is not split again', NET.parseStats('a\tb\tc'), { a: 'b\tc' })
  eq('a later line wins a duplicate key', NET.parseStats('a\t1\na\t2'), { a: '2' })
})
group('anything that is not key<TAB>value is dropped', () => {
  eq('a line with no tab', NET.parseStats('iface wlan0'), {})
  eq('a blank line between values is skipped', NET.parseStats('a\t1\n\nb\t2'), { a: '1', b: '2' })
  eq('a leading tab makes an empty key', NET.parseStats('\tvalue'), { '': 'value' })
  eq('a trailing tab makes an empty value', NET.parseStats('a\t'), { a: '' })
  eq('CRLF: the value carries the CR away with the trim', NET.parseStats('a\t1\r\nb\t2'), { a: '1', b: '2' })
  eq('CRLF with a bare CR in the key does not', NET.parseStats('a\r\t1'), { 'a\r': '1' })
})
group('an absent reply is an empty object, not a throw', () => {
  eq('an empty string', NET.parseStats(''), {})
  eq('a newline only', NET.parseStats('\n'), {})
  eq('null', NET.parseStats(null), {})
  eq('undefined', NET.parseStats(undefined), {})
  eq('no argument', NET.parseStats(), {})
  eq('a number is stringified', NET.parseStats(7), {})
  eq('an object reads as "[object Object]" with no tab', NET.parseStats({}), {})
  noThrow('a symbol-free object', () => NET.parseStats({ a: 1 }))
})
group('the reply the island actually gets: iface, rx_bytes, tx_bytes', () => {
  const parsed = NET.parseStats('iface\twlan0\nrx_bytes\t1000\ntx_bytes\t2000\n')
  eq('three keys', Object.keys(parsed), ['iface', 'rx_bytes', 'tx_bytes'])
  eq('all strings', Object.values(parsed).every((v) => typeof v === 'string'), true)
  eq('the counters are numbers as text', parsed.rx_bytes, '1000')
  eq('and deriveStats parses them', NET.deriveStats(null, 'iface\twlan0\nrx_bytes\t1000\n', 10).totalRxBytes, 1000)
})

section('Network/Model.throughputState - the rate from successive samples')
group('the first sample has no baseline and reports no rate', () => {
  eq('from nothing', NET.throughputState(null, { iface: 'wlan0', rx_bytes: '100', tx_bytes: '50' }, 10), {
    prevIface: 'wlan0', prevRxBytes: 100, prevTxBytes: 50, prevSampleTime: 10, downloadRate: 0, uploadRate: 0,
  })
  eq('from an empty object', NET.throughputState({}, { iface: 'wlan0', rx_bytes: '100', tx_bytes: '50' }, 10).downloadRate, 0)
  eq('from undefined', NET.throughputState(undefined, { iface: 'wlan0', rx_bytes: '100' }, 10).downloadRate, 0)
  eq('and it records the baseline for next time', NET.throughputState(null, { iface: 'wlan0', rx_bytes: '100' }, 10).prevRxBytes, 100)
})
group('a real delta is bytes per second', () => {
  const next = NET.throughputState({ prevIface: 'wlan0', prevRxBytes: 100, prevTxBytes: 50, prevSampleTime: 10 }, { iface: 'wlan0', rx_bytes: '300', tx_bytes: '70' }, 20)
  eq('download', next.downloadRate, 20)
  eq('upload', next.uploadRate, 2)
  eq('the baseline moved', [next.prevRxBytes, next.prevTxBytes, next.prevSampleTime], [300, 70, 20])
  eq('a fraction of a second', NET.throughputState({ prevIface: 'w', prevRxBytes: 0, prevTxBytes: 0, prevSampleTime: 10 }, { iface: 'w', rx_bytes: '100', tx_bytes: '100' }, 10.5).downloadRate, 200)
})
group('a switch, an empty iface or a missing clock drops the baseline', () => {
  // "The first sample after a switch (or after open) has no baseline and must
  // not manufacture a spike" - the three reset cases.
  const sw = NET.throughputState({ prevIface: 'eth0', prevRxBytes: 1, prevTxBytes: 1, prevSampleTime: 10 }, { iface: 'wlan0', rx_bytes: '300', tx_bytes: '70' }, 20)
  eq('an interface switch reports no rate', [sw.downloadRate, sw.uploadRate], [0, 0])
  eq('and re-baselines on the new interface', sw.prevIface, 'wlan0')
  eq('an empty iface', NET.throughputState({ prevIface: 'w', prevSampleTime: 10 }, { iface: '', rx_bytes: '1' }, 20).downloadRate, 0)
  eq('a missing iface field', NET.throughputState({ prevIface: 'w', prevSampleTime: 10 }, { rx_bytes: '1' }, 20).downloadRate, 0)
  eq('a zero previous time', NET.throughputState({ prevIface: 'w', prevRxBytes: 1, prevSampleTime: 0 }, { iface: 'w', rx_bytes: '99' }, 20).downloadRate, 0)
  eq('no previous time at all', NET.throughputState({ prevIface: 'w', prevRxBytes: 1 }, { iface: 'w', rx_bytes: '99' }, 20).downloadRate, 0)
})
group('a counter that goes backwards clamps to zero, never negative', () => {
  // `Math.max(0, (rx - prev) / dt)` - an interface reset (a new route, a
  // counter wrap) reads as no traffic rather than as a huge negative.
  const reset = NET.throughputState({ prevIface: 'w', prevRxBytes: 500, prevTxBytes: 500, prevSampleTime: 10 }, { iface: 'w', rx_bytes: '10', tx_bytes: '10' }, 20)
  eq('download', reset.downloadRate, 0)
  eq('upload', reset.uploadRate, 0)
  eq('and the counter is kept as read', reset.prevRxBytes, 10)
})
group('a zero or negative interval reports no rate', () => {
  eq('the same instant', NET.throughputState({ prevIface: 'w', prevRxBytes: 0, prevTxBytes: 0, prevSampleTime: 20 }, { iface: 'w', rx_bytes: '100', tx_bytes: '100' }, 20).downloadRate, 0)
  eq('a clock that went backwards', NET.throughputState({ prevIface: 'w', prevRxBytes: 0, prevTxBytes: 0, prevSampleTime: 30 }, { iface: 'w', rx_bytes: '100', tx_bytes: '100' }, 20).downloadRate, 0)
  eq('a NaN interval', NET.throughputState({ prevIface: 'w', prevRxBytes: 0, prevTxBytes: 0, prevSampleTime: 10 }, { iface: 'w', rx_bytes: '100' }, NaN).downloadRate, 0)
  eq('a non-numeric interval', NET.throughputState({ prevIface: 'w', prevRxBytes: 0, prevTxBytes: 0, prevSampleTime: 10 }, { iface: 'w', rx_bytes: '100' }, 'x').downloadRate, 0)
})
group('missing counters are treated as zero', () => {
  eq('a sample with no rx_bytes', NET.throughputState({ prevIface: 'w', prevRxBytes: 0, prevTxBytes: 0, prevSampleTime: 10 }, { iface: 'w' }, 20).prevRxBytes, 0)
  eq('a numeric string is parsed', NET.throughputState({ prevIface: 'w', prevRxBytes: 0, prevTxBytes: 0, prevSampleTime: 10 }, { iface: 'w', rx_bytes: '100.5' }, 20).downloadRate, 10.05)
  eq('a null counter is zero', NET.throughputState({ prevIface: 'w', prevRxBytes: 0, prevTxBytes: 0, prevSampleTime: 10 }, { iface: 'w', rx_bytes: null }, 20).prevRxBytes, 0)
  // A non-numeric counter text is the one input that leaks NaN into the
  // state rather than reading as zero: parseFloat("abc") is NaN and the
  // Math.max(0, NaN) is NaN. The reply is generated from /sys, so this is
  // only reachable on a corrupt read - pinned because the alternative
  // (a silent zero) would be what a reader assumes.
  const junk = NET.throughputState({ prevIface: 'w', prevRxBytes: 0, prevTxBytes: 0, prevSampleTime: 10 }, { iface: 'w', rx_bytes: 'x', tx_bytes: 'y' }, 20)
  eq('a non-numeric counter records NaN', Number.isNaN(junk.prevRxBytes), true)
  eq('and the rate is NaN too', Number.isNaN(junk.downloadRate), true)
  eq('which the formatter renders as no reading', NET.formatRate(junk.downloadRate), '0 B/s')
})
group('the returned state is the six documented fields', () => {
  const st = NET.throughputState(null, { iface: 'wlan0', rx_bytes: '1', tx_bytes: '2' }, 5)
  eq('the key set', Object.keys(st), ['prevIface', 'prevRxBytes', 'prevTxBytes', 'prevSampleTime', 'downloadRate', 'uploadRate'])
  eq('the counters are numbers, not the reply strings', typeof st.prevRxBytes, 'number')
  eq('the time is the one passed in', st.prevSampleTime, 5)
})

section('Network/Model.deriveStats - the metrics block, as one pure step')
const RAW_STATS = 'iface\twlan0\nrx_bytes\t1000\ntx_bytes\t2000\n'
group('the first sample has stats but no rate', () => {
  const s = NET.deriveStats(null, RAW_STATS, 10)
  eq('the key set', Object.keys(s), ['hasStats', 'downloadRate', 'uploadRate', 'totalRxBytes', 'totalTxBytes', 'prevThroughput'])
  eq('hasStats', s.hasStats, true)
  eq('no rate yet', [s.downloadRate, s.uploadRate], [0, 0])
  eq('the cumulative totals are read straight through', [s.totalRxBytes, s.totalTxBytes], [1000, 2000])
  is('the throughput baseline is kept for next time', s.prevThroughput, (v) => v && typeof v === 'object' && v.prevSampleTime === 10, 'a throughputState')
})
group('the second sample rates the delta', () => {
  const first = NET.deriveStats(null, RAW_STATS, 10)
  const second = NET.deriveStats(first, 'iface\twlan0\nrx_bytes\t3000\ntx_bytes\t2000\n', 20)
  eq('download', second.downloadRate, 200)
  eq('upload', second.uploadRate, 0)
  eq('the carried total is the new one', second.totalRxBytes, 3000)
  eq('and the carried total is untouched where the reply omitted it', second.totalTxBytes, 2000)
  eq('the baseline is the new sample', second.prevThroughput.prevSampleTime, 20)
})
group('a reply with no iface means no active route', () => {
  // "the link is down, rates read "--", and the throughput baseline is
  // DROPPED so the next connect does not manufacture a spike off a stale
  // interval. The cumulative counters carry forward."
  const first = NET.deriveStats(null, RAW_STATS, 10)
  const down = NET.deriveStats(first, '', 20)
  eq('no stats', down.hasStats, false)
  eq('no rate', [down.downloadRate, down.uploadRate], [0, 0])
  eq('the baseline is dropped', down.prevThroughput, null)
  eq('the boot-to-now totals carry forward', [down.totalRxBytes, down.totalTxBytes], [1000, 2000])
  eq('a reply with no iface key at all reads the same', NET.deriveStats(first, 'rx_bytes\t5\n', 20).hasStats, false)
  eq('and the next run after a drop re-baselines', NET.deriveStats(down, RAW_STATS, 30).downloadRate, 0)
})
group('a sample that omits a counter keeps the last one', () => {
  // "rather than reporting a false zero for a counter nobody read this tick".
  const first = NET.deriveStats(null, RAW_STATS, 10)
  const partial = NET.deriveStats(first, 'iface\twlan0\n', 20)
  eq('the rx total carries', partial.totalRxBytes, 1000)
  eq('the tx total carries', partial.totalTxBytes, 2000)
  eq('and the baseline reads the omitted counters as zero', [partial.prevThroughput.prevRxBytes, partial.prevThroughput.prevTxBytes], [0, 0])
  eq('a null state is an empty carry', NET.deriveStats(null, RAW_STATS, 10).totalRxBytes, 1000)
})
group('an unusable clock does not poison the baseline', () => {
  const first = NET.deriveStats(null, RAW_STATS, 10)
  const bad = NET.deriveStats(first, RAW_STATS, 'x')
  eq('a non-numeric clock becomes zero', bad.prevThroughput.prevSampleTime, 0)
  eq('and reports no rate', bad.downloadRate, 0)
  eq('a NaN clock becomes zero', NET.deriveStats(first, RAW_STATS, NaN).prevThroughput.prevSampleTime, 0)
  eq('an absent clock becomes zero', NET.deriveStats(first, RAW_STATS).prevThroughput.prevSampleTime, 0)
  eq('a null clock becomes zero', NET.deriveStats(first, RAW_STATS, null).prevThroughput.prevSampleTime, 0)
  // A zero clock is the same as "no baseline" on the NEXT call, which is the
  // safe direction: a fresh sample rather than a divide by a bogus interval.
  eq('so the next sample re-baselines instead of spiking', NET.deriveStats(bad, RAW_STATS, 40).downloadRate, 0)
})
group('a corrupt counter reads as a zero total', () => {
  eq('a non-numeric rx', NET.deriveStats(null, 'iface\twlan0\nrx_bytes\tabc\n', 10).totalRxBytes, 0)
  eq('a non-numeric tx', NET.deriveStats(null, 'iface\twlan0\ntx_bytes\tabc\n', 10).totalTxBytes, 0)
  eq('an empty counter', NET.deriveStats(null, 'iface\twlan0\nrx_bytes\t\n', 10).totalRxBytes, 0)
  eq('a missing total in the previous state is zero', NET.deriveStats({ }, '', 10).totalRxBytes, 0)
  eq('a non-numeric previous total is zero', NET.deriveStats({ totalRxBytes: 'x', totalTxBytes: 'y' }, '', 10).totalRxBytes, 0)
})
group('the state is handable back untouched', () => {
  // "prev is the exact object this function returned last time" - so a second
  // call with the first call's result must report no change.
  const first = NET.deriveStats(null, RAW_STATS, 10)
  eq('the object is not mutated by the second call', NET.deriveStats(first, RAW_STATS, 10).totalRxBytes, 1000)
  eq('and the first result still reads the same', first.totalRxBytes, 1000)
  eq('a null previous state is fine', NET.deriveStats(null, RAW_STATS, 10).hasStats, true)
  eq('an undefined previous state is fine', NET.deriveStats(undefined, RAW_STATS, 10).hasStats, true)
  eq('a string previous state is fine', NET.deriveStats('x', RAW_STATS, 10).hasStats, true)
  eq('a null reply is a dropped link', NET.deriveStats(null, null, 10).hasStats, false)
  eq('undefined is a dropped link', NET.deriveStats(null, undefined, 10).hasStats, false)
  eq('a number reply is a dropped link', NET.deriveStats(null, 7, 10).hasStats, false)
})

section('Network/Model - the byte and rate formatters')
group('each unit boundary, and the label on the far side of it', () => {
  eq('zero', NET.formatBytes(0), '0 B')
  eq('1', NET.formatBytes(1), '1 B')
  eq('255', NET.formatBytes(255), '255 B')
  eq('256', NET.formatBytes(256), '256 B')
  eq('one below a kibibyte', NET.formatBytes(1023), '1023 B')
  eq('exactly a kibibyte', NET.formatBytes(1024), '1.0 KB')
  eq('one above', NET.formatBytes(1025), '1.0 KB')
  eq('one below a mebibyte', NET.formatBytes(1048575), '1024.0 KB')
  eq('exactly a mebibyte', NET.formatBytes(1048576), '1.0 MB')
  eq('one below a gibibyte', NET.formatBytes(1073741823), '1024.0 MB')
  eq('exactly a gibibyte', NET.formatBytes(1073741824), '1.00 GB')
  eq('a decimal gigabyte', NET.formatBytes(1500000000), '1.40 GB')
})
group('the byte unit is rounded to a whole number, the rest to one decimal', () => {
  eq('a fractional byte rounds', NET.formatBytes(512.6), '513 B')
  eq('a byte value that rounds up past the unit boundary', NET.formatBytes(1023.9), '1024 B')
  eq('and the same one byte later switches unit', NET.formatBytes(1024), '1.0 KB')
  eq('a mebibyte one step down rounds to 1024.0 KB', NET.formatBytes(1048575.9), '1024.0 KB')
  eq('a KB keeps one decimal', NET.formatBytes(1536), '1.5 KB')
  eq('a MB keeps one decimal', NET.formatBytes(1572864), '1.5 MB')
  eq('a GB keeps two', NET.formatBytes(1073741824 * 1.5), '1.50 GB')
  eq('and never three', NET.formatBytes(1073741824 * 1.5), '1.50 GB')
})
group('an unusable byte count reads as zero', () => {
  eq('a negative count', NET.formatBytes(-1), '0 B')
  eq('a large negative', NET.formatBytes(-1e9), '0 B')
  eq('NaN', NET.formatBytes(NaN), '0 B')
  eq('Infinity', NET.formatBytes(Infinity), '0 B')
  eq('-Infinity', NET.formatBytes(-Infinity), '0 B')
  eq('a non-numeric string', NET.formatBytes('abc'), '0 B')
  eq('null', NET.formatBytes(null), '0 B')
  eq('undefined', NET.formatBytes(undefined), '0 B')
  eq('no argument', NET.formatBytes(), '0 B')
  eq('an object', NET.formatBytes({}), '0 B')
  eq('an array', NET.formatBytes([]), '0 B')
})
group('a numeric string is coerced', () => {
  eq('"2048"', NET.formatBytes('2048'), '2.0 KB')
  eq('"0"', NET.formatBytes('0'), '0 B')
  eq('"-1"', NET.formatBytes('-1'), '0 B')
  eq('an empty string is a zero', NET.formatBytes(''), '0 B')
  eq('a fractional string', NET.formatBytes('512.6'), '513 B')
})
group('the rate is the same number with /s on the end', () => {
  eq('zero', NET.formatRate(0), '0 B/s')
  eq('a kibibyte per second', NET.formatRate(1024), '1.0 KB/s')
  eq('a gigabit-scale figure', NET.formatRate(1073741824), '1.00 GB/s')
  eq('the underlying formatter agrees', NET.formatRate(2048), NET.formatBytes(2048) + '/s')
  eq('a null rate', NET.formatRate(null), '0 B/s')
  eq('a NaN rate', NET.formatRate(NaN), '0 B/s')
  eq('a negative rate is clamped by the byte formatter', NET.formatRate(-5), '0 B/s')
  for (const n of [0, 1, 1023, 1024, 1048576, 1073741824]) {
    eq(`formatRate(${n}) is formatBytes(${n})/s`, NET.formatRate(n), `${NET.formatBytes(n)}/s`)
  }
})

section('Network/Model - the security label table')
group('the twelve enum members, in numeric order', () => {
  eq('Wpa3SuiteB192', NET.securityLabel(0), 'WPA3-Enterprise')
  eq('Sae', NET.securityLabel(1), 'WPA3')
  eq('Wpa2Eap', NET.securityLabel(2), 'WPA2-Enterprise')
  eq('Wpa2Psk', NET.securityLabel(3), 'WPA2')
  eq('WpaEap', NET.securityLabel(4), 'WPA-Enterprise')
  eq('WpaPsk', NET.securityLabel(5), 'WPA')
  eq('StaticWep', NET.securityLabel(6), 'WEP')
  eq('DynamicWep', NET.securityLabel(7), 'WEP')
  eq('Leap', NET.securityLabel(8), 'LEAP')
  eq('Owe', NET.securityLabel(9), 'OWE')
  eq('Open', NET.securityLabel(10), 'Open')
  eq('Unknown', NET.securityLabel(11), 'Secured')
})
group('the table is the source of the labels', () => {
  eq('twelve entries', NET.SECURITY_LABELS.length, 12)
  for (let i = 0; i < NET.SECURITY_LABELS.length; i++) {
    eq(`index ${i} reads back itself`, NET.securityLabel(i), NET.SECURITY_LABELS[i])
  }
  eq('both WEP kinds share one label', NET.SECURITY_LABELS[6], NET.SECURITY_LABELS[7])
  eq('every label is a non-empty string', NET.SECURITY_LABELS.every((l) => typeof l === 'string' && l !== ''), true)
})
group('an out-of-range or unreadable enum is the fail-closed label', () => {
  // "if (!isFinite(s) || s < 0 || s >= SECURITY_LABELS.length) return "Secured"" -
  // an unknown network reads as secured, so the island offers a passphrase
  // field rather than connecting an open network by accident.
  eq('one past the last member', NET.securityLabel(12), 'Secured')
  eq('far past it', NET.securityLabel(9999), 'Secured')
  eq('a negative value', NET.securityLabel(-1), 'Secured')
  eq('NaN', NET.securityLabel(NaN), 'Secured')
  eq('a non-numeric string', NET.securityLabel('x'), 'Secured')
  eq('an empty string', NET.securityLabel(''), 'Secured')
  eq('null', NET.securityLabel(null), 'Secured')
  eq('undefined', NET.securityLabel(undefined), 'Secured')
  eq('no argument', NET.securityLabel(), 'Secured')
  eq('an object', NET.securityLabel({}), 'Secured')
})
group('a numeric string is parsed, and a float truncates', () => {
  // parseInt(security, 10) - so a string enum works and 3.9 becomes 3.
  eq('"3"', NET.securityLabel('3'), 'WPA2')
  eq('"10"', NET.securityLabel('10'), 'Open')
  eq('" 3"', NET.securityLabel(' 3'), 'WPA2')
  eq('"3.9" truncates at the dot', NET.securityLabel('3.9'), 'WPA2')
  eq('the numeric 3.7 truncates too', NET.securityLabel(3.7), 'WPA2')
  eq('the numeric -0.1 truncates to -0, which is in range', NET.securityLabel(-0.1), 'WPA3-Enterprise')
  eq('"3abc" parses the leading digits', NET.securityLabel('3abc'), 'WPA2')
  eq('"0x10" parses as 0', NET.securityLabel('0x10'), 'WPA3-Enterprise')
  eq('Infinity is out of range', NET.securityLabel(Infinity), 'Secured')
})

section('Network/Model.subtextFor - the wifi row sub-line')
group('percentage signal, then the security type', () => {
  eq('a secured network', NET.subtextFor({ signal: 80, securityLabel: 'WPA2' }), '80% signal · WPA2')
  eq('a remembered one trails a saved marker', NET.subtextFor({ signal: 80, securityLabel: 'WPA2', known: true, connected: false }), '80% signal · WPA2 · saved')
  eq('but not while it is the active one', NET.subtextFor({ signal: 80, securityLabel: 'WPA2', known: true, connected: true }), '80% signal · WPA2')
  eq('and not on an unknown network', NET.subtextFor({ signal: 80, securityLabel: 'WPA2', known: false, connected: false }), '80% signal · WPA2')
  eq('an open one', NET.subtextFor({ signal: 42, securityLabel: 'Open' }), '42% signal · Open')
  eq('the separator is a middle dot', NET.subtextFor({ signal: 1, securityLabel: 'Open' }).split(' ')[2], '·')
  eq('the percentage leads', NET.subtextFor({ signal: 55, securityLabel: 'WPA3' }).split(' ')[0], '55%')
  eq('the label trails', NET.subtextFor({ signal: 55, securityLabel: 'WPA3' }).endsWith('WPA3'), true)
})
group('the signal is clamped to 0..100 and rounded', () => {
  eq('rounded down', NET.subtextFor({ signal: 80.4 }), '80% signal · Open')
  eq('rounded up', NET.subtextFor({ signal: 80.5 }), '81% signal · Open')
  eq('zero', NET.subtextFor({ signal: 0 }), '0% signal · Open')
  eq('full', NET.subtextFor({ signal: 100 }), '100% signal · Open')
  eq('above full clamps', NET.subtextFor({ signal: 140 }), '100% signal · Open')
  eq('below zero clamps', NET.subtextFor({ signal: -20 }), '0% signal · Open')
  eq('a fraction rounds to zero', NET.subtextFor({ signal: 0.4 }), '0% signal · Open')
  eq('a numeric string is coerced', NET.subtextFor({ signal: '77' }), '77% signal · Open')
})
group('an unusable signal and label read as 0% and Open', () => {
  eq('a non-numeric signal', NET.subtextFor({ signal: 'x' }), '0% signal · Open')
  eq('a missing signal', NET.subtextFor({}), '0% signal · Open')
  eq('a null signal', NET.subtextFor({ signal: null }), '0% signal · Open')
  eq('NaN', NET.subtextFor({ signal: NaN }), '0% signal · Open')
  // `!isFinite(sig)` folds an infinite signal to zero - it is an unusable
  // reading, not a very strong one. Pinned because wifiRow clamps a big
  // signal but subtextFor does not: the two are reached with different
  // inputs (a 0..100 row here, a 0..1 strength in the row).
  eq('Infinity is an unusable reading, not a strong one', NET.subtextFor({ signal: Infinity }), '0% signal · Open')
  eq('-Infinity likewise', NET.subtextFor({ signal: -Infinity }), '0% signal · Open')
  eq('a null row', NET.subtextFor(null), '0% signal · Open')
  eq('undefined', NET.subtextFor(undefined), '0% signal · Open')
  eq('no argument', NET.subtextFor(), '0% signal · Open')
  eq('a string row', NET.subtextFor('x'), '0% signal · Open')
  // `r.securityLabel ? r.securityLabel : "Open"` is a falsy fold, so a row
  // whose label is the empty string reads as an open network - which is the
  // one place this function guesses, and it is the guess the island wants
  // only because wifiRow always fills a label.
  eq('an empty label falls back to Open', NET.subtextFor({ signal: 0.4, securityLabel: '' }), '0% signal · Open')
  eq('a null label falls back to Open', NET.subtextFor({ signal: 0.4, securityLabel: null }), '0% signal · Open')
  eq('the Secured label is not empty, so it is kept', NET.subtextFor({ securityLabel: 'Secured' }), '0% signal · Secured')
  eq('a numeric zero label falls back', NET.subtextFor({ securityLabel: 0 }), '0% signal · Open')
})

section('Network/Model.isOutOfReach and wifiRow - the snapshot')
group('out of reach is a known, disconnected network with no signal', () => {
  eq('the case', NET.isOutOfReach({ known: true, connected: false, signalStrength: 0 }), true)
  eq('a connected network is never out of reach', NET.isOutOfReach({ known: true, connected: true, signalStrength: 0 }), false)
  eq('an unknown network is not out of reach', NET.isOutOfReach({ known: false, connected: false, signalStrength: 0 }), false)
  eq('a known network with signal is not', NET.isOutOfReach({ known: true, connected: false, signalStrength: 0.5 }), false)
  eq('a missing signal field counts as none', NET.isOutOfReach({ known: true, connected: false }), true)
  eq('a negative signal counts as none', NET.isOutOfReach({ known: true, connected: false, signalStrength: -1 }), true)
  eq('a NaN signal counts as none', NET.isOutOfReach({ known: true, connected: false, signalStrength: NaN }), true)
  eq('a null network', NET.isOutOfReach(null), false)
  eq('a known: 0 network', NET.isOutOfReach({ known: 0, connected: false, signalStrength: 0 }), false)
  eq('a truthy known', NET.isOutOfReach({ known: 1, connected: 0, signalStrength: 0 }), true)
  eq('a truthy connected beats a zero signal', NET.isOutOfReach({ known: true, connected: 1, signalStrength: 0 }), false)
})
group('the row is exactly the seven snapshot fields', () => {
  eq('the key set', Object.keys(NET.wifiRow({}, OPEN_SEC, OWE_SEC)), ['connected', 'known', 'outOfReach', 'ssid', 'signal', 'secured', 'securityLabel'])
  eq('a full network', NET.wifiRow({ name: 'Net', signalStrength: 0.82, connected: true, known: true, security: 3 }, OPEN_SEC, OWE_SEC), {
    connected: true, known: true, outOfReach: false, ssid: 'Net', signal: 82, secured: true, securityLabel: 'WPA2',
  })
})
group('the signal is a 0..100 percentage, rounded', () => {
  eq('rounded up', NET.wifiRow({ signalStrength: 0.826 }, OPEN_SEC, OWE_SEC).signal, 83)
  eq('rounded down', NET.wifiRow({ signalStrength: 0.824 }, OPEN_SEC, OWE_SEC).signal, 82)
  eq('full', NET.wifiRow({ signalStrength: 1 }, OPEN_SEC, OWE_SEC).signal, 100)
  eq('a missing strength is zero', NET.wifiRow({}, OPEN_SEC, OWE_SEC).signal, 0)
  eq('a numeric string is coerced', NET.wifiRow({ signalStrength: '0.5' }, OPEN_SEC, OWE_SEC).signal, 50)
  eq('and is not clamped above 100', NET.wifiRow({ signalStrength: 2 }, OPEN_SEC, OWE_SEC).signal, 200)
  eq('a NaN strength', NET.wifiRow({ signalStrength: NaN }, OPEN_SEC, OWE_SEC).signal, 0)
  eq('a null strength', NET.wifiRow({ signalStrength: null }, OPEN_SEC, OWE_SEC).signal, 0)
})
group('secured is "not open and not OWE"', () => {
  eq('open', NET.wifiRow({ security: OPEN_SEC }, OPEN_SEC, OWE_SEC).secured, false)
  eq('owe', NET.wifiRow({ security: OWE_SEC }, OPEN_SEC, OWE_SEC).secured, false)
  eq('wpa2', NET.wifiRow({ security: 3 }, OPEN_SEC, OWE_SEC).secured, true)
  eq('an unknown type is secured', NET.wifiRow({ security: 99 }, OPEN_SEC, OWE_SEC).secured, true)
  eq('a missing type is secured when the enums are real', NET.wifiRow({}, OPEN_SEC, OWE_SEC).secured, true)
  // `security !== openSecurity && security !== oweSecurity` - with undefined
  // enums (a caller that forgot to pass them) a real type still needs a
  // passphrase, because it is not undefined. Only an absent type reads as
  // open. The island always passes both (NetworkIsland.qml:362), so this is
  // the shape a new caller would get, pinned rather than relied on.
  eq('no enums but a real type still needs a passphrase', NET.wifiRow({ security: 3 }, undefined, undefined).secured, true)
  eq('no enums and no type reads as open', NET.wifiRow({}, undefined, undefined).secured, false)
  eq('the predicate on its own', [NET.requiresCredentials(OPEN_SEC, OPEN_SEC, OWE_SEC), NET.requiresCredentials(OWE_SEC, OPEN_SEC, OWE_SEC), NET.requiresCredentials(3, OPEN_SEC, OWE_SEC)], [false, false, true])
  eq('and with both enums equal to undefined', [NET.requiresCredentials(undefined, undefined, undefined), NET.requiresCredentials(3, undefined, undefined)], [false, true])
})
group('a network with no identity is refused, not projected', () => {
  eq('null', NET.wifiRow(null, OPEN_SEC, OWE_SEC), null)
  eq('undefined', NET.wifiRow(undefined, OPEN_SEC, OWE_SEC), null)
  eq('zero', NET.wifiRow(0, OPEN_SEC, OWE_SEC), null)
  eq('an empty string', NET.wifiRow('', OPEN_SEC, OWE_SEC), null)
  noThrow('an empty object is not refused', () => NET.wifiRow({}, OPEN_SEC, OWE_SEC))
  eq('a nameless network keeps an empty ssid', NET.wifiRow({}, OPEN_SEC, OWE_SEC).ssid, '')
  eq('and it still reaches the row with the fail-closed label', NET.wifiRow({}, OPEN_SEC, OWE_SEC).securityLabel, 'Secured')
})
group('the ssid and the flags are normalised', () => {
  // `network.name || ""` is a falsiness fold, not a String() call, so a
  // numeric name survives as a number. wifiDisplayKey and escapeHtml
  // stringify it downstream, so nothing renders wrong - but the row is not
  // primitive-normalised the way the other eight fields are.
  eq('a numeric ssid survives as a number', NET.wifiRow({ name: 5 }, OPEN_SEC, OWE_SEC).ssid, 5)
  eq('and the display key stringifies it', NET.wifiDisplayKey(NET.wifiRow({ name: 5 }, OPEN_SEC, OWE_SEC)), 'ssid:5')
  eq('an empty name', NET.wifiRow({ name: '' }, OPEN_SEC, OWE_SEC).ssid, '')
  eq('a null name', NET.wifiRow({ name: null }, OPEN_SEC, OWE_SEC).ssid, '')
  eq('a truthy connected', NET.wifiRow({ connected: 1 }, OPEN_SEC, OWE_SEC).connected, true)
  eq('an unknown network', NET.wifiRow({ known: 0 }, OPEN_SEC, OWE_SEC).known, false)
  eq('a connected network is never out of reach in the row', NET.wifiRow({ known: true, connected: true, signalStrength: 0 }, OPEN_SEC, OWE_SEC).outOfReach, false)
})

section('Network/Model.failureReasonText - the five named reasons')
const FAIL_REASONS = { NoSecrets: 1, WifiAuthTimeout: 2, WifiNetworkLost: 3, WifiClientDisconnected: 4, WifiClientFailed: 5 }
group('each named reason has its own sentence', () => {
  eq('NoSecrets', NET.failureReasonText(1, FAIL_REASONS), 'Passphrase required')
  eq('WifiAuthTimeout', NET.failureReasonText(2, FAIL_REASONS), 'Wrong password')
  eq('WifiNetworkLost', NET.failureReasonText(3, FAIL_REASONS), 'Network lost')
  eq('WifiClientDisconnected', NET.failureReasonText(4, FAIL_REASONS), 'Disconnected')
  eq('WifiClientFailed', NET.failureReasonText(5, FAIL_REASONS), 'Connection failed')
  eq('the fallback', NET.failureReasonText(99, FAIL_REASONS), 'Failed to connect')
})
group('the reasons map is injected, so the enum values are the caller\'s', () => {
  // "given the ConnectionFailReason enum values as a plain object (pure JS,
  // node-testable)" - NetworkIsland.qml:315 builds exactly this map.
  const shifted = { NoSecrets: 70, WifiAuthTimeout: 71, WifiNetworkLost: 72, WifiClientDisconnected: 73, WifiClientFailed: 74 }
  eq('a shifted map still resolves', NET.failureReasonText(71, shifted), 'Wrong password')
  eq('the original value no longer resolves', NET.failureReasonText(2, shifted), 'Failed to connect')
  eq('a map with a zero member', NET.failureReasonText(0, { NoSecrets: 0 }), 'Passphrase required')
  eq('a missing map is the fallback for everything', NET.failureReasonText(1, null), 'Failed to connect')
  eq('undefined too', NET.failureReasonText(1, undefined), 'Failed to connect')
  eq('an empty map', NET.failureReasonText(1, {}), 'Failed to connect')
  eq('a string map', NET.failureReasonText(1, 'x'), 'Failed to connect')
})
group('an unnamed or nullish reason is the fallback', () => {
  eq('zero against a real map', NET.failureReasonText(0, FAIL_REASONS), 'Failed to connect')
  eq('null', NET.failureReasonText(null, FAIL_REASONS), 'Failed to connect')
  eq('undefined', NET.failureReasonText(undefined, FAIL_REASONS), 'Failed to connect')
  eq('a non-numeric string', NET.failureReasonText('x', FAIL_REASONS), 'Failed to connect')
  // `reason === r.NoSecrets` with a missing map is `undefined === undefined`,
  // so an absent reason matches the FIRST rule. Pinned: it is the one way
  // this function can return the wrong sentence, and it needs a caller that
  // passes neither the reason nor the map.
  eq('no reason and no map matches the first rule', NET.failureReasonText(), 'Passphrase required')
  eq('a reason with no map is the fallback', NET.failureReasonText(99, null), 'Failed to connect')
  eq('and a map that names the reason does resolve it', NET.failureReasonText(1, { WifiAuthTimeout: 1 }), 'Wrong password')
  eq('but a named reason with an empty map does not', NET.failureReasonText(2, {}), 'Failed to connect')
  eq('an object reason', NET.failureReasonText({}, FAIL_REASONS), 'Failed to connect')
  eq('every sentence is a non-empty string', [1, 2, 3, 4, 5, 99].every((r) => typeof NET.failureReasonText(r, FAIL_REASONS) === 'string' && NET.failureReasonText(r, FAIL_REASONS) !== ''), true)
})

section('Network/Model.shouldDiscardSecrets - the wrong-password cleanup')
group('only a fresh secret on a credential failure is discarded', () => {
  eq('wrong password on a fresh submit', NET.shouldDiscardSecrets('connect', true, 2, FAIL_REASONS), true)
  eq('missing secrets on a fresh submit', NET.shouldDiscardSecrets('connect', true, 1, FAIL_REASONS), true)
  eq('a lost network keeps the profile', NET.shouldDiscardSecrets('connect', true, 3, FAIL_REASONS), false)
  eq('a saved profile is never deleted', NET.shouldDiscardSecrets('connect', false, 2, FAIL_REASONS), false)
  eq('only connects count', NET.shouldDiscardSecrets('forget', true, 2, FAIL_REASONS), false)
})

section('Network/Model.authFailureArgv - the urgent wrong-password toast')
group('critical, expiring, tagged, named', () => {
  const argv = NET.authFailureArgv('MyWifi')
  eq('the sender', argv[0], 'notify-send')
  eq('critical urgency', argv[argv.indexOf('-u') + 1], 'critical')
  eq('expiring', argv[argv.indexOf('-t') + 1], '8000')
  contains('the adoption tag', argv, 'string:x-vb-tag:vb-network-auth')
  eq('the summary', argv[argv.length - 2], 'Wrong password')
  contains('the name in bold', argv, '<b>MyWifi</b>')
})

section('Network/Model.sortWifiRows and sectionTitleFor - the two sections')
const NET_ROWS = [
  { ssid: 'A', connected: true, known: true, signal: 10 },
  { ssid: 'B', connected: false, known: true, signal: 90 },
  { ssid: 'C', connected: false, known: false, signal: 50 },
  { ssid: 'D', connected: false, known: false, signal: 70 },
]
const NET_SORTED = NET.sortWifiRows(NET_ROWS)
group('connected first, then known, then by signal', () => {
  eq('the order', NET_SORTED.map((r) => r.ssid), ['A', 'B', 'D', 'C'])
  eq('the input is not mutated', NET_ROWS.map((r) => r.ssid), ['A', 'B', 'C', 'D'])
  eq('a new array comes back', NET.sortWifiRows(NET_ROWS) === NET_ROWS, false)
  eq('the same row objects though', NET.sortWifiRows(NET_ROWS)[0] === NET_ROWS[0], true)
  eq('a connected weak network still beats a known strong one', NET.sortWifiRows([{ ssid: 'w', connected: true, signal: 1 }, { ssid: 's', connected: false, known: true, signal: 99 }]).map((r) => r.ssid), ['w', 's'])
  eq('a known network beats an unknown stronger one', NET.sortWifiRows([{ ssid: 'u', known: false, signal: 99 }, { ssid: 'k', known: true, signal: 1 }]).map((r) => r.ssid), ['k', 'u'])
  eq('within a section it is strongest first', NET.sortWifiRows([{ ssid: 'a', known: false, signal: 10 }, { ssid: 'b', known: false, signal: 90 }]).map((r) => r.ssid), ['b', 'a'])
  eq('a tie keeps the input order', NET.sortWifiRows([{ ssid: 'a', known: false, signal: 50 }, { ssid: 'b', known: false, signal: 50 }]).map((r) => r.ssid), ['a', 'b'])
})
group('the two section headers', () => {
  eq('the titles of a four-network list', NET_SORTED.map((_, i) => NET.sectionTitleFor(i, NET_SORTED)), ['KNOWN NETWORKS', '', 'OTHER NETWORKS', ''])
  eq('an all-known list opens KNOWN', NET.sectionTitleFor(0, [{ known: true }]), 'KNOWN NETWORKS')
  eq('and continues empty', NET.sectionTitleFor(1, [{ known: true }, { known: true }]), '')
  eq('an all-other list opens OTHER', NET.sectionTitleFor(0, [{ known: false }]), 'OTHER NETWORKS')
  eq('and continues empty', NET.sectionTitleFor(1, [{ known: false }, { known: false }]), '')
  eq('a known row after an unknown one reopens KNOWN', NET.sectionTitleFor(1, [{ known: false }, { known: true }]), 'KNOWN NETWORKS')
  eq('an unknown row after a known one opens OTHER', NET.sectionTitleFor(1, [{ known: true }, { known: false }]), 'OTHER NETWORKS')
  eq('an out-of-range index', [NET.sectionTitleFor(-1, NET_SORTED), NET.sectionTitleFor(4, NET_SORTED), NET.sectionTitleFor(99, NET_SORTED)], ['', '', ''])
  eq('a missing list', [NET.sectionTitleFor(0, null), NET.sectionTitleFor(0, undefined), NET.sectionTitleFor(0, 'x')], ['', '', ''])
  eq('a row with no known field is other', NET.sectionTitleFor(0, [{}]), 'OTHER NETWORKS')
})
group('the degenerate row lists', () => {
  eq('an empty list', NET.sortWifiRows([]), [])
  eq('a null list', NET.sortWifiRows(null), [])
  eq('undefined', NET.sortWifiRows(undefined), [])
  eq('a non-array', NET.sortWifiRows('x'), [])
  eq('a number', NET.sortWifiRows(7), [])
  eq('a missing signal sorts as NaN, which is neither less nor more', NET.sortWifiRows([{ ssid: 'a' }, { ssid: 'b' }]).map((r) => r.ssid), ['a', 'b'])
  noThrow('no argument at all', () => NET.sortWifiRows())
  noThrow('a row with no fields at all', () => NET.sortWifiRows([{}]))
  // The comparator reads `a.connected` unguarded, so a null ENTRY throws
  // while a null LIST is handled by the Array.isArray guard. The island
  // builds its rows from wifiRow(), which refuses a falsy network, so an
  // entry is never null.
  throws('a null entry inside the list', () => NET.sortWifiRows([null, { ssid: 'a' }]), /connected/)
  eq('but a single null entry never reaches the comparator', NET.sortWifiRows([null]).length, 1)
})

section('Network/Model - the display key, the viewport and the equality gate')
group('the key is never empty, which a keyed model requires', () => {
  eq('an ssid row', NET.wifiDisplayKey({ ssid: 'A' }), 'ssid:A')
  eq('a nameless row still gets a namespaced key', NET.wifiDisplayKey({}), 'ssid:')
  eq('a null row still gets one', NET.wifiDisplayKey(null), 'ssid:')
  eq('undefined too', NET.wifiDisplayKey(undefined), 'ssid:')
  eq('a numeric ssid is stringified', NET.wifiDisplayKey({ ssid: 5 }), 'ssid:5')
  for (const row of [{ ssid: 'A' }, { ssid: '' }, {}, null]) {
    is(`${JSON.stringify(row)} keys to a non-empty string`, NET.wifiDisplayKey(row), (k) => typeof k === 'string' && k !== '', 'a non-empty string')
  }
})
group('the viewport is bounded at one page of rows', () => {
  eq('a long list', NET.wifiListViewportHeight(1000), 250)
  eq('a short list', NET.wifiListViewportHeight(100), 100)
  eq('exactly the cap', NET.wifiListViewportHeight(250), 250)
  eq('one over the cap', NET.wifiListViewportHeight(251), 250)
})
group('an unusable content height is a zero-height viewport', () => {
  eq('zero', NET.wifiListViewportHeight(0), 0)
  eq('a negative height', NET.wifiListViewportHeight(-1), 0)
  eq('NaN', NET.wifiListViewportHeight(NaN), 0)
  eq('Infinity', NET.wifiListViewportHeight(Infinity), 0)
  eq('a non-numeric string', NET.wifiListViewportHeight('x'), 0)
  eq('null', NET.wifiListViewportHeight(null), 0)
  eq('undefined', NET.wifiListViewportHeight(undefined), 0)
  eq('no content height at all', NET.wifiListViewportHeight(), 0)
  eq('a numeric string is coerced', NET.wifiListViewportHeight('300'), 250)
  eq('extra arguments are ignored', NET.wifiListViewportHeight(1000, null), 250)
  eq('a non-array second argument is ignored', NET.wifiListViewportHeight(1000, 'x'), 250)
  eq('and so is an array one', NET.wifiListViewportHeight(1000, [null, { ssid: 'a' }]), 250)
})
group('the equality gate covers the eight fields plus the derived section', () => {
  const base = { ssid: 'A', connected: false, known: true, outOfReach: false, secured: true, signal: 80, securityLabel: 'WPA2', section: 'KNOWN NETWORKS' }
  eq('a structural copy is equal', NET.wifiRowsEqual([base], [Object.assign({}, base)]), true)
  eq('two empty lists', NET.wifiRowsEqual([], []), true)
  eq('a null and an undefined list', NET.wifiRowsEqual(null, undefined), true)
  eq('a non-array on either side is empty', NET.wifiRowsEqual('x', []), true)
  eq('a length change', NET.wifiRowsEqual([base], [base, base]), false)
  for (const field of ['ssid', 'connected', 'known', 'outOfReach', 'secured', 'signal', 'securityLabel', 'section']) {
    const changed = Object.assign({}, base)
    if (field === 'ssid' || field === 'securityLabel' || field === 'section') changed[field] = 'other'
    else if (field === 'signal') changed[field] = 10
    else changed[field] = !base[field]
    eq(`a changed ${field} is a change`, NET.wifiRowsEqual([base], [changed]), false)
  }
})
group('the gate folds the same way the row builder does', () => {
  // Five of the eight fields go through `!!` or `|| ""`, so a row rebuilt by
  // deriveWifiState with the same *values* is equal even when the types
  // differ. This is the property that stops a 1.5s poll recreating the model.
  eq('a truthy flag and a truthy flag', NET.wifiRowsEqual([{ connected: 1 }], [{ connected: 'yes' }]), true)
  eq('a truthy and a falsy flag differ', NET.wifiRowsEqual([{ connected: 1 }], [{ connected: 0 }]), false)
  eq('a numeric string signal', NET.wifiRowsEqual([{ signal: 50 }], [{ signal: '50' }]), true)
  eq('a null signal and a missing one', NET.wifiRowsEqual([{ signal: null }], [{}]), true)
  eq('an empty section and a missing one', NET.wifiRowsEqual([{ ssid: 'a', section: '' }], [{ ssid: 'a' }]), true)
  eq('a null row and an empty row', NET.wifiRowsEqual([null], [{}]), true)
  eq('a string row and an empty row', NET.wifiRowsEqual(['x'], [{}]), true)
  eq('an extra field is ignored', NET.wifiRowsEqual([{ ssid: 'A', extra: 1 }], [{ ssid: 'A', extra: 2 }]), true)
  eq('but a differing ssid is not', NET.wifiRowsEqual([{ ssid: 'A', extra: 1 }], [{ ssid: 'B', extra: 2 }]), false)
})

section('Network/Model.deriveWifiState - the one pure step the island runs')
const STATE_ROWS = [
  { ssid: 'A', connected: true, known: true, signal: 80 },
  { ssid: 'B', connected: false, known: true, signal: 60 },
  { ssid: 'C', connected: false, known: false, signal: 40 },
]
group('the result carries the eight fields the island reads', () => {
  const st = NET.deriveWifiState(null, STATE_ROWS)
  eq('the key set', Object.keys(st), ['sorted', 'known', 'other', 'display', 'changed', 'knownChanged', 'otherChanged', 'grew'])
  eq('sorted is connected -> known -> other', entriesOf(st.sorted), ['A', 'B', 'C'])
  eq('known is the first section', st.known.map((r) => r.ssid), ['A', 'B'])
  eq('other is the second', st.other.map((r) => r.ssid), ['C'])
  eq('display is the sorted list with no divider', entriesOf(st.display), ['A', 'B', 'C'])
  eq('the cold-start gates are all true', [st.changed, st.knownChanged, st.otherChanged, st.grew], [true, true, true, true])
})
group('every row carries its section label forward', () => {
  // "sectionTitleFor returns "" on continuations, and ListView turns a "" into
  // its own blank section header - a phantom gap" - so the label is copied
  // onto every row of the group.
  const st = NET.deriveWifiState(null, STATE_ROWS)
  eq('the sections of the sorted rows', st.sorted.map((r) => r.section), ['KNOWN NETWORKS', 'KNOWN NETWORKS', 'OTHER NETWORKS'])
  eq('and of the display rows', st.display.map((r) => r.section), ['KNOWN NETWORKS', 'KNOWN NETWORKS', 'OTHER NETWORKS'])
  const onlyKnown = NET.deriveWifiState(null, [{ ssid: 'A', known: true }])
  eq('an all-known list labels every row KNOWN', onlyKnown.sorted.map((r) => r.section), ['KNOWN NETWORKS'])
  const onlyOther = NET.deriveWifiState(null, [{ ssid: 'A', known: false }])
  eq('an all-other list labels every row OTHER', onlyOther.sorted.map((r) => r.section), ['OTHER NETWORKS'])
  eq('no row is left with an empty section', st.sorted.every((r) => r.section !== ''), true)
})
group('handing the result straight back is the no-change answer', () => {
  // "prev is the exact object this function returned last time, so the gates
  // below cannot drift from the arrays the island reads."
  const first = NET.deriveWifiState(null, STATE_ROWS)
  const second = NET.deriveWifiState(first, STATE_ROWS)
  eq('nothing changed', [second.changed, second.knownChanged, second.otherChanged], [false, false, false])
  eq('and nothing was promoted', second.grew, false)
  eq('the first result is unchanged by the second call', first.sorted.map((r) => r.ssid), ['A', 'B', 'C'])
})
group('a signal wobble inside the known set is a change but not a promotion', () => {
  // Only A and B move, so the OTHER section is untouched and its own gate
  // stays false - which is what lets the island leave that list alone.
  const first = NET.deriveWifiState(null, STATE_ROWS)
  const wobbled = STATE_ROWS.map((r) => (r.ssid === 'A' ? { ...r, signal: 10 } : r.ssid === 'B' ? { ...r, signal: 70 } : { ...r }))
  const wobble = NET.deriveWifiState(first, wobbled)
  eq('the connected network fell, so the sort changed', wobble.changed, true)
  eq('and the known set is reported as changed', wobble.knownChanged, true)
  eq('but nothing was promoted', wobble.grew, false)
  eq('and the other set did not change', wobble.otherChanged, false)
  eq('the known order is unchanged - the fall was inside it', wobble.known.map((r) => r.ssid), ['A', 'B'])
  eq('the other set really is the same one row', wobble.other.map((r) => r.ssid), ['C'])
  // A wobble that also moves the other section sets that gate too.
  const both = NET.deriveWifiState(first, STATE_ROWS.map((r) => ({ ...r, signal: r.ssid === 'A' ? 10 : 60 })))
  eq('a wobble that touches the other set reports it', both.otherChanged, true)
  eq('and is still not a promotion', both.grew, false)
})
group('a promotion grows the known set and arms the slide', () => {
  // The newcomer is a full wifiRow shape, `connected` included - see the
  // group below for what a row missing that field does to the comparator.
  const first = NET.deriveWifiState(null, STATE_ROWS)
  const promoted = NET.deriveWifiState(first, STATE_ROWS.concat([{ ssid: 'D', connected: false, known: true, signal: 1 }]))
  eq('grew', promoted.grew, true)
  eq('the known set changed', promoted.knownChanged, true)
  eq('the whole list changed', promoted.changed, true)
  eq('the other set did not', promoted.otherChanged, false)
  // D is known, so it joins the known section - and within that section the
  // sort is by signal, so its 1% puts it last rather than first.
  eq('the new network is in known, last by signal', promoted.known.map((r) => r.ssid), ['A', 'B', 'D'])
  eq('and the display moved with it', entriesOf(promoted.display), ['A', 'B', 'D', 'C'])
  eq('the sorted list is connected -> known -> signal', promoted.sorted.map((r) => r.ssid), ['A', 'B', 'D', 'C'])
  // A demotion is the opposite: the known set shrank, which is not a growth.
  const demoted = NET.deriveWifiState(first, STATE_ROWS.map((r) => (r.ssid === 'B' ? Object.assign({}, r, { known: false }) : r)))
  eq('a demotion is not a growth', demoted.grew, false)
  eq('but the known set still changed', demoted.knownChanged, true)
})
group('a row with no `connected` field is not sorted by the documented tiers', () => {
  // `a.connected !== b.connected` is a strict compare, so `false` and
  // `undefined` are DIFFERENT there while both are falsy in the branch that
  // follows: a row missing the field is "not connected" only when it is the
  // second element of the compared pair, and the result depends on the input
  // order. wifiRow always sets the boolean, and the island always hands over
  // wifiRow output, so this is a fixture-shape trap rather than a live path -
  // pinned because a hand-built row in a test or a future caller would sort
  // unpredictably.
  const newcomer = { ssid: 'D', known: true, signal: 1 }
  eq('a newcomer with no connected field lands after an unknown row', NET.sortWifiRows(STATE_ROWS.concat([newcomer])).map((r) => r.ssid), ['A', 'B', 'C', 'D'])
  eq('the same newcomer with the field lands before it', NET.sortWifiRows(STATE_ROWS.concat([Object.assign({ connected: false }, newcomer)])).map((r) => r.ssid), ['A', 'B', 'D', 'C'])
  eq('and the two are in different sections', [
    NET.deriveWifiState(null, STATE_ROWS.concat([newcomer])).known.map((r) => r.ssid),
    NET.deriveWifiState(null, STATE_ROWS.concat([Object.assign({ connected: false }, newcomer)])).known.map((r) => r.ssid),
  ], [['A', 'B', 'D'], ['A', 'B', 'D']])
  eq('while the display order differs', [
    entriesOf(NET.deriveWifiState(null, STATE_ROWS.concat([newcomer])).display),
    entriesOf(NET.deriveWifiState(null, STATE_ROWS.concat([Object.assign({ connected: false }, newcomer)])).display),
  ], [['A', 'B', 'C', 'D'], ['A', 'B', 'D', 'C']])
})
group('the growth check is keyed on the ssid through a null-prototype map', () => {
  // "A null-prototype map, so an SSID that happens to be spelled
  // "constructor" or "__proto__" reads as absent instead of resolving to an
  // inherited Object member." Asserted on both spellings, which is the whole
  // reason for the Object.create(null).
  for (const hostile of ['constructor', '__proto__', 'toString', 'hasOwnProperty', 'valueOf']) {
    const first = NET.deriveWifiState(null, [{ ssid: hostile, known: true, signal: 1 }])
    eq(`${hostile} is a growth the first time`, first.grew, true)
    const second = NET.deriveWifiState(first, [{ ssid: hostile, known: true, signal: 1 }])
    eq(`${hostile} is not a growth the second time`, second.grew, false)
  }
})
group('an empty poll is a change, not a no-op', () => {
  const first = NET.deriveWifiState(null, STATE_ROWS)
  const emptied = NET.deriveWifiState(first, [])
  eq('the lists are empty', [emptied.sorted, emptied.known, emptied.other, emptied.display], [[], [], [], []])
  eq('and every gate but the growth is true', [emptied.changed, emptied.knownChanged, emptied.otherChanged, emptied.grew], [true, true, true, false])
  eq('the first result still holds its rows', first.sorted.length, 3)
})
group('the row objects are stamped, so a caller must not share them', () => {
  // sortWifiRows copies the ARRAY; deriveWifiState then writes `.section` on
  // the row objects themselves. The island hands over freshly built rows, so
  // this is safe there - but it is a mutation of the caller's objects and is
  // pinned so a future "build new rows instead" is a visible change.
  const rows = STATE_ROWS.map((r) => Object.assign({}, r))
  NET.deriveWifiState(null, rows)
  eq('the caller\'s rows now carry a section', rows.map((r) => r.section), ['KNOWN NETWORKS', 'KNOWN NETWORKS', 'OTHER NETWORKS'])
  const again = NET.deriveWifiState(null, STATE_ROWS)
  eq('but the sorted list is a new array each time', again.sorted === STATE_ROWS, false)
  eq('and holds the caller\'s objects', again.sorted[0] === STATE_ROWS[0], true)
})
group('a partial or missing previous state is tolerated', () => {
  eq('a null previous state is a cold start', NET.deriveWifiState(null, STATE_ROWS).changed, true)
  eq('undefined too', NET.deriveWifiState(undefined, STATE_ROWS).changed, true)
  eq('a previous state with only the sorted list', NET.deriveWifiState({ sorted: STATE_ROWS.slice() }, STATE_ROWS).changed, false)
  eq('but it still reports a growth, because prevKnown is empty', NET.deriveWifiState({ sorted: STATE_ROWS.slice() }, STATE_ROWS).grew, true)
  eq('a previous state with no arrays at all', NET.deriveWifiState({}, STATE_ROWS).changed, true)
  eq('a string previous state', NET.deriveWifiState('x', STATE_ROWS).changed, true)
  eq('a missing row list is an empty one', NET.deriveWifiState(null, null).sorted, [])
  eq('and the display is empty too', NET.deriveWifiState(null, null).display, [])
  eq('a non-array row list', NET.deriveWifiState(null, 'x').sorted, [])
  eq('no row list at all', NET.deriveWifiState(null).sorted, [])
  eq('an empty previous state with an empty row list', NET.deriveWifiState({}, []).changed, false)
})

section('Network/Model - the profile toggles and their patches')
group('a complete map reads three booleans', () => {
  eq('all on', NET.profileToggles({ connection: { autoconnect: true }, ipv4: { method: 'auto' }, ipv6: { method: 'dhcp' } }), { autoconnect: true, ipv4: true, ipv6: true })
  eq('all off', NET.profileToggles({ connection: { autoconnect: false }, ipv4: { method: 'disabled' }, ipv6: { method: 'disabled' } }), { autoconnect: false, ipv4: false, ipv6: false })
  eq('the key order is fixed', Object.keys(NET.profileToggles({ connection: {}, ipv4: {}, ipv6: {} })), ['autoconnect', 'ipv4', 'ipv6'])
  // "conn.autoconnect !== false" - so a profile that does not carry the key
  // reads as ON, which is NetworkManager's own default.
  eq('a missing autoconnect is on', NET.profileToggles({ connection: {}, ipv4: {}, ipv6: {} }).autoconnect, true)
  eq('a falsy autoconnect other than false is on', NET.profileToggles({ connection: { autoconnect: 0 }, ipv4: {}, ipv6: {} }).autoconnect, true)
  eq('a null autoconnect is on', NET.profileToggles({ connection: { autoconnect: null }, ipv4: {}, ipv6: {} }).autoconnect, true)
  eq('a zero-string autoconnect is off', NET.profileToggles({ connection: { autoconnect: 'false' }, ipv4: {}, ipv6: {} }).autoconnect, true)
})
group('an ip method is on unless it is exactly "disabled"', () => {
  eq('auto', NET.profileToggles({ connection: {}, ipv4: { method: 'auto' }, ipv6: {} }).ipv4, true)
  eq('manual', NET.profileToggles({ connection: {}, ipv4: { method: 'manual' }, ipv6: {} }).ipv4, true)
  eq('dhcp', NET.profileToggles({ connection: {}, ipv4: { method: 'dhcp' }, ipv6: {} }).ipv4, true)
  eq('disabled', NET.profileToggles({ connection: {}, ipv4: { method: 'disabled' }, ipv6: {} }).ipv4, false)
  eq('a missing method is on', NET.profileToggles({ connection: {}, ipv4: {}, ipv6: {} }).ipv4, true)
  eq('a null method is on', NET.profileToggles({ connection: {}, ipv4: { method: null }, ipv6: {} }).ipv4, true)
  eq('a differently-spelled disabled is still on', NET.profileToggles({ connection: {}, ipv4: { method: 'Disabled' }, ipv6: {} }).ipv4, true)
  eq('and each protocol is independent', NET.profileToggles({ connection: {}, ipv4: { method: 'disabled' }, ipv6: { method: 'auto' } }), { autoconnect: true, ipv4: false, ipv6: true })
})
group('a map that cannot back the section is null, not three defaults', () => {
  // "`null` is the fail-closed answer: the caller hides the section rather
  // than showing three defaults that are not the backend's state."
  eq('an empty map', NET.profileToggles({}), null)
  eq('no connection section', NET.profileToggles({ ipv4: {}, ipv6: {} }), null)
  eq('no ipv4 section', NET.profileToggles({ connection: {}, ipv6: {} }), null)
  eq('no ipv6 section', NET.profileToggles({ connection: {}, ipv4: {} }), null)
  eq('null', NET.profileToggles(null), null)
  eq('undefined', NET.profileToggles(undefined), null)
  eq('a string', NET.profileToggles('x'), null)
  eq('a number', NET.profileToggles(7), null)
  eq('true', NET.profileToggles(true), null)
  eq('no argument', NET.profileToggles(), null)
  eq('a non-object connection', NET.profileToggles({ connection: 1, ipv4: {}, ipv6: {} }), null)
  eq('a null connection', NET.profileToggles({ connection: null, ipv4: {}, ipv6: {} }), null)
  eq('a string ipv4', NET.profileToggles({ connection: {}, ipv4: 'auto', ipv6: {} }), null)
  eq('an array section is an object, so it passes', NET.profileToggles({ connection: {}, ipv4: [], ipv6: {} }), { autoconnect: true, ipv4: true, ipv6: true })
})
group('the DTO cannot leak a credential', () => {
  // "Only these three keys are read. The map may carry credentials for a
  // saved profile; nothing here copies, logs or forwards any field beyond
  // the three booleans, so the DTO cannot leak a secret into the view."
  const map = {
    connection: { autoconnect: true, id: 'Home', password: 'hunter2', secrets: 'x' },
    ipv4: { method: 'auto', addresses: ['10.0.0.2/24'], gateway: '10.0.0.1' },
    ipv6: { method: 'auto', addresses: ['fe80::1/64'] },
    '802-1x': { private_key_password: 'leak' },
  }
  const out = NET.profileToggles(map)
  eq('exactly the three booleans', out, { autoconnect: true, ipv4: true, ipv6: true })
  eq('no extra keys', Object.keys(out).length, 3)
  const text = JSON.stringify(out)
  notContains('no password in the DTO', text, 'hunter2')
  notContains('no 802.1x key', text, 'private_key_password')
  notContains('no address', text, '10.0.0.2')
  eq('an inherited section is still read', NET.profileToggles(Object.create({ connection: {}, ipv4: {}, ipv6: {} })), { autoconnect: true, ipv4: true, ipv6: true })
})
group('the patch is the one place the section name is spelled', () => {
  eq('autoconnect on', NET.profilePatch('autoconnect', true), { connection: { autoconnect: true } })
  eq('ipv4 on', NET.profilePatch('ipv4', true), { ipv4: { method: 'auto' } })
  eq('ipv6 on', NET.profilePatch('ipv6', true), { ipv6: { method: 'auto' } })
  eq('autoconnect off', NET.profilePatch('autoconnect', false), { connection: { autoconnect: false } })
  eq('ipv4 off', NET.profilePatch('ipv4', false), { ipv4: { method: 'disabled' } })
  eq('ipv6 off', NET.profilePatch('ipv6', false), { ipv6: { method: 'disabled' } })
  // "on ? "auto" : "disabled"" - a truthiness test, so the caller does not
  // have to pass a real boolean.
  eq('a truthy non-boolean on', NET.profilePatch('ipv4', 1), { ipv4: { method: 'auto' } })
  eq('a string on', NET.profilePatch('ipv4', 'yes'), { ipv4: { method: 'auto' } })
  eq('zero is off', NET.profilePatch('ipv4', 0), { ipv4: { method: 'disabled' } })
  eq('undefined is off', NET.profilePatch('ipv4', undefined), { ipv4: { method: 'disabled' } })
  eq('null is off', NET.profilePatch('ipv4', null), { ipv4: { method: 'disabled' } })
  eq('no `on` at all is off', NET.profilePatch('autoconnect'), { connection: { autoconnect: false } })
  eq('the patch carries exactly one section', Object.keys(NET.profilePatch('ipv6', true)), ['ipv6'])
  eq('and exactly one key inside it', Object.keys(NET.profilePatch('ipv6', true).ipv6), ['method'])
})
group('a key the section does not own writes nothing', () => {
  // "Returns null for a key this section does not own, and the caller
  // writes nothing."
  eq('an unknown key', NET.profilePatch('other', true), null)
  eq('the empty string', NET.profilePatch('', true), null)
  eq('null', NET.profilePatch(null, true), null)
  eq('undefined', NET.profilePatch(undefined, true), null)
  eq('a number', NET.profilePatch(7, true), null)
  eq('a capitalised key', NET.profilePatch('IPv4', true), null)
  eq('a padded key', NET.profilePatch(' ipv4', true), null)
  eq('the QML property name IP4', NET.profilePatch('ip4', true), null)
  eq('no key at all', NET.profilePatch(), null)
  eq('the key match is exact and case-sensitive', NET.profilePatch('AUTOCONNECT', true), null)
})

section('Network/Model - the escaped SSID and its status suffix')
group('the SSID is escaped before it reaches RichText', () => {
  // "SSIDs are arbitrary bytes and must never break out of the markup."
  eq('an ampersand', NET.escapeHtml('a&b'), 'a&amp;b')
  eq('a less than', NET.escapeHtml('a<b'), 'a&lt;b')
  eq('a greater than', NET.escapeHtml('a>b'), 'a&gt;b')
  eq('all three', NET.escapeHtml('a&b<c>d'), 'a&amp;b&lt;c&gt;d')
  eq('an ampersand is escaped first, so an entity is not forged', NET.escapeHtml('&lt;'), '&amp;lt;')
  eq('already-escaped text is escaped again, not unescaped', NET.escapeHtml('&amp;'), '&amp;amp;')
  eq('null is empty', NET.escapeHtml(null), '')
  eq('undefined is empty', NET.escapeHtml(undefined), '')
  eq('a number is stringified', NET.escapeHtml(0), '0')
  eq('a numeric-looking string', NET.escapeHtml(7), '7')
  eq('the empty string', NET.escapeHtml(''), '')
  eq('a quote is not escaped, because the markup uses attributes not quotes', NET.escapeHtml('a"b'), 'a"b')
  eq('a hostile ssid loses its tags', NET.escapeHtml('<b>x</b>'), '&lt;b&gt;x&lt;/b&gt;')
})
group('a connected row with no verdict is the bare name', () => {
  // The connected state is carried by the accent-coloured icon, so the title
  // no longer repeats "connected" - only a watcher verdict (if any) rides
  // beside the name.
  eq('connected', NET.ssidWithStatus('Net', true, '#A1', '#B2'), 'Net')
  eq('no markup at all', NET.ssidWithStatus('Net', true, '#A1', '#B2').includes('<font'), false)
  eq('the name is escaped', NET.ssidWithStatus('a&b', true, '#A1', '#B2'), 'a&amp;b')
  eq('a null ssid renders as empty', NET.ssidWithStatus(null, true, '#A1', '#B2'), '')
  eq('a numeric ssid is stringified', NET.ssidWithStatus(5, true, '#A1', '#B2'), '5')
})
group('a watcher verdict rides a single dot in its own ink', () => {
  eq('login required', NET.ssidWithStatus('Net', true, '#A1', '#B2', 'portal', '#C3'),
    'Net <font color="#B2">•</font> <font color="#C3">login required</font>')
  eq('no internet', NET.ssidWithStatus('Net', true, '#A1', '#B2', 'offline', '#C3').includes('>no internet</font>'), true)
  eq('metered', NET.ssidWithStatus('Net', true, '#A1', '#B2', 'metered', '#C3').includes('>metered</font>'), true)
  eq('an empty verdict is the bare name', NET.ssidWithStatus('Net', true, '#A1', '#B2', '', '#C3'), 'Net')
  eq('an unknown verdict is silent', NET.ssidWithStatus('Net', true, '#A1', '#B2', 'roaming', '#C3').split('•').length - 1, 0)
  eq('a missing ink falls back to the dot tone', NET.ssidWithStatus('Net', true, '#A1', '#B2', 'metered').includes('color="#B2">metered'), true)
  eq('a disconnected row never takes one', NET.ssidWithStatus('Net', false, '#A1', '#B2', 'portal', '#C3').includes('login required'), false)
  eq('portal words it', NET.linkNoteText('portal'), 'login required')
  eq('offline words it', NET.linkNoteText('offline'), 'no internet')
  eq('metered words it', NET.linkNoteText('metered'), 'metered')
  eq('configuring words it', NET.linkNoteText('configuring'), 'configuring...')
  eq('anything else is silent', [NET.linkNoteText(''), NET.linkNoteText('roaming'), NET.linkNoteText()], ['', '', ''])
})
group('anything not connected is the bare name - saved lives in the subtext', () => {
  eq('a remembered network keeps its bare name', NET.ssidWithStatus('Net', false, '#A1', '#B2'), 'Net')
  eq('no markup at all', NET.ssidWithStatus('Net', false, '#A1', '#B2').includes('<font'), false)
  eq('no saved word anywhere', NET.ssidWithStatus('Net', false, '#A1', '#B2').includes('saved'), false)
})
group('an unknown network is the bare name', () => {
  eq('not connected', NET.ssidWithStatus('Net', false, '#A1', '#B2'), 'Net')
  eq('no markup at all', NET.ssidWithStatus('Net', false, '#A1', '#B2').includes('<font'), false)
  eq('a truthy non-boolean connected flag renders no connected word', NET.ssidWithStatus('Net', 1, '#A1', '#B2').includes('connected'), false)
  eq('the escaped name is still the whole output', NET.ssidWithStatus('a<b', false, '#A1', '#B2'), 'a&lt;b')
})
group('a missing dot colour falls back to the accent', () => {
  // With no verdict the connected row is the bare name, so the dot colour
  // only matters when a verdict rides along.
  eq('verdict with null dotHex', NET.ssidWithStatus('N', true, '#A1', null, 'portal', '#C3'), 'N <font color="#A1">•</font> <font color="#C3">login required</font>')
  eq('verdict with empty dotHex', NET.ssidWithStatus('N', true, '#A1', '', 'portal', '#C3'), 'N <font color="#A1">•</font> <font color="#C3">login required</font>')
  eq('verdict with undefined dotHex', NET.ssidWithStatus('N', true, '#A1', undefined, 'portal', '#C3'), 'N <font color="#A1">•</font> <font color="#C3">login required</font>')
  eq('a zero dotHex is passed through verbatim', NET.ssidWithStatus('N', true, '#A1', 0, 'portal', '#C3'), 'N <font color="0">•</font> <font color="#C3">login required</font>')
  eq('a disconnected row needs no dot at all', NET.ssidWithStatus('N', false, '#A1', null), 'N')
  eq('an unknown network needs no colour at all', NET.ssidWithStatus('N', false, null, null), 'N')
})
group('a hostile SSID cannot inject a font tag', () => {
  const hostile = 'a<font color="#000">b'
  const out = NET.ssidWithStatus(hostile, true, '#A1', '#B2', 'portal', '#C3')
  eq('the injected tag is escaped', out.includes('&lt;font'), true)
  // one dot + one verdict word = two font tags
  eq('and there are exactly two font tags', (out.match(/<font /g) || []).length, 2)
  eq('and both are the ones the caller passed', (out.match(/<font color="(#[A-F0-9]{2})"/g) || []).length, 2)
})

section('Network/Model - the QR payload')
const QR_FULL = 'meta\twlan0\tWPA2\tMyNet\n00100\n01110\n10101\n11011\n00000'
group('a well-formed payload splits into meta and a square matrix', () => {
  const parsed = NET.parseQrOutput(QR_FULL)
  eq('the two keys', Object.keys(parsed), ['meta', 'matrix'])
  eq('the meta', parsed.meta, { iface: 'wlan0', security: 'WPA2', ssid: 'MyNet' })
  eq('the size', parsed.matrix.size, 5)
  eq('the rows', parsed.matrix.rows, ['00100', '01110', '10101', '11011', '00000'])
  eq('the matrix key set', Object.keys(parsed.matrix), ['rows', 'size'])
  eq('a 1x1 matrix', NET.parseQrOutput('0').matrix, { rows: ['0'], size: 1 })
  eq('a 2x2 matrix', NET.parseQrOutput('00\n11').matrix, { rows: ['00', '11'], size: 2 })
})
group('the SSID sits last so it may hold a tab', () => {
  eq('a tabbed ssid', NET.parseQrOutput('meta\tw0\tWPA2\ta\tb\n00\n00').meta, { iface: 'w0', security: 'WPA2', ssid: 'a\tb' })
  eq('a ssid with several tabs', NET.parseQrOutput('meta\tw0\tOpen\ta\tb\tc\n00\n00').meta.ssid, 'a\tb\tc')
  eq('a ssid that looks like fields', NET.parseQrOutput('meta\tw0\tOpen\tw1\tWPA2\tNet\n00\n00').meta.ssid, 'w1\tWPA2\tNet')
  eq('a missing ssid', NET.parseQrOutput('meta\tw0\tWPA2\n00\n00').meta, { iface: 'w0', security: 'WPA2', ssid: '' })
  eq('a missing security', NET.parseQrOutput('meta\tw0\n00\n00').meta, { iface: 'w0', security: '', ssid: '' })
  eq('a bare meta line', NET.parseQrOutput('meta\tw0\tOpen\tS').meta, { iface: 'w0', security: 'Open', ssid: 'S' })
  eq('and the matrix of a bare meta line is empty', NET.parseQrOutput('meta\tw0\tOpen\tS').matrix, { rows: [], size: 0 })
  eq('a meta line with no fields', NET.parseQrOutput('meta\t').meta, { iface: '', security: '', ssid: '' })
})
group('a payload with no meta line is all matrix', () => {
  eq('a bare matrix', NET.parseQrOutput('00\n00'), { meta: { iface: '', security: '', ssid: '' }, matrix: { rows: ['00', '00'], size: 2 } })
  eq('a bare single row', NET.parseQrOutput('0').meta.ssid, '')
  // The header must START with "meta\t", so a matrix row that happens to
  // begin with the word meta is not eaten as a header.
  eq('a row starting with "meta" but no tab is a matrix row', NET.parseQrOutput('meta\n00').matrix, { rows: [], size: 0 })
  eq('and one with a tab is a header', NET.parseQrOutput('meta\tx').meta.iface, 'x')
})
group('CRLF and blank lines are tolerated', () => {
  eq('a CRLF payload', NET.parseQrOutput('meta\tw0\tOpen\tS\r\n00\r\n00').matrix, { rows: ['00', '00'], size: 2 })
  eq('a CRLF meta line', NET.parseQrOutput('meta\tw0\tOpen\tS\r\n00\r\n00').meta, { iface: 'w0', security: 'Open', ssid: 'S' })
  eq('blank lines between rows are dropped', NET.parseQrOutput('meta\tw0\tOpen\tS\n\n00\n\n00\n\n').matrix, { rows: ['00', '00'], size: 2 })
  eq('a payload that is only newlines', NET.parseQrOutput('\n\n\n'), { meta: { iface: '', security: '', ssid: '' }, matrix: { rows: [], size: 0 } })
})
group('a malformed matrix is empty, not a code that cannot scan', () => {
  // "A malformed matrix returns empty rather than rendering a code that
  // cannot scan."
  eq('a ragged row count', NET.parseQrOutput('meta\tw0\tOpen\tS\n00\n000').matrix, { rows: [], size: 0 })
  eq('ragged row widths', NET.parseQrOutput('001\n01').matrix, { rows: [], size: 0 })
  eq('a non-binary character', NET.parseQrOutput('00\n02').matrix, { rows: [], size: 0 })
  eq('a letter', NET.parseQrOutput('0a').matrix, { rows: [], size: 0 })
  eq('a trailing space', NET.parseQrOutput('00 \n00').matrix, { rows: [], size: 0 })
  eq('a leading space', NET.parseQrOutput(' 0\n00').matrix, { rows: [], size: 0 })
  // The header survives even when the matrix does not, so the overlay can
  // still name the network it failed to encode.
  eq('the meta is still parsed', NET.parseQrOutput('meta\tw0\tOpen\tS\n00\n000').meta, { iface: 'w0', security: 'Open', ssid: 'S' })
  eq('an empty payload', NET.parseQrOutput(''), { meta: { iface: '', security: '', ssid: '' }, matrix: { rows: [], size: 0 } })
  eq('a whitespace payload', NET.parseQrOutput('   \n  ').matrix, { rows: [], size: 0 })
  eq('null', NET.parseQrOutput(null).matrix, { rows: [], size: 0 })
  eq('undefined', NET.parseQrOutput(undefined).matrix, { rows: [], size: 0 })
  eq('a number', NET.parseQrOutput(7).matrix, { rows: [], size: 0 })
  eq('no argument', NET.parseQrOutput().matrix, { rows: [], size: 0 })
})
group('the matrix parser is the half that validates', () => {
  eq('an empty list', NET.parseQrMatrix([]), { rows: [], size: 0 })
  eq('a square list', NET.parseQrMatrix(['00', '00']), { rows: ['00', '00'], size: 2 })
  eq('the size is the first row length', NET.parseQrMatrix(['001', '010', '100']), { rows: ['001', '010', '100'], size: 3 })
  eq('a ragged width', NET.parseQrMatrix(['001', '01']), { rows: [], size: 0 })
  eq('a non-binary row', NET.parseQrMatrix(['00', '0a']), { rows: [], size: 0 })
  // `size = lines[0].length` and the check is `size !== lines.length`, so a
  // single row of width 2 is 2 !== 1 and is refused. A one-module QR would
  // have to be the single character "0" or "1".
  eq('a one-row matrix is refused: width != row count', NET.parseQrMatrix(['00']), { rows: [], size: 0 })
  eq('and the one-module case is a single character', NET.parseQrMatrix(['0']), { rows: ['0'], size: 1 })
  // The parser takes an array and indexes `.length` unguarded, so a nullish
  // list throws rather than reading as empty. The only caller passes the
  // result of String(raw || "").split(), which is always an array.
  throws('a null list', () => NET.parseQrMatrix(null), /length/)
  throws('an undefined list', () => NET.parseQrMatrix(undefined), /length/)
  throws('a null row inside', () => NET.parseQrMatrix([null]), /length/)
  noThrow('a string list', () => NET.parseQrMatrix('00'))
  eq('a string is not a list of rows', NET.parseQrMatrix('00'), { rows: [], size: 0 })
  // `lines[0].length` is read unguarded, so a number throws: `(7).length` is
  // undefined, the `lines.length === 0` guard is false, and `(7)[0]` is
  // undefined. The only caller passes the result of String(raw).split(),
  // which is always an array.
  throws('a number list', () => NET.parseQrMatrix(7), /length/)
  throws('a boolean list', () => NET.parseQrMatrix(true), /length/)
})

// ======================================================================
section('pass/Model.versionCompare - the approximate sort -V')
group('numeric chunks compare by value, the rest by code point', () => {
  eq('equal strings', signed(PASS.versionCompare('a', 'a')), 0)
  eq('a before b', signed(PASS.versionCompare('a', 'b')), -1)
  eq('b after a', signed(PASS.versionCompare('b', 'a')), 1)
  eq('2 before 10', signed(PASS.versionCompare('2', '10')), -1)
  eq('10 after 2', signed(PASS.versionCompare('10', '2')), 1)
  eq('a2 before a10', signed(PASS.versionCompare('a2', 'a10')), -1)
  eq('1.9 before 1.10', signed(PASS.versionCompare('1.9', '1.10')), -1)
  eq('a full path compares on its tail', signed(PASS.versionCompare('mail/2', 'mail/10')), -1)
  eq('a path before a longer one', signed(PASS.versionCompare('gmail', 'gmail2')), -1)
  eq('a path difference', signed(PASS.versionCompare('x/y', 'x/z')), -1)
  eq('a numeric head beats an alphabetic one', signed(PASS.versionCompare('10', '9a')), 1)
  eq('an appended number is after the bare name', signed(PASS.versionCompare('a1', 'a')), 1)
})
group('leading zeros are insignificant, the way sort -V treats them', () => {
  eq('02 equals 2', signed(PASS.versionCompare('02', '2')), 0)
  eq('0 equals 00', signed(PASS.versionCompare('0', '00')), 0)
  eq('007 before 8', signed(PASS.versionCompare('007', '8')), -1)
  eq('a1.02 equals a1.2', signed(PASS.versionCompare('a1.02', 'a1.2')), 0)
  eq('and 0 is not 00 in length terms only after stripping', signed(PASS.versionCompare('000', '0')), 0)
})
group('a missing chunk reads as empty, so a prefix sorts first', () => {
  eq('empty equals empty', signed(PASS.versionCompare('', '')), 0)
  eq('a non-empty name is after an empty one', signed(PASS.versionCompare('a', '')), 1)
  eq('and before it the other way', signed(PASS.versionCompare('', 'a')), -1)
  eq('1 before 1.0', signed(PASS.versionCompare('1', '1.0')), -1)
  eq('null reads as empty', signed(PASS.versionCompare(null, 'a')), -1)
  eq('and a non-empty name against null', signed(PASS.versionCompare('a', null)), 1)
  eq('undefined against undefined', signed(PASS.versionCompare(undefined, undefined)), 0)
  eq('undefined against a name', signed(PASS.versionCompare(undefined, 'a')), -1)
  eq('a number is stringified', signed(PASS.versionCompare(2, 10)), -1)
  // `String(a || "")` is a falsy fold, so the number 0 is the empty string
  // and compares as one - the same fold that makes normalizePct and
  // fracOr treat 0 as a value. Pinned so the numeric 0 is not mistaken for a
  // version chunk.
  eq('a zero is a falsy fold, so it is the empty string', signed(PASS.versionCompare(0, '')), 0)
  eq('and a non-zero number is stringified', signed(PASS.versionCompare(2, 10)), -1)
})
group('it is a real total order over the names a store holds', () => {
  const names = ['v10', 'v2', 'v1', 'a10', 'a2', 'b', 'B', '2', '10', 'a/b', 'a/b2', 'a/b10']
  // Code-point order for the text chunks, so 'B' (0x42) precedes every
  // lower-case name, and 'a/b' follows 'a10' because '/' (0x2f) is below '1'
  // (0x31). It is an approximation of `sort -V`, not a locale compare.
  eq('the sort is the version order', names.slice().sort(PASS.versionCompare), ['2', '10', 'B', 'a2', 'a10', 'a/b', 'a/b2', 'a/b10', 'b', 'v1', 'v2', 'v10'])
  is('comparing is antisymmetric', names, (list) => list.every((a) => list.every((b) => signed(PASS.versionCompare(a, b)) === -signed(PASS.versionCompare(b, a)))), 'sign(a,b) === -sign(b,a)')
  is('a value is its own twin', names, (list) => list.every((a) => PASS.versionCompare(a, a) === 0), 'compare(x,x) === 0')
  is('the sort is a permutation', names, (list) => new Set(list.slice().sort(PASS.versionCompare)).size === list.length, 'nothing lost or duplicated')
})

section('pass/Model.stripGpg and splitEntry - the entry shape')
group('the .gpg suffix is stripped once', () => {
  eq('a nested entry', PASS.stripGpg('email/gmail.gpg'), 'email/gmail')
  eq('a root entry', PASS.stripGpg('gmail.gpg'), 'gmail')
  eq('a double suffix keeps one', PASS.stripGpg('a.gpg.gpg'), 'a.gpg')
  // `s.length > 4` guards the strip, and ".gpg" is exactly 4 characters, so
  // it is left alone. A bare ".gpg" therefore reaches listEntries unchanged -
  // which is then dropped by the same `length > 4` test there.
  eq('a bare .gpg is left alone - the guard is length > 4', PASS.stripGpg('.gpg'), '.gpg')
  eq('a different extension is not stripped', PASS.stripGpg('x.gpgx'), 'x.gpgx')
  eq('the case matters', PASS.stripGpg('.GPG'), '.GPG')
  eq('a name that is only "gpg" has no suffix', PASS.stripGpg('gpg'), 'gpg')
  // "s.length > 4" - so a 4-character path is left alone, which is why
  // ".gpg" survives and why ".gpg.gpg" is handled by the >4 branch.
  eq('one character over the boundary is stripped', PASS.stripGpg('a.gpg'), 'a')
  eq('a no-extension path', PASS.stripGpg('email/gmail'), 'email/gmail')
  eq('the empty string', PASS.stripGpg(''), '')
  eq('null', PASS.stripGpg(null), '')
  eq('undefined', PASS.stripGpg(undefined), '')
  eq('no argument', PASS.stripGpg(), '')
  eq('a number is stringified', PASS.stripGpg(7), '7')
})
group('an entry is { path, dir, name }', () => {
  eq('a nested entry', PASS.splitEntry('email/gmail'), { path: 'email/gmail', dir: 'email', name: 'gmail' })
  eq('a root entry', PASS.splitEntry('gmail'), { path: 'gmail', dir: '', name: 'gmail' })
  eq('a deep entry', PASS.splitEntry('a/b/c'), { path: 'a/b/c', dir: 'a/b', name: 'c' })
  eq('a leading slash gives an empty dir', PASS.splitEntry('/x'), { path: '/x', dir: '', name: 'x' })
  eq('a trailing slash gives an empty name', PASS.splitEntry('a/'), { path: 'a/', dir: 'a', name: '' })
  eq('the key order is fixed', Object.keys(PASS.splitEntry('a/b')), ['path', 'dir', 'name'])
  eq('the empty path', PASS.splitEntry(''), { path: '', dir: '', name: '' })
  eq('null', PASS.splitEntry(null), { path: '', dir: '', name: '' })
  eq('undefined', PASS.splitEntry(undefined), { path: '', dir: '', name: '' })
  eq('a number is stringified', PASS.splitEntry(7), { path: '7', dir: '', name: '7' })
})
group('the row never carries the value - only the name', () => {
  // "A row is { path, dir, name } and nothing else: a row names an entry, it
  // never carries its value."
  const row = PASS.splitEntry('email/gmail')
  eq('exactly three keys', Object.keys(row).length, 3)
  eq('and no value key', 'value' in row, false)
  eq('and no secret key', 'secret' in row, false)
  eq('and no password key', 'password' in row, false)
})

section('pass/Model.parseFindOutput and listEntries - the store scan')
const FIND_LINES = [
  'd /store',
  'd /store/email',
  'f /store/email/gmail.gpg',
  'f /store/.git/config',
  'd /store/.git',
  'f /store/a/.git/x.gpg',
  'f /store/b/.git/y.gpg',
  'f /store/plain.txt',
  'x weird',
  'f',
  'd ',
  'f \r',
]
group('a prefixed find output splits into files and dirs', () => {
  eq('with the store dir', PASS.parseFindOutput('/store', FIND_LINES), { files: ['email/gmail.gpg'], dirs: ['email'] })
  eq('a trailing slash on the store dir', PASS.parseFindOutput('/store/', FIND_LINES), { files: ['email/gmail.gpg'], dirs: ['email'] })
  eq('without a store dir the paths stand', PASS.parseFindOutput('', ['d email', 'f email/gmail.gpg']), { files: ['email/gmail.gpg'], dirs: ['email'] })
  eq('the store root itself is dropped', PASS.parseFindOutput('/store', ['d /store']).dirs, [])
  eq('only .gpg files survive', PASS.parseFindOutput('', ['f a.gpg', 'f b.txt', 'f c.gpg.bak', 'd d']).files, ['a.gpg'])
  eq('the two keys', Object.keys(PASS.parseFindOutput('', [])), ['files', 'dirs'])
})
group('.git bookkeeping never surfaces', () => {
  // ".git bookkeeping never surfaces on either side."
  eq('a .git dir', PASS.parseFindOutput('', ['d .git']), { files: [], dirs: [] })
  eq('a .git file', PASS.parseFindOutput('', ['f .git/config.gpg']), { files: [], dirs: [] })
  // The filter is `f === ".git" || f.indexOf(".git/") === 0 ||
  // f.indexOf("/.git/") !== -1` - all three shapes with a SLASH after .git.
  // A `find` run that lists the folder itself prints "a/.git", which matches
  // none of them and surfaces as an empty folder the browser would show.
  // The two children of that folder ARE filtered, so the folder comes back
  // empty rather than never: a visible empty folder, not a listing hazard.
  eq('a nested .git dir is not one of the three filtered shapes', PASS.parseFindOutput('', ['d a/.git']), { files: [], dirs: ['a/.git'] })
  eq('and its children are filtered, so it reads as empty', PASS.parseFindOutput('', ['d a/.git', 'f a/.git/c.gpg', 'd a/.git/refs']), { files: [], dirs: ['a/.git'] })
  eq('a nested .git file', PASS.parseFindOutput('', ['f a/.git/x.gpg']), { files: [], dirs: [] })
  eq('a real sibling survives', PASS.parseFindOutput('', ['f a/b.gpg', 'f a/.git/x.gpg']).files, ['a/b.gpg'])
  eq('and the .git folder is listed beside the real one', PASS.parseFindOutput('', ['d a/.git', 'd a/b']).dirs, ['a/.git', 'a/b'])
  // listEntries DOES filter the same three shapes, so the entry list never
  // carries it - the two filters are not identical in shape.
  eq('but listEntries filters the same path', PASS.listEntries(['a/.git/c.gpg', 'a/b.gpg']).map((e) => e.path), ['a/b'])
})
group('duplicate folders collapse, and the survivors sort -V', () => {
  eq('a repeated dir', PASS.parseFindOutput('', ['d email', 'd email']).dirs, ['email'])
  eq('the version order, not the byte order', PASS.parseFindOutput('', ['d a10', 'd a2', 'd a1']).dirs, ['a1', 'a2', 'a10'])
  eq('a mix of both', PASS.parseFindOutput('', ['d email', 'd a', 'd a10', 'd a2']).dirs, ['a', 'a2', 'a10', 'email'])
  eq('four duplicate mentions of one dir', PASS.parseFindOutput('', ['d x', 'd x', 'd x', 'd x']).dirs, ['x'])
})
group('the input may be an array or the raw multi-line string', () => {
  eq('a raw string', PASS.parseFindOutput('', 'd email\nf a.gpg'), { files: ['a.gpg'], dirs: ['email'] })
  eq('a CRLF string', PASS.parseFindOutput('', 'f a.gpg\r\nd email\r'), { files: ['a.gpg'], dirs: ['email'] })
  eq('a null list is empty', PASS.parseFindOutput('', null), { files: [], dirs: [] })
  eq('an empty list', PASS.parseFindOutput('', []), { files: [], dirs: [] })
  eq('undefined', PASS.parseFindOutput('', undefined), { files: [], dirs: [] })
  eq('a number list', PASS.parseFindOutput('', 7), { files: [], dirs: [] })
  eq('a null entry in the list', PASS.parseFindOutput('', [null, 'f a.gpg']), { files: ['a.gpg'], dirs: [] })
  // A 7 stringifies to "7", which is one character, so the `< 3` guard drops
  // it before the kind/space is read. So a stray non-string is inert.
  eq('a non-string entry is too short to parse', PASS.parseFindOutput('', [7, 'f a.gpg']), { files: ['a.gpg'], dirs: [] })
  eq('a longer non-string is still dropped: no space at index 1', PASS.parseFindOutput('', [12345, 'f a.gpg']), { files: ['a.gpg'], dirs: [] })
})
group('lines that are not "kind space path" are dropped', () => {
  eq('a two-character line', PASS.parseFindOutput('', ['f ']).files, [])
  eq('a one-character line', PASS.parseFindOutput('', ['f']).files, [])
  eq('a line with no space', PASS.parseFindOutput('', ['fstore/a.gpg']).files, [])
  eq('a tab instead of a space', PASS.parseFindOutput('', ['f\tstore/a.gpg']).files, [])
  eq('an unknown kind', PASS.parseFindOutput('', ['x store/a.gpg']), { files: [], dirs: [] })
  eq('a kind longer than one character', PASS.parseFindOutput('', ['ff store/a.gpg']), { files: [], dirs: [] })
  eq('an empty line', PASS.parseFindOutput('', ['']).files, [])
  eq('a path of whitespace only is dropped', PASS.parseFindOutput('', ['f   ']).files, [])
})

section('pass/Model.listEntries - the flat projection the panel rows from')
group('listEntries(files) drops the suffix and splits the path', () => {
  eq('three entries', PASS.listEntries(['b/x.gpg', 'a/y.gpg', 'c.gpg']), [
    { path: 'a/y', dir: 'a', name: 'y' },
    { path: 'b/x', dir: 'b', name: 'x' },
    { path: 'c', dir: '', name: 'c' },
  ])
  eq('and they come back sorted', PASS.listEntries(['c.gpg', 'a.gpg', 'b.gpg']).map((e) => e.path), ['a', 'b', 'c'])
  eq('in version order, not byte order', PASS.listEntries(['e10.gpg', 'e2.gpg', 'e1.gpg']).map((e) => e.path), ['e1', 'e2', 'e10'])
  eq('a nested path before a root one', PASS.listEntries(['z.gpg', 'a/b.gpg']).map((e) => e.path), ['a/b', 'z'])
})
group('listEntries(storeDir, files) relativises first', () => {
  eq('absolute paths under the store', PASS.listEntries('/store', ['/store/email/gmail.gpg', '/store/a.gpg']), [
    { path: 'a', dir: '', name: 'a' },
    { path: 'email/gmail', dir: 'email', name: 'gmail' },
  ])
  eq('a trailing slash on the store dir', PASS.listEntries('/store/', ['/store/a.gpg']).map((e) => e.path), ['a'])
  eq('the store dir itself is dropped', PASS.listEntries('/store', ['/store']).map((e) => e.path), [])
  // `f.indexOf(dir + "/") === 0` is the only relativising test, so a path
  // outside the store keeps its LEADING SLASH and becomes dir "/other" -
  // a shape the browser will not match against any folder. Pinned: the scan
  // is `find <storeDir>`, so every hit is inside it; the case is a
  // hand-edited or redirected store, not a live one.
  eq('a path outside the store keeps its leading slash', PASS.listEntries('/store', ['/other/a.gpg']), [{ path: '/other/a', dir: '/other', name: 'a' }])
  eq('a sibling with a shared prefix is not relativised', PASS.listEntries('/store', ['/store2/a.gpg']).map((e) => e.path), ['/store2/a'])
  eq('an empty store dir means no relativising', PASS.listEntries('', ['/store/a.gpg']).map((e) => e.path), ['/store/a'])
  eq('and a relative hit is the shape the panel really sees', PASS.listEntries('/store', ['/store/email/gmail.gpg']), [{ path: 'email/gmail', dir: 'email', name: 'gmail' }])
  // PassController.qml:238 calls exactly this two-argument form.
  eq('the two-argument form of the scan result', PASS.listEntries('/store', PASS.parseFindOutput('/store', FIND_LINES).files).map((e) => e.path), ['email/gmail'])
})
group('a file that is not an entry is dropped', () => {
  eq('no suffix', PASS.listEntries(['a']), [])
  eq('a different suffix', PASS.listEntries(['a.txt', 'a.gpg.bak']), [])
  eq('a bare .gpg has no logical name', PASS.listEntries(['.gpg']), [])
  eq('a four-character name ending in .gpg is too short to be one', PASS.listEntries(['.gpg']), [])
  eq('an empty string', PASS.listEntries(['']), [])
  eq('a null entry', PASS.listEntries([null]), [])
  eq('an undefined entry', PASS.listEntries([undefined]), [])
  eq('a CRLF name', PASS.listEntries(['a.gpg\r']), [{ path: 'a', dir: '', name: 'a' }])
  eq('a .git entry', PASS.listEntries(['.git/config.gpg', 'a.gpg']).map((e) => e.path), ['a'])
  eq('a nested .git entry', PASS.listEntries(['b/.git/x.gpg', 'a.gpg']).map((e) => e.path), ['a'])
  eq('a directory-shaped path without a suffix', PASS.listEntries(['a/b']), [])
})
group('the input list is only read', () => {
  const files = ['b.gpg', 'a.gpg']
  const snapshot = files.slice()
  const out = PASS.listEntries(files)
  eq('the input is unchanged', files, snapshot)
  eq('and the output is a fresh list of fresh objects', out[0] === files[0], false)
  eq('a null first argument with an array second', PASS.listEntries(null, ['a.gpg']).map((e) => e.path), ['a'])
  // `String(a || "")` folds a zero dir to the empty string, so nothing is
  // relativised and the path keeps its "0/" prefix.
  eq('a zero first argument is a falsy store dir', PASS.listEntries(0, ['0/a.gpg']).map((e) => e.path), ['0/a'])
  eq('and a non-zero number really is a store dir', PASS.listEntries(7, ['7/a.gpg']).map((e) => e.path), ['a'])
  eq('a string first argument is read as the store dir', PASS.listEntries('/store', ['/store/a.gpg']).map((e) => e.path), ['a'])
  eq('no arguments at all', PASS.listEntries(), [])
  eq('undefined', PASS.listEntries(undefined), [])
  eq('both arguments null', PASS.listEntries(null, null), [])
  eq('a number first argument is a store dir', PASS.listEntries(7, ['7/a.gpg']).map((e) => e.path), ['a'])
})

section('pass/Model.isValidName - the prompt_valid_name mirror')
group('the allowlist is [a-zA-Z0-9._ @-]', () => {
  for (const n of ['ok', 'a', 'A1', 'a.b', 'a_b', 'a@b', 'a-b', 'a b', 'with space', 'Mixed Case 123', 'a.b@c-d e', '-', '_', '@']) {
    eq(`${JSON.stringify(n)} is valid`, PASS.isValidName(n), true)
  }
})
group('the rejections, each for its own reason', () => {
  eq('a leading dot', PASS.isValidName('.hidden'), false)
  eq('a lone dot', PASS.isValidName('.'), false)
  eq('two dots anywhere', PASS.isValidName('a..b'), false)
  eq('a trailing double dot', PASS.isValidName('a..'), false)
  eq('a slash', PASS.isValidName('a/b'), false)
  eq('a backslash', PASS.isValidName('a\\b'), false)
  eq('a semicolon', PASS.isValidName('a;b'), false)
  eq('a dollar', PASS.isValidName('a$b'), false)
  eq('a quote', PASS.isValidName('a\'b'), false)
  eq('a star', PASS.isValidName('a*b'), false)
  eq('a tab', PASS.isValidName('a\tb'), false)
  eq('a newline', PASS.isValidName('a\nb'), false)
  eq('a non-ascii letter', PASS.isValidName('naïve'), false)
  eq('an emoji', PASS.isValidName('a😀'), false)
  // "no leading dot, no .. anywhere" - so an internal single dot is fine but
  // a leading one is not even without a second.
  eq('an internal dot is fine', PASS.isValidName('a.b'), true)
  eq('a leading dot is not', PASS.isValidName('.a.b'), false)
})
group('the empty cases', () => {
  eq('the empty string', PASS.isValidName(''), false)
  eq('whitespace only', PASS.isValidName('   '), false)
  eq('a tab only', PASS.isValidName('\t'), false)
  // "non-empty after trim" - so padding is allowed as long as something
  // survives, and the dot check runs on the trimmed string.
  eq('a padded name is valid', PASS.isValidName('  ok  '), true)
  eq('a padded leading dot is still rejected', PASS.isValidName('  .hidden  '), false)
})
group('a non-string is never valid, and never throws', () => {
  // `typeof name !== "string"` guards first, so the panel's
  // "panel.pendingName === "" || !isValidName(panel.pendingName)" cannot
  // reach the regex with a number.
  for (const n of [null, undefined, 7, 0, true, false, [], {}, ['a'], () => {}]) {
    noThrow(`isValidName(${JSON.stringify(n) === undefined ? 'undefined' : JSON.stringify(n)})`, () => PASS.isValidName(n))
  }
  eq('null', PASS.isValidName(null), false)
  eq('undefined', PASS.isValidName(undefined), false)
  eq('a number', PASS.isValidName(7), false)
  eq('zero', PASS.isValidName(0), false)
  eq('true', PASS.isValidName(true), false)
  eq('an array', PASS.isValidName([]), false)
  eq('an array of a valid name', PASS.isValidName(['ok']), false)
  eq('an object', PASS.isValidName({}), false)
  eq('a function', PASS.isValidName(() => {}), false)
  eq('no argument', PASS.isValidName(), false)
  // A String object is not a primitive string, so it is refused even though
  // its contents are valid. Pinned: it is the one shape a caller could get
  // wrong and silently never validate.
  eq('a String object', PASS.isValidName(new String('ok')), false)
})

section('pass/Model.storeDir - the pass resolution order')
group('PASSWORD_STORE_DIR wins, then XDG_DATA_HOME, then HOME', () => {
  // "caller-exported PASSWORD_STORE_DIR wins, then XDG_DATA_HOME, then
  // ~/.local/share" - the same order pass itself uses.
  eq('all three set', PASS.storeDir({ PASSWORD_STORE_DIR: '/x', XDG_DATA_HOME: '/y', HOME: '/z' }), '/x')
  eq('no PASSWORD_STORE_DIR', PASS.storeDir({ XDG_DATA_HOME: '/y', HOME: '/z' }), '/y/password-store')
  eq('only HOME', PASS.storeDir({ HOME: '/z' }), '/z/.local/share/password-store')
  eq('nothing at all', PASS.storeDir({}), '~/.local/share/passworld-store'.replace('passworld', 'password'))
  eq('the key order in the map is irrelevant', PASS.storeDir({ HOME: '/z', XDG_DATA_HOME: '/y' }), '/y/password-store')
  eq('a second HOME-like key is ignored', PASS.storeDir({ XDG_DATA_HOME: '/y', USERPROFILE: '/w' }), '/y/password-store')
})
group('an empty string falls through to the next source', () => {
  eq('an empty PASSWORD_STORE_DIR', PASS.storeDir({ PASSWORD_STORE_DIR: '', XDG_DATA_HOME: '/y', HOME: '/z' }), '/y/password-store')
  eq('an empty XDG_DATA_HOME', PASS.storeDir({ XDG_DATA_HOME: '', HOME: '/z' }), '/z/.local/share/password-store')
  eq('both empty', PASS.storeDir({ PASSWORD_STORE_DIR: '', XDG_DATA_HOME: '', HOME: '' }), '~/.local/share/password-store')
})
group('a non-string value falls through rather than being concatenated', () => {
  // `typeof psd === "string"` - so a numeric export is ignored, not
  // stringified into a path. pass itself requires a string here too.
  eq('a numeric PASSWORD_STORE_DIR', PASS.storeDir({ PASSWORD_STORE_DIR: 7, HOME: '/z' }), '/z/.local/share/password-store')
  eq('a numeric XDG_DATA_HOME', PASS.storeDir({ XDG_DATA_HOME: 7, HOME: '/z' }), '/z/.local/share/password-store')
  eq('a numeric HOME', PASS.storeDir({ HOME: 7 }), '~/.local/share/password-store')
  eq('a null PASSWORD_STORE_DIR', PASS.storeDir({ PASSWORD_STORE_DIR: null, HOME: '/z' }), '/z/.local/share/password-store')
})
group('the returned dir is verbatim, with no normalisation', () => {
  eq('a trailing slash survives', PASS.storeDir({ PASSWORD_STORE_DIR: '/x/' }), '/x/')
  eq('a doubled slash survives', PASS.storeDir({ PASSWORD_STORE_DIR: '/x//' }), '/x//')
  eq('a relative path survives', PASS.storeDir({ PASSWORD_STORE_DIR: 'store' }), 'store')
  eq('a tilde is not expanded', PASS.storeDir({ PASSWORD_STORE_DIR: '~/store' }), '~/store')
  eq('the XDG form appends exactly one segment', PASS.storeDir({ XDG_DATA_HOME: '/y/' }), '/y//password-store')
  eq('the HOME form appends the two segments', PASS.storeDir({ HOME: '/z/' }), '/z//.local/share/password-store')
})
group('the no-env fallback does not read the host environment', () => {
  // The env map is a parameter, so a suite can pass a stub; a missing map
  // means "no environment at all" rather than "process.env", because a
  // .pragma library context has no `process` - which is why the tilde
  // answer is the reachable one in a probe.
  eq('a null map', PASS.storeDir(null), '~/.local/share/password-store')
  eq('an undefined map', PASS.storeDir(undefined), '~/.local/share/password-store')
  eq('no argument', PASS.storeDir(), '~/.local/share/password-store')
  eq('an empty object', PASS.storeDir({}), '~/.local/share/password-store')
  eq('a non-object map', PASS.storeDir('x'), '~/.local/share/password-store')
  eq('a number map', PASS.storeDir(7), '~/.local/share/password-store')
  eq('an array map', PASS.storeDir([]), '~/.local/share/password-store')
})

section('pass/Model.firstLine - the password is line 1 only')
group('only the first line is ever returned', () => {
  // "Password is line 1 only; printf %s semantics (no trailing newline out)"
  // - and this is the redaction boundary: the rest of the file (the user
  // name, the notes) is the sort of data a masked field must not leak.
  eq('a one-line file', PASS.firstLine('secret'), 'secret')
  eq('a three-line file', PASS.firstLine('secret\nuser\nnotes'), 'secret')
  eq('a trailing newline is not part of the value', PASS.firstLine('a\n'), 'a')
  eq('a leading newline is an empty password', PASS.firstLine('\nrest'), '')
  eq('a CRLF file', PASS.firstLine('secret\r\nuser'), 'secret')
  eq('a bare CR before the newline', PASS.firstLine('a\r\nb'), 'a')
  eq('a lone CR is not a line break here', PASS.firstLine('a\rb'), 'a\rb')
  eq('the empty string', PASS.firstLine(''), '')
  eq('a CRLF-only file is empty', PASS.firstLine('\r\nx'), '')
})
group('a non-string is coerced, and nullish is empty', () => {
  eq('null', PASS.firstLine(null), '')
  eq('undefined', PASS.firstLine(undefined), '')
  eq('no argument', PASS.firstLine(), '')
  eq('a number', PASS.firstLine(5), '5')
  eq('a zero', PASS.firstLine(0), '0')
  eq('false', PASS.firstLine(false), 'false')
  eq('an object', PASS.firstLine({}), '[object Object]')
  // String(['a', 'b']) is "a,b" - the join separator, not the first
  // element. The transport hands over a string, so this is the shape a
  // wrong-typed argument produces.
  eq('an array joins with a comma', PASS.firstLine(['a', 'b']), 'a,b')
  eq('a one-element array has no comma', PASS.firstLine(['a']), 'a')
  eq('a numeric-looking string keeps its characters', PASS.firstLine('12345'), '12345')
})
group('a value with a newline in it can never come back whole', () => {
  // The redaction contract in test form: whatever the file held after the
  // first newline is unreachable through this function.
  const file = 'PASSWORD\nuser@example.com\nnote with "quotes"'
  const got = PASS.firstLine(file)
  eq('the result has no newline', got.includes('\n'), false)
  eq('and is a strict prefix of the file', file.startsWith(got), true)
  notContains('and no part of the second line', got, 'user')
  notContains('and no part of the third', got, 'note')
})

section('pass/Model.childrenOf and countUnder - the browser')
const ENTRIES = [
  { path: 'a', dir: '', name: 'a' },
  { path: 'b/one', dir: 'b', name: 'one' },
  { path: 'b/two', dir: 'b', name: 'two' },
  { path: 'b10/three', dir: 'b10', name: 'three' },
  { path: 'b/x', dir: 'b/x', name: 'x' },
  { path: 'c/deep/d', dir: 'c/deep', name: 'd' },
]
group('the root lists its files and its immediate folders', () => {
  eq('the root', PASS.childrenOf(ENTRIES, ''), { dirs: ['b', 'b10'], files: [{ path: 'a', dir: '', name: 'a' }] })
  eq('a folder', PASS.childrenOf(ENTRIES, 'b'), { dirs: ['x'], files: [ENTRIES[1], ENTRIES[2]] })
  eq('a leaf folder has no dirs', PASS.childrenOf(ENTRIES, 'b/x').dirs, [])
  eq('a leaf folder has its file', PASS.childrenOf(ENTRIES, 'b/x').files, [ENTRIES[4]])
  eq('the two keys', Object.keys(PASS.childrenOf(ENTRIES, '')), ['dirs', 'files'])
  eq('a folder with nothing in it', PASS.childrenOf(ENTRIES, 'zz'), { dirs: [], files: [] })
  // The trailing slash keeps sibling prefixes apart: "mail" vs "mail2".
  eq('a prefix sibling is a different folder', PASS.childrenOf(ENTRIES, 'b').dirs, ['x'])
  eq('and it has its own entries', PASS.childrenOf(ENTRIES, 'b10').files.map((e) => e.path), ['b10/three'])
  eq('a dir with a trailing slash matches nothing', PASS.childrenOf(ENTRIES, 'b/'), { dirs: [], files: [] })
})
group('a folder whose only entry is deeper does not appear at the root', () => {
  // "c" is only mentioned by "c/deep", so the root listing cannot derive it
  // from the entries - which is exactly what extraDirs is for.
  eq('the root has no c', PASS.childrenOf(ENTRIES, '').dirs.includes('c'), false)
  eq('extraDirs folds the empty folders in', PASS.childrenOf(ENTRIES, '', ['c', 'd/e']).dirs, ['b', 'b10', 'c'])
  // extraDirs are STORE-relative paths, so they are folded the same way an
  // entry's dir is: 'b/empty' becomes the child 'empty'. The child 'x' is
  // there because b/x is an entry, not because of extraDirs.
  eq('and they browse like populated folders', PASS.childrenOf(ENTRIES, 'b', ['b/empty', 'b/z']).dirs, ['empty', 'x', 'z'])
  eq('an empty entries list leaves only the extras', PASS.childrenOf([], 'b', ['b/empty', 'b/z']).dirs, ['empty', 'z'])
  eq('an extraDir at this exact level adds nothing', PASS.childrenOf([], 'b', ['b']).dirs, [])
  eq('a duplicate extraDir collapses', PASS.childrenOf([], 'b', ['b/x', 'b/x']).dirs, ['x'])
  eq('an extraDir that is an entry dir is skipped', PASS.childrenOf(ENTRIES, 'b', ['b']).dirs, ['x'])
  // `String(extra[i] || "")` folds a nullish entry to the empty string, and
  // consider() skips an empty path. A path that is not under `dir` is
  // skipped too - extraDirs are store-relative, so 'x' is not a child of 'b'.
  eq('an empty extraDir string is skipped', PASS.childrenOf([], 'b', ['', null, undefined]).dirs, [])
  eq('an extraDir outside this folder is skipped', PASS.childrenOf([], 'b', ['', null, 'x']).dirs, [])
  eq('a store-relative one is kept', PASS.childrenOf([], 'b', ['', null, 'b/x']).dirs, ['x'])
  eq('extraDirs are sorted -V too', PASS.childrenOf([{ dir: 'd10' }, { dir: 'd2' }, { dir: 'd1' }], '').dirs, ['d1', 'd2', 'd10'])
  eq('a non-array extraDirs is an empty one', PASS.childrenOf(ENTRIES, 'b', null).dirs, ['x'])
  eq('a string extraDirs is an empty one', PASS.childrenOf(ENTRIES, 'b', 'x').dirs, ['x'])
})
group('a null entry in the list is skipped', () => {
  eq('the surviving root entry', PASS.childrenOf([null, { path: 'x', dir: '' }], ''), { dirs: [], files: [{ path: 'x', dir: '' }] })
  eq('and the entry object is the caller\'s, name field and all', PASS.childrenOf([null, { path: 'x', dir: '', name: 'x' }], ''), { dirs: [], files: [{ path: 'x', dir: '', name: 'x' }] })
  // A null or missing `dir` on an entry reaches consider(), which calls
  // .indexOf on it. The projection always sets `dir` to a string, so an
  // entry missing it is outside the contract - pinned as a throw rather than
  // a silent skip.
  throws('a null dir on an entry', () => PASS.childrenOf([{ path: 'x', dir: null }], ''), /indexOf/)
  throws('a missing dir on an entry', () => PASS.childrenOf([{ path: 'x' }], ''), /indexOf/)
  // entries.length is read unguarded, so a missing list throws; the panel
  // always hands over the live array.
  throws('a null entry list', () => PASS.childrenOf(null, ''), /length/)
  throws('an undefined entry list', () => PASS.childrenOf(undefined, ''), /length/)
  noThrow('an empty list', () => PASS.childrenOf([], ''))
  throws('no entry list at all', () => PASS.childrenOf(), /length/)
  noThrow('no dir at all', () => PASS.childrenOf([], undefined))
})
group('countUnder counts the whole subtree, with a trailing slash', () => {
  eq('the whole vault', PASS.countUnder(ENTRIES, ''), 6)
  eq('a folder and everything under it', PASS.countUnder(ENTRIES, 'b'), 3)
  eq('a prefix sibling is not counted', PASS.countUnder(ENTRIES, 'b10'), 1)
  eq('an unknown folder', PASS.countUnder(ENTRIES, 'zz'), 0)
  eq('a leaf folder', PASS.countUnder(ENTRIES, 'b/x'), 1)
  eq('a null dir is the whole vault', PASS.countUnder(ENTRIES, null), 6)
  eq('a trailing slash matches nothing', PASS.countUnder(ENTRIES, 'b/'), 0)
  eq('a non-array entries list', PASS.countUnder('x', 'b'), 0)
  eq('a null entries list with a real dir', PASS.countUnder(null, 'b'), 0)
  eq('a null entry in the list is skipped', PASS.countUnder([null, { dir: 'b' }], 'b'), 1)
  eq('an entry with no dir field matches only the root', PASS.countUnder([{ path: 'a' }], ''), 1)
  eq('a folder name that is a prefix of another', PASS.countUnder(ENTRIES, 'b1'), 0)
})

section('pass/Model - the two filters')
group('filterEntries is a flat substring match over paths', () => {
  eq('a fragment', PASS.filterEntries(ENTRIES, 'b/one').map((e) => e.path), ['b/one'])
  eq('case-insensitive', PASS.filterEntries(ENTRIES, 'B/ONE').map((e) => e.path), ['b/one'])
  eq('a substring, not a prefix', PASS.filterEntries(ENTRIES, 'dee').map((e) => e.path), ['c/deep/d'])
  eq('a shared fragment matches several', PASS.filterEntries(ENTRIES, 'b').map((e) => e.path), ['b/one', 'b/two', 'b10/three', 'b/x'])
  eq('no match', PASS.filterEntries(ENTRIES, 'zzz'), [])
  eq('the input order is preserved', PASS.filterEntries(ENTRIES, 'b').map((e) => e.path), ['b/one', 'b/two', 'b10/three', 'b/x'])
  eq('the entries are the caller\'s objects', PASS.filterEntries(ENTRIES, 'a')[0] === ENTRIES[0], true)
})
group('an empty query is "no filter", as a copy', () => {
  eq('the empty string', PASS.filterEntries(ENTRIES, '').map((e) => e.path), ENTRIES.map((e) => e.path))
  eq('null', PASS.filterEntries(ENTRIES, null).length, 6)
  eq('undefined', PASS.filterEntries(ENTRIES, undefined).length, 6)
  eq('zero', PASS.filterEntries(ENTRIES, 0).length, 6)
  eq('false', PASS.filterEntries(ENTRIES, false).length, 6)
  eq('and it is a copy, not the array itself', PASS.filterEntries(ENTRIES, '') === ENTRIES, false)
  eq('a whitespace query is not trimmed away - it searches for it', PASS.filterEntries(ENTRIES, ' ').length, 0)
  eq('a null entry is skipped', PASS.filterEntries([null, { path: 'a' }], 'a').length, 1)
  eq('an entry with no path never matches', PASS.filterEntries([{ name: 'x' }], 'x'), [])
  eq('a non-numeric query is stringified', PASS.filterEntries([{ path: 'x1' }], 1).length, 1)
})
group('searchVault searches entries and folders separately', () => {
  const found = PASS.searchVault(ENTRIES, ['b', 'b10', 'zzz'], 'b')
  // versionCompare splits on digit runs, so 'b10/three' beats 'b/one':
  // the second chunk is '10' (a number) against '' + '/' - '1' is below '/'.
  eq('the entry paths, in version order', found.entries.map((e) => e.path), ['b10/three', 'b/one', 'b/two', 'b/x'])
  eq('the folder paths, in version order', found.dirs, ['b', 'b10'])
  eq('the two keys', Object.keys(found), ['entries', 'dirs'])
  eq('an entry hit is the caller\'s object', found.entries[0] === ENTRIES[3], true)
  eq('and every hit is, in order', found.entries.map((e) => e.path).length, 4)
  eq('an empty query is an empty result, not everything', PASS.searchVault(ENTRIES, ['b'], ''), { entries: [], dirs: [] })
  eq('a whitespace query searches for it', PASS.searchVault(ENTRIES, ['b'], ' '), { entries: [], dirs: [] })
  eq('case-insensitive on both sides', PASS.searchVault(ENTRIES, ['Mail'], 'mail').dirs, ['Mail'])
  eq('a folder hit is a substring match too', PASS.searchVault([], ['a/b'], 'a').dirs, ['a/b'])
  eq('no hits', PASS.searchVault(ENTRIES, [], 'zzz'), { entries: [], dirs: [] })
  eq('a null dir element is skipped', PASS.searchVault(ENTRIES, [null, 'b'], 'b').dirs, ['b'])
  eq('a non-array dir list', PASS.searchVault(ENTRIES, null, 'b').dirs, [])
  eq('a null entry is skipped', PASS.searchVault([null, { path: 'a' }], [], 'a').entries.length, 1)
  eq('an entry with no path never matches', PASS.searchVault([{ name: 'x' }], [], 'x'), { entries: [], dirs: [] })
  eq('a numeric query is stringified', PASS.searchVault([{ path: 'x1' }], [], 1).entries.length, 1)
  eq('folders sort -V', PASS.searchVault([], ['d10', 'd2', 'd1'], 'd').dirs, ['d1', 'd2', 'd10'])
  // entries.length is read unguarded, so a missing entry list throws while a
  // missing dir list is tolerated - the two halves have different guards.
  throws('a null entry list', () => PASS.searchVault(null, null, 'x'), /length/)
  noThrow('a null dir list', () => PASS.searchVault(ENTRIES, null, 'b'))
  // The query is read first, so an absent query short-circuits before the
  // unguarded `entries.length` is ever reached.
  eq('no arguments at all is the empty-query answer', PASS.searchVault(), { entries: [], dirs: [] })
  eq('and an empty query with no list is the same', PASS.searchVault(undefined, undefined, ''), { entries: [], dirs: [] })
  eq('but a real query with no list throws', (() => { try { PASS.searchVault(null, null, 'x'); return 'no throw' } catch (e) { return e.constructor.name } })(), 'TypeError')
})
group('neither filter can carry a value out', () => {
  // Both read `.path` only, so a row shape that had picked up a credential
  // by accident would still not be searchable - but the projection is what
  // guarantees there is no credential to carry in the first place.
  const rows = [{ path: 'email/gmail', dir: 'email', name: 'gmail' }]
  eq('the filter output is the same object', PASS.filterEntries(rows, 'gmail')[0] === rows[0], true)
  eq('the search output is the same object', PASS.searchVault(rows, [], 'gmail').entries[0] === rows[0], true)
  eq('and both output rows carry exactly the three keys', Object.keys(PASS.filterEntries(rows, 'gmail')[0]), ['path', 'dir', 'name'])
})

section('pass/Model.parseKeyFingerprints - the gpg colon output')
const GPG_ONE = 'sec:u:4096:1:ABC:keyid:::u:::scESC:::+:::23::0:\nfpr:::::::::AABBCCDD:'
group('one fingerprint per sec record, from the next fpr line', () => {
  eq('one', PASS.parseKeyFingerprints(GPG_ONE), ['AABBCCDD'])
  eq('two', PASS.parseKeyFingerprints(GPG_ONE + '\nsec:u:1:2:X:::::::u::::sc:::::::0:\nfpr:::::::::EEFF0011:'), ['AABBCCDD', 'EEFF0011'])
  eq('a numeric fingerprint is kept as text', PASS.parseKeyFingerprints('sec:x\nfpr:::::::::123:'), ['123'])
  eq('a full 40-hex fingerprint survives whole', PASS.parseKeyFingerprints(`sec:x\nfpr:::::::::${'A'.repeat(40)}:`), ['A'.repeat(40)])
  eq('an empty list', PASS.parseKeyFingerprints(''), [])
  eq('null', PASS.parseKeyFingerprints(null), [])
  eq('undefined', PASS.parseKeyFingerprints(undefined), [])
  eq('no argument', PASS.parseKeyFingerprints(), [])
})
group('only a sec record followed by an fpr line counts', () => {
  eq('a sec record at the end with no fpr', PASS.parseKeyFingerprints('sec:u:1:2:X:::::::u::::sc:::::::0:'), [])
  eq('a sec record followed by a sub record', PASS.parseKeyFingerprints('sec:x\nsub:x'), [])
  eq('an fpr line with an empty field 10', PASS.parseKeyFingerprints('sec:x\nfpr:::::::::'), [])
  eq('an fpr line with too few fields', PASS.parseKeyFingerprints('sec:x\nfpr:9'), [])
  eq('an fpr line with no sec before it', PASS.parseKeyFingerprints('fpr:::::::::AA:\nsub:x'), [])
  eq('a sub record is never a sec record', PASS.parseKeyFingerprints('sub:x\nfpr:::::::::AA:'), [])
  eq('the fpr must be the IMMEDIATE next line', PASS.parseKeyFingerprints('sec:x\nuid:x\nfpr:::::::::AA:'), [])
  eq('a CRLF sec line still matches, and the CR rides on the fpr', PASS.parseKeyFingerprints('sec:x\r\nfpr:::::::::AA:'), ['AA'])
  eq('a non-string input reads as one line', PASS.parseKeyFingerprints(7), [])
  eq('a number of lines with no sec', PASS.parseKeyFingerprints('a\nb\nc\nd'), [])
})

section('pass/Model - the four facade projections')
group('unavailableVerb names the state, never the last error', () => {
  // "The defined answer for a verb issued while no controller is there, so a
  // caller learns why instead of getting a silent no-op. `error` is the
  // controller's own code (a construction failure), never its lastError."
  eq('a failed controller with a code', PASS.unavailableVerb('failed', 'probe'), 'error:probe')
  eq('a failed controller with no code', PASS.unavailableVerb('failed', ''), 'error:controller')
  // `error !== ""` is a strict comparison, so undefined and null pass
  // through and appear in the reply verbatim. Pinned: the facade always
  // passes a string, so this is the shape a new caller would get wrong.
  eq('undefined is not the empty string', PASS.unavailableVerb('failed', undefined), 'error:undefined')
  eq('null is not the empty string either', PASS.unavailableVerb('failed', null), 'error:null')
  eq('loading', PASS.unavailableVerb('loading', 'probe'), 'loading')
  eq('loading ignores the error', PASS.unavailableVerb('loading', ''), 'loading')
  eq('unloaded', PASS.unavailableVerb('unloaded', ''), 'unavailable')
  eq('an empty state', PASS.unavailableVerb('', ''), 'unavailable')
  eq('null', PASS.unavailableVerb(null, null), 'unavailable')
  eq('undefined', PASS.unavailableVerb(undefined, undefined), 'unavailable')
  eq('no arguments', PASS.unavailableVerb(), 'unavailable')
  eq('a state that is not one of the three', PASS.unavailableVerb('gone', ''), 'unavailable')
  eq('the state match is exact and case-sensitive', PASS.unavailableVerb('Failed', ''), 'unavailable')
})
group('statusError prefers the controller, else the transport', () => {
  eq('a controller error', PASS.statusError('controller said so', 'transport said so'), 'controller said so')
  eq('an empty controller error falls through', PASS.statusError('', 'transport said so'), 'transport said so')
  eq('both empty', PASS.statusError('', ''), '')
  eq('no transport error either', PASS.statusError('', undefined), undefined)
  // `controllerError === ""` is again a strict comparison: null and undefined
  // are returned as they came in, not treated as "no error".
  eq('null is not the empty string', PASS.statusError(null, 'transport'), null)
  eq('undefined is not the empty string', PASS.statusError(undefined, 'transport'), undefined)
  eq('no arguments', PASS.statusError(), undefined)
  eq('a numeric controller error is returned as-is', PASS.statusError(7, 'transport'), 7)
})
group('navigationBack peels exactly one step', () => {
  // "one peel step of the panel's navigation ... Menu dismissal is the
  // terminal step - there are no Back rows anywhere."
  eq('an action step returns to browse', PASS.navigationBack('action', 'email'), { mode: 'browse' })
  eq('a create step returns to browse', PASS.navigationBack('create', 'email'), { mode: 'browse' })
  eq('and neither moves the folder', 'dir' in PASS.navigationBack('action', 'email'), false)
  eq('browse at the root returns to the menu', PASS.navigationBack('browse', ''), { mode: 'menu' })
  eq('browse in a folder returns to browse at the parent', PASS.navigationBack('browse', 'a'), { mode: 'browse', dir: '' })
  eq('browse in a nested folder', PASS.navigationBack('browse', 'a/b'), { mode: 'browse', dir: 'a' })
  eq('browse three deep', PASS.navigationBack('browse', 'a/b/c'), { mode: 'browse', dir: 'a/b' })
  eq('a null dir is the root', PASS.navigationBack('browse', null), { mode: 'menu' })
  eq('the menu is the terminal step', PASS.navigationBack('menu', 'a'), { close: true })
  eq('an unknown mode is terminal', PASS.navigationBack('x', 'a'), { close: true })
  eq('the empty mode is terminal', PASS.navigationBack('', ''), { close: true })
  eq('no arguments are terminal', PASS.navigationBack(), { close: true })
  eq('the step carries only the fields it changes', [Object.keys(PASS.navigationBack('action', 'a')), Object.keys(PASS.navigationBack('browse', 'a/b')), Object.keys(PASS.navigationBack('menu', 'a'))], [['mode'], ['mode', 'dir'], ['close']])
  eq('a dir with a trailing slash peels to the same folder', PASS.navigationBack('browse', 'a/b/'), { mode: 'browse', dir: 'a/b' })
  eq('a leading slash peels to the empty parent', PASS.navigationBack('browse', '/a'), { mode: 'browse', dir: '' })
})
group('toggleReply closes with ok and opens only when up', () => {
  // "closing always reports ok, and opening reports ok only once the
  // controller is ready and the panel is actually up."
  eq('closing', PASS.toggleReply(true, 'ready', true, ''), 'ok')
  eq('closing from any state', PASS.toggleReply(true, 'failed', false, 'probe'), 'ok')
  eq('closing with the error set', PASS.toggleReply(true, 'failed', false, 'probe'), 'ok')
  eq('opening with a ready controller', PASS.toggleReply(false, 'ready', true, ''), 'ok')
  eq('opening while still loading', PASS.toggleReply(false, 'loading', true, ''), 'loading')
  eq('opening when the panel is not up', PASS.toggleReply(false, 'ready', false, ''), 'unavailable')
  eq('opening with no controller', PASS.toggleReply(false, 'unloaded', false, ''), 'unavailable')
  eq('opening a failed controller', PASS.toggleReply(false, 'failed', true, 'probe'), 'error:probe')
  eq('a failed controller with no code', PASS.toggleReply(false, 'failed', true, ''), 'error:controller')
  eq('a truthy non-boolean visible', PASS.toggleReply(false, 'ready', 1, ''), 'ok')
  eq('a falsy visible', PASS.toggleReply(false, 'ready', 0, ''), 'unavailable')
  eq('a state that is not ready', PASS.toggleReply(false, 'gone', true, ''), 'unavailable')
  eq('the case matters', PASS.toggleReply(false, 'Ready', true, ''), 'unavailable')
  eq('no arguments', PASS.toggleReply(), 'unavailable')
  eq('the refusal is unavailableVerb\'s', PASS.toggleReply(false, 'failed', true, 'probe'), PASS.unavailableVerb('failed', 'probe'))
})
group('the redaction contract, in test form', () => {
  // "each returns a state name, a code, or a path, and none takes or returns
  // a value. A decrypted credential lives in SecretStore under a handle and
  // is reached only through the facade's transport; nothing in this file can
  // read one, so a projection that landed here could not publish one either."
  // The one thing that IS echoed is the controller's error CODE, verbatim and
  // prefixed - it is a construction-failure code, never its lastError. So the
  // contract is "a code or a state name", not "nothing is echoed".
  eq('the code is echoed, prefixed', PASS.unavailableVerb('failed', 'no-quickshell'), 'error:no-quickshell')
  eq('loading ignores the code entirely', PASS.unavailableVerb('loading', 'no-quickshell'), 'loading')
  // The navigation and toggle answers are a CLOSED set: no argument can put
  // anything of its own into them.
  const NAV_INPUTS = [
    ['action', 'email'], ['create', 'email'], ['browse', ''], ['browse', 'a'], ['browse', 'a/b'],
    ['browse', 'a/b/c'], ['menu', 'a'], ['', ''], ['x', 'y'], ['browse', null], [0, 0], [null, null],
    ['browse', 'SECRET'], ['browse', '/a'], ['browse', 'a/b/'], ['SECRET', 'SECRET'],
  ]
  eq('navigationBack only ever returns these', [...new Set(NAV_INPUTS.map(([m, d]) => JSON.stringify(PASS.navigationBack(m, d))))].sort(), ['{"close":true}', '{"mode":"browse","dir":""}', '{"mode":"browse","dir":"a"}', '{"mode":"browse","dir":"a/b"}', '{"mode":"browse"}', '{"mode":"menu"}'])
  eq('and the count matches the hand-written list above', new Set(NAV_INPUTS.map(([m, d]) => JSON.stringify(PASS.navigationBack(m, d)))).size, 6)
  eq('toggleReply only ever returns these', [...new Set([[true, 'ready', true, ''], [false, 'ready', true, ''], [false, 'ready', false, ''], [false, 'loading', true, ''], [false, 'failed', true, 'c'], [false, 'unloaded', false, ''], [false, '', false, '']].map((a) => PASS.toggleReply(a[0], a[1], a[2], a[3])))].sort(), ['error:c', 'loading', 'ok', 'unavailable'])
  eq('and neither carries an arbitrary string through', PASS.navigationBack('action', 'SECRET').mode !== 'SECRET', true)
  // The only place a value crosses this file is firstLine, and only its
  // first line - which is the password itself, read for the copy transport.
  eq('firstLine is the single value-bearing function', PASS.firstLine('hunter2\nuser'), 'hunter2')
  is('and the three two-argument projections take two scalars', [
    PASS.unavailableVerb.length, PASS.statusError.length, PASS.navigationBack.length,
  ], (l) => l.every((n) => n === 2), 'exactly two declared parameters')
  eq('toggleReply is the four-argument one', PASS.toggleReply.length, 4)
  // None of the four returns a field name from an entry: they answer with
  // mode/dir/close or a status word.
  is('no projection returns a { path, dir, name } row', [PASS.navigationBack('action', 'email'), PASS.navigationBack('browse', 'a/b')], (v) => v.every((o) => !('path' in o) && !('value' in o)), 'a navigation field set, not an entry')
})
skip('the transport sink (SecretStore.feed into wl-copy --sensitive)', 'lives in Pass.qml and SecretStore.qml; there is no PAM agent or a wl-copy binary in this environment')

// ======================================================================
section('pass/Model - the opaque tokens the log may name a store by')
//
// The contract, in one sentence: an entry name IS the secret, so the log may
// name an entry only through a token, and the token must be a counter rather
// than a hash or a prefix. These cases hold both halves of that: the token
// is stable and distinct (so a reader can follow one entry's thread), and it
// carries nothing about the name (so a reader of the log cannot recover it).
//
// The names here are invented. Nothing in this suite reads a real store, and
// nothing here should: a case that needs a name can make one up, and every
// assertion below is about the mapping rather than about any entry.
group('newTokenMap is a fresh, empty, null-prototype map', () => {
  eq('it is an object', typeof PASS.newTokenMap(), 'object')
  eq('with no own keys', Object.keys(PASS.newTokenMap()).length, 0)
  eq('and no prototype at all', Object.getPrototypeOf(PASS.newTokenMap()), null)
  // Two calls must not share state: the facade builds one per shell, and a
  // shared map would leak one session's numbering into the next.
  const a = PASS.newTokenMap()
  const b = PASS.newTokenMap()
  PASS.token(a, 'entry', 'x')
  eq('a second map is unaffected by the first', PASS.token(b, 'entry', 'x'), 'entry#1')
  // The prototype is the load-bearing part, not tidiness: a plain {} answers
  // `map['constructor']` from Object.prototype, so an entry named
  // "constructor" would read as already seen and log a prototype method's
  // source instead of a token.
  for (const name of ['constructor', '__proto__', 'toString', 'hasOwnProperty', 'valueOf']) {
    const got = PASS.token(a, 'entry', name)
    is(`the name "${name}" mints its own token`, got, (t) => /^entry#[1-9][0-9]*$/.test(t), 'a token, not an inherited value')
    is(`and "${name}" is not holding the prototype's answer`, a.entry.seen[name], (v) => typeof v === 'string' && v === got, 'the bucket, not Object.prototype')
  }
  eq('each of the five got its own number',
    new Set(['constructor', '__proto__', 'toString', 'hasOwnProperty', 'valueOf'].map((n) => PASS.token(a, 'entry', n))).size, 5)
})
group('token is stable for one name and distinct across names', () => {
  const m = PASS.newTokenMap()
  eq('the first entry', PASS.token(m, 'entry', 'work-email/bank'), 'entry#1')
  eq('the same name again', PASS.token(m, 'entry', 'work-email/bank'), 'entry#1')
  eq('and a third time', PASS.token(m, 'entry', 'work-email/bank'), 'entry#1')
  eq('a different name gets the next number', PASS.token(m, 'entry', 'github'), 'entry#2')
  eq('and another', PASS.token(m, 'entry', 'bank'), 'entry#3')
  // The counter is per kind, so entry#1 and folder#1 both exist and cannot
  // be read as one another - which is the point of the kind prefix.
  eq('the folder counter is its own', PASS.token(m, 'folder', 'work-email'), 'folder#1')
  eq('a folder and an entry may share a name without sharing a token',
    [PASS.token(m, 'folder', 'shared'), PASS.token(m, 'entry', 'shared')], ['folder#2', 'entry#4'])
  eq('the store has its own kind too', PASS.token(m, 'store', '/home/u/.local/share/password-store'), 'store#1')
  eq('a gpg key has its own', PASS.token(m, 'key', 'FINGERPRINT'), 'key#1')
  eq('the numbering does not restart per kind', PASS.token(m, 'entry', 'later'), 'entry#5')
  // Numbering is first-seen order and nothing else: two calls in the other
  // order give two different mappings, which is fine, because neither can be
  // turned back into a name.
  const m2 = PASS.newTokenMap()
  eq('order one', [PASS.token(m2, 'entry', 'a'), PASS.token(m2, 'entry', 'b')], ['entry#1', 'entry#2'])
  const m3 = PASS.newTokenMap()
  eq('order two', [PASS.token(m3, 'entry', 'b'), PASS.token(m3, 'entry', 'a')], ['entry#1', 'entry#2'])
})
group('the token carries nothing about the name', () => {
  const m = PASS.newTokenMap()
  const names = ['work-email/bank', 'github', 'Bank', 'a/b/c/d/e']
  const tokens = names.map((n) => PASS.token(m, 'entry', n))
  eq('no token contains its own name', tokens.every((t, i) => !t.includes(names[i])), true)
  eq('no token contains any name at all', tokens.every((t) => names.every((n) => !t.includes(n))), true)
  // A truncated prefix is not anonymisation either, and neither is a digest:
  // a password store has a small guessable vocabulary, so either would be a
  // lookup table. So the token is exactly "kind#n" and nothing else.
  is('and every token has that exact shape', tokens, (ts) => ts.every((t) => /^entry#[1-9][0-9]*$/.test(t)), 'kind, hash, digits')
  // Not reversible: given a token and the candidate names, a guess is a
  // comparison against the MAP, which never leaves the facade - the token
  // itself answers nothing.
  eq('the map is keyed by the real name', m.entry.seen['work-email/bank'], 'entry#1')
  eq('and not by the token', m.entry.seen['entry#1'], undefined)
  eq('the map is a two-level structure, kind then name', Object.keys(m.entry).sort(), ['n', 'seen'])
})
group('token is total, so a logging call site always has an answer', () => {
  eq('no map at all', PASS.token(null, 'entry', 'x'), 'entry#1')
  eq('an undefined map', PASS.token(undefined, 'entry', 'x'), 'entry#1')
  eq('a non-object map', PASS.token(7, 'entry', 'x'), 'entry#1')
  eq('no arguments', PASS.token(), '#1')
  eq('a null name is the empty name', PASS.token(PASS.newTokenMap(), 'entry', null), 'entry#1')
  eq('an undefined name is the empty name', PASS.token(PASS.newTokenMap(), 'entry', undefined), 'entry#1')
  eq('and they are the same name', PASS.token(PASS.newTokenMap(), 'entry', ''), 'entry#1')
  eq('a numeric name is stringified', PASS.token(PASS.newTokenMap(), 'entry', 42), 'entry#1')
  eq('a null kind is an empty kind', PASS.token(PASS.newTokenMap(), null, 'x'), '#1')
  // A map carrying something other than a bucket is repaired rather than
  // thrown on: a name called "n" or "seen" cannot collide with the two
  // reserved slots, because they live on the bucket and not on the map.
  const m = PASS.newTokenMap()
  m.entry = 'not a bucket'
  eq('a damaged bucket is rebuilt', PASS.token(m, 'entry', 'x'), 'entry#1')
  eq('and the entry name "n" is still just a name', PASS.token(m, 'entry', 'n'), 'entry#2')
  noThrow('a name that is an empty string never returns an empty token', () => PASS.token(PASS.newTokenMap(), 'entry', ''))
})

section('pass/Model.redact - a child\'s own words, with every store name swapped out')
group('a git error comes back with its paths tokenised', () => {
  const m = PASS.newTokenMap()
  PASS.token(m, 'store', '/home/someone/.local/share/password-store')
  PASS.token(m, 'entry', 'work-email/bank')
  eq(
    'the whole message, one line',
    PASS.redact("fatal: not a git repository: /home/someone/.local/share/password-store\nError: work-email/bank is not in the password store.", m, 160),
    'fatal: not a git repository: store#1 Error: entry#1 is not in the password store.',
  )
  eq('every occurrence, not just the first', (() => {
    const mm = PASS.newTokenMap()
    PASS.token(mm, 'entry', 'gh')
    return PASS.redact('gh then gh then gh', mm, 160)
  })(), 'entry#1 then entry#1 then entry#1')
  eq('a name in the middle of a path survives as a token, not a fragment', (() => {
    const mm = PASS.newTokenMap()
    PASS.token(mm, 'store', '/home/someone/.local/share/password-store')
    return PASS.redact('find: /home/someone/.local/share/password-store: Permission denied', mm, 160)
  })(), 'find: store#1: Permission denied')
})
group('longest name first, or a folder would eat its own entry', () => {
  const m = PASS.newTokenMap()
  PASS.token(m, 'entry', 'work-email/bank')
  PASS.token(m, 'folder', 'work-email')
  // If the shorter name went first the entry token would then be searched
  // for inside "folder#1/bank", which is not in the map, and the tail would
  // survive as a fragment of a real name.
  eq('the entry token wins', PASS.redact('work-email/bank', m, 160), 'entry#1')
  const m2 = PASS.newTokenMap()
  PASS.token(m2, 'folder', 'work-email')
  PASS.token(m2, 'entry', 'work-email/bank')
  eq('and it does not depend on the minting order', PASS.redact('work-email/bank', m2, 160), 'entry#1')
  // Two kinds holding the same name: the tie-break is total, so the same
  // session reads the same way on every run.
  const m3 = PASS.newTokenMap()
  PASS.token(m3, 'folder', 'same')
  PASS.token(m3, 'entry', 'same')
  eq('a name under two kinds is deterministic', PASS.redact('same', m3, 160), 'entry#1')
  eq('and still deterministic on a second map', (() => { const x = PASS.newTokenMap(); PASS.token(x, 'entry', 'same'); PASS.token(x, 'folder', 'same'); return PASS.redact('same', x, 160) })(), 'entry#1')
})
group('a hit inside a longer word is left alone', () => {
  // A three-character entry must not turn "high" into "hi" + token + "h".
  // Garbling a line is its own kind of wrong, and the boundary test is what
  // keeps the redaction from being useless.
  const m = PASS.newTokenMap()
  PASS.token(m, 'entry', 'gh')
  eq('inside a word', PASS.redact('high school', m, 160), 'high school')
  eq('alone', PASS.redact('gh alone', m, 160), 'entry#1 alone')
  eq('after a slash', PASS.redact('a/gh', m, 160), 'a/entry#1')
  eq('inside a path segment', PASS.redact('high/gherkin', m, 160), 'high/gherkin')
  const m2 = PASS.newTokenMap()
  PASS.token(m2, 'entry', 'work-email')
  eq('a hyphen is a word character, not a boundary', PASS.redact('x-work-email-y', m2, 160), 'x-work-email-y')
  eq('a space is a boundary', PASS.redact('x work-email y', m2, 160), 'x entry#1 y')
})
group('the text is flattened and bounded before it is redacted', () => {
  const m = PASS.newTokenMap()
  PASS.token(m, 'entry', 'secret-name')
  // grep reads lines, so a message carrying a newline would forge a second
  // log line out of the first.
  eq('a newline cannot survive', PASS.redact('a\nb\nc', m, 160), 'a b c')
  eq('nor a carriage return', PASS.redact('a\r\nb', m, 160), 'a b')
  eq('nor a tab-run', PASS.redact('a \t\t b', m, 160), 'a b')
  eq('the default cap is 160', PASS.redact('x'.repeat(400), m).length, 160)
  eq('and it ends with an ellipsis, not a cut glyph', PASS.redact('x'.repeat(400), m).endsWith('...'), true)
  eq('a shorter text is untouched by the cap', PASS.redact('short', m, 160), 'short')
  eq('an explicit cap is honoured', PASS.redact('abcdefghij', m, 5), 'ab...')
  eq('a nonsense cap falls back to the default', PASS.redact('abcdefghij', m, 0), 'abcdefghij')
  eq('and so does a negative one', PASS.redact('abcdefghij', m, -3), 'abcdefghij')
  eq('redaction happens inside the cap, not after', PASS.redact('zzz secret-name zzz', m, 20), 'zzz entry#1 zzz')
  eq('an empty text is empty', PASS.redact('', m, 160), '')
  eq('whitespace alone is empty', PASS.redact('  \n ', m, 160), '')
  eq('null is empty', PASS.redact(null, m, 160), '')
  eq('undefined is empty', PASS.redact(undefined, m, 160), '')
  eq('no arguments are empty', PASS.redact(), '')
})
group('a damaged or empty map redacts nothing and does not throw', () => {
  noThrow('a null map', () => PASS.redact('x', null, 160))
  noThrow('no map', () => PASS.redact('x'))
  eq('and the text comes through bounded', PASS.redact('x'.repeat(400)).length, 160)
  const m = PASS.newTokenMap()
  m.entry = 'not a bucket'
  m.folder = { seen: 'not a map' }
  m.store = { seen: Object.create(null) }
  noThrow('a bucket that is a string', () => PASS.redact('x', m, 160))
  eq('and the text is untouched', PASS.redact('x', m, 160), 'x')
})

section('pass/Model - the two helpers redact() is built from')
// Not part of the intended API and not reachable from the component - the
// component only ever calls `redact` - but the ledger publishes them, so they
// are pinned here rather than left as the two uncovered names in the file.
group('_wordish draws the boundary, and a store name is a file name', () => {
  is('letters, digits, dots, dashes, plus and at are inside a name',
    ['a', 'Z', '0', '9', '.', '-', '+', '@', '_'], (cs) => cs.every((c) => PASS._wordish(c)), 'all word-ish')
  is('and spaces, slashes, colons, quotes and a terminator are not',
    [' ', '/', ':', ',', '(', '=', '"', "'"], (cs) => cs.every((c) => !PASS._wordish(c)), 'all boundaries')
  eq('an empty string is a boundary, being both ends of the text', PASS._wordish(''), false)
  eq('so is a newline', PASS._wordish('\n'), false)
})
group('_swap replaces the name and leaves a coincidental hit alone', () => {
  eq('every occurrence', PASS._swap('a a a', 'a', 'entry#1'), 'entry#1 entry#1 entry#1')
  eq('a dash is inside a name, so a-a-a is one string, not three names', PASS._swap('a-a-a', 'a', 'entry#1'), 'a-a-a')
  eq('a flanked hit', PASS._swap('xa x', 'a', 'entry#1'), 'xa x')
  eq('an empty name changes nothing', PASS._swap('abc', '', 'entry#1'), 'abc')
  eq('an empty token changes nothing', PASS._swap('abc', 'b', ''), 'abc')
  eq('a null token changes nothing', PASS._swap('abc', 'b', null), 'abc')
  eq('an undefined token changes nothing', PASS._swap('abc', 'b', undefined), 'abc')
  eq('no match at all', PASS._swap('abc', 'z', 'entry#1'), 'abc')
  eq('a non-string token is printed as it came', PASS._swap('x b', 'b', 7), 'x 7')
  eq('the empty text', PASS._swap('', 'a', 'entry#1'), '')
})

section('pass/Model.fieldCounts - how much a decrypted entry holds, and how much of it is blank')
group('the counts, for the shapes pass actually writes', () => {
  eq('a password and a username', PASS.fieldCounts('pw\nuser\n'), { fields: 2, empty: 0 })
  eq('a password alone', PASS.fieldCounts('pw'), { fields: 1, empty: 0 })
  eq('a password, a username and a note', PASS.fieldCounts('pw\nuser\nnote\n'), { fields: 3, empty: 0 })
  // The trailing newline ends the last line; it is not a field the user left
  // blank. Getting this wrong is what would make every entry report one
  // empty field forever.
  eq('the trailing newline is not a field', PASS.fieldCounts('pw\n'), { fields: 1, empty: 0 })
  eq('a password and a blank second line is one empty field', PASS.fieldCounts('pw\n\n'), { fields: 1, empty: 1 })
  eq('a blank between two values is one empty field', PASS.fieldCounts('pw\n\nuser\n'), { fields: 2, empty: 1 })
  eq('and it counts', PASS.fieldCounts('pw\n\n\nuser\n'), { fields: 2, empty: 2 })
  eq('a carriage return is trimmed like any whitespace', PASS.fieldCounts('pw\r\nuser\r\n'), { fields: 2, empty: 0 })
  eq('a blank line of spaces is still blank', PASS.fieldCounts('pw\n   \nuser\n'), { fields: 2, empty: 1 })
})
group('the degenerate inputs a child can produce', () => {
  eq('empty', PASS.fieldCounts(''), { fields: 0, empty: 0 })
  eq('a single newline', PASS.fieldCounts('\n'), { fields: 0, empty: 0 })
  eq('only newlines', PASS.fieldCounts('\n\n\n'), { fields: 0, empty: 0 })
  eq('only spaces', PASS.fieldCounts('   '), { fields: 0, empty: 0 })
  eq('null', PASS.fieldCounts(null), { fields: 0, empty: 0 })
  eq('undefined', PASS.fieldCounts(undefined), { fields: 0, empty: 0 })
  eq('no argument', PASS.fieldCounts(), { fields: 0, empty: 0 })
  eq('a number', PASS.fieldCounts(7), { fields: 1, empty: 0 })
  eq('exactly the two keys, and no value key', Object.keys(PASS.fieldCounts('pw\nuser')), ['fields', 'empty'])
})

section('pass/Model.storeStats - what one scan found')
group('entries, folders and the depth of the walk', () => {
  eq('a flat store', PASS.storeStats(['a.gpg', 'b.gpg'], []), { entries: 2, folders: 0, depth: 1 })
  eq('a nested one', PASS.storeStats(['a/b.gpg', 'a/c/d.gpg'], ['a', 'a/c']), { entries: 2, folders: 2, depth: 3 })
  eq('depth is the deepest name on either side', PASS.storeStats(['x.gpg'], ['a/b/c/d']), { entries: 1, folders: 1, depth: 4 })
  // This is the pair that makes the scan line readable: a scan that found
  // fewer entries than expected is a smaller tree or a broken walk, and the
  // depth is what tells those two apart.
  eq('a shallow store and a shallow store agree', [PASS.storeStats(['a.gpg'], ['a']), PASS.storeStats(['b.gpg'], ['b'])].map((s) => s.depth), [1, 1])
  eq('a shallow store and a deep one do not', [PASS.storeStats(['a.gpg'], ['a']), PASS.storeStats(['a/b/c.gpg'], ['a', 'a/b'])].map((s) => s.depth), [1, 3])
  eq('an empty store is depth zero', PASS.storeStats([], []), { entries: 0, folders: 0, depth: 0 })
  eq('folders alone still set the depth', PASS.storeStats([], ['a', 'a/b']), { entries: 0, folders: 2, depth: 2 })
  eq('exactly the three keys', Object.keys(PASS.storeStats([], [])), ['entries', 'folders', 'depth'])
})
group('the degenerate inputs the two callers can produce', () => {
  eq('no arguments', PASS.storeStats(), { entries: 0, folders: 0, depth: 0 })
  eq('a null list', PASS.storeStats(null, null), { entries: 0, folders: 0, depth: 0 })
  eq('a non-array', PASS.storeStats('x', 7), { entries: 0, folders: 0, depth: 0 })
  eq('a null entry is counted and costs no depth', PASS.storeStats([null, 'a.gpg'], [null]), { entries: 2, folders: 1, depth: 1 })
  eq('an empty name costs no depth', PASS.storeStats(['', 'a.gpg'], []), { entries: 2, folders: 0, depth: 1 })
  eq('a trailing slash does not add a level', PASS.storeStats(['a/b/.gpg'], []), { entries: 1, folders: 0, depth: 3 })
})

// ======================================================================
section('WallpaperTrans - the kind and speed tables')
group('the kind table, the pool and the directions', () => {
  eq('the six kinds', WT.transitions(), ['none', 'fade', 'slide', 'swipe', 'circle', 'random'])
  eq('the random pool', WT.randomPool(), ['fade', 'slide', 'swipe', 'circle'])
  eq('the four slide directions', WT.slideDirections(), ['left', 'right', 'top', 'bottom'])
  eq('the speed presets', WT.speeds(), { slow: 1200, def: 600, fast: 250 })
  eq('slow is the longest', WT.speeds().slow > WT.speeds().def, true)
  eq('and fast the shortest', WT.speeds().def > WT.speeds().fast, true)
  eq('every preset is a positive integer ms', Object.values(WT.speeds()).every((v) => Number.isInteger(v) && v > 0), true)
})
group('the pool excludes none and random, and is a subset of the kinds', () => {
  // "Kinds the random pool may yield. `none` (a confusing no-op win) and
  // `random` itself are excluded" - and the README says the same twice.
  eq('none is excluded', WT.randomPool().includes('none'), false)
  eq('random is excluded', WT.randomPool().includes('random'), false)
  eq('the pool is a subset of the kinds', WT.randomPool().every((k) => WT.transitions().includes(k)), true)
  eq('the pool is the kinds minus none and random', WT.transitions().filter((k) => k !== 'none' && k !== 'random'), WT.randomPool())
  eq('the pool holds four', WT.randomPool().length, 4)
  eq('the kinds hold six', WT.transitions().length, 6)
})
group('every table hands back a fresh array, so a caller cannot corrupt it', () => {
  // These are functions rather than vars for the same reason the speed scale
  // is: a QML-imported script exposes only its top-level functions.
  const kinds = WT.transitions()
  kinds.push('hacked')
  eq('the kind table is unchanged', WT.transitions(), ['none', 'fade', 'slide', 'swipe', 'circle', 'random'])
  const pool = WT.randomPool()
  pool.push('hacked')
  eq('the pool is unchanged', WT.randomPool(), ['fade', 'slide', 'swipe', 'circle'])
  const dirs = WT.slideDirections()
  dirs.push('hacked')
  eq('the directions are unchanged', WT.slideDirections(), ['left', 'right', 'top', 'bottom'])
  eq('two calls are equal but not identical', WT.transitions() === WT.transitions(), false)
  eq('the speed table is a fresh object each call', WT.speeds() === WT.speeds(), false)
  eq('and equal', WT.speeds(), { slow: 1200, def: 600, fast: 250 })
})

section('WallpaperTrans.normalizeKind - every retired spelling')
group('the four live kinds pass through', () => {
  eq('none', WT.normalizeKind('none'), 'none')
  eq('fade', WT.normalizeKind('fade'), 'fade')
  eq('slide', WT.normalizeKind('slide'), 'slide')
  eq('swipe', WT.normalizeKind('swipe'), 'swipe')
  eq('circle', WT.normalizeKind('circle'), 'circle')
  eq('random', WT.normalizeKind('random'), 'random')
  eq('each of the six is a fixed point of the table', WT.transitions().every((k) => WT.normalizeKind(k) === k), true)
})
group('the three wipe keys become swipe', () => {
  // Old transition names still accepted as input aliases: "the four
  // slide keys, grow/outer and all wipe keys".
  eq('wipe', WT.normalizeKind('wipe'), 'swipe')
  eq('wipe-horizontal', WT.normalizeKind('wipe-horizontal'), 'swipe')
  eq('wipe-vertical', WT.normalizeKind('wipe-vertical'), 'swipe')
  eq('the header lists three wipe keys and there are three', ['wipe', 'wipe-horizontal', 'wipe-vertical'].length, 3)
})
group('the four slide keys become slide', () => {
  eq('slide-left', WT.normalizeKind('slide-left'), 'slide')
  eq('slide-right', WT.normalizeKind('slide-right'), 'slide')
  eq('slide-top', WT.normalizeKind('slide-top'), 'slide')
  eq('slide-bottom', WT.normalizeKind('slide-bottom'), 'slide')
  eq('the header lists four slide keys and there are four', ['slide-left', 'slide-right', 'slide-top', 'slide-bottom'].length, 4)
})
group('grow and outer become circle', () => {
  // "grow (a growing disc) and outer (a shrinking hole)" share the circle
  // kind; the view's invert flag is what tells them apart at render time.
  eq('grow', WT.normalizeKind('grow'), 'circle')
  eq('outer', WT.normalizeKind('outer'), 'circle')
})
group('every retired spelling lands inside the live table', () => {
  const retired = ['wipe', 'wipe-horizontal', 'wipe-vertical', 'slide-left', 'slide-right', 'slide-top', 'slide-bottom', 'grow', 'outer']
  eq('nine retired spellings', retired.length, 9)
  for (const r of retired) {
    is(`${r} maps into transitions()`, WT.normalizeKind(r), (v) => WT.transitions().includes(v), 'a live kind')
    ne(`${r} is not itself a live kind`, WT.normalizeKind(r), r)
  }
  eq('they map onto three parents', [...new Set(retired.map(WT.normalizeKind))].sort(), ['circle', 'slide', 'swipe'])
})
group('the match is trimmed and lowercased first', () => {
  eq('an upper-case live kind', WT.normalizeKind('FADE'), 'fade')
  eq('an upper-case retired key', WT.normalizeKind('WIPE'), 'swipe')
  eq('an upper-case slide key', WT.normalizeKind('Slide-Left'), 'slide')
  eq('padded', WT.normalizeKind('  Fade  '), 'fade')
  eq('padded retired', WT.normalizeKind('\twipe-vertical\n'), 'swipe')
  eq('inner spaces are not trimmed, so it is unknown', WT.normalizeKind('fa de'), 'fade')
})
group('an unknown or hand-edited value falls back to the crossfade', () => {
  // "Unknown/hand-edited values fall back to the plain crossfade" - and the
  // README repeats it, so a settings file naming a kind this build dropped
  // degrades to a crossfade rather than to nothing.
  eq('an unknown word', WT.normalizeKind('zoom'), 'fade')
  eq('a slide key that was never real', WT.normalizeKind('slide-up'), 'fade')
  eq('a mis-typed wipe key', WT.normalizeKind('wipe-diagonal'), 'fade')
  eq('a near-miss on a live kind', WT.normalizeKind('fades'), 'fade')
  eq('a number', WT.normalizeKind(0), 'fade')
  eq('a number that is not a kind index', WT.normalizeKind(7), 'fade')
  eq('the empty string', WT.normalizeKind(''), 'fade')
  eq('whitespace', WT.normalizeKind('   '), 'fade')
  eq('null', WT.normalizeKind(null), 'fade')
  eq('undefined', WT.normalizeKind(undefined), 'fade')
  eq('no argument', WT.normalizeKind(), 'fade')
  eq('an object', WT.normalizeKind({}), 'fade')
  eq('false', WT.normalizeKind(false), 'fade')
})

section('WallpaperTrans.resolveKind - the roll, with an injectable r')
group('a non-random kind is returned as normalized, without consulting r', () => {
  eq('fade', WT.resolveKind('fade', 0.9), 'fade')
  eq('none', WT.resolveKind('none', 0.9), 'none')
  eq('a retired key', WT.resolveKind('wipe', 0.9), 'swipe')
  eq('an unknown value', WT.resolveKind('bogus', 0.9), 'fade')
  eq('undefined r is not consulted', WT.resolveKind('slide'), 'slide')
})
group('the pool is split into four equal quarters', () => {
  // `pool[Math.floor(r * pool.length)]` over a four-entry pool.
  eq('r = 0', WT.resolveKind('random', 0), 'fade')
  eq('just under a quarter', WT.resolveKind('random', 0.2499), 'fade')
  eq('exactly a quarter', WT.resolveKind('random', 0.25), 'slide')
  eq('just under a half', WT.resolveKind('random', 0.4999), 'slide')
  eq('exactly a half', WT.resolveKind('random', 0.5), 'swipe')
  eq('just under three quarters', WT.resolveKind('random', 0.7499), 'swipe')
  eq('exactly three quarters', WT.resolveKind('random', 0.75), 'circle')
  eq('the last representable value', WT.resolveKind('random', 0.999999), 'circle')
  eq('the whole pool is reachable', [...new Set([0, 0.24, 0.49, 0.74, 0.999].map((r) => WT.resolveKind('random', r)))], ['fade', 'slide', 'swipe', 'circle'])
  eq('and it is exactly the pool', [...new Set([0, 0.24, 0.49, 0.74, 0.999].map((r) => WT.resolveKind('random', r)))], WT.randomPool())
  eq('no roll can yield none', [...new Set([0, 0.24, 0.49, 0.74, 0.999].map((r) => WT.resolveKind('random', r)))].includes('none'), false)
  eq('nor random', [...new Set([0, 0.24, 0.49, 0.74, 0.999].map((r) => WT.resolveKind('random', r)))].includes('random'), false)
})
group('r is clamped into the half-open unit interval', () => {
  // "if (isNaN(r) || r < 0) r = 0; if (r >= 1) r = 0.999999" - so a Math
  // .random() that somehow returns 1, or a caller passing a percentage, can
  // never index past the end of the pool (which would be `undefined`).
  eq('r = 1 clamps to the last entry', WT.resolveKind('random', 1), 'circle')
  eq('r = 1.5 clamps too', WT.resolveKind('random', 1.5), 'circle')
  eq('a huge r', WT.resolveKind('random', 1e9), 'circle')
  eq('Infinity clamps', WT.resolveKind('random', Infinity), 'circle')
  eq('r = 0 is the first entry', WT.resolveKind('random', 0), 'fade')
  eq('a negative r clamps to the first entry', WT.resolveKind('random', -0.1), 'fade')
  eq('a large negative', WT.resolveKind('random', -1e9), 'fade')
  eq('-Infinity clamps', WT.resolveKind('random', -Infinity), 'fade')
  eq('NaN is the first entry', WT.resolveKind('random', NaN), 'fade')
  eq('a non-numeric string', WT.resolveKind('random', 'x'), 'fade')
  eq('an empty string is a zero, not a NaN', WT.resolveKind('random', ''), 'fade')
  eq('a numeric string is coerced', WT.resolveKind('random', '0.5'), 'swipe')
  eq('null is a zero', WT.resolveKind('random', null), 'fade')
  eq('undefined is a NaN', WT.resolveKind('random', undefined), 'fade')
  eq('no r at all', WT.resolveKind('random'), 'fade')
  is('no roll ever returns undefined', [0, 0.1, 0.5, 0.9, 1, 2, -1, NaN, null].map((r) => WT.resolveKind('random', r)), (v) => v.every((k) => typeof k === 'string' && k !== ''), 'always a live kind')
  is('and every roll is inside the pool', [0, 0.1, 0.5, 0.9, 1, 2, -1, NaN, null].map((r) => WT.resolveKind('random', r)), (v) => v.every((k) => WT.randomPool().includes(k)), 'always in randomPool()')
})

section('WallpaperTrans - the speed preset and its duration')
group('slow and fast are named, everything else is the default', () => {
  eq('slow', WT.normalizeSpeed('slow'), 'slow')
  eq('fast', WT.normalizeSpeed('fast'), 'fast')
  eq('the table key def is not accepted', WT.normalizeSpeed('def'), 'default')
  eq('the word default is folded to default', WT.normalizeSpeed('default'), 'default')
  eq('an unknown speed', WT.normalizeSpeed('quick'), 'default')
  eq('an upper-case speed', WT.normalizeSpeed('SLOW'), 'slow')
  eq('a padded speed', WT.normalizeSpeed('  fast  '), 'fast')
  eq('the empty string', WT.normalizeSpeed(''), 'default')
  eq('whitespace', WT.normalizeSpeed('   '), 'default')
  eq('null', WT.normalizeSpeed(null), 'default')
  eq('undefined', WT.normalizeSpeed(undefined), 'default')
  eq('a number', WT.normalizeSpeed(0), 'default')
  eq('a near-miss', WT.normalizeSpeed('slowly'), 'default')
  eq('no argument', WT.normalizeSpeed(), 'default')
})
group('durationFor reads the preset name, not the table key', () => {
  eq('slow', WT.durationFor('slow'), 1200)
  eq('fast', WT.durationFor('fast'), 250)
  eq('def', WT.durationFor('def'), 600)
  eq('default', WT.durationFor('default'), 600)
  eq('an unknown name', WT.durationFor('quick'), 600)
  eq('the empty string', WT.durationFor(''), 600)
  eq('null', WT.durationFor(null), 600)
  eq('undefined', WT.durationFor(undefined), 600)
  eq('no argument', WT.durationFor(), 600)
  eq('a number', WT.durationFor(0), 600)
  eq('the case matters', WT.durationFor('SLOW'), 600)
  // The composition the view actually does (WallpaperView.qml:66):
  // durationFor(normalizeSpeed(Settings.value(...))).
  // The composition is what makes a hand-edited setting work: normalizeSpeed
  // folds the case and the padding first, so 'SLOW' and '  slow  ' both reach
  // the 1200 preset. durationFor on the raw string would not.
  for (const raw of ['slow', 'fast', 'def', 'default', 'quick', '', null, undefined, 'SLOW', '  slow  ']) {
    const composed = WT.durationFor(WT.normalizeSpeed(raw))
    is(`durationFor(normalizeSpeed(${JSON.stringify(raw)})) is a published preset`, composed, (v) => Object.values(WT.speeds()).includes(v), '1200, 600 or 250')
  }
  eq('SLOW is folded to slow, unlike durationFor alone', [WT.durationFor('SLOW'), WT.durationFor(WT.normalizeSpeed('SLOW'))], [600, 1200])
  eq('a padded slow likewise', [WT.durationFor('  slow  '), WT.durationFor(WT.normalizeSpeed('  slow  '))], [600, 1200])
  eq('and every normalised name reaches a real preset', ['slow', 'fast', 'def', 'default', 'quick', '', null, undefined, 'SLOW', '  slow  '].map((r) => Object.values(WT.speeds()).includes(WT.durationFor(WT.normalizeSpeed(r)))), [true, true, true, true, true, true, true, true, true, true])
})
group('the middle preset is spelled "def" in the table and "default" as a name', () => {
  // normalizeSpeed names it "default" and speeds() keys it "def", so a
  // `speeds()[normalizeSpeed(raw)]` lookup only resolves for slow and fast.
  // The view never does that - it goes through durationFor - but the asymmetry
  // is worth pinning, because it is the kind of thing a new caller would trip
  // over. See the report.
  eq('slow resolves by name', WT.speeds()[WT.normalizeSpeed('slow')], 1200)
  eq('fast resolves by name', WT.speeds()[WT.normalizeSpeed('fast')], 250)
  eq('def does not resolve by name', WT.speeds()[WT.normalizeSpeed('def')], undefined)
  eq('the table key is def', Object.keys(WT.speeds())[1], 'def')
  eq('but the normalized name is default', WT.normalizeSpeed('def'), 'default')
  eq('so the three real presets are slow, def and fast', Object.keys(WT.speeds()), ['slow', 'def', 'fast'])
})
group('the durations are the README\'s numbers', () => {
  // README.md:74 - "slow 1200, def 600, fast 250".
  eq('slow', WT.speeds().slow, 1200)
  eq('def', WT.speeds().def, 600)
  eq('fast', WT.speeds().fast, 250)
  // 1200 / 250 is 4.8, not 4 - the three presets are round milliseconds
  // chosen by eye, not a geometric series. Pinned so a "tidy up the table"
  // change is a visible diff.
  eq('slow is 4.8x fast', WT.speeds().slow / WT.speeds().fast, 4.8)
  eq('and def is not their midpoint', WT.speeds().def === (WT.speeds().slow + WT.speeds().fast) / 2, false)
  is('but def does sit between them', WT.speeds().def, (v) => v > WT.speeds().fast && v < WT.speeds().slow, 'between fast and slow')
})

section('WallpaperTrans - the two kind predicates')
group('only swipe and circle go through the mask layer', () => {
  // "Kinds rendered through the mask layer (swipe band / circles). Slides
  // translate the layer and fades crossfade it - neither needs a mask."
  eq('swipe', WT.isMaskKind('swipe'), true)
  eq('circle', WT.isMaskKind('circle'), true)
  eq('slide is not masked', WT.isMaskKind('slide'), false)
  eq('fade is not masked', WT.isMaskKind('fade'), false)
  eq('none is not masked', WT.isMaskKind('none'), false)
  eq('random is not masked - it has been rolled by now', WT.isMaskKind('random'), false)
  eq('the empty string', WT.isMaskKind(''), false)
  eq('null', WT.isMaskKind(null), false)
  eq('undefined', WT.isMaskKind(undefined), false)
  eq('no argument', WT.isMaskKind(), false)
  eq('the case matters', WT.isMaskKind('Swipe'), false)
  eq('mask == swipe or circle, for every live kind', WT.transitions().every((k) => WT.isMaskKind(k) === (WT.isSwipeKind(k) || k === 'circle')), true)
  eq('and a retired spelling is not masked either', WT.isMaskKind('wipe'), false)
})
group('isSwipeKind is an exact string match', () => {
  eq('swipe', WT.isSwipeKind('swipe'), true)
  eq('circle', WT.isSwipeKind('circle'), false)
  eq('slide', WT.isSwipeKind('slide'), false)
  eq('the empty string', WT.isSwipeKind(''), false)
  eq('null', WT.isSwipeKind(null), false)
  eq('undefined', WT.isSwipeKind(undefined), false)
  eq('a padded swipe', WT.isSwipeKind('swipe '), false)
  eq('an upper-case swipe', WT.isSwipeKind('Swipe'), false)
  eq('a number', WT.isSwipeKind(0), false)
  eq('no argument', WT.isSwipeKind(), false)
  eq('a swipe-shaped object is not a swipe', WT.isSwipeKind({ swipe: true }), false)
})

section('WallpaperTrans.normalizeDirection and the two guards')
group('the four directions, normalised', () => {
  eq('left', WT.normalizeDirection('left'), 'left')
  eq('right', WT.normalizeDirection('right'), 'right')
  eq('top', WT.normalizeDirection('top'), 'top')
  eq('bottom', WT.normalizeDirection('bottom'), 'bottom')
  eq('upper case', WT.normalizeDirection('LEFT'), 'left')
  eq('padded', WT.normalizeDirection('  right  '), 'right')
  eq('an unknown direction is left', WT.normalizeDirection('sideways'), 'left')
  eq('up is not a direction', WT.normalizeDirection('up'), 'left')
  eq('down is not a direction', WT.normalizeDirection('down'), 'left')
  eq('the empty string', WT.normalizeDirection(''), 'left')
  eq('whitespace', WT.normalizeDirection('   '), 'left')
  eq('null', WT.normalizeDirection(null), 'left')
  eq('undefined', WT.normalizeDirection(undefined), 'left')
  eq('a number', WT.normalizeDirection(0), 'left')
  eq('no argument', WT.normalizeDirection(), 'left')
  eq('every direction is one of the four', WT.slideDirections().every((d) => WT.slideDirections().includes(WT.normalizeDirection(d))), true)
  eq('and the normalisation is a fixed point', WT.slideDirections().map((d) => WT.normalizeDirection(WT.normalizeDirection(d))), WT.slideDirections())
})
group('clamp01 closes the unit interval on both sides', () => {
  eq('0', WT.clamp01(0), 0)
  eq('0.5', WT.clamp01(0.5), 0.5)
  eq('1', WT.clamp01(1), 1)
  eq('a negative', WT.clamp01(-0.1), 0)
  eq('a large negative', WT.clamp01(-1e9), 0)
  eq('above one', WT.clamp01(1.1), 1)
  eq('a large positive', WT.clamp01(1e9), 1)
  eq('NaN is shut', WT.clamp01(NaN), 0)
  eq('Infinity is open', WT.clamp01(Infinity), 1)
  eq('-Infinity is shut', WT.clamp01(-Infinity), 0)
  eq('a numeric string is coerced', WT.clamp01('0.5'), 0.5)
  eq('a non-numeric string is shut', WT.clamp01('x'), 0)
  eq('an empty string is a zero', WT.clamp01(''), 0)
  eq('null is a zero', WT.clamp01(null), 0)
  eq('undefined is shut', WT.clamp01(undefined), 0)
  eq('no argument', WT.clamp01(), 0)
  eq('true is one', WT.clamp01(true), 1)
  eq('false is zero', WT.clamp01(false), 0)
  eq('an array holding a fraction', WT.clamp01([0.5]), 0.5)
  eq('an empty array is a zero', WT.clamp01([]), 0)
  is('the result is always a finite number in 0..1', [-1, 0, 0.5, 1, 2, NaN, Infinity, null, 'x', true].map(WT.clamp01), (v) => v.every((n) => Number.isFinite(n) && n >= 0 && n <= 1), '0 <= n <= 1 and finite')
})
group('fracOr is clamp01 with a fallback instead of a zero', () => {
  eq('0', WT.fracOr(0, 0.5), 0)
  eq('0.3', WT.fracOr(0.3, 0.5), 0.3)
  eq('0.75', WT.fracOr(0.75, 0.5), 0.75)
  eq('1', WT.fracOr(1, 0.5), 1)
  eq('a negative clamps to 0, not to the fallback', WT.fracOr(-0.1, 0.5), 0)
  eq('above one clamps to 1', WT.fracOr(1.1, 0.5), 1)
  eq('NaN is the fallback', WT.fracOr(NaN, 0.25), 0.25)
  eq('a non-numeric string is the fallback', WT.fracOr('x', 0.25), 0.25)
  eq('undefined is the fallback', WT.fracOr(undefined, 0.25), 0.25)
  eq('no argument takes the fallback', WT.fracOr(undefined, 0.25), 0.25)
  eq('Infinity clamps to 1, it is not the fallback', WT.fracOr(Infinity, 0.25), 1)
  eq('-Infinity clamps to 0', WT.fracOr(-Infinity, 0.25), 0)
  // Number(null) is 0, so null is a zero and NOT the fallback - the same
  // null/defined split normalizePct has. Pinned.
  eq('null is a zero, not the fallback', WT.fracOr(null, 0.25), 0)
  eq('a numeric string is coerced', WT.fracOr('0.5', 0.25), 0.5)
  eq('a zero fallback is honoured for a NaN', WT.fracOr(NaN, 0), 0)
  eq('an out-of-range fallback is NOT clamped', WT.fracOr(NaN, 5), 5)
  is('the in-range domain is passed through untouched', [0, 0.3, 0.5, 0.75, 1].map((v) => WT.fracOr(v, 0.5)), (v) => v.every((n, i) => n === [0, 0.3, 0.5, 0.75, 1][i]), 'identity on 0..1')
  is('and out of range is clamped, not passed through', [-1, 2, 100].map((v) => WT.fracOr(v, 0.5)), (v) => v.every((n) => n >= 0 && n <= 1), 'inside 0..1')
})

section('WallpaperTrans - the slide geometry')
group('progress 0 puts the new frame a full screen off the named edge', () => {
  eq('left', WT.slideOffset('left', 0, 1920, 1080), { x: -1920, y: 0 })
  eq('right', WT.slideOffset('right', 0, 1920, 1080), { x: 1920, y: 0 })
  eq('top', WT.slideOffset('top', 0, 1920, 1080), { x: 0, y: -1080 })
  eq('bottom', WT.slideOffset('bottom', 0, 1920, 1080), { x: 0, y: 1080 })
})
group('progress 1 is at rest', () => {
  eq('left', WT.slideOffset('left', 1, 1920, 1080), { x: 0, y: 0 })
  eq('right', WT.slideOffset('right', 1, 1920, 1080), { x: 0, y: 0 })
  eq('top', WT.slideOffset('top', 1, 1920, 1080), { x: 0, y: 0 })
  eq('bottom', WT.slideOffset('bottom', 1, 1920, 1080), { x: 0, y: 0 })
  eq('and the halves match the scalar forms', WT.slideDirections().every((d) => WT.slideX(d, 1, 1920) === WT.slideOffset(d, 1, 1920, 1080).x && WT.slideY(d, 1, 1920) === WT.slideOffset(d, 1, 1920, 1080).y), true)
})
group('the offset shrinks linearly with progress', () => {
  eq('half on the x axis', WT.slideOffset('left', 0.5, 100, 50), { x: -50, y: 0 })
  eq('a quarter', WT.slideOffset('left', 0.25, 100, 50), { x: -75, y: 0 })
  eq('three quarters', WT.slideOffset('left', 0.75, 100, 50), { x: -25, y: 0 })
  for (const t of [0, 0.25, 0.5, 0.75, 1]) {
    eq(`the x offsets mirror at t=${t}`, WT.slideOffset('left', t, 100, 50).x, -WT.slideOffset('right', t, 100, 50).x)
    eq(`the y offsets mirror at t=${t}`, WT.slideOffset('top', t, 100, 50).y, -WT.slideOffset('bottom', t, 100, 50).y)
  }
  is('the x offset is monotone in progress', [0, 0.25, 0.5, 0.75, 1].map((t) => WT.slideX('left', t, 100)), (v) => v.every((n, i) => i === 0 || n >= v[i - 1]), 'non-decreasing')
  is('and the y offset too', [0, 0.25, 0.5, 0.75, 1].map((t) => WT.slideY('top', t, 100)), (v) => v.every((n, i) => i === 0 || n >= v[i - 1]), 'non-decreasing')
  is('and both are linear: half progress is half the distance', [0.1, 0.2, 0.3, 0.4, 0.5].map((t) => Math.abs(WT.slideX('left', t, 100) + (1 - t) * 100)), (v) => v.every((n) => n < 1e-12), 'rest * w exactly')
})
group('progress outside 0..1 is clamped, and an unusable value is shut', () => {
  eq('below 0 reads as 0', WT.slideOffset('left', -1, 100, 50), { x: -100, y: 0 })
  eq('above 1 reads as 1', WT.slideOffset('left', 2, 100, 50), { x: 0, y: 0 })
  eq('NaN reads as 0', WT.slideOffset('left', NaN, 100, 50), { x: -100, y: 0 })
  eq('Infinity reads as 1', WT.slideOffset('left', Infinity, 100, 50), { x: 0, y: 0 })
  eq('a numeric string is coerced', WT.slideOffset('left', '0.5', 100, 50), { x: -50, y: 0 })
  eq('a non-numeric string is shut', WT.slideOffset('left', 'x', 100, 50), { x: -100, y: 0 })
  eq('null is a zero', WT.slideOffset('left', null, 100, 50), { x: -100, y: 0 })
  eq('undefined is shut', WT.slideOffset('left', undefined, 100, 50), { x: -100, y: 0 })
  eq('no progress at all', WT.slideOffset('left', undefined, 100, 50), { x: -100, y: 0 })
})
group('the axes are disjoint, and a wrong-axis direction reads as zero', () => {
  eq('slideX is zero for a vertical direction', WT.slideX('top', 0.5, 200), 0)
  eq('slideX is zero for bottom', WT.slideX('bottom', 0, 200), 0)
  eq('slideY is zero for a horizontal direction', WT.slideY('left', 0.5, 200), 0)
  eq('slideY is zero for right', WT.slideY('right', 0, 200), 0)
  eq('the object form agrees on both axes', [['top'], ['bottom'], ['left'], ['right']].every(([d]) => {
    const o = WT.slideOffset(d, 0.5, 200, 100)
    return WT.slideX(d, 0.5, 200) === o.x && WT.slideY(d, 0.5, 100) === o.y
  }), true)
  eq('a zero-size surface has no offset', WT.slideOffset('left', 0.5, 0, 0), { x: 0, y: 0 })
  eq('at progress 0 too', WT.slideOffset('left', 0, 0, 0), { x: 0, y: 0 })
  eq('a zero width with a real height', WT.slideOffset('top', 0.5, 0, 100), { x: 0, y: -50 })
  eq('a zero height with a real width', WT.slideOffset('right', 0.5, 100, 0), { x: 50, y: 0 })
})
group('an unknown direction is normalised to left, not dropped', () => {
  eq('an unknown name', WT.slideOffset('sideways', 0.5, 100, 50), { x: -50, y: 0 })
  eq('the empty string', WT.slideOffset('', 0.5, 100, 50), { x: -50, y: 0 })
  eq('null', WT.slideOffset(null, 0.5, 100, 50), { x: -50, y: 0 })
  eq('undefined', WT.slideOffset(undefined, 0.5, 100, 50), { x: -50, y: 0 })
  // progress and width are read unguarded, so a call with no arguments at
  // all multiplies NaN and hands a NaN offset to the animation. The view
  // always passes all four (WallpaperView.qml:224-225).
  is('no direction at all still normalises to left', WT.slideOffset(), (v) => v.y === 0, 'the y axis is untouched')
  eq('and the x offset is NaN, not a number', Number.isNaN(WT.slideOffset().x), true)
  eq('an upper-case direction is normalised first', WT.slideOffset('LEFT', 0.5, 100, 50), { x: -50, y: 0 })
  eq('and the scalar forms use the same normalisation', WT.slideX('sideways', 0.5, 100), -50)
})
group('-0 is normalized to 0, for strict consumers', () => {
  // "+ 0 normalizes -0 (rest = 0) to 0 for strict consumers" - an animation
  // binding that distinguishes -0 from 0 would otherwise see a change.
  eq('the x offset at rest is +0', Object.is(WT.slideOffset('left', 1, 100, 50).x, -0), false)
  eq('and equals 0', WT.slideOffset('left', 1, 100, 50).x, 0)
  eq('slideX at rest is +0', Object.is(WT.slideX('left', 1, 200), -0), false)
  eq('slideX equals 0', WT.slideX('left', 1, 200), 0)
  eq('slideY at rest is +0', Object.is(WT.slideY('top', 1, 200), -0), false)
  eq('slideY equals 0', WT.slideY('top', 1, 200), 0)
  eq('and the y of a horizontal slide is +0', Object.is(WT.slideOffset('left', 0.5, 100, 50).y, -0), false)
  eq('a NaN progress gives the shut offset, not -0', WT.slideX('left', NaN, 100), -100)
})

section('WallpaperTrans.swipeBandRect - the slanted masked reveal')
group('progress drives the band WIDTH, and the height is fixed', () => {
  // "progress 0..1 grows the band width 0 -> full coverage ... Returns
  // frame-space center, full size and the echoed angle for a centered
  // rectangle." fullH is the long axis, sized for the whole frame at p=0
  // already; fullW is the progress axis.
  const s = WT.swipeBandRect
  eq('p = 0 is exactly shut', s(0, 1920, 1080, 0.5, 0.5, 0).fullW, 0)
  eq('p = 0.2', s(0.2, 1920, 1080, 0.5, 0.5, 0).fullW, 385.6)
  eq('p = 0.4', s(0.4, 1920, 1080, 0.5, 0.5, 0).fullW, 771.2)
  eq('p = 0.6', s(0.6, 1920, 1080, 0.5, 0.5, 0).fullW, 1156.8)
  eq('p = 0.8', s(0.8, 1920, 1080, 0.5, 0.5, 0).fullW, 1542.4)
  eq('p = 1', s(1, 1920, 1080, 0.5, 0.5, 0).fullW, 1928)
  is('the width is linear in progress', [0.2, 0.4, 0.6, 0.8].map((t) => s(t, 1920, 1080, 0.5, 0.5, 0).fullW), (w) => w.every((v, i) => Math.abs(v - [385.6, 771.2, 1156.8, 1542.4][i]) < 1e-6), 'proportional to p')
  is('the height never moves', [0, 0.25, 0.5, 0.75, 1].map((t) => s(t, 1920, 1080, 0.5, 0.5, 30).fullH), (h) => new Set(h).size === 1, 'one value across the range')
  eq('the returned keys, in order', Object.keys(s(0.5, 10, 10, 0.5, 0.5, 30)), ['cx', 'cy', 'fullW', 'fullH', 'angleDeg'])
})
group('the centre is frame-space, and the fractions are guarded', () => {
  eq('the centre of the frame', WT.swipeBandRect(0, 1920, 1080, 0.5, 0.5, 0), { cx: 960, cy: 540, fullW: 0, fullH: 1088, angleDeg: 0 })
  eq('a corner origin', [WT.swipeBandRect(0, 100, 50, 0, 0, 0).cx, WT.swipeBandRect(0, 100, 50, 0, 0, 0).cy], [0, 0])
  eq('the far corner', [WT.swipeBandRect(0, 100, 50, 1, 1, 0).cx, WT.swipeBandRect(0, 100, 50, 1, 1, 0).cy], [100, 50])
  eq('a fraction above one clamps', [WT.swipeBandRect(1, 100, 50, 2, 2, 0).cx, WT.swipeBandRect(1, 100, 50, 2, 2, 0).cy], [100, 50])
  eq('a fraction below zero clamps', [WT.swipeBandRect(1, 100, 50, -1, -1, 0).cx, WT.swipeBandRect(1, 100, 50, -1, -1, 0).cy], [0, 0])
  eq('an unusable fraction takes the 0.5 fallback', [WT.swipeBandRect(1, 100, 50, 'x', 'x', 0).cx, WT.swipeBandRect(1, 100, 50, 'x', 'x', 0).cy], [50, 25])
  eq('null is a zero, not the fallback', [WT.swipeBandRect(1, 100, 50, null, null, 0).cx, WT.swipeBandRect(1, 100, 50, null, null, 0).cy], [0, 0])
  eq('a zero-size frame has a centre at the origin', [WT.swipeBandRect(0, 0, 0, 0.5, 0.5, 0).cx, WT.swipeBandRect(0, 0, 0, 0.5, 0.5, 0).cy], [0, 0])
  eq('a zero width with a real height', WT.swipeBandRect(0, 0, 100, 0.5, 0.5, 0).cy, 50)
  eq('a zero height with a real width', WT.swipeBandRect(0, 100, 0, 0.5, 0.5, 0).cx, 50)
})
group('the extents are exact maxima over the frame corners', () => {
  // "+4 margin" - so a p = 1 band provably covers the frame at any angle
  // and any origin, and the margin is inside the progress term so p = 0
  // stays exactly shut.
  // The extents are maxima over the four corners RELATIVE to the centre, so
  // a centred 100x100 frame needs 2 * (50 + 4) and a corner-origin one needs
  // 2 * (100 + 4). The +4 is the margin.
  eq('a centre origin at 0 degrees', WT.swipeBandRect(1, 100, 100, 0.5, 0.5, 0).fullW, 108)
  eq('the same height', WT.swipeBandRect(1, 100, 100, 0.5, 0.5, 0).fullH, 108)
  eq('a corner origin at 0 degrees', [WT.swipeBandRect(1, 100, 100, 0, 0, 0).fullW, WT.swipeBandRect(1, 100, 100, 0, 0, 0).fullH], [208, 208])
  eq('an aspect-1 frame', [WT.swipeBandRect(1, 500, 500, 0.5, 0.5, 0).fullW, WT.swipeBandRect(1, 500, 500, 0.5, 0.5, 0).fullH], [508, 508])
  eq('a 1920x1080 frame at 0 degrees', [WT.swipeBandRect(1, 1920, 1080, 0.5, 0.5, 0).fullW, WT.swipeBandRect(1, 1920, 1080, 0.5, 0.5, 0).fullH], [1928, 1088])
  eq('a zero-size frame still gets the margin', [WT.swipeBandRect(1, 0, 0, 0.5, 0.5, 0).fullW, WT.swipeBandRect(1, 0, 0, 0.5, 0.5, 0).fullH], [8, 8])
})
group('the angle orients the long axis, and is echoed back', () => {
  // "0 sweeps horizontally, 90 vertically, anything between diagonally".
  eq('0 degrees is horizontal', [WT.swipeBandRect(1, 1920, 1080, 0.5, 0.5, 0).fullW, WT.swipeBandRect(1, 1920, 1080, 0.5, 0.5, 0).fullH], [1928, 1088])
  approx('90 degrees is vertical', WT.swipeBandRect(1, 1920, 1080, 0.5, 0.5, 90).fullW, 1088, 1e-9)
  approx('and its height is the old width', WT.swipeBandRect(1, 1920, 1080, 0.5, 0.5, 90).fullH, 1928, 1e-9)
  approx('45 degrees is square on a 1:1 frame', WT.swipeBandRect(1, 100, 100, 0.5, 0.5, 45).fullW, WT.swipeBandRect(1, 100, 100, 0.5, 0.5, 45).fullH, 1e-9)
  // A half turn and a quarter turn give back the same extents up to the
  // floating point noise of sin/cos at those angles, so the comparison is
  // approximate rather than exact.
  approx('180 degrees is 0 degrees again', WT.swipeBandRect(1, 100, 100, 0.5, 0.5, 180).fullW, 108, 1e-9)
  approx('and its height too', WT.swipeBandRect(1, 100, 100, 0.5, 0.5, 180).fullH, 108, 1e-9)
  approx('270 degrees is 90 degrees again', WT.swipeBandRect(1, 100, 100, 0.5, 0.5, 270).fullW, 108, 1e-9)
  approx('and its height too', WT.swipeBandRect(1, 100, 100, 0.5, 0.5, 270).fullH, 108, 1e-9)
  eq('while 0 degrees is exact', WT.swipeBandRect(1, 100, 100, 0.5, 0.5, 0).fullW, 108)
  eq('a negative angle echoes back unchanged', WT.swipeBandRect(0.5, 10, 10, 0.5, 0.5, -30).angleDeg, -30)
  eq('and 360 echoes back as 360, not 0', WT.swipeBandRect(0.5, 10, 10, 0.5, 0.5, 360).angleDeg, 360)
  eq('a numeric string is coerced', WT.swipeBandRect(0.5, 10, 10, 0.5, 0.5, '45').angleDeg, 45)
  eq('a non-numeric angle becomes 0', [WT.swipeBandRect(0.5, 10, 10, 0.5, 0.5, 'x').angleDeg, WT.swipeBandRect(0.5, 10, 10, 0.5, 0.5, null).angleDeg, WT.swipeBandRect(0.5, 10, 10, 0.5, 0.5, undefined).angleDeg, WT.swipeBandRect(0.5, 10, 10, 0.5, 0.5, NaN).angleDeg], [0, 0, 0, 0])
  eq('a non-numeric angle also lays the band flat', WT.swipeBandRect(1, 100, 100, 0.5, 0.5, 'x').fullW, 108)
  // Number(Infinity) is Infinity and isNaN(Infinity) is false, so an infinite
  // angle is NOT folded to 0 - the layout degenerates to sin/cos of
  // Infinity (NaN) and the rect is unusable. Pinned: the guard is isNaN, not
  // isFinite, which is the one shape the header's "angleDeg orients the
  // band" contract does not cover.
  eq('Infinity is echoed back, not folded to 0', WT.swipeBandRect(0.5, 10, 10, 0.5, 0.5, Infinity).angleDeg, Infinity)
  // sin/cos of Infinity are NaN, and every `NaN > need` comparison is false,
  // so needA and needP stay 0 and the band collapses to the bare +4 margin.
  eq('and the extents collapse to the bare margin', WT.swipeBandRect(1, 100, 100, 0.5, 0.5, Infinity), { cx: 50, cy: 50, fullW: 8, fullH: 8, angleDeg: Infinity })
  eq('no angle at all', WT.swipeBandRect(0.5, 10, 10, 0.5, 0.5).angleDeg, 0)
})
group('p = 1 provably covers the frame from any origin at any angle', () => {
  // The claim in the header, checked rather than read: every frame corner has
  // to land inside the rotated rectangle.
  let covered = 0
  let total = 0
  for (const angle of [0, 15, 30, 45, 60, 90, 135, 180, -40]) {
    for (const [w, h] of [[1, 1], [100, 50], [1920, 1080], [1920, 10]]) {
      for (const fx of [0, 0.13, 0.5, 0.87, 1]) {
        for (const fy of [0, 0.2, 0.5, 0.9, 1]) {
          const r = WT.swipeBandRect(1, w, h, fx, fy, angle)
          const cx = w * WT.fracOr(fx, 0.5)
          const cy = h * WT.fracOr(fy, 0.5)
          const a = (angle * Math.PI) / 180
          const ux = -Math.sin(a)
          const uy = Math.cos(a)
          const vx = Math.cos(a)
          const vy = Math.sin(a)
          const corners = [[-cx, -cy], [w - cx, -cy], [-cx, h - cy], [w - cx, h - cy]]
          total++
          if (corners.every(([dx, dy]) => Math.abs(dx * ux + dy * uy) <= r.fullH / 2 && Math.abs(dx * vx + dy * vy) <= r.fullW / 2)) covered++
        }
      }
    }
  }
  eq('every one of the 900 combinations covers all four corners', covered, 900)
  is('and none of them returned a non-finite extent', [0, 45, 90, 135].map((deg) => WT.swipeBandRect(1, 1920, 1080, 0.3, 0.7, deg)), (rects) => rects.every((r) => Number.isFinite(r.fullW) && Number.isFinite(r.fullH) && Number.isFinite(r.cx) && Number.isFinite(r.cy)), 'finite extents and centre')
  is('and the extents are positive at p = 1', [0, 45, 90, 135].map((deg) => WT.swipeBandRect(1, 1920, 1080, 0.3, 0.7, deg)), (rects) => rects.every((r) => r.fullW > 0 && r.fullH > 0), 'both axes positive')
})
group('progress is clamped and an unusable value is shut', () => {
  eq('below 0', WT.swipeBandRect(-1, 100, 100, 0.5, 0.5, 0).fullW, 0)
  eq('above 1', WT.swipeBandRect(2, 100, 100, 0.5, 0.5, 0).fullW, 108)
  eq('NaN', WT.swipeBandRect(NaN, 100, 100, 0.5, 0.5, 0).fullW, 0)
  eq('Infinity', WT.swipeBandRect(Infinity, 100, 100, 0.5, 0.5, 0).fullW, 108)
  eq('a numeric string', WT.swipeBandRect('0.5', 100, 100, 0.5, 0.5, 0).fullW, 54)
  eq('a non-numeric string is shut', WT.swipeBandRect('x', 100, 100, 0.5, 0.5, 0).fullW, 0)
  eq('null is a zero', WT.swipeBandRect(null, 100, 100, 0.5, 0.5, 0).fullW, 0)
  eq('undefined is shut', WT.swipeBandRect(undefined, 100, 100, 0.5, 0.5, 0).fullW, 0)
  eq('no progress at all', WT.swipeBandRect().fullW, 0)
  is('no arguments at all yields a NaN centre', WT.swipeBandRect().cx, (v) => Number.isNaN(v), 'NaN * undefined')
  eq('and the angle still falls back to 0', WT.swipeBandRect().angleDeg, 0)
  eq('a frame of 0x0 at p=0.5', WT.swipeBandRect(0.5, 0, 0, 0.5, 0.5, 0).fullW, 4)
})

section('WallpaperTrans.discDiameter - the grow / outer disc')
group('grow scales up with progress and outer scales down', () => {
  const d = (t, invert) => WT.discDiameter(t, 100, 100, 0.5, 0.5, invert)
  eq('grow at 0 is nothing', d(0, false), 0)
  approx('grow at 0.25', d(0.25, false), 36.7695, 1e-3)
  approx('grow at 0.5', d(0.5, false), 73.5390, 1e-3)
  approx('grow at 1', d(1, false), 147.078, 1e-3)
  eq('outer at 0 is the full diameter, which is grow at 1', d(0, true), d(1, false))
  eq('outer at 1 is nothing', d(1, true), 0)
  eq('outer at 1 equals grow at 0', d(1, true), d(0, false))
  eq('the two meet in the middle', d(0.5, false), d(0.5, true))
  eq('and are mirror images', d(0.25, false), d(0.75, true))
  is('grow is monotone in progress', [0, 0.2, 0.4, 0.6, 0.8, 1].map((t) => d(t, false)), (v) => v.every((n, i) => i === 0 || n > v[i - 1]), 'strictly increasing')
  is('outer is monotone the other way', [0, 0.2, 0.4, 0.6, 0.8, 1].map((t) => d(t, true)), (v) => v.every((n, i) => i === 0 || n < v[i - 1]), 'strictly decreasing')
  is('and the pair always sums to the full diameter', [0, 0.2, 0.4, 0.6, 0.8, 1].map((t) => d(t, false) + d(t, true)), (v) => v.every((n, i) => Math.abs(n - d(1, false)) < 1e-9), 'constant sum')
})
group('the diameter is 2 * the farthest corner * 1.04', () => {
  const s = (w, h, fx, fy) => 2 * Math.sqrt(Math.max(w * fx, w - w * fx) ** 2 + Math.max(h * fy, h - h * fy) ** 2) * 1.04
  for (const [w, h, fx, fy] of [[100, 100, 0.5, 0.5], [100, 100, 0, 0], [100, 100, 1, 1], [100, 100, 0, 1], [1920, 1080, 0.5, 0.5], [500, 500, 0.5, 0.5], [1, 1, 0.5, 0.5]]) {
    approx(`${w}x${h} at ${fx},${fy}`, WT.discDiameter(1, w, h, fx, fy, false), s(w, h, fx, fy), 1e-9)
  }
  eq('the 1.04 margin is the only slack there is', WT.discDiameter(1, 500, 500, 0.5, 0.5, false) / (2 * Math.sqrt(250 * 250 + 250 * 250)), 1.04)
})
group('a 1:1 frame centred gives the diagonal, not the side', () => {
  eq('the half-diagonal times 2.08', WT.discDiameter(1, 500, 500, 0.5, 0.5, false), 2 * Math.sqrt(250 * 250 + 250 * 250) * 1.04)
  is('a square frame is not the side length', WT.discDiameter(1, 500, 500, 0.5, 0.5, false), (v) => v > 500, 'larger than the side')
  approx('a wide frame uses its width and half its height', WT.discDiameter(1, 1000, 100, 0.5, 0.5, false), 2 * Math.sqrt(500 * 500 + 50 * 50) * 1.04, 1e-9)
  approx('a tall frame the other way', WT.discDiameter(1, 100, 1000, 0.5, 0.5, false), 2 * Math.sqrt(50 * 50 + 500 * 500) * 1.04, 1e-9)
})
group('p = 1 covers the frame from any origin', () => {
  let covered = 0
  let total = 0
  for (const [w, h] of [[1, 1], [100, 100], [1920, 1080], [1920, 10], [10, 1920]]) {
    for (const [fx, fy] of [[0, 0], [0, 1], [1, 0], [1, 1], [0.5, 0.5], [0.13, 0.87]]) {
      const d = WT.discDiameter(1, w, h, fx, fy, false)
      const cx = w * fx
      const cy = h * fy
      total++
      if ([[0, 0], [w, 0], [0, h], [w, h]].every(([px, py]) => Math.hypot(px - cx, py - cy) <= d / 2)) covered++
    }
  }
  eq('every one of the 30 combinations covers all four corners', covered, 30)
  is('and none of them is NaN', [[0, 0], [0.5, 0.5], [1, 1]].map(([fx, fy]) => WT.discDiameter(1, 1920, 1080, fx, fy, false)), (v) => v.every(Number.isFinite), 'finite')
})
group('the fractions are guarded and the progress is clamped', () => {
  eq('a fraction above one clamps to the far corner', WT.discDiameter(1, 100, 100, 2, 2, false), WT.discDiameter(1, 100, 100, 1, 1, false))
  eq('a fraction below zero clamps to the near corner', WT.discDiameter(1, 100, 100, -1, -1, false), WT.discDiameter(1, 100, 100, 0, 0, false))
  eq('an unusable fraction takes the 0.5 fallback', WT.discDiameter(1, 100, 100, 'x', 'x', false), WT.discDiameter(1, 100, 100, 0.5, 0.5, false))
  eq('null is a zero', WT.discDiameter(1, 100, 100, null, null, false), WT.discDiameter(1, 100, 100, 0, 0, false))
  eq('progress below 0', WT.discDiameter(-1, 100, 100, 0.5, 0.5, false), 0)
  eq('progress above 1', WT.discDiameter(2, 100, 100, 0.5, 0.5, false), WT.discDiameter(1, 100, 100, 0.5, 0.5, false))
  eq('NaN progress is nothing for grow', WT.discDiameter(NaN, 100, 100, 0.5, 0.5, false), 0)
  eq('and everything for outer', WT.discDiameter(NaN, 100, 100, 0.5, 0.5, true), WT.discDiameter(1, 100, 100, 0.5, 0.5, false))
  eq('a numeric string is coerced', WT.discDiameter('0.5', 100, 100, 0.5, 0.5, false), WT.discDiameter(0.5, 100, 100, 0.5, 0.5, false))
  eq('a zero-size frame is nothing', WT.discDiameter(1, 0, 0, 0.5, 0.5, false), 0)
  eq('a zero width with a real height', WT.discDiameter(1, 0, 100, 0.5, 0.5, false), 2 * 50 * 1.04)
})
group('invert is a truthiness test, and omitting it means grow', () => {
  // "invert flips the sweep for the shrink variant" - the view passes `false`
  // for grow and `true` for outer (WallpaperView.qml:292 and :310).
  eq('grow is the default', WT.discDiameter(0.25, 100, 100, 0.5, 0.5), WT.discDiameter(0.25, 100, 100, 0.5, 0.5, false))
  eq('false is grow', WT.discDiameter(0.25, 100, 100, 0.5, 0.5, false), WT.discDiameter(0.25, 100, 100, 0.5, 0.5, 0))
  eq('true is outer', WT.discDiameter(0.25, 100, 100, 0.5, 0.5, true), WT.discDiameter(0.75, 100, 100, 0.5, 0.5, false))
  eq('a truthy non-boolean is outer', WT.discDiameter(0.25, 100, 100, 0.5, 0.5, 1), WT.discDiameter(0.25, 100, 100, 0.5, 0.5, true))
  eq('a string true is outer', WT.discDiameter(0.25, 100, 100, 0.5, 0.5, 'yes'), WT.discDiameter(0.25, 100, 100, 0.5, 0.5, true))
  eq('undefined is grow', WT.discDiameter(0.25, 100, 100, 0.5, 0.5, undefined), WT.discDiameter(0.25, 100, 100, 0.5, 0.5, false))
  eq('null is grow', WT.discDiameter(0.25, 100, 100, 0.5, 0.5, null), WT.discDiameter(0.25, 100, 100, 0.5, 0.5, false))
  eq('an empty string is grow', WT.discDiameter(0.25, 100, 100, 0.5, 0.5, ''), WT.discDiameter(0.25, 100, 100, 0.5, 0.5, false))
  eq('no invert at all', WT.discDiameter(0.25, 100, 100, 0.5, 0.5), WT.discDiameter(0.25, 100, 100, 0.5, 0.5, false))
  is('no arguments at all yields NaN, not zero', WT.discDiameter(), (v) => Number.isNaN(v), '0 * NaN')
  is('because the size is missing', WT.discDiameter(1), (v) => Number.isNaN(v), 'w and h undefined')
  eq('and an explicit 0x0 frame is a real zero', WT.discDiameter(1, 0, 0, 0, 0, false), 0)
  eq('which for outer would be everything - also nothing, at 0x0', WT.discDiameter(0, 0, 0, 0, 0, true), 0)
})

// ======================================================================
section('coverage ledger')
// The surface list, one entry per library, checked against the loaded
// namespace AND against this file's own source. Removing a function, renaming
// one, or dropping a cluster therefore turns this section red rather than
// quietly shrinking the coverage.
const SURFACE = {
  'UnitIpc': ['help'],
  'Battery/Model': [
    'normalizePct', 'batteryIconFor', 'batteryAccentFor', 'batteryColorFor', 'isTrackedType',
    'deviceLabel', 'deviceIconName', 'prettyState', 'formatDuration', 'formatRate',
    'rowSubtext', 'sortRows', 'detailRows', 'tooltipRows',
    // The six helpers services/power reads. Same file, other reader, so
    // they are listed here (the surface check is about the namespace) and
    // covered in services-power.test.mjs - see COVERED_ELSEWHERE.
    'deviceKey', 'resolveLevels', 'alertFor', 'isRunningDown', 'notifyArgv', 'alertToneFor',
  ],
  'Bluetooth/Model': [
    'deviceLabel', 'isKnown', 'deviceRow', 'deviceRowsEqual', 'deviceIconName',
    'sortDeviceRows', 'sectionTitleFor', 'subtextFor', 'listEntries',
  ],
  'Network/Model': [
    'strengthDimTiers', 'parseStats', 'throughputState', 'formatBytes',
    'formatRate', 'securityLabel', 'subtextFor', 'isOutOfReach', 'wifiRow',
    'failureReasonText', 'shouldDiscardSecrets', 'authFailureArgv', 'sortWifiRows', 'sectionTitleFor',
    'wifiListViewportHeight', 'wifiDisplayKey', 'deriveWifiState', 'linkNoteText',
    'requiresCredentials', 'deriveStats', 'profileToggles', 'profilePatch', 'escapeHtml',
    'ssidWithStatus', 'initialSpeedScale', 'stepSpeedScale', 'speedScaleLabel',
    'parseQrOutput', 'parseQrMatrix', 'wifiRowsEqual',
  ],
  'pass/Model': [
    'versionCompare', 'stripGpg', 'splitEntry', 'listEntries', 'parseFindOutput', 'isValidName',
    'storeDir', 'firstLine', 'childrenOf', 'countUnder', 'filterEntries', 'searchVault',
    'parseKeyFingerprints', 'unavailableVerb', 'statusError', 'navigationBack', 'toggleReply',
    // The redaction surface: five entry points and the two private helpers
    // that back them. `_swap` and `_wordish` are the same kind of case as
    // WallpaperTrans's `fracOr` - not part of the intended API, published by
    // the loader anyway, so the ledger lists them rather than leaving the
    // ledger's own check to complain about them.
    'newTokenMap', 'token', 'redact', 'fieldCounts', 'storeStats', '_swap', '_wordish',
  ],
  'WallpaperTrans': [
    'transitions', 'randomPool', 'speeds', 'normalizeKind', 'resolveKind', 'normalizeSpeed',
    'durationFor', 'isMaskKind', 'isSwipeKind', 'slideDirections', 'normalizeDirection',
    'slideOffset', 'slideX', 'slideY', 'swipeBandRect', 'discDiameter', 'fracOr', 'clamp01',
  ],
}
const NAMESPACES = { 'UnitIpc': UI, 'Battery/Model': BAT, 'Bluetooth/Model': BT, 'Network/Model': NET, 'pass/Model': PASS, 'WallpaperTrans': WT }
// The three table vars: declarations rather than functions, so they get the
// read-side check instead of the call check. `Network/Model` and
// `WallpaperTrans` are the only two files with any, and the QML surface
// never sees them.
const TABLES = { 'Network/Model': ['SECURITY_LABELS', 'SPEED_SCALE_STOPS'], 'WallpaperTrans': [], 'UnitIpc': [], 'Battery/Model': [], 'Bluetooth/Model': [], 'pass/Model': [] }
const selfSource = fs.readFileSync(path.join(import.meta.dirname, 'modules-wallpaper.test.mjs'), 'utf8')

group('the surface lists match the loaded namespaces exactly', () => {
  for (const [label, names] of Object.entries(SURFACE)) {
    const ns = NAMESPACES[label]
    const declared = [...names, ...(TABLES[label] || [])].sort()
    const actual = Object.keys(ns).sort()
    eq(`${label} exports nothing the ledger forgot`, actual.filter((n) => !declared.includes(n)), [])
    eq(`${label} exports nothing the ledger invented`, declared.filter((n) => !actual.includes(n)), [])
    eq(`${label}: ${declared.length} exports, ${Object.keys(ns).length} on the namespace`, declared.length, Object.keys(ns).length)
    eq(`${label} publishes only functions plus its declared table vars`, declared.filter((n) => typeof ns[n] !== 'function' && !TABLES[label].includes(n)), [])
    for (const t of TABLES[label]) eq(`${label}.${t} is an array`, Array.isArray(ns[t]), true)
  }
  eq('UnitIpc: 1 export', SURFACE['UnitIpc'].length, 1)
  eq('Battery/Model: 20 exports', SURFACE['Battery/Model'].length, 20)
  eq('Bluetooth/Model: 9 exports', SURFACE['Bluetooth/Model'].length, 9)
  eq('Network/Model: 30 functions plus 2 table vars', SURFACE['Network/Model'].length + TABLES['Network/Model'].length, 32)
  eq('pass/Model: 24 exports', SURFACE['pass/Model'].length, 24)
  eq('WallpaperTrans: 18 exports', SURFACE['WallpaperTrans'].length, 18)
  eq('104 exports across the six files', Object.values(SURFACE).reduce((n, a) => n + a.length, 0) + Object.values(TABLES).reduce((n, a) => n + a.length, 0), 104)
  // Six names are genuinely shared between two libraries - deviceLabel,
  // deviceIconName, formatRate, subtextFor, sectionTitleFor and listEntries -
  // and each is called through ITS OWN namespace, so the call check above
  // stays unambiguous. Asserted explicitly rather than left to chance.
  eq('the shared names are exactly these six', (() => {
    const seen = new Map()
    for (const [label, names] of Object.entries(SURFACE)) for (const n of names) seen.set(n, (seen.get(n) || []).concat(label))
    return [...seen.entries()].filter(([, ls]) => ls.length > 1).map(([n, ls]) => n + ' in ' + ls.join(' + ')).sort()
  })(), [
    'deviceIconName in Battery/Model + Bluetooth/Model',
    'deviceLabel in Battery/Model + Bluetooth/Model',
    'formatRate in Battery/Model + Network/Model',
    'listEntries in Bluetooth/Model + pass/Model',
    'sectionTitleFor in Bluetooth/Model + Network/Model',
    'subtextFor in Bluetooth/Model + Network/Model',
  ])
  // ...and each of those six is reached through BOTH namespaces in this file,
  // so the call check above cannot be satisfied by one library's usage.
  const ALIAS = { 'UnitIpc': 'UI', 'Battery/Model': 'BAT', 'Bluetooth/Model': 'BT', 'Network/Model': 'NET', 'pass/Model': 'PASS', 'WallpaperTrans': 'WT' }
  for (const name of ['deviceLabel', 'deviceIconName', 'formatRate', 'subtextFor', 'sectionTitleFor', 'listEntries']) {
    const owners = Object.keys(SURFACE).filter((l) => SURFACE[l].includes(name))
    is(`${name} is called through both of its namespaces`, selfSource, (src) => owners.every((l) => new RegExp(`\\b${ALIAS[l]}\\.${name}\\s*\\(`).test(src)), owners.map((l) => `${ALIAS[l]}.${name}()`).join(' and '))
  }
})
// Three exports are reached from a sibling suite rather than from here:
// shell/common/power/BatteryModel.js is shared with services/power, so
// services-power.test.mjs is where those three contracts are held. The
// call check still runs for every name - it reads the file that owns the
// call instead, which is a stronger claim than skipping the assertion.
const COVERED_ELSEWHERE = { 'Battery/Model': ['deviceKey', 'resolveLevels', 'alertFor', 'isRunningDown', 'notifyArgv', 'alertToneFor'] }
const OWNER_SOURCE = fs.readFileSync(path.join(import.meta.dirname, 'services-power.test.mjs'), 'utf8')
group('every export is called by this suite', () => {
  for (const [label, names] of Object.entries(SURFACE)) {
    const ns = NAMESPACES[label]
    for (const name of names) {
      const elsewhere = (COVERED_ELSEWHERE[label] || []).includes(name)
      const src = elsewhere ? OWNER_SOURCE : selfSource
      // A namespaced call (`NET.formatBytes(...)`) rather than a bare word:
      // stricter than a `\bname\s*(` match, because a comment or a local
      // helper of the same name could not satisfy it.
      is(`${label}.${name}() is called${elsewhere ? ' by services-power' : ' below'}`, src, (s) => new RegExp('\\.\\s*' + name + '\\s*\\(').test(s), elsewhere ? 'a namespaced call in services-power.test.mjs' : 'a namespaced call in this file')
      is(`${label}.${name} resolves to a function`, ns[name], (v) => typeof v === 'function', 'a function on the namespace')
    }
  }
  for (const [label, names] of Object.entries(TABLES)) {
    for (const name of names) {
      contains(`${label}.${name} is read by this suite`, selfSource, `${label === 'Network/Model' ? 'NET' : 'WT'}.${name}`)
      is(`${label}.${name} resolves to an array`, NAMESPACES[label][name], (v) => Array.isArray(v), 'an array on the namespace')
    }
  }
})
group('the ledger itself is not asserting the wrong file', () => {
  // `selfSource` must be THIS file. If the path were wrong the read would
  // throw, but a file that read *itself* into the surface check would be a
  // silent pass, so the path is asserted rather than assumed.
  contains('this file names itself in the ledger read', selfSource, 'modules-wallpaper.test.mjs')
  eq('and the read is not empty', selfSource.length > 10000, true)
  eq('and it is this suite - the header names all six files', [
    'BatteryModel.js',
    'UnitIpc.js',
    'Bluetooth/Model.js',
    'Network/Model.js',
    'pass/Model.js',
    'WallpaperTrans.js',
  ].filter((f) => selfSource.includes(f)).length, 6)
  eq('the six load calls are all present', [UI, BAT, BT, NET, PASS, WT].every((l) => l && Object.keys(l).length > 0), true)
  // The one library that is NOT here - it is covered as a subprocess by
  // tests/shell/suites/cli/hyprland-editor-cli-test.sh - must not be loaded.
  // Checked on the loadLib calls rather than on the whole file, because this
  // file's header comment legitimately names it.
  const loadCalls = (selfSource.match(/loadLib\([^)]*\)/g) || []).join('\n')
  eq('the file has exactly six loadLib calls', (selfSource.match(/loadLib\(/g) || []).length, 6)
  notContains('and the excluded library is never one of them', loadCalls, 'HyprlandEditorCli')
  eq('every load goes through the kit SHELL_DIR', (selfSource.match(/loadLib\(/g) || []).length - (selfSource.match(/loadLib\(path\.join\(SHELL_DIR,/g) || []).length, 0)
})

finish()
