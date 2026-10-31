#!/usr/bin/env node
// Drive shell/services/power/BatteryAlert.qml's policy with a synthetic
// device fleet, on a machine with no battery to discharge.
//
// A desktop has one AC adapter and, here, one mouse. That exercises neither
// the laptop AC/battery transition nor a drain, so the alert path has nothing
// to fire on. This harness supplies the missing half: a fleet of devices
// shaped exactly as Quickshell's UPowerDevice reports them, replayed through
// the discharge cycles the service actually implements.
//
// What is real here and what is not:
//
//   REAL    every decision. The device filter, the per-device level set, the
//           re-arm rule, the most-urgent-crossed verdict, the label, the icon
//           and the notify-send argv all come from the same
//           common/power/BatteryModel.js the running service calls, and the
//           orchestration below is the service's own _devicesChanged /
//           _evaluate / _pending / _announce step for step.
//   NOT     the QML object itself. `Connections`, `createObject`, `Settings`
//           and `Exec` need a live Quickshell runtime, so this re-derives
//           their inputs instead of constructing them. A disagreement between
//           the two would show up as a differing argv, which is the thing
//           worth checking.
//
// `percentage` arrives as the 0..1 fraction Quickshell's UPowerDevice
// reports (probed live, not the 0..100 UPower puts on the bus), and `type` is
// a UPowerDeviceType enum value. Getting either wrong is exactly how a second
// reader ends up with a different definition of "empty", so both are written
// the way the daemon writes them.
//
// Usage:
//   node tests/shell/demos/battery-alert-synthetic.mjs          # table only
//   node tests/shell/demos/battery-alert-synthetic.mjs --send   # post the cards
//
// --send fires the real notify-send argv at the real notification daemon, so
// the cards land in the running shell's pile exactly as the service's would.
// It is opt-in because it is visible on the user's desktop and a critical
// card is, by design, persistent.

import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { loadLib } from '../lib/qmlloader.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const SHELL_DIR = path.resolve(HERE, '../../../shell')
const BM = loadLib(path.join(SHELL_DIR, 'common/power/BatteryModel.js'))

// UPowerDeviceType, read off the installed type description
// (/usr/lib/qt6/qml/Quickshell/Services/UPower/quickshell-service-upower.qmltypes).
// Index matters: the service passes `d.type` straight to isTrackedType.
const TYPE = {
  Unknown: 0, LinePower: 1, Battery: 2, Ups: 3, Monitor: 4, Mouse: 5,
  Keyboard: 6, Pda: 7, Phone: 8, MediaPlayer: 9, Tablet: 10, Computer: 11,
  GamingInput: 12, Pen: 13, Touchpad: 14, Modem: 15, Network: 16,
  Headset: 17, Speakers: 18, Headphones: 19, Video: 20, OtherAudio: 21,
  RemoteControl: 22, Printer: 23, Scanner: 24, Camera: 25, Wearable: 26,
  Toy: 27, BluetoothGeneric: 28,
}

// UPowerDeviceState.
const STATE = {
  Unknown: 0, Charging: 1, Discharging: 2, Empty: 3, FullyCharged: 4,
  PendingCharge: 5, PendingDischarge: 6,
}

// The page's shipped defaults, as shell/22-power.jsonc declares them.
const WARN = 20
const CRITICAL = 5
const LEVELS = BM.resolveLevels(WARN, CRITICAL)

const SEND = process.argv.includes('--send')

// One synthetic device, shaped as Quickshell hands a UPowerDevice over.
function device(name, type, model, nativePath, pct, state) {
  return {
    name, type: TYPE[type], typeName: type, model, nativePath,
    percentage: pct / 100, state: STATE[state], stateName: state,
    isPresent: true, powerSupply: false, isLaptopBattery: type === 'Battery',
    energy: 0, energyCapacity: 0, changeRate: 0, timeToEmpty: 0, timeToFull: 0,
    healthPercentage: 0, healthSupported: false,
  }
}

