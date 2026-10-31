#!/usr/bin/env node
// Suite: the shared GTK settings.ini reader (shell/common/settings).
//
// GtkSettings.js is the single home for the cursor theme/size fallback
// reads MiscSettings and CursorPicker used to duplicate: one parser,
// one quote rule, one fallback contract. The shell's own cursor state
// JSON stays the first source; this file pins the shared INI fallback.
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, finish,
} from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const G = loadLib(path.join(SHELL, 'common/settings/GtkSettings.js'))

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

finish()
