#!/usr/bin/env node
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, deepEqual, finish } from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const L = loadLib(path.join(SHELL, 'common', 'audio', 'AudioLoopback.js'))

suite('common/audio/AudioLoopback', 'persistent default-device loopback planning and graph reconciliation')

section('channel pairing')
const planned = L.plan('mic', 'speaker',
  'mic:capture_FL\nmic:capture_FR\n',
  'speaker:playback_FL\nspeaker:playback_FR\n')
eq('stereo capture ports map to matching playback channels', planned.error, '')
deepEqual('stereo pairs retain exact argv port paths', planned.pairs, [
  { output: 'mic:capture_FL', input: 'speaker:playback_FL' },
  { output: 'mic:capture_FR', input: 'speaker:playback_FR' },
])
group('unsafe and incomplete layouts are refused', () => {
  eq('wildcard device names are refused', L.plan('mic*', 'speaker', 'mic*:capture_FL', 'speaker:playback_FL').pairs.length, 0)
  eq('mismatched channels do not create a partial route', L.plan('mic', 'speaker',
    'mic:capture_FL\nmic:capture_FR', 'speaker:playback_FL').pairs.length, 0)
})

section('PipeWire link table')
const links = L.parseLinks([
  '71 speaker:playback_FL',
  '95   |<-   58 mic:capture_FL',
  '58 mic:capture_FL',
  '95   |->   71 speaker:playback_FL',
].join('\n'))
deepEqual('direction and duplicate link rows resolve to one port pair', links, [
  { id: '95', output: 'mic:capture_FL', input: 'speaker:playback_FL' },
])
const nodes = [{ id: 21, name: 'mic' }, { id: 34, name: 'speaker' }]
deepEqual('link endpoints resolve to stable node identities', L.identifyLinks(links, nodes), [
  { id: '95', sourceId: '21', sinkId: '34', output: 'mic:capture_FL', input: 'speaker:playback_FL' },
])

section('owned route recovery')
const persisted = L.routesForDefault(planned.pairs, '21', '34')
eq('valid route records survive cache validation', L.validRoutes(persisted).length, 2)
const goneSink = L.routesForDefault(planned.pairs, '21', '35')
const currentGraph = L.identifyLinks(links, nodes)
eq('only the old persisted pair is removed after a default switch',
  L.removalSteps(currentGraph, persisted, goneSink).length, 2)
eq('already linked desired routes do not get duplicated',
  L.connectionSteps(currentGraph, persisted, persisted).length, 0)
eq('explicit unlink commands remove only owned pairs',
  L.applyCommand(persisted, { argv: ['pw-link', '-d', persisted[0].output, persisted[0].input] }, [])
    .length, 1)

finish()