// The fleet. Paths are the two shapes UPower really reports - a sysfs power
// supply and a bluez object path - plus this machine's own hidpp battery,
// which is a bare name with no directory at all, because that is what the
// live daemon returned for the attached mouse.
// The fleet. Paths are the two shapes UPower really reports - a sysfs power
// supply and a bluez object path - plus this machine's own hidpp battery,
// which is a bare name with no directory at all, because that is what the
// live daemon returned for the attached mouse.
//
// The two attached devices carry the state UPower ACTUALLY reports for them,
// measured over busctl on this machine: the Logitech mouse reads 2
// (Discharging) because HID++ exposes a charging property, and the connected
// Xbox controller reads 0 (Unknown) because a Bluetooth HID peripheral
// exposes none. That difference is the whole reason the service asks
// isRunningDown rather than testing for Discharging, so the fleet reproduces
// it rather than pretending every peripheral reports a charge state.
const FLEET = [
  device('laptop', 'Battery', 'ACME Lithium', '/sys/class/power_supply/BAT0', 24, 'Discharging'),
  device('mouse', 'Mouse', 'Logitech G305', 'hidpp_battery_0', 18, 'Discharging'),
  device('gamepad', 'GamingInput', 'Xbox Wireless Controller', '/org/bluez/hci0/dev_40_8E_2C_86_10_D2', 69, 'Unknown'),
  device('keyboard', 'Keyboard', 'Keychron K3', '/org/bluez/hci0/dev_1C_1B_4D_22_08_11', 4, 'Unknown'),
  device('headset', 'Headset', 'Sony WH-1000XM4', '/org/bluez/hci0/dev_E3_FA_54_FF_5A_86', 2, 'Unknown'),
  device('ups', 'Ups', 'APC Back-UPS 600', '/sys/class/power_supply/hybrid_power_supply', 80, 'Discharging'),
  device('ac', 'LinePower', '', '/sys/class/power_supply/AC', 0, 'Unknown'),
  device('mystery', 'Unknown', '', '', 1, 'Unknown'),
]

const bold = (s) => `\u001b[1m${s}\u001b[0m`
const dim = (s) => `\u001b[90m${s}\u001b[0m`
const green = (s) => `\u001b[32m${s}\u001b[0m`
const red = (s) => `\u001b[31m${s}\u001b[0m`
const yellow = (s) => `\u001b[33m${s}\u001b[0m`

// --- BatteryAlert.qml, step for step -------------------------------------

// _tracked: every type except the AC adapter and Unknown, minus anything
// explicitly absent.
function tracked(d) {
  if (d === null || d === undefined) return false
  if (d.isPresent === false) return false
  return BM.isTrackedType(d.type, TYPE.LinePower, TYPE.Unknown)
}

// _devicesChanged: file each arriving device under its key.
function build() {
  const entries = {}
  for (const d of FLEET) {
    if (!tracked(d)) continue
    const key = BM.deviceKey(d.nativePath, d.typeName.toLowerCase())
    if (key === '') continue
    entries[key] = { device: d, fired: {} }
  }
  return entries
}

// _pending: the most urgent crossed level this device has not announced yet.
// Mirrors BatteryAlert.qml's scan, which leads with the verdict and walks the
// levels below it only when the verdict is already armed.
const URGENT_FIRST = ['critical', 'warn']
function pending(verdict, pct, keep) {
  const start = URGENT_FIRST.indexOf(verdict)
  if (start < 0) return ''
  for (let i = start; i < URGENT_FIRST.length; i++) {
    const name = URGENT_FIRST[i]
    if (keep[name] === true) continue
    if (pct > LEVELS[name]) continue
    return name
  }
  return ''
}

// _evaluate: one device, one report. Returns the level announced, or ''.
function evaluate(entry, pct) {
  const d = entry.device
  // The real gate, not a copy of it: BatteryAlert.qml asks isRunningDown
  // rather than testing for Discharging, because a Bluetooth HID peripheral
  // reads Unknown for its whole connection and would otherwise never announce.
  const discharging = BM.isRunningDown(d.state, STATE.Charging, STATE.FullyCharged, STATE.PendingCharge)
  const was = entry.fired
  const keep = { warn: false, critical: false }
  if (discharging) {
    if (was.warn === true && pct <= LEVELS.warn) keep.warn = true
    if (was.critical === true && pct <= LEVELS.critical) keep.critical = true
  }
  const level = discharging
    ? pending(BM.alertFor(d.percentage, LEVELS), pct, keep)
    : ''
  if (level !== '') keep[level] = true
  entry.fired = keep
  return level
}

// _announce: the shared wire format, straight into notify-send.
function announce(d, level) {
  const label = BM.deviceLabel(d.model, d.typeName, d.nativePath)
  const argv = BM.notifyArgv(level, label, d.percentage)
  if (SEND) {
    // argv[0] is the program, as Exec.run wants it; spawnSync takes the
    // program separately, so passing the whole array would hand notify-send
    // its own name as the first positional and it would reject the rest.
    const r = spawnSync(argv[0], argv.slice(1), { encoding: 'utf8' })
    if (r.status !== 0) {
      console.error(dim('    notify-send failed: ' + (r.stderr || '').trim()))
      sent.push(null)
    }
  }
  return { label, argv }
}

