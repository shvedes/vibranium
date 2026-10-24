#!/usr/bin/env node
// Suite: features/apps/audioMixer/MixerModel.js - what a node IS, what a row is
// CALLED, what a level prints as, and the Pulse `list` parser that turns the
// daemon's own indices into PipeWire node ids.
//
// A `.pragma library` with no Qt imports and no host object, so every claim in
// it is a claim about plain values: two booleans, a property map, and a
// string. Four contracts live here, and each is the difference between a row
// that is right and a row that acts on the wrong object:
//
//   classify            four rows out of the two booleans the API documents,
//                       and null for everything else - a guessed row would
//                       write a volume onto whatever node it landed next to
//   label / iconName    a fallback order, with the client-chosen node name last
//                       because that is the string a filter chain publishes
//   volumeText          a mute prints no percentage, and a percent string that
//   parsePercent        is not one is refused rather than coerced
//   parsePulseObjects   five maps keyed by `object.id`, which is the only join
//                       between a PipeWire node id and a daemon index
//
// The parser section runs against a fixture committed in this file. There is no
// daemon read, no child process and no network here, so the suite answers the
// same on a host with no PipeWire as it does on one that has a graph running.

import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite,
  section,
  group,
  eq,
  is,
  deepEqual,
  noThrow,
  skip,
  show,
  finish,
} from '../../lib/assert.mjs'

// The shell tree, resolved from this file's own location the way
// collections.test.mjs does. `SHELL_DIR` in the kit climbs four levels out of
// tests/shell/lib and lands beside the repo rather than in it, so a suite that
// used it would not find the library at all.
const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const M = loadLib(path.join(SHELL, 'features', 'apps', 'audioMixer', 'MixerModel.js'))

// A node with both boolean flags present and nothing else. classify() is
// documented as reading those two fields only, so this is the whole input the
// four-row table needs.
const NODE = (sink, stream, extra) => ({ isSink: sink, isStream: stream, ...extra })

suite(
  'features/apps/audioMixer/MixerModel',
  'node classification, labels, levels, the Pulse list parser',
)

// ---------------------------------------------------------------------------
section('classify - four rows from two booleans, and null for the rest')
// ---------------------------------------------------------------------------
group('the four combinations land in four different rows', () => {
  // The library's own table, which is also the tab split: a sink that is not a
  // stream is an output device, a source that is not a stream is an input
  // device, and isStream is what moves a node from the device tab to the stream
  // list under it.
  eq('isSink and isStream is a playback stream', M.classify(NODE(true, true)), 'playbackStream')
  eq('isSink alone is an output device', M.classify(NODE(true, false)), 'outputDevice')
  eq('isStream alone is a capture stream', M.classify(NODE(false, true)), 'captureStream')
  eq('neither is an input device', M.classify(NODE(false, false)), 'inputDevice')
  // Four distinct answers, so a row cannot be labelled by a kind that belongs
  // to another row.
  is('the four rows are four distinct strings', [
    M.classify(NODE(true, true)),
    M.classify(NODE(true, false)),
    M.classify(NODE(false, true)),
    M.classify(NODE(false, false)),
  ], (kinds) => new Set(kinds).size === 4, 'four distinct kinds')
})

group('classification reads the two booleans and nothing else', () => {
  // `type` is a flags value the API publishes, and a flag word read as a string
  // and substring-matched is how a node lands in the wrong row. The header says
  // it is not read at all, so a node whose type contradicts its flags classifies
  // by the flags.
  eq('a contradicting type string does not change the row', M.classify(NODE(false, true, { type: 'Sink' })), 'captureStream')
  eq('a flags number does not change the row either', M.classify(NODE(true, false, { type: 0x20 })), 'outputDevice')
  eq('a node carrying every other field still classifies', M.classify(NODE(true, true, {
    id: 310,
    nickname: 'Chromium',
    name: 'Chromium',
    properties: { 'media.name': 'Song' },
  })), 'playbackStream')
})

group('a node that cannot be placed is null, never a guess', () => {
  // null is a real answer here rather than a failure: a dropped node is invisible
  // in the mixer, while a guessed row would act on a node the user never picked.
  eq('null', M.classify(null), null)
  eq('undefined', M.classify(undefined), null)
  eq('an object with no flags at all', M.classify({}), null)
  eq('one flag of two', M.classify({ isSink: true }), null)
  eq('the other flag alone', M.classify({ isStream: true }), null)
  // The gate is `typeof === "boolean"`, so anything a truthiness check would
  // accept is refused here: a 0 is not a false, it is a number.
  eq('a string-valued flag', M.classify({ isSink: 'true', isStream: false }), null)
  eq('a numeric flag', M.classify({ isSink: 1, isStream: 0 }), null)
  eq('a null flag', M.classify({ isSink: null, isStream: true }), null)
  eq('a flag read as undefined on a present object', M.classify({ isSink: undefined, isStream: true }), null)
  // A node whose flag read throws is a destroyed handle, which is the same
  // answer: a binding must not fault on it.
  eq('a node whose flag read throws', M.classify({
    get isSink() { throw new Error('handle deleted') },
    isStream: false,
  }), null)
  // The two kind predicates read a null as "not a kind", so a caller that
  // branches on the predicate after a null classification takes the drop path
  // rather than the device path.
  eq('a null kind is not a device kind', M.isDeviceKind(null), false)
  eq('a null kind is not a stream kind', M.isStreamKind(null), false)
})

group('the kind predicates split the four rows the way the tabs do', () => {
  eq('the device rows', [M.isDeviceKind('outputDevice'), M.isDeviceKind('inputDevice')], [true, true])
  eq('the stream rows', [M.isStreamKind('playbackStream'), M.isStreamKind('captureStream')], [true, true])
  eq('a device row is not a stream', M.isStreamKind('outputDevice'), false)
  eq('a stream row is not a device', M.isDeviceKind('captureStream'), false)
  // Both vocabularies are closed and exact, so a misspelled or invented kind is
  // refused rather than drawn as a row of its own.
  eq('a near-miss spelling', M.isDeviceKind('outputdevice'), false)
  eq('an unknown kind', M.isDeviceKind('device'), false)
  eq('the empty string', M.isDeviceKind(''), false)
  eq('undefined', M.isStreamKind(undefined), false)
  eq('a number', M.isStreamKind(1), false)
})

