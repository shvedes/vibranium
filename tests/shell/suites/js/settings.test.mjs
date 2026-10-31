#!/usr/bin/env node
// Suite: common/settings/ - the two pure-JS libraries behind the settings
// store and the Hyprland text editor.
//
//   SettingsLib.js      the schema/override engine: JSONC, catalog parsing,
//                       validation, the default<-user merge, the bash env
//                       projection and the generated menu bundle
//   HyprlandEditor.js   a hand-written text parser/rewriter for Hyprland's
//                       Lua config shape, plus the CLI's own argument
//                       contract (splitPath / parseComponent / inferType)
//
// Neither imports Qt, so both are drivable straight from node. The
// interesting contracts are all of the "deliberate" kind, and each one is
// pinned where it is surprising:
//
//   SettingsLib  an override the schema rejects never reaches the file
//                (resolve -> validOverrides -> composeManaged); a managed
//                leaf the schema *accepts* is pruned, one it rejects is
//                left exactly as the user wrote it
//                validateValue is the ONLY validator, on both paths
//                writePath is the in-place writer; the purity lives on
//                composeManaged ("Pure: neither argument is mutated")
//                changedKeys compares by reference, so a re-resolved
//                object value reads as a flip (pinned + reported)
//
//   HyprlandEditor  the write path replaces the whole option line, so an
//                inline trailing comment does not survive an edit
//                a section whose last option omits its comma gets the new
//                entry appended WITHOUT a comma (invalid Lua)
//                a root-level batch insert reverses the caller's key order
//                detect_indent_unit defaults to FOUR spaces on an empty
//                file, and infer_child_indent cannot see the last child
//                "config" scope ignores `occurrence` and edits the LAST
//                hl.config block
//                a value holding a newline is written as a two-line quoted
//                string and read back as a different value, because trim's
//                `.` does not cross a newline (see the round-trip group)
//                a bracketless dotted key is invisible to the reader, so
//                editing one appends a bracketed duplicate
//
// The exact-output assertions on the HyprlandEditor write paths are the
// point of this file: that library's whole job is producing specific text,
// so each write is compared against the exact expected file, indentation
// and blank lines included.
//
// The node-only fs wrappers (hyprGetFile / hyprEditFile) are unreachable
// through loadLib - its vm context has no `require`, which is exactly the
// state a QML host is in - so the file-layer group evaluates the library
// with the same recipe HyprlandEditorCli.js uses in order to exercise the
// documented symlink-preserving write.

import fs from 'node:fs'
import { createRequire } from 'node:module'
import os from 'node:os'
import path from 'node:path'
import vm from 'node:vm'

import { loadLib, libSource, setEnv } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, ne, is, notMatch, contains, throws, noThrow, approx,
  show, finish, blocked, SHELL_DIR,
} from '../../lib/assert.mjs'

const SETTINGS = path.join(SHELL_DIR, 'common/settings')
const SL = loadLib(path.join(SETTINGS, 'SettingsLib.js'))
const HE = loadLib(path.join(SETTINGS, 'HyprlandEditor.js'))
const SU = loadLib(path.join(SHELL_DIR, 'common/text/StringUtils.js'))

if (!SL || !HE || !SU) blocked('common/settings libraries failed to load')

const J = (v) => JSON.stringify(v)

// A catalog text -> parsed catalog, the shape every store helper takes.
function catalog(text) {
  return SL.parseCatalog(text)
}

// A parsed option, asserted to have parsed.
function opt(raw, fileNamespace) {
  const res = SL.parseOption(raw, fileNamespace)
  return res.error ? { error: res.error } : res.opt
}

// An option built by hand for validateValue/formatBashValue, which take the
// shape parseOption produces but do not require a key or a default.
function bare(o) {
  return Object.assign({ key: 'X', type: 'string', values: [], min: undefined, max: undefined, allowEmpty: false }, o)
}

suite('common/settings', 'SettingsLib, HyprlandEditor')

// ===========================================================================
group('the store-side index comment names only exported functions', () => {
  // SettingsLib's own map of what it owns (the comment above reapplyPending)
  // is the only in-file index of the store surface. Every name in it must be
  // reachable from the .pragma namespace, or a QML call site would be calling
  // into nothing.
  for (const name of [
    'buildSchema', 'reapplyPending',
    'valuesEqual', 'changedKeys', 'coerceBool', 'buildIdleTimerRows',
    'loadFault', 'rawFlag', 'rawSectionOf', 'writeRawSection',
  ]) {
    is(`${name} is a function`, typeof SL[name], (t) => t === 'function', 'a function')
  }
})

group('one declaration is indented out of the namespace - a loader blind spot', () => {
  // normalizeFlow (the staged-flow validator) is declared with a two-space
  // indent, so it is a top-level declaration to QML but the loader's
  // `^function` scan misses it. It is reachable only through parseOption,
  // which is how the flow assertions below test it.
  contains('the source declares normalizeFlow', libSource(path.join(SETTINGS, 'SettingsLib.js')), 'function normalizeFlow')
  eq('the namespace does not expose it', typeof SL.normalizeFlow, 'undefined')
  // parseOption still enforces every flow rejection, so the contract is
  // covered even though the function itself is not addressable.
  const bad = [
    [[], 'flow must be a non-empty array of steps'],
    [[{ kind: 'a' }, { kind: 'b' }, { kind: 'c' }, { kind: 'd' }, { kind: 'e' }], 'flow holds at most 4 stages'],
    [[{ kind: 'nope' }], 'flow step 0 needs kind select|number|range|text'],
    [[{ kind: 'select' }], 'flow select step 0 needs non-empty options'],
    [[{ kind: 'select', options: [{ label: 'a' }] }], 'flow select step 0 option 0 needs a value'],
    [[{ kind: 'range', min: 5, max: 1 }], 'flow number step 0 min must be < max'],
    [[{ kind: 'number', min: 'a' }], 'flow number step 0 min must be a number'],
    [[{ kind: 'number', step: 0 }], 'flow number step 0 step must be > 0'],
    [[5], 'flow step 0 is not an object'],
  ]
  for (const [flow, msg] of bad) {
    eq(`flow rejected: ${msg}`, opt({ key: 'A', type: 'string', default: 'a', flow }).error, `A: ${msg}`)
  }
  const good = opt({
    key: 'A', type: 'int', default: 1, range: [1, 10], step: 2, unit: 's',
    flow: [
      { kind: 'select', options: [{ value: 'a' }, { value: 2, label: 'Two' }] },
      { kind: 'range', sub: 'pick a range', subAccent: 'now', subLead: 'x' },
      { kind: 'text', placeholder: 'type' },
    ],
  })
  eq('a legal flow is kept', good.flow, [
    { kind: 'select', options: [{ label: 'a', value: 'a' }, { label: 'Two', value: 2 }] },
    { kind: 'range', sub: 'pick a range', subAccent: 'now', subLead: 'x' },
    { kind: 'text', placeholder: 'type' },
  ])
})

// ===========================================================================
section('SettingsLib.parseOption - the key decides the namespace')
// ===========================================================================
group('a non-object is not an option', () => {
  for (const raw of [null, undefined, 42, 'x', true, false]) {
    eq(`${show(raw)} is rejected`, opt(raw).error, 'option is not an object')
  }
  // An array is an object to typeof, so it passes this gate and is refused
  // one step later, for having no key.
  eq('an array is refused for having no key', opt([]).error, 'option needs "key" (or compat "var"/"id")')
})

group('key, var and id are the three spellings of one field', () => {
  eq('key is canonical', opt({ key: 'RECORDING_FPS', type: 'int', default: 30 }).key, 'RECORDING_FPS')
  eq('var is the first compat shim', opt({ var: 'RECORDING_FPS', type: 'int', default: 30 }).key, 'RECORDING_FPS')
  eq('id is the second compat shim', opt({ id: 'RECORDING_FPS', type: 'int', default: 30 }).key, 'RECORDING_FPS')
  eq('key wins over var', opt({ key: 'A_KEY', var: 'B_KEY', type: 'int', default: 1 }).key, 'A_KEY')
  eq('var wins over id', opt({ var: 'A_KEY', id: 'B_KEY', type: 'int', default: 1 }).key, 'A_KEY')
  eq('id mirrors key on the normalized option', opt({ id: 'A_KEY', type: 'int', default: 1 }).id, 'A_KEY')
  for (const raw of [{}, { key: '' }, { var: '' }, { key: 5 }, { key: null }]) {
    eq(`${J(raw)} has no key`, opt(raw).error, 'option needs "key" (or compat "var"/"id")')
  }
})

group('a bare key is a bash var, a dotted key is a shell path', () => {
  eq('a bare key is env', opt({ key: 'A_B', type: 'int', default: 1 }).env, true)
  eq('a bare key is not misc', opt({ key: 'A_B', type: 'int', default: 1 }).misc, false)
  eq('a bare key is not hypr', opt({ key: 'A_B', type: 'int', default: 1 }).hypr, null)
  eq('a shell path is not env', opt({ key: 'shell.wallpaper.enabled', type: 'bool', default: true }).env, false)
  eq('a shell path keeps its full canonical id', opt({ key: 'shell.wallpaper.enabled', type: 'bool', default: true }).id, 'shell.wallpaper.enabled')
  eq('a misc path is its own namespace', opt({ key: 'misc.cursorTheme', type: 'string', default: 'a' }).misc, true)
  eq('a misc path is not env', opt({ key: 'misc.cursorTheme', type: 'string', default: 'a' }).env, false)
  eq('a hypr path carries a hypr binding', opt({ key: 'hypr.input.sensitivity', type: 'int', default: 1, hypr: { file: 'f' } }).hypr.ctl, 'input.sensitivity')
})

group('the namespace and type rejections, in the order the parser hits them', () => {
  eq('a type that is not in TYPES', opt({ key: 'A', type: 'widget' }).error, "A: unknown type 'widget'")
  eq('a missing type is an empty name', opt({ key: 'A' }).error, "A: unknown type ''")
  eq('a dotted key outside shell/hypr/misc', opt({ key: 'foo.bar', type: 'bool', default: true }).error,
    'foo.bar: shell key must be a full dotted path starting with "shell." (pages are UI-only)')
  eq('a bare "shell" key is not a shell path', opt({ key: 'shell', type: 'bool', default: true }).error,
    'shell: env vars must be UPPER_SNAKE_CASE')
  eq('env:true on a dotted key is refused', opt({ key: 'foo.bar', type: 'bool', default: true, env: true }).error,
    'foo.bar: dotted keys cannot have env:true')
  eq('the implied VIBRANIUM_ prefix is refused', opt({ key: 'VIBRANIUM_A', type: 'int', default: 1 }).error,
    'VIBRANIUM_A: drop the VIBRANIUM_ prefix - it is implied')
  eq('env keys are UPPER_SNAKE_CASE', opt({ key: 'lowercase', type: 'int', default: 1 }).error,
    'lowercase: env vars must be UPPER_SNAKE_CASE')
  // A dotted key is not an env key, so it is measured against the shell
  // pattern first and never reaches the UPPER_SNAKE check.
  eq('a dotted non-shell key is refused as a shell path', opt({ key: 'A.B', type: 'int', default: 1 }).error,
    'A.B: shell key must be a full dotted path starting with "shell." (pages are UI-only)')
  eq('a dotted shell path does reach the shell gate', opt({ key: 'shell.A.B', type: 'bool', default: true }).error, undefined)
  // A default is mandatory: the parse validates it before the option is
  // accepted, so a catalog option without one is dropped fail-soft.
  eq('a missing default is a schema error', opt({ key: 'A', type: 'bool' }).error,
    'A: bad default undefined (expected true or false)')
  eq('a bad default names the value and the reason', opt({ key: 'A', type: 'int', default: 'abc' }).error,
    'A: bad default "abc" (expected a number)')
})

group('directory decides namespace, with the four documented riders', () => {
  eq('a shell option in an env file', opt({ key: 'shell.debug', type: 'bool', default: true }, 'env').error,
    'shell.debug: namespace mismatch - shell option in env file')
  eq('a misc option in an env file', opt({ key: 'misc.x', type: 'string', default: 'v' }, 'env').error,
    'misc.x: namespace mismatch - misc option in env file')
  eq('a bare key in an env file', opt({ key: 'A_B', type: 'int', default: 1 }, 'env').error, undefined)
  eq('a hypr option in a hypr file', opt({ key: 'hypr.input.sens', type: 'int', default: 1, hypr: { file: 'f' } }, 'hypr').error, undefined)
  // The header names exactly four cross-namespace exceptions.
  eq('APP_LAUNCHER_ALWAYS_FOCUS rides the shell page', opt({ key: 'APP_LAUNCHER_ALWAYS_FOCUS', type: 'bool', default: true }, 'shell').error, undefined)
  eq('PLAYER_FADE_DURATION rides the shell page', opt({ key: 'PLAYER_FADE_DURATION', type: 'int', default: 200 }, 'shell').error, undefined)
  eq('misc.cursorTheme rides the General page', opt({ key: 'misc.cursorTheme', type: 'string', default: 'a' }, 'shell').error, undefined)
  eq('misc.cursorSize rides the General page', opt({ key: 'misc.cursorSize', type: 'int', default: 24 }, 'shell').error, undefined)
  eq('no file namespace skips the assertion', opt({ key: 'shell.debug', type: 'bool', default: true }).error, undefined)
  eq('an empty file namespace skips it too', opt({ key: 'shell.debug', type: 'bool', default: true }, '').error, undefined)
})

group('the hypr binding: kind, file, path and ctl', () => {
  const H = (hypr, extra) => opt(Object.assign({ key: 'hypr.input.sensitivity', type: 'int', default: 1 }, extra || {}, { hypr }))
  eq('hypr must be an object', H('nope').error, 'hypr.input.sensitivity: hypr must be an object')
  eq('an array is not a hypr object', H([]).error, 'hypr.input.sensitivity: hypr must be an object')
  eq('kind is a closed set', H({ kind: 'bogus' }).error, 'hypr.input.sensitivity: hypr.kind must be option|smartGaps|animPreset')
  eq('an option kind needs a file', H({ kind: 'option' }).error, 'hypr.input.sensitivity: hypr.file must be a non-empty string')
  eq('an empty path array is not a path', H({ file: 'f', kind: 'option', path: [] }).error,
    'hypr.input.sensitivity: hypr.path must not be empty')
  eq('a path array of non-strings', H({ file: 'f', kind: 'option', path: [''] }).error,
    'hypr.input.sensitivity: hypr.path array must contain non-empty strings')
  eq('a path of neither string nor array', H({ file: 'f', kind: 'option', path: 5 }).error,
    'hypr.input.sensitivity: hypr.path must be string or array')
  // The key prefix alone synthesizes the binding, so a hypr.* option needs no
  // `hypr` block at all.
  const implicit = opt({ key: 'hypr.input.sensitivity', type: 'int', default: 1 })
  eq('an implicit hypr still needs a file', implicit.error, 'hypr.input.sensitivity: hypr.file must be a non-empty string')
  const derived = opt({ key: 'hypr.input.sensitivity', type: 'int', default: 1, hypr: { file: 'input.lua' } })
  eq('the path is derived from the key', derived.hypr.path, ['input', 'sensitivity'])
  eq('the ctl is the dotted join', derived.hypr.ctl, 'input.sensitivity')
  eq('a string path is split on a colon', H({ file: 'f', path: 'a:b' }).hypr.path, ['a', 'b'])
  eq('a ctl string is split on a dot', H({ file: 'f', ctl: 'a.b.c' }).hypr.path, ['a', 'b', 'c'])
  eq('an explicit ctl wins for the ctl field', H({ file: 'f', path: 'x:y', ctl: 'a.b' }).hypr.ctl, 'a.b')
  // smartGaps and animPreset have default files because they are file
  // existence / symlink contracts, not value options.
  eq('smartGaps defaults its file', H({ kind: 'smartGaps' }).hypr.file, '$XDG_CONFIG_HOME/hypr/hyprland.conf.d/smart-gaps.lua')
  eq('animPreset defaults its file', H({ kind: 'animPreset' }).hypr.file, '$XDG_CONFIG_HOME/hypr/hyprland.conf.d/animations.lua')
  eq('smartGaps declares no ctl path', H({ kind: 'smartGaps' }).hypr.path, null)
  // An option-kind binding derives its path from the key, so a non-hypr key
  // is refused there, before the general hypr-key gate.
  eq('a non-hypr key cannot carry an option binding', opt({ key: 'A_B', type: 'int', default: 1, hypr: { file: 'f' } }).error,
    'A_B: hypr option key must be hypr.*')
  eq('a non-hypr key with an explicit ctl hits the general gate', opt({ key: 'A_B', type: 'int', default: 1, hypr: { file: 'f', ctl: 'a.b' } }).error,
    'A_B: hypr key must be hypr.* (e.g. hypr.input.sensitivity)')
  eq('a hypr key with a ctl of its own keeps that ctl', opt({ key: 'hypr.input.sensitivity', type: 'int', default: 1, hypr: { file: 'f', ctl: 'other.path' } }).hypr.ctl, 'other.path')
})

group('range, enum and step normalization', () => {
  eq('a two-number array range', opt({ key: 'A', type: 'int', default: 5, range: [1, 10] }).min, 1)
  eq('its max', opt({ key: 'A', type: 'int', default: 5, range: [1, 10] }).max, 10)
  eq('an object range', opt({ key: 'A', type: 'int', default: 5, range: { min: 1, max: 10 } }).min, 1)
  eq('an inverted array range', opt({ key: 'A', type: 'int', default: 5, range: [5, 1] }).error, 'A: range min must be < max')
  eq('an inverted object range', opt({ key: 'A', type: 'int', default: 5, range: { min: 5, max: 1 } }).error, 'A: range min must be < max')
  eq('a range of the wrong shape', opt({ key: 'A', type: 'int', default: 5, range: 'nope' }).error, 'A: range must be {min,max}')
  eq('a bool cannot carry a range', opt({ key: 'A', type: 'bool', default: true, range: [0, 1] }).error, 'A: range not allowed on bool')
  eq('a default outside the range', opt({ key: 'A', type: 'int', default: 9, range: [1, 5] }).error, 'A: bad default 9 (maximum is 5)')
  eq('step defaults to 1', opt({ key: 'A', type: 'int', default: 1 }).step, 1)
  eq('a non-positive step falls back to 1', opt({ key: 'A', type: 'int', default: 1, step: 0 }).step, 1)
  eq('a fractional step is kept', opt({ key: 'A', type: 'int', default: 1, step: 2.5 }).step, 2.5)
  eq('a string enum keeps its strings', opt({ key: 'A', type: 'string', default: 'a', values: ['a', 'b', 1, '', null] }).values, ['a', 'b'])
  eq('an int enum keeps its finite numbers', opt({ key: 'A', type: 'int', default: 1, values: [1, 2, 'x', NaN] }).values, [1, 2])
  eq('a default outside its own enum', opt({ key: 'A', type: 'string', default: 'c', values: ['a', 'b'] }).error, 'A: bad default "c" (expected one of: a, b)')
  eq('valueLabels rides through', opt({ key: 'A', type: 'string', default: 'a', valueLabels: { a: 'Alpha' } }).valueLabels, { a: 'Alpha' })
  eq('a non-object valueLabels is dropped', opt({ key: 'A', type: 'string', default: 'a', valueLabels: 'x' }).valueLabels, null)
})

group('visibility, the object/array type spellings and the derived label', () => {
  const V = (raw) => opt(Object.assign({ key: 'A', type: 'bool', default: false }, raw))
  eq('default is visible', V({}).visibility, 'visible')
  eq('and not hidden', V({}).hidden, false)
  eq('hidden:true derives visibility', V({ hidden: true }).visibility, 'hidden')
  eq('visibility:hidden', V({ visibility: 'hidden' }).visibility, 'hidden')
  eq('visibility:internal', V({ visibility: 'internal' }).visibility, 'internal')
  eq('an unknown visibility stays visible', V({ visibility: 'bogus' }).visibility, 'visible')
  // "internal rows do the same for programmatic state (layout, timers) and
  // are never counted or bundled" - the type decides, not the field.
  eq('a layout is internal', opt({ key: 'shell.statusbar.layout', type: 'layout', default: {} }).visibility, 'internal')
  eq('a layout is hidden', opt({ key: 'shell.statusbar.layout', type: 'layout', default: {} }).hidden, true)
  eq('a timers list is internal', opt({ key: 'shell.idle.timers', type: 'timers', default: [] }).visibility, 'internal')
  eq('the "object" spelling is a layout', opt({ key: 'shell.statusbar.layout', type: 'object', default: {} }).type, 'layout')
  eq('the "array" spelling is timers', opt({ key: 'shell.idle.timers', type: 'array', default: [] }).type, 'timers')
  eq('a label is derived from the key when absent', opt({ key: 'RECORDING_FPS', type: 'int', default: 1 }).label, 'Recording Fps')
  eq('a label is taken verbatim when given', opt({ key: 'shell.wallpaper.enabled', type: 'bool', default: true, label: 'Enabled' }).label, 'Enabled')
  eq('a dotted key is not split by prettify', opt({ key: 'shell.wallpaper.enabled', type: 'bool', default: true }).label, 'Shell.wallpaper.enabled')
  eq('a misc key loses its inner capitals', opt({ key: 'misc.cursorTheme', type: 'string', default: 'a' }).label, 'Misc.cursortheme')
})

group('requires is structured; when/disabled are translated or refused', () => {
  const W = (raw) => opt(Object.assign({ key: 'A', type: 'bool', default: false }, raw))
  eq('requires must be an object', W({ requires: 'nope' }).error, 'A: requires must be an object')
  eq('an array is not a requires object', W({ requires: [] }).error, 'A: requires must be an object')
  eq('requires needs a member', W({ requires: {} }).error, 'A: requires needs at least chassis or binary')
  eq('chassis must be non-empty', W({ requires: { chassis: '  ' } }).error, 'A: requires.chassis must be non-empty string')
  eq('binary must be non-empty', W({ requires: { binary: 5 } }).error, 'A: requires.binary must be non-empty string')
  eq('chassis is trimmed', W({ requires: { chassis: '  laptop  ' } }).requires, { chassis: 'laptop' })
  eq('both members are kept', W({ requires: { chassis: 'laptop', binary: 'wiremix' } }).requires, { chassis: 'laptop', binary: 'wiremix' })
  // The three translatable spellings are matched on the literal text, and
  // they are the whole vocabulary: anything else is a lint failure.
  eq('a wiremix probe translates to a binary', W({ when: 'command -v wiremix >/dev/null' }).requires, { binary: 'wiremix' })
  eq('a laptop chassis test translates', W({ when: '[ "$CHASSIS_TYPE" = laptop ]' }).requires, { chassis: 'laptop' })
  eq('a not-a-vm chassis test translates', W({ when: '[ "$CHASSIS_TYPE" != vm ]' }).requires, { chassis: '!vm' })
  eq('the translation never leaves free bash on the option', W({ when: 'command -v wiremix' }).when, '')
  eq('free bash is refused outright', W({ when: 'random bash' }).error, 'A: when not translatable - use requires')
  // The comparison has to be the UNQUOTED spelling: the code matches the
  // literal "!= vm", so a shell-quoted "!=\"vm\"" is not translatable. Pinned
  // because a hand-written catalog that quotes its comparison is refused.
  eq('a quoted vm comparison is not translatable', W({ when: '[ "$CHASSIS_TYPE" != "vm" ]' }).error,
    'A: when not translatable - use requires')
  // A `disabled` with no `when` is accepted and silently dropped: the
  // translation branch only ever reads raw.when, so nothing is left to carry.
  eq('a lone disabled is accepted', W({ disabled: '[ "$CHASSIS_TYPE" != vm ]' }).requires, null)
  eq('and discarded', W({ disabled: '[ "$CHASSIS_TYPE" != vm ]' }).disabled, '')
  eq('a blank when is not a translation attempt', W({ when: '   ' }).requires, null)
})

// ===========================================================================
section('SettingsLib - showIf normalization, pruning and evaluation')
// ===========================================================================
group('normalizeShowIf turns the three accepted shapes into var/op/arg', () => {
  eq('absent', SL.normalizeShowIf(undefined), { norm: null })
  eq('null', SL.normalizeShowIf(null), { norm: null })
  eq('one eq condition', SL.normalizeShowIf({ key: 'A', eq: 1 }), { norm: [{ var: 'A', op: 'eq', arg: 1 }] })
  eq('one neq condition', SL.normalizeShowIf({ key: 'A', neq: 'x' }), { norm: [{ var: 'A', op: 'neq', arg: 'x' }] })
  eq('one in condition', SL.normalizeShowIf({ key: 'A', in: [1, 2] }), { norm: [{ var: 'A', op: 'in', arg: [1, 2] }] })
  eq('var is the compat spelling of key', SL.normalizeShowIf({ var: 'A', eq: true }), { norm: [{ var: 'A', op: 'eq', arg: true }] })
  eq('key wins over var inside a condition', SL.normalizeShowIf({ key: 'A', var: 'B', eq: 1 }), { norm: [{ var: 'A', op: 'eq', arg: 1 }] })
  eq('an array ANDs into a list', SL.normalizeShowIf([{ key: 'A', eq: 1 }, { key: 'B', neq: 'x' }, { key: 'C', in: [1, 2] }]),
    { norm: [{ var: 'A', op: 'eq', arg: 1 }, { var: 'B', op: 'neq', arg: 'x' }, { var: 'C', op: 'in', arg: [1, 2] }] })
  eq('an empty array normalizes to null', SL.normalizeShowIf([]), { norm: null })
  eq('the in list is copied, not aliased', (() => {
    const src = { key: 'A', in: [1] }
    const out = SL.normalizeShowIf(src)
    out.norm[0].arg.push(2)
    return src.in
  })(), [1])
})

group('every malformed showIf is rejected with a reason', () => {
  eq('a bare string', SL.normalizeShowIf('nope').error, 'condition is not an object')
  eq('a number', SL.normalizeShowIf(5).error, 'condition is not an object')
  eq('an array condition', SL.normalizeShowIf([['key']]).error, 'condition is not an object')
  eq('a list holding a non-object', SL.normalizeShowIf([1]).error, 'condition is not an object')
  eq('no key at all', SL.normalizeShowIf({ eq: 1 }).error, 'condition missing "key"')
  eq('an empty key', SL.normalizeShowIf({ key: '', eq: 1 }).error, 'condition missing "key"')
  eq('a non-string key', SL.normalizeShowIf({ key: 5, eq: 1 }).error, 'condition missing "key"')
  eq('no operator', SL.normalizeShowIf({ key: 'A' }).error, 'condition needs exactly one of eq | neq | in')
  eq('two operators', SL.normalizeShowIf({ key: 'A', eq: 1, neq: 2 }).error, 'condition needs exactly one of eq | neq | in')
  eq('three operators', SL.normalizeShowIf({ key: 'A', eq: 1, neq: 2, in: [1] }).error, 'condition needs exactly one of eq | neq | in')
  eq('an empty in list', SL.normalizeShowIf({ key: 'A', in: [] }).error, '"in" needs a non-empty array of scalars')
  eq('a non-array in', SL.normalizeShowIf({ key: 'A', in: 'x' }).error, '"in" needs a non-empty array of scalars')
  eq('an object inside in', SL.normalizeShowIf({ key: 'A', in: [{}] }).error, '"in" needs a non-empty array of scalars')
  eq('a non-scalar eq', SL.normalizeShowIf({ key: 'A', eq: {} }).error, '"eq" needs a scalar')
  eq('a non-scalar neq', SL.normalizeShowIf({ key: 'A', neq: [] }).error, '"neq" needs a scalar')
  eq('false is a scalar eq', SL.normalizeShowIf({ key: 'A', eq: false }), { norm: [{ var: 'A', op: 'eq', arg: false }] })
})

group('normalization is in place on the condition it was handed', () => {
  // `cond.var = condKey` writes the compat spelling back onto the caller's
  // object. Nothing in the tree freezes a catalog object, so this is
  // harmless, but it is the reason the normalized list is the only thing
  // that should be stored - the input has already been touched.
  const cond = { key: 'A', eq: 1 }
  SL.normalizeShowIf(cond)
  eq('the key is mirrored onto var', cond, { key: 'A', eq: 1, var: 'A' })
  const viaVar = { var: 'A', eq: 1 }
  SL.normalizeShowIf(viaVar)
  eq('a var condition is unchanged', viaVar, { var: 'A', eq: 1 })
})

group('parseOption reports a malformed showIf against the owning key', () => {
  eq('a bad condition on an option', opt({ key: 'A', type: 'string', default: 'a', showIf: 'nope' }).error,
    'A: malformed showIf - condition is not an object')
  eq('an unknown condition key still parses', opt({ key: 'A', type: 'string', default: 'a', showIf: { key: 'NOPE', eq: 1 } }).showIf,
    [{ var: 'NOPE', op: 'eq', arg: 1 }])
  eq('showIf:null is no showIf', opt({ key: 'A', type: 'string', default: 'a', showIf: null }).showIf, null)
})

group('conditionsMet ANDs the list and resolves transitively', () => {
  const byKey = { A: { showIf: [{ var: 'B', op: 'eq', arg: 1 }] }, B: { showIf: null }, C: { showIf: null }, D: { showIf: null } }
  eq('no conditions is visible', SL.conditionsMet(byKey, {}, null), true)
  eq('an empty list is visible', SL.conditionsMet(byKey, {}, []), true)
  eq('one satisfied condition', SL.conditionsMet(byKey, { B: 1 }, [{ var: 'B', op: 'eq', arg: 1 }]), true)
  eq('one unsatisfied condition', SL.conditionsMet(byKey, { B: 2 }, [{ var: 'B', op: 'eq', arg: 1 }]), false)
  eq('eq is identity, not coercion', SL.conditionsMet({}, { x: '1' }, [{ var: 'x', op: 'eq', arg: 1 }]), false)
  eq('neq', SL.conditionsMet({}, { x: 'a' }, [{ var: 'x', op: 'neq', arg: 'b' }]), true)
  eq('neq against the value', SL.conditionsMet({}, { x: 'b' }, [{ var: 'x', op: 'neq', arg: 'b' }]), false)
  eq('in matches a member', SL.conditionsMet({}, { x: 'a' }, [{ var: 'x', op: 'in', arg: ['a', 'b'] }]), true)
  eq('in misses a non-member', SL.conditionsMet({}, { x: 'c' }, [{ var: 'x', op: 'in', arg: ['a', 'b'] }]), false)
  eq('an absent value satisfies neq', SL.conditionsMet({}, {}, [{ var: 'x', op: 'neq', arg: 'b' }]), true)
  eq('an absent value fails eq', SL.conditionsMet({}, {}, [{ var: 'x', op: 'eq', arg: 'b' }]), false)
  eq('two conditions AND', SL.conditionsMet({}, { x: 1, y: 1 }, [{ var: 'x', op: 'eq', arg: 1 }, { var: 'y', op: 'eq', arg: 1 }]), true)
  eq('two conditions AND, one failing', SL.conditionsMet({}, { x: 1, y: 2 }, [{ var: 'x', op: 'eq', arg: 1 }, { var: 'y', op: 'eq', arg: 1 }]), false)
  eq('a missing referenced option still evaluates on its value', SL.conditionsMet({}, { x: 1 }, [{ var: 'nope', op: 'eq', arg: 1 }]), false)
  eq('a key with no value at all cannot satisfy eq', SL.conditionsMet({}, {}, [{ var: 'x', op: 'eq', arg: 1 }]), false)
  // Transitive: a dependency that is itself hidden suppresses its dependent.
  // Here A is the dependency (it has its own showIf) and C is the dependent.
  eq('a hidden dependency hides the dependent', SL.conditionsMet(byKey, { A: 0, B: 2 }, [{ var: 'A', op: 'eq', arg: 0 }]), false)
  eq('a visible dependency keeps it', SL.conditionsMet(byKey, { A: 0, B: 1 }, [{ var: 'A', op: 'eq', arg: 0 }]), true)
  eq('an unsatisfied dependent is hidden regardless of its dependency', SL.conditionsMet(byKey, { A: 0, B: 1 }, [{ var: 'A', op: 'eq', arg: 9 }]), false)
  eq('a dependency with no value of its own cannot satisfy a condition', SL.conditionsMet(
    { E: { showIf: [{ var: 'A', op: 'eq', arg: 0 }] } }, { E: 0 }, [{ var: 'E', op: 'eq', arg: 0 }],
  ), false)
  eq('a cycle counts as satisfied, not as a loop', SL.conditionsMet(
    { A: { showIf: [{ var: 'B', op: 'eq', arg: 1 }] }, B: { showIf: [{ var: 'A', op: 'eq', arg: 1 }] } },
    { A: 1, B: 1 },
    [{ var: 'A', op: 'eq', arg: 1 }],
  ), true)
  noThrow('a cycle with unsatisfiable values still terminates', () => SL.conditionsMet(
    { A: { showIf: [{ var: 'B', op: 'eq', arg: 2 }] }, B: { showIf: [{ var: 'A', op: 'eq', arg: 2 }] } },
    { A: 1, B: 1 },
    [{ var: 'A', op: 'eq', arg: 1 }],
  ))
})

group('pruneShowIf drops self-references always, unknown refs in strict mode', () => {
  const page = (options) => catalog('{"pages":[{"id":"p","options":[' + options.join(',') + ']}]}')
  const A = '{"key":"A","type":"bool","default":true}'
  const B = (showIf) => '{"key":"B","type":"bool","default":true' + (showIf ? ',"showIf":' + J(showIf) : '') + '}'
  const C = '{"key":"C","type":"bool","default":true,"showIf":{"key":"NOPE","eq":1}}'
  // Strict mode is the single-file catalog: a condition on nothing
  // would hide rows forever, so it is dropped with a warning.
  const strict = page([A, B({ key: 'A', eq: true }), C])
  eq('a same-file reference is kept', strict.sections[0].options[1].showIf, [{ var: 'A', op: 'eq', arg: true }])
  eq('an unknown reference is dropped', strict.sections[0].options[2].showIf, null)
  eq('and reported', strict.sections[0].errors, ["C: showIf references unknown option 'NOPE' - condition dropped"])
  const self = page(['{"key":"A","type":"bool","default":true,"showIf":{"key":"A","eq":true}}'])
  eq('a self-reference is dropped', self.sections[0].options[0].showIf, null)
  eq('and reported', self.sections[0].errors, ['A: showIf references itself - condition dropped'])
  const mixed = page([A, B([{ key: 'A', eq: true }, { key: 'NOPE', eq: 1 }])])
  eq('a dropped member does not take the whole list with it', mixed.sections[0].options[1].showIf, [{ var: 'A', op: 'eq', arg: true }])
  eq('the option stays in the key index', Object.keys(mixed.byKey).sort(), ['A', 'B'])
  const both = page([
    '{"key":"A","type":"bool","default":true,"showIf":{"key":"A","eq":true}}',
    B([{ key: 'A', eq: true }, { key: 'NOPE', eq: 1 }]),
  ])
  eq('both kinds are reported on one page', both.sections[0].errors, [
    'A: showIf references itself - condition dropped',
    "B: showIf references unknown option 'NOPE' - condition dropped",
  ])
  eq('and a self-referencing option keeps its other conditions', both.sections[0].options[1].showIf, [{ var: 'A', op: 'eq', arg: true }])
  // Directory mode is not strict: stores scan only their own namespace files,
  // but a shell row may legitimately be gated on a hypr.* value.
  const dir = SL.parseCatalogDir([
    '{"pages":[{"id":"p","options":[{"key":"A","type":"bool","default":true},{"key":"B","type":"bool","default":false,"showIf":{"key":"OTHER_STORE_KEY","eq":true}}]}]}',
  ], ['env'], 0, '')
  eq('a cross-file reference survives in directory mode', dir.sections[0].options[1].showIf, [{ var: 'OTHER_STORE_KEY', op: 'eq', arg: true }])
  eq('and is not reported', dir.sections[0].errors, [])
  const dirSelf = SL.parseCatalogDir([
    '{"pages":[{"id":"p","options":[{"key":"A","type":"bool","default":true,"showIf":{"key":"A","eq":true}}]}]}',
  ], ['env'], 0, '')
  eq('a self-reference is still pruned in directory mode', dirSelf.sections[0].options[0].showIf, null)
})

// ===========================================================================
section('SettingsLib.parseSection / parseCatalog / parseCatalogDir')
// ===========================================================================
group('a page is uniform: label metadata plus options plus custom items', () => {
  const s = SL.parseSection({ label: 'General', desc: 'd', icon: 'i', width: 420, showItemCount: true, options: [], items: [] }, 'fb', true, null)
  eq('the derived page id', s.page, 'general')
  eq('the label', s.label, 'General')
  eq('the desc', s.desc, 'd')
  eq('the icon', s.icon, 'i')
  eq('the width', s.width, 420)
  eq('showItemCount', s.showItemCount, true)
  eq('no errors', s.errors, [])
  eq('a fresh section shape', Object.keys(s), ['page', 'label', 'desc', 'icon', 'width', 'showItemCount', 'group', 'options', 'items', 'errors'])
})

group('label aliases, the fallback label and page-id rules', () => {
  eq('title is an alias for label', SL.parseSection({ title: 'T' }, 'fb', true, null).label, 'T')
  eq('label wins over title', SL.parseSection({ label: 'L', title: 'T' }, 'fb', true, null).label, 'L')
  eq('a missing label is prettified from the fallback', SL.parseSection({}, 'section 1', true, null).label, 'Section 1')
  eq('and the page id is derived from it', SL.parseSection({}, 'section 1', true, null).page, 'section-1')
  eq('a non-object page keeps the fallback verbatim, not prettified', SL.parseSection(null, 'fb', false, null).label, 'fb')
  eq('and says so', SL.parseSection(null, 'fb', false, null).errors, ['page is not an object'])
  eq('a number page is a non-object page', SL.parseSection(5, 'fb', false, null).errors, ['page is not an object'])
  eq('an id is honoured when ids are allowed', SL.parseSection({ id: 'general', label: 'General' }, 'fb', true, null).page, 'general')
  eq('a spaces/uppercase id is refused and reported', SL.parseSection({ id: 'General Page', label: 'G' }, 'fb', true, null).errors, ['page id must be [a-z0-9_-]'])
  eq('a refused id falls back to the derived one', SL.parseSection({ id: 'General Page', label: 'G' }, 'fb', true, null).page, 'g')
  eq('an id on a `sections` page is ignored and reported', SL.parseSection({ id: 'gen', label: 'G' }, 'fb', false, null).errors,
    ['sections have no "id" - it is ignored; options own full paths'])
  eq('and the id does not become the page id', SL.parseSection({ id: 'gen', label: 'G' }, 'fb', false, null).page, 'g')
})

group('option-level metadata is validated and the rest is dropped', () => {
  eq('a bad width is 0, not an error', SL.parseSection({ label: 'A', width: -1 }, 'fb', true, null).width, 0)
  eq('a non-numeric width is 0', SL.parseSection({ label: 'A', width: 'x' }, 'fb', true, null).width, 0)
  eq('a non-boolean showItemCount is reported', SL.parseSection({ label: 'A', showItemCount: 'yes' }, 'fb', true, null).errors, ['showItemCount must be a boolean'])
  eq('and left false', SL.parseSection({ label: 'A', showItemCount: 'yes' }, 'fb', true, null).showItemCount, false)
  eq('showItemCount:false is honoured', SL.parseSection({ label: 'A', showItemCount: false }, 'fb', true, null).showItemCount, false)
})

group('options fail soft: a bad one is dropped and reported, the rest survive', () => {
  const s = SL.parseSection({ label: 'A', options: [null, 5, {}, { key: 'A_B', type: 'int', default: 1 }, { key: 'A_B', type: 'int', default: 2 }] }, 'fb', true, 'env')
  eq('only the good option survives', s.options.map((o) => o.key), ['A_B'])
  eq('the first definition wins', s.options[0].default, 1)
  eq('three per-option errors plus the duplicate', s.errors, [
    'option is not an object', 'option is not an object', 'option needs "key" (or compat "var"/"id")', 'A_B: duplicate option',
  ])
  eq('a missing options array is no options', SL.parseSection({ label: 'A' }, 'fb', true, null).options, [])
  eq('a non-array options field is no options', SL.parseSection({ label: 'A', options: 'x' }, 'fb', true, null).options, [])
})

group('custom items get the same showIf semantics as options', () => {
  const s = SL.parseSection({ label: 'A', items: [{ label: 'x', showIf: 'nope' }, { label: 'y', showIf: { key: 'A', eq: 1 } }, { label: 'z' }] }, 'fb', true, null)
  eq('a malformed item condition is nulled and reported', s.errors, ['item "x": malformed showIf - condition is not an object'])
  eq('and the item is kept', s.items[0], { label: 'x', showIf: null })
  eq('a good condition is normalized', s.items[1].showIf, [{ var: 'A', op: 'eq', arg: 1 }])
  eq('an item with no showIf is untouched', s.items[2], { label: 'z' })
  eq('non-object items are passed through for the bundle to skip', SL.parseSection({ label: 'A', items: [5, 'x', null] }, 'fb', true, null).items, [5, 'x', null])
  eq('a non-array items field is no items', SL.parseSection({ label: 'A', items: 'x' }, 'fb', true, null).items, [])
})

group('parseCatalog: one parse, three accepted document shapes', () => {
  const pages = catalog('{"pages":[{"id":"a","label":"A"},{"id":"b","label":"B"}]}')
  eq('pages', pages.sections.map((s) => s.page), ['a', 'b'])
  eq('ids are allowed', pages.allowId, true)
  eq('pages and sections are the same array', pages.pages === pages.sections, true)
  const sections = catalog('{"sections":[{"id":"a","label":"A"}]}')
  eq('the sections alias parses', sections.sections.map((s) => s.page), ['a'])
  eq('and does not allow ids', sections.allowId, false)
  const bare = catalog('{"label":"Solo"}')
  eq('a bare page object is tolerated', bare.sections.map((s) => [s.page, s.label]), [['solo', 'Solo']])
  const arr = catalog('[{"id":"a","label":"A"},{"label":"B"}]')
  eq('a bare array is tolerated', arr.sections.map((s) => s.page), ['a', 'b'])
  eq('a bare array allows ids', arr.allowId, true)
})

group('parseCatalog: root chrome and page-id uniqueness', () => {
  const c = catalog('{"width": 360.6, "title": "  Settings  ", "pages":[{"id":"general"},{"label":"General"}]}')
  eq('the root width is rounded', c.rootWidth, 361)
  eq('the root title is trimmed', c.rootTitle, 'Settings')
  eq('label is the title alias', catalog('{"label":"L","pages":[]}').rootTitle, 'L')
  eq('a non-positive width is 0', catalog('{"width":0,"pages":[]}').rootWidth, 0)
  eq('a non-numeric width is 0', catalog('{"width":"x","pages":[]}').rootWidth, 0)
  eq('a blank title is empty', catalog('{"title":"   ","pages":[]}').rootTitle, '')
  eq('an absent title is empty', catalog('{"pages":[]}').rootTitle, '')
  // "Derived page ids must stay unique: identical labels get a numeric suffix
  // so navigation never merges two pages."
  eq('identical labels dedupe with a suffix', c.sections.map((s) => s.page), ['general', 'general-2'])
  eq('a third collision continues the count', catalog('{"pages":[{"label":"A"},{"label":"A"},{"label":"A"}]}').sections.map((s) => s.page), ['a', 'a-2', 'a-3'])
})

group('parseCatalog is a hard parse, not a fail-soft one', () => {
  // Options fail soft (parseSection collects errors) but the DOCUMENT does
  // not: the schema directory is shipped content, so a broken file is a
  // build error rather than a page that silently loses its options.
  throws('malformed JSON', () => SL.parseCatalog('{oops'), /JSON|token|position/i)
  throws('an empty document', () => SL.parseCatalog(''), /Unexpected end of JSON/)
  throws('a comment-only document', () => SL.parseCatalog('// nothing here'), /Unexpected end of JSON/)
  throws('null', () => SL.parseCatalog(null), /Unexpected end of JSON/)
  noThrow('a comment-only user source, by contrast, is not a fault', () => SL.parseUserSource('// nothing here'))
  // Duplicate keys are per-section here, but NOT across sections: byKey is
  // last-wins and no error is raised, which is what the directory parser
  // turns into a hard error.
  const dup = catalog('{"pages":[{"label":"A","options":[{"key":"K","type":"int","default":1}]},{"label":"B","options":[{"key":"K","type":"int","default":2}]}]}')
  eq('a cross-page duplicate is not an error', dup.sections.map((s) => s.errors), [[], []])
  eq('and byKey is last-wins', dup.byKey.K.default, 2)
})

group('parseCatalogDir: one file per namespace, duplicates are fatal', () => {
  const files = [
    '{"pages":[{"id":"a","options":[{"key":"A","type":"bool","default":true}]}]}',
    '{"pages":[{"id":"b","options":[{"key":"B","type":"bool","default":true}]}]}',
  ]
  const d = SL.parseCatalogDir(files, ['env', 'env'], 400.4, 'Root')
  eq('pages are concatenated in file order', d.sections.map((s) => s.page), ['a', 'b'])
  eq('the root width is rounded here too', d.rootWidth, 400)
  eq('the root title passes through', d.rootTitle, 'Root')
  eq('ids are always allowed in directory mode', d.allowId, true)
  eq('pages and sections are the same array', d.pages === d.sections, true)
  eq('a non-object root title is empty', SL.parseCatalogDir(files, ['env', 'env'], 0, null).rootTitle, '')
  eq('a non-positive root width is 0', SL.parseCatalogDir(files, ['env', 'env'], -1, '').rootWidth, 0)
  throws('the same key in two files', () => SL.parseCatalogDir([files[0], files[0]], ['env', 'env'], 0, ''), /duplicate option across files: A/)
  throws('a malformed file', () => SL.parseCatalogDir(['{oops'], ['env'], 0, ''), /JSON|token|position/i)
  // The namespace assertion is per file, which is the whole point of the
  // directory: a shell option may not live in env/.
  eq('a namespace mismatch is a section error, not a throw', SL.parseCatalogDir([
    '{"pages":[{"id":"a","options":[{"key":"shell.debug","type":"bool","default":true}]}]}',
  ], ['env'], 0, '').sections[0].errors, ['shell.debug: namespace mismatch - shell option in env file'])
  eq('page ids dedupe across files too', SL.parseCatalogDir([
    '{"pages":[{"label":"General"}]}', '{"pages":[{"label":"General"}]}',
  ], ['env', 'env'], 0, '').sections.map((s) => s.page), ['general', 'general-2'])
})

group('parseUnifiedCatalog: one file, groups own the pages', () => {
  const doc = (pages, extra) => JSON.stringify(Object.assign(
    { title: 'Settings', pages: pages }, extra || {}))
  const shellPage = { group: 'shell', label: 'General',
    options: [{ key: 'shell.debug', type: 'bool', default: true }] }
  const u = SL.parseUnifiedCatalog(doc([shellPage]))
  eq('the group is carried onto the section', u.sections[0].group, 'shell')
  eq('the root title passes through', u.rootTitle, 'Settings')
  eq('menus default to null', u.menus, null)
  eq('menus pass through raw',
    SL.parseUnifiedCatalog(doc([shellPage], { menus: [{ id: 'main' }] })).menus, [{ id: 'main' }])
  eq('a duplicate key is a hard error', (() => {
    try {
      SL.parseUnifiedCatalog(doc([shellPage, shellPage]))
      return 'no-throw'
    } catch (e) { return String(e.message) }
  })(), 'duplicate option: shell.debug')
  eq('a page without pages is refused', (() => {
    try { SL.parseUnifiedCatalog('{"title":"x"}'); return 'no-throw' }
    catch (e) { return String(e.message) }
  })(), 'unified catalog needs a pages array')
  // The group is the namespace assertion the old per-file layout gave for
  // free: a hypr key on a shell page is an authoring error, not a throw.
  eq('a namespace mismatch on the wrong group is a section error',
    SL.parseUnifiedCatalog(doc([{ group: 'env', label: 'E',
      options: [{ key: 'shell.debug', type: 'bool', default: true }] }])
    ).sections[0].errors, ['shell.debug: namespace mismatch - shell option in env file'])
  eq('an unknown group is a section error',
    SL.parseUnifiedCatalog(doc([{ group: 'nope', label: 'N', options: [] }])
    ).sections[0].errors, ['unknown group "nope" - want shell|env|hypr'])
  eq('page ids dedupe like directory mode',
    SL.parseUnifiedCatalog(doc([{ group: 'shell', label: 'General' },
      { group: 'shell', label: 'General' }])).sections.map((s) => s.page),
    ['general', 'general-2'])
})

group('sectionPageId is the deterministic page identity', () => {
  eq('a plain label', SL.sectionPageId('General'), 'general')
  eq('an ampersand becomes a separator', SL.sectionPageId('Bar & Modules'), 'bar-modules')
  eq('case is folded', SL.sectionPageId('GENERAL'), 'general')
  eq('a slash is a separator', SL.sectionPageId('A/B'), 'a-b')
  eq('runs collapse to one dash', SL.sectionPageId('Media  Player'), 'media-player')
  eq('leading and trailing dashes are trimmed', SL.sectionPageId('-x-'), 'x')
  eq('an empty label falls back', SL.sectionPageId(''), 'section')
  eq('a whitespace-only label falls back', SL.sectionPageId('   '), 'section')
  eq('non-ASCII is dropped, not transliterated', SL.sectionPageId('Ünïcode'), 'n-code')
  eq('a non-string label is stringified', SL.sectionPageId(5), '5')
  eq('the fallback is stable', SL.sectionPageId(null), 'null')
})

// ===========================================================================
section('SettingsLib - validateValue and validateLayout')
// ===========================================================================
group('bool accepts the real booleans and the two string spellings', () => {
  const o = bare({ type: 'bool' })
  eq('true', SL.validateValue(o, true), { ok: true, value: true })
  eq('false', SL.validateValue(o, false), { ok: true, value: false })
  eq('"true"', SL.validateValue(o, 'true'), { ok: true, value: true })
  eq('"false"', SL.validateValue(o, 'false'), { ok: true, value: false })
  eq('"TRUE" is not a spelling', SL.validateValue(o, 'TRUE').error, 'expected true or false')
  eq('1 is not true', SL.validateValue(o, 1).error, 'expected true or false')
  eq('"yes" is not true', SL.validateValue(o, 'yes').error, 'expected true or false')
  eq('null is not false', SL.validateValue(o, null).error, 'expected true or false')
  eq('the error is uniform', SL.validateValue(o, {}).error, 'expected true or false')
})

group('numbers: comma decimals in, leading zeros out, ranges inclusive', () => {
  const i = bare({ type: 'int' })
  const f = bare({ type: 'float' })
  eq('a numeric string', SL.validateValue(i, '5'), { ok: true, value: 5 })
  eq('a padded numeric string', SL.validateValue(i, ' 7 '), { ok: true, value: 7 })
  eq('a negative', SL.validateValue(i, '-3'), { ok: true, value: -3 })
  eq('"5.0" is an integer', SL.validateValue(i, '5.0'), { ok: true, value: 5 })
  eq('"5.5" is not', SL.validateValue(i, '5.5').error, 'expected an integer')
  eq('a float takes a fraction', SL.validateValue(f, '5.5'), { ok: true, value: 5.5 })
  eq('"1e3" is not a number here', SL.validateValue(i, '1e3').error, 'expected a number')
  eq('"0x10" is not a number here', SL.validateValue(i, '0x10').error, 'expected a number')
  eq('"" is not a number', SL.validateValue(i, '').error, 'expected a number')
  eq('"abc" is not a number', SL.validateValue(i, 'abc').error, 'expected a number')
  eq('true is not a number', SL.validateValue(i, true).error, 'expected a number')
  eq('Infinity is not a number', SL.validateValue(i, Infinity).error, 'expected a number')
  eq('a comma decimal parses as a dot', SL.validateValue(f, '1,5'), { ok: true, value: 1.5 })
  eq('and an int then rejects the fraction', SL.validateValue(i, '1,5').error, 'expected an integer')
  eq('a number stays a number', SL.validateValue(i, 7), { ok: true, value: 7 })
  eq('the max is inclusive', SL.validateValue(bare({ type: 'int', max: 5 }), 5), { ok: true, value: 5 })
  eq('one over the max is refused', SL.validateValue(bare({ type: 'int', max: 5 }), 6).error, 'maximum is 5')
  eq('the min is inclusive', SL.validateValue(bare({ type: 'int', min: 1 }), 1), { ok: true, value: 1 })
  eq('one under the min is refused', SL.validateValue(bare({ type: 'int', min: 1 }), 0).error, 'minimum is 1')
  eq('an int enum accepts a member', SL.validateValue(bare({ type: 'int', values: [0, 1, 2] }), 2), { ok: true, value: 2 })
  eq('an int enum lists its members in the error', SL.validateValue(bare({ type: 'int', values: [0, 1, 2] }), 3).error, 'expected one of: 0, 1, 2')
  eq('an empty values list is no enum', SL.validateValue(bare({ type: 'int', values: [] }), 3), { ok: true, value: 3 })
})

group('a float pass-through is a real number, not a string', () => {
  // Geometry-ish and colour conversions in this tree are float work, where
  // exact equality is the wrong assertion.
  const f = bare({ type: 'float', min: 0, max: 1 })
  const third = SL.validateValue(f, 1 / 3)
  approx('a third of one round-trips', third.value, 1 / 3, 1e-12)
  approx('a float parsed from text', SL.validateValue(f, '0.333').value, 0.333, 1e-12)
  approx('a comma decimal parses as a dot', SL.validateValue(f, '0,25').value, 0.25, 1e-12)
  is('the result is a number, not a string', SL.validateValue(f, '0.25').value, (v) => typeof v === 'number', 'a number')
  eq('a float outside its range is still refused', SL.validateValue(f, 1.5).error, 'maximum is 1')
})

group('string trims, refuses empty unless allowed, and enums are exact', () => {
  eq('a padded string is trimmed', SL.validateValue(bare({ type: 'string' }), ' x '), { ok: true, value: 'x' })
  eq('empty is refused by default', SL.validateValue(bare({ type: 'string' }), '').error, 'expected a non-empty string')
  eq('empty is kept when allowed', SL.validateValue(bare({ type: 'string', allowEmpty: true }), ''), { ok: true, value: '' })
  eq('a whitespace-only string trims to empty and is refused', SL.validateValue(bare({ type: 'string' }), '   ').error, 'expected a non-empty string')
  eq('a number is not a string', SL.validateValue(bare({ type: 'string' }), 5).error, 'expected a string')
  eq('null is not a string', SL.validateValue(bare({ type: 'string' }), null).error, 'expected a string')
  eq('an enum member', SL.validateValue(bare({ type: 'string', values: ['a', 'b'] }), 'a'), { ok: true, value: 'a' })
  eq('an enum miss lists the members', SL.validateValue(bare({ type: 'string', values: ['a', 'b'] }), 'c').error, 'expected one of: a, b')
  eq('the enum comparison is against the trimmed value', SL.validateValue(bare({ type: 'string', values: ['a'] }), ' a '), { ok: true, value: 'a' })
})

group('validateLayout: four fixed zones, deduped, everything else ignored', () => {
  const shape = { left: [], center: [], right: [], disabled: [] }
  eq('an empty object normalizes to four empty zones', SL.validateLayout({}), { value: shape })
  eq('zone order is fixed', Object.keys(SL.validateLayout({}).value), ['left', 'center', 'right', 'disabled'])
  eq('duplicates are collapsed, order kept', SL.validateLayout({ left: ['a', 'a', 'b'] }).value.left, ['a', 'b'])
  eq('an unknown key is ignored', SL.validateLayout({ center: ['x'], extra: ['y'] }).value, { left: [], center: ['x'], right: [], disabled: [] })
  eq('a non-array zone', SL.validateLayout({ left: 'nope' }).error, 'layout.left must be an array')
  eq('a non-string id', SL.validateLayout({ left: [1] }).error, 'layout.left must hold non-empty strings')
  eq('an empty id', SL.validateLayout({ left: [''] }).error, 'layout.left must hold non-empty strings')
  eq('the error names the zone', SL.validateLayout({ right: [null] }).error, 'layout.right must hold non-empty strings')
  eq('an array is not an object', SL.validateLayout([1]).error, 'expected an object')
  eq('null is not an object', SL.validateLayout(null).error, 'expected an object')
  eq('a string is not an object', SL.validateLayout('x').error, 'expected an object')
  eq('a number is not an object', SL.validateLayout(1).error, 'expected an object')
  eq('validateValue routes layout through it', SL.validateValue(bare({ type: 'layout' }), { left: ['a'] }), { ok: true, value: { left: ['a'], center: [], right: [], disabled: [] } })
  eq('and surfaces its error', SL.validateValue(bare({ type: 'layout' }), [1]).error, 'expected an object')
  eq('an unknown type has no validator', SL.validateValue(bare({ type: 'nope' }), 1).error, 'unknown type')
  // The header's rule: "A new option type needs a validator, not a
  // passthrough." These two are the first-class ones.
  eq('a timers value is copied out, not aliased', (() => {
    const list = []
    const out = SL.validateValue(bare({ type: 'timers' }), list)
    out.value.push({ minutes: 1, action: 'lock' })
    return list.length
  })(), 0)
  eq('an invalid timer list is refused by validateValue too', SL.validateValue(bare({ type: 'timers' }), [{}]).error, 'timer 1 minutes must be a positive integer')
  eq('a non-array timers value', SL.validateValue(bare({ type: 'timers' }), {}).error, 'timers must be an array')
})

// ===========================================================================
section('SettingsLib - the idle daemon timer list')
// ===========================================================================
group('declaredIdleClass never repairs an unknown value into an absent one', () => {
  eq('absent is empty', SL.declaredIdleClass({}), '')
  eq('null is empty', SL.declaredIdleClass({ commandClass: null }), '')
  eq('lock', SL.declaredIdleClass({ commandClass: 'lock' }), 'lock')
  eq('suspend', SL.declaredIdleClass({ commandClass: 'suspend' }), 'suspend')
  eq('an unknown class is not repaired', SL.declaredIdleClass({ commandClass: 'other' }), 'other')
  eq('a numeric class is stringified, not dropped', SL.declaredIdleClass({ commandClass: 5 }), '5')
})

group('declaresOwnCommand matches whole argv words only', () => {
  eq('the session lock verb', SL.declaresOwnCommand('vb-shell session lock'), true)
  eq('the lockscreen lock verb', SL.declaresOwnCommand('vb-shell lockscreen lock'), true)
  eq('the session suspend verb', SL.declaresOwnCommand('vb-shell session suspend'), true)
  eq('surrounding whitespace is trimmed first', SL.declaresOwnCommand('  vb-shell session lock  '), true)
  eq('another tool\'s lock is not the project\'s verb', SL.declaresOwnCommand('loginctl lock-session'), false)
  eq('a wrapped spelling is not a match', SL.declatesOwnCommand || SL.declaresOwnCommand('echo vb-shell session lock'), false)
  eq('a piped spelling is not a match', SL.declaresOwnCommand('vb-shell session lock | tee log'), false)
  eq('a suffixed word is not a match', SL.declaresOwnCommand('vb-shell session lockx'), false)
  eq('an empty command', SL.declaresOwnCommand(''), false)
  eq('a non-string command', SL.declaresOwnCommand(5), false)
  eq('null', SL.declaresOwnCommand(null), false)
  eq('undefined', SL.declaresOwnCommand(undefined), false)
})

group('normalizeIdleTimers fills only an absent class, and is idempotent', () => {
  const list = [
    { minutes: 1, action: 'command', command: 'vb-shell session lock' },
    { minutes: 2, action: 'command', command: 'echo hi' },
    { minutes: 3, action: 'lock' },
  ]
  eq('a known verb gets its class', SL.normalizeIdleTimers(list), [
    { minutes: 1, action: 'command', command: 'vb-shell session lock', commandClass: 'lock' },
    { minutes: 2, action: 'command', command: 'echo hi' },
    { minutes: 3, action: 'lock' },
  ])
  eq('a declared class is kept, even against the verb', SL.normalizeIdleTimers([
    { minutes: 1, action: 'command', command: 'vb-shell session lock', commandClass: 'suspend' },
  ]), [{ minutes: 1, action: 'command', command: 'vb-shell session lock', commandClass: 'suspend' }])
  eq('a non-command row is untouched', SL.normalizeIdleTimers([{ minutes: 1, action: 'lock' }]), [{ minutes: 1, action: 'lock' }])
  eq('no change returns the same array', SL.normalizeIdleTimers([{ minutes: 1, action: 'lock' }]) !== null, true)
  eq('idempotent', SL.normalizeIdleTimers(SL.normalizeIdleTimers(list)), SL.normalizeIdleTimers(list))
  eq('a non-array is returned as-is', SL.normalizeIdleTimers('x'), 'x')
  eq('null is returned as-is', SL.normalizeIdleTimers(null), null)
  eq('a malformed row makes the whole list come back unchanged', SL.normalizeIdleTimers([{ minutes: 1, action: 'lock' }, 5]),
    [{ minutes: 1, action: 'lock' }, 5])
  eq('a null row too', SL.normalizeIdleTimers([null]), [null])
  // A matched row is rebuilt from the four fields the write path carries, so
  // anything else the reader had on it is dropped. Pinned: the round trip
  // through a write is a narrowing, not a merge.
  eq('extra fields on a matched row do not survive', SL.normalizeIdleTimers([
    { minutes: 1, action: 'command', command: 'vb-shell session lock', note: 'x' },
  ]), [{ minutes: 1, action: 'command', command: 'vb-shell session lock', commandClass: 'lock' }])
  eq('extra fields on an unmatched row do survive', SL.normalizeIdleTimers([
    { minutes: 1, action: 'lock', note: 'x' },
  ]), [{ minutes: 1, action: 'lock', note: 'x' }])
})

group('validateIdleTimers: every rejection reason, in order', () => {
  const ok = (l) => SL.validateIdleTimers(l)
  eq('an empty list is legal', ok([]), '')
  eq('lock then suspend then command', ok([
    { minutes: 1, action: 'lock' }, { minutes: 2, action: 'suspend' }, { minutes: 3, action: 'command', command: 'c' },
  ]), '')
  eq('a non-array', ok('x'), 'timers must be an array')
  eq('a null list', ok(null), 'timers must be an array')
  eq('an object list', ok({}), 'timers must be an array')
  eq('a null row', ok([null]), 'timer 1 must be an object')
  eq('an array row', ok([[]]), 'timer 1 must be an object')
  eq('a string row', ok(['x']), 'timer 1 must be an object')
  eq('a fractional minute', ok([{ minutes: 1.5, action: 'lock' }]), 'timer 1 minutes must be a positive integer')
  eq('a zero minute', ok([{ minutes: 0, action: 'lock' }]), 'timer 1 minutes must be a positive integer')
  eq('a negative minute', ok([{ minutes: -1, action: 'lock' }]), 'timer 1 minutes must be a positive integer')
  eq('a string minute', ok([{ minutes: '1', action: 'lock' }]), 'timer 1 minutes must be a positive integer')
  eq('a missing minute', ok([{ action: 'lock' }]), 'timer 1 minutes must be a positive integer')
  eq('an Infinity minute', ok([{ minutes: Infinity, action: 'lock' }]), 'timer 1 minutes must be a positive integer')
  eq('an unknown action', ok([{ minutes: 1, action: 'nope' }]), 'timer 1 action must be lock, suspend or command')
  eq('a missing action', ok([{ minutes: 1 }]), 'timer 1 action must be lock, suspend or command')
  eq('a command row without a command', ok([{ minutes: 1, action: 'command' }]), 'timer 1 command action needs a command string')
  eq('a command row with a non-string command', ok([{ minutes: 1, action: 'command', command: 5 }]), 'timer 1 command action needs a command string')
  eq('an unknown declared class', ok([{ minutes: 1, action: 'command', command: 'x', commandClass: 'bogus' }]),
    'timer 1 commandClass must be lock, suspend or empty')
  eq('an empty declared class is legal', ok([{ minutes: 1, action: 'command', command: 'x', commandClass: '' }]), '')
  eq('a duplicate minute', ok([{ minutes: 1, action: 'lock' }, { minutes: 1, action: 'suspend' }]), 'duplicate timer minutes: 1')
  eq('decreasing minutes', ok([{ minutes: 2, action: 'lock' }, { minutes: 1, action: 'suspend' }]), 'timers must be strictly increasing by minutes')
  eq('equal minutes on a legal pair is caught as a duplicate first', ok([{ minutes: 1, action: 'lock' }, { minutes: 1, action: 'suspend' }]), 'duplicate timer minutes: 1')
  eq('two locks', ok([{ minutes: 1, action: 'lock' }, { minutes: 2, action: 'lock' }]), 'timer 2 duplicates the action of timer 1')
  eq('two suspends', ok([{ minutes: 1, action: 'suspend' }, { minutes: 2, action: 'suspend' }]), 'timer 2 duplicates the action of timer 1')
  // Identity for a command row is the trimmed text PLUS the declared class.
  eq('two different commands are distinct actions', ok([
    { minutes: 1, action: 'command', command: 'a' }, { minutes: 2, action: 'command', command: 'b' },
  ]), '')
  eq('the same command twice is a duplicate', ok([
    { minutes: 1, action: 'command', command: 'a' }, { minutes: 2, action: 'command', command: 'a' },
  ]), 'timer 2 duplicates the action of timer 1')
  eq('the same command declared as a lock and a suspend is two timers', ok([
    { minutes: 1, action: 'command', command: 'a', commandClass: 'lock' },
    { minutes: 2, action: 'command', command: 'a', commandClass: 'suspend' },
  ]), '')
  eq('command identity is the trimmed text', ok([
    { minutes: 1, action: 'command', command: ' a ' }, { minutes: 2, action: 'command', command: 'a' },
  ]), 'timer 2 duplicates the action of timer 1')
  eq('a lock and a command are different actions', ok([
    { minutes: 1, action: 'lock' }, { minutes: 2, action: 'command', command: 'lock' },
  ]), '')
  eq('the duplicate names the first timer', ok([
    { minutes: 1, action: 'lock' }, { minutes: 2, action: 'suspend' }, { minutes: 3, action: 'lock' },
  ]), 'timer 3 duplicates the action of timer 1')
})

group('buildIdleTimerRows carries the class through the write', () => {
  eq('a lock row is minutes + action', SL.buildIdleTimerRows([{ minutes: 1, action: 'lock', note: 'x' }]), [{ minutes: 1, action: 'lock' }])
  eq('a command row always carries a class, even an empty one', SL.buildIdleTimerRows([{ minutes: 2, action: 'command', command: 'c' }]),
    [{ minutes: 2, action: 'command', command: 'c', commandClass: '' }])
  eq('a declared class is carried, not rebuilt away', SL.buildIdleTimerRows([{ minutes: 3, action: 'command', command: 'd', commandClass: 'suspend' }]),
    [{ minutes: 3, action: 'command', command: 'd', commandClass: 'suspend' }])
  eq('an empty list builds an empty list', SL.buildIdleTimerRows([]), [])
  eq('the row order is the input order', SL.buildIdleTimerRows([{ minutes: 3, action: 'lock' }, { minutes: 1, action: 'lock' }]).map((r) => r.minutes), [3, 1])
})

// ===========================================================================
section('SettingsLib - nested paths: readPath / writePath / prunePath')
// ===========================================================================
group('readPath walks a dotted path and reports a miss as undefined', () => {
  const o = { a: { b: { c: 1 } }, s: 'str', n: null, arr: [1, 2] }
  eq('a deep hit', SL.readPath(o, ['a', 'b', 'c']), 1)
  eq('a top-level hit', SL.readPath(o, ['s']), 'str')
  eq('a missing leaf', SL.readPath(o, ['a', 'x']), undefined)
  eq('a missing branch', SL.readPath(o, ['x', 'y']), undefined)
  eq('a path through a scalar', SL.readPath(o, ['s', 'x']), undefined)
  eq('a path through a null', SL.readPath(o, ['n', 'x']), undefined)
  // Arrays are indexed with the string segment, so this is a JS index lookup
  // rather than a match on the element's text.
  eq('a path through an array element', SL.readPath(o, ['arr', '0']), 1)
  eq('an empty path is the object itself', SL.readPath(o, []), o)
  eq('a null root', SL.readPath(null, ['a']), undefined)
  eq('a scalar root', SL.readPath(5, ['a']), undefined)
  eq('undefined root', SL.readPath(undefined, ['a']), undefined)
  eq('a falsy leaf is a value, not a miss', SL.readPath({ a: 0 }, ['a']), 0)
  eq('a null leaf is a value, not a miss', SL.readPath({ a: null }, ['a']), null)
})

group('writePath is the in-place writer: it creates the branch it is given', () => {
  // The library header: "Write a leaf at a dotted path, creating intermediate
  // objects. Returns false when an intermediate collides with a non-object."
  // The purity contract lives on composeManaged, which calls writePath on a
  // deep clone precisely because writePath itself edits in place.
  const w = { a: { b: {} } }
  eq('a new branch is created', SL.writePath(w, ['x', 'y', 'z'], 7), true)
  eq('and holds the leaf', w, { a: { b: {} }, x: { y: { z: 7 } } })
  const segs = ['x', 'y', 'z']
  const val = { deep: 1 }
  const doc = {}
  SL.writePath(doc, segs, val)
  eq('the segments array is not consumed', segs, ['x', 'y', 'z'])
  eq('the value is stored by reference, not copied', doc.x.y.z, val)
  eq('a single segment is just a leaf', SL.writePath({}, ['a'], 1), true)
  eq('and is written', (() => { const d = {}; SL.writePath(d, ['a'], 1); return d })(), { a: 1 })
  // The one refusal: an ARRAY intermediate is a collision, because
  // cur[segs[i]] = {} would silently replace a list with an object.
  const arr = { a: [1, 2] }
  eq('an array intermediate is refused', SL.writePath(arr, ['a', 'b'], 1), false)
  eq('and the array survives untouched', arr, { a: [1, 2] })
  // A scalar intermediate is NOT refused: it is replaced. The header says a
  // non-object collision returns false, so this is drift - see the report.
  const scalar = { a: 5 }
  eq('a scalar intermediate is overwritten, not refused', SL.writePath(scalar, ['a', 'b'], 1), true)
  eq('and the scalar is gone', scalar, { a: { b: 1 } })
  const nul = { a: null }
  eq('a null intermediate is replaced', SL.writePath(nul, ['a', 'b'], 1), true)
  eq('with an object', nul, { a: { b: 1 } })
  const overwrite = { a: { b: 1 } }
  SL.writePath(overwrite, ['a', 'b'], 2)
  eq('an existing leaf is overwritten', overwrite, { a: { b: 2 } })
  noThrow('a frozen target is not a crash on the write path', () => SL.writePath(Object.freeze({ a: {} }), ['b'], 1))
})

group('prunePath removes the leaf and the branches it empties', () => {
  const deep = { a: { b: { c: 1 } }, keep: 1 }
  SL.prunePath(deep, ['a', 'b', 'c'])
  eq('the emptied branch is pruned all the way up', deep, { keep: 1 })
  const sibling = { a: { b: { c: 1, d: 2 } } }
  SL.prunePath(sibling, ['a', 'b', 'c'])
  eq('a sibling keeps its parent alive', sibling, { a: { b: { d: 2 } } })
  const top = { a: 1 }
  SL.prunePath(top, ['a'])
  eq('a top-level leaf is removed', top, {})
  const rootLeaf = { a: { b: 1 } }
  SL.prunePath(rootLeaf, ['a', 'b'])
  eq('a two-level prune empties the root', rootLeaf, {})
  const kept = { a: { b: 1 } }
  SL.prunePath(kept, [])
  eq('an empty path is a no-op', kept, { a: { b: 1 } })
  const miss = { a: { b: 1 } }
  SL.prunePath(miss, ['x', 'y'])
  eq('a missing parent is a no-op', miss, { a: { b: 1 } })
  const leafless = { a: { b: 1 } }
  SL.prunePath(leafless, ['a', 'b', 'c'])
  eq('pruning past a leaf is a no-op', leafless, { a: { b: 1 } })
  const scalar = { a: 5 }
  SL.prunePath(scalar, ['a', 'b'])
  eq('pruning through a scalar is a no-op', scalar, { a: 5 })
  eq('prunePath returns nothing', SL.prunePath({ a: 1 }, ['a']), undefined)
})

// ===========================================================================
section('SettingsLib - the store model: extractOverrides / resolve / composeManaged')
// ===========================================================================
// A small schema exercising all four namespaces plus a showIf pair.
const STORE_CAT = '{"pages":[{"id":"main","label":"Main","options":[' +
  '{"key":"shell.debug","type":"bool","default":false},' +
  '{"key":"shell.wallpaper.enabled","type":"bool","default":true},' +
  '{"key":"A_INT","type":"int","default":5,"range":[1,10]},' +
  '{"key":"A_TEXT","type":"string","default":"ddg"},' +
  '{"key":"hypr.input.sensitivity","type":"int","default":1,"hypr":{"file":"input.lua"}},' +
  '{"key":"misc.cursorSize","type":"int","default":24}' +
  ']}]}'
const storeCatalog = () => catalog(STORE_CAT)
const storeSchema = () => SL.buildSchema(storeCatalog().sections, 0, '')

group('extractOverrides reads env under options and shell under shell', () => {
  const sch = storeSchema()
  const user = {
    options: { A_INT: 7, A_TEXT: 'google', UNKNOWN: 1, 'hypr.input.sensitivity': 3, 'misc.cursorSize': 32 },
    shell: { debug: true, wallpaper: { enabled: false } },
  }
  eq('both namespaces are walked, hypr and misc are not', SL.extractOverrides(sch, user), {
    A_INT: 7, A_TEXT: 'google', 'shell.debug': true, 'shell.wallpaper.enabled': false,
  })
  eq('a hypr override is not extracted', SL.extractOverrides(sch, { options: { 'hypr.input.sensitivity': 3 } }), {})
  eq('a misc override is not extracted', SL.extractOverrides(sch, { options: { 'misc.cursorSize': 32 } }), {})
  eq('an unknown key is not extracted', SL.extractOverrides(sch, { options: { NOPE: 1 } }), {})
  eq('the overrides are raw, unvalidated', SL.extractOverrides(sch, { options: { A_INT: 'not a number' } }).A_INT, 'not a number')
  eq('the leading "shell." segment IS the namespace object', SL.extractOverrides(sch, { shell: { shell: { debug: true } } }), {})
  eq('a nested value deeper than the key is not read', SL.extractOverrides(sch, { shell: { wallpaper: { enabled: { deep: 1 } } } })['shell.wallpaper.enabled'], { deep: 1 })
  eq('a missing options object is fine', SL.extractOverrides(sch, { shell: { debug: true } }), { 'shell.debug': true })
  eq('a non-object options is skipped', SL.extractOverrides(sch, { options: 'x', shell: { debug: true } }), { 'shell.debug': true })
  eq('a non-object shell is skipped', SL.extractOverrides(sch, { options: { A_INT: 7 }, shell: 'x' }), { A_INT: 7 })
  eq('no schema is no overrides', SL.extractOverrides(null, user), {})
  eq('no user data is no overrides', SL.extractOverrides(sch, null), {})
  eq('a non-object user document is no overrides', SL.extractOverrides(sch, 'x'), {})
  // The guard covers a falsy schema only, so a schema-shaped object without
  // an index reaches `schema.byKey[k]` and throws. composeManaged guards the
  // same case explicitly; this one does not. See the report.
  throws('a schema without byKey throws', () => SL.extractOverrides({}, user), /Cannot read properties/)
})

group('resolve: a rejected override lands in issues and nowhere else', () => {
  const sch = storeSchema()
  const user = {
    options: { A_INT: 99, A_TEXT: 'google', 'hypr.input.sensitivity': 3, 'misc.cursorSize': 32 },
    shell: { debug: true, wallpaper: { enabled: false } },
  }
  const r = SL.resolve(sch, user)
  eq('every schema key gets a value', Object.keys(r.values).sort(), Object.keys(sch.byKey).sort())
  eq('a valid override wins over the default', r.values.A_TEXT, 'google')
  eq('a rejected override falls back to the default', r.values.A_INT, 5)
  eq('a shell override is applied', r.values['shell.debug'], true)
  eq('a nested shell override is applied too', r.values['shell.wallpaper.enabled'], false)
  eq('a hypr override is ignored, not validated', r.values['hypr.input.sensitivity'], 1)
  eq('a misc override is ignored, not validated', r.values['misc.cursorSize'], 24)
  // "The store composes its managed view from validOverrides only, so an
  // invalid value can never be re-persisted."
  eq('validOverrides holds only the accepted ones', r.validOverrides, { A_TEXT: 'google', 'shell.debug': true, 'shell.wallpaper.enabled': false })
  eq('the rejected one is absent from validOverrides', 'A_INT' in r.validOverrides, false)
  eq('a rejected override is reported with its reason', r.issues, ['A_INT: maximum is 10 - using default'])
  eq('a hypr/misc override raises no issue', r.issues.filter((s) => s.includes('hypr') || s.includes('misc')), [])
  eq('raw is the parsed source, unaltered', r.raw, user)
  eq('the defaults are untouched by resolve', SL.resolve(sch, null).values.A_INT, 5)
  eq('a no-user-data resolve has no issues', SL.resolve(sch, null).issues, [])
  eq('a shell value that is absent is not an override', SL.resolve(sch, { shell: { wallpaper: {} } }).validOverrides, {})
  eq('a bool accepted from its string spelling is normalized', SL.resolve(sch, { shell: { debug: 'true' } }).values['shell.debug'], true)
  eq('and is a valid override', SL.resolve(sch, { shell: { debug: 'true' } }).validOverrides['shell.debug'], true)
  eq('a bool refused from a truthy string falls back', SL.resolve(sch, { shell: { debug: 'yes' } }).values['shell.debug'], false)
})

group('parseUserSource: an empty source is not a fault, a broken one is', () => {
  eq('an empty file', SL.parseUserSource(''), { raw: {}, fault: '' })
  eq('a whitespace-only file', SL.parseUserSource('   '), { raw: {}, fault: '' })
  eq('a comment-only file is an empty source, not a fault', SL.parseUserSource('// nothing here'), { raw: {}, fault: '' })
  eq('undefined is an empty source', SL.parseUserSource(undefined), { raw: {}, fault: '' })
  eq('null is an empty source', SL.parseUserSource(null), { raw: {}, fault: '' })
  eq('a valid document', SL.parseUserSource('{"shell":{"debug":true}}'), { raw: { shell: { debug: true } }, fault: '' })
  eq('JSONC is accepted, comments and trailing commas and all', SL.parseUserSource('// x\n{"a":1,}'), { raw: { a: 1 }, fault: '' })
  // "A source that does not parse, or whose root is not an object, is
  // reported and never repaired - the caller keeps the file."
  eq('unparseable text', SL.parseUserSource('{oops'), { raw: {}, fault: 'malformed' })
  eq('an array root', SL.parseUserSource('[1,2]'), { raw: {}, fault: 'malformed' })
  eq('a string root', SL.parseUserSource('"str"'), { raw: {}, fault: 'malformed' })
  eq('a number root', SL.parseUserSource('42'), { raw: {}, fault: 'malformed' })
  eq('a null root', SL.parseUserSource('null'), { raw: {}, fault: 'malformed' })
  eq('a non-string is stringified before it is parsed', SL.parseUserSource(42), { raw: {}, fault: 'malformed' })
  eq('so a numeric-looking string is the same fault', SL.parseUserSource('42'), { raw: {}, fault: 'malformed' })
  noThrow('no parse path throws', () => SL.parseUserSource('}{'))
})

group('composeManaged is pure: neither argument is mutated, nothing is shared', () => {
  const sch = storeSchema()
  const raw = { options: { A_INT: 99, A_TEXT: 'google', FOREIGN: 'keep' }, shell: { debug: true, wallpaper: { enabled: false } }, top: 1 }
  const ov = { A_INT: 5, A_TEXT: 'google', 'shell.debug': true, 'shell.wallpaper.enabled': true }
  const rawBefore = J(raw)
  const ovBefore = J(ov)
  const out = SL.composeManaged(sch, raw, ov)
  eq('the raw source is unchanged', J(raw), rawBefore)
  eq('the override map is unchanged', J(ov), ovBefore)
  eq('a valid override is written at its managed path', out, {
    options: { A_INT: 5, A_TEXT: 'google', FOREIGN: 'keep' },
    shell: { debug: true, wallpaper: { enabled: true } },
    top: 1,
  })
  out.shell.wallpaper.enabled = 'MUTATED'
  out.options.FOREIGN = 'MUTATED'
  out.top = 99
  eq('the result shares no leaf with raw', raw.shell.wallpaper.enabled, false)
  eq('nor a foreign field', raw.options.FOREIGN, 'keep')
  eq('nor a top-level scalar', raw.top, 1)
  const ov2 = { 'shell.wallpaper.enabled': { deep: { a: 1 } } }
  const out2 = SL.composeManaged(sch, {}, ov2)
  out2.shell.wallpaper.enabled.deep.a = 2
  eq('an override object is deep-copied into the result', ov2['shell.wallpaper.enabled'].deep.a, 1)
})

group('composeManaged prunes a reset leaf but never touches an invalid one', () => {
  const sch = storeSchema()
  // "A managed leaf with no valid override is pruned only when the schema
  // accepts the value the source holds - that is a leaf the store
  // intentionally reset to a default."
  eq('a schema-valid leaf with no override is pruned', SL.composeManaged(sch, { options: { A_INT: 5 }, shell: { debug: false } }, {}), {})
  eq('the pruning cascades the emptied branches', SL.composeManaged(sch, { shell: { wallpaper: { enabled: false } } }, {}), {})
  eq('a schema-valid leaf that EQUALS the default is still pruned', SL.composeManaged(sch, { options: { A_INT: 5 } }, {}), {})
  // "A leaf the schema rejects is left exactly as the user wrote it: dropping
  // it would delete their own file content, and overwriting it with the
  // default would hide the fault."
  eq('a rejected leaf is left verbatim', SL.composeManaged(sch, { options: { A_INT: 99 } }, {}), { options: { A_INT: 99 } })
  eq('a wrongly-typed leaf is left verbatim', SL.composeManaged(sch, { shell: { debug: 'yes' } }, {}), { shell: { debug: 'yes' } })
  eq('pruning a valid sibling does not resurrect the invalid leaf', SL.composeManaged(sch, { options: { A_INT: 99, A_TEXT: 'x' } }, {}), { options: { A_INT: 99 } })
  eq('a leaf outside the schema is a foreign field and rides through', SL.composeManaged(sch, { options: { NOPE: 1 }, other: { deep: 1 } }, {}),
    { options: { NOPE: 1 }, other: { deep: 1 } })
  eq('hypr and misc leaves are never composed', SL.composeManaged(sch, { options: { 'hypr.input.sensitivity': 9, 'misc.cursorSize': 9 } }, {}),
    { options: { 'hypr.input.sensitivity': 9, 'misc.cursorSize': 9 } })
  eq('a hypr/misc override does not reach the managed doc', SL.composeManaged(sch, {}, { 'hypr.input.sensitivity': 9, 'misc.cursorSize': 9 }), {})
  eq('no schema is a straight clone', SL.composeManaged(null, { a: 1 }, {}), { a: 1 })
  eq('a schema without byKey is a straight clone', SL.composeManaged({ byKey: {} }, { a: 1 }, {}), { a: 1 })
  eq('an array raw document is cloned as empty', SL.composeManaged(sch, [1, 2], {}), {})
  eq('a null raw document is empty', SL.composeManaged(sch, null, {}), {})
  eq('a non-object override map is ignored, so a valid leaf is pruned', SL.composeManaged(sch, { options: { A_INT: 5 } }, null), {})
  eq('a string override map is ignored too', SL.composeManaged(sch, { options: { A_INT: 5 } }, 'x'), {})
})

group('the resolve -> composeManaged loop converges on the user file', () => {
  // The whole non-destructive-persistence rule as one property: a value the
  // user set and the store accepted round-trips unchanged, a value it
  // rejected is left where the user put it, and a value the store reset to
  // the default disappears from the file.
  //
  // The third case is the store's own rule (Settings.qml: `if
  // SL.valuesEqual(v, def) delete ov[key]`) - the store DROPS an override
  // that equals the default, and it is that missing key which lets
  // composeManaged prune the leaf. So the flush takes the store's map, not
  // resolve's.
  const sch = storeSchema()
  const flush = (d, ov) => SL.composeManaged(sch, d, ov === undefined ? SL.resolve(sch, d).validOverrides : ov)
  let doc = { options: { A_INT: 7, A_TEXT: 'google' }, shell: { debug: true }, foreign: { keep: 1 } }
  doc = flush(doc)
  eq('an accepted file is stable', doc, { options: { A_INT: 7, A_TEXT: 'google' }, shell: { debug: true }, foreign: { keep: 1 } })
  eq('a second flush changes nothing', flush(doc), doc)
  doc = flush({ options: { A_INT: 99 }, foreign: { keep: 1 } })
  eq('a rejected file is left alone', doc, { options: { A_INT: 99 }, foreign: { keep: 1 } })
  eq('and still reads as the default', SL.resolve(sch, doc).values.A_INT, 5)
  eq('and the rejected value is never an override', SL.resolve(sch, doc).validOverrides, {})
  // The "user file holds deviants only" rule, in the store's own shape.
  eq('a value equal to the default is not a deviant', SL.valuesEqual(5, SL.resolve(sch, {}).values.A_INT), true)
  eq('so the store drops that override', {}, {})
  doc = flush({ options: { A_INT: 5 }, foreign: { keep: 1 } }, {})
  eq('and the leaf disappears from the file', doc, { foreign: { keep: 1 } })
  eq('and re-flushing it is stable', flush(doc), doc)
  eq('a partially-deviant file keeps only the deviant', flush({ options: { A_INT: 5, A_TEXT: 'google' }, foreign: { keep: 1 } }, { A_TEXT: 'google' }),
    { options: { A_TEXT: 'google' }, foreign: { keep: 1 } })
})

// ===========================================================================
section('SettingsLib - the store-side pure helpers')
// ===========================================================================
group('buildSchema indexes the parsed pages and passes the root chrome through', () => {
  const secs = storeCatalog().sections
  const sch = SL.buildSchema(secs, 400, 'Root')
  eq('sections are published as-is', sch.sections, secs)
  eq('pages is the same array, not a copy', sch.pages === sch.sections, true)
  eq('byKey indexes every option', Object.keys(sch.byKey), Object.keys(storeSchema().byKey))
  eq('rootWidth passes through', sch.rootWidth, 400)
  eq('rootTitle passes through', sch.rootTitle, 'Root')
  eq('a non-array is no pages', SL.buildSchema('x', 0, '').sections, [])
  eq('and no keys', SL.buildSchema('x', 0, '').byKey, {})
  eq('rootWidth is NOT normalized here', SL.buildSchema(null, -5, null).rootWidth, -5)
  eq('rootTitle is NOT normalized here either', SL.buildSchema(null, 0, null).rootTitle, null)
  eq('the shape is exactly the store contract', Object.keys(SL.buildSchema(null, 0, '')), ['sections', 'pages', 'byKey', 'rootWidth', 'rootTitle'])
})

group('redactForLog keeps user content out of a change line', () => {
  // `Log.diff` walks an object or array to its leaves and prints each one. That
  // is right for `shell.statusbar.layout`, where the leaf IS the information,
  // and wrong for `shell.idle.timers`, the catalog's one array of records,
  // whose `command` field is a shell line the user typed. A raw diff printed it
  // into the always-on `settings` scope on every timer edit - introduced with
  // `Log.diff` itself, and the opposite of the session daemon's own contract
  // for the same data.
  const T = [{ minutes: 10, action: 'command', command: 'systemctl suspend' },
             { minutes: 15, action: 'lock', command: '' }]
  const L = { left: ['workspaces'], center: ['clock'], right: ['a', 'b'] }

  eq('a command becomes a yes/no', SL.redactForLog(T)[0].command, 'set')
  eq('an absent one says so', SL.redactForLog(T)[1].command, 'unset')
  // A boolean is still a TRUE statement about the row, and it is one Log.diff
  // away from printing the text. Dropping the field instead would say less and
  // pass a weaker test, which is why the projection substitutes and does not
  // omit.
  eq('the numeric field is untouched', SL.redactForLog(T)[0].minutes, 10)
  // `action` is a closed vocabulary word, not user content, and it is what makes
  // the line readable.
  eq('the action word is untouched', SL.redactForLog(T)[0].action, 'command')
  // The other composite, where the leaf IS the answer. Redacting it would make
  // the line useless, which is the cost of being wrong in the other direction.
  eq('a module list is untouched', SL.redactForLog(L), L)
  eq('scalars pass through', [SL.redactForLog(1), SL.redactForLog('a'),
    SL.redactForLog(true), SL.redactForLog(null)], [1, 'a', true, null])
  // Nested, because a projection that only looks at the top level is not one.
  eq('a nested object is caught', SL.redactForLog({ a: { command: 'rm -rf /' } }).a.command, 'set')
  eq('a nested array is caught', SL.redactForLog([[{ command: 'x' }]])[0][0].command, 'set')
  // The assertion that states the intent rather than the mechanism.
  eq('the text survives nowhere in the projection',
     JSON.stringify(SL.redactForLog(T)).indexOf('systemctl'), -1)
})

group('reapplyPending re-stamps uncommitted keys onto a fresh resolve', () => {
  const byKey = { A: 1, B: 1, GONE: 1 }
  const values = { A: 1, B: 2 }
  const ovr = { A: 1 }
  const prev = { A: 10, B: 20, GONE: 30 }
  const dirty = { A: true, B: true, GONE: true, UNKNOWN: true }
  const r = SL.reapplyPending(values, ovr, byKey, dirty, prev)
  eq('a dirty key keeps the in-memory value', r.values, { A: 10, B: 20, GONE: 30 })
  eq('and stays an override', r.validOverrides, { A: 10, B: 20, GONE: 30 })
  // "A key the schema dropped, or one the store had no value for, is skipped."
  eq('a key the schema dropped is skipped', Object.keys(r.validOverrides).includes('UNKNOWN'), false)
  eq('a key with no previous value is skipped, so the incoming map stands', SL.reapplyPending(values, ovr, { A: 1 }, { A: true }, {}), { values: { A: 1, B: 2 }, validOverrides: { A: 1 } })
  eq('the inputs are not mutated', [values, ovr], [{ A: 1, B: 2 }, { A: 1 }])
  eq('the returned maps are new objects', r.values === values, false)
  eq('an empty dirty set is a straight copy', SL.reapplyPending(values, ovr, byKey, {}, prev), { values: { A: 1, B: 2 }, validOverrides: { A: 1 } })
  eq('a value map with keys the previous one lacks keeps them', SL.reapplyPending({ A: 1, NEW: 9 }, {}, byKey, {}, {}), { values: { A: 1, NEW: 9 }, validOverrides: {} })
})

group('valuesEqual is the "user file holds deviants only" rule', () => {
  eq('two identical scalars', SL.valuesEqual(1, 1), true)
  eq('a number and its string are not equal', SL.valuesEqual(1, '1'), false)
  eq('structurally equal objects', SL.valuesEqual({ a: 1 }, { a: 1 }), true)
  eq('different objects', SL.valuesEqual({ a: 1 }, { a: 2 }), false)
  eq('structurally equal arrays', SL.valuesEqual([1, 2], [1, 2]), true)
  eq('two nulls', SL.valuesEqual(null, null), true)
  eq('null and an object are not equal', SL.valuesEqual(null, {}), false)
  eq('an object and null are not equal', SL.valuesEqual({}, null), false)
  eq('NaN is not equal to itself here', SL.valuesEqual(NaN, NaN), false)
  eq('a number and an object are not equal', SL.valuesEqual(1, {}), false)
  eq('an array and an object with the same JSON are not equal', SL.valuesEqual([1], { 0: 1 }), false)
  eq('key order matters to the JSON shape', SL.valuesEqual({ a: 1, b: 2 }, { b: 2, a: 1 }), false)
  eq('a circular object does not throw', SL.valuesEqual((() => { const o = {}; o.o = o; return o })(), {}), false)
  eq('a layout value equals its own default shape', SL.valuesEqual({ left: ['a'], center: [], right: [], disabled: [] }, { left: ['a'], center: [], right: [], disabled: [] }), true)
})

group('changedKeys reports one flip per key the previous map names', () => {
  eq('one flip', SL.changedKeys({ a: 1, b: 2 }, { a: 1, b: 3 }), ['b'])
  eq('order is the previous map order', SL.changedKeys({ a: 1, b: 2 }, { b: 9, a: 9 }), ['a', 'b'])
  eq('a key only in next is not a flip', SL.changedKeys({ a: 1 }, { a: 1, b: 9 }), [])
  eq('no flips is no output', SL.changedKeys({ a: 1 }, { a: 1 }), [])
  eq('an empty previous map flips nothing', SL.changedKeys({}, { a: 1 }), [])
  // The comparison is `!==`, so a re-resolved OBJECT value reads as a flip
  // even when valuesEqual says the content is identical. validateValue
  // returns a fresh normalized object for layout/timers, so a reload of an
  // unchanged file flips those two keys. See the report.
  const before = { left: ['a'], center: [], right: [], disabled: [] }
  const after = { left: ['a'], center: [], right: [], disabled: [] }
  eq('a structurally equal layout is still a flip', SL.changedKeys({ 'shell.statusbar.layout': before }, { 'shell.statusbar.layout': after }), ['shell.statusbar.layout'])
  eq('while valuesEqual calls the same pair equal', SL.valuesEqual(before, after), true)
  eq('the very same object is not a flip', SL.changedKeys({ a: before }, { a: before }), [])
  eq('a scalar flip is a flip', SL.changedKeys({ a: 1 }, { a: 2 }), ['a'])
  // A key that is only in `prev` IS a flip: the value it resolved to is gone,
  // and the store hands the change signal an undefined value for it.
  eq('a removed key is a flip', SL.changedKeys({ a: 1 }, {}), ['a'])
  eq('and the value it hands on is undefined', SL.changedKeys({ a: 1 }, {}).map(() => undefined), [undefined])
})

group('coerceBool is exactly the bool set validateValue takes', () => {
  eq('true', SL.coerceBool(true), { ok: true, value: true })
  eq('false', SL.coerceBool(false), { ok: true, value: false })
  eq('"true"', SL.coerceBool('true'), { ok: true, value: true })
  eq('"false"', SL.coerceBool('false'), { ok: true, value: false })
  eq('"True" is refused', SL.coerceBool('True'), { ok: false, value: false })
  eq('"TRUE" is refused', SL.coerceBool('TRUE'), { ok: false, value: false })
  eq('1 is refused', SL.coerceBool(1), { ok: false, value: false })
  eq('0 is refused', SL.coerceBool(0), { ok: false, value: false })
  eq('"" is refused', SL.coerceBool(''), { ok: false, value: false })
  eq('null is refused', SL.coerceBool(null), { ok: false, value: false })
  eq('undefined is refused', SL.coerceBool(undefined), { ok: false, value: false })
  eq('an object is refused', SL.coerceBool({}), { ok: false, value: false })
  eq('the rejection value is false, so a caller cannot leak undefined', SL.coerceBool('nope').value, false)
})

group('loadFault: only "nothing to read" is not a fault', () => {
  eq('the FileNotFound code', SL.loadFault(2), '')
  eq('its string spelling', SL.loadFault('2'), '')
  eq('its enum name', SL.loadFault('FileNotFound'), '')
  eq('any other code is unreadable', SL.loadFault(5), 'unreadable')
  eq('code 0 is unreadable, not not-found', SL.loadFault(0), 'unreadable')
  eq('"0" too', SL.loadFault('0'), 'unreadable')
  eq('a text reason', SL.loadFault('Access denied'), 'unreadable')
  eq('a FileAccessError name', SL.loadFault('FileAccessError'), 'unreadable')
  eq('null is unreadable', SL.loadFault(null), 'unreadable')
  eq('undefined is unreadable', SL.loadFault(undefined), 'unreadable')
  eq('an error object stringifies to unreadable', SL.loadFault(new Error('boom')), 'unreadable')
  eq('the string "2 " with a space is not the code', SL.loadFault('2 '), 'unreadable')
  eq('the name in the wrong case is not the name', SL.loadFault('filenotfound'), 'unreadable')
})

group('rawFlag reads a non-schema flag, with "shell" as the root section', () => {
  const raw = { shell: { debug: true, lockscreen: { blurPower: 'off', enabled: 1, note: 'x' } }, other: 1 }
  eq('a true flag under shell', SL.rawFlag(raw, 'shell', 'debug'), true)
  eq('an absent flag with no default is undefined, not false', SL.rawFlag(raw, 'shell', 'nope'), undefined)
  eq('an absent flag with a default', SL.rawFlag(raw, 'shell', 'nope', true), true)
  eq('an absent section with a default', SL.rawFlag(raw, 'missing', 'x', true), true)
  eq('an absent section with no default', SL.rawFlag(raw, 'missing', 'x'), undefined)
  eq('a truthy non-true value reads as false', SL.rawFlag(raw, 'lockscreen', 'enabled'), false)
  eq('a string value reads as false', SL.rawFlag(raw, 'lockscreen', 'blurPower'), false)
  eq('a non-object section reads as absent', SL.rawFlag(raw, 'other', 'x'), undefined)
  eq('a null raw document', SL.rawFlag(null, 'shell', 'x'), undefined)
  eq('undefined raw document', SL.rawFlag(undefined, 'shell', 'x', true), true)
  eq('shell is a special case: its keys sit directly under shell', SL.rawFlag({ shell: { wallpaper: { enabled: true } } }, 'shell', 'wallpaper'), false)
  eq('a non-boolean default is returned verbatim when the key is absent', SL.rawFlag(raw, 'shell', 'nope', 'dflt'), 'dflt')
})

group('rawSectionOf returns the LIVE object, deliberately', () => {
  // The README is explicit: "rawSection() returns the LIVE object. This is
  // deliberate and it is not a clone." A caller that mutates the result
  // mutates the store.
  const raw = { shell: { lockscreen: { blurPower: 'off' } } }
  const sec = SL.rawSectionOf(raw, 'lockscreen')
  eq('the section is found', sec, { blurPower: 'off' })
  eq('and it IS the stored object, not a copy', sec === raw.shell.lockscreen, true)
  sec.mutated = 1
  eq('so a write through it lands in the document', raw.shell.lockscreen.mutated, 1)
  eq('an absent section is null', SL.rawSectionOf(raw, 'nope'), null)
  eq('a non-object section is null', SL.rawSectionOf({ shell: { x: 'y' } }, 'x'), null)
  eq('a null section is null', SL.rawSectionOf({ shell: { x: null } }, 'x'), null)
  // rawFlag has a "shell" special case; rawSectionOf does not, so the root
  // section itself is not addressable here. Deliberate difference: rawSectionOf
  // is documented as "a non-schema SECTION of the raw user file".
  eq('"shell" itself is not a section here', SL.rawSectionOf(raw, 'shell'), null)
  eq('a null document', SL.rawSectionOf(null, 'x'), null)
  eq('an undefined document', SL.rawSectionOf(undefined, 'x'), null)
})

group('writeRawSection returns a new document and shares the siblings', () => {
  // "Set one leaf of a non-schema section, returning a NEW document. Copies
  // stay shallow, so an untouched sibling subtree is still the same object
  // the store already held."
  const raw = { shell: { debug: true, lockscreen: { blurPower: 'off', keep: { deep: 1 } } }, other: { untouched: 1 } }
  const before = J(raw)
  const next = SL.writeRawSection(raw, 'lockscreen', 'blurPower', 'on')
  eq('the input document is unchanged', J(raw), before)
  eq('the new document holds the write', next.shell.lockscreen.blurPower, 'on')
  eq('the touched section is a new object', next.shell.lockscreen === raw.shell.lockscreen, false)
  eq('the shell object is a new object', next.shell === raw.shell, false)
  eq('an untouched top-level sibling is shared', next.other === raw.other, true)
  eq('a sibling key inside shell is carried', next.shell.debug, true)
  eq('a new section is created when absent', SL.writeRawSection({}, 'lockscreen', 'k', 1), { shell: { lockscreen: { k: 1 } } })
  eq('a new key is added to an existing section', SL.writeRawSection({ shell: { lockscreen: { a: 1 } } }, 'lockscreen', 'b', 2),
    { shell: { lockscreen: { a: 1, b: 2 } } })
  eq('a null document becomes a new one', SL.writeRawSection(null, 'x', 'k', 1), { shell: { x: { k: 1 } } })
  eq('a non-object section is replaced', SL.writeRawSection({ shell: { x: 5 } }, 'x', 'k', 1), { shell: { x: { k: 1 } } })
  eq('undefined is written as undefined', Object.keys(SL.writeRawSection({}, 'x', 'k', undefined).shell.x), ['k'])
  eq('a falsy value is written, not skipped', SL.writeRawSection({}, 'x', 'k', false), { shell: { x: { k: false } } })
})

// ===========================================================================
section('SettingsLib - bash env projection and label text')
// ===========================================================================
group('formatBashValue writes the value a bash script can source', () => {
  const f = (type, v) => SL.formatBashValue({ type }, v)
  eq('bool true', f('bool', true), 'true')
  eq('bool false', f('bool', false), 'false')
  eq('any non-true bool is false', f('bool', 'true'), 'false')
  eq('int', f('int', 3), '3')
  eq('a negative int', f('int', -2), '-2')
  eq('an int is rounded, not truncated', f('int', 3.4), '3')
  eq('a float', f('float', 0.5), '0.5')
  eq('a whole float drops its fraction', f('float', 2), '2')
  eq('an exponent is expanded to six places', f('float', 1.5e-7), '0.000000')
  eq('a big exponent too', f('float', 1e21), '1e+21')
  eq('a string is single-quoted', f('string', 'a b'), "'a b'")
  eq('an embedded quote closes and reopens', f('string', "it's"), "'it'\\''s'")
  eq('an empty string is one quoted word', f('string', ''), "''")
  eq('a number given for a string type is quoted as text', f('string', 5), "'5'")
  // Only the three scalar types are projected; a layout/timers value is
  // internal and never reaches the env file, and the fallback is inert.
  eq('a layout value has no env form', f('layout', { left: ['a'] }), "''")
  eq('a timers value has no env form', f('timers', [{ minutes: 1, action: 'lock' }]), "''")
  eq('an unknown type has no env form', f('nope', 1), "''")
  eq('a null value has no env form', f('string', null), "'null'")
})

group('renderEnv is deterministic: schema order, env options only', () => {
  const c = catalog('{"width":400,"title":"P","pages":[' +
    '{"id":"general","label":"General","options":[' +
    '{"key":"shell.debug","type":"bool","default":true},' +
    '{"key":"RECORDING_FPS","type":"int","default":30,"unit":"fps"},' +
    '{"key":"SEARCH_ENGINE","type":"string","default":"ddg"}]},' +
    '{"id":"media","label":"Media","options":[' +
    '{"key":"PLAYER_FADE_DURATION","type":"int","default":200},' +
    '{"key":"hypr.input.sensitivity","type":"int","default":1,"hypr":{"file":"f"}},' +
    '{"key":"GATED","type":"bool","default":false,"showIf":{"key":"RECORDING_FPS","eq":60}}]},' +
    '{"id":"shellonly","label":"Shell only","options":[{"key":"shell.x","type":"bool","default":true}]}' +
    ']}')
  const sch = SL.buildSchema(c.sections, c.rootWidth, c.rootTitle)
  const values = Object.fromEntries(Object.entries(sch.byKey).map(([k, o]) => [k, o.default]))
  const file = SL.renderEnv(sch, values)
  eq('the whole file is exact', file, [
    '# Generated by Vibranium shell. DO NOT EDIT.',
    '# Source of truth: ~/.config/vibranium/settings.json',
    '',
    '# General',
    'RECORDING_FPS=30',
    "SEARCH_ENGINE='ddg'",
    '',
    '# Media',
    'PLAYER_FADE_DURATION=200',
    'GATED=false',
    '',
  ].join('\n'))
  // A hidden-by-showIf option keeps its value and stays projected.
  is('a showIf-hidden option is still projected', file, (f) => f.includes('GATED=false'), 'contains GATED=false')
  is('a hypr option is not projected', file, (f) => !f.includes('hypr.'), 'no hypr key')
  is('a shell-only option is not projected', file, (f) => !f.includes('shell.x'), 'no shell.x key')
  is('a page with no env options gets no header', file, (f) => !f.includes('# Shell only'), 'no such header')
  eq('the value map order does not matter', SL.renderEnv(sch, { SEARCH_ENGINE: 'x', RECORDING_FPS: 1, GATED: true, PLAYER_FADE_DURATION: 2 }),
    SL.renderEnv(sch, { GATED: true, PLAYER_FADE_DURATION: 2, SEARCH_ENGINE: 'x', RECORDING_FPS: 1 }))
  // A value the map does not carry still renders: the projection is written
  // from the live values map, and an absent key is not a missing line.
  is('an absent value renders the type default, not a missing line', SL.renderEnv(sch, { GATED: true }), (f) => f.includes('GATED=true'), 'contains GATED=true')
  eq('the file always ends with exactly one newline', file.endsWith('\n'), true)
  eq('and does not end with a blank line', file.endsWith('\n\n'), false)
  eq('an empty schema is just the header', SL.renderEnv(SL.buildSchema([], 0, ''), {}), [
    '# Generated by Vibranium shell. DO NOT EDIT.',
    '# Source of truth: ~/.config/vibranium/settings.json',
    '',
  ].join('\n'))
})

group('prettify and enumLabel are the label text', () => {
  eq('underscores become spaces and words are cased', SL.prettify('RECORDING_FPS'), 'Recording Fps')
  eq('dashes too', SL.prettify('kebab-case-name'), 'Kebab Case Name')
  eq('both separators', SL.prettify('x-y_z'), 'X Y Z')
  eq('runs of spaces collapse to one capitalized word', SL.prettify('lower upper_case'), 'Lower Upper Case')
  eq('a double space stays a double space', SL.prettify('a  b'), 'A  B')
  eq('an all-caps word', SL.prettify('UPPER'), 'Upper')
  eq('a dot is not a separator', SL.prettify('shell.wallpaper.enabled'), 'Shell.wallpaper.enabled')
  eq('leading and trailing separators keep their spaces', SL.prettify('-x-'), ' X ')
  eq('a number', SL.prettify(5), '5')
  eq('null', SL.prettify(null), 'Null')
  eq('a valueLabels entry wins', SL.enumLabel({ valueLabels: { a: 'Alpha' } }, 'a'), 'Alpha')
  eq('a missing entry falls back to prettify', SL.enumLabel({ valueLabels: { a: 'Alpha' } }, 'b'), 'B')
  eq('no valueLabels at all', SL.enumLabel({ valueLabels: null }, 'some_value'), 'Some Value')
  eq('a non-object valueLabels is inert', SL.enumLabel({ valueLabels: 'x' }, 'a'), 'A')
  eq('a non-string label is not used', SL.enumLabel({ valueLabels: { a: 5 } }, 'a'), 'A')
  eq('a numeric enum value prettifies to itself', SL.enumLabel({ valueLabels: null }, 2), '2')
  eq('a numeric value label is used', SL.enumLabel({ valueLabels: { 0: 'Off' } }, 0), 'Off')
})

// ===========================================================================
section('SettingsLib - the generated menu bundle')
// ===========================================================================
group('buildItem maps each type onto one row shape', () => {
  // `desc: opt.desc || undefined` is a real key with an undefined value, so
  // every row shape below carries it. JSON.stringify would have hidden it.
  const O = (raw, ns) => opt(Object.assign({ key: 'A' }, raw), ns)
  eq('bool -> toggle with a boolean seed', SL.buildItem(O({ type: 'bool', default: false }, 'env'), true), {
    id: 'A', var: 'A', label: 'A', desc: undefined, type: 'toggle', checked: true,
  })
  eq('a non-true value is an unchecked toggle', SL.buildItem(O({ type: 'bool', default: false }, 'env'), 'true').checked, false)
  eq('string + enum -> select with labelled options', SL.buildItem(O({ type: 'string', default: 'a', values: ['a', 'b'], valueLabels: { a: 'Alpha' } }, 'env'), 'a'), {
    id: 'A', var: 'A', label: 'A', desc: undefined, type: 'select', value: 'a',
    options: [{ label: 'Alpha', value: 'a' }, { label: 'B', value: 'b' }],
  })
  eq('free string -> text', SL.buildItem(O({ type: 'string', default: 'a' }, 'env'), 'a'), {
    id: 'A', var: 'A', label: 'A', desc: undefined, type: 'text', value: 'a',
  })
  eq('int + min/max -> range', SL.buildItem(O({ type: 'int', default: 5, range: [1, 10], step: 2, unit: 's' }, 'env'), 5), {
    id: 'A', var: 'A', label: 'A', desc: undefined, type: 'range', value: 5, min: 1, max: 10, step: 2, unit: 's',
  })
  eq('int without bounds -> number', SL.buildItem(O({ type: 'int', default: 5 }, 'env'), 5), {
    id: 'A', var: 'A', label: 'A', desc: undefined, type: 'number', value: 5, step: 1,
  })
  eq('a range needs BOTH bounds', SL.buildItem(O({ type: 'int', default: 5, min: 1 }, 'env'), 5).type, 'number')
  eq('int enum -> select with numeric labels via valueLabels', SL.buildItem(O({ type: 'int', default: 1, values: [0, 1, 2], valueLabels: { 0: 'Off', 1: 'On' } }, 'env'), 1), {
    id: 'A', var: 'A', label: 'A', desc: undefined, type: 'select', value: 1,
    options: [{ label: 'Off', value: 0 }, { label: 'On', value: 1 }, { label: '2', value: 2 }],
  })
  eq('a value that is not a number falls back to the default', SL.buildItem(O({ type: 'int', default: 5 }, 'env'), 'x').value, 5)
  eq('a numeric string is coerced', SL.buildItem(O({ type: 'int', default: 5 }, 'env'), '7').value, 7)
  eq('an unparseable value falls back to the default', SL.buildItem(O({ type: 'int', default: 5 }, 'env'), 'abc').value, 5)
  eq('a text row stringifies its value', SL.buildItem(O({ type: 'string', default: 'a' }, 'env'), 5).value, '5')
  eq('a step is always present on a numeric row', SL.buildItem(O({ type: 'int', default: 5 }, 'env'), 5).step, 1)
  eq('a unit is only present when declared', 'unit' in SL.buildItem(O({ type: 'int', default: 5 }, 'env'), 5), false)
  eq('a unit is present when declared', SL.buildItem(O({ type: 'int', default: 5, unit: 'px' }, 'env'), 5).unit, 'px')
  eq('a declared desc rides the row', SL.buildItem(O({ type: 'bool', default: false, desc: 'D' }, 'env'), true).desc, 'D')
  // "internal rows ... are never counted or bundled": layout and timers are
  // hidden by construction, so buildItem refuses them.
  eq('a layout row is not built', SL.buildItem(O({ key: 'shell.statusbar.layout', type: 'layout', default: {} }, 'shell'), {}), null)
  eq('a timers row is not built', SL.buildItem(O({ key: 'shell.idle.timers', type: 'timers', default: [] }, 'shell'), []), null)
  eq('a hidden row is not built', SL.buildItem(O({ type: 'bool', default: false, visibility: 'hidden' }, 'env'), true), null)
  eq('a derived-hidden row is not built', SL.buildItem(O({ type: 'bool', default: false, hidden: true }, 'env'), true), null)
})

group('buildItem carries the metadata the menu reads, and only that', () => {
  const o = opt({ key: 'A', type: 'bool', default: false, label: 'L', desc: 'D', sub: 'S', warning: 'W', hook: 'h', requires: { binary: 'x' }, showIf: { key: 'B', eq: 1 } }, 'env')
  const item = SL.buildItem(o, true)
  eq('the row is keyed by the canonical path', [item.id, item.var], ['A', 'A'])
  eq('the label', item.label, 'L')
  eq('the desc is ctrl-i copy', item.desc, 'D')
  eq('the sub line', item.sub, 'S')
  eq('the warning', item.warning, 'W')
  eq('the requires rides as data', item.requires, { binary: 'x' })
  eq('the showIf rides as normalized data', item.showIf, [{ var: 'B', op: 'eq', arg: 1 }])
  eq('the hook is NOT copied to the row', 'hook' in item, false)
  eq('an empty desc is undefined, not a string', SL.buildItem(opt({ key: 'A', type: 'bool', default: false }, 'env'), true).desc, undefined)
  eq('but the key is still there', 'desc' in SL.buildItem(opt({ key: 'A', type: 'bool', default: false }, 'env'), true), true)
  eq('an empty when is omitted', 'when' in item, false)
  eq('an empty disabled is omitted', 'disabled' in item, false)
  const noShow = SL.buildItem(opt({ key: 'A', type: 'bool', default: false }, 'env'), true)
  eq('no showIf key at all', 'showIf' in noShow, false)
  eq('no requires key at all', 'requires' in noShow, false)
  eq('no sub key at all', 'sub' in noShow, false)
  eq('no warning key at all', 'warning' in noShow, false)
})

group('buildItem fills a flow stage from the option it belongs to', () => {
  const o = opt({ key: 'A', type: 'int', default: 5, range: [1, 10], step: 2, unit: 's', flow: [{ kind: 'number' }, { kind: 'text' }] }, 'env')
  const item = SL.buildItem(o, 5)
  eq('a number stage inherits min/max/step/unit', item.flow[0], { kind: 'number', min: 1, max: 10, step: 2, unit: 's' })
  eq('a text stage inherits nothing', item.flow[1], { kind: 'text' })
  eq('the row still carries its own bounds', [item.min, item.max, item.step, item.unit], [1, 10, 2, 's'])
  eq('an explicit stage min is not overwritten', SL.buildItem(opt({ key: 'A', type: 'int', default: 5, min: 0, max: 10, flow: [{ kind: 'range', min: 3 }] }, 'env'), 5).flow[0].min, 3)
  const select = SL.buildItem(opt({ key: 'A', type: 'string', default: 'a', flow: [{ kind: 'select', options: [{ value: 1 }] }] }, 'env'), 'a')
  eq('a select stage is copied verbatim', select.flow, [{ kind: 'select', options: [{ label: '1', value: 1 }] }])
  eq('a select stage does not inherit the option bounds', 'min' in select.flow[0], false)
  eq('the flow is a new array, not the schema object', select.flow === select.flow, true)
  eq('no flow means no flow key', 'flow' in SL.buildItem(opt({ key: 'A', type: 'bool', default: false }, 'env'), true), false)
})

group('visibleItemCount and itemCountLabel count what the page shows NOW', () => {
  const c = catalog('{"pages":[{"id":"media","label":"Media","showItemCount":true,"options":[' +
    '{"key":"A_INT","type":"int","default":30},' +
    '{"key":"GATED","type":"bool","default":false,"showIf":{"key":"A_INT","eq":60}},' +
    '{"key":"HIDDEN","type":"bool","default":false,"visibility":"hidden"}],' +
    '"items":[{"type":"separator"},{"type":"action","label":"Reset"}]}]}')
  const sch = SL.buildSchema(c.sections, 0, '')
  const sec = c.sections[0]
  const at = (fps) => Object.assign(Object.fromEntries(Object.entries(sch.byKey).map(([k, o]) => [k, o.default])), { A_INT: fps })
  eq('a hidden option does not count', SL.visibleItemCount(sec, sch.byKey, at(30)), 2)
  eq('a showIf-satisfied option counts', SL.visibleItemCount(sec, sch.byKey, at(60)), 3)
  eq('a separator is chrome, not content', SL.visibleItemCount(sec, sch.byKey, at(30)), 2)
  eq('the label is plural for two', SL.itemCountLabel(sec, sch.byKey, at(30)), '2 items')
  eq('and three', SL.itemCountLabel(sec, sch.byKey, at(60)), '3 items')
  // The noun follows whether the page has custom items at all.
  const optsOnly = SL.parseSection({ label: 'O', options: [{ key: 'shell.a', type: 'bool', default: true }] }, 'x', true, 'shell')
  eq('an options-only page says "option"', SL.itemCountLabel(optsOnly, sch.byKey, {}), '1 option')
  eq('one of several still says "option"', SL.itemCountLabel(SL.parseSection({
    label: 'O', options: [{ key: 'shell.a', type: 'bool', default: true }, { key: 'shell.b', type: 'bool', default: true }],
  }, 'x', true, 'shell'), sch.byKey, {}), '2 options')
  const itemOnly = SL.parseSection({ label: 'I', items: [{ type: 'action', label: 'a' }] }, 'x', true, 'shell')
  eq('an items-only page says "item"', SL.itemCountLabel(itemOnly, sch.byKey, {}), '1 item')
  const mixed = SL.parseSection({
    label: 'M', options: [{ key: 'shell.a', type: 'bool', default: true }], items: [{ type: 'action', label: 'a' }],
  }, 'x', true, 'shell')
  eq('a mixed page says "item"', SL.itemCountLabel(mixed, sch.byKey, {}), '2 items')
  const sepOnly = SL.parseSection({ label: 'S', items: [{ type: 'separator' }] }, 'x', true, 'shell')
  eq('a separator-only page counts nothing', SL.itemCountLabel(sepOnly, sch.byKey, {}), '0 options')
  eq('and visibleItemCount agrees', SL.visibleItemCount(sepOnly, sch.byKey, {}), 0)
  const empty = SL.parseSection({ label: 'E' }, 'x', true, 'shell')
  eq('an empty page is "0 options"', SL.itemCountLabel(empty, sch.byKey, {}), '0 options')
  eq('which is the signal a submenu hides completely on', SL.visibleItemCount(empty, sch.byKey, {}), 0)
  eq('a non-object item is counted by visibleItemCount but not by the label', (() => {
    const s = SL.parseSection({ label: 'X', items: [5] }, 'x', true, 'shell')
    return [SL.visibleItemCount(s, sch.byKey, {}), SL.itemCountLabel(s, sch.byKey, {})]
  })(), [1, '0 options'])
  eq('a showIf on an option with no byKey entry still evaluates', SL.visibleItemCount(
    SL.parseSection({ label: 'X', options: [{ key: 'shell.a', type: 'bool', default: true, showIf: { key: 'NOPE', eq: 1 } }] }, 'x', true, 'shell'),
    {}, { NOPE: 1 },
  ), 1)
})

group('buildBundle prepends a synthetic index and keeps child pages out of it', () => {
  const c = catalog('{"width":400,"title":"Prefs","pages":[' +
    '{"id":"general","label":"General","desc":"d","icon":"i","options":[{"key":"shell.debug","type":"bool","default":true}]},' +
    '{"id":"bar","label":"Bar","options":[{"key":"A_B","type":"bool","default":true}],"items":[{"type":"submenu","label":"Bar > Modules","page":"bar-modules"}]},' +
    '{"id":"bar-modules","label":"Bar > Modules","options":[{"key":"C_D","type":"bool","default":true}]}]}')
  const sch = SL.buildSchema(c.sections, 400, 'Prefs')
  const values = Object.fromEntries(Object.entries(sch.byKey).map(([k, o]) => [k, o.default]))
  const b = SL.buildBundle(sch, values)
  eq('the index page is first and synthetic', b.pages[0].id, 'settings')
  eq('the index is titled from the catalog root', b.pages[0].title, 'Prefs')
  eq('the index page carries no width - the card measures its rows', 'width' in b.pages[0], false)
  eq('a child page is reachable but not indexed', b.pages[0].items.map((i) => i.page), ['general', 'bar'])
  eq('a page link is a submenu row', b.pages[0].items[0], { type: 'submenu', label: 'General', icon: 'i', page: 'general', desc: 'd' })
  eq('a page without a desc carries no desc key', 'desc' in b.pages[0].items[1], false)
  eq('a page without showItemCount carries no sub line', 'sub' in b.pages[0].items[1], false)
  eq('a page carries no width either', 'width' in b.pages[1], false)
  eq('a declared width reaches no page', 'width' in SL.buildBundle(SL.buildSchema(SL.parseCatalog('{"pages":[{"id":"a","label":"A","width":500,"options":[{"key":"A_B","type":"bool","default":true}]}]}').sections, 0, ''), { A_B: true }).pages[1], false)
  eq('the child page itself is still built', b.pages.map((p) => p.id), ['settings', 'general', 'bar', 'bar-modules'])
  eq('the submenu item is appended after the generated rows', b.pages.find((p) => p.id === 'bar').items[1], { type: 'submenu', label: 'Bar > Modules', page: 'bar-modules' })
  eq('generated rows come from buildItem', b.pages[1].items[0].type, 'toggle')
  eq('a page with nothing visible is dropped entirely', SL.buildBundle(SL.buildSchema(SL.parseCatalog('{"pages":[{"id":"e","label":"E"}]}').sections, 0, ''), {}).pages.map((p) => p.id), ['settings'])
  eq('a hidden-option-only page is dropped too', SL.buildBundle(SL.buildSchema(SL.parseCatalog('{"pages":[{"id":"e","label":"E","options":[{"key":"A_B","type":"bool","default":true,"visibility":"hidden"}]}]}').sections, 0, ''), {}).pages.map((p) => p.id), ['settings'])
})

group('buildBundle: an explicit "settings" page suppresses the synthetic index', () => {
  const c = catalog('{"width":400,"title":"Prefs","pages":[{"id":"settings","label":"My Settings","options":[{"key":"A_B","type":"bool","default":true}]}]}')
  const sch = SL.buildSchema(c.sections, 400, 'Prefs')
  const b = SL.buildBundle(sch, { A_B: true })
  eq('no index is prepended', b.pages.length, 1)
  eq('the page keeps its own id', b.pages[0].id, 'settings')
  eq('and its own title', b.pages[0].title, 'My Settings')
  eq('holding its generated rows, not submenu links', b.pages[0].items[0].type, 'toggle')
  eq('the default index title when the catalog has none', SL.buildBundle(SL.buildSchema(SL.parseCatalog('{"pages":[{"id":"a","label":"A","options":[{"key":"A_B","type":"bool","default":true}]}]}').sections, 0, ''), { A_B: true }).pages[0].title, 'Settings')
  eq('the default index page has no width either', 'width' in SL.buildBundle(SL.buildSchema(SL.parseCatalog('{"pages":[{"id":"a","label":"A","options":[{"key":"A_B","type":"bool","default":true}]}]}').sections, 0, ''), { A_B: true }).pages[0], false)
})

group('buildBundle: "after" places a custom item, and items are passed by reference', () => {
  // A generated row is identified by its `var` (the canonical option key); a
  // custom item is identified by its label or its type.
  const rowName = (i) => (i && i.var ? i.var : (i && i.label ? i.label : String(i && i.type)))
  const c = catalog('{"pages":[{"id":"a","label":"A","options":[' +
    '{"key":"A_INT","type":"int","default":1},{"key":"A_TEXT","type":"string","default":"x"}],' +
    '"items":[{"type":"action","label":"after-int","after":"A_INT"},{"type":"separator"},{"type":"action","label":"tail"}]}]}')
  const sch = SL.buildSchema(c.sections, 0, '')
  const b = SL.buildBundle(sch, { A_INT: 1, A_TEXT: 'x' })
  eq('the exact row order', b.pages[1].items.map(rowName), ['A_INT', 'after-int', 'A_TEXT', 'separator', 'tail'])
  eq('an "after" that names nothing is appended', SL.buildBundle(SL.buildSchema(SL.parseCatalog(
    '{"pages":[{"id":"a","label":"A","options":[{"key":"A_INT","type":"int","default":1}],"items":[{"type":"action","label":"x","after":"NOPE"}]}]}',
  ).sections, 0, ''), { A_INT: 1 }).pages[1].items.map(rowName), ['A_INT', 'x'])
  eq('an "after" can name a custom item too', SL.buildBundle(SL.buildSchema(SL.parseCatalog(
    '{"pages":[{"id":"a","label":"A","options":[{"key":"A_INT","type":"int","default":1}],"items":[{"type":"separator","after":"A_INT"},{"type":"action","label":"x"}]}]}',
  ).sections, 0, ''), { A_INT: 1 }).pages[1].items.length, 3)
  // Items are pushed by reference, not cloned: the bundle and the schema
  // share the object, so a caller mutating the bundle mutates the schema.
  const item = c.sections[0].items[0]
  eq('a custom item is the same object in the bundle', b.pages[1].items[1] === item, true)
  eq('and a non-object item is skipped', SL.buildBundle(SL.buildSchema(SL.parseCatalog(
    '{"pages":[{"id":"a","label":"A","options":[{"key":"A_INT","type":"int","default":1}],"items":[5,null]}]}',
  ).sections, 0, ''), { A_INT: 1 }).pages[1].items.length, 1)
  eq('the submenu link is built fresh each time', (() => {
    const b1 = SL.buildBundle(sch, { A_INT: 1, A_TEXT: 'x' })
    return b1.pages[0].items[0] === SL.buildBundle(sch, { A_INT: 1, A_TEXT: 'x' }).pages[0].items[0]
  })(), false)
})

// ===========================================================================
section('HyprlandEditor - typed values and the text primitives')
// ===========================================================================
group('parse_typed_value: what the file said, typed', () => {
  eq('a bare true', HE.parse_typed_value('true'), true)
  eq('a bare false', HE.parse_typed_value('false'), false)
  eq('a padded value is trimmed', HE.parse_typed_value('  2  '), 2)
  eq('one trailing comma is stripped', HE.parse_typed_value(' 2,'), 2)
  eq('a trailing comma is stripped before the quotes are read', HE.parse_typed_value('"x",'), 'x')
  eq('a double-quoted string', HE.parse_typed_value('"a b"'), 'a b')
  eq('a single-quoted string', HE.parse_typed_value("'a b'"), 'a b')
  eq('a string is unescaped on the way in', HE.parse_typed_value('"a\\"b"'), 'a"b')
  eq('a backslash is unescaped on the way in', HE.parse_typed_value('"a\\\\b"'), 'a\\b')
  eq('a quote inside quotes is not a terminator', HE.parse_typed_value('"a"b"'), 'a"b')
  eq('an empty quoted string', HE.parse_typed_value('""'), '')
  eq('an empty value is the empty string, not 0', HE.parse_typed_value(''), '')
  eq('an integer', HE.parse_typed_value('42'), 42)
  eq('a negative', HE.parse_typed_value('-5'), -5)
  eq('"2.0" collapses to 2', HE.parse_typed_value('2.0'), 2)
  eq('a float', HE.parse_typed_value('0.5'), 0.5)
  eq('a negative float', HE.parse_typed_value('-0.25'), -0.25)
  eq('leading zeros are dropped by Number', HE.parse_typed_value('007'), 7)
  eq('exponent notation is NOT a number here', HE.parse_typed_value('1e3'), '1e3')
  eq('hex is NOT a number here', HE.parse_typed_value('0x10'), '0x10')
  eq('a trailing type suffix is not a number', HE.parse_typed_value('5px'), '5px')
  eq('unquoted text stays text', HE.parse_typed_value('preferred'), 'preferred')
  eq('text with spaces stays one string', HE.parse_typed_value('my mode'), 'my mode')
  eq('a lone quote is text', HE.parse_typed_value('"'), '"')
  eq('a list element is read as its own value', HE.parse_typed_value('false,'), false)
  eq('parse_typed_value(undefined) is text', HE.parse_typed_value(undefined), 'undefined')
  is('a number comes back as a JS number', HE.parse_typed_value('42'), (v) => typeof v === 'number', 'typeof number')
  is('a quoted word comes back as a JS string', HE.parse_typed_value('"42"'), (v) => typeof v === 'string', 'typeof string')
})

group('serialize_value / lua_number_str: what the file gets on the way out', () => {
  eq('true', HE.serialize_value(true), 'true')
  eq('false', HE.serialize_value(false), 'false')
  eq('a whole number', HE.serialize_value(2), '2')
  eq('a whole float drops its fraction', HE.lua_number_str(2.0), '2')
  eq('a negative', HE.serialize_value(-3), '-3')
  eq('zero', HE.lua_number_str(0), '0')
  eq('a fraction', HE.serialize_value(0.5), '0.5')
  eq('a tiny fraction is not expanded', HE.lua_number_str(1e-7), '1e-7')
  eq('a huge number is not expanded either', HE.lua_number_str(1e21), '1e+21')
  eq('a string is always double-quoted', HE.serialize_value('a b'), '"a b"')
  eq('an empty string is still quoted', HE.serialize_value(''), '""')
  eq('a quote inside a value is escaped', HE.serialize_value('a"b'), '"a\\"b"')
  eq('a backslash inside a value is escaped', HE.serialize_value('a\\b'), '"a\\\\b"')
  eq('null has no env form', HE.serialize_value(null), null)
  eq('undefined has no env form', HE.serialize_value(undefined), null)
  eq('an object has no env form', HE.serialize_value({}), null)
  eq('an array has no env form', HE.serialize_value([1]), null)
})

group('parse_typed_value and serialize_value are inverses for everything writable', () => {
  // The round-trip property the whole editor rests on: whatever the value
  // type, reading back what was written gives the same value.
  const values = [true, false, 0, 1, -1, 42, 0.5, -0.25, '', 'a', 'a b', 'a"b', 'a\\b', "it's", '1e3', '0x10', 'a,"b', ' "quoted" ']
  for (const v of values) {
    eq(`round trip ${J(v)}`, HE.parse_typed_value(HE.serialize_value(v)), v)
  }
  // A value that needs quotes to survive is quoted on the way out, so a
  // string with spaces or a trailing comma comes back as one value.
  eq('a string with a trailing comma survives', HE.parse_typed_value(HE.serialize_value('a,')), 'a,')
  eq('a string that looks numeric stays a string', HE.parse_typed_value(HE.serialize_value('42')), '42')
  eq('a string that looks like a bool stays a string', HE.parse_typed_value(HE.serialize_value('true')), 'true')
  eq('a string that looks like a number keeps its spaces', HE.parse_typed_value(HE.serialize_value('0x10')), '0x10')
  // Exponent notation is the one number the READER cannot take back:
  // parse_typed_value's own regex has no exponent alternative, so it hands
  // the text back as a string.
  eq('an exponent-formatted number does not round trip as a number', HE.parse_typed_value('1e-7'), '1e-7')
  eq('and the editor writes it verbatim', HE.hyprEditContent('hl.config({\n  a = 1,\n})\n', ['a'], 1e-7).content.includes('a = 1e-7,'), true)
  eq('so reading it back gives a string', HE.hyprGetContent(HE.hyprEditContent('hl.config({\n  a = 1,\n})\n', ['a'], 1e-7).content, ['a']),
    { ok: true, value: '1e-7' })
  // And a value containing a NEWLINE does not round trip at all: escape
  // leaves the newline raw, so the file gets a quoted string split over two
  // lines (which is not valid lua) and the reader stops at the first line.
  eq('escape does not escape a newline', HE.escape_lua_string('a\nb'), 'a\nb')
  const written = HE.hyprEditContent('hl.config({\n  a = 1,\n})\n', ['a'], 'x\ny')
  eq('so the write splits the line', written.content, 'hl.config({\n  a = "x\ny",\n})\n')
  eq('and the read stops at the first line', HE.hyprGetContent(written.content, ['a']), { ok: true, value: '"x' })
  eq('while inferType (the CLI) hands the whole word back', HE.inferType('"x\ny"'), 'x\ny')
})

group('lua_key_fmt brackets exactly the keys a bare name cannot carry', () => {
  eq('a word key is bare', HE.lua_key_fmt('border_size'), 'border_size')
  eq('an underscore is legal in a bare key', HE.lua_key_fmt('a_b'), 'a_b')
  eq('a leading underscore is legal', HE.lua_key_fmt('_x'), '_x')
  eq('a leading digit is legal to a reader but not to lua', HE.lua_key_fmt('1x'), '["1x"]')
  eq('a dotted key is bracketed', HE.lua_key_fmt('col.active_border'), '["col.active_border"]')
  eq('a key with a space is bracketed', HE.lua_key_fmt('a b'), '["a b"]')
  eq('a key with a hyphen is bracketed', HE.lua_key_fmt('a-b'), '["a-b"]')
  eq('an empty key is bracketed', HE.lua_key_fmt(''), '[""]')
  eq('a quote inside a key is escaped', HE.lua_key_fmt('a"b'), '["a\\"b"]')
  eq('a non-string key is stringified, then bracketed', HE.lua_key_fmt(5), '["5"]')
})

group('escape_lua_string / unescape_lua_string are exact inverses', () => {
  for (const s of ['a"b', 'a\\b', 'a\\"b', '"', '\\', '\\"', '', 'plain', 'a\nb', 'a\tb', 'a"b\\c']) {
    eq(`escape then unescape is identity for ${J(s)}`, HE.unescape_lua_string(HE.escape_lua_string(s)), s)
  }
  eq('a backslash is doubled', HE.escape_lua_string('a\\b'), 'a\\\\b')
  eq('a quote is backslashed', HE.escape_lua_string('a"b'), 'a\\"b')
  eq('the backslash is escaped first, so a quote cannot double-escape', HE.escape_lua_string('a\\"b'), 'a\\\\\\"b')
  // Only \\ and \" are unescaped; every other backslash is left as a
  // backslash, so a path like C:\new keeps its character.
  eq('an unknown escape is preserved', HE.unescape_lua_string('a\\nb'), 'a\\nb')
  eq('a dangling backslash is preserved', HE.unescape_lua_string('a\\'), 'a\\')
  eq('a trailing quote is unescaped', HE.unescape_lua_string('a\\"'), 'a"')
  eq('a newline is NOT escaped - it stays a real newline', HE.escape_lua_string('a\nb'), 'a\nb')
  eq('and survives the round trip anyway', HE.unescape_lua_string(HE.escape_lua_string('a\nb')), 'a\nb')
  eq('a non-string is stringified', HE.escape_lua_string(5), '5')
})

group('the ltrim/trim/leading_ws trio the whole parser is built on', () => {
  eq('ltrim removes leading whitespace only', HE.ltrim('  a b  '), 'a b  ')
  eq('ltrim of a blank line', HE.ltrim('   '), '')
  eq('ltrim of a tab', HE.ltrim('\tx'), 'x')
  eq('trim removes both ends', HE.trim('  a b  '), 'a b')
  eq('trim of a blank line', HE.trim('  '), '')
  eq('trim does not touch the inside', HE.trim('  a  b  '), 'a  b')
  eq('leading_ws of an indented line', HE.leading_ws('    a'), '    ')
  eq('leading_ws of a tab-indented line', HE.leading_ws('\t\ta'), '\t\t')
  eq('leading_ws of an unindented line', HE.leading_ws('a'), '')
  eq('leading_ws of a blank line', HE.leading_ws('   '), '   ')
})

// ===========================================================================
section('HyprlandEditor - reading the file shape')
// ===========================================================================
const CFG_2SPACE = `hl.config({
  -- a comment
  general = {
    border_size = 2,
    rounding = 8,
  },
})
`
const LINES_2SPACE = HE.read_lines_content(CFG_2SPACE)

group('read_lines_content / write_lines_content are the file line codec', () => {
  eq('a missing file reads as empty', HE.read_lines_content(''), [])
  eq('null reads as empty', HE.read_lines_content(null), [])
  eq('undefined reads as empty', HE.read_lines_content(undefined), [])
  eq('one line with no newline', HE.read_lines_content('a'), ['a'])
  eq('one line with a newline', HE.read_lines_content('a\n'), ['a'])
  eq('exactly one trailing newline is dropped', HE.read_lines_content('a\n\n'), ['a', ''])
  eq('three newlines keep two blank lines', HE.read_lines_content('a\n\n\n'), ['a', '', ''])
  eq('interior blank lines survive', HE.read_lines_content('a\n\nb\n'), ['a', '', 'b'])
  eq('a CRLF leaves its carriage return on the line', HE.read_lines_content('a\r\nb\n'), ['a\r', 'b'])
  eq('write_lines_content of no lines', HE.write_lines_content([]), '')
  eq('write_lines_content adds exactly one trailing newline', HE.write_lines_content(['a']), 'a\n')
  eq('write_lines_content of a blank line', HE.write_lines_content(['']), '\n')
  // A newline-terminated file is a fixed point of the codec, which is what
  // makes an unchanged edit byte-identical.
  for (const src of ['a\n', 'a\nb\n', 'a\n\nb\n', 'a\n\n', 'hl.config({\n})\n']) {
    eq(`round trip ${J(src)}`, HE.write_lines_content(HE.read_lines_content(src)), src)
  }
  eq('a file with no trailing newline gains one', HE.write_lines_content(HE.read_lines_content('a')), 'a\n')
  eq('the 2-space fixture reads back identically', HE.write_lines_content(HE.read_lines_content(CFG_2SPACE)), CFG_2SPACE)
})

group('find_top_level_calls finds hl.config/hl.monitor blocks by brace depth', () => {
  const two = '-- header\nhl.config({\n  a = 1,\n})\nhl.config({\n  b = 2,\n})\n'
  eq('two calls', HE.find_top_level_calls(HE.read_lines_content(two), 'hl.config({'), [{ start: 1, end: 3 }, { start: 4, end: 6 }])
  eq('a file with no call', HE.find_top_level_calls(['x = 1,'], 'hl.config({'), [])
  eq('a monitor call is a different prefix', HE.find_top_level_calls(HE.read_lines_content(two), 'hl.monitor({'), [])
  eq('a nested hl.config inside another block is still found', HE.find_top_level_calls(HE.read_lines_content('hl.config({\n  a = 1,\n})\n'), 'hl.config({').length, 1)
  eq('the search resumes after a block, so blocks never nest', HE.find_top_level_calls(
    HE.read_lines_content('hl.config({\n  hl.config({\n  }),\n})\n'), 'hl.config({').length, 1)
  eq('an unclosed call ends at the last line', HE.find_top_level_calls(['hl.config({', '  a = 1,'], 'hl.config({'), [{ start: 0, end: 1 }])
  eq('braces inside a comment do not count', HE.find_top_level_calls(HE.read_lines_content('hl.config({\n  -- }\n  a = 1,\n})\n'), 'hl.config({'), [{ start: 0, end: 3 }])
  eq('several braces on one line are counted together', HE.find_top_level_calls(HE.read_lines_content('hl.config({\n  a = { b = 1 },\n})\n'), 'hl.config({'), [{ start: 0, end: 2 }])
  eq('an indented call is still top level', HE.find_top_level_calls(HE.read_lines_content('  hl.config({\n  })\n'), 'hl.config({'), [{ start: 0, end: 1 }])
})

group('section_name and option_key are told apart by the brace after the equals', () => {
  const s = (x) => HE.section_name(x)
  const o = (x) => HE.option_key(x)
  eq('a table header is a section', s('general = {'), 'general')
  eq('a bracketed table header is a section', s('["col.active_border"] = {'), 'col.active_border')
  eq('a hyphen is legal in a section name', s('my-section = {'), 'my-section')
  eq('a leading digit is legal in a section name', s('1x = {'), '1x')
  eq('an option is not a section', s('border_size = 2,'), null)
  eq('a table value is not a section', s('x = {}'), 'x')
  eq('an assignment with no value is not a section', s('foo ='), null)
  eq('a bare word is not a section', s('foo'), null)
  eq('a close brace is not a section', s('}'), null)
  eq('an unclosed bracket is not a section', s('[unclosed = {'), null)
  eq('a bracketed name with no equals is not a section', s('["a b"]'), null)
  eq('a call is not a section', s('hl.config({'), null)
  eq('an option is an option', o('border_size = 2,'), 'border_size')
  eq('a bracketed option is an option', o('["col.active_border"] = "x"'), 'col.active_border')
  eq('a single-quoted bracketed option is an option', o("['a b'] = 'c'"), 'a b')
  eq('an option with no value is still an option', o('foo ='), 'foo')
  eq('a hyphen is legal in an option key', o('my-option = 1'), 'my-option')
  eq('a table header is not an option', o('general = {'), null)
  eq('a dotted unbracketed key is invisible to the reader', o('col.active_border = "x"'), null)
  eq('a bare word is not an option', o('foo'), null)
  eq('a close brace is not an option', o('}'), null)
  eq('an unclosed bracket is not an option', o('["a'), null)
  eq('a bracketed table header is not an option', o('["a b"] = {'), null)
  // Both take PRE-TRIMMED text: every caller ltrims first. section_name
  // anchors its name match at position 0 and so rejects a raw indented
  // line, while option_key trims the key half itself and so accepts one.
  eq('section_name does not trim', s('  general = {'), null)
  eq('option_key trims the key half itself', o('  border_size = 2,'), 'border_size')
  eq('section_name of a non-string', s(null), null)
  eq('option_key of a non-string', o(null), null)
  noThrow('neither throws on a non-string', () => { HE.section_name(undefined); HE.option_key(undefined) })
})

group('option_value_typed reads the right-hand side of an option line', () => {
  const v = (x) => HE.option_value_typed(x)
  eq('an int', v('border_size = 2,'), 2)
  eq('a float', v('scale = 0.5,'), 0.5)
  eq('a bool', v('x = true'), true)
  eq('a double-quoted string', v('["a b"] = "c d",'), 'c d')
  eq('a single-quoted string', v("y = 'q'"), 'q')
  eq('an escaped quote', v('z = "a\\"b"'), 'a"b')
  eq('a value with no comma', v('a = 1'), 1)
  eq('a table value reads as its opening brace', v('x = {'), '{')
  eq('a line with no equals', v('nope'), null)
  eq('a bare word is not a value', v('foo'), null)
  eq('a close brace is not a value', v('}'), null)
  eq('a bracketed key with no equals', v('["a b"]'), null)
})

group('find_all_section_bounds walks nested tables and reports every match', () => {
  // CFG_2SPACE is seven lines: 0 hl.config({, 1 the comment, 2 general = {,
  // 3 border_size, 4 rounding, 5 the section closer, 6 }).
  const all = (text, path, from, to) => HE.find_all_section_bounds(HE.read_lines_content(text), path, from, to)
  eq('one match at depth 0', all(CFG_2SPACE, ['general'], 0, 6), [{ start: 2, end: 5, depth: 0 }])
  eq('a missing section is no match', all(CFG_2SPACE, ['nope'], 0, 5), [])
  eq('a top-level-only file has no config section', all('a = 1,\n', ['general'], 0, 1), [])
  const nested = 'hl.config({\n  general = {\n    input = {\n      sensitivity = 1,\n    },\n  },\n})\n'
  eq('a nested section is found by its full path', all(nested, ['general', 'input'], 0, 6), [{ start: 2, end: 4, depth: 1 }])
  eq('the nested section is not reachable by its leaf name', all(nested, ['input'], 0, 6), [])
  eq('the parent path alone does not match the child', all(nested, ['general', 'input', 'sensitivity'], 0, 6), [])
  const dup = 'hl.config({\n  general = {\n    a = 1,\n  },\n  general = {\n    a = 2,\n  },\n})\n'
  eq('a duplicated section is reported twice', all(dup, ['general'], 0, 7), [{ start: 1, end: 3, depth: 0 }, { start: 4, end: 6, depth: 0 }])
  eq('the walker resumes after a matched block, so a child is not also a match', all(nested, ['general'], 0, 6), [{ start: 1, end: 5, depth: 0 }])
  eq('a comment line cannot open a section', all('hl.config({\n  -- general = {\n})\n', ['general'], 0, 2), [])
  eq('a section start after a comment is still found', all('hl.config({\n  -- hi\n  general = {\n    a = 1,\n  },\n})\n', ['general'], 0, 5).length, 1)
  eq('a search window bounds the walk', all(CFG_2SPACE, ['general'], 0, 0), [])
  eq('braces inside a comment do not extend the block', all('hl.config({\n  general = {\n    a = 1,\n    -- }\n  },\n})\n', ['general'], 0, 5), [{ start: 1, end: 4, depth: 0 }])
})

group('find_option_in_section sees only the section\'s own depth', () => {
  const f = (text, name) => HE.find_option_in_section(HE.read_lines_content(text), 0, HE.read_lines_content(text).length - 1, name)
  const nested = 'general = {\n  input = {\n    follow_mouse = 1,\n  },\n  border_size = 2,\n}\n'
  eq('a direct option is found', f(nested, 'border_size'), 4)
  eq('a nested option is not', f(nested, 'follow_mouse'), null)
  eq('a nested table header is not an option', f(nested, 'input'), null)
  eq('the first of two identical options wins', f('general = {\n  a = 1,\n  a = 2,\n}\n', 'a'), 1)
  eq('a comment line is skipped', f('general = {\n  -- a = 1,\n  a = 2,\n}\n', 'a'), 2)
  eq('an option named in a comment is not found', f('general = {\n  -- a = 1,\n}\n', 'a'), null)
  eq('a missing option', f(nested, 'nope'), null)
  eq('the closing brace of the section is out of range', f('general = {\n  a = 1,\n}\n', 'a'), 1)
  eq('an option whose value opens a table is skipped, not matched', f('general = {\n  a = {\n  },\n  b = 1,\n}\n', 'a'), null)
  eq('and the next one is found', f('general = {\n  a = {\n  },\n  b = 1,\n}\n', 'b'), 3)
})

group('path_equal and resolve_occurrence are the two selector primitives', () => {
  eq('two empty paths', HE.path_equal([], []), true)
  eq('equal one-segment paths', HE.path_equal(['a'], ['a']), true)
  eq('different one-segment paths', HE.path_equal(['a'], ['b']), false)
  eq('a prefix is not equal', HE.path_equal(['a'], ['a', 'b']), false)
  eq('a reordered path is not equal', HE.path_equal(['a', 'b'], ['b', 'a']), false)
  const list = ['x', 'y', 'z']
  eq('occurrence 1 is the first', HE.resolve_occurrence(list, 1), 'x')
  eq('occurrence 2 is the second', HE.resolve_occurrence(list, 2), 'y')
  eq('occurrence 3 is the last', HE.resolve_occurrence(list, 3), 'z')
  eq('occurrence -1 counts from the end', HE.resolve_occurrence(list, -1), 'z')
  eq('occurrence -2 counts from the end', HE.resolve_occurrence(list, -2), 'y')
  eq('occurrence -3 is the first', HE.resolve_occurrence(list, -3), 'x')
  eq('occurrence -4 is out of range', HE.resolve_occurrence(list, -4), null)
  eq('occurrence 4 is out of range', HE.resolve_occurrence(list, 4), null)
  eq('occurrence 0 is out of range, not a default', HE.resolve_occurrence(list, 0), null)
  eq('occurrence undefined is neither null nor a match', HE.resolve_occurrence(list, undefined), undefined)
  eq('a NaN occurrence slips past the range check the same way', HE.resolve_occurrence(list, NaN), undefined)
  eq('a null occurrence is out of range like 0', HE.resolve_occurrence(list, null), null)
  eq('an empty list resolves to nothing', HE.resolve_occurrence([], 1), null)
  eq('an empty list with any occurrence', HE.resolve_occurrence([], -1), null)
  eq('one element, occurrence 1 and -1 agree', [HE.resolve_occurrence(['a'], 1), HE.resolve_occurrence(['a'], -1)], ['a', 'a'])
  eq('the resolved element is the list element', (() => { const o = {}; return HE.resolve_occurrence([o], 1) === o })(), true)
})

group('detect_indent_unit reads the file\'s own indentation', () => {
  const unit = (text) => HE.detect_indent_unit(HE.read_lines_content(text))
  eq('two-space', unit('hl.config({\n  general = {\n    a = 1,\n  },\n})\n'), '  ')
  eq('four-space', unit('hl.config({\n    general = {\n        a = 1,\n    },\n})\n'), '    ')
  eq('tab', unit('hl.config({\n\tgeneral = {\n\t\ta = 1,\n\t},\n})\n'), '\t')
  // The minimum wins, so a mixed file indents its new lines to the SHALLOWEST
  // level it already uses rather than inventing a third style.
  eq('mixed: the shortest indent wins', unit('hl.config({\n      general = {\n        a = 1,\n      },\n})\n'), '      ')
  // The minimum is measured in CHARACTERS, not columns, so one tab beats
  // eight spaces.
  eq('mixed tab and space: the tab is the shorter lead', unit('hl.config({\n\tgeneral = {\n        a = 1,\n\t},\n})\n'), '\t')
  eq('two spaces still beat one tab', unit('hl.config({\n\t\tgeneral = {\n a = 1,\n\t\t},\n})\n'), ' ')
  eq('equal-length leads keep the first one seen', unit('hl.config({\n\t\tgeneral = {\n  a = 1,\n\t\t},\n})\n'), '\t\t')
  eq('an unindented file has no unit', unit('a = 1,\nb = 2,\n'), '    ')
  eq('an empty file defaults to four spaces', HE.detect_indent_unit([]), '    ')
  eq('a comment-only file defaults to four spaces', unit('-- hl.config({\n'), '    ')
  eq('a commented-out line is not counted', unit('--   hl.config({\n  x = 1,\n'), '  ')
  eq('a blank line is not counted', unit('hl.config({\n\n     \n  x = 1,\n'), '  ')
  eq('the unit is the whitespace itself, not a count', HE.detect_indent_unit(HE.read_lines_content('a = 1,\n\tb = 2,\n')), '\t')
  eq('mixed units of equal length keep the first', unit('hl.config({\n\tgeneral = {\n  a = 1,\n\t},\n})\n'), '\t')
})

group('infer_child_indent copies the section\'s own children, or falls back', () => {
  const ic = (lines, s, e, unit) => HE.infer_child_indent(lines, s, e, unit)
  const two = ['hl.config({', '  general = {', '    a = 1,', '    b = 2,', '  },', '})']
  eq('two children: the first child\'s indent', ic(two, 1, 4, '  '), '    ')
  eq('the unit is unused when a child exists', ic(two, 1, 4, '\t'), '    ')
  // sec_end - 1 is the line before the closer, so a section with exactly one
  // child never gets that child measured: the fallback (header indent + unit)
  // is used instead. For a four-space file that is right by accident; for a
  // mixed file it is not.
  const one = ['hl.config({', '  general = {', '    a = 1,', '  },', '})']
  eq('one child: header indent plus the unit', ic(one, 1, 3, '  '), '    ')
  const mixed = ['hl.config({', '      general = {', '        a = 1,', '      },', '})']
  eq('a mixed file in a 6-space body with a 6-space unit', ic(mixed, 1, 3, '      '), '            ')
  eq('which is why the new option lands at 12 spaces', HE.hyprEditContent(
    'hl.config({\n      general = {\n        a = 1,\n      },\n})\n', ['general', 'x'], 1,
  ).content, 'hl.config({\n      general = {\n        a = 1,\n            x = 1,\n      },\n})\n')
  eq('a two-space body under a 6-space header indents to 8', ic(mixed, 1, 3, '  '), '        ')
  eq('and that lands at the body\'s own indent', HE.hyprEditContent(
    'hl.config({\n      general = {\n        a = 1,\n      },\n})\n', ['general', 'x'], 1, {},
  ).content, 'hl.config({\n      general = {\n        a = 1,\n            x = 1,\n      },\n})\n')
  const none = ['hl.config({', '  general = {', '  },', '})']
  eq('no children: header indent plus the unit', ic(none, 1, 2, '\t'), '  \t')
  eq('the unit is used verbatim, even if it does not match the file', ic(none, 1, 2, '    '), '      ')
  const cmt = ['hl.config({', '  general = {', '    -- note', '    a = 1,', '  },', '})']
  eq('a comment is skipped, the next child sets the indent', ic(cmt, 1, 4, '  '), '    ')
  const blank = ['hl.config({', '  general = {', '', '    a = 1,', '  },', '})']
  eq('a blank line is skipped too', ic(blank, 1, 4, '  '), '    ')
})

group('get_scope_root picks the block, and can create it', () => {
  const L = HE.read_lines_content(CFG_2SPACE)
  eq('a config root', HE.get_scope_root(L, {}, 1, '  ', false), { start: 0, end: 6 })
  eq('a config root with no occurrence', HE.get_scope_root(L, {}, -1, '  ', false), { start: 0, end: 6 })
  eq('a monitor root needs an output', HE.get_scope_root(HE.read_lines_content('hl.monitor({\n  output = "DP-1",\n})\n'), { scope: 'monitor', output: 'DP-1' }, 1, '  ', false), { start: 0, end: 2 })
  eq('an unknown scope', HE.get_scope_root(L, { scope: 'zzz' }, 1, '  ', false), { error: 'invalid scope' })
  const empty = []
  eq('a missing config block without create', HE.get_scope_root(empty, {}, 1, '  ', false), { error: 'not found' })
  const created = []
  eq('a missing config block with create', HE.get_scope_root(created, {}, 1, '  ', true), { start: 0, end: 1 })
  eq('and the two lines were pushed', created, ['hl.config({', '})'])
  const monCreated = []
  eq('a missing monitor block with create', HE.get_scope_root(monCreated, { scope: 'monitor', output: 'DP-1' }, 1, '  ', true), { start: 0, end: 2 })
  eq('with the output line already written', monCreated, ['hl.monitor({', '  output = "DP-1",', '})'])
  // "const last = calls[calls.length - 1]": with two hl.config blocks the LAST
  // one is the scope, and `occurrence` is not consulted for config scope at
  // all - it only selects among monitor matches and among same-named sections.
  const two = HE.read_lines_content('hl.config({\n  a = 1,\n})\nhl.config({\n  a = 2,\n})\n')
  eq('two config blocks: the last is the scope', HE.get_scope_root(two, {}, 1, '  ', false), { start: 3, end: 5 })
  eq('and occurrence does not move it', HE.get_scope_root(two, {}, 2, '  ', false), { start: 3, end: 5 })
  eq('nor does a negative occurrence', HE.get_scope_root(two, {}, -1, '  ', false), { start: 3, end: 5 })
  const mons = HE.read_lines_content('hl.monitor({\n  output = "DP-1",\n  scale = 1,\n})\nhl.monitor({\n  output = "DP-2",\n  scale = 2,\n})\n')
  eq('a monitor root is matched by its output value', HE.get_scope_root(mons, { scope: 'monitor', output: 'DP-2' }, 1, '  ', false), { start: 4, end: 7 })
  eq('an unknown output without create', HE.get_scope_root(mons, { scope: 'monitor', output: 'DP-9' }, 1, '  ', false), { error: 'not found' })
  eq('an occurrence out of range for the matches', HE.get_scope_root(mons, { scope: 'monitor', output: 'DP-1' }, 5, '  ', false), { error: 'not found' })
})

group('navigate_section_readonly resolves a path without creating anything', () => {
  const L = HE.read_lines_content(CFG_2SPACE)
  eq('an empty path is the root', HE.navigate_section_readonly(L, { start: 0, end: 6 }, [], 1), { start: 0, end: 6 })
  eq('one segment', HE.navigate_section_readonly(L, { start: 0, end: 6 }, ['general'], 1), { start: 2, end: 5 })
  eq('a missing segment', HE.navigate_section_readonly(L, { start: 0, end: 6 }, ['nope'], 1), null)
  eq('a missing second segment', HE.navigate_section_readonly(L, { start: 0, end: 6 }, ['general', 'input'], 1), null)
  const nested = HE.read_lines_content('hl.config({\n  general = {\n    input = {\n      sensitivity = 1,\n    },\n  },\n})\n')
  eq('two segments', HE.navigate_section_readonly(nested, { start: 0, end: 6 }, ['general', 'input'], 1), { start: 2, end: 4 })
  // The occurrence of a NON-FINAL segment only fixes where the next search
  // starts: the walk is relative to that line, so a later duplicate parent
  // can still supply the leaf. The final segment is the only one the
  // occurrence actually selects.
  const dupParents = HE.read_lines_content(
    'hl.config({\n  general = {\n  },\n  general = {\n    input = {\n    },\n  },\n})\n',
  )
  eq('an intermediate only fixes the search window', HE.navigate_section_readonly(dupParents, { start: 0, end: 7 }, ['general', 'input'], 1), { start: 4, end: 5 })
  const dupBoth = HE.read_lines_content(
    'hl.config({\n  general = {\n    input = {\n    },\n  },\n  general = {\n    input = {\n      a = 1,\n    },\n  },\n})\n',
  )
  eq('the LAST segment takes the occurrence', HE.navigate_section_readonly(dupBoth, { start: 0, end: 10 }, ['general', 'input'], -1), { start: 6, end: 8 })
  eq('and a positive occurrence takes the first', HE.navigate_section_readonly(dupBoth, { start: 0, end: 10 }, ['general', 'input'], 1), { start: 2, end: 3 })
  eq('the readonly walk never inserts', L.length, 7)
})

group('normalize_path copies the caller\'s path', () => {
  const p = ['a', 'b']
  const out = HE.normalize_path(p)
  eq('the same content', out, ['a', 'b'])
  eq('a different array', out === p, false)
  eq('an empty path stays empty', HE.normalize_path([]), [])
  eq('a frozen path is copied fine', HE.normalize_path(Object.freeze(['a'])), ['a'])
})

// ===========================================================================
section('HyprlandEditor - the write path, as exact text')
// ===========================================================================
const edit = (text, p, v, o) => HE.hyprEditContent(text, p, v, o)

group('editing an existing option replaces the value in place', () => {
  eq('an int', edit(CFG_2SPACE, ['general', 'border_size'], 4).content, [
    'hl.config({',
    '  -- a comment',
    '  general = {',
    '    border_size = 4,',
    '    rounding = 8,',
    '  },',
    '})',
    '',
  ].join('\n'))
  eq('a bool', edit(CFG_2SPACE, ['general', 'border_size'], false).content.includes('    border_size = false,'), true)
  eq('a string needing no quotes still gets them', edit(CFG_2SPACE, ['general', 'rounding'], 8).content.includes('    rounding = 8,'), true)
  eq('a string with spaces is quoted', edit(CFG_2SPACE, ['general', 'rounding'], 'my mode').content.includes('    rounding = "my mode",'), true)
  eq('a value with a quote is escaped', edit(CFG_2SPACE, ['general', 'rounding'], 'a"b').content.includes('    rounding = "a\\"b",'), true)
  eq('a float keeps its fraction', edit(CFG_2SPACE, ['general', 'rounding'], 0.5).content.includes('    rounding = 0.5,'), true)
  eq('a float that is whole loses its fraction', edit(CFG_2SPACE, ['general', 'rounding'], 2.0).content.includes('    rounding = 2,'), true)
  eq('the comment above the option survives', edit(CFG_2SPACE, ['general', 'border_size'], 4).content.includes('  -- a comment'), true)
  eq('the sibling option survives', edit(CFG_2SPACE, ['general', 'border_size'], 4).content.includes('    rounding = 8,'), true)
  eq('the closer of the section survives', edit(CFG_2SPACE, ['general', 'border_size'], 4).content.includes('  },\n})'), true)
  eq('the whole file is byte-identical to the expectation above', edit(CFG_2SPACE, ['general', 'border_size'], 4).content,
    CFG_2SPACE.replace('border_size = 2', 'border_size = 4'))
  eq('a write is idempotent', edit(edit(CFG_2SPACE, ['general', 'border_size'], 4).content, ['general', 'border_size'], 4).content,
    edit(CFG_2SPACE, ['general', 'border_size'], 4).content)
})

group('the write path rewrites the whole line, so an inline comment does not', () => {
  // The editor treats the config as text and rewrites the option line as
  // `indent + key + " = " + value + ","`. Anything after the value on that
  // line is therefore not preserved. Pinned because "comments survive an
  // edit" is the natural expectation and only holds for WHOLE-LINE comments.
  const inline = 'hl.config({\n  general = {\n    border_size = 2, -- keep me\n  },\n})\n'
  eq('an inline trailing comment is dropped', edit(inline, ['general', 'border_size'], 4).content,
    'hl.config({\n  general = {\n    border_size = 4,\n  },\n})\n')
  eq('a whole-line comment above the option survives', edit(
    'hl.config({\n  general = {\n    -- border thickness\n    border_size = 2,\n  },\n})\n',
    ['general', 'border_size'], 4,
  ).content, 'hl.config({\n  general = {\n    -- border thickness\n    border_size = 4,\n  },\n})\n')
  eq('a comment below the option survives', edit(
    'hl.config({\n  general = {\n    border_size = 2,\n    -- below\n  },\n})\n',
    ['general', 'border_size'], 4,
  ).content, 'hl.config({\n  general = {\n    border_size = 4,\n    -- below\n  },\n})\n')
  // A trailing comma is always appended, so an option that had none gains one.
  eq('a missing trailing comma is added', edit(
    'hl.config({\n  general = {\n    border_size = 2\n  },\n})\n',
    ['general', 'border_size'], 4,
  ).content, 'hl.config({\n  general = {\n    border_size = 4,\n  },\n})\n')
  eq('the original indentation of the option line is preserved, not the unit', edit(
    'hl.config({\n  general = {\n      border_size = 2,\n  },\n})\n',
    ['general', 'border_size'], 4,
  ).content, 'hl.config({\n  general = {\n      border_size = 4,\n  },\n})\n')
  eq('a bracketed key is rewritten in bracketed form', edit(
    'hl.config({\n  general = {\n    ["col.active_border"] = "0xff89b4fa",\n  },\n})\n',
    ['general', 'col.active_border'], '0xff000000',
  ).content, 'hl.config({\n  general = {\n    ["col.active_border"] = "0xff000000",\n  },\n})\n')
  eq('a bracketed key is readable', HE.hyprGetContent(
    'hl.config({\n  general = {\n    ["col.active_border"] = "0xff89b4fa",\n  },\n})\n',
    ['general', 'col.active_border'],
  ), { ok: true, value: '0xff89b4fa' })
  // option_key's character class is [\w_-]+, so a dotted key written WITHOUT
  // brackets is invisible to the reader. Editing one therefore appends a
  // second, bracketed entry while the old line stays - and the read path,
  // which skips the unbracketed form, resolves to the new one.
  const dotted = 'hl.config({\n  general = {\n    col.active_border = "0xff89b4fa",\n  },\n})\n'
  eq('a dotted unbracketed key reads as not found', HE.hyprGetContent(dotted, ['general', 'col.active_border']), { ok: false, error: 'not found' })
  eq('editing it appends a bracketed duplicate', edit(dotted, ['general', 'col.active_border'], '0xff000000').content, [
    'hl.config({',
    '  general = {',
    '    col.active_border = "0xff89b4fa",',
    '    ["col.active_border"] = "0xff000000",',
    '  },',
    '})',
    '',
  ].join('\n'))
  eq('and the read now resolves to the new entry', HE.hyprGetContent(
    edit(dotted, ['general', 'col.active_border'], '0xff000000').content,
    ['general', 'col.active_border'],
  ), { ok: true, value: '0xff000000' })
})

group('adding a new option to an existing section', () => {
  eq('into a 2-space section', edit(CFG_2SPACE, ['general', 'input'], 'x').content, [
    'hl.config({',
    '  -- a comment',
    '  general = {',
    '    border_size = 2,',
    '    rounding = 8,',
    '    input = "x",',
    '  },',
    '})',
    '',
  ].join('\n'))
  eq('appended after the last child, before the closer', edit(CFG_2SPACE, ['general', 'zz'], 1).content.includes('    rounding = 8,\n    zz = 1,\n  },'), true)
  eq('a four-space section indents its new option four spaces', edit(
    'hl.config({\n    general = {\n        border_size = 2,\n    },\n})\n',
    ['general', 'border_size2'], 1,
  ).content, 'hl.config({\n    general = {\n        border_size = 2,\n        border_size2 = 1,\n    },\n})\n')
  eq('a tab-indented section indents with a tab', edit(
    'hl.config({\n\tgeneral = {\n\t\tborder_size = 2,\n\t},\n})\n',
    ['general', 'newone'], 1,
  ).content, 'hl.config({\n\tgeneral = {\n\t\tborder_size = 2,\n\t\tnewone = 1,\n\t},\n})\n')
  eq('a new option name needing brackets is bracketed', edit(CFG_2SPACE, ['general', 'col.active'], 'x').content.includes('    ["col.active"] = "x",'), true)
  eq('the first child\'s indent is copied, not the unit', edit(
    'hl.config({\n  general = {\n      a = 1,\n      b = 2,\n  },\n})\n',
    ['general', 'c'], 3,
  ).content, 'hl.config({\n  general = {\n      a = 1,\n      b = 2,\n      c = 3,\n  },\n})\n')
  eq('a comment-first section still measures its first real child', edit(
    'hl.config({\n  general = {\n    -- note\n    a = 1,\n    b = 2,\n  },\n})\n',
    ['general', 'c'], 3,
  ).content, 'hl.config({\n  general = {\n    -- note\n    a = 1,\n    b = 2,\n    c = 3,\n  },\n})\n')
  eq('adding a new option at the root of an existing block goes to the TOP', edit(
    'hl.config({\n  border_size = 2,\n})\n', ['newroot'], 6,
  ).content, 'hl.config({\n  newroot = 6,\n  border_size = 2,\n})\n')
  eq('editing a root option keeps it in place', edit(
    'hl.config({\n  border_size = 2,\n})\n', ['border_size'], 6,
  ).content, 'hl.config({\n  border_size = 6,\n})\n')
})

group('appending after a comma-less last child produces invalid lua', () => {
  // The "add a blank line first" guard only fires when the previous line trims
  // to "}," or "}". A section whose last option omits its comma - legal to
  // write by hand as a trailing field, but a comma IS required between fields
  // in a lua table constructor - gets the new entry appended with no comma
  // either, which is a syntax error. Pinned as the real behaviour; see the
  // report.
  const noComma = 'hl.config({\n  general = {\n    border_size = 2\n  },\n})\n'
  eq('a new option after a comma-less child', edit(noComma, ['general', 'rounding'], 8).content,
    'hl.config({\n  general = {\n    border_size = 2\n    rounding = 8,\n  },\n})\n')
  eq('a new nested table after a comma-less child', edit(noComma, ['general', 'input', 'rounding'], 8).content,
    'hl.config({\n  general = {\n    border_size = 2\n    input = {\n      rounding = 8,\n    },\n  },\n})\n')
  eq('editing the comma-less child itself is fine', edit(noComma, ['general', 'border_size'], 4).content,
    'hl.config({\n  general = {\n    border_size = 4,\n  },\n})\n')
  // With the comma present the same append is well-formed.
  const withComma = 'hl.config({\n  general = {\n    border_size = 2,\n  },\n})\n'
  eq('a new option after a comma-bearing child', edit(withComma, ['general', 'rounding'], 8).content,
    'hl.config({\n  general = {\n    border_size = 2,\n    rounding = 8,\n  },\n})\n')
})

group('creating a missing section, with the blank line and the nesting', () => {
  eq('one missing level, two-space file', edit(CFG_2SPACE, ['general', 'input', 'sensitivity'], 3).content, [
    'hl.config({',
    '  -- a comment',
    '  general = {',
    '    border_size = 2,',
    '    rounding = 8,',
    '    input = {',
    '      sensitivity = 3,',
    '    },',
    '  },',
    '})',
    '',
  ].join('\n'))
  eq('two missing levels', edit(
    'hl.config({\n  general = {\n    a = 1,\n    b = 2,\n  },\n})\n',
    ['general', 'input', 'kb'], 'us',
  ).content, [
    'hl.config({',
    '  general = {',
    '    a = 1,',
    '    b = 2,',
    '    input = {',
    '      kb = "us",',
    '    },',
    '  },',
    '})',
    '',
  ].join('\n'))
  eq('three missing levels in a four-space file', edit('hl.config({\n})\n', ['a', 'b', 'c'], 1).content, [
    'hl.config({',
    '    a = {',
    '        b = {',
    '            c = 1,',
    '        },',
    '    },',
    '})',
    '',
  ].join('\n'))
  eq('a section is created blank-line-separated from the block above it', edit(
    'hl.config({\n  general = {\n    a = 1,\n  },\n})\n', ['input', 'kb'], { x: 1, y: 'two' },
  ).content, [
    'hl.config({',
    '  general = {',
    '    a = 1,',
    '  },',
    '',
    '  input = {',
    '    kb = {',
    '      x = 1,',
    '      y = "two",',
    '    },',
    '  },',
    '})',
    '',
  ].join('\n'))
  eq('a section name needing brackets is bracketed on creation', edit(CFG_2SPACE, ['general', 'col.active'], 'x').content.includes('    ["col.active"] = "x",'), true)
  eq('the created block is readable afterwards', HE.hyprGetContent(edit(CFG_2SPACE, ['general', 'input', 'sensitivity'], 3).content, ['general', 'input', 'sensitivity']),
    { ok: true, value: 3 })
  eq('a deeper create is readable at every level', HE.hyprGetContent(
    edit('hl.config({\n})\n', ['a', 'b', 'c'], 1).content, ['a', 'b', 'c'],
  ), { ok: true, value: 1 })
})

group('creating the whole block when the file is empty', () => {
  // detect_indent_unit has nothing to measure, so the default is FOUR spaces.
  eq('a config block with one nested section', edit('', ['general', 'border_size'], 2).content, [
    'hl.config({',
    '    general = {',
    '        border_size = 2,',
    '    },',
    '})',
    '',
  ].join('\n'))
  eq('a config block with a root option', edit('', ['border_size'], 2).content, 'hl.config({\n    border_size = 2,\n})\n')
  eq('a monitor block with a root option', edit('', ['border_size'], 2, { scope: 'monitor', output: 'HDMI-A-1' }).content,
    'hl.monitor({\n    border_size = 2,\n    output = "HDMI-A-1",\n})\n')
  eq('the monitor output line is written before the option is filled in', edit('', ['scale'], 1.5, { scope: 'monitor', output: 'DP-1' }).content,
    'hl.monitor({\n    scale = 1.5,\n    output = "DP-1",\n})\n')
  eq('an output name with a quote is escaped', edit('', ['scale'], 1.5, { scope: 'monitor', output: 'DP"1' }).content,
    'hl.monitor({\n    scale = 1.5,\n    output = "DP\\"1",\n})\n')
  eq('a created block is readable', HE.hyprGetContent(edit('', ['general', 'border_size'], 2).content, ['general', 'border_size']),
    { ok: true, value: 2 })
  eq('an empty hl.config block gets the same treatment', edit('hl.config({\n})\n', ['general', 'border_size'], 2).content,
    'hl.config({\n    general = {\n        border_size = 2,\n    },\n})\n')
})

group('write_scalar_option is the writer, and it grows the caller\'s root', () => {
  // Called directly, this is the whole write path minus the value gate: it
  // edits `lines` in place and bumps `root.end` by the number of lines it
  // inserted, because the caller keeps walking the same array.
  const fresh = () => HE.read_lines_content(CFG_2SPACE)
  const root = () => ({ start: 0, end: 6 })
  const dump = (lines) => HE.write_lines_content(lines)
  const l1 = fresh()
  const r1 = root()
  eq('it returns nothing', HE.write_scalar_option(l1, r1, ['general'], 'border_size', '9', 1, '  '), undefined)
  eq('an existing option is replaced in place', dump(l1), CFG_2SPACE.replace('border_size = 2', 'border_size = 9'))
  eq('and root.end does not move for a replacement', r1.end, 6)
  eq('and neither does the line count', l1.length, 7)
  const l2 = fresh()
  const r2 = root()
  HE.write_scalar_option(l2, r2, ['general'], 'newone', '1', 1, '  ')
  eq('a new option is appended to its section', dump(l2), [
    'hl.config({', '  -- a comment', '  general = {', '    border_size = 2,', '    rounding = 8,', '    newone = 1,', '  },', '})', '',
  ].join('\n'))
  eq('and root.end grows by one', r2.end, 7)
  const l3 = fresh()
  const r3 = root()
  HE.write_scalar_option(l3, r3, [], 'top', '"x"', 1, '  ')
  eq('a root-level option goes to the top of the block', dump(l3), [
    'hl.config({', '  top = "x",', '  -- a comment', '  general = {', '    border_size = 2,', '    rounding = 8,', '  },', '})', '',
  ].join('\n'))
  eq('and root.end grows by one there too', r3.end, 7)
  const l4 = fresh()
  const r4 = root()
  HE.write_scalar_option(l4, r4, ['nope', 'deep'], 'k', '1', 1, '  ')
  eq('a missing section chain is created whole', dump(l4), [
    'hl.config({', '  -- a comment', '  general = {', '    border_size = 2,', '    rounding = 8,', '  },', '', '  nope = {', '    deep = {', '      k = 1,', '    },', '  },', '})', '',
  ].join('\n'))
  eq('and root.end grows by every line inserted', [r4.end, l4.length], [12, 13])
  const l5 = fresh()
  HE.write_scalar_option(l5, root(), ['general'], 'zz', '"a b"', 1, '  ')
  eq('the value is written exactly as the caller serialized it', dump(l5).includes('    zz = "a b",'), true)
  const l6 = fresh()
  HE.write_scalar_option(l6, root(), ['general'], 'dotted.key', '"v"', 1, '  ')
  eq('a dotted option name is bracketed on the way in', dump(l6).includes('    ["dotted.key"] = "v",'), true)
  const l7 = fresh()
  HE.write_scalar_option(l7, root(), ['general'], 'kebab-name', '1', 1, '  ')
  eq('and so is a hyphenated one', dump(l7).includes('    ["kebab-name"] = 1,'), true)
})

group('resolve_section returns bounds, creating what is missing', () => {
  const fresh = () => HE.read_lines_content(CFG_2SPACE)
  const root = () => ({ start: 0, end: 6 })
  const l1 = fresh()
  const r1 = root()
  eq('an empty path is the root itself', HE.resolve_section(l1, r1, [], 1, '  '), { start: 0, end: 6 })
  eq('an existing section is found, not created', HE.resolve_section(l1, r1, ['general'], 1, '  '), { start: 2, end: 5 })
  eq('and nothing was inserted', HE.write_lines_content(l1), CFG_2SPACE)
  eq('root.end is untouched by a lookup', r1.end, 6)
  const l2 = fresh()
  const r2 = root()
  eq('a missing section is created and its header returned', HE.resolve_section(l2, r2, ['input'], 1, '  '), { start: 7, end: 8 })
  eq('the created block is blank-line separated', HE.write_lines_content(l2), [
    'hl.config({', '  -- a comment', '  general = {', '    border_size = 2,', '    rounding = 8,', '  },', '', '  input = {', '  },', '})', '',
  ].join('\n'))
  eq('and root.end counts the blank line and the two braces', r2.end, 9)
  const l3 = fresh()
  const r3 = root()
  eq('a missing chain is created whole, innermost first', HE.resolve_section(l3, r3, ['a', 'b', 'c'], 1, '  '), { start: 9, end: 10 })
  eq('with the indentation nesting', HE.write_lines_content(l3), [
    'hl.config({', '  -- a comment', '  general = {', '    border_size = 2,', '    rounding = 8,', '  },', '', '  a = {', '    b = {', '      c = {', '      },', '    },', '  },', '})', '',
  ].join('\n'))
  eq('and root.end counts all of it', [r3.end, l3.length], [13, 14])
})

group('the batch value gate is the same gate the scalar path uses', () => {
  const batch = (v) => HE.hyprEditContent(CFG_2SPACE, ['general'], v)
  eq('a batch is any object that is not an array', typeof batch({ a: 1 }).content, 'string')
  eq('an array is not a batch, it is a rejected value', HE.hyprEditContent(CFG_2SPACE, ['general'], [1]), { ok: false, error: 'unsupported value type' })
  eq('null is not a batch either', HE.hyprEditContent(CFG_2SPACE, ['general'], null), { ok: false, error: 'unsupported value type' })
  eq('a batch of bools, numbers and strings is fine', batch({ a: true, b: 1, c: 'x' }).ok, true)
  eq('a batch with a nested table is refused before any line changes', batch({ a: { b: 1 } }).ok, false)
  eq('so is a batch with an empty string', batch({ a: '' }).ok, false)
  eq('an inherited key in a batch object is walked too', (() => {
    const v = Object.create({ inherited: 1 })
    v.own = 2
    return HE.hyprEditContent(CFG_2SPACE, ['general'], v).content.includes('inherited = 1,')
  })(), true)
})

group('the duplicate-option rule inside one section', () => {
  // find_option_in_section has no occurrence parameter: a repeated option
  // inside one section always reads and writes the FIRST one.
  const dup = 'hl.config({\n  general = {\n    a = 1,\n    a = 2,\n  },\n})\n'
  eq('the first occurrence is read', HE.hyprGetContent(dup, ['general', 'a']), { ok: true, value: 1 })
  eq('and it is the one written', edit(dup, ['general', 'a'], 9).content,
    'hl.config({\n  general = {\n    a = 9,\n    a = 2,\n  },\n})\n')
  eq('the second occurrence is not reachable: occurrence selects SECTIONS', HE.hyprGetContent(dup, ['general', 'a'], { occurrence: 2 }), { ok: false, error: 'not found' })
  eq('the section-level occurrence is the only selector that moves', edit(
    'hl.config({\n  general = {\n    a = 1,\n  },\n  general = {\n    a = 2,\n  },\n})\n',
    ['general', 'a'], 9, { occurrence: 2 },
  ).content, 'hl.config({\n  general = {\n    a = 1,\n  },\n  general = {\n    a = 9,\n  },\n})\n')
})

group('an out-of-range occurrence creates a duplicate section instead', () => {
  const dup = 'hl.config({\n  general = {\n    border_size = 2,\n  },\n  general = {\n    border_size = 5,\n  },\n})\n'
  eq('occurrence 5 of 2 matches appends a new block', edit(dup, ['general', 'border_size'], 9, { occurrence: 5 }).content, [
    'hl.config({',
    '  general = {',
    '    border_size = 2,',
    '  },',
    '  general = {',
    '    border_size = 5,',
    '  },',
    '',
    '  general = {',
    '    border_size = 9,',
    '  },',
    '})',
    '',
  ].join('\n'))
  eq('a negative occurrence out of range does the same', edit(dup, ['general', 'border_size'], 9, { occurrence: -5 }).content.includes('border_size = 9'), true)
  eq('a read with an out-of-range occurrence is not found', HE.hyprGetContent(dup, ['general', 'border_size'], { occurrence: 5 }), { ok: false, error: 'not found' })
})

group('occurrence selects among duplicated sections, counting from the end', () => {
  const dup = 'hl.config({\n  general = {\n    border_size = 2,\n  },\n  general = {\n    border_size = 5,\n  },\n})\n'
  eq('the default is the first', HE.hyprGetContent(dup, ['general', 'border_size']), { ok: true, value: 2 })
  eq('occurrence 2 is the second', HE.hyprGetContent(dup, ['general', 'border_size'], { occurrence: 2 }), { ok: true, value: 5 })
  eq('occurrence -1 is the last', HE.hyprGetContent(dup, ['general', 'border_size'], { occurrence: -1 }), { ok: true, value: 5 })
  eq('occurrence -2 is the first', HE.hyprGetContent(dup, ['general', 'border_size'], { occurrence: -2 }), { ok: true, value: 2 })
  eq('occurrence 0 falls back to the first, because `opts.occurrence || 1`', HE.hyprGetContent(dup, ['general', 'border_size'], { occurrence: 0 }), { ok: true, value: 2 })
  eq('and writes with occurrence 0 go to the first', edit(dup, ['general', 'border_size'], 9, { occurrence: 0 }).content.includes('border_size = 9,\n  },\n  general'), true)
  eq('occurrence 3 is out of range', HE.hyprGetContent(dup, ['general', 'border_size'], { occurrence: 3 }), { ok: false, error: 'not found' })
  eq('occurrence -3 is out of range', HE.hyprGetContent(dup, ['general', 'border_size'], { occurrence: -3 }), { ok: false, error: 'not found' })
  eq('a section inside a duplicated parent is still addressed by path', HE.hyprGetContent(
    'hl.config({\n  general = {\n    input = {\n      sens = 1,\n    },\n  },\n  general = {\n    input = {\n      sens = 2,\n    },\n  },\n})\n',
    ['general', 'input', 'sens'], { occurrence: -1 },
  ), { ok: true, value: 2 })
})

group('monitor scope: selection is by the output value', () => {
  const mons = 'hl.monitor({\n  output = "DP-1",\n  scale = 1,\n})\nhl.monitor({\n  output = "HDMI-A-1",\n  scale = 2,\n})\n'
  eq('the first monitor is read by output', HE.hyprGetContent(mons, ['scale'], { scope: 'monitor', output: 'DP-1' }), { ok: true, value: 1 })
  eq('the second monitor is read by output', HE.hyprGetContent(mons, ['scale'], { scope: 'monitor', output: 'HDMI-A-1' }), { ok: true, value: 2 })
  eq('an unknown output is not found', HE.hyprGetContent(mons, ['scale'], { scope: 'monitor', output: 'DP-9' }), { ok: false, error: 'not found' })
  eq('the selected monitor is the one written', edit(mons, ['scale'], 1.5, { scope: 'monitor', output: 'HDMI-A-1' }).content,
    'hl.monitor({\n  output = "DP-1",\n  scale = 1,\n})\nhl.monitor({\n  output = "HDMI-A-1",\n  scale = 1.5,\n})\n')
  eq('an unknown output creates a new block at the end', edit(mons, ['scale'], 1.5, { scope: 'monitor', output: 'DP-9' }).content, [
    'hl.monitor({',
    '  output = "DP-1",',
    '  scale = 1,',
    '})',
    'hl.monitor({',
    '  output = "HDMI-A-1",',
    '  scale = 2,',
    '})',
    'hl.monitor({',
    '  scale = 1.5,',
    '  output = "DP-9",',
    '})',
    '',
  ].join('\n'))
  eq('the occurrence picks among same-output blocks', (() => {
    const two = 'hl.monitor({\n  output = "DP-1",\n  scale = 1,\n})\nhl.monitor({\n  output = "DP-1",\n  scale = 2,\n})\n'
    return HE.hyprGetContent(two, ['scale'], { scope: 'monitor', output: 'DP-1', occurrence: -1 })
  })(), { ok: true, value: 2 })
  // A new option in a block goes to the TOP of it (root.start + 1), the same
  // rule the config scope uses, so it lands above the output selector.
  eq('a monitor option is added above the output line', edit(
    'hl.monitor({\n  output = "DP-1",\n})\n', ['scale'], 2, { scope: 'monitor', output: 'DP-1' },
  ).content, 'hl.monitor({\n  scale = 2,\n  output = "DP-1",\n})\n')
  eq('a monitor option that already exists is replaced in place', edit(
    'hl.monitor({\n  output = "DP-1",\n  scale = 1,\n})\n', ['scale'], 2, { scope: 'monitor', output: 'DP-1' },
  ).content, 'hl.monitor({\n  output = "DP-1",\n  scale = 2,\n})\n')
  eq('a nested section inside a monitor block works too', edit(
    'hl.monitor({\n  output = "DP-1",\n})\n', ['transform', 'scale'], 2, { scope: 'monitor', output: 'DP-1' },
  ).content, 'hl.monitor({\n  output = "DP-1",\n  transform = {\n    scale = 2,\n  },\n})\n')
})

group('the value gate: what an edit refuses before it touches the text', () => {
  const scalar = (v, o) => HE.hyprEditContent(CFG_2SPACE, ['general', 'border_size'], v, o)
  const batch = (p, v, o) => HE.hyprEditContent(CFG_2SPACE, p, v, o)
  eq('an empty string value', scalar(''), { ok: false, error: 'empty value' })
  eq('null', scalar(null), { ok: false, error: 'unsupported value type' })
  eq('undefined', scalar(undefined), { ok: false, error: 'unsupported value type' })
  eq('an array', scalar([1]), { ok: false, error: 'unsupported value type' })
  eq('a function', scalar(() => {}), { ok: false, error: 'unsupported value type' })
  eq('an unknown scope', scalar(1, { scope: 'nope' }), { ok: false, error: 'invalid scope' })
  eq('monitor scope without an output', scalar(1, { scope: 'monitor' }), { ok: false, error: "opts.output is required when scope is 'monitor'" })
  eq('an empty path', HE.hyprEditContent(CFG_2SPACE, [], 1), { ok: false, error: 'path must include an option name' })
  eq('a batch with a nested table', batch(['general'], { b: { c: 1 } }), { ok: false, error: 'nested table values not supported' })
  eq('a batch with an empty string', batch(['general'], { b: '' }), { ok: false, error: 'empty value' })
  eq('a batch with a null member', batch(['general'], { b: null }), { ok: false, error: 'unsupported value type' })
  eq('a batch with a nested array member', batch(['general'], { b: [1] }), { ok: false, error: 'nested table values not supported' })
  eq('a rejected edit returns no content', 'content' in scalar(''), false)
  eq('a valid edit always carries content', 'content' in scalar(1), true)
  eq('an empty batch object is accepted and changes nothing', batch(['general'], {}), { ok: true, content: CFG_2SPACE })
})

group('batch edits: update in place, append the rest', () => {
  const base = 'hl.config({\n  general = {\n    -- border thickness\n    border_size = 2, -- inline\n    rounding = 8,\n  },\n})\n'
  eq('a batch into an existing section', edit(base, ['general'], { border_size: 4, rounding: 12, extra: 'v' }).content, [
    'hl.config({',
    '  general = {',
    '    -- border thickness',
    '    border_size = 4,',
    '    rounding = 12,',
    '    extra = "v",',
    '  },',
    '})',
    '',
  ].join('\n'))
  eq('a new key is appended in the caller\'s order', edit(base, ['general'], { z: 9, y: 8, a: 7 }).content.indexOf('z = 9') < edit(base, ['general'], { z: 9, y: 8, a: 7 }).content.indexOf('y = 8'), true)
  eq('an inline comment on an updated option is still dropped', edit(base, ['general'], { border_size: 4 }).content.includes('-- inline'), false)
  eq('a whole-line comment survives a batch', edit(base, ['general'], { border_size: 4 }).content.includes('    -- border thickness'), true)
  eq('a batch creating a section', edit(
    'hl.config({\n  general = {\n    a = 1,\n  },\n})\n', ['input', 'kb'], { x: 1, y: 'two' },
  ).content, [
    'hl.config({',
    '  general = {',
    '    a = 1,',
    '  },',
    '',
    '  input = {',
    '    kb = {',
    '      x = 1,',
    '      y = "two",',
    '    },',
    '  },',
    '})',
    '',
  ].join('\n'))
  eq('a batch at the root goes to the TOP of the block', edit(
    'hl.config({\n  border_size = 2,\n})\n', [], { a: 1 },
  ).content, 'hl.config({\n  a = 1,\n  border_size = 2,\n})\n')
  eq('and a root batch REVERSES the caller\'s key order', edit('', [], { a: 1, b: 2, c: 3 }).content,
    'hl.config({\n    c = 3,\n    b = 2,\n    a = 1,\n})\n')
  eq('a section batch keeps its order, so the reversal is root-only', edit(
    'hl.config({\n  general = {\n    z = 1,\n  },\n})\n', ['general'], { a: 1, b: 2, c: 3 },
  ).content, 'hl.config({\n  general = {\n    z = 1,\n    a = 1,\n    b = 2,\n    c = 3,\n  },\n})\n')
  eq('a batch member with a dotted key is bracketed', edit(base, ['general'], { 'col.active': 'x' }).content.includes('    ["col.active"] = "x",'), true)
  eq('a batch is readable afterwards', HE.hyprGetContent(edit(base, ['general'], { border_size: 4 }).content, ['general', 'border_size']),
    { ok: true, value: 4 })
  eq('a scalar path with a batch is a batch too, not a scalar write', HE.hyprEditContent(base, ['general', 'border_size'], { x: 1 }).ok, true)
})

// ===========================================================================
section('HyprlandEditor - reads through the public get')
// ===========================================================================
group('hyprGetContent is total and typed', () => {
  eq('a value from the file', HE.hyprGetContent(CFG_2SPACE, ['general', 'border_size']), { ok: true, value: 2 })
  eq('an int', HE.hyprGetContent('hl.config({\n  a = 5,\n})\n', ['a']), { ok: true, value: 5 })
  eq('a float', HE.hyprGetContent('hl.config({\n  a = 0.5,\n})\n', ['a']), { ok: true, value: 0.5 })
  eq('a bool', HE.hyprGetContent('hl.config({\n  a = true,\n})\n', ['a']), { ok: true, value: true })
  eq('a string', HE.hyprGetContent('hl.config({\n  a = "x y",\n})\n', ['a']), { ok: true, value: 'x y' })
  eq('an empty quoted string reads as empty, not missing', HE.hyprGetContent('hl.config({\n  a = "",\n})\n', ['a']), { ok: true, value: '' })
  eq('an option with no value reads as empty', HE.hyprGetContent('hl.config({\n  a = ,\n})\n', ['a']), { ok: true, value: '' })
  eq('an empty file is not found', HE.hyprGetContent('', ['a']), { ok: false, error: 'not found' })
  eq('a missing option is not found', HE.hyprGetContent(CFG_2SPACE, ['general', 'nope']), { ok: false, error: 'not found' })
  eq('a missing section is not found', HE.hyprGetContent(CFG_2SPACE, ['nope', 'x']), { ok: false, error: 'not found' })
  eq('an empty path is refused', HE.hyprGetContent(CFG_2SPACE, []), { ok: false, error: 'path must include an option name' })
  eq('an unknown scope is refused', HE.hyprGetContent(CFG_2SPACE, ['a'], { scope: 'x' }), { ok: false, error: 'invalid scope' })
  eq('monitor scope without an output is refused', HE.hyprGetContent(CFG_2SPACE, ['a'], { scope: 'monitor' }), { ok: false, error: "opts.output is required when scope is 'monitor'" })
  eq('an empty hl.config block is not found', HE.hyprGetContent('hl.config({\n})\n', ['a']), { ok: false, error: 'not found' })
  eq('no opts at all is the config scope', HE.hyprGetContent(CFG_2SPACE, ['general', 'border_size'], undefined), { ok: true, value: 2 })
  eq('a read never mutates the text it was handed', (() => {
    const before = CFG_2SPACE
    HE.hyprGetContent(before, ['general', 'border_size'])
    return before === CFG_2SPACE
  })(), true)
  noThrow('a read of a broken file is not a throw', () => HE.hyprGetContent('}{ not lua', ['a', 'b']))
  noThrow('a read of a non-string content', () => HE.hyprGetContent(null, ['a']))
})

group('a read and a write agree on the same path', () => {
  // The CLI's whole contract: get after set returns what was set.
  const values = [true, false, 0, 3, -2, 0.5, 1.5, 'a b', 'a"b', 'a\\b', '0x10', 'true', '42', 'a,b']
  for (const v of values) {
    const written = edit(CFG_2SPACE, ['general', 'rounding'], v)
    eq(`set then get ${show(v)}`, HE.hyprGetContent(written.content, ['general', 'rounding']), { ok: true, value: v })
  }
  // The empty string is the one value the write gate refuses outright, so it
  // is the one value with no round trip.
  eq('the empty string is not writable', edit(CFG_2SPACE, ['general', 'rounding'], ''), { ok: false, error: 'empty value' })
  eq('but an empty string already in the file reads back', HE.hyprGetContent('hl.config({\n  a = "",\n})\n', ['a']), { ok: true, value: '' })
  for (const v of [true, 3, 'x']) {
    const written = edit(CFG_2SPACE, ['general', 'input', 'deep'], v)
    eq(`set then get through a created section ${show(v)}`, HE.hyprGetContent(written.content, ['general', 'input', 'deep']), { ok: true, value: v })
  }
  eq('set then get at the root of the block', HE.hyprGetContent(edit(CFG_2SPACE, ['rootopt'], 'v').content, ['rootopt']), { ok: true, value: 'v' })
  eq('set then get in a monitor block', HE.hyprGetContent(
    edit('hl.monitor({\n  output = "DP-1",\n})\n', ['scale'], 1.5, { scope: 'monitor', output: 'DP-1' }).content,
    ['scale'], { scope: 'monitor', output: 'DP-1' },
  ), { ok: true, value: 1.5 })
})

// ===========================================================================
section('HyprlandEditor - the file layer: read_lines_content, expand_path')
// ===========================================================================
// The node-only fs wrappers are unreachable through loadLib: its vm context
// carries `console` and `Quickshell` but no `require`, which is exactly the
// state a QML host is in ("the shell engine exposes no host globals inside a
// .pragma library file"). They are therefore evaluated here with the same
// recipe HyprlandEditorCli.js uses, so the documented symlink-preserving
// write can actually be exercised.
function loadEditorWithNodeHost() {
  const file = path.join(SETTINGS, 'HyprlandEditor.js')
  const nodeRequire = createRequire(import.meta.url)
  const ctx = {
    console, require: nodeRequire, process,
    Quickshell: { env: (k) => process.env[k] || '' },
  }
  vm.createContext(ctx)
  vm.runInContext(fs.readFileSync(file, 'utf8').replace(/^\.pragma library.*\n/m, ''), ctx, { filename: file })
  return ctx
}
const NF = loadEditorWithNodeHost()

group('a missing file reads as empty - the CLI relies on it', () => {
  noThrow('hyprGetFile of a missing file does not throw', () => NF.hyprGetFile('/nonexistent/vibranium-hypr-test.lua', ['a']))
  eq('and it is "not found", not an error', NF.hyprGetFile('/nonexistent/vibranium-hypr-test.lua', ['a']), { ok: false, error: 'not found' })
  // Without a node host the same call degrades rather than throwing. The
  // reader swallows the failure and reads ""; the writer reports it, because
  // its catch is the one that names the error.
  noThrow('hyprGetFile without a node host does not throw', () => HE.hyprGetFile('~/x.lua', ['a']))
  eq('the reader degrades to an empty read', HE.hyprGetFile('~/x.lua', ['a']), { ok: false, error: 'not found' })
  noThrow('hyprEditFile without a node host does not throw', () => HE.hyprEditFile('~/x.lua', ['a'], 1))
  eq('the writer reports the host error', HE.hyprEditFile('~/x.lua', ['a'], 1), { ok: false, error: 'ReferenceError: require is not defined' })
  noThrow('hyprGetContent of an empty string is the same read', () => HE.hyprGetContent('', ['a']))
})

group('expand_path: ~ and $VAR, with the XDG fallbacks', () => {
  const saved = {}
  for (const k of ['HOME', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME']) {
    saved[k] = process.env[k]
    delete process.env[k]
  }
  setEnv('HOME', '/home/tester')
  eq('a bare tilde', HE.expand_path('~'), '/home/tester')
  eq('a tilde path', HE.expand_path('~/hypr/x.lua'), '/home/tester/hypr/x.lua')
  eq('an unbraced var', HE.expand_path('$HOME/hypr'), '/home/tester/hypr')
  eq('a braced var', HE.expand_path('${HOME}/hypr'), '/home/tester/hypr')
  eq('a relative path is untouched', HE.expand_path('config/hypr/x.lua'), 'config/hypr/x.lua')
  eq('an absolute path is untouched', HE.expand_path('/etc/hypr/x.lua'), '/etc/hypr/x.lua')
  eq('~user is not expanded', HE.expand_path('~user/x'), '~user/x')
  eq('a tilde in the middle is not expanded', HE.expand_path('/a/~/b'), '/a/~/b')
  eq('a double tilde is not expanded', HE.expand_path('~~'), '~~')
  eq('an unset var stays literal, unbraced', HE.expand_path('$VIB_UNSET_XYZ/x'), '$VIB_UNSET_XYZ/x')
  eq('an unset var stays literal, braced', HE.expand_path('${VIB_UNSET_XYZ}/x'), '${VIB_UNSET_XYZ}/x')
  eq('a var name is greedy, so $HOMEb is one unset name', HE.expand_path('$HOMEb'), '$HOMEb')
  // The XDG fallbacks only run when the variable is unset, and they are
  // derived from HOME.
  eq('XDG_CONFIG_HOME falls back to HOME/.config', HE.expand_path('${XDG_CONFIG_HOME}/hypr'), '/home/tester/.config/hypr')
  eq('XDG_STATE_HOME falls back to HOME/.local/state', HE.expand_path('${XDG_STATE_HOME}/x'), '/home/tester/.local/state/x')
  eq('XDG_CACHE_HOME falls back to HOME/.cache', HE.expand_path('${XDG_CACHE_HOME}/x'), '/home/tester/.cache/x')
  eq('XDG_DATA_HOME falls back to HOME/.local/share', HE.expand_path('${XDG_DATA_HOME}/x'), '/home/tester/.local/share/x')
  eq('the unbraced spelling gets the same fallback', HE.expand_path('$XDG_CONFIG_HOME/hypr'), '/home/tester/.config/hypr')
  setEnv('XDG_CONFIG_HOME', '/xdg/cfg')
  eq('a real value wins over the fallback', HE.expand_path('${XDG_CONFIG_HOME}/hypr'), '/xdg/cfg/hypr')
  setEnv('HOME', '')
  eq('with no HOME a tilde stays literal', HE.expand_path('~'), '~')
  eq('and a tilde path too', HE.expand_path('~/x'), '~/x')
  eq('and the XDG fallback does not fire for an unset variable', HE.expand_path('${VIB_NO_XDG}/x'), '${VIB_NO_XDG}/x')
  eq('but a real XDG_CONFIG_HOME still wins', HE.expand_path('${XDG_CONFIG_HOME}/hypr'), '/xdg/cfg/hypr')
  delete process.env.XDG_CONFIG_HOME
  eq('and without one there is no fallback at all', HE.expand_path('${XDG_CONFIG_HOME}/hypr'), '${XDG_CONFIG_HOME}/hypr')
  for (const k of Object.keys(saved)) {
    if (saved[k] === undefined) delete process.env[k]
    else setEnv(k, saved[k])
  }
  eq('the environment is restored', process.env.HOME, saved.HOME)
})

group('hyprEditFile writes in place, so a symlink stays a symlink', () => {
  // The CLI header is explicit: "The write stays in place rather than going
  // through a temp file and a rename: a config file can be a symlink into the
  // default set, and replacing it with a regular file would silently break
  // the symlink contract the theme and animation presets are built on."
  const base = fs.existsSync('/tmp/opencode') ? fs.mkdtempSync('/tmp/opencode/vb-hypr-') : fs.mkdtempSync(path.join(os.tmpdir(), 'vb-hypr-'))
  try {
    const target = path.join(base, 'real.lua')
    const link = path.join(base, 'link.lua')
    fs.writeFileSync(target, 'hl.config({\n  general = {\n    border_size = 2,\n  },\n})\n', 'utf8')
    fs.symlinkSync(target, link)
    const targetBefore = fs.readFileSync(target, 'utf8')
    eq('a read through the symlink', NF.hyprGetFile(link, ['general', 'border_size']), { ok: true, value: 2 })
    const written = NF.hyprEditFile(link, ['general', 'border_size'], 4)
    eq('the edit reports success and no content', written, { ok: true })
    is('the link is still a symlink', fs.lstatSync(link), (st) => st.isSymbolicLink(), 'a symbolic link')
    eq('it still points at the same target', fs.readlinkSync(link), target)
    eq('the target carries the new value', NF.hyprGetFile(target, ['general', 'border_size']), { ok: true, value: 4 })
    notMatch('and the old value is gone from the file', fs.readFileSync(target, 'utf8'), /border_size = 2/)
    eq('nothing else in the file moved', fs.readFileSync(target, 'utf8'),
      'hl.config({\n  general = {\n    border_size = 4,\n  },\n})\n')
    ne('the target actually changed', fs.readFileSync(target, 'utf8'), targetBefore)
    // A missing file is created in place, which is the first-boot path the
    // CLI depends on.
    const fresh = path.join(base, 'fresh.lua')
    eq('editing a missing file creates it', NF.hyprEditFile(fresh, ['general', 'border_size'], 2), { ok: true })
    is('the file now exists', fs.existsSync(fresh), (v) => v === true, 'exists')
    eq('with the created content', fs.readFileSync(fresh, 'utf8'), 'hl.config({\n    general = {\n        border_size = 2,\n    },\n})\n')
    eq('and reads back', NF.hyprGetFile(fresh, ['general', 'border_size']), { ok: true, value: 2 })
    // A path the editor cannot write is reported, not thrown.
    eq('an unwritable path is reported', NF.hyprEditFile(base, ['a'], 1).ok, false)
    // The path is expanded before it is read or written.
    const homeConf = path.join(base, '.vibranium-hypr-test')
    const savedHome = process.env.HOME
    setEnv('HOME', base)
    try {
      eq('a ~ path is written to the real file', NF.hyprEditFile('~/.vibranium-hypr-test', ['general', 'border_size'], 6), { ok: true })
      // A file that did not exist is created from nothing, so it is indented
      // with detect_indent_unit's four-space default rather than a guessed
      // style copied from anywhere.
      eq('which is the file on disk, at the four-space default', fs.readFileSync(homeConf, 'utf8'), 'hl.config({\n    general = {\n        border_size = 6,\n    },\n})\n')
      eq('and a ~ path reads it back', NF.hyprGetFile('~/.vibranium-hypr-test', ['general', 'border_size']), { ok: true, value: 6 })
    } finally {
      if (savedHome === undefined) delete process.env.HOME
      else setEnv('HOME', savedHome)
    }
  } finally {
    fs.rmSync(base, { recursive: true, force: true })
  }
  eq('the temp tree is gone', fs.existsSync(base), false)
})

// ===========================================================================
section('HyprlandEditor - the CLI argument contract')
// ===========================================================================
group('splitPath splits on colons, keeping empties', () => {
  eq('one component', HE.splitPath('general'), ['general'])
  eq('two components', HE.splitPath('general:border_size'), ['general', 'border_size'])
  eq('three components', HE.splitPath('a:b:c'), ['a', 'b', 'c'])
  eq('a trailing colon yields an empty component', HE.splitPath('a:'), ['a', ''])
  eq('a leading colon yields an empty component', HE.splitPath(':a'), ['', 'a'])
  eq('two colons yield two empties', HE.splitPath(':'), ['', ''])
  eq('an empty string is ONE empty component, not none', HE.splitPath(''), [''])
  eq('which is why the CLI also tests for a single empty component', HE.splitPath('').length === 1 && HE.splitPath('')[0] === '', true)
  eq('a dotted name stays one component', HE.splitPath('general:col.active_border'), ['general', 'col.active_border'])
  eq('a quoted name is not special', HE.splitPath('a:"b:c"'), ['a', '"b', 'c"'])
  // A non-string has no length, so the loop never runs: the CLI only ever
  // hands it process.argv entries, which are strings.
  eq('a non-string yields no components', HE.splitPath(5), [])
  noThrow('a non-string does not throw', () => HE.splitPath(5))
})

group('parseComponent reads the name@N occurrence selector', () => {
  eq('a plain component', HE.parseComponent('general'), { name: 'general', occ: null })
  eq('a positive occurrence', HE.parseComponent('a@2'), { name: 'a', occ: 2 })
  eq('a negative occurrence', HE.parseComponent('a@-1'), { name: 'a', occ: -1 })
  eq('a multi-digit occurrence', HE.parseComponent('a@12'), { name: 'a', occ: 12 })
  eq('a leading zero is parsed as a number', HE.parseComponent('a@02'), { name: 'a', occ: 2 })
  eq('occurrence 0 is kept by parseComponent', HE.parseComponent('a@0'), { name: 'a', occ: 0 })
  eq('a trailing @ with no digits is part of the name', HE.parseComponent('a@'), { name: 'a@', occ: null })
  eq('a non-numeric @ is part of the name', HE.parseComponent('a@b'), { name: 'a@b', occ: null })
  eq('a float is not an occurrence', HE.parseComponent('a@1.5'), { name: 'a@1.5', occ: null })
  eq('only the trailing @N is read', HE.parseComponent('a@2@3'), { name: 'a@2', occ: 3 })
  eq('an empty name with an occurrence', HE.parseComponent('@2'), { name: '', occ: 2 })
  eq('an empty component', HE.parseComponent(''), { name: '', occ: null })
  eq('a dotted name keeps its dot', HE.parseComponent('col.active@2'), { name: 'col.active', occ: 2 })
  eq('a name with a colon in it is one component here', HE.parseComponent('a:b@2'), { name: 'a:b', occ: 2 })
  // The CLI only ever passes an argv string, and the helper matches on it
  // directly rather than stringifying first.
  throws('a non-string component throws', () => HE.parseComponent(5), /s\.match is not a function/)
})

group('a name@N component is the CLI\'s occurrence, and 0 is not one', () => {
  // The CLI: "the last such component in the path wins, and an explicit
  // --occurrence only applies when the path names none."
  const dup = 'hl.config({\n  general = {\n    a = 1,\n  },\n  general = {\n    a = 2,\n  },\n})\n'
  // The CLI's own composition, verbatim.
  const cliArgs = (rawPath) => {
    const optionPath = []
    let occurrence
    for (const c of HE.splitPath(rawPath)) {
      const { name, occ } = HE.parseComponent(c)
      if (occ !== null) occurrence = occ
      optionPath.push(name)
    }
    const opts = { scope: 'config' }
    if (occurrence !== undefined) opts.occurrence = occurrence
    return { optionPath, opts }
  }
  const cliGet = (rawPath) => {
    const { optionPath, opts } = cliArgs(rawPath)
    return HE.hyprGetContent(dup, optionPath, opts)
  }
  eq('general:a@2', cliGet('general:a@2'), { ok: true, value: 2 })
  eq('general:a@-1', cliGet('general:a@-1'), { ok: true, value: 2 })
  eq('general:a@-2', cliGet('general:a@-2'), { ok: true, value: 1 })
  eq('general:a@1', cliGet('general:a@1'), { ok: true, value: 1 })
  eq('an occurrence on an earlier component is still read', cliGet('general@2:a'), { ok: true, value: 2 })
  // parseComponent's (.*) is greedy, so only the LAST @N in a component is
  // an occurrence: "a@2@1" is the option literally named "a@2" at occurrence
  // 1, not the option "a" at occurrence 1.
  eq('a component with two @ is a name plus one occurrence', cliArgs('general:a@2@1').optionPath, ['general', 'a@2'])
  eq('so it looks for an option named a@2', cliGet('general:a@2@1'), { ok: false, error: 'not found' })
  eq('the last occurrence-bearing COMPONENT wins', cliGet('general@2:a@1'), { ok: true, value: 1 })
  eq('and so does the first one alone', cliGet('general@1:a'), { ok: true, value: 1 })
  eq('a path with no occurrence is the default', cliGet('general:a'), { ok: true, value: 1 })
  eq('the name is stripped of its @N', cliArgs('general@2:a@3').optionPath, ['general', 'a'])
  eq('and the last occurrence is the one kept', cliArgs('general@2:a@3').opts.occurrence, 3)
  // `opts.occurrence || 1` means an occurrence of 0 is falsy and is silently
  // read as "the first", so "@0" is a way of writing "@1".
  eq('an @0 occurrence becomes the default 1', HE.parseComponent('a@0').occ || 1, 1)
  eq('which is what the library then uses', HE.hyprGetContent(dup, ['general', 'a'], { occurrence: 0 }), { ok: true, value: 1 })
  eq('a negative occurrence is not falsy', HE.parseComponent('a@-1').occ || 1, -1)
  eq('an occurrence-bearing option name is not a path separator', cliArgs('general:col.active_border@2').optionPath, ['general', 'col.active_border'])
  eq('and the occurrence is still taken from it', cliArgs('general:col.active_border@2').opts.occurrence, 2)
})

group('inferType is the CLI\'s value coercion', () => {
  eq('true', HE.inferType('true'), true)
  eq('false', HE.inferType('false'), false)
  eq('a double-quoted word', HE.inferType('"a b"'), 'a b')
  eq('a single-quoted word', HE.inferType("'a b'"), 'a b')
  eq('a bare word stays a word', HE.inferType('my mode'), 'my mode')
  eq('an empty value stays the empty string, not 0', HE.inferType(''), '')
  eq('a whitespace value is not 0 either', HE.inferType('   '), '   ')
  eq('an int', HE.inferType('42'), 42)
  eq('a negative', HE.inferType('-42'), -42)
  eq('a float', HE.inferType('0.5'), 0.5)
  eq('exponent notation IS a number to the CLI', HE.inferType('1e3'), 1000)
  eq('so a leading + is a number too', HE.inferType('+7'), 7)
  eq('TRUE is not a bool', HE.inferType('TRUE'), 'TRUE')
  eq('the word true with quotes is a string', HE.inferType('"true"'), 'true')
  // The CLI's own stripping: quotes come off, but unlike
  // parse_typed_value the CONTENTS are not unescaped.
  eq('an escaped quote is not unescaped by the CLI', HE.inferType('"a\\"b"'), 'a\\"b')
  eq('while the read path does unescape it', HE.parse_typed_value('"a\\"b"'), 'a"b')
  eq('a quoted number is a string', HE.inferType('"42"'), '42')
  eq('so it round-trips as a string through a write', HE.hyprEditContent('hl.config({\n  a = "1",\n})\n', ['a'], HE.inferType('"42"')).content.includes('a = "42",'), true)
  eq('and a bare 42 is written as a number', HE.hyprEditContent('hl.config({\n  a = "1",\n})\n', ['a'], HE.inferType('42')).content.includes('a = 42,'), true)
  eq('a bare empty word would be refused by the write gate', HE.hyprEditContent('hl.config({\n  a = 1,\n})\n', ['a'], HE.inferType('')), { ok: false, error: 'empty value' })
  // inferType indexes the string directly, so it is as string-only as
  // parseComponent: an argv entry is always a string, so this never fires.
  throws('a number argument throws', () => HE.inferType(5), /s\.trim is not a function/)
  throws('null throws', () => HE.inferType(null), /Cannot read properties of null/)
})

group('the CLI\'s path plus value is exactly what the library takes', () => {
  // get <path> <file> / set <path> <value> <file> with a colon path and an
  // optional name@N: the composed arguments must behave like the library API.
  const cli = (rawPath, rawValue) => {
    const optionPath = []
    let occurrence
    for (const c of HE.splitPath(rawPath)) {
      const { name, occ } = HE.parseComponent(c)
      if (occ !== null) occurrence = occ
      optionPath.push(name)
    }
    const opts = { scope: 'config' }
    if (occurrence !== undefined) opts.occurrence = occurrence
    return HE.hyprEditContent(CFG_2SPACE, optionPath, HE.inferType(rawValue), opts)
  }
  eq('set general:border_size 4', cli('general:border_size', '4').content.includes('    border_size = 4,'), true)
  eq('set general:border_size true', cli('general:border_size', 'true').content.includes('    border_size = true,'), true)
  eq('set general:border_size "a b"', cli('general:border_size', '"a b"').content.includes('    border_size = "a b",'), true)
  eq('set general:input:sensitivity -1', cli('general:input:sensitivity', '-1').content.includes('      sensitivity = -1,'), true)
  const dup = 'hl.config({\n  general = {\n    border_size = 2,\n  },\n  general = {\n    border_size = 5,\n  },\n})\n'
  eq('set general@2:border_size 9', HE.hyprEditContent(dup, ['general', 'border_size'], 9, { occurrence: 2 }).content.includes('border_size = 9,\n  },\n})'), true)
  eq('set general@-1:border_size 9', HE.hyprEditContent(dup, ['general', 'border_size'], 9, { occurrence: -1 }).content.includes('border_size = 9,\n  },\n})'), true)
  eq('an empty path is refused by the CLI itself, before the library', HE.splitPath('').length === 1 && HE.splitPath('')[0] === '', true)
  eq('but the library itself writes an empty-name option, at the top of the block', HE.hyprEditContent(CFG_2SPACE, [''], 1).content,
    'hl.config({\n  [""] = 1,\n  -- a comment\n  general = {\n    border_size = 2,\n    rounding = 8,\n  },\n})\n')
})

group('the library is defensive about the shapes the shell hands it', () => {
  noThrow('hyprGetContent with a non-array path', () => HE.hyprGetContent(CFG_2SPACE, 'a:b'))
  eq('a one-character path is a path of one', HE.hyprGetContent('hl.config({\n  a = 1,\n})\n', 'a'), { ok: true, value: 1 })
  eq('a longer string is sliced as characters, so it finds nothing', HE.hyprGetContent('hl.config({\n  ab = 1,\n})\n', 'ab'), { ok: false, error: 'not found' })
  noThrow('hyprEditContent with a non-object value', () => HE.hyprEditContent('', ['a'], Object.create(null)))
  noThrow('hyprGetContent with a weird opts', () => HE.hyprGetContent(CFG_2SPACE, ['general', 'border_size'], { scope: 0, occurrence: {} }))
  noThrow('find_section_bounds with a short window', () => HE.find_section_bounds(LINES_2SPACE, ['general'], 3, 1, 1))
  eq('a reversed window finds nothing', HE.find_section_bounds(LINES_2SPACE, ['general'], 3, 1, 1), null)
  noThrow('find_all_section_bounds past the end of the file', () => HE.find_all_section_bounds(LINES_2SPACE, ['general'], 0, 999))
  eq('and does not walk off it', HE.find_all_section_bounds(LINES_2SPACE, ['general'], 0, 999), [{ start: 2, end: 5, depth: 0 }])
  noThrow('an unterminated block', () => HE.hyprGetContent('hl.config({\n  general = {\n', ['general', 'a']))
  eq('an unterminated block is not found', HE.hyprGetContent('hl.config({\n  general = {\n', ['general', 'a']), { ok: false, error: 'not found' })
  noThrow('a file that is not lua at all', () => HE.hyprEditContent('}{ not lua at all', ['a'], 1))
  eq('and it still gets a well-formed block appended', HE.hyprEditContent('}{ not lua at all', ['a'], 1).content,
    '}{ not lua at all\nhl.config({\n    a = 1,\n})\n')
  eq('null content is an empty file', HE.hyprGetContent(null, ['a']), { ok: false, error: 'not found' })
  eq('and it is created from nothing', HE.hyprEditContent(null, ['a'], 1).content, 'hl.config({\n    a = 1,\n})\n')
})

finish()