#!/usr/bin/env node
// Suite: shell/common/power/BatteryModel.js - the three helpers
// services/power reads. Device key, alert levels, alert verdict.
//
// The file is shared with the Battery bar module, and its fourteen bar-side
// helpers (the level table, the row projections) are asserted in
// modules-wallpaper.test.mjs. These three are the services-side half and
// they are here for the reason the file lives in common/ at all: a
// services/ unit may not import features/, so the power services read
// battery policy through the same definitions the bar reads rather than
// through a copy. What is asserted is the contract each service is built
// on, not the QML around it:
//
//   deviceKey       one stable string per UPower device. Everything keyed on
//                   a device - the set of levels already announced, the
//                   watcher built for it - hangs off this, and a key that
//                   collapses two devices into one silently merges their
//                   state. UPowerDevice has no `id` and no `busName`, so a
//                   key built from either is always the bare type.
//   resolveLevels   two raw settings values into `{ warn, critical }`, both
//                   integers in 1..100 and always ordered critical < warn.
//                   The catalog checks each level's own range and cannot
//                   relate the two, so the ordering is this function's job.
//   alertFor        the most urgent level a sample has crossed, or "". One
//                   string out, so a sample below both thresholds cannot
//                   produce two cards for one event.
//   isRunningDown   which UPower states mean the charge is going down. Counts
//                   Unknown, which is what a Bluetooth HID peripheral reports
//                   for its whole connection: gating on the literal
//                   Discharging silences every gamepad and headset forever.
//   notifyArgv      the argv one alert is sent with, and alertToneFor the
//                   palette key it carries. The flag the glyph rides on is
//                   load-bearing: the card resolves shot.image first and
//                   never recolors it, so `-i` posts an untintable XDG theme
//                   glyph while `-n` reaches the shipped, recolorable asset.
//
// No assertion here pins a notification, a card or a theme value: this is
// the pure policy layer, and what the shell does with the verdict it
// returns is a live check rather than a source one.

import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, ne, is, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const BM = loadLib(path.join(SHELL_DIR, 'common/power/BatteryModel.js'))

suite('services-power', 'BatteryModel.js: deviceKey, resolveLevels, alertFor, isRunningDown, notifyArgv')

// The two paths UPower actually reports, one per device class: a sysfs
// power supply for a laptop battery, and an object path for a bluetooth
// peripheral. The bluetooth one is what makes the key worth having - it
// carries the adapter and the device address, so two headsets behind two
// adapters do not collapse.
const BAT0 = '/sys/class/power_supply/BAT0'
const HEADSET = '/org/bluez/hci0/dev_E3_FA_54_FF_5A_86'

// The levels the shipped defaults resolve to, and the pair the samples
// below are read against.
const DEFAULT_LEVELS = { warn: 20, critical: 5 }

