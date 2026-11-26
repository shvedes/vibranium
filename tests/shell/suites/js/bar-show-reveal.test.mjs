#!/usr/bin/env node
// Suite: the transient visibility show replays the boot entrance. The bar's
// persistent enable/disable switch is untouched; only clearing the IPC-only
// hide arms a separate, re-armable two-step clock - strip first, then the
// contents slidefade onto it. Boot's one-shot gate keeps its milestones.
//
// The contents half rides a plain progress property that snaps to the hold
// at arm and is animated only at release. A Behavior-driven hold animated
// the contents OUT under the arriving strip when its enabled binding lost
// the race with the value binding, so it is explicitly ruled out here.

import fs from 'node:fs'
import path from 'node:path'
import { suite, section, group, eq, contains, notContains, finish, SHELL_DIR } from '../../lib/assert.mjs'

const BAR = fs.readFileSync(path.join(SHELL_DIR, 'features/bar/Bar.qml'), 'utf8')
const VIEW = fs.readFileSync(path.join(SHELL_DIR, 'features/bar/BarView.qml'), 'utf8')
const ZONE = fs.readFileSync(path.join(SHELL_DIR, 'features/bar/Zone.qml'), 'utf8')

const reveal = BAR.slice(BAR.indexOf('// --- transient show reveal ---'),
  BAR.indexOf('// Is `kind` on the bar?'))
const setEnabled = BAR.slice(BAR.indexOf('function ipcSetEnabled('),
  BAR.indexOf('function ipcSetHidden('))

suite('bar-show-reveal', 'a visibility show replays the boot entrance')

section('only the transient hide drives the reveal')
group('the change edge is hideToggle, not enabled', () => {
  eq('one hideToggle change edge', (BAR.match(/onHideToggleChanged:/g) || []).length, 1)
  contains('a hide parks the reveal', BAR, 'if (root.hideToggle) root._resetReveal()')
  contains('a show replays the entrance', BAR, 'else root._replayEntrance()')
  contains('ipc show clears the transient hide', BAR, 'root.hideToggle = hidden === true')
  notContains('the persistent switch never replays', setEnabled, '_replayEntrance')
})

group('the reveal is re-armable and gated', () => {
  contains('the contents clock rests released', BAR, 'property real revealProgress: 1')
  notContains('no Behavior on the contents clock', reveal, 'Behavior on revealProgress')
  contains('a show waits for the boot strip', BAR, '!root.entranceModulesReady')
  contains('motion-off shows snap', BAR, '!MotionPolicy.enabled')
  contains('a disabled bar does not animate an invisible surface', BAR, '!root.enabled')
  eq('one reveal animation', (BAR.match(/id: revealAnim/g) || []).length, 1)
  contains('each show restarts it', BAR, 'revealAnim.restart()')
  contains('a hide stops it', BAR, 'revealAnim.stop()')
  contains('a hide restores the contents', BAR, 'root.revealProgress = 1')
})

section('the strip travels first, then the contents')
group('the reveal steps are ordered', () => {
  const replay = BAR.slice(BAR.indexOf('function _replayEntrance()'),
    BAR.indexOf('function _resetReveal()'))
  const snapAt = replay.indexOf('root.revealProgress = 0')
  const parkAt = replay.indexOf('root.entranceSlide = root.entranceSlideFrom')
  const restartAt = replay.indexOf('revealAnim.restart()')
  const stripAt = reveal.indexOf('property: "entranceSlide"')
  const contentsAt = reveal.indexOf('property: "revealProgress"')
  eq('arm snaps, parks, then starts in the same turn',
    snapAt > 0 && snapAt < parkAt && parkAt < restartAt, true)
  notContains('no ScriptAction can delay the arm', reveal, 'ScriptAction {')
  eq('contents slidefade only after the strip lands', stripAt < contentsAt, true)
  contains('the contents clock starts from the snap', reveal, 'from: 0')
  contains('the contents clock ends released', reveal, 'to: 1')
  contains('the strip shares the boot travel property', VIEW, 'y: Bar.entranceSlide')
})

section('every slot slidefades onto the landed strip')
group('the contents factor is separate from boot intro', () => {
  contains('the factor rests at 1 and holds warm', ZONE,
    'readonly property real revealIntro: Bar.entranceWarmOpacity')
  contains('the factor follows the reveal clock', ZONE,
    '(1 - Bar.entranceWarmOpacity) * Bar.revealProgress')
  contains('opacity multiplies the factor', ZONE, 'slot.enter * slot.intro * slot.revealIntro')
  contains('travel rides the same axis', ZONE,
    '+ (1 - slot.revealIntro) * slot.introOffset')
  notContains('no Behavior can animate the arm', ZONE, 'Behavior on revealIntro')
  notContains('boot intro is not re-armed', ZONE, 'Bar.revealRunning')
  contains('boot intro keeps its original gate', ZONE,
    '? ((Bar.entranceModulesReady && contentLoader.status === Loader.Ready) ? 1 : Bar.entranceWarmOpacity) : 1')
  contains('boot intro Behavior is unchanged', ZONE,
    'enabled: slot._bootHeld && MotionPolicy.enabled')
})

section('no reverse step in the derived factor')
group('sampling the release never fades back out', () => {
  // The warm value is read from the source, not copied into the model.
  const warm = Number(BAR.match(/entranceWarmOpacity:\s*([\d.]+)/)[1])
  const revealIntro = progress => warm + (1 - warm) * progress
  const samples = [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1].map(revealIntro)
  eq('the arm lands at warm', samples[0], warm)
  eq('the release lands at 1', samples[samples.length - 1], 1)
  eq('no frame moves backwards',
    samples.every((value, i) => i === 0 || value >= samples[i - 1]), true)
  contains('the model matches the shipped derivation', ZONE,
    '(1 - Bar.entranceWarmOpacity) * Bar.revealProgress')
})

section('boot keeps its one-shot contract')
group('the boot gate is not re-armed', () => {
  contains('boot gate stays derived', BAR, 'readonly property bool entranceModulesReady:')
  eq('no writes to the boot gate', (BAR.match(/root\.entranceModulesReady\s*=/g) || []).length, 0)
  eq('one strip-done writer', (BAR.match(/root\.entranceSlideDone\s*=/g) || []).length, 1)
  contains('boot settled milestone stays', BAR, 'noteBootEntranceSettled()')
  contains('boot played milestone stays', BAR, 'noteBootEntrancePlayed')
})

finish()
