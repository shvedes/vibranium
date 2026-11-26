#!/usr/bin/env node
// Suite: AudioNodeKind / AudioIpc - the shared audio classification and the
// typed IPC projections. Both are `.pragma library` files, so the qmlloader
// harness drives them with no Qt engine and no live PipeWire graph.
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, finish, SHELL_DIR } from '../../lib/assert.mjs'

const K = loadLib(path.join(SHELL_DIR, 'common/audio/AudioNodeKind.js'))
const I = loadLib(path.join(SHELL_DIR, 'services/audio/AudioIpc.js'))

function node(over, props) {
  return Object.assign({
    id: 7, name: 'alsa_output', isSink: true, isStream: false,
    description: 'Built-in', properties: props || {}
  }, over || {})
}

suite('audio-node-kind', 'one classifier for the mixer and the audio IPC surface')

section('classification')

group('the two documented booleans decide the row', () => {
  eq('sink device', K.classify(node({ isSink: true, isStream: false })), 'outputDevice')
  eq('source device', K.classify(node({ isSink: false, isStream: false })), 'inputDevice')
  eq('playback', K.classify(node({ isSink: true, isStream: true })), 'playbackStream')
  eq('capture', K.classify(node({ isSink: false, isStream: true })), 'captureStream')
  eq('no flags is not a row', K.classify({}), null)
  eq('a flag read that throws is not a row', K.classify({
    get isSink() { throw new Error('dead') }, isStream: false
  }), null)
})

group('shell taps and application streams', () => {
  eq('a shell-named tap with no application is filtered', K.isShellTap(node({
    name: 'quickshell', isSink: false, isStream: true
  })), true)
  eq('a shell-named tap with the capture class is filtered', K.isShellTap(node({
    name: 'quickshell.1', isSink: false, isStream: true
  }, { 'application.name': 'Quickshell Peak Detect', 'media.class': 'Stream/Input/Audio' })), true)
  eq('an application capture stream is kept', K.isApplicationStream(node({
    name: 'firefox', isSink: false, isStream: true
  }, { 'media.class': 'Stream/Input/Audio' })), true)
  eq('an unnamed third-party stream is kept', K.isApplicationStream(node({
    name: 'plugin-filter', isSink: false, isStream: true
  })), true)
})

group('flags and labels', () => {
  eq('a virtual media class', K.virtual(node({}, { 'media.class': 'Audio/Sink/Virtual' })), true)
  eq('a virtual node property string', K.virtual(node({}, { 'node.virtual': 'true' })), true)
  eq('a real device', K.virtual(node()), false)
  eq('a monitor is only a suffix', K.monitor(node({ name: 'alsa_output.monitor' })), true)
  eq('an id never becomes a label', K.label(node({ name: '', description: '', id: 9 })), '')
  eq('nickname wins', K.label(node({ nickname: 'Desk', description: 'Other' })), 'Desk')
  eq('no application name is null', K.appNameOrNull(node({ isSink: true, isStream: true })), null)
  eq('the application name is projected', K.appNameOrNull(node({ isSink: true, isStream: true },
    { 'application.name': 'mpv' })), 'mpv')
})

section('typed projections')

group('device rows carry no raw identities', () => {
  const row = I.deviceRow(node({ id: 5 }), 'n1.2', 'outputDevice', true, false)
  eq('all fields', Object.keys(row), ['id', 'name', 'direction', 'virtual', 'monitor',
    'default', 'configuredDefault', 'percent', 'muted'])
  eq('opaque id', row.id, 'n1.2')
  eq('direction', row.direction, 'output')
  eq('percent from the fraction', row.percent, 0)
  eq('effective default', row.default, true)
  eq('a null node is not a row', I.deviceRow(null, 'n1.3', 'outputDevice', false, false), null)
})

group('app rows keep multiple streams distinct', () => {
  const one = I.appRow(node({ id: 5, name: 'mpv' }, { 'application.name': 'mpv' }), 'n1.2', 'playbackStream')
  const two = I.appRow(node({ id: 6, name: 'mpv' }, { 'application.name': 'mpv' }), 'n1.3', 'playbackStream')
  eq('same app, two refs', [one.app, one.id, two.id], ['mpv', 'n1.2', 'n1.3'])
  eq('a non-stream is not an app row', I.appRow(node(), 'n1.4', 'outputDevice'), null)
  eq('rows sort by name then ref', I.sortRows([two, one]).map(r => r.id), ['n1.2', 'n1.3'])
})

group('steps and levels', () => {
  eq('default step is a fraction', I.stepFraction(undefined, 0.05), 0.05)
  eq('explicit step is percentage points', I.stepFraction(10, 0.05), 0.1)
  eq('zero step is refused', I.stepFraction(0, 0.05), null)
  eq('over-cap step is refused', I.stepFraction(201, 0.05), null)
  eq('a fractional step is refused', I.stepFraction(1.5, 0.05), null)
  const audio = { volume: 1.4, muted: true }
  K.applyVolume(audio, 0, 1.5)
  eq('zero keeps the explicit mute', [audio.volume, audio.muted], [0, true])
  K.applyVolume(audio, 0.3, 1.5)
  eq('a positive write lifts the mute', [audio.volume, audio.muted], [0.3, false])
  eq('a level is read back', I.levelOf({ audio: audio }), { percent: 30, muted: false })
})

group('status additions keep the old fields', () => {
  const s = I.statusFields(0.5, false, 0.25, true, 0.05, 1, 2, true, false, '', true, 'n1.1', 'n1.2')
  eq('fractional levels survive', [s.sinkVolume, s.sourceVolume], [0.5, 0.25])
  eq('percent fields added', [s.sinkPercent, s.sourcePercent], [50, 25])
  eq('defaults are opaque refs', [s.sink, s.source], ['n1.1', 'n1.2'])
  eq('graph readiness', s.graphReady, true)
})

finish()