// ---------------------------------------------------------------------------
section('labels - a fallback order, with the client-chosen name last')
// ---------------------------------------------------------------------------
group('the display name takes the first rung that carries text', () => {
  // The order is nickname, then the hardware description, then the media name,
  // then the node's own name. The first three are things the driver or the
  // media stack wrote; the fourth is what the application chose to call itself.
  eq('a nickname wins', M.label(NODE(true, false, {
    nickname: 'Speakers',
    description: 'Built-in Audio Analog Stereo',
    properties: { 'media.name': 'System Sounds' },
    name: 'alsa_output.pci-0000_00_1f.3.analog-stereo',
  })), 'Speakers')
  eq('a blank nickname falls through to the description', M.label(NODE(true, false, {
    nickname: '',
    description: 'Built-in Audio Analog Stereo',
    properties: { 'media.name': 'System Sounds' },
    name: 'alsa_output.pci-0000_00_1f.3.analog-stereo',
  })), 'Built-in Audio Analog Stereo')
  eq('a blank description falls through to the media name', M.label(NODE(true, false, {
    nickname: '',
    description: '',
    properties: { 'media.name': 'System Sounds' },
    name: 'alsa_output.pci-0000_00_1f.3.analog-stereo',
  })), 'System Sounds')
  eq('with nothing above it, the node name is the label', M.label(NODE(true, false, {
    nickname: '',
    description: '',
    properties: {},
    name: 'alsa_output.pci-0000_00_1f.3.analog-stereo',
  })), 'alsa_output.pci-0000_00_1f.3.analog-stereo')
  // Every rung is trimmed, so a name the daemon printed with padding does not
  // render as a row with a leading space.
  eq('a padded nickname is trimmed', M.label(NODE(true, false, { nickname: '  Desk speakers  ', description: 'x' })), 'Desk speakers')
  eq('whitespace alone is not a name', M.label(NODE(true, false, { nickname: '   ', description: 'Real' })), 'Real')
  eq('a padded description is trimmed', M.label(NODE(true, false, { nickname: '', description: '  Built-in  ' })), 'Built-in')
  eq('a padded node name is trimmed', M.label(NODE(true, false, { name: '  alsa_output  ' })), 'alsa_output')
})

group('a rung that is not a string is skipped like an empty one', () => {
  // A PipeWire string property is a string and a deleted QObject reads as
  // undefined, so both have to fall through rather than print "undefined".
  eq('a numeric nickname', M.label(NODE(true, false, { nickname: 7, description: 'Real' })), 'Real')
  eq('a null nickname', M.label(NODE(true, false, { nickname: null, description: 'Real' })), 'Real')
  eq('a numeric media name in the property map', M.label(NODE(true, false, {
    properties: { 'media.name': 42 },
    name: 'alsa_output',
  })), 'alsa_output')
  eq('a non-string property map', M.label(NODE(true, false, { properties: null, name: 'alsa_output' })), 'alsa_output')
  eq('a property map that is not an object at all', M.label(NODE(true, false, { properties: 'x', name: 'alsa_output' })), 'alsa_output')
  // The graph id is not a name. A row labelled "95" would be a node id printed
  // as if the user had named it, which is graph state rather than a label.
  eq('a node with only an id has no label', M.label(NODE(true, false, { id: 95 })), '')
  eq('and the id does not become one either', M.label(NODE(true, false, { id: '95', name: 5 })), '')
})

group('a node with nothing to name it answers ""', () => {
  // "" is the documented answer, and it is what a row binds a glyph to when
  // there is no text to show.
  eq('an empty object', M.label({}), '')
  eq('null', M.label(null), '')
  eq('undefined', M.label(undefined), '')
  eq('a numeric node name', M.label({ name: 42 }), '')
  eq('a whitespace-only node name', M.label({ name: '   ' }), '')
  // A node whose field read throws is a deleted handle. The label is a string in
  // a QML binding, so a throw here would be a warning on stderr and an
  // undefined row on screen.
  eq('a node whose nickname read throws', M.label({
    get nickname() { throw new Error('handle deleted') },
    description: 'Real',
  }), '')
  eq('a node whose property read throws', M.label({
    nickname: '',
    description: '',
    name: 'alsa_output',
    get properties() { throw new Error('handle deleted') },
  }), 'alsa_output')
})

group('the app name asks who is playing, in the stream-shaped order', () => {
  // This is the primary line of a stream row and `label()` is its last resort,
  // so the two share a vocabulary: application.name, then media.name, then the
  // same four-rung label().
  eq('the application name wins', M.appName(NODE(true, true, {
    properties: { 'application.name': 'Firefox', 'media.name': 'Sound Tab' },
  })), 'Firefox')
  eq('a blank application name falls through to the media name', M.appName(NODE(true, true, {
    properties: { 'application.name': '', 'media.name': 'Sound Tab' },
  })), 'Sound Tab')
  eq('with neither property, the label order takes over', M.appName(NODE(true, true, {
    properties: {},
    nickname: 'Speakers',
  })), 'Speakers')
  eq('and the label order reaches the node name last', M.appName(NODE(true, true, {
    properties: {},
    name: 'alsa_input.usb-microphone',
  })), 'alsa_input.usb-microphone')
  // media.title is what is playing, not who is playing it, so it is not an app
  // name.
  eq('a media title is not an app name', M.appName(NODE(true, true, { properties: { 'media.title': 'A Song' } })), '')
  eq('null', M.appName(null), '')
  eq('an empty object', M.appName({}), '')
})

group('a media name never falls back to node.name', () => {
  // The deliberate rule, stated in the header: `node.name` is client-supplied
  // text and is also the string a filter chain publishes, so the secondary line
  // answers "" rather than filling itself with an application-chosen token.
  eq('the media name is preferred', M.mediaName(NODE(true, true, {
    properties: { 'media.name': 'Sound Tab', 'media.title': 'A Song' },
  })), 'Sound Tab')
  eq('a media title is the second rung', M.mediaName(NODE(true, true, {
    properties: { 'media.name': '', 'media.title': 'A Song' },
  })), 'A Song')
  eq('a node name is never a media name', M.mediaName(NODE(true, true, {
    properties: {},
    name: 'Chromium',
  })), '')
  eq('a nickname is never a media name', M.mediaName(NODE(true, true, {
    properties: {},
    nickname: 'Speakers',
  })), '')
  eq('a description is never a media name', M.mediaName(NODE(true, true, { description: 'Built-in' })), '')
  eq('null', M.mediaName(null), '')
  eq('an empty object', M.mediaName({}), '')
})

group('the icon name reads client data, then device data, then the graph class', () => {
  // Ordered so the most specific answer wins: what the application chose for
  // itself, then what the driver chose for the device, then the graph's own
  // class, and only then the node's own name. The result is a NAME, not a path,
  // so the caller resolves it through the shell icon set and a miss degrades to
  // the generic glyph rather than to a broken image.
  eq('the application icon name wins', M.iconName(NODE(true, true, {
    properties: {
      'application.icon_name': 'firefox',
      'device.icon_name': 'audio-headphones',
      'media.class': 'Stream/Output/Audio',
    },
  })), 'firefox')
  // The daemon spells this key both ways depending on the driver, so both
  // spellings are candidates rather than one being a near-miss refusal.
  eq('the dashed spelling is the same candidate', M.iconName(NODE(true, true, {
    properties: { 'application.icon-name': 'firefox', 'device.icon_name': 'audio-headphones' },
  })), 'firefox')
  eq('the device icon name is the next candidate', M.iconName(NODE(true, true, {
    properties: {
      'application.icon_name': '',
      'device.icon_name': 'audio-headphones',
      'media.class': 'Stream/Output/Audio',
    },
  })), 'audio-headphones')
  eq('the dashed device spelling too', M.iconName(NODE(true, true, {
    properties: { 'device.icon-name': 'audio-headphones' },
  })), 'audio-headphones')
  // The class is the only candidate that is correct for a node with no
  // application behind it - a device row has no client of its own.
  eq('a sink class becomes the speaker glyph', M.iconName(NODE(true, false, {
    properties: { 'media.class': 'Audio/Sink' },
  })), 'speaker')
  eq('a playback stream class becomes the music glyph', M.iconName(NODE(true, true, {
    properties: { 'media.class': 'Stream/Output/Audio' },
  })), 'music')
  eq('a capture stream class becomes the mic glyph', M.iconName(NODE(false, true, {
    properties: { 'media.class': 'Stream/Input/Audio' },
  })), 'mic-on')
  eq('a source class becomes the mic glyph', M.iconName(NODE(false, false, {
    properties: { 'media.class': 'Audio/Source' },
  })), 'mic-on')
  eq('a link class becomes the link glyph', M.iconName(NODE(false, false, {
    properties: { 'media.class': 'Sink/Input/Audio' },
  })), 'link')
  eq('and the other link spelling', M.iconName(NODE(false, false, {
    properties: { 'media.class': 'Source/Output/Audio' },
  })), 'link')
})

