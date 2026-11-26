#!/usr/bin/env node
// Suite: exact appLauncher help text and removal of two public verbs.
import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, contains, notContains, finish, SHELL_DIR } from '../../lib/assert.mjs'

const C = loadLib(path.join(SHELL_DIR, 'common/text/IpcCatalog.js'))
const P = loadLib(path.join(SHELL_DIR, 'common/text/IpcProtocol.js'))
const APP = fs.readFileSync(path.join(SHELL_DIR, 'features/launcher/AppLauncher.qml'), 'utf8')
const DOCS = fs.readFileSync(path.join(ROOT(), 'docs/user/app-launcher.md'), 'utf8')

function ROOT() { return path.dirname(SHELL_DIR) }

suite('launcher-help-text', 'exact appLauncher summaries and retired verbs')

section('exact summaries')
group('top-level and branch text', () => {
  eq('toggle summary', C.findRow('appLauncher.toggle').summary, 'Toggle the launcher panel')
  eq('history branch summary', C.findTarget('appLauncher').branches.history.summary,
    'View and manage usage history')
  eq('history branch has no notes', C.findTarget('appLauncher').branches.history.notes || [], [])
  eq('plugins branch has no notes', C.findTarget('appLauncher').branches.plugin.notes, [])
  eq('plugins list summary', C.findRow('appLauncher.plugin.list').summary, 'List all known plugins')
  eq('status summary', C.findRow('appLauncher.plugin.status').summary, "Show one plugin's status")
  eq('enable summary', C.findRow('appLauncher.plugin.enable').summary, 'Enable a plugin')
  eq('disable summary', C.findRow('appLauncher.plugin.disable').summary, 'Disable a plugin')
  eq('toggle plugin summary', C.findRow('appLauncher.plugin.toggle').summary, 'Toggle a plugin')
  eq('single reload summary', C.findRow('appLauncher.plugin.id.reload').summary,
    'Reload one plugin')
  eq('bulk reload summary', C.findRow('appLauncher.plugin.reload').summary,
    'Reload all enabled plugins')
  const pluginNotes = C.findRow('appLauncher.plugin.command').notes.join(' ')
  notContains('no fabricated user-plugin note', pluginNotes, 'user plugin')
})

section('verb literals, not enum placeholders')
group('lifecycle usage', () => {
  const expected = {
    'appLauncher.plugin.status': 'plugin <ID> status',
    'appLauncher.plugin.enable': 'plugin <ID> enable',
    'appLauncher.plugin.disable': 'plugin <ID> disable',
    'appLauncher.plugin.toggle': 'plugin <ID> toggle',
    'appLauncher.plugin.id.reload': 'plugin <ID> reload'
  }
  for (const [id, usage] of Object.entries(expected)) {
    eq(`${id} usage`, P.usage(C.findRow(id).words), usage)
  }
  eq('status still validates a plugin ref',
    P.match(C.findRow('appLauncher.plugin.status').words,
      ['plugin', 'calc', 'status']).args.ID, 'calc')
})

section('removed public verbs')
group('no rescan or discover anywhere in the public surface', () => {
  eq('no rescan row', C.findRow('appLauncher.rescan'), null)
  eq('no discover row', C.findRow('appLauncher.plugin.discover'), null)
  notContains('no rescan closure', APP, '"appLauncher.rescan"')
  notContains('no discover closure', APP, '"appLauncher.plugin.discover"')
  notContains('no rescan owner method', APP, 'function _rescanApps(')
  notContains('no discover owner method', APP, 'function _pluginsDiscover(')
  notContains('docs have no public rescan command', DOCS, 'vb-shell appLauncher rescan')
  notContains('docs have no public discover command', DOCS, 'vb-shell appLauncher plugin discover')
  contains('plugin command help points at list', C.findRow('appLauncher.plugin.command').notes[0],
    "'vb-shell appLauncher plugin list'")
})

finish()