// Pad on VISIBLE width. Every cell here is wrapped in an SGR escape before it
// is measured, so String.length would count the escape bytes and every column
// would be padded to a width no terminal agrees with.
const ANSI = /\u001b\[[0-9;]*m/g
const visible = (s) => String(s).replace(ANSI, '').length
const pad = (s, n) => String(s) + ' '.repeat(Math.max(0, n - visible(s)))
// Columns are sized once, across every row of the table, rather than per row.
// A per-row maximum would size each column to its own row's widest value and
// the table would not line up - which is what a hand-rolled width function
// gets wrong the moment the rows carry different data.
function table(rows, aligns) {
  const cols = Math.max(...rows.map((r) => r.length))
  const widths = []
  for (let c = 0; c < cols; c++) {
    widths[c] = Math.max(...rows.map((r) => (r[c] === undefined ? 0 : visible(r[c]))))
  }
  return rows.map((r) => '  ' + widths.map((w, c) => {
    if (c === cols - 1) return String(r[c] ?? '')
    const cell = String(r[c] ?? '')
    const text = aligns && aligns[c] === 'right' ? cell.padStart(w) : pad(cell, w)
    return text
  }).join('  ')).join('\n')
}
// Percentages are left-padded to a fixed width so a drain reads as a run of
// numbers at the same column.
const pct = (n) => String(n).padStart(3) + '%'

// --- the run --------------------------------------------------------------

console.log(bold('\nbattery alert - synthetic fleet'))
console.log(dim(`levels from the shipped page: warn ${LEVELS.warn}%, critical ${LEVELS.critical}%`))
console.log(dim(`argv from common/power/BatteryModel.js notifyArgv();${SEND ? ' posting to the notification daemon' : ' dry run, pass --send to post'}\n`))

console.log(bold('device filter - what a desktop with a full fleet sees'))
const entries = build()
console.log(table(FLEET.map((d) => {
  const key = BM.deviceKey(d.nativePath, d.typeName.toLowerCase())
  const kept = tracked(d) && key !== ''
  return [
    kept ? green('watched') : dim('skipped'),
    d.typeName,
    BM.deviceLabel(d.model, d.typeName, d.nativePath),
    pct(BM.normalizePct(d.percentage)),
    d.stateName,
    dim('key ' + (key === '' ? '<none>' : key)),
  ]
}), [null, null, null, 'right', null, null]))

console.log(bold('\ndischarge replay - the alerts each device earns'))
// Percentage sequences chosen to exercise the re-arm rule, not just the
// thresholds: each device dips under a level, comes back above it, and dips
// again, so a rule that forgot to re-arm would announce once and go quiet.
const REPLAYS = [
  { device: 'laptop', script: [24, 19, 18, 12, 22, 21, 20, 4, 9, 26] },
  { device: 'mouse', script: [18, 12, 8, 21, 20, 19, 4, 3, 30] },
  { device: 'gamepad', script: [69, 40, 19, 18, 22, 20, 6, 4] },
  { device: 'keyboard', script: [25, 6, 5, 4] },
  { device: 'headset', script: [30, 8, 2] },
  { device: 'ups', script: [80, 40, 21, 20] },
]

// One sample cell, packed to a fixed width so a drain reads across as a
// descending run of numbers rather than as ragged ones. The paint is applied
// AFTER the padding, so the escape bytes never count toward the width.
const SAMPLE_W = 17
function sample(v, level) {
  const text = pct(v) + (level ? ' ' + (level === 'critical' ? 'CRIT' : 'warn') + ' ' + BM.alertToneFor(level) : '')
  const paint = level === 'critical' ? red : level === 'warn' ? yellow : dim
  return paint(pad(text, SAMPLE_W))
}

const sent = []
const replayRows = []
for (const { device: name, script } of REPLAYS) {
  const src = FLEET.find((d) => d.name === name)
  const entry = entries[BM.deviceKey(src.nativePath, src.typeName.toLowerCase())]
  const d = entry.device
  const cells = [dim(name), d.typeName]
  for (const v of script) {
    d.percentage = v / 100
    const level = evaluate(entry, v)
    if (level !== '') sent.push(announce(d, level).argv)
    cells.push(v, level)
  }
  replayRows.push(cells)
}
console.log(table(replayRows.map((r) => {
  // Sample columns are packed to one width here rather than in sample(),
  // so table() is the only thing that decides a column's width.
  const out = r.slice(0, 2)
  for (let i = 2; i < r.length; i += 2) out.push(sample(r[i], r[i + 1]))
  return out
}), [null, null]))

console.log(bold('\nwhat went on the wire'))
for (const argv of sent) {
  if (argv === null) continue
  console.log('  ' + argv.map((a) => (a.startsWith('-') ? yellow(a) : a)).join(' '))
}

const posted = sent.filter((a) => a !== null).length
const refused = sent.length - posted
console.log(dim(`\n${sent.length} card(s) ${SEND ? 'built' : 'built'}` +
  (SEND ? `, ${posted} posted` + (refused ? `, ${refused} refused` : '') : '; pass --send to post') +
  '; none carries a replaces-id, so each device keeps its own card.'))
console.log(dim('the summary states the level beside the label; the body never repeats it.\n'))