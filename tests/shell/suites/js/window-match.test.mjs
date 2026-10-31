#!/usr/bin/env node
// Suite: common/window/WindowMatch.js - app identity to window.
//
// The policy under test decides which open window a notification belongs
// to. The notification spec carries no pid and no window handle, so this
// is inference rather than a lookup, and inference is exactly the kind of
// thing that drifts silently. Every phase, every tie-break and every way a
// sender can be unrecognisable is pinned here.
//
// WindowFocus.qml, the QML face, is a protocol client: it holds the
// toplevel list, orders it and calls activate(). None of that is pure, so
// this suite drives the decision only; whether the compositor honours the
// request is a live check, not a source one.

import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, deepEqual, finish,
} from '../../lib/assert.mjs'

// The shell root is resolved from this file's location, as
// collections.test.mjs does: assert.mjs's own SHELL_DIR climbs to the
// parent of the repo, so a suite that used it would not find the library.
const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')

const WM = loadLib(path.join(SHELL, 'common/window/WindowMatch.js'))

// A key is a {raw, flat} pair and the shape is load-bearing: the raw form
// keeps the separators a word boundary is visible in, the flat form is
// what a display string and a machine id can be compared as. Every phase
// needs one or the other, so the tests read `.flat` where they are
// asserting identity and the matcher itself chooses per phase.
const flatKeys = (sender) => WM.candidateKeys(sender).map(k => k.flat)

suite('common/window', 'WindowMatch.js: identity normalisation, the three match phases, the recency tie-break')

const r = (appId, recency = 0) => ({ appId, recency })
const sender = (extra) => ({ appName: '', appIcon: '', desktopEntry: '', ...extra })

// ---------------------------------------------------------------------------
section('flatten - one form for a human name and a machine id')
// ---------------------------------------------------------------------------
group('case and separator folding', () => {
  eq('lowercased', WM.flatten('Firefox'), 'firefox')
  eq('spaces stripped', WM.flatten('Google Chrome'), 'googlechrome')
  eq('dots and dashes stripped', WM.flatten('org.telegram.desktop'), 'orgtelegramdesktop')
  eq('a free-form name folds to one token', WM.flatten('  Steam__2 - Client!  '), 'steam2client')
  eq('already folded', WM.flatten('foot'), 'foot')
})
group('nothing in, nothing out', () => {
  // flatten is the identity floor for every key, so a miss here would
  // become an empty key that matches an empty appId further down.
  eq('undefined', WM.flatten(undefined), '')
  eq('null', WM.flatten(null), '')
  eq('an empty string', WM.flatten(''), '')
  eq('whitespace only', WM.flatten('   '), '')
  eq('punctuation only', WM.flatten('---'), '')
})

// ---------------------------------------------------------------------------
section('fromDesktopEntry - the one sender field that is an app id by construction')
// ---------------------------------------------------------------------------
group('the extension and the decoration come off', () => {
  eq('extension dropped', WM.fromDesktopEntry('telegram.desktop'), 'telegram')
  eq('no extension passes through', WM.fromDesktopEntry('telegram'), 'telegram')
  eq('case folded', WM.fromDesktopEntry('Firefox.DESKTOP'), 'firefox')
  eq('a dotless entry is its own key', WM.fromDesktopEntry('foot'), 'foot')
  eq('a reverse-DNS entry yields the name component', WM.fromDesktopEntry('org.telegram.desktop'), 'telegram')
  eq('a single-letter component is decoration, not a name', WM.fromDesktopEntry('a.b.firefox.desktop'), 'firefox')
  eq('nothing in, nothing out', WM.fromDesktopEntry(''), '')
  eq('an extension on its own is nothing', WM.fromDesktopEntry('.desktop'), '')
})

// ---------------------------------------------------------------------------
section('sepPrefix - a prefix that ends on a word boundary')
// ---------------------------------------------------------------------------
group('accepted boundaries', () => {
  eq('hyphen boundary, short first', WM.sepPrefix('google-chrome', 'google-chrome-stable'), true)
  eq('hyphen boundary, long first', WM.sepPrefix('google-chrome-stable', 'google-chrome'), true)
  eq('dot boundary', WM.sepPrefix('a.b', 'a.b.c'), true)
  eq('underscore boundary', WM.sepPrefix('a_b', 'a_b_c'), true)
  eq('equal strings are their own prefix', WM.sepPrefix('foot', 'foot'), true)
})
group('a mid-word hit is not a prefix', () => {
  // The reason a plain startswith is not enough: "obs" would otherwise
  // claim "obsidian". The character after the shared prefix has to be a
  // separator or nothing, never another letter or digit.
  eq('letters run together', WM.sepPrefix('obs', 'obsidian'), false)
  eq('a digit run together', WM.sepPrefix('foot2', 'foot21'), false)
  eq('a dot followed by a letter is not a boundary', WM.sepPrefix('a.b', 'a.bc'), false)
  eq('an underscore followed by a letter is not a boundary', WM.sepPrefix('a_b', 'a_bc'), false)
  eq('unrelated', WM.sepPrefix('firefox', 'chromium'), false)
  eq('an empty side never prefixes', WM.sepPrefix('', 'chromium'), false)
  eq('an empty subject never prefixes', WM.sepPrefix('chromium', ''), false)
})

// ---------------------------------------------------------------------------
section('rdnsMatch - the component, never the whole id')
// ---------------------------------------------------------------------------
group('a reverse-DNS id is matched by component', () => {
  eq('exact component', WM.rdnsMatch('org.telegram.desktop', 'telegram'), true)
  eq('multi-component id', WM.rdnsMatch('org.gnome.nautilus', 'nautilus'), true)
  // "gnome-terminal" against the component "gnome": the boundary sits in
  // the key, which is the one direction a component alone can carry.
  eq('key-first separator-bounded component', WM.rdnsMatch('org.gnome.nautilus', 'gnome-terminal'), true)
  eq('a mid-word component is not a match', WM.rdnsMatch('org.gnome.nautilus', 'nau'), false)
})
group('a dotless id is not decomposable', () => {
  eq('no dot, no components', WM.rdnsMatch('chromium', 'chrom'), false)
  eq('a component the id does not have', WM.rdnsMatch('org.telegram.desktop', 'signal'), false)
  // The guard that plain startswith would fail: a short leading component
  // must not claim a key that merely begins with the same letters.
  eq('a short component does not absorb a prefix', WM.rdnsMatch('org.telegram.desktop', 'tel'), false)
  eq('an empty key matches nothing', WM.rdnsMatch('org.telegram.desktop', ''), false)
})

// ---------------------------------------------------------------------------
section('candidateKeys - strongest identity first')
// ---------------------------------------------------------------------------
group('the three sender fields in strength order', () => {
  deepEqual(
    'desktop entry, then icon, then app name',
    flatKeys(sender({ desktopEntry: 'foo.desktop', appIcon: 'bar', appName: 'Baz' })),
    ['foo', 'bar', 'baz']
  )
  deepEqual('app name alone', flatKeys(sender({ appName: 'Telegram' })), ['telegram'])
  deepEqual('desktop entry alone', flatKeys(sender({ desktopEntry: 'foot.desktop' })), ['foot'])
})
group('a key that carries no identity is not a key', () => {
  // A path folded to an alnum token could never equal an appId, so
  // keeping it would only lengthen every later phase.
  deepEqual('a filesystem icon is dropped', flatKeys(sender({ appIcon: '/usr/share/a.png', appName: 'Baz' })), ['baz'])
  deepEqual('a file: icon is dropped', flatKeys(sender({ appIcon: 'file:///a.png' })), [])
})
group('redundant keys collapse', () => {
  deepEqual('the same identity from two fields', flatKeys(sender({ desktopEntry: 'foot.desktop', appName: 'foot' })), ['foot'])
  deepEqual('a sender that says nothing', flatKeys(sender({})), [])
  deepEqual('a null sender', flatKeys(null), [])
})

// ---------------------------------------------------------------------------
section('matchIndex - phase 0, an exact identity')
// ---------------------------------------------------------------------------
group('the exact hit', () => {
  eq('a desktop entry naming a reverse-DNS appId', WM.matchIndex(
    sender({ desktopEntry: 'telegram.desktop' }),
    [r('org.telegram.desktop', 5), r('chromium', 9)]
  ), 0)
  eq('a display name naming the appId exactly', WM.matchIndex(
    sender({ appName: 'Discord' }),
    [r('chromium', 9), r('discord', 3)]
  ), 1)
  eq('an exact hit on the first row', WM.matchIndex(
    sender({ appName: 'foot' }),
    [r('foot', 1), r('foot', 7)]
  ), 0)
})

// ---------------------------------------------------------------------------
section('matchIndex - phase 1, a separator-bounded prefix')
// ---------------------------------------------------------------------------
group('a prefix that ends on a word boundary', () => {
  eq('key shorter than the appId', WM.matchIndex(
    sender({ appName: 'google-chrome' }),
    [r('google-chrome-stable', 4), r('firefox', 9)]
  ), 0)
  eq('key longer than the appId', WM.matchIndex(
    sender({ appName: 'google-chrome-stable' }),
    [r('google-chrome', 4), r('firefox', 9)]
  ), 0)
})
group('a mid-word prefix is not a match', () => {
  eq('a bare prefix', WM.matchIndex(
    sender({ appName: 'chrom' }),
    [r('chromium', 4), r('firefox', 9)]
  ), -1)
  eq('a one-character-over prefix', WM.matchIndex(
    sender({ appName: 'foot2' }),
    [r('foot21', 4)]
  ), -1)
})

// ---------------------------------------------------------------------------
section('matchIndex - phase 2, a reverse-DNS component')
// ---------------------------------------------------------------------------
group('a display name reaches through a reverse-DNS appId', () => {
  // The case that makes the whole scheme necessary: no sender bothers to
  // report "org.telegram.desktop" as its name, they report "Telegram".
  eq('a display name', WM.matchIndex(
    sender({ appName: 'Telegram' }),
    [r('org.telegram.desktop', 2), r('chromium', 9)]
  ), 0)
  eq('a desktop entry', WM.matchIndex(
    sender({ desktopEntry: 'org.telegram.desktop' }),
    [r('foot', 9), r('org.telegram.desktop', 1)]
  ), 1)
})
group('and it is still bounded', () => {
  eq('a key too short for any component', WM.matchIndex(
    sender({ appName: 'tel' }),
    [r('org.telegram.desktop', 2)]
  ), -1)
  eq('a key absent from every component', WM.matchIndex(
    sender({ appName: 'signal' }),
    [r('org.telegram.desktop', 2)]
  ), -1)
})

// ---------------------------------------------------------------------------
section('precedence - identity decides the window, recency only breaks a tie')
// ---------------------------------------------------------------------------
group('a stronger identity outranks a more recent weaker one', () => {
  // The order the phases are run in, not scored. Scoring would let a hit
  // through the loosest phase on a weak key accumulate enough to outrank
  // an exact hit on a strong one - and the loose phases are only ever
  // reached by the weak keys, so a score would rank the weakest evidence
  // highest.
  eq('an exact desktop entry beats a loose app name', WM.matchIndex(
    sender({ desktopEntry: 'firefox.desktop', appName: 'Telegram' }),
    [r('org.telegram.desktop', 1), r('firefox', 99)]
  ), 1)
  eq('a prefix on a strong key beats a loose hit on a weak one', WM.matchIndex(
    sender({ desktopEntry: 'google-chrome.desktop', appName: 'Telegram' }),
    [r('org.telegram.desktop', 1), r('google-chrome-stable', 40)]
  ), 1)
  eq('an exact appId beats a prefix on a strong key', WM.matchIndex(
    sender({ desktopEntry: 'firefox.desktop', appName: 'google-chrome' }),
    [r('google-chrome-stable', 99), r('firefox', 1)]
  ), 1)
})
group('within one identity the row order decides, and the caller owns that order', () => {
  // Recency is read from the row, never sorted here: the caller is the
  // one that knows how the compositor reports focus order, and a match
  // that re-sorted its own input would disagree with whatever else ranks
  // the same list. Given rows already in descending recency, the first
  // match is the window a sender with several open means.
  eq('the first of two same-app rows', WM.matchIndex(
    sender({ appName: 'foot' }),
    [r('foot', 7), r('foot', 1)]
  ), 0)
  eq('the first of three same-app rows', WM.matchIndex(
    sender({ appName: 'foot' }),
    [r('foot', 7), r('foot', 4), r('foot', 1)]
  ), 0)
  eq('a tie keeps the given order', WM.matchIndex(
    sender({ appName: 'foot' }),
    [r('foot', 5), r('foot', 5)]
  ), 0)
  eq('an unfocused window still matches when it is the only one', WM.matchIndex(
    sender({ appName: 'foot' }),
    [r('foot', 0), r('chromium', 9)]
  ), 0)
})
group('a window the shell never saw focused is still a window', () => {
  eq('recency 0 matches', WM.matchIndex(sender({ appName: 'foot' }), [r('foot', 0)]), 0)
  eq('a missing recency counts as 0', WM.matchIndex(sender({ appName: 'foot' }), [{ appId: 'foot' }]), 0)
  eq('a negative recency is not a window', WM.matchIndex(sender({ appName: 'foot' }), [r('foot', -3)]), -1)
  eq('a non-numeric recency is not a window', WM.matchIndex(
    sender({ appName: 'foot' }), [{ appId: 'foot', recency: 'soon' }]
  ), -1)
  eq('NaN recency is not a window', WM.matchIndex(
    sender({ appName: 'foot' }), [{ appId: 'foot', recency: NaN }]
  ), -1)
})

// ---------------------------------------------------------------------------
section('misses - an unmatched sender activates nothing')
// ---------------------------------------------------------------------------
group('no window, no window', () => {
  eq('an empty list', WM.matchIndex(sender({ appName: 'foot' }), []), -1)
  eq('a null list', WM.matchIndex(sender({ appName: 'foot' }), null), -1)
  eq('an undefined list', WM.matchIndex(sender({ appName: 'foot' }), undefined), -1)
})
group('a sender with no identity is never guessed at', () => {
  // The important negative: a notification from a script carries no
  // desktop entry and an appName like "Vibranium". Falling back to
  // "focus something plausible" would steal focus on a timer, so a miss
  // has to stay a miss.
  eq('a fully blank sender', WM.matchIndex(sender({}), [r('foot', 1)]), -1)
  eq('a blank sender with no windows', WM.matchIndex(sender({}), []), -1)
  eq('a null sender', WM.matchIndex(null, [r('foot', 1)]), -1)
  eq('an empty appId never matches', WM.matchIndex(sender({ appName: 'foot' }), [r('', 9)]), -1)
  eq('a whitespace appId never matches', WM.matchIndex(sender({ appName: 'foot' }), [r('   ', 9)]), -1)
})
group('malformed rows are skipped, not matched', () => {
  eq('a hole in the list', WM.matchIndex(sender({ appName: 'foot' }), [null, r('foot', 1)]), 1)
  eq('a hole before the hit is skipped', WM.matchIndex(sender({ appName: 'foot' }), [null, null, r('foot', 2)]), 2)
  eq('a hole in front of a real row', WM.matchIndex(sender({ appName: 'foot' }), [null, r('foot', 3)]), 1)
})

// ---------------------------------------------------------------------------
section('the identities this has to get right in practice')
// ---------------------------------------------------------------------------
group('against a real client list', () => {
  // The rows are the shape WindowFocus.qml builds: appId plus the focus
  // recency it derived from the compositor event stream.
  const clients = [
    { appId: 'foot', recency: 1 },
    { appId: 'discord', recency: 6 },
    { appId: 'org.telegram.desktop', recency: 5 },
    { appId: 'chromium', recency: 4 },
  ]
  eq('Telegram by display name', WM.matchIndex(sender({ appName: 'Telegram' }), clients), 2)
  eq('Telegram by desktop entry', WM.matchIndex(sender({ desktopEntry: 'telegram.desktop' }), clients), 2)
  eq('Discord by display name', WM.matchIndex(sender({ appName: 'Discord' }), clients), 1)
  eq('Chromium by display name', WM.matchIndex(sender({ appName: 'Chromium' }), clients), 3)
  eq('a terminal by desktop entry', WM.matchIndex(sender({ desktopEntry: 'foot.desktop' }), clients), 0)
  eq('a sender with no window among them', WM.matchIndex(
    sender({ appName: 'Thunderbird', desktopEntry: 'thunderbird.desktop' }), clients
  ), -1)
})

finish()
