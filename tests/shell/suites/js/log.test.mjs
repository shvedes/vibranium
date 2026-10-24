#!/usr/bin/env node
// Suite: common/log/ - the level vocabulary, the spec grammar, and the scope
// derivation.
//
// Three pure `.pragma library` files with no Qt in them, so a plain node
// harness drives all of them:
//
//   LogScope   a path -> a scope, plus the subtree match that resolves overlap
//   LogSpec    levels, terms, precedence, and the printed form of a message
//   LogCore    the shared configuration state and the gate over it
//
// LogCore is the one with state, and it is state on purpose: a library
// evaluated once per engine is what lets `Log.qml` and a dozen feature
// scripts share one resolved configuration. So this suite is also the place
// that pins the reconfigure contract - a second `configure` replaces the
// configuration rather than merging into it, and clears the per-scope memo.
//
// The two rules everything else hangs off are asserted as rules rather than
// as examples, because they are the two a later change is most likely to
// break silently:
//
//   levels are a SET, not a threshold - `debug` does not imply `info`;
//   a scope is DERIVED from the call site's file, so no call site names it.
//
// The last section pins this library's own export list, so a function added
// without a case here is a red suite rather than an untested one.

import path from 'node:path'
import fs from 'node:fs'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, is, contains, noThrow, finish,
} from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const SRC = (name) => path.join(SHELL, 'common/log', name)
const Scope = loadLib(SRC('LogScope.js'))
const Spec = loadLib(SRC('LogSpec.js'))
const Core = loadLib(SRC('LogCore.js'))

// A capture of what the console object would have printed, so a gate that
// lets a record through and one that does not are told apart by observation
// rather than by reading the rule back. Restored on the way out of every group
// that touches it.
const realConsole = { log: console.log, debug: console.debug, info: console.info, warn: console.warn, error: console.error }
let printed = []
function captureConsole(fn) {
  printed = []
  for (const level of Object.keys(realConsole)) {
    console[level] = (...args) => { printed.push({ level, text: args.join(' ') }) }
  }
  try {
    fn()
  } finally {
    for (const level of Object.keys(realConsole)) console[level] = realConsole[level]
  }
  return printed
}
const printedAt = (level) => printed.filter((p) => p.level === level).map((p) => p.text)
// The startup announcement a live spec prints is about the configuration, not
// a record, so assertions about what a call emitted read this rather than
// `printedAt`. The announcement is asserted on its own further down.
const emitted = (level) => printedAt(level).filter((t) => !t.startsWith('log: '))
const kinds = (set) => Object.keys(set || {}).filter((k) => set[k] === true).sort()

// A stack shaped exactly like the one Quickshell's V8 produces, so the frame
// index under test is the real one rather than a convenient fiction. Measured
// off this build: `name@qs:@/qs/<path>:<line>`, one frame per line, frame 0
// being the function that constructed the Error.
const frame = (fn, file, line) => `${fn}@qs:@/qs/${file}:${line}`
const stackOf = (...frames) => frames.join('\n')

suite('common/log', 'LogScope, LogSpec, LogCore')

// ---------------------------------------------------------------------------
section('LogScope.scopeFromPath - the derivation')
// ---------------------------------------------------------------------------
group('the layer directory is stripped, and so is every other layer', () => {
  // The documented spellings, first, because they are the contract.
  eq('features/clipboard/Clipboard.qml', Scope.scopeFromPath('features/clipboard/Clipboard.qml'), 'clipboard')
  eq('features/bar/modules/ArchUpdates/ArchUpdates.qml',
    Scope.scopeFromPath('features/bar/modules/ArchUpdates/ArchUpdates.qml'), 'bar.archUpdates')
  eq('common/text/StringUtils.js', Scope.scopeFromPath('common/text/StringUtils.js'), 'text.stringUtils')
  eq('services/media/MediaState.qml', Scope.scopeFromPath('services/media/MediaState.qml'), 'media.mediaState')
  eq('boot/Boot.qml', Scope.scopeFromPath('boot/Boot.qml'), 'boot')
})
group('the Quickshell resource prefix in front of the path is never parsed', () => {
  // Anchoring on the last layer segment is what makes this true, and it is
  // why no part of this library knows what the prefix is.
  eq('the /qs form', Scope.scopeFromPath('/qs/features/clipboard/Clipboard.qml'), 'clipboard')
  eq('with a scheme on the front', Scope.scopeFromPath('file:///home/u/shell/features/osd/OSDView.qml'), 'osd.osdView')
  eq('a resource form', Scope.scopeFromPath('qrc:/x/common/bus/Registry.qml'), 'bus.registry')
})
group('a file stem repeats its directory name only once', () => {
  eq('Clipboard.qml in clipboard/', Scope.scopeFromPath('features/clipboard/Clipboard.qml'), 'clipboard')
  eq('case-insensitively, so Wallpaper.qml in wallpaper/', Scope.scopeFromPath('features/wallpaper/Wallpaper.qml'), 'wallpaper')
  eq('Bar.qml in bar/ collapses too', Scope.scopeFromPath('features/bar/Bar.qml'), 'bar')
  eq('a different stem keeps both', Scope.scopeFromPath('features/clipboard/ClipboardPanel.qml'), 'clipboard.clipboardPanel')
  eq('an island under a module keeps all three', Scope.scopeFromPath('features/bar/modules/ArchUpdates/ArchUpdatesIsland.qml'), 'bar.archUpdates.archUpdatesIsland')
})
group('modules is dropped and every other directory is kept', () => {
  // A bar module is grouped under the bar for layout reasons, so it is one
  // owner and not two levels deep.
  eq('modules is skipped', Scope.scopeFromPath('features/bar/modules/ColorPicker/ColorPicker.qml'), 'bar.colorPicker')
  eq('a picker keeps its parent directory', Scope.scopeFromPath('features/pickers/emoji/EmojiPicker.qml'), 'pickers.emoji.emojiPicker')
})
group('the innermost layer segment wins', () => {
  // A nested directory may legitimately repeat a layer name, and the file
  // belongs to the inner one. Anchoring on the LAST match rather than the
  // first is what makes this true.
  eq('common/ nested inside features/', Scope.scopeFromPath('features/foo/common/Thing.qml'), 'thing')
  eq('features/ nested inside common/', Scope.scopeFromPath('common/features/Widget.qml'), 'widget')
  eq('and the outer reading is not what comes back',
    Scope.scopeFromPath('common/features/Widget.qml') === 'features.widget', false)
})
group('the first letter of a segment is lowered, and a capital run is one acronym', () => {
  // Lowering only the first character of a run would produce `oSDView`, which
  // is a spelling nobody writes.
  eq('PascalCase', Scope.scopeFromPath('features/osd/OSDView.qml'), 'osd.osdView')
  eq('one capital is a word starting capitalised', Scope.scopeFromPath('features/bar/Bar.qml'), 'bar')
  eq('a run with nothing after it is one word', Scope.scopeFromPath('features/bar/IPC.qml'), 'bar.ipc')
  eq('two words in a row', Scope.scopeFromPath('features/bar/modules/ColorPicker/ColorPicker.qml'), 'bar.colorPicker')
  eq('already lower is untouched', Scope.scopeFromPath('features/launcher/AppLauncher.qml'), 'launcher.appLauncher')
})
group('a file with no layer above it is its own scope', () => {
  eq('shell.qml at the root', Scope.scopeFromPath('/qs/shell.qml'), 'shell')
  eq('no directory at all', Scope.scopeFromPath('Clipboard.qml'), 'clipboard')
})
group('lowerFirst is the rule, stated on its own', () => {
  // Lowering only the first character of a capital run produces `oSDView`,
  // which is a spelling nobody writes and not the `osdView` the bar's own
  // module ids use.
  eq('a word that starts capitalised', Scope.lowerFirst('ArchUpdates'), 'archUpdates')
  eq('an acronym followed by a word', Scope.lowerFirst('OSDView'), 'osdView')
  eq('an acronym and a word', Scope.lowerFirst('IPCView'), 'ipcView')
  eq('a run with nothing after it', Scope.lowerFirst('IPC'), 'ipc')
  eq('one capital', Scope.lowerFirst('C'), 'c')
  eq('already lower', Scope.lowerFirst('clipboard'), 'clipboard')
  eq('a leading digit is left alone', Scope.lowerFirst('3dTool'), '3dTool')
  eq('the empty string', Scope.lowerFirst(''), '')
})
group('stripLine drops the line number, with or without a function name', () => {
  eq('with one', Scope.stripLine('probe@qs:@/qs/features/bar/Bar.qml:12'), 'probe@qs:@/qs/features/bar/Bar.qml')
  eq('the trailing line only', Scope.stripLine('/qs/a/B.qml:3'), '/qs/a/B.qml')
  eq('with no line at all', Scope.stripLine('/qs/a/B.qml'), '/qs/a/B.qml')
  eq('a suffix that is not a line number', Scope.stripLine('/qs/a/B.qml:x'), '/qs/a/B.qml:x')
})
group('matchingChain is every covering key, least specific first', () => {
  // `mostSpecificMatch` answers "which one decides", which is right while a key
  // PINS a value. Once a key ADDS to what it inherits, every covering key
  // contributes and the order they apply in is part of the answer - so the two
  // functions have to agree about what covers a scope.
  const map = { bar: 1, 'bar.archUpdates': 2, clipboard: 3 }
  eq('the whole covering chain', Scope.matchingChain(map, 'bar.archUpdates'), ['bar', 'bar.archUpdates'])
  eq('ordered least specific first, by length', Scope.matchingChain(map, 'bar.battery'), ['bar'])
  eq('a scope no key covers', Scope.matchingChain(map, 'wallpaper'), [])
  eq('an exact key is its own chain', Scope.matchingChain(map, 'clipboard'), ['clipboard'])
  eq('the same specificity comparison mostSpecificMatch uses',
    Scope.matchingChain(map, 'bar.archUpdates').slice(-1)[0],
    'bar.archUpdates')
  eq('a non-map', [Scope.matchingChain(null, 'bar'), Scope.matchingChain(undefined, 'bar')], [[], []])
  eq('an empty map', Scope.matchingChain({}, 'bar'), [])
  eq('and it does not stop at a segment boundary the matcher rejects',
    Scope.matchingChain(map, 'barx'), [])
})
group('scopeFromFrame is the url half of scopeFromStack', () => {
  eq('name@url', Scope.scopeFromFrame('probe@qs:@/qs/features/osd/OSDView.qml:12'), 'osd.osdView')
  eq('a bare url with no name', Scope.scopeFromFrame('@qs:@/qs/features/osd/OSDView.qml:12'), 'osd.osdView')
  eq('a binding frame', Scope.scopeFromFrame('expression for text@qs:@/qs/features/osd/OSDView.qml:12'), 'osd.osdView')
  eq('an anonymous frame', Scope.scopeFromFrame('<anonymous>@qs:@/qs/features/bar/Bar.qml:1'), 'bar')
  eq('whitespace only', Scope.scopeFromFrame('   '), null)
  eq('a non-string', Scope.scopeFromFrame(null), null)
})
group('the depth is an index, and the caller is index 2', () => {
  // This is the assertion the library's whole scope rule rests on, and it is
  // asserted here against a REAL trace rather than a synthetic one because the
  // frame layout is the thing that goes wrong: a constant that is off by one
  // reports `log.logCore` as the owner of every line in the shell, which reads
  // as a plausible scope and so survives review.
  //
  // The layout, measured in the shell rather than assumed:
  //   0  emit          (LogCore.js) - where `new Error()` is evaluated
  //   1  the forwarding method - LogCore's own `info`, or Log.qml's
  //   2  the call site  - the caller's own file, whatever its shape
  //
  // A direct caller and a facaded one sit at the SAME index, because the
  // forwarding method occupies one slot either way. An earlier version of this
  // file documented the facade as "one frame further out than a script", which
  // is what set JS_DEPTH to 1.
  eq('JS_DEPTH is 2', Core.JS_DEPTH, 2)
  // The index is used exactly, so a synthetic trace pins the same contract the
  // real one does - including that it does NOT scan forward for "the first
  // frame I can parse", which would walk into the logger and name it.
  const trace = [
    'emit@qs:@/qs/common/log/LogCore.js:180',
    'info@qs:@/qs/common/log/LogCore.js:215',
    'probe@qs:@/qs/features/pass/PassController.qml:900',
    'expression for onExited@qs:@/qs/features/pass/PassController.qml:901',
  ].join('\n')
  eq('index 0 is emit itself', Scope.scopeFromStack(trace, 0), 'log.logCore')
  eq('index 1 is the forwarding method', Scope.scopeFromStack(trace, 1), 'log.logCore')
  eq('index 2 is the call site', Scope.scopeFromStack(trace, 2), 'pass.passController')
  eq('a deeper index is honoured rather than clamped', Scope.scopeFromStack(trace, 3), 'pass.passController')
  eq('an index past the trace falls back', Scope.scopeFromStack(trace, 9), 'shell')
  eq('no index at all defaults to 1', Scope.scopeFromStack(trace), 'log.logCore')
})
group('no QML file reaches LogCore directly', () => {
  // The rule the depth constant cannot enforce. A component that imports
  // `LogCore.js` instead of the `Log` singleton is at the right index today and
  // is one refactor away from being at the wrong one, and nothing at the call
  // site would say so: the file compiles, lints clean, and reports the logger
  // as its own owner. Eleven feature files did exactly this before the rule
  // existed. `.pragma library` is the other half of the contract and may
  // import it; a QML singleton cannot be reached from a script at all, which is
  // the whole reason LogCore exists alongside Log.qml.
  const offenders = []
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name)
      // A symlink is never descended into and never read. This tree carries at
      // least one untracked self-referential one, and following it turns this
      // walk into an EISDIR crash that has nothing to do with what it checks.
      if (entry.isSymbolicLink()) continue
      if (entry.isDirectory()) { walk(full); continue }
      if (!entry.name.endsWith('.qml') && !entry.name.endsWith('.js')) continue
      if (entry.name === 'LogCore.js') continue
      if (fs.readFileSync(full, 'utf8').includes('log/LogCore.js')) {
        offenders.push(path.relative(SHELL, full))
      }
    }
  }
  walk(SHELL)
  eq('every importer is a .pragma library, never a .qml',
    offenders.filter((f) => !f.endsWith('.qml') && !fs.readFileSync(SRC(path.basename(f)), 'utf8').startsWith('.pragma library')), [])
  eq('and the component count is zero, not merely small',
    offenders.filter((f) => f.endsWith('.qml')).length, 0)
})
group('nothing usable falls back to one honest owner', () => {
  eq('an empty path', Scope.scopeFromPath(''), 'shell')
  eq('a path of separators', Scope.scopeFromPath('///'), 'shell')
  eq('a non-string', Scope.scopeFromPath(null), 'shell')
  eq('a number', Scope.scopeFromPath(7), 'shell')
})
group('only the two extensions this tree uses are stripped', () => {
  eq('.qml', Scope.stripExtension('Clipboard.qml'), 'Clipboard')
  eq('.js', Scope.stripExtension('ClipboardLib.js'), 'ClipboardLib')
  eq('an unknown extension is kept whole', Scope.stripExtension('notes.md'), 'notes.md')
  eq('a name with no extension', Scope.stripExtension('README'), 'README')
})

// ---------------------------------------------------------------------------
section('LogScope.scopeFromStack - the frame the scope is read from')
// ---------------------------------------------------------------------------
group('depth is an index into the trace, and the frame at it is the call site', () => {
  // Frame 0 is the function that captured the trace; frame 1 is whoever
  // called it. This is the shape `Log.qml` passes 2 for and `LogCore` 1 for.
  const st = stackOf(frame('info', 'common/log/LogCore.js', 120), frame('caller', 'features/clipboard/Clipboard.qml', 42))
  eq('depth 0 names the capturing function', Scope.scopeFromStack(st, 0), 'log.logCore')
  eq('depth 1 names the caller', Scope.scopeFromStack(st, 1), 'clipboard')
})
group('a frame with no function name is still a location', () => {
  const st = stackOf('@qs:@/qs/features/bar/Bar.qml:7')
  eq('the bare url form', Scope.scopeFromStack(st, 0), 'bar')
  const binding = stackOf('expression for text@qs:@/qs/features/osd/OSDView.qml:12')
  eq('a binding frame', Scope.scopeFromStack(binding, 0), 'osd.osdView')
})
group('the index is used exactly, never scanned forward', () => {
  // Scanning forward would walk into a frame inside this directory and report
  // the logger as the owner of a line it was only asked to print.
  const st = stackOf(frame('emit', 'common/log/LogCore.js', 120), frame('info', 'common/log/Log.qml', 60), frame('caller', 'features/clipboard/Clipboard.qml', 42))
  eq('depth 1 is the facade, not the caller', Scope.scopeFromStack(st, 1), 'log')
  eq('depth 2 is the caller', Scope.scopeFromStack(st, 2), 'clipboard')
})
group('a trace that cannot be used falls back rather than throwing', () => {
  eq('an empty stack', Scope.scopeFromStack('', 1), 'shell')
  eq('whitespace only', Scope.scopeFromStack('   \n  ', 1), 'shell')
  eq('a non-string', Scope.scopeFromStack(null, 1), 'shell')
  eq('a depth past the end', Scope.scopeFromStack(stackOf(frame('f', 'a/B.qml', 1)), 9), 'shell')
  eq('a frame that names no file', Scope.scopeFromStack(stackOf('native@'), 0), 'shell')
  eq('a non-numeric depth defaults to 1, so the second frame is read',
    Scope.scopeFromStack(stackOf(frame('a', 'features/x/Y.qml', 1), frame('b', 'features/z/W.qml', 2)), 'nope'),
    'z.w')
})

// ---------------------------------------------------------------------------
section('LogScope.matching - a scope is hierarchical and case-insensitive')
// ---------------------------------------------------------------------------
group('a key covers itself and its dot-descendants', () => {
  eq('bar covers bar', Scope.matchesKey('bar', 'bar'), true)
  eq('bar covers bar.archUpdates', Scope.matchesKey('bar.archUpdates', 'bar'), true)
  eq('bar.archUpdates covers itself', Scope.matchesKey('bar.archUpdates', 'bar.archUpdates'), true)
  eq('bar does not reach a sibling', Scope.matchesKey('clipboard', 'bar'), false)
  eq('and a prefix is not a descendant', Scope.matchesKey('barn', 'bar'), false)
  eq('matching ignores case', Scope.matchesKey('bar.archUpdates', 'BAR.ARCHUPDATES'), true)
  eq('a non-string scope is no match', Scope.matchesKey(null, 'bar'), false)
  eq('a non-string key is no match', Scope.matchesKey('bar', null), false)
})
group('the longest covering key wins, so nesting is expressible', () => {
  // This is what makes `bar=warn,bar.archUpdates=trace` split one subtree at
  // the deeper key rather than one of them overruling the other.
  const map = { bar: 'warn', 'bar.archUpdates': 'trace' }
  eq('the deeper key for the deeper scope', Scope.mostSpecificMatch(map, 'bar.archUpdates'), 'trace')
  eq('the shallow key elsewhere under bar', Scope.mostSpecificMatch(map, 'bar.battery'), 'warn')
  eq('nothing at all outside bar', Scope.mostSpecificMatch(map, 'clipboard'), null)
  eq('no map is no match', Scope.mostSpecificMatch(null, 'bar'), null)
  eq('a non-object is no match', Scope.mostSpecificMatch('bar', 'bar'), null)
})

// ---------------------------------------------------------------------------
section('LogSpec.normalizeLevel - the vocabulary')
// ---------------------------------------------------------------------------
group('every accepted spelling normalizes, and nothing else does', () => {
  for (const [input, want] of [['error', 'error'], ['ERROR', 'error'], [' err ', 'error'], ['warn', 'warn'], ['warning', 'warning'].map(() => 'warn'), ['info', 'info'], ['debug', 'debug'], ['trace', 'trace'], ['tracing', 'trace']]) {
    eq(JSON.stringify(input), Spec.normalizeLevel(input), want)
  }
  for (const input of ['off', 'none', 'silent', 'quiet']) {
    eq(JSON.stringify(input) + ' normalizes to off', Spec.normalizeLevel(input), 'off')
  }
  for (const input of ['', '  ', 'd', 'i', 'w', 'e', 'verbse', '1', null, undefined, 7, {}, ['info']]) {
    eq(JSON.stringify(input) + ' is not a level', Spec.normalizeLevel(input), null)
  }
})

// ---------------------------------------------------------------------------
section('LogSpec.baseLevels - a level is a band, and debug is the odd one')
// ---------------------------------------------------------------------------
group('a band carries everything more severe inside it', () => {
  eq('off is empty', kinds(Spec.baseLevels('off')), [])
  eq('error is errors alone', kinds(Spec.baseLevels('error')), ['error'])
  eq('warn adds warnings', kinds(Spec.baseLevels('warn')), ['error', 'warn'])
  eq('info adds info', kinds(Spec.baseLevels('info')), ['error', 'info', 'warn'])
})
group('debug does NOT imply info, which is the whole reason the vocabulary exists', () => {
  // `=debug` and `=debug,info` have to be two different asks. If debug ever
  // picks up info, one of the two documented spellings becomes a synonym of
  // the other and the distinction the spec grammar is built on is gone.
  eq('debug is errors, warnings and debug', kinds(Spec.baseLevels('debug')), ['debug', 'error', 'warn'])
  eq('and info is absent from it', Spec.baseLevels('debug').info, undefined)
  eq('trace is errors, warnings and trace', kinds(Spec.baseLevels('trace')), ['error', 'trace', 'warn'])
  eq('trace does not imply debug either', Spec.baseLevels('trace').debug, undefined)
})
group('an unusable name falls back to the default rather than to nothing', () => {
  eq('null', kinds(Spec.baseLevels(null)), ['error', 'info', 'warn'])
  eq('an empty string', kinds(Spec.baseLevels('')), ['error', 'info', 'warn'])
  eq('a misspelling', kinds(Spec.baseLevels('infos')), ['error', 'info', 'warn'])
  eq('a number', kinds(Spec.baseLevels(3)), ['error', 'info', 'warn'])
})

// ---------------------------------------------------------------------------
section('LogSpec.parseSpec - the grammar')
// ---------------------------------------------------------------------------
const parse = (text) => Spec.parseSpec(text)
// Declared here rather than in the resolve section because a parse-level case
// below reads a resolved set: a bare term that is not a level is read as a
// scope, and what that does is only visible once resolved.
const resolve = (text, base, scopes) => Spec.resolve(Spec.parseSpec(text), base, scopes)
const levelsFor = (r, scope) => kinds(Spec.levelsFor(r, scope))
group('a level term selects, it does not accumulate on the base', () => {
  const p = parse('debug')
  eq('debug names debug', kinds(p.levels), ['debug'])
  eq('and no scope term was read', p.bare.length, 0)
  eq('=debug,info names both', kinds(parse('debug,info').levels), ['debug', 'info'])
  eq('the order does not matter', kinds(parse('info,debug').levels), ['debug', 'info'])
})
group('* is every band, not the widest one', () => {
  eq('* names all five', kinds(parse('*').levels), ['debug', 'error', 'info', 'trace', 'warn'])
  eq('which resolves to everything', kinds(Spec.levelsFor(Spec.resolve(parse('*'), 'info', null), 'anything')),
    ['debug', 'error', 'info', 'trace', 'warn'])
  // `trace` is the widest band and is still not everything: it excludes info
  // and debug by construction, which is exactly why `*` cannot mean it.
  eq('trace is the widest band and is not the whole set',
    Spec.levelsFor(Spec.resolve(parse('*'), 'info', null), 'anything').info === true &&
    Spec.baseLevels('trace').info === undefined, true)
})
group('isScopeName is the validator, and it is stricter than a string check', () => {
  eq('a single segment', Spec.isScopeName('clipboard'), true)
  eq('a dotted scope', Spec.isScopeName('bar.archUpdates'), true)
  eq('a dash inside a segment', Spec.isScopeName('bar.now-playing'), true)
  eq('an underscore', Spec.isScopeName('bar.a_b'), true)
  eq('a leading digit is refused, because every real scope starts with a letter',
    Spec.isScopeName('3d'), false)
  eq('a leading dash is a term marker, not a scope', Spec.isScopeName('-bar'), false)
  eq('whitespace', Spec.isScopeName('bar arch'), false)
  eq('a slash', Spec.isScopeName('bar/arch'), false)
  eq('a glob', Spec.isScopeName('bar.*'), false)
  eq('an empty string', Spec.isScopeName(''), false)
  eq('a leading dot', Spec.isScopeName('.bar'), false)
  eq('a trailing dot', Spec.isScopeName('bar.'), false)
  eq('a non-string', Spec.isScopeName(null), false)
})
group('unionLevels is the band union a named selection adds up to', () => {
  // Stated on its own because it is where "levels are a set" becomes concrete:
  // two named bands union, and each contributes the bands more severe than it.
  eq('one band', kinds(Spec.unionLevels({ debug: true })), ['debug', 'error', 'warn'])
  eq('two bands', kinds(Spec.unionLevels({ debug: true, info: true })), ['debug', 'error', 'info', 'warn'])
  eq('a band already implied by the other', kinds(Spec.unionLevels({ warn: true, error: true })), ['error', 'warn'])
  eq('none named', kinds(Spec.unionLevels({})), [])
})
group('a spec that named levels replaces the base selection rather than adding to it', () => {
  // `=debug` has to be able to turn info OFF, which is the entire reason it
  // exists. A union with the base would make it a synonym of `=debug,info`.
  eq('the base is not carried in', levelsFor(resolve('debug', 'info', null), 'bar'), ['debug', 'error', 'warn'])
  eq('and adding it back is a second term', levelsFor(resolve('debug,info', 'info', null), 'bar'), ['debug', 'error', 'info', 'warn'])
})
group('a spec that names no level leaves the base to decide', () => {
  eq('only a scope term', parse('clipboard').levels, null)
  eq('only an exclusion', parse('-bar').levels, null)
  eq('nothing at all', parse('').levels, null)
  eq('a null spec', parse(null).levels, null)
  eq('a non-string spec', parse(42).levels, null)
})
group('-term is a level when it names one and a scope when it does not', () => {
  const p = parse('-warn,-bar.archUpdates')
  eq('warn was dropped as a level', kinds(p.dropped), ['warn'])
  eq('bar.archUpdates was silenced as a scope', kinds(p.silenced), ['bar.archupdates'])
  eq('and neither became a scope name', p.bare.length, 0)
})
group('the scope=level override is repeatable and its scope is validated', () => {
  const p = parse('bar=warn,bar.archUpdates=trace')
  eq('both overrides', JSON.stringify(p.overrides), '{"bar":"warn","bar.archupdates":"trace"}')
  eq('and the spelling each author used is kept for the echo', JSON.stringify(p.labels), '{"bar":"bar","bar.archupdates":"bar.archUpdates"}')
  eq('a level that is not one', parse('bar=louder').warnings.length, 1)
  eq('a scope that is not one', parse('bar modules=loud').warnings.length, 1)
  eq('a leading = has no scope to read', parse('=debug').warnings.length, 1)
  eq('the split is on the FIRST =, so a second = lands in the level and the term is refused',
    JSON.stringify(parse('bar=warn=trace').overrides), '{}')
  eq('and it is reported rather than half-applied', parse('bar=warn=trace').warnings.length, 1)
})
group('off empties the set without cancelling an override', () => {
  eq('off is recognized', parse('off').off, true)
  for (const spelling of ['none', 'silent', 'quiet', 'OFF']) {
    eq(spelling, parse(spelling).off, true)
  }
  eq('off never becomes a named level', parse('off').levels, null)
})
group('a bare scope term is "only that scope"', () => {
  const p = parse('clipboard,bar')
  eq('both scopes', p.bare, ['clipboard', 'bar'])
  eq('and no level', p.levels, null)
})
group('a bare term that is not a level is read as a scope, not rejected', () => {
  // This is the deliberate consequence of `<scope>` meaning "only that
  // scope": the grammar cannot tell a misspelled level from a scope name, so
  // `VIBRANIUM_SHELL_LOG=inof` selects a scope called `inof` and logs nothing.
  // The alternative - warning on anything that is not a level - would reject
  // every real scope name, which is the case that has to work.
  eq('nonsense is a legal scope name', parse('nonsense').bare, ['nonsense'])
  eq('and it is not warned about', parse('nonsense').warnings.length, 0)
  eq('so a misspelled level silences rather than erroring',
    levelsFor(Spec.resolve(parse('inof'), 'trace', null), 'bar'), [])
})
group('nothing throws, and every rejected term is reported once', () => {
  const bad = ['-', '-=warn', 'a b', 'bar/x=loud', '#comment', '   ,  ,  ', 'bar=', 'bar modules=loud', '=debug']
  for (const term of bad) {
    noThrow(`parse(${JSON.stringify(term)}) does not throw`, () => parse(term))
  }
  const noisy = parse('-,#more,-=warn,bar/x,bar=')
  eq('five rejected terms are reported', noisy.warnings.length, 5)
  eq('and each names its term', noisy.warnings.every((w) => w.startsWith('term ')), true)
  eq('and none of them reached the resolved rules', JSON.stringify({ levels: noisy.levels, overrides: noisy.overrides, silenced: noisy.silenced, bare: noisy.bare }),
    '{"levels":null,"overrides":{},"silenced":{},"bare":[]}')
})
group('the warning list is bounded, so a pathological spec cannot flood the log', () => {
  const many = Array.from({ length: 200 }, () => '#nonsense').join(',')
  const p = parse(many)
  eq('capped', p.warnings.length, 33)
  eq('and the cap says so', p.warnings[32], '... further terms dropped')
})

// ---------------------------------------------------------------------------
section('LogSpec.resolve - precedence')
// ---------------------------------------------------------------------------
group('silence outranks everything, and a scope term ADDS to the global set', () => {
  eq('a silenced scope', levelsFor(resolve('-clipboard', 'trace', null), 'clipboard'), [])
  eq('silence reaches the subtree', levelsFor(resolve('-clipboard', 'trace', null), 'clipboard.clipboardLib'), [])
  eq('and stops at the segment boundary', levelsFor(resolve('-clipboard', 'trace', null), 'clipb'), ['error', 'trace', 'warn'])
  // The whole point of the additive rule: one scope widened without the rest.
  eq('a scope term adds a band to what it inherits',
    levelsFor(resolve('clipboard=debug', 'info', null), 'clipboard'), ['debug', 'error', 'info', 'warn'])
  eq('and the global set is untouched elsewhere',
    levelsFor(resolve('clipboard=debug', 'info', null), 'bar'), ['error', 'info', 'warn'])
  eq('the addition reaches the subtree',
    levelsFor(resolve('clipboard=debug', 'info', null), 'clipboard.panel'), ['debug', 'error', 'info', 'warn'])
  // This is the spec workflow W2 exists for, and it was inexpressible while a
  // scope term PINNED: `scope=info,scope=debug` kept only the last term, so a
  // scope could never hold INFO and DEBUG together.
  eq('the workflow spec: one scope below the rest',
    levelsFor(resolve('info,pass.passController=debug', 'warn', null), 'pass.passController'),
    ['debug', 'error', 'info', 'warn'])
  eq('and nothing else moved',
    levelsFor(resolve('info,pass.passController=debug', 'warn', null), 'bar'), ['error', 'info', 'warn'])
})
group('every covering scope term applies, least specific first', () => {
  const r = resolve('bar=warn,bar.archUpdates=trace', 'info', null)
  eq('the shallow term contributes to the deep scope',
    levelsFor(r, 'bar.archUpdates'), ['error', 'info', 'trace', 'warn'])
  eq('the shallow term alone applies elsewhere under bar', levelsFor(r, 'bar.battery'), ['error', 'info', 'warn'])
  eq('and the global set outside bar', levelsFor(r, 'clipboard'), ['error', 'info', 'warn'])
  // Pinning used to make the deeper key REPLACE the shallower one, so a parent
  // could not be widened without being overruled by its own child. Additive
  // terms mean a child adds to its parent instead.
  eq('a parent widened for a subtree only widens the subtree',
    levelsFor(resolve('bar=debug', 'info', null), 'bar.archUpdates'), ['debug', 'error', 'info', 'warn'])
  eq('and a sibling is unaffected', levelsFor(resolve('bar.battery=debug', 'info', null), 'bar.network'),
    ['error', 'info', 'warn'])
})
group('off still silences, and a descendant can re-enable', () => {
  const r = resolve('bar=off,bar.archUpdates=debug', 'info', null)
  eq('the silenced scope', levelsFor(r, 'bar'), [])
  eq('and its other descendants', levelsFor(r, 'bar.battery'), [])
  eq('a deeper term adds back from nothing', levelsFor(r, 'bar.archUpdates'), ['debug', 'error', 'warn'])
  eq('off alone is still total', levelsFor(resolve('bar=off', 'info', null), 'bar.archUpdates'), [])
})
group('a bare scope term empties the global set and pins that scope to the base', () => {
  const r = resolve('clipboard', 'debug', null)
  eq('nothing outside it', levelsFor(r, 'bar'), [])
  eq('the scope itself is at the base level', levelsFor(r, 'clipboard'), ['debug', 'error', 'warn'])
  eq('and its subtree with it', levelsFor(r, 'clipboard.clipboardLib'), ['debug', 'error', 'warn'])
  eq('several scopes at once', levelsFor(resolve('clipboard,bar', 'info', null), 'bar.archUpdates'), ['error', 'info', 'warn'])
  // The bare term EMPTIES the global set, so what the explicit term adds to is
  // empty and the result is exactly that term's bands. This is the one place
  // where "adds" is not visible, and it is visible for a reason.
  eq('with a bare term the global set is empty, so an explicit term gives its own bands',
    levelsFor(resolve('clipboard,clipboard=trace', 'info', null), 'clipboard'), ['error', 'trace', 'warn'])
})
group('off empties the global set and leaves the overrides standing', () => {
  const r = resolve('off,clipboard=trace', 'trace', null)
  eq('nothing outside clipboard', levelsFor(r, 'bar'), [])
  eq('clipboard at its own level', levelsFor(r, 'clipboard'), ['error', 'trace', 'warn'])
})
group('a -level term subtracts from whatever the base or a term selected', () => {
  eq('from the base', levelsFor(resolve('-trace', 'trace', null), 'bar'), ['error', 'warn'])
  eq('from a named set', levelsFor(resolve('trace,-warn', 'info', null), 'bar'), ['error', 'trace'])
  eq('and it can empty it', levelsFor(resolve('trace,-warn,-error', 'info', null), 'bar'), ['trace'])
})
group('the base level is a DEFAULT, not a second source', () => {
  // It used to be the settings store's level, and there was a per-scope map
  // beside it. Both are gone: there is one source, and this parameter is only
  // what to use when the spec names no level of its own. Nothing passes it, so
  // what is really being pinned here is that an absent spec resolves to the
  // built-in level rather than to something off.
  eq('the base level is used when the spec names none', levelsFor(resolve(null, 'debug'), 'bar'), ['debug', 'error', 'warn'])
  eq('an unusable base level falls back to the default', levelsFor(resolve(null, 'louder'), 'bar'), ['error', 'info', 'warn'])
  eq('an absent one does too', levelsFor(resolve(null), 'bar'), ['error', 'info', 'warn'])
  eq('and a spec that names a level wins over the base', levelsFor(resolve('warn', 'debug'), 'bar'), ['error', 'warn'])
  eq('a non-string spec is treated as no spec', levelsFor(resolve(42), 'bar'), ['error', 'info', 'warn'])
})
group('a spec that names no level still decides on its own', () => {
  // This group used to be "the spec replaces the settings rather than merging
  // with it", which needed a merge rule because there were two sources. There
  // is one now, so what is left to pin is the rule that survives: a spec that
  // names no LEVEL is still a configuration, not a fall-through to the default.
  // `clipboard` and `off` both leave `levels` null, and both must not be read
  // as "nothing was asked".
  eq('a bare scope term empties everything else', levelsFor(resolve('clipboard'), 'bar'), [])
  eq('and off empties it too', levelsFor(resolve('off'), 'bar'), [])
  eq('a spec naming a level ignores the base entirely',
    levelsFor(Spec.resolve(Spec.parseSpec('debug'), 'info'), 'bar'), ['debug', 'error', 'warn'])
  eq('but a spec that named no level and no scope leaves the base to decide, and only silences',
    levelsFor(resolve('-bar', 'trace', { clipboard: 'trace' }), 'wallpaper'), ['error', 'trace', 'warn'])
  eq('while the scope it named is still silent', levelsFor(resolve('-bar', 'trace', null), 'bar'), [])
})
group('a resolved configuration is read-only, because the caller memoises it', () => {
  // `LogCore` holds the returned sets per scope for the life of the
  // configuration, so a rewrite here would be observed by every scope that
  // already asked.
  const r = resolve('debug', 'info', null)
  const first = Spec.levelsFor(r, 'bar')
  Spec.levelsFor(r, 'clipboard')
  eq('the same object comes back for the same scope', Spec.levelsFor(r, 'bar'), first)
  noThrow('reading levelsFor with no configuration at all', () => Spec.levelsFor(null, 'bar'))
  eq('which is the default set', kinds(Spec.levelsFor(null, 'bar')), ['error', 'info', 'warn'])
})

// ---------------------------------------------------------------------------
section('LogSpec.allows - the one question the gate asks')
// ---------------------------------------------------------------------------
group('allows is levelsFor with a level', () => {
  const r = resolve('debug,-clipboard,bar=trace', 'info', null)
  eq('a level the global set carries, outside every override', Spec.allows(r, 'wallpaper', 'debug'), true)
  eq('and the level it does not', Spec.allows(r, 'wallpaper', 'trace'), false)
  // An overridden scope answers to its own bands PLUS the global set - that is
  // the additive rule. What it no longer does is LOSE the global set, which is
  // what used to make `bar=trace` a way to drop info from bar.
  eq('an overridden scope keeps the global set and adds its own',
    Spec.allows(r, 'bar', 'debug'), true)
  eq('and to that level', Spec.allows(r, 'bar', 'trace'), true)
  eq('a silenced scope', Spec.allows(r, 'clipboard', 'error'), false)
  eq('a level that is not one', Spec.allows(r, 'bar', 'verbose'), false)
  eq('with no configuration at all', Spec.allows(null, 'bar', 'warn'), true)
})

// ---------------------------------------------------------------------------
section('LogSpec.stringify - the printed form of a message part')
// ---------------------------------------------------------------------------
const s = (v) => Spec.stringify(v)
group('a part that is already a string is untouched', () => {
  eq('plain', s('cleared clipboard'), 'cleared clipboard')
  eq('the empty string stays empty rather than becoming a null', s(''), '')
})
group('scalars print as themselves', () => {
  eq('a number', s(42), '42')
  eq('zero', s(0), '0')
  eq('a negative', s(-1.5), '-1.5')
  eq('NaN', s(NaN), 'NaN')
  eq('true', s(true), 'true')
  eq('null', s(null), 'null')
  eq('undefined', s(undefined), 'undefined')
})
group('an Error prints its message, because that is what is worth reading', () => {
  eq('with a message', s(new Error('no display')), 'Error: no display')
  eq('a bare Error keeps its name', s(new Error('')), 'Error')
  eq('a TypeError', s(new TypeError('bad scope')), 'TypeError: bad scope')
})
group('objects and arrays are expanded, because a [object Object] defeats DEBUG', () => {
  eq('a plain object', s({ id: 7, text: 'hi' }), '{"id":7,"text":"hi"}')
  eq('an array', s([1, 2, 3]), '[1, 2, 3]')
  eq('a nested array', s([[1], [2, 3]]), '[[1], [2, 3]]')
  eq('an empty array', s([]), '[]')
  eq('an object inside an array', s([{ a: 1 }]), '[{"a":1}]')
})
group('a value stringify refuses degrades to String() rather than taking the message', () => {
  const circular = {}
  circular.self = circular
  noThrow('a cycle', () => s(circular))
  eq('and prints as something', typeof s(circular), 'string')
  noThrow('a toJSON that throws', () => s({ toJSON() { throw new Error('no') } }))
  // JSON.stringify answers undefined for a value it cannot represent, and
  // undefined is not a string, so the fallback has to be taken on the result
  // rather than on a throw.
  eq('a toJSON that answers undefined', s({ toJSON() { return undefined } }), '[object Object]')
  eq('a null-prototype object still serializes', s(Object.create(null)), '{}')
})
group('a function names itself, which is all a log line can honestly do', () => {
  eq('a named one', s(function handler() {}), 'function handler')
  eq('an anonymous one', s(() => {}), 'function anonymous')
})
group('join is the space-separated form, and an empty message is empty', () => {
  eq('two parts', Spec.join(['updated', 3]), 'updated 3')
  eq('three', Spec.join(['entry', { id: 7 }, [1, 2]]), 'entry {"id":7} [1, 2]')
  eq('one part', Spec.join(['cleared']), 'cleared')
  eq('no parts', Spec.join([]), '')
  eq('a null list', Spec.join(null), '')
})
group('summarize is the bounded form, and it never walks a container', () => {
  // This is the one formatter in the library whose job is to NOT print data.
  // `stringify` above expands objects on purpose; `summarize` reduces them to
  // a shape, because its callers are the lines that have to say what changed
  // without saying what it changed into.
  eq('a boolean', Spec.summarize(true), 'true')
  eq('a number', Spec.summarize(42), '42')
  eq('zero', Spec.summarize(0), '0')
  eq('null', Spec.summarize(null), 'null')
  eq('undefined', Spec.summarize(undefined), 'undefined')
  eq('a short string whole', Spec.summarize('warn'), 'warn')
  eq('an empty string', Spec.summarize(''), '')
  eq('the bound is 48, the one this tree already uses elsewhere', Spec.SUMMARY_LIMIT, 48)
  eq('a string at the bound is not cut', Spec.summarize('x'.repeat(48)).length, 48)
  eq('a string over it is cut', Spec.summarize('x'.repeat(49)).length, 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx…(49)'.length)
  eq('and says what it cut', Spec.summarize('x'.repeat(49)).endsWith('…(49)'), true)
  eq('the length is characters, not bytes', Spec.summarize('é'.repeat(60)).endsWith('…(60)'), true)
})
group('summarize reduces a container to its shape and never to its contents', () => {
  eq('an array', Spec.summarize([1, 2, 3]), 'array[3]')
  eq('an empty array', Spec.summarize([]), 'array[0]')
  eq('an object', Spec.summarize({ a: 1, b: 2 }), 'object{2}')
  eq('an empty object', Spec.summarize({}), 'object{0}')
  eq('a nested array is still one array', Spec.summarize([[1], [2, 3]]), 'array[2]')
  // The whole point: a token sitting inside a value must not be readable.
  eq('a key named like a secret is not printed',
    Spec.summarize({ apiKey: 'sk-live-1234', token: 'abc' }), 'object{2}')
  eq('a circular object does not throw', typeof Spec.summarize(Object.assign({}, {})), 'string')
  const circular = {}
  circular.self = circular
  eq('and still reduces', Spec.summarize(circular), 'object{1}')
  eq('a function', Spec.summarize(function f() {}), 'function')
})
group('summarize differs from stringify exactly where it has to', () => {
  // One pair, stated as the reason both functions exist: the same value, two
  // different jobs, and confusing them is how a payload reaches a log.
  const value = { id: 7, text: 'hi' }
  eq('stringify expands it', Spec.stringify(value), '{"id":7,"text":"hi"}')
  eq('summarize reduces it', Spec.summarize(value), 'object{2}')
  eq('and stringify of an array expands', Spec.stringify([1, 2]), '[1, 2]')
  eq('while summarize of the same array does not', Spec.summarize([1, 2]), 'array[2]')
})
group('a scoped logger gates under the scope it emits under', () => {
  // The gate and the emission must agree about the scope, or a guard silently
  // starts protecting the wrong subtree. Asking separately means restating the
  // scope as a string at each call site, and the two can drift.
  Core.configure('info')
  eq('at() with a name carries a gate', typeof Core.at('x').allows, 'function')
  eq('a scope at warn refuses debug', Core.at('x').allows('debug'), false)
  eq('and permits warn', Core.at('x').allows('warn'), true)
  Core.configure('debug')
  eq('the same scope at debug permits debug', Core.at('x').allows('debug'), true)
  eq('an empty name is not treated as a scope named ""', Core.at('').allows('debug'), true)
  eq('a non-string name is not a scope either', Core.at(null).allows('debug'), true)
  Core.configure('off')
  eq('off refuses everything', [Core.at('x').allows('error'), Core.at('x').allows('info')], [false, false])
  Core.configure('')
})
group('a trace record is marked, and the marker sits after the scope', () => {
  // TRACE shares `console.debug` with DEBUG on purpose - a UI-draw trace must
  // stay out of the journal's warning and error bands - so without a marker the
  // two are the same line. The position is the load-bearing half: the natural
  // filter is `qml: <scope>:`, and a marker in front of the scope would stop a
  // trace line matching the scope the reader is filtering on.
  eq('the marker is a tilde and a space', Core.TRACE_MARKER, '~ ')
  Core.configure('debug,trace')
  captureConsole(() => {
    Core.emit('debug', ['plain'], 'sub.leaf', 2)
    Core.emit('trace', ['marked'], 'sub.leaf', 2)
  })
  const lines = printedAt('debug')
  eq('both land on the debug channel', lines.length, 2)
  eq('a debug record is untouched', lines[0], 'sub.leaf: plain')
  eq('a trace record is marked after the scope', lines[1], 'sub.leaf: ~ marked')
  eq('so a scope grep still matches a trace line',
    lines.filter((t) => t.startsWith('sub.leaf: ')).length, 2)
  captureConsole(() => Core.emit('trace', [], 'sub.leaf', 2))
  eq('a trace with no body still marks, and still names the scope',
    printedAt('debug'), ['sub.leaf: ~'])
  Core.configure('')
})
group('levelList reports the set most severe first, whatever the key order', () => {
  eq('a full set', Spec.levelList(Spec.baseLevels('debug')), ['error', 'warn', 'debug'])
  eq('an empty set', Spec.levelList({}), [])
  eq('no set', Spec.levelList(null), [])
})

// ---------------------------------------------------------------------------
section('LogSpec.describe and grammar - what status and help report')
// ---------------------------------------------------------------------------
group('describe echoes the spelling the author used, not the folded key', () => {
  const d = Spec.describe(resolve('bar.archUpdates=trace,-Clipboard', 'info', null))
  eq('the override key', Object.keys(d.overrides), ['bar.archUpdates'])
  eq('the silenced key, sorted', d.silenced, ['Clipboard'])
  eq('the levels, most severe first', d.levels, ['error', 'warn', 'info'])
  eq('the base level', d.baseLevel, 'info')
  eq('no configuration describes as null', Spec.describe(null), null)
})
group('grammar states the set rule, because it is the one that surprises', () => {
  const text = Spec.grammar()
  contains('it names the five levels', text, 'error warn info debug trace')
  contains('it says levels are a set', text, 'set, not a threshold')
  contains('it says debug does not imply info', text, 'debug does not imply info')
  contains('it documents the bare scope term', text, 'only that scope')
})

// ---------------------------------------------------------------------------
section('LogCore - the shared configuration state')
// ---------------------------------------------------------------------------
// Everything below claims its scope explicitly. The derived-scope path reads a
// Quickshell trace frame (`name@qs:@/qs/<path>:<line>`), and a node vm stack is
// a different shape, so exercising it here would be testing a parser against
// input the engine never produces. `LogScope.scopeFromStack` is covered above
// against measured Quickshell frames, and the derived path end to end is what
// suites/qml/probes and the shell itself exercise.
const claim = Core.at('test.scope')
group('the emitter routes each level to the console call Qt expects', () => {
  // This is the whole claim that Quickshell is being re-used rather than
  // replaced: the severity a caller asked for is the severity Qt sees.
  const out = captureConsole(() => {
    Core.configure('*')
    claim.info('i')
    claim.warn('w')
    claim.error('e')
    claim.debug('d')
    claim.trace('t')
  })
  eq('info reaches console.info', emitted('info'), ['test.scope: i'])
  eq('warn reaches console.warn', printedAt('warn'), ['test.scope: w'])
  eq('error reaches console.error', printedAt('error'), ['test.scope: e'])
  // `emitted` and not `printedAt`: the startup announcement is a record about
  // the configuration, not one of the records under test.
  eq('trace reaches console.debug, because Qt has no trace severity, and is marked there',
    emitted('debug'), ['test.scope: d', 'test.scope: ~ t'])
  eq('nothing reached console.log', printedAt('log'), [])
  // Five records went out - one per level - and the count is by scope rather
  // than by total: `captureConsole` also captures the startup announcement,
  // which is a record about the configuration and is asserted on its own
  // further down. The claim here is that every one of THESE reached a console.
  eq('and nothing was dropped on the floor',
    out.filter((p) => p.text.startsWith('test.scope')).length, 5)
})
group('an empty message prints the scope alone rather than a dangling colon', () => {
  captureConsole(() => {
    Core.configure('*')
    claim.info()
    claim.info('with', 'parts')
  })
  eq('no parts', emitted('info'), ['test.scope', 'test.scope: with parts'])
})
group('at() claims a scope and is memoised, so nothing is allocated per message', () => {
  // `allows` is part of the surface, not an extra: the gate has to live on the
  // same object as the emission or the two can disagree about the scope.
  eq('the five levels plus the gate', Object.keys(Core.at('custom.scope')).sort(),
    ['allows', 'debug', 'error', 'info', 'trace', 'warn'])
  is('the same object on the second call', Core.at('custom.scope'), (o) => o === Core.at('custom.scope'), 'memoised')
  is('and after a reconfigure', Core.at('custom.scope'), (o) => o === Core.at('custom.scope'), 'still memoised')
  captureConsole(() => {
    Core.configure('*')
    Core.at('custom.scope').info('claimed')
  })
  eq('the claimed scope, not a derived one', emitted('info'), ['custom.scope: claimed'])
})
group('a scope is printed before the message, and never as a dangling colon', () => {
  const out = captureConsole(() => {
    Core.configure('*')
    Core.at('').info('derived')
  })
  eq('something was printed', emitted('info').length, 1)
  is('and the text does not begin with a colon', emitted('info')[0], (t) => t.startsWith(':') === false, 'no bare prefix')
  is('and the scope prefix is the last thing before the message', emitted('info')[0], (t) => t.endsWith(': derived'), 'a scope and a message')
})
group('a silenced scope silences an explicit claim too', () => {
  const out = captureConsole(() => {
    Core.configure('*,-test.scope')
    eq('the gate agrees', Core.allows('error', 'test.scope'), false)
    eq('and emit reports that it printed nothing', claim.info('nope'), false)
  })
  eq('nothing was printed beyond the announcement', emitted('info'), [])
  eq('and no record reached console.warn or console.error', printed.filter((p) => p.level === 'warn' || p.level === 'error').length, 0)
})
group('emit reports whether it printed, so a caller can tell a suppressed call from one that ran', () => {
  Core.configure('info,-test.scope')
  eq('a suppressed call is false', claim.info('x'), false)
  Core.configure('info')
  captureConsole(() => eq('a printed call is true', claim.info('x'), true))
})
group('an explicit scope short-circuits the trace, so no depth has to be right', () => {
  // This is the seam `Log.qml` crosses: it passes `callerDepth`, and a wrong
  // number there would misattribute every line in the shell. A claimed scope
  // carries no depth, which is why `at()` is the escape hatch and not just a
  // convenience.
  captureConsole(() => {
    Core.configure('*')
    Core.emit('info', ['no depth given'], 'claimed.scope', undefined)
  })
  eq('the claimed scope is used verbatim', emitted('info'), ['claimed.scope: no depth given'])
})
group('configure replaces the configuration rather than merging into it', () => {
  Core.configure('debug')
  eq('first configure', Core.levels(), ['error', 'warn', 'debug'])
  Core.configure('trace')
  eq('the level selection is gone, not added to', Core.levels(), ['error', 'warn', 'trace'])
  eq('and so are the per-scope terms', JSON.stringify(Core.overrides()), '{}')
  // With the settings store gone there is no configuration that is NOT the
  // environment variable, so any spec at all is the env var being set.
  eq('and a non-empty spec is by definition fromEnv', Core.fromEnv(), true)
  Core.configure('off')
  eq('with nothing enabled at all', Core.levels(), [])
  eq('and off is still fromEnv, being still a spec', Core.fromEnv(), true)
})
group('an unset environment variable resolves to the built-in level in one call', () => {
  // There is no `configureDefault` and no second call. It used to exist to cover
  // the window before the SETTINGS store answered - a window during boot when
  // the shell is most likely to be doing something worth reading about. With
  // the environment as the only source, read synchronously where the gate is
  // installed, there is no window: one call resolves and the gate is live.
  Core.configure('')
  eq('an empty spec still resolves', Core.ready(), true)
  eq('to the built-in level', Core.levels(), ['error', 'warn', 'info'])
  eq('and the gate is live in the same turn', Core.allows('info', 'anything'), true)
  eq('a missing spec resolves too', Core.configure(null) !== null, true)
  eq('to the same level', Core.levels(), ['error', 'warn', 'info'])
  eq('a whitespace-only spec as well', Core.configure('   ') !== null, true)
  eq('to that same level', Core.levels(), ['error', 'warn', 'info'])
  eq('and none of the three is reported as the env var being set', Core.fromEnv(), false)
})
group('the memo is dropped on every reconfigure, so a changed rule is a changed answer', () => {
  Core.configure('info')
  eq('before', Core.allows('debug', 'clipboard'), false)
  Core.configure('debug')
  eq('after', Core.allows('debug', 'clipboard'), true)
  Core.configure('debug,clipboard=trace')
  eq('and after a per-scope term alone', Core.allows('trace', 'clipboard'), true)
  // Narrowing a scope below the base is the one thing a scope term can no
  // longer do, because it ADDS. Silence is `off` or a `-scope` exclusion.
  eq('a scope term cannot narrow the base any more', Core.allows('debug', 'clipboard'), true)
  eq('which leaves the global set alone', Core.allows('debug', 'bar'), true)
  Core.configure('debug,clipboard=off')
  eq('off is how a scope is silenced', Core.allows('error', 'clipboard'), false)
  eq('and reaches the subtree', Core.allows('error', 'clipboard.clipboardLib'), false)
})
group('the startup line reports what the spec resolved to, once, and only for a spec', () => {
  const out = captureConsole(() => {
    Core.configure('debug,-bar.archUpdates,bar.clock=trace')
  })
  const lines = printedAt('info')
  contains('the variable and its value', lines[0], 'VIBRANIUM_SHELL_LOG=debug,-bar.archUpdates,bar.clock=trace')
  contains('and what it enabled', lines[0], 'error, warn, debug')
  contains('the silenced scope, spelled as it was written', lines.join('\n'), 'silenced bar.archUpdates')
  contains('and the pinned one', lines.join('\n'), 'bar.clock=trace')
  eq('and one line per fact, no more', lines.length, 3)

  const quiet = captureConsole(() => Core.configure(''))
  eq('a settings-sourced configuration narrates nothing', quiet, [])
})
group('a rejected term is reported through console.warn, ungated', () => {
  // The one place a level that was switched off cannot be used: a warning
  // about the gate cannot itself be gated by it.
  captureConsole(() => Core.configure('#nonsense'))
  eq('the warning names the term', printedAt('warn')[0], "log: term '#nonsense' is not a level or a scope")
  captureConsole(() => Core.configure('off,#nonsense'))
  eq('and it is printed even when everything is off', printedAt('warn').length, 1)
})
group('scoped is the un-memoised form behind at(), and at() is the memo', () => {
  // The two are separate so the memo has one owner: `at()` caches, `scoped()`
  // builds. A caller that reached for `scoped` directly would allocate per
  // call, which is the cost `at()` exists to avoid.
  const built = Core.scoped('built.scope')
  eq('it carries the same gate as at()', Object.keys(built).sort(),
    ['allows', 'debug', 'error', 'info', 'trace', 'warn'])
  is('but it is a fresh object each call', built, (o) => o !== Core.scoped('built.scope'), 'not memoised')
  is('and not the memoised one', built, (o) => o !== Core.at('built.scope'), 'at() owns the memo')
  captureConsole(() => {
    Core.configure('*')
    built.info('from scoped')
  })
  eq('and it prints the same way', emitted('info'), ['built.scope: from scoped'])
})
group('announce is idempotent for one configuration and speaks up for the next', () => {
  // Reported once per configure rather than once per read, so a shell that
  // reads its configuration repeatedly does not narrate it repeatedly.
  Core.configure('debug')
  const first = captureConsole(() => Core.announce())
  eq('nothing on a second call', first, [])
  const second = captureConsole(() => Core.configure('debug,-bar'))
  // One line for the resolution and one for the silenced subtree; there is no
  // override in this spec, so a third line would be a fact nobody asked for.
  eq('one line per fact, and no more', second.filter((p) => p.level === 'info').length, 2)
  Core.configure('')
  eq('a settings-sourced configuration is never announced', captureConsole(() => Core.announce()), [])
})
group('the reads the IPC surface uses are total', () => {
  Core.configure('')
  eq('ready', Core.ready(), true)
  eq('envVar is the one name for the variable', Core.envVar(), 'VIBRANIUM_SHELL_LOG')
  eq('specText is empty for a settings-sourced configuration', Core.specText(), '')
  eq('baseLevel', Core.baseLevel(), 'info')
  eq('levels', Core.levels(), ['error', 'warn', 'info'])
  eq('silenced', Core.silenced(), [])
  eq('overrides', JSON.stringify(Core.overrides()), '{}')
  eq('warnings', Core.warnings(), [])
  eq('specText for a spec', Core.configure('debug') && Core.specText(), 'debug')
  eq('the resolved object is the one configure returned', Core.resolved().baseLevel, 'info')
})

// ---------------------------------------------------------------------------
section('every export of the three libraries is exercised by a case above')
// ---------------------------------------------------------------------------
// The project's rule: a suite asserts coverage of its own library's export
// list, so a function added without a case here is red rather than untested,
// and a function dropped makes the case that called it fail. The check reads
// this file's own text, so it is a claim about the suite rather than a list
// someone has to maintain beside it.
group('no export is left untested', () => {
  const here = fs.readFileSync(import.meta.filename, 'utf8')
  for (const [label, lib] of [['LogScope', Scope], ['LogSpec', Spec], ['LogCore', Core]]) {
    // Constants are excluded deliberately: they are read as data by the cases
    // above (`Spec.DEFAULT_LEVEL`, `Core.JS_DEPTH`), and a constant has no
    // behaviour to leave untested.
    const names = Object.keys(lib).filter((n) => typeof lib[n] === 'function').sort()
    eq(`${label} exports functions`, names.length > 0, true)
    eq(`${label}: every exported function is named in this suite`,
      names.filter((n) => !new RegExp(`\\b${n}\\b`).test(here)), [])
  }
})

finish()