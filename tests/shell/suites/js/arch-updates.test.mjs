#!/usr/bin/env node
// Suite: the Arch updates checkupdates parser (shell/services/system/).
//
// ArchUpdatesLib.parseUpdates pins the fetcher output format: one package
// per line, `pkgname oldver -> newver` (checkupdates and yay -Qua share
// the shape; the bare pacman -Qu field form is handled too). Malformed
// lines are skipped, never painted; overlong fields are capped. The
// service delegates to this parser, so the format lives in exactly one
// place.
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, finish,
} from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const AL = loadLib(path.join(SHELL, 'services/system/ArchUpdatesLib.js'))

suite('arch-updates', 'ArchUpdatesLib.parseUpdates')

// ---------------------------------------------------------------------------
section('arrow form - checkupdates and yay -Qua')

group('one package per line', () => {
  eq('a single line', AL.parseUpdates('firefox 131.0-1 -> 132.0-1', 'official'), [
    { name: 'firefox', current: '131.0-1', candidate: '132.0-1', repository: '', size: '', source: 'official' },
  ])
  eq('several lines', AL.parseUpdates('a 1 -> 2\nb 3 -> 4', 'aur').length, 2)
  eq('the source rides along', AL.parseUpdates('a 1 -> 2', 'aur')[0].source, 'aur')
  eq('blank lines are skipped', AL.parseUpdates('\na 1 -> 2\n\n', 'official').length, 1)
  eq('empty input parses to nothing', AL.parseUpdates('', 'official'), [])
  eq('undefined input parses to nothing', AL.parseUpdates(undefined, 'official'), [])
})

// ---------------------------------------------------------------------------
section('bare field form - pacman -Qu')

group('no arrow, positional fields', () => {
  eq('four fields take the fourth as candidate',
    AL.parseUpdates('vim 9.1-1 9.1-2 extra', 'official')[0], {
      name: 'vim', current: '9.1-1', candidate: 'extra', repository: '', size: '', source: 'official',
    })
  eq('three fields take the third as candidate',
    AL.parseUpdates('vim 9.1-1 9.1-2', 'official')[0].candidate, '9.1-2')
  eq('fewer fields are skipped', AL.parseUpdates('vim 9.1', 'official'), [])
})

// ---------------------------------------------------------------------------
section('hygiene - nothing malformed reaches the list')

group('caps and skips', () => {
  eq('a line past the length cap is skipped', AL.parseUpdates('x'.repeat(600), 'official'), [])
  const long = 'n'.repeat(200) + ' 1 -> 2'
  eq('an overlong name is capped at 128', AL.parseUpdates(long, 'official')[0].name.length, 128)
  eq('whitespace-only lines are skipped', AL.parseUpdates('   \n\t\n', 'official'), [])
})

finish()