group('a class nobody matches falls through instead of guessing a glyph', () => {
  eq('an unmapped class with a node name uses the name', M.iconName(NODE(true, true, {
    properties: { 'media.class': 'Stream/Video/Audio' },
    name: 'mpv',
  })), 'mpv')
  eq('an unmapped class with nothing else names no icon', M.iconName(NODE(true, true, {
    properties: { 'media.class': 'Stream/Video/Audio' },
  })), '')
  eq('the map is a closed vocabulary', M.iconForMediaClass('Nope'), '')
  eq('a case variant is not in it', M.iconForMediaClass('audio/sink'), '')
  eq('an unpadded class is not in it', M.iconForMediaClass(' Audio/Sink '), '')
  eq('null is not in it', M.iconForMediaClass(null), '')
  eq('a number is not in it', M.iconForMediaClass(5), '')
  eq('null node', M.iconName(null), '')
})

group('the node name is the last icon candidate, normalised to a bare token', () => {
  // The direction suffix is dropped and the leading segment is kept, because
  // that segment is the application's own token: "firefox.monitor" is
  // "firefox", and the long name a browser publishes becomes its lower-case
  // form so the icon set can answer it.
  eq('the direction suffix is stripped', M.iconName({ name: 'alsa_output.pci-0000_00_1f.3.analog-stereo' }), 'alsa_output')
  eq('a browser stream name is lower-cased', M.iconName({ name: 'Chromium Web Content' }), 'chromium web content')
  eq('the suffix and the case both go', M.iconName({ name: 'FireFox.Playback' }), 'firefox')
  // A name with no dot at all keeps its whole text, so a plain token is not
  // truncated to nothing.
  eq('a name with no dot is kept whole', M.iconName({ name: 'mpv' }), 'mpv')
  eq('an empty node name names no icon', M.iconName({ name: '' }), '')
  eq('a whitespace-only node name names no icon', M.iconName({ name: '   ' }), '')
  eq('a name that is only a suffix names no icon', M.iconName({ name: '.mono' }), '')
  eq('a monitor name names no icon', M.iconName({ name: 'alsa_output.monitor' }), '')
  // The monitor's glyph belongs to the device it watches, so a `.monitor` name
  // yields "" rather than an icon named after the node it duplicates.
  eq('a monitor name is refused even with a leading segment', M.iconName({ name: 'firefox.monitor' }), '')
  eq('null', M.iconName(null), '')
  eq('undefined', M.iconName(undefined), '')
})

group('a device with no media class but a driver description gets the generic glyph', () => {
  // device.class is what says "this is hardware", and the description is what
  // says the class glyph would be wrong for a device nobody named - a paired
  // headset has no media class and no application, so an absent icon reads as
  // a broken row rather than as hardware.
  eq('a device class with no description is headphones', M.iconName(NODE(true, false, {
    properties: { 'device.class': 'sound' },
  })), 'headphones')
  eq('a description takes precedence over the generic device glyph', M.iconName(NODE(true, false, {
    properties: { 'device.class': 'sound' },
    description: 'Built-in Audio',
  })), '')
  eq('without a device class there is nothing to key the glyph on', M.iconName(NODE(true, false, {
    properties: { 'media.class': '' },
  })), '')
  // An application icon still wins over the generic device glyph.
  eq('an application icon beats the generic device glyph', M.iconName(NODE(true, false, {
    properties: { 'device.class': 'sound', 'application.icon_name': 'firefox' },
  })), 'firefox')
})

group('isMonitorName is the one suffix rule both callers read', () => {
  // PipeWire makes one node object per monitor and names it after the device it
  // watches with a `.monitor` suffix. The icon fallback uses it to refuse a
  // duplicate glyph; the parser uses it to split a source from its monitor.
  // Both answers come from this function, so both change together.
  eq('a monitor name', M.isMonitorName('alsa_output.pci-0000_00_1f.3.analog-stereo.monitor'), true)
  eq('a padded monitor name', M.isMonitorName('  alsa_output.monitor  '), true)
  eq('a bare suffix', M.isMonitorName('.monitor'), true)
  eq('the device name itself', M.isMonitorName('alsa_output'), false)
  eq('a name that only starts like one', M.isMonitorName('monitoring'), false)
  eq('a name that ends near one', M.isMonitorName('monitor2'), false)
  eq('an empty string', M.isMonitorName(''), false)
  eq('null', M.isMonitorName(null), false)
  eq('undefined', M.isMonitorName(undefined), false)
  eq('a number', M.isMonitorName(5), false)
})

// ---------------------------------------------------------------------------
section('levels - a percentage on the way out, a number on the way back')
// ---------------------------------------------------------------------------
group('a level prints as a whole percentage', () => {
  eq('unity volume', M.percentText(1), '100%')
  eq('a fraction of unity', M.percentText(0.42), '42%')
  eq('silence', M.percentText(0), '0%')
  eq('a tiny fraction rounds down', M.percentText(0.004), '0%')
  eq('a tiny fraction rounds up', M.percentText(0.005), '1%')
  eq('just under unity', M.percentText(0.999), '100%')
  eq('a negative level keeps its sign', M.percentText(-0.5), '-50%')
  eq('a negative fraction that rounds to zero loses the sign', M.percentText(-0.004), '0%')
})

group('an over-unity level is not clamped to a hundred', () => {
  // A mixer row can be above unity - a filter chain raises a stream's gain, and
  // a device with headroom accepts it. Printing 100% there would be a claim the
  // mixer is not making, and it would hide the level the user set.
  eq('half over unity', M.percentText(1.5), '150%')
  eq('double unity', M.percentText(2), '200%')
  eq('an unrepresentable multiplier is still printed', M.percentText(100), '10000%')
  eq('and the row reads the same way unmuted', M.volumeText(1.5, false), '150%')
})

group('a muted row prints no percentage at all', () => {
  // A percentage beside a mute would be rating a level nobody is hearing, so the
  // mute is the whole readout and the level is not printed next to it.
  eq('a muted half-volume row', M.volumeText(0.42, true), 'Muted')
  eq('a muted over-unity row', M.volumeText(1.5, true), 'Muted')
  eq('a muted silence', M.volumeText(0, true), 'Muted')
  // The mute is the whole answer even when the volume beside it is unusable, so
  // a mute can never print an empty percentage.
  eq('a muted row with an unusable volume', M.volumeText('abc', true), 'Muted')
  eq('a muted row with no volume', M.volumeText(undefined, true), 'Muted')
  // The mute flag is an argument, so a call that passes neither prints no level
  // and names no mute: neither branch is taken from an unassigned argument.
  eq('a row with no arguments at all is blank, not muted', M.volumeText(), '')
  // The flag is `=== true`, so an unassigned mute property does not mute.
  eq('no mute flag at all', M.volumeText(0.42), '42%')
  eq('an undefined mute flag', M.volumeText(0.42, undefined), '42%')
  eq('a false mute flag', M.volumeText(0.42, false), '42%')
  eq('a truthy non-boolean is not a mute', M.volumeText(0.42, 'true'), '42%')
  eq('a numeric one is not a mute either', M.volumeText(0.42, 1), '42%')
})

group('unmuted is exactly the percentage half, so the two cannot disagree', () => {
  // volumeText is percentText plus the mute branch. Sharing the function is the
  // whole point: a row's digits and the digits a caller parses come from one
  // place, so they cannot drift apart.
  for (const v of [0, 0.005, 0.42, 1, 1.5, 2]) {
    eq(`an unmuted ${show(v)} row is percentText(${show(v)})`, M.volumeText(v, false), M.percentText(v))
  }
  eq('and the mute branch is the only difference', [M.volumeText(0.42, true), M.volumeText(0.42, false)], ['Muted', '42%'])
})

group('an unusable level prints nothing rather than NaN%', () => {
  // The readout is a string in a QML binding, so "" is what a row renders as no
  // text. Anything else would put "NaN%" on screen.
  // Named rather than rendered, because show() prints NaN and both infinities as
  // the same "null", and three identical assertion labels would hide which
  // shape each one exercises.
  const notLevels = [
    ['NaN', NaN],
    ['Infinity', Infinity],
    ['-Infinity', -Infinity],
    ['a word', 'abc'],
    ['null', null],
    ['undefined', undefined],
    ['true', true],
    ['an array', []],
    ['an object', {}],
  ]
  for (const [what, v] of notLevels) {
    eq(`${what} is not a level`, M.percentText(v), '')
  }
  eq('and the row inherits that', M.volumeText('abc', false), '')
  // Number() is applied verbatim to a string, so a numeric string is a level and
  // anything else Number() rejects is not. This is the asymmetry with
  // parsePercent below: one coerces and the other refuses.
  eq('a numeric string is a level', M.percentText('0.42'), '42%')
  eq('Number() decides, so a padded string keeps its value', M.percentText(' 42 '), '4200%')
  eq('a percent-suffixed string is not a level to Number()', M.percentText('42%'), '')
  eq('the empty string is zero to Number()', M.percentText(''), '0%')
  eq('a whitespace string is zero to Number()', M.percentText('  '), '0%')
})

group('parsePercent reads back exactly what percentText prints', () => {
  for (const v of [0, 0.42, 1, 1.5, 2]) {
    eq(`"${M.percentText(v)}" parses to ${M.percentText(v).slice(0, -1)}`, M.parsePercent(M.percentText(v)), v * 100)
  }
  eq('the trailing percent sign is optional', M.parsePercent('42'), 42)
  eq('surrounding space is trimmed', M.parsePercent('  42  '), 42)
  eq('space inside the pair is trimmed', M.parsePercent(' 42 % '), 42)
  eq('unity', M.parsePercent('100%'), 100)
  eq('over unity', M.parsePercent('150%'), 150)
  eq('silence', M.parsePercent('0%'), 0)
  eq('leading zeros are a number', M.parsePercent('00042%'), 42)
  eq('a fraction is kept', M.parsePercent('0.5%'), 0.5)
  eq('a signed value is kept', M.parsePercent('-5%'), -5)
  eq('an explicit plus is kept', M.parsePercent('+5%'), 5)
  eq('a negative zero reads as zero', M.parsePercent('-0%'), 0)
})

group('a percent string that is not one is refused, not coerced', () => {
  // The one place a level is read back out of text rather than off the node is
  // the place a wrong answer would be written back as a volume, so every shape
  // the grammar does not cover answers null and leaves the level alone.
  const refused = [
    ['', 'the empty string'],
    ['   ', 'a whitespace-only string'],
    ['%', 'a bare percent sign'],
    [' %', 'a percent sign with nothing before it'],
    ['42%%', 'two percent signs'],
    ['4 2%', 'a space inside the digits'],
    ['4.2.3', 'two decimal points'],
    ['1e3', 'exponent notation'],
    ['.5%', 'a fraction with no leading digit'],
    ['1.', 'a trailing decimal point'],
    ['42 %x', 'trailing text'],
    ['abc', 'a word'],
    ['0x10', 'a hexadecimal literal'],
    ['Infinity', 'a non-number keyword'],
    ['--5%', 'a doubled sign'],
    ['42,5%', 'a decimal comma'],
    ['4\t2%', 'a tab inside the digits'],
    ['42%%', 'a doubled suffix on digits'],
  ]
  for (const [value, what] of refused) {
    eq(`${what} is refused`, M.parsePercent(value), null)
  }
  eq('null is refused', M.parsePercent(null), null)
  eq('undefined is refused', M.parsePercent(undefined), null)
  eq('a number is not a percent string', M.parsePercent(42), null)
  eq('a boolean is not a percent string', M.parsePercent(true), null)
  eq('an object is not a percent string', M.parsePercent({}), null)
  eq('nothing is coerced to zero', M.parsePercent(''), null)
  eq('and a refused read is null, so a caller can branch on it', M.parsePercent('4.2.3'), null)
})

// ---------------------------------------------------------------------------
section('parsePulseObjects - five maps keyed by object.id')
// ---------------------------------------------------------------------------
//
// The join this section exists to pin. The Pulse CLI numbers its own objects
// independently of the graph's: `Sink #1967` is PipeWire node `95`. Nothing in
// the block header carries the graph id, and every block carries
// `object.id = "<pipewire node id>"` in its property tail, so that string is the
// only reliable join between a node id the shell has and an index the daemon
// will accept on the command line. Keying by the header index would produce a
// map that looks plausible and routes every stream into a neighbour.

// One Pulse `list` excerpt, trimmed to the five block kinds the mixer reads,
// two kinds it does not, and one Sink that carries no object.id at all. Written
// as explicit '\t' sequences rather than as a heredoc so the tab indent the
// parser keys on is visible in this file, and so nothing here has to be captured
// from a live daemon to be read.
const FIXTURE_BLOCKS = [
  [
    'Sink #1967',
    '\tState: RUNNING',
    '\tVolume: front-left: 45875 /  70% / -9.79 dB,   front-right: 45875 /  70% / -9.79 dB',
    '\t        balance 0.00',
    '\tSink Source: 1',
    '\tSample Specification: pulse',
    '\tChannel Map: front-left,front-right',
    '\tProperties:',
    '\t\talsa.resolution_bits = "16"',
    '\t\tdevice.class = "sound"',
    '\t\tdevice.description = "Built-in Audio Analog Stereo"',
    '\t\tmedia.class = "Audio/Sink"',
    '\t\tnode.name = "alsa_output.pci-0000_00_1f.3.analog-stereo"',
    '\t\tobject.id = "95"',
    '\t\tobject.serial = "1554382984"',
    '\t\tobject.string = "sink:alsa_output.pci-0000_00_1f.3.analog-stereo"',
  ],
  [
    'Source #1968',
    '\tName: alsa_input.usb-microphone',
    '\tDescription: Built-in Audio Analog Stereo',
    '\tDriver: io1',
    '\tSample Specification: pulse',
    '\tChannel Map: mono',
    '\tVolume: mono: 0 / 0% / -inf dB',
    '\tProperties:',
    '\t\tdevice.class = "sound"',
    '\t\tmedia.class = "Audio/Source"',
    '\t\tnode.name = "alsa_input.usb-microphone"',
    '\t\tobject.id = "128"',
  ],
  // The monitor's header `Name:` carries the `.monitor` suffix while its
  // `node.name` property does not, and its object.id is the sink's own id - the
  // two facts that make the split necessary and that decide it.
  [
    'Source #1969',
    '\tName: alsa_output.pci-0000_00_1f.3.analog-stereo.monitor',
    '\tDescription: Monitor of Built-in Audio Analog Stereo',
    '\tDriver: io1',
    '\tChannel Map: front-left,front-right',
    '\tProperties:',
    '\t\tmedia.class = "Audio/Source"',
    '\t\tnode.name = "alsa_output.pci-0000_00_1f.3.analog-stereo"',
    '\t\tobject.id = "95"',
  ],
  // A Sink Input prints no `Name:` line at all, which is why the node name is
  // read from the property tail too.
  [
    'Sink Input #1970',
    '\tDriver: protocol-native',
    '\tOwner Module: 12',
    '\tClient: 30',
    '\tVolume: mono: 22938 / 35% / -14.55 dB',
    '\tProperties:',
    '\t\tapplication.name = "Chromium"',
    '\t\tapplication.process.binary = "chrome"',
    '\t\tmedia.name = "Sound Tab"',
    '\t\tnode.name = "Chromium"',
    '\t\tobject.id = "310"',
  ],
  // A kind the mixer does not read. It carries an object.id of its own, which is
  // how a walk that did not stop at a header would leak it into the next block.
  [
    'Client #1971',
    '\tOwner Module: 12',
    '\tProperties:',
    '\t\tapplication.name = "Chromium"',
    '\t\tmedia.name = "Sound Tab"',
    '\t\tobject.id = "999"',
  ],
  [
    'Source Output #1972',
    '\tDriver: protocol-native',
    '\tOwner Module: 12',
    '\tClient: 31',
    '\tProperties:',
    '\t\tapplication.name = "Firefox"',
    '\t\tmedia.name = "Mozilla Firefox"',
    '\t\tnode.name = "Firefox"',
    '\t\tobject.id = "417"',
  ],
  [
    'Module #12',
    '\tName: module-native-protocol-pulse',
    '\tProperties:',
    '\t\tobject.id = "555"',
  ],
  // A block with no object.id at all: a header, a name and a property tail
  // that never names the graph object.
  [
    'Sink #1973',
    '\tName: headphones',
    '\tState: RUNNING',
    '\tProperties:',
    '\t\tdevice.class = "sound"',
    '\t\tnode.name = "bluez_output.00_00.1"',
    '\t\tobject.serial = "00000000000000a"',
  ],
]

// Joins the chosen blocks into one capture, blank line between blocks the way
// the daemon prints them.
const fixture = (...bounds) => {
  const [from, to] = bounds.length === 1 ? [0, bounds[0]] : bounds
  return FIXTURE_BLOCKS.slice(from, to).map((b) => b.join('\n')).join('\n\n')
}
const FIXTURE = fixture(0, FIXTURE_BLOCKS.length)
const PULSE = M.parsePulseObjects(FIXTURE)

group('the fixture states the premises the assertions below rely on', () => {
  // Pinning the fixture's own shape means a later edit that breaks a premise
  // fails here, where it is readable, instead of silently weakening a claim
  // somewhere further down.
  const idLines = (block) => block.filter((l) => l.trim().startsWith('object.id'))
  eq('the sink block names one object.id', idLines(FIXTURE_BLOCKS[0]).length, 1)
  eq('and the monitor block names the same one', idLines(FIXTURE_BLOCKS[2]), idLines(FIXTURE_BLOCKS[0]))
  eq('only the monitor header Name field carries the suffix', FIXTURE_BLOCKS[2][1].endsWith('.monitor'), true)
  eq('and no node.name property in that block does', FIXTURE_BLOCKS[2].some((l) => l.includes('node.name') && l.trim().endsWith('.monitor')), false)
  eq('the sink input block has no Name field', FIXTURE_BLOCKS[3].some((l) => l.startsWith('\tName:')), false)
  eq('the last block names no object.id at all', idLines(FIXTURE_BLOCKS[7]).length, 0)
  eq('both unread kinds carry an object.id of their own', [FIXTURE_BLOCKS[5], FIXTURE_BLOCKS[6]].map((b) => idLines(b).length), [1, 1])
  // The Volume continuation is indented with a tab and then spaces, which is what
  // keeps it off both the field branch and the property branch.
  eq('the fixture carries a tab-then-spaces continuation line', FIXTURE_BLOCKS[0].filter((l) => /^\t +/.test(l)).length, 1)
})

group('the five maps are keyed by object.id and valued with the Pulse index', () => {
  eq('the whole result is five maps and nothing else', Object.keys(PULSE).sort(), [
    'monitors', 'sinkInputs', 'sinks', 'sourceOutputs', 'sources',
  ])
  eq('a sink', PULSE.sinks, { 95: 1967 })
  eq('a source', PULSE.sources, { 128: 1968 })
  eq('a source monitor', PULSE.monitors, { 95: 1969 })
  eq('a sink input', PULSE.sinkInputs, { 310: 1970 })
  eq('a source output', PULSE.sourceOutputs, { 417: 1972 })
  // Every key is a decimal string, because the graph's node id is the text the
  // daemon published and the shell's own lookup key is the same text.
  is('every key of every map is a decimal string', [
    ...Object.keys(PULSE.sinks),
    ...Object.keys(PULSE.sources),
    ...Object.keys(PULSE.monitors),
    ...Object.keys(PULSE.sinkInputs),
    ...Object.keys(PULSE.sourceOutputs),
  ], (keys) => keys.every((k) => /^[0-9]+$/.test(k)), 'decimal keys')
  // At least one entry has an index and an id that differ, which is the whole
  // reason the two cannot be the same number by accident.
  is('at least one entry keys an id that is not its index', PULSE.sinks, (s) => Object.keys(s).some((k) => k !== String(s[k])), 'id differs from index')
})

group('a Pulse index is never a key, and no header index leaks in', () => {
  eq('the sink is keyed 95, not 1967', '95' in PULSE.sinks, true)
  eq('and its index is not a key', '1967' in PULSE.sinks, false)
  eq('the sink input is keyed 310, not 1970', ['310' in PULSE.sinkInputs, '1970' in PULSE.sinkInputs], [true, false])
  eq('the source output is keyed 417, not 1972', ['417' in PULSE.sourceOutputs, '1972' in PULSE.sourceOutputs], [true, false])
  eq('the source is keyed 128, not 1968', ['128' in PULSE.sources, '1968' in PULSE.sources], [true, false])
  // No header index from the capture appears as a key anywhere, which is what a
  // parser that keyed by the header instead of by object.id would produce.
  const everyKey = [
    ...Object.keys(PULSE.sinks),
    ...Object.keys(PULSE.sources),
    ...Object.keys(PULSE.monitors),
    ...Object.keys(PULSE.sinkInputs),
    ...Object.keys(PULSE.sourceOutputs),
  ]
  is('no header index is a key anywhere', everyKey, (keys) => !keys.some((k) => /^196[7-9]$|^197[0-3]$/.test(k)), 'no index keys')
})

group('a monitor is filed under monitors, and the header Name field decides', () => {
  // The daemon prints the monitor's name with the `.monitor` suffix in the
  // header field and without it in the `node.name` property, so a parser that
  // read the property would file both objects under sources and leave monitors
  // empty. The header field wins, and the property is only the fallback.
  eq('the monitor is not a source', '95' in PULSE.sources, false)
  eq('the monitor is in monitors under the sink id', PULSE.monitors['95'], 1969)
  eq('the plain source is in sources under its own id', PULSE.sources['128'], 1968)
  // The two shapes that decide it, side by side.
  eq('a source whose Name field ends in .monitor is a monitor', M.parsePulseObjects([
    'Source #67',
    '\tName: eq_input.monitor',
    '\tProperties:',
    '\t\tnode.name = "eq_input"',
    '\t\tobject.id = "301"',
  ].join('\n')).monitors, { 301: 67 })
  eq('and a source whose Name field does not stays a source', M.parsePulseObjects([
    'Source #68',
    '\tName: eq_input',
    '\tProperties:',
    '\t\tnode.name = "eq_input.monitor"',
    '\t\tobject.id = "302"',
  ].join('\n')).sources, { 302: 68 })
  // A Sink Input prints no Name field at all, so for a source-like block the
  // property is what the split has to read.
  eq('a source with no Name field falls back to its node.name property', M.parsePulseObjects([
    'Source #69',
    '\tState: SUSPENDED',
    '\tProperties:',
    '\t\tnode.name = "eq_output.monitor"',
    '\t\tobject.id = "303"',
  ].join('\n')).monitors, { 303: 69 })
  // A Source block that names nothing is not a monitor: the suffix test is on the
  // name it does carry, and an absent name fails it, so the object stays a source.
  eq('and a source that names nothing stays a plain source', M.parsePulseObjects([
    'Source #70',
    '\tProperties:',
    '\t\tobject.id = "304"',
  ].join('\n')).sources, { 304: 70 })
})

group('monitors is a separate map because the id is shared, not a renamed one', () => {
  // The monitor and the sink it watches are one PipeWire node each with the same
  // number, so there is no id left to tell them apart - which is exactly why the
  // parser cannot file both in one map keyed by that id.
  eq('the monitor key is a key sinks also carries', '95' in PULSE.sinks && '95' in PULSE.monitors, true)
  eq('and the two maps hold different indices under it', [PULSE.sinks['95'], PULSE.monitors['95']], [1967, 1969])
  // The split is what keeps the shared id out of sources, not a suffix or a
  // rename applied to the key.
  is('monitors and sources share no key', [PULSE.monitors, PULSE.sources], ([m, s]) => Object.keys(m).every((k) => !(k in s)), 'disjoint maps')
  is('no monitor entry is reachable through sources', PULSE.sources, (s) => !Object.keys(PULSE.monitors).some((k) => k in s), 'no overlap')
  // The sink and its sink input may share a number too: the key space is
  // per-bucket, so one id appearing in two maps is not a collision.
  eq('one id in two buckets is stored in both', M.parsePulseObjects([
    'Sink #75', '\tProperties:', '\t\tobject.id = "400"',
    'Sink Input #76', '\tProperties:', '\t\tobject.id = "400"',
  ].join('\n')).sinks['400'], 75)
})

group('the monitor split is scoped to the sources bucket', () => {
  // A `.monitor` name on a Sink or a Sink Input is not a monitor: only a Source
  // block shares an id with another block, so only a Source block is split.
  eq('a sink input named .monitor is still a sink input', M.parsePulseObjects([
    'Sink Input #77',
    '\tProperties:',
    '\t\tnode.name = "bluez_input.00_00.1.monitor"',
    '\t\tobject.id = "308"',
  ].join('\n')), { sinks: {}, sources: {}, monitors: {}, sinkInputs: { 308: 77 }, sourceOutputs: {} })
  eq('a sink named .monitor is still a sink', M.parsePulseObjects([
    'Sink #78',
    '\tName: alsa_output.monitor',
    '\tProperties:',
    '\t\tobject.id = "309"',
  ].join('\n')), { sinks: { 309: 78 }, sources: {}, monitors: {}, sinkInputs: {}, sourceOutputs: {} })
})

group('a block with no object.id is skipped, not keyed by its index', () => {
  // The last block of the fixture is a Sink with a name, a class and a property
  // tail that never names the graph object. Its header index is a number the
  // shell could look up in the wrong map, so the block is dropped instead.
  eq('the sink map still holds only the one sink', PULSE.sinks, { 95: 1967 })
  eq('its index is no key', '1973' in PULSE.sinks, false)
  eq('and it reached no other map', [
    '1973' in PULSE.sources, '1973' in PULSE.monitors,
    '1973' in PULSE.sinkInputs, '1973' in PULSE.sourceOutputs,
  ], [false, false, false, false])
  // An empty, valueless or whitespace id is the same answer as no id at all.
  eq('an empty id is skipped', M.parsePulseObjects(['Sink #79', '\tProperties:', '\t\tobject.id = ""'].join('\n')).sinks, {})
  eq('a valueless id is skipped', M.parsePulseObjects(['Sink #80', '\tProperties:', '\t\tobject.id ='].join('\n')).sinks, {})
  eq('a property named only object.id. is not an id', M.parsePulseObjects([
    'Sink #81', '\tProperties:', '\t\tobject.id.x = "309"',
  ].join('\n')).sinks, {})
  // A block with no property tail at all commits nothing either.
  eq('a header and fields with no properties commit nothing', M.parsePulseObjects([
    'Sink #82', '\tName: n', '\tState: RUNNING',
  ].join('\n')).sinks, {})
})

group('a kind the mixer does not read is walked past and cannot leak', () => {
  // The Client and Module blocks in the fixture carry an object.id each. The walk
  // has to keep reading past an unread header, and the block after one has to
  // bring its own id rather than inherit the unread block's.
  eq('a client object.id is not in any map', [
    '999' in PULSE.sinks, '999' in PULSE.sources, '999' in PULSE.monitors,
    '999' in PULSE.sinkInputs, '999' in PULSE.sourceOutputs,
  ], [false, false, false, false, false])
  eq('a module object.id is not in any map', [
    '555' in PULSE.sinks, '555' in PULSE.sources, '555' in PULSE.monitors,
    '555' in PULSE.sinkInputs, '555' in PULSE.sourceOutputs,
  ], [false, false, false, false, false])
  eq('and the sink input before the client keeps its own id', PULSE.sinkInputs, { 310: 1970 })
  eq('the source output after the client brings its own id', PULSE.sourceOutputs, { 417: 1972 })
  eq('a client block on its own stores nothing', M.parsePulseObjects([
    'Client #83', '\tProperties:', '\t\tobject.id = "900"',
  ].join('\n')), { sinks: {}, sources: {}, monitors: {}, sinkInputs: {}, sourceOutputs: {} })
  eq('a module block on its own stores nothing', M.parsePulseObjects([
    'Module #12', '\tName: module-native-protocol-pulse', '\tProperties:', '\t\tobject.id = "901"',
  ].join('\n')).sinks, {})
  eq('a card block on its own stores nothing', M.parsePulseObjects([
    'Card #0', '\tName: alsa_card.pci', '\tProperties:', '\t\tobject.id = "902"',
  ].join('\n')).sinks, {})
})

group('object.id is read out of the property tail, unquoted and nothing more', () => {
  // The id arrives in the property tail, where every entry is `key = "value"`.
  // Only that spelling is read, and only two keys: the object id and the node
  // name. Everything else in the tail is data the mixer does not route.
  eq('the ordinary spelling', M.parsePulseObjects(['Sink #84', '\tProperties:', '\t\tobject.id = "305"'].join('\n')).sinks, { 305: 84 })
  eq('no space around the equals sign', M.parsePulseObjects(['Sink #85', '\tProperties:', '\t\tobject.id="306"'].join('\n')).sinks, { 306: 85 })
  eq('an indented key', M.parsePulseObjects(['Sink #86', '\tProperties:', '\t\t   object.id = "307"'].join('\n')).sinks, { 307: 86 })
  eq('an unquoted value', M.parsePulseObjects(['Sink #87', '\tProperties:', '\t\tobject.id = 308'].join('\n')).sinks, { 308: 87 })
  eq('a single-quoted value keeps its quotes, so it is not a plain id', M.parsePulseObjects(["Sink #88", '\tProperties:', "\tobject.id = '309'"].join('\n')).sinks, { "'309'": 88 })
  // The field form carries a colon, which is how the parser tells a field from a
  // property at all: an `object.id =` line outside the property tail is neither.
  eq('the colon field form is read as a field', M.parsePulseObjects(['Sink #89', '\tName: n', '\tobject.id: "310"'].join('\n')).sinks, { 310: 89 })
  eq('an equals line outside the property tail is not read', M.parsePulseObjects(['Sink #90', '\tName: n', '\tobject.id = "311"'].join('\n')).sinks, {})
  eq('the value is unquoted but not otherwise rewritten', M.parsePulseObjects(['Sink #91', '\tProperties:', '\t\tobject.id = " 312 "'].join('\n')).sinks, { ' 312 ': 91 })
  // A line whose first character is the equals sign has no key to the left of
  // it, so it is skipped rather than read as a nameless entry.
  eq('a line with no key is skipped', M.parsePulseObjects(['Sink #92', '\tProperties:', '\t\t= x', '\t\tobject.id = "313"'].join('\n')).sinks, { 313: 92 })
  eq('an unrecognised property is not read as an id', M.parsePulseObjects([
    'Sink #93', '\tProperties:', '\t\tdevice.description = "Built-in"', '\t\tobject.id = "314"',
  ].join('\n')).sinks, { 314: 93 })
})

group('only a header line opens a block', () => {
  // The header is `Kind #Index` with nothing else on the line, which is what
  // keeps one block's fields out of the next block's record. A line that only
  // looks like a header does not open one.
  eq('the ordinary header', M.parsePulseObjects(['Sink #94', '\tProperties:', '\t\tobject.id = "315"'].join('\n')).sinks, { 315: 94 })
  eq('a two-word kind opens its own bucket', M.parsePulseObjects(['Sink Input #95', '\tProperties:', '\t\tobject.id = "316"'].join('\n')).sinkInputs, { 316: 95 })
  eq('and the other two-word kind too', M.parsePulseObjects(['Source Output #96', '\tProperties:', '\t\tobject.id = "317"'].join('\n')).sourceOutputs, { 317: 96 })
  eq('index zero is an index', M.parsePulseObjects(['Sink #0', '\tProperties:', '\t\tobject.id = "318"'].join('\n')).sinks, { 318: 0 })
  eq('trailing space is not a header', M.parsePulseObjects(['Sink #97 ', '\tProperties:', '\t\tobject.id = "319"'].join('\n')).sinks, {})
  eq('a lower-case kind is not a header', M.parsePulseObjects(['sink #98', '\tProperties:', '\t\tobject.id = "320"'].join('\n')).sinks, {})
  eq('a digit-leading kind is not a header', M.parsePulseObjects(['3 Sink #99', '\tProperties:', '\t\tobject.id = "321"'].join('\n')).sinks, {})
  eq('a header with no index is not a header', M.parsePulseObjects(['Sink #', '\tProperties:', '\t\tobject.id = "322"'].join('\n')).sinks, {})
  // The record is committed when the NEXT header arrives, so a block with no
  // following header is still committed - the tail of the capture.
  eq('the last block of a capture is committed', M.parsePulseObjects('Sink #100\n\tProperties:\n\t\tobject.id = "323"').sinks, { 323: 100 })
  eq('blank lines and a bare tab between blocks change nothing', M.parsePulseObjects([
    '', 'Sink #101', '\t', '\tProperties:', '\t\tobject.id = "324"', '', '',
  ].join('\n')).sinks, { 324: 101 })
  eq('an indented header line is a field, not a header', M.parsePulseObjects([
    '\tSink #102', '\tProperties:', '\t\tobject.id = "325"',
  ].join('\n')).sinks, {})
})

group('a field is read only when it has a colon, and a continuation is not one', () => {
  // Fields are tab-indented `Field: value` lines. A continuation line is
  // indented deeper and carries no colon, and it is what keeps the tail of a
  // Volume entry from becoming a field of its own.
  eq('a Name field is read', M.parsePulseObjects([
    'Sink #103', '\tName: eq_output.monitor', '\tProperties:', '\t\tobject.id = "326"',
  ].join('\n')).sinks, { 326: 103 })
  eq('a Name value may contain a colon', M.parsePulseObjects([
    'Source #104', '\tName: foo: bar', '\tProperties:', '\t\tobject.id = "327"',
  ].join('\n')).sources, { 327: 104 })
  eq('the Volume continuation line in the fixture is not a field', M.parsePulseObjects(fixture(0, 1)).sinks, { 95: 1967 })
  eq('a field with no colon is ignored', M.parsePulseObjects([
    'Sink #105', '\tbalance 0.00', '\tProperties:', '\t\tobject.id = "328"',
  ].join('\n')).sinks, { 328: 105 })
  // The property tail runs to the end of the block, so a `Name:` field printed
  // after `Properties:` is read as a property line - it has no equals sign, so it
  // is skipped - and the header name never gets set. A block that would have been
  // a monitor on that field is a plain source instead.
  eq('a Name field after the property tail is not a field', M.parsePulseObjects([
    'Source #106', '\tProperties:', '\t\tobject.id = "329"', '\tName: late.monitor',
  ].join('\n')), { sinks: {}, sources: { 329: 106 }, monitors: {}, sinkInputs: {}, sourceOutputs: {} })
})

group('empty, CRLF and truncated input all answer empty maps instead of throwing', () => {
  // The parser reads text a daemon produced inside a QML handler, so a missing
  // block, a CRLF line ending, a blank line and an unrecognised kind all leave
  // the maps empty rather than throwing: a throw there is a warning on stderr
  // and an undefined routing map on screen.
  const EMPTY = { sinks: {}, sources: {}, monitors: {}, sinkInputs: {}, sourceOutputs: {} }
  eq('the empty string', M.parsePulseObjects(''), EMPTY)
  eq('null', M.parsePulseObjects(null), EMPTY)
  eq('undefined', M.parsePulseObjects(undefined), EMPTY)
  eq('a number', M.parsePulseObjects(42), EMPTY)
  eq('an object', M.parsePulseObjects({ list: FIXTURE }), EMPTY)
  eq('an array of lines', M.parsePulseObjects(FIXTURE.split('\n')), EMPTY)
  noThrow('parsing with no argument at all', () => M.parsePulseObjects())
  // CRLF is what a capture taken on a daemon that writes Windows line endings
  // looks like, and the trailing carriage return has to be gone before the
  // header's end-of-line anchor matches.
  eq('the whole capture with CRLF endings parses to the LF answer', M.parsePulseObjects(FIXTURE.replace(/\n/g, '\r\n')), PULSE)
  // A capture cut before the first block's object.id has nothing to commit.
  eq('a cut inside the first block leaves every map empty', M.parsePulseObjects(FIXTURE_BLOCKS[0].slice(0, 4).join('\n')), EMPTY)
  eq('a cut before any block leaves every map empty', M.parsePulseObjects('Sink #1967'), EMPTY)
  noThrow('a capture cut at its first byte', () => M.parsePulseObjects(FIXTURE.slice(0, 1)))
  noThrow('a capture cut at an arbitrary offset', () => M.parsePulseObjects(FIXTURE.slice(0, 613)))
  // A capture cut mid-file keeps every block that was complete and drops the
  // partial one, because a record is committed only once it carries an id.
  const FOUR = {
    sinks: { 95: 1967 },
    sources: { 128: 1968 },
    monitors: { 95: 1969 },
    sinkInputs: { 310: 1970 },
    sourceOutputs: {},
  }
  eq('a cut after four complete blocks keeps exactly those four', M.parsePulseObjects(fixture(0, 4)), FOUR)
  eq('a cut inside the fifth block drops that block only', M.parsePulseObjects(
    fixture(0, 5).split('\n').slice(0, -2).join('\n'),
  ), FOUR)
  eq('a cut before the first object.id of the first block keeps nothing', M.parsePulseObjects(
    fixture(0, 5).split('\n').slice(0, 5).join('\n'),
  ), EMPTY)
  // A capture cut in the middle of a header line: the fragment is not a header,
  // and even when it parses as one it carries no id, so nothing is committed.
  eq('a cut mid-header commits nothing', M.parsePulseObjects(`${fixture(0, 1)}\nSink #19`), {
    sinks: { 95: 1967 },
    sources: {},
    monitors: {},
    sinkInputs: {},
    sourceOutputs: {},
  })
  eq('and a CRLF capture cut mid-header is the same answer', M.parsePulseObjects(
    `${fixture(0, 1).replace(/\n/g, '\r\n')}\r\nSink #19`,
  ), {
    sinks: { 95: 1967 },
    sources: {},
    monitors: {},
    sinkInputs: {},
    sourceOutputs: {},
  })
})

group('the five maps are the only shape the parser ever returns', () => {
  // A consumer reaches for these five names and nothing else, so a map that
  // grew a sixth key or lost one would be a silent change in what a caller can
  // read off the result.
  const shapes = new Set([
    JSON.stringify(M.parsePulseObjects(FIXTURE)),
    JSON.stringify(M.parsePulseObjects('')),
    JSON.stringify(M.parsePulseObjects('Module #1\n')),
    JSON.stringify(M.parsePulseObjects('Client #1\n\tProperties:\n\t\tobject.id = "1"')),
  ])
  is('every answer has the same five keys', [...shapes].map((s) => Object.keys(JSON.parse(s)).sort().join(',')), (keys) => new Set(keys).size === 1, 'one shape')
  eq('and it is these five', Object.keys(JSON.parse([...shapes][0])).sort(), ['monitors', 'sinkInputs', 'sinks', 'sourceOutputs', 'sources'])
  // Every key is a decimal id, so a key can never be an Object.prototype name.
  // That is what makes a miss a miss: `map[k]` for a key nobody stored reads as
  // undefined rather than as an inherited function.
  eq('no map carries a prototype name as one of its own keys', [
    ...Object.keys(PULSE.sinks), ...Object.keys(PULSE.sources), ...Object.keys(PULSE.monitors),
    ...Object.keys(PULSE.sinkInputs), ...Object.keys(PULSE.sourceOutputs),
  ].filter((k) => k in Object.prototype), [])
  eq('a key nobody stored reads as undefined', PULSE.sinks['1967'], undefined)
  eq('and every value is a finite number', [
    ...Object.values(PULSE.sinks), ...Object.values(PULSE.sources), ...Object.values(PULSE.monitors),
    ...Object.values(PULSE.sinkInputs), ...Object.values(PULSE.sourceOutputs),
  ].every((v) => typeof v === 'number' && isFinite(v)), true)
})

group('the answers are a pure function of the string handed in', () => {
  // This section asserts a fixture committed in the file, so a claim here can
  // only hold if the parser reads nothing else: no daemon, no process, no file,
  // no clock. Two parses of one string, and of its CRLF twin, have to agree.
  is('the same string parsed twice agrees', [PULSE, M.parsePulseObjects(FIXTURE)], (pair) => deepEqual(pair[0], pair[1]), 'identical answers')
  is('and its CRLF twin agrees too', [PULSE, M.parsePulseObjects(FIXTURE.replace(/\n/g, '\r\n'))], (pair) => deepEqual(pair[0], pair[1]), 'identical answers')
  is('and nothing in the answer carries a node name', PULSE, (maps) => ![maps.sinks, maps.sources, maps.monitors, maps.sinkInputs, maps.sourceOutputs].some((m) => JSON.stringify(m).includes('alsa')), 'ids and indices only')
  skip('the fixture is byte-shaped like a live daemon capture', 'needs a running Pulse/PipeWire daemon, and the suite is required to pass on a host that has none: the fixture is a trimmed hand-written excerpt, so only its shape is asserted')
})

finish()