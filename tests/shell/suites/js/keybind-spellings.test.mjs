#!/usr/bin/env node
// Suite: shipped keybinds use the rearranged CLI spellings, with no retired
// audio verbs left in either binding file or its comments.
import fs from 'node:fs'
import path from 'node:path'
import { suite, section, group, eq, contains, notContains, finish, SHELL_DIR } from '../../lib/assert.mjs'

const ROOT_DIR = path.dirname(SHELL_DIR)
const read = (...parts) => fs.readFileSync(path.join(ROOT_DIR, ...parts), 'utf8')
const DEFAULT = read('default', 'hypr', 'binds.lua')
const USER = read('config', 'hypr', 'hyprland.conf.d', 'binds.lua')

suite('keybind-spellings', 'audio keybinds use the nested verbs')

section('default binds')
group('volume and microphone keys', () => {
  for (const verb of ['audio.volume.down', 'audio.volume.up', 'audio.volume.toggle',
    'audio.microphone.toggle', 'microphone set N', 'microphone down/microphone up']) {
    contains(`default binds use or teach ${verb}`, DEFAULT, verb)
  }
  for (const retired of ['audio volumeDown', 'audio volumeUp', 'audio volumeToggle',
    'audio micToggle', 'audio micUp', 'audio micDown', 'audio set mic']) {
    notContains(`default binds retire ${retired}`, DEFAULT, retired)
  }
})

section('user binds')
group('microphone key', () => {
  contains('uses microphone toggle', USER, 'Hypr.Helpers.BindShell(mainMod .. " + M", "audio.microphone.toggle"')
  contains('teaches microphone set', USER, 'vb-shell audio microphone set N')
  for (const retired of ['micToggle', 'micDown/micUp', 'audio set mic']) {
    notContains(`user binds retire ${retired}`, USER, retired)
  }
})

section('shell shortcuts')
const router = read('shell', 'common', 'bus', 'IpcRouter.qml')
for (const config of [DEFAULT, USER]) {
  notContains('avoids spawning the CLI from a keybind', config, 'exec_raw("vb-shell ')
  for (const [, action] of config.matchAll(/Hypr\.Helpers\.BindShell\(\s*[^\n,]+,\s*"([^"]+)"/g)) {
    contains(`router allows ${action}`, router, `"${action}": [`)
  }
}
