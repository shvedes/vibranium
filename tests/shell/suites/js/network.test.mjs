#!/usr/bin/env node
// Suite: the network island's connected-row suffix and subtext.
//
// ssidWithStatus keeps the whole "SSID • verdict" line in one
// Text so the suffix survives elision glued to the name. The verdict word
// comes from linkNoteText and the ink from the caller; both are pinned
// here, including the unknown-verdict silence. subtextFor carries the
// saved marker for remembered networks instead.
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, contains, notContains, finish,
} from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const NM = loadLib(path.join(SHELL, 'features/bar/modules/Network/Model.js'))

suite('network-display', 'Model.ssidWithStatus, Model.linkNoteText, Model.subtextFor')

const ACCENT = '#aaccff'
const DOT = '#888888'
const INK = '#ffff00'

// ---------------------------------------------------------------------------
section('linkNoteText - the verdict vocabulary')

group('one lowercase word per watch verdict', () => {
  eq('portal', NM.linkNoteText('portal'), 'login required')
  eq('offline', NM.linkNoteText('offline'), 'no internet')
  eq('metered', NM.linkNoteText('metered'), 'metered')
  eq('configuring', NM.linkNoteText('configuring'), 'configuring...')
  eq('empty is silent', NM.linkNoteText(''), '')
  eq('unknown is silent', NM.linkNoteText('roaming'), '')
  eq('missing is silent', NM.linkNoteText(), '')
  eq('null is silent', NM.linkNoteText(null), '')
})

// ---------------------------------------------------------------------------
section('ssidWithStatus - the verdict dot')

group('a connected row carries the verdict after a single dot', () => {
  const line = NM.ssidWithStatus('Home', true, ACCENT, DOT, 'portal', INK)
  contains('the ssid', line, 'Home')
  contains('the verdict in its ink', line, `<font color="${INK}">login required</font>`)
  eq('one dot', line.split('•').length - 1, 1)
})

group('no verdict is the bare name', () => {
  const plain = NM.ssidWithStatus('Home', true, ACCENT, DOT)
  eq('shape', plain, 'Home')
  eq('an empty verdict', NM.ssidWithStatus('Home', true, ACCENT, DOT, '', INK), plain)
  eq('an unknown verdict', NM.ssidWithStatus('Home', true, ACCENT, DOT, 'roaming', INK), plain)
})

group('a missing ink falls back to the dot tone', () => {
  contains('undefined ink', NM.ssidWithStatus('Home', true, ACCENT, DOT, 'metered'), `<font color="${DOT}">metered</font>`)
  contains('empty ink', NM.ssidWithStatus('Home', true, ACCENT, DOT, 'metered', ''), `<font color="${DOT}">metered</font>`)
})

group('the ssid stays escaped under a verdict', () => {
  contains('a hostile ssid', NM.ssidWithStatus('<b>x</b>', true, ACCENT, DOT, 'offline', INK), '&lt;b&gt;x&lt;/b&gt;')
})

group('disconnected rows are the bare name, verdict or not', () => {
  eq('no saved suffix anymore', NM.ssidWithStatus('Home', false, ACCENT, DOT, 'portal', INK), 'Home')
  eq('plain', NM.ssidWithStatus('Home', false, ACCENT, DOT, 'metered', INK), 'Home')
})

group('subtextFor carries the saved marker', () => {
  eq('remembered and down', NM.subtextFor({ signal: 80, securityLabel: 'WPA2', known: true, connected: false }), '80% signal · WPA2 · saved')
  eq('not while active', NM.subtextFor({ signal: 80, securityLabel: 'WPA2', known: true, connected: true }), '80% signal · WPA2')
  eq('not for unknown networks', NM.subtextFor({ signal: 80, securityLabel: 'WPA2' }), '80% signal · WPA2')
})

group('shouldDiscardSecrets drops only a fresh secret on credential failure', () => {
  const R = { NoSecrets: 1, WifiAuthTimeout: 4, WifiNetworkLost: 5, WifiClientDisconnected: 2, WifiClientFailed: 3 }
  eq('wrong password on a fresh submit', NM.shouldDiscardSecrets('connect', true, 4, R), true)
  eq('missing secrets on a fresh submit', NM.shouldDiscardSecrets('connect', true, 1, R), true)
  eq('a lost network keeps the profile', NM.shouldDiscardSecrets('connect', true, 5, R), false)
  eq('a disconnect keeps the profile', NM.shouldDiscardSecrets('connect', true, 2, R), false)
  eq('a saved profile is never deleted', NM.shouldDiscardSecrets('connect', false, 4, R), false)
  eq('only connects count', NM.shouldDiscardSecrets('forget', true, 4, R), false)
  eq('missing flag keeps the profile', NM.shouldDiscardSecrets('connect', false, 4, R), false)
})

group('a freshly typed secret that NM rejects reads as wrong password', () => {
  const R = { NoSecrets: 1, WifiAuthTimeout: 4, WifiNetworkLost: 5 }
  eq('NoSecrets on a fresh submit', NM.failureReasonText(1, R, true), 'Wrong password')
  eq('auth timeout on a fresh submit', NM.failureReasonText(4, R, true), 'Wrong password')
  eq('NoSecrets without the flag stays put', NM.failureReasonText(1, R), 'Passphrase required')
  eq('a lost network is not a password problem', NM.failureReasonText(5, R, true), 'Network lost')
})

group('the wrong-password toast is urgent and expiring', () => {
  const argv = NM.authFailureArgv('MyWifi')
  eq('the sender', argv[0], 'notify-send')
  eq('critical urgency', argv[argv.indexOf('-u') + 1], 'critical')
  eq('expiring, the row owns the persistence', argv[argv.indexOf('-t') + 1], '8000')
  eq('the Pass lock icon', argv[argv.indexOf('-n') + 1], 'lock')
  contains('the adoption tag', argv, 'string:x-vb-tag:vb-network-auth')
  contains('no print-id: nothing to close', argv.includes('-p'), false)
  eq('the summary', argv[argv.length - 2], 'Wrong password')
  contains('the name in bold', argv, '<b>MyWifi</b>')
  eq('nameless falls back', NM.authFailureArgv()[NM.authFailureArgv().length - 1], 'The password was incorrect.')
  const hostile = NM.authFailureArgv('<b>x</b>')
  notContains('no live tag rides it', hostile, '<b>x</b>')
})

finish()