// ---------------------------------------------------------------------------
section('deviceKey - one stable string per device')
// ---------------------------------------------------------------------------
group('the native path is the key when there is one', () => {
  eq('a sysfs power supply', BM.deviceKey(BAT0, 'Battery'), BAT0)
  eq('a bluetooth object path', BM.deviceKey(HEADSET, 'Headset'), HEADSET)
  // The path wins even when the type would have been enough, because the
  // type is the thing that is shared: every laptop battery reports
  // "Battery", every bluetooth mouse reports "Mouse".
  eq('the path wins over the type', BM.deviceKey(BAT0, 'LinePower'), BAT0)
})
group('the lowercased type stands in when there is no path', () => {
  eq('an empty path', BM.deviceKey('', 'Battery'), 'battery')
  eq('an absent path', BM.deviceKey(undefined, 'Headset'), 'headset')
  eq('the case is folded, so one device cannot key twice', BM.deviceKey('', 'UNKNOWN'), 'unknown')
  eq('a bluetooth device type', BM.deviceKey('', 'Headphones'), 'headphones')
})
group('whitespace is trimmed off both halves', () => {
  // UPower hands out "" for a device with no path, and a path read through
  // a binding can arrive padded. Neither may reach the key: an untrimmed
  // path is a different string from the same device's next read.
  eq('a padded path', BM.deviceKey('  ' + BAT0 + '  ', 'Battery'), BAT0)
  eq('a padded type', BM.deviceKey('', '  Battery  '), 'battery')
  eq('a padded type with mixed case', BM.deviceKey('', '\tHeadSET\n'), 'headset')
  // A path that is nothing but whitespace is no path at all, so the type
  // takes over rather than keying the device on "   ".
  eq('a whitespace-only path falls through to the type', BM.deviceKey('   ', 'Mouse'), 'mouse')
  eq('a whitespace-only path and a whitespace-only type', BM.deviceKey('  ', '\t '), '')
})
group('nothing to key on is an empty string, never undefined', () => {
  eq('two empty strings', BM.deviceKey('', ''), '')
  eq('no arguments at all', BM.deviceKey(), '')
  eq('two nulls', BM.deviceKey(null, null), '')
  eq('whitespace and undefined', BM.deviceKey('  ', undefined), '')
  // A map key must be a string: undefined would stringify as "undefined" in
  // a JS map and as "undefined" in a QML object, which is a key two
  // different devices could collide on.
  is('the result is always a string', BM.deviceKey(), (v) => typeof v === 'string', 'typeof "string"')
})
group('a non-string is treated as absent rather than stringified', () => {
  // D-Bus hands over undefined for a property the daemon does not report,
  // and a QML property read on a null object is undefined. Stringifying
  // either would key a device on the word "undefined".
  eq('a numeric path falls through to the type', BM.deviceKey(42, 'Battery'), 'battery')
  eq('a zero path falls through to the type', BM.deviceKey(0, 'Mouse'), 'mouse')
  eq('an object path falls through to the type', BM.deviceKey({}, 'Battery'), 'battery')
  eq('a numeric type with a real path keeps the path', BM.deviceKey(BAT0, 7), BAT0)
  eq('a numeric type with no path is absent', BM.deviceKey('', 7), '')
  eq('a numeric type with no path of its own', BM.deviceKey(42, 7), '')
})
group('the same device always keys the same, two devices never collide', () => {
  eq('the same device twice', BM.deviceKey(BAT0, 'Battery'), BM.deviceKey(BAT0, 'Battery'))
  ne('two batteries behind two adapters stay apart', BM.deviceKey('/sys/class/power_supply/BAT0', 'Battery'), BM.deviceKey('/sys/class/power_supply/BAT1', 'Battery'))
  ne('a bluetooth and a wired mouse stay apart', BM.deviceKey(HEADSET, 'Mouse'), BM.deviceKey('/sys/class/power_supply/mouse0', 'Mouse'))
})
group('the trap this function exists to avoid', () => {
  // A UPowerDevice carries neither `id` nor `busName` - checked against the
  // installed type description - so a key built from either is undefined and
  // every battery in the machine reads as the same bare type. Pinned here
  // because it is silent: the map still works, it just stops being per
  // device.
  const device = { type: 'Battery', nativePath: BAT0 }
  eq('reading the property the type does not have gives the bare type', BM.deviceKey(device.id, device.type), 'battery')
  eq('reading the native path gives the real key', BM.deviceKey(device.nativePath, device.type), BAT0)
  ne('and the two are not the same entry', BM.deviceKey(device.id, device.type), BM.deviceKey(device.nativePath, device.type))
  // Two path-less devices of one type therefore share a key. That is the
  // documented cost of a daemon that reports no identity for them, and it
  // is why the path is read first rather than as a tie-break.
  eq('two path-less devices of a type collapse, and that is pinned', BM.deviceKey('', 'Battery'), BM.deviceKey('', 'Battery'))
})

// ---------------------------------------------------------------------------
section('resolveLevels - two raw settings values into an ordered pair')
// ---------------------------------------------------------------------------
group('the shipped defaults come back unchanged', () => {
  eq('the defaults as numbers', BM.resolveLevels(20, 5), DEFAULT_LEVELS)
  // A setting that was never written reads as absent, and absent has to
  // mean the shipped default rather than a level of 1.
  eq('nothing set at all', BM.resolveLevels(), DEFAULT_LEVELS)
  eq('both null', BM.resolveLevels(null, null), DEFAULT_LEVELS)
  eq('both blank strings', BM.resolveLevels('', ''), DEFAULT_LEVELS)
  eq('both whitespace', BM.resolveLevels('   ', ' \t '), DEFAULT_LEVELS)
  eq('the defaults as the strings a settings store hands over', BM.resolveLevels('20', '5'), DEFAULT_LEVELS)
})
group('each level is coerced, rounded and clamped into 1..100', () => {
  eq('numeric strings', BM.resolveLevels('30', '10'), { warn: 30, critical: 10 })
  eq('rounds half up, not to even', BM.resolveLevels('20.5', '5'), { warn: 21, critical: 5 })
  eq('rounds a fraction above the half up', BM.resolveLevels('20.6', '5.4'), { warn: 21, critical: 5 })
  eq('rounds a fraction below the half down', BM.resolveLevels('20.4', '5.6'), { warn: 20, critical: 6 })
  eq('a level above 100 clamps to 100', BM.resolveLevels('400', '50'), { warn: 100, critical: 50 })
  eq('a level below 1 clamps to 1', BM.resolveLevels('20', '0'), { warn: 20, critical: 1 })
  eq('both levels clamp to the same end', BM.resolveLevels('400', '250'), { warn: 100, critical: 99 })
})
group('a value that is not a number falls back to its own default', () => {
  // Each level falls back independently, so one bad option does not reset
  // the other: a catalog that has not been edited yet hands over undefined
  // for both, and a hand-edited file can break one.
  eq('the warn level is not a number', BM.resolveLevels('soon', 5), { warn: 20, critical: 5 })
  eq('the critical level is not a number', BM.resolveLevels(20, 'soon'), { warn: 20, critical: 5 })
  eq('neither is a number', BM.resolveLevels('abc', 'xyz'), DEFAULT_LEVELS)
  eq('NaN', BM.resolveLevels(NaN, 5), { warn: 20, critical: 5 })
  eq('a NaN critical', BM.resolveLevels(20, NaN), { warn: 20, critical: 5 })
  eq('Infinity', BM.resolveLevels(Infinity, 5), { warn: 20, critical: 5 })
  eq('-Infinity', BM.resolveLevels(20, -Infinity), { warn: 20, critical: 5 })
  eq('a numeric string with trailing words', BM.resolveLevels('20 %', 5), { warn: 20, critical: 5 })
  // Number("") is 0 and Number("  ") is 0, both finite - a bare
  // Number() coercion would clamp them up to a 1% threshold and read as a
  // deliberate setting. Blank is checked before the coercion.
  eq('an empty string is blank, not zero', BM.resolveLevels('', 5), { warn: 20, critical: 5 })
  eq('a zero is a number, so it clamps to the floor', BM.resolveLevels(0, 0), { warn: 2, critical: 1 })
})
group('critical is pulled below warn when the two cross', () => {
  // The catalog validates each level's own range and cannot relate them, so
  // this pair is a setting it accepts and no reader can honour.
  eq('the two swapped', BM.resolveLevels(5, 20), { warn: 5, critical: 4 })
  eq('critical one above warn', BM.resolveLevels(5, 6), { warn: 5, critical: 4 })
  eq('critical well above warn', BM.resolveLevels(10, 90), { warn: 10, critical: 9 })
  eq('the two swapped and rounded', BM.resolveLevels('5.4', '20.6'), { warn: 5, critical: 4 })
  eq('a swapped level that does not coerce falls back first', BM.resolveLevels(5, 'soon'), { warn: 5, critical: 4 })
  eq('both clamped to 100 first', BM.resolveLevels(200, 200), { warn: 100, critical: 99 })
})
group('critical equal to warn is still crossed', () => {
  eq('the same level twice', BM.resolveLevels(5, 5), { warn: 5, critical: 4 })
  eq('at the warn default', BM.resolveLevels(20, 20), { warn: 20, critical: 19 })
  eq('at the floor', BM.resolveLevels(1, 1), { warn: 2, critical: 1 })
  eq('at the ceiling', BM.resolveLevels(100, 100), { warn: 100, critical: 99 })
})
group('a warn level at the floor moves the pair rather than dropping critical', () => {
  // warn 1 leaves no room below it, so `warn - 1` would be 0 and a level
  // would leave the 1..100 the settings page promises. The pair steps up
  // instead, and the critical level that was asked for is what it steps to.
  eq('warn at the floor, critical above it', BM.resolveLevels(1, 5), { warn: 6, critical: 5 })
  eq('warn at the floor, critical at the ceiling', BM.resolveLevels(1, 100), { warn: 100, critical: 99 })
  eq('warn at the floor, critical just above it', BM.resolveLevels(1, 2), { warn: 3, critical: 2 })
  eq('both at the floor', BM.resolveLevels(1, 1), { warn: 2, critical: 1 })
  // Both clamped to 1 before the ordering: 0 and -5 both reach the floor,
  // so the result is the floor case and not a level below it.
  eq('both clamped down to the floor', BM.resolveLevels(0, -5), { warn: 2, critical: 1 })
})
group('the invariants hold for every pair the settings page can produce', () => {
  // The sweep is the contract: whatever a hand-edited settings file or a
  // clamped catalog range hands over, both levels are integers in 1..100
  // and critical is strictly below warn. The uncrossed path and the crossed
  // path are both in here, and so are both ends of the range.
  const inputs = [undefined, '', 0, 1, 5, 20, 21, 100, 250, '30', 'soon', NaN]
  for (const warn of inputs) {
    for (const critical of inputs) {
      is(`resolveLevels(${String(warn)}, ${String(critical)}) is an ordered pair of levels in 1..100`,
        BM.resolveLevels(warn, critical),
        (v) => Number.isInteger(v.warn) && Number.isInteger(v.critical)
          && v.warn >= 1 && v.warn <= 100 && v.critical >= 1 && v.critical <= 100
          && v.critical < v.warn,
        'two integers in 1..100 with critical strictly below warn')
    }
  }
})

// ---------------------------------------------------------------------------
section('alertFor - the most urgent level a sample has crossed')
// ---------------------------------------------------------------------------
group('below critical is the critical alert', () => {
  eq('empty', BM.alertFor(0, DEFAULT_LEVELS), 'critical')
  eq('one under', BM.alertFor(4, DEFAULT_LEVELS), 'critical')
  eq('right at the threshold', BM.alertFor(5, DEFAULT_LEVELS), 'critical')
  eq('a bluetooth peripheral', BM.alertFor(3, DEFAULT_LEVELS), 'critical')
})
group('between the two thresholds is the warning alert', () => {
  eq('just above critical', BM.alertFor(6, DEFAULT_LEVELS), 'warn')
  eq('halfway', BM.alertFor(12, DEFAULT_LEVELS), 'warn')
  eq('right at the threshold', BM.alertFor(20, DEFAULT_LEVELS), 'warn')
})
group('above the warning threshold is no alert', () => {
  eq('just above warn', BM.alertFor(21, DEFAULT_LEVELS), '')
  eq('half way', BM.alertFor(60, DEFAULT_LEVELS), '')
  eq('full', BM.alertFor(100, DEFAULT_LEVELS), '')
})
group('a sample below both levels announces only the more urgent one', () => {
  // One string comes back, so one sample cannot produce two cards for one
  // event - which is what the shared notify-send replaces-id used to buy by
  // leaving only the last card of a burst on screen. The samples are
  // fractions because that is what UPower reports: normalizePct reads 1 as
  // a full device, so 1 is not a nearly-empty one.
  eq('a sample far below both', BM.alertFor(0.01, DEFAULT_LEVELS), 'critical')
  is('and it is a single level, not a list', BM.alertFor(0.01, DEFAULT_LEVELS),
    (v) => typeof v === 'string' && !v.includes(' '), 'one level name')
  eq('the levels are ordered, so warn is never the answer here', BM.alertFor(0.01, BM.resolveLevels(5, 20)), 'critical')
})
group('the 0..1 fraction UPower reports reads as a percentage', () => {
  // UPowerDevice.percentage arrives normalized: a full device reads 1
  // while the daemon says 100. A verdict that skipped normalizePct would
  // read every battery as empty, so the fraction is fed in as it arrives.
  eq('a fraction below critical', BM.alertFor(0.02, DEFAULT_LEVELS), 'critical')
  eq('a fraction right at critical', BM.alertFor(0.05, DEFAULT_LEVELS), 'critical')
  eq('a fraction between the two', BM.alertFor(0.1, DEFAULT_LEVELS), 'warn')
  eq('a fraction right at warn', BM.alertFor(0.2, DEFAULT_LEVELS), 'warn')
  eq('a fraction above warn', BM.alertFor(0.21, DEFAULT_LEVELS), '')
  eq('a full device reads 1 and is not an alert', BM.alertFor(1, DEFAULT_LEVELS), '')
  // Anything already above 1 is taken as percent and passes through, which
  // is what normalizePct does for every reader in the file.
  eq('an already-scaled percentage still works', BM.alertFor(100, DEFAULT_LEVELS), '')
  eq('a numeric string fraction', BM.alertFor('0.05', DEFAULT_LEVELS), 'critical')
})
group('a percentage that is not a number is not an alert', () => {
  // normalizePct reads a non-finite value as a full device, so an
  // unreadable sample is silence rather than a false alarm.
  eq('undefined', BM.alertFor(undefined, DEFAULT_LEVELS), '')
  eq('a word', BM.alertFor('soon', DEFAULT_LEVELS), '')
  eq('NaN', BM.alertFor(NaN, DEFAULT_LEVELS), '')
  // Number(null) and Number("") are both 0, which is finite, so they take
  // the empty reading rather than the full one. Pinned: it is the one input
  // where a missing value and a real 0% agree, and a reader has to know
  // which of the two it is looking at.
  eq('null reads as an empty device', BM.alertFor(null, DEFAULT_LEVELS), 'critical')
  eq('an empty string reads as an empty device', BM.alertFor('', DEFAULT_LEVELS), 'critical')
})
group('the verdict follows the levels it is handed', () => {
  // 10/90 crossed is a pair the catalog accepts and no reader could honour
  // raw, so it is the case worth driving a reader through: the pair comes
  // back as 10/9 and every verdict follows the resolved levels.
  const steep = BM.resolveLevels(10, 90)
  eq('a crossed pair keeps its own warn level', BM.alertFor(10, steep), 'warn')
  eq('and its own critical level', BM.alertFor(9, steep), 'critical')
  eq('a sample below both still announces only the critical one', BM.alertFor(0.01, steep), 'critical')
  eq('above both it is silent', BM.alertFor(11, steep), '')
  eq('with the shipped defaults', BM.alertFor(50, BM.resolveLevels(20, 5)), '')
  const tight = BM.resolveLevels(6, 5)
  eq('a pair one point apart', BM.alertFor(5, tight), 'critical')
  eq('and one above it', BM.alertFor(6, tight), 'warn')
})
group('a half-resolved pair alerts on the level it has and stays silent on the one it does not', () => {
  // A missing level coerces to NaN, and every comparison against NaN is
  // false. Treating it as 0 instead would alert on every sample, so the
  // missing half is the silent one.
  eq('no levels at all', BM.alertFor(0), '')
  eq('an empty pair', BM.alertFor(0, {}), '')
  eq('only the warn level', BM.alertFor(0.01, { warn: 20 }), 'warn')
  eq('and only the critical level', BM.alertFor(0.01, { critical: 5 }), 'critical')
  eq('levels that are not numbers', BM.alertFor(0, { warn: 'soon', critical: 'later' }), '')
})

// ---------------------------------------------------------------------------
section('isRunningDown - which UPower states mean the charge is going down')
// ---------------------------------------------------------------------------
// UPowerDeviceState, read off the installed type description.
const ST = { Unknown: 0, Charging: 1, Discharging: 2, Empty: 3, FullyCharged: 4, PendingCharge: 5, PendingDischarge: 6 }
const notRunningDown = (s) => BM.isRunningDown(s, ST.Charging, ST.FullyCharged, ST.PendingCharge)

group('the three states that mean the charge is NOT going down', () => {
  eq('charging', notRunningDown(ST.Charging), false)
  eq('fully charged', notRunningDown(ST.FullyCharged), false)
  eq('pending charge', notRunningDown(ST.PendingCharge), false)
})
group('the states that mean it is', () => {
  eq('discharging', notRunningDown(ST.Discharging), true)
  eq('empty', notRunningDown(ST.Empty), true)
  eq('pending discharge', notRunningDown(ST.PendingDischarge), true)
})
group('Unknown is the one that decides this, and it counts as running down', () => {
  // A Bluetooth HID peripheral exposes no charging property, so UPower has
  // nothing to derive from and reports Unknown for the whole connection, at
  // every level. Measured on one machine, same daemon and session:
  //
  //   Logitech G305       (hidpp)          State 2  Discharging
  //   Xbox Wireless Ctrl  (bluetooth hid)  State 0  Unknown
  //
  // Skipping Unknown reads "not discharging" as "not running down" and silences
  // every gamepad, keyboard and headset for as long as they stay connected.
  eq('unknown is running down', notRunningDown(ST.Unknown), true)
  // The cost of being wrong here is asymmetric, which is what makes it safe:
  // eligibility only matters below a threshold, because that is what alertFor
  // decides. So a false positive costs one alert on a healthy battery and a
  // false negative costs every alert on a dying one.
  eq('and the false positive needs the level to actually be crossed',
    BM.alertFor(0.9, BM.resolveLevels(20, 5)), '')
})
group('every state in the enumeration is decided', () => {
  // Pinned as a set rather than by count, so a member the enum grows later is
  // a new answer here instead of silently inheriting one of these.
  const decided = {}
  for (const name of Object.keys(ST)) decided[name] = notRunningDown(ST[name])
  eq('the verdicts', decided, {
    Unknown: true, Charging: false, Discharging: true, Empty: true,
    FullyCharged: false, PendingCharge: false, PendingDischarge: true,
  })
})
group('the three named states are the only exclusions', () => {
  // A state this function has not heard of is treated as running down, so a
  // daemon that grows a member alerts rather than going quiet. The enum is
  // fixed by UPower and closed, so this is a statement about the default rather
  // than a live concern.
  eq('an unknown state value is running down', notRunningDown(99), true)
  eq('and so is undefined', notRunningDown(undefined), true)
})

// ---------------------------------------------------------------------------
section('notifyArgv - the wire format the notification card receives')
// ---------------------------------------------------------------------------
// The card resolves its icon in a fixed order, and the two notify-send icon
// fields land in different legs of it:
//
//   -i icon  -> `image`    -> shot.image, returned FIRST and never recolored
//   -n icon  -> app_icon   -> shot.appIcon, the leg AppIcons.url threads the
//                             color key into, and the only leg Icons.url can
//                             repaint from shell/assets/icons
//
// Quickshell resolves an image-leg name to `image://icon/<name>`, an XDG
// icon-theme lookup. A card carrying that field cannot be tinted at all, and
// the palette hint is read into snapshot.iconColor and then has no leg to
// paint. So the flag is load-bearing and pinned here: `-i` renders an
// untintable theme glyph where the bar paints a recolored shipped one.
const argOf = (argv, flag) => {
  const i = argv.indexOf(flag)
  return i < 0 ? undefined : argv[i + 1]
}
const has = (argv, flag) => argv.indexOf(flag) >= 0

group('the glyph rides the recolorable leg, never the artwork leg', () => {
  const warn = BM.notifyArgv('warn', 'Keychron K3', 0.18)
  const crit = BM.notifyArgv('critical', 'Keychron K3', 0.04)
  eq('-n carries the icon', argOf(warn, '-n'), 'battery-2')
  eq('-i is absent', has(warn, '-i'), false)
  eq('-i is absent on the critical leg too', has(crit, '-i'), false)
  // The icon is the one the bar paints at that level: 18% is battery-2
  // (pills), 4% is battery-0 (whole outline).
  eq('the level icon follows the bar level table', argOf(crit, '-n'), 'battery-0')
  eq('and it never carries the charging bolt', BM.notifyArgv('warn', 'X', 0.18).includes('battery-charging'), false)
})
group('the tone is a palette key on the hint the card reads', () => {
  eq('warn asks for orange', argOf(BM.notifyArgv('warn', 'X', 0.18), '-h'), 'string:x-vb-icon-color:orange')
  eq('critical asks for red', argOf(BM.notifyArgv('critical', 'X', 0.04), '-h'), 'string:x-vb-icon-color:red')
  // A hex would freeze the colour at send time; Icons.url resolves a key
  // against the live palette, so a card still on screen after a theme switch
  // keeps the colour the new theme defines for that key.
  eq('never a literal hex', BM.notifyArgv('warn', 'X', 0.18).some((a) => /#[0-9a-f]{6}/i.test(a)), false)
  eq('alertToneFor agrees with the argv', [BM.alertToneFor('warn'), BM.alertToneFor('critical')], ['orange', 'red'])
})
group('urgency and timeout follow the level', () => {
  eq('warn is normal with a deadline', [argOf(BM.notifyArgv('warn', 'X', 0.18), '-u'), argOf(BM.notifyArgv('warn', 'X', 0.18), '-t')], ['normal', '15000'])
  eq('critical asks for no deadline', [argOf(BM.notifyArgv('critical', 'X', 0.04), '-u'), argOf(BM.notifyArgv('critical', 'X', 0.04), '-t')], ['critical', '0'])
})
group('the sender is the shell and no card shares a replaces-id', () => {
  eq('the app name is Vibranium', argOf(BM.notifyArgv('warn', 'X', 0.18), '-a'), 'Vibranium')
  // A shared id would let the second battery of a machine overwrite the first
  // one's alert, and the card carries the device label precisely so it can.
  eq('there is no replaces-id', has(BM.notifyArgv('critical', 'X', 0.04), '-r'), false)
})
group('the label plus level is the summary and the level is the body', () => {
  const argv = BM.notifyArgv('critical', 'Sony WH-1000XM4', 0.02)
  eq('the summary names the device and its level', argv[argv.length - 2], 'Sony WH-1000XM4 - 2%')
  eq('the body is the level sentence', argv[argv.length - 1], 'Battery is critically low')
  // The level reads once: the summary states it beside the label, and the
  // body keeps the sentence only, so the number appears exactly once.
  eq('no percentage in the body', /%/.test(argv[argv.length - 1]), false)
  eq('the summary states the rounded level', / - 2%/.test(argv[argv.length - 2]), true)
  eq('a warn summary reads the same shape', BM.notifyArgv('warn', 'Keychron K3', 0.18).slice(-2)[0], 'Keychron K3 - 18%')
})

finish()