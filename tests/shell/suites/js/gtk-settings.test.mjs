#!/usr/bin/env node
// Suite: the shared GTK settings.ini reader (shell/common/settings).
//
// GtkSettings.js is the single home for the cursor theme/size fallback
// reads MiscSettings and CursorPicker used to duplicate: one parser,
// one quote rule, one fallback contract. The shell's own cursor state
// JSON stays the first source; this file pins the shared INI fallback.
import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, finish, contains, notMatch, match,
} from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const G = loadLib(path.join(SHELL, 'common/settings/GtkSettings.js'))
const SYSFONT_QML = fs.readFileSync(
  path.join(SHELL, 'common/settings/SystemFont.qml'), 'utf8'
)

// The block text of a named QML handler/object, up to its closing brace at the
// given indent. Used for source assertions on SystemFont's completion path.
function block(src, header, indent) {
  const m = src.match(new RegExp(`${header}:\\s*\\{([\\s\\S]*?)\\n${indent}\\}`))
  return m ? m[1] : ''
}

suite('gtk-settings', 'GtkSettings.parseIni, cursorThemeOf, cursorSizeOf')

const INI = '[Settings]\ngtk-cursor-theme-name = "Adwaita"\ngtk-cursor-theme-size = 24\n'

// ---------------------------------------------------------------------------
section('parseIni - one flat map')

group('keys and quotes', () => {
  eq('a quoted value is unquoted', G.parseIni(INI)['gtk-cursor-theme-name'], 'Adwaita')
  eq('a bare value is kept', G.parseIni('gtk-cursor-theme-size = 24\n')['gtk-cursor-theme-size'], '24')
  eq('first occurrence wins', G.parseIni('a = 1\na = 2\n').a, '1')
  eq('an indented line is not a key', G.parseIni('  a = 1\n').a, undefined)
  eq('a line without = is skipped', G.parseIni('just words\n').nothing, undefined)
  eq('empty input parses to nothing', Object.keys(G.parseIni('')).length, 0)
})

// ---------------------------------------------------------------------------
section('cursorThemeOf - theme with fallback')

group('theme or fallback', () => {
  eq('a quoted theme', G.cursorThemeOf(INI, ''), 'Adwaita')
  eq('an unquoted theme', G.cursorThemeOf('gtk-cursor-theme-name = Breeze\n', ''), 'Breeze')
  eq('absent reads the fallback', G.cursorThemeOf('[Settings]\n', 'Bibata'), 'Bibata')
  eq('an empty value reads the fallback', G.cursorThemeOf('gtk-cursor-theme-name = \n', 'Bibata'), 'Bibata')
})

// ---------------------------------------------------------------------------
section('cursorSizeOf - size with fallback')

group('size or fallback', () => {
  eq('a plain size', G.cursorSizeOf(INI, 0), 24)
  eq('absent reads the fallback', G.cursorSizeOf('[Settings]\n', 32), 32)
  eq('a non-number reads the fallback', G.cursorSizeOf('gtk-cursor-theme-size = big\n', 32), 32)
})

// ---------------------------------------------------------------------------
// SET-3: three uncoordinated SystemFont writers let completion order decide
// the font; one source record with a rank gate now governs it. All three
// readers still start at boot: the gate, not the load order, sets precedence.
// Headless has no gsettings and no GTK ini files, so these are source-level
// assertions: the rank gate is extracted from the real QML and executed
// against a stub root.
section('SystemFont - one source record, rank wins over arrival order')

group('onCompleted starts all three initial reads', () => {
  const body = block(SYSFONT_QML, 'Component\\.onCompleted', '  ')
  contains('onCompleted spawns gsettings', body, 'gsettingsProc.running = true')
  // FileView does not load on path assignment; it needs an explicit read.
  contains('onCompleted reloads gtk3', body, 'gtk3File.reload()')
  contains('onCompleted reloads gtk4', body, 'gtk4File.reload()')
})

group('ini reloads stay in the gsettings failure branch', () => {
  const body = block(SYSFONT_QML, 'onStreamFinished', '      ')
  contains('the failure branch reloads gtk3', body, 'gtk3File.reload()')
  contains('the failure branch reloads gtk4', body, 'gtk4File.reload()')
  // The watchers stay live for mid-session ini writes.
  contains('gtk3 still watches for changes', SYSFONT_QML, 'onFileChanged: gtk3File.reload()')
  contains('gtk4 still watches for changes', SYSFONT_QML, 'onFileChanged: gtk4File.reload()')
})

group('the rank gate: lower rank wins, later ini cannot clobber', () => {
  const m = SYSFONT_QML.match(/function _offer\([^)]*\)\s*\{[\s\S]*?\n  \}/)
  eq('SystemFont declares _offer', !!m, true)
  if (!m) return
  // Execute the real gate against a stub root: _offer is plain JS, so the
  // extracted declaration evaluates with the injected root in scope.
  const offer = new Function('root', `${m[0]}; return _offer`)
  const fresh = () => ({ _fontSource: { rank: 99, raw: 'Sans 11' } })

  let root = fresh()
  let put = offer(root)
  put(0, 'Cantarell 11') // gsettings
  put(1, 'Noto Sans 10') // gtk4
  put(2, 'DejaVu Sans 9') // gtk3
  eq('gsettings wins the boot race', root._fontSource.raw, 'Cantarell 11')
  eq('and its rank is kept', root._fontSource.rank, 0)

  // Boot path: all three readers start together, ini answers can land first.
  root = fresh()
  put = offer(root)
  put(2, 'DejaVu Sans 9') // gtk3 onLoaded
  put(1, 'Noto Sans 10') // gtk4 onLoaded
  put(0, 'Cantarell 11') // gsettings answer, later in arrival order
  eq('boot: ini first, later rank-0 answer still wins', root._fontSource.raw, 'Cantarell 11')
  eq('boot: the winning rank is gsettings', root._fontSource.rank, 0)

  root = fresh()
  put = offer(root)
  put(2, 'DejaVu Sans 9') // gtk3 first
  put(1, 'Noto Sans 10') // gtk4 outranks it
  put(1, 'Liberation 12') // a later equal-rank ini answer
  eq('gtk4 outranks gtk3', root._fontSource.raw, 'Noto Sans 10')
  eq('a later equal-rank ini cannot clobber', root._fontSource.rank, 1)

  root = fresh()
  put = offer(root)
  put(0, 'Cantarell 11')
  put(2, 'DejaVu Sans 9') // mid-session ini write
  eq('a mid-session ini write cannot clobber gsettings', root._fontSource.raw, 'Cantarell 11')

  root = fresh()
  put = offer(root)
  put(99, 'Sans 11')
  eq('an offer at the floor rank is ignored', root._fontSource.rank, 99)
})

group('family and pointSize derive from the one raw string', () => {
  notMatch('no imperative family write', SYSFONT_QML, /root\.family\s*=/)
  notMatch('no imperative pointSize write', SYSFONT_QML, /root\.pointSize\s*=/)
  notMatch('no imperative raw write', SYSFONT_QML, /root\.raw\s*=/)
  match('raw binds from _fontSource', SYSFONT_QML, /property string raw:\s*root\._fontSource\.raw/)
  match('family binds from the parsed record', SYSFONT_QML, /property string family:\s*root\._fontParsed\.family/)
  match('pointSize binds from the parsed record', SYSFONT_QML, /property int pointSize:\s*root\._fontParsed\.pointSize/)
  match('the default record is the floor', SYSFONT_QML, /rank: 99, raw: "Sans 11"/)
})

finish()
