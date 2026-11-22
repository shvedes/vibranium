#!/usr/bin/env node
// Suite: the annotation editor's push progress and toolbar reveal (OVL-1/2).
//
//   shell/features/annotations/AnnotationEditor.qml   push and its two curves,
//                                                    onLoadStateChanged
//
// Limitation: AnnotationEditor is a LayerSurface that needs a compositor and a
// real capture; Quickshell.screens is empty under offscreen and there is no
// synthesized close. This suite reads the shipped QML, lifts the push and
// reveal handlers by brace matching, and runs them against stubs. It pins the
// mechanism - one animated source with no hardcoded `from`, both visible
// properties derived from it, and one edge owning the reveal - not the pixels.
// The visible close-mid-arrival sequence stays source-level here.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, ne, match, notMatch, contains, notContains,
  finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const EDITOR_QML = fs.readFileSync(
  path.join(SHELL_DIR, 'features', 'annotations', 'AnnotationEditor.qml'), 'utf8')

function bracedBody(src, firstBrace, label) {
  if (firstBrace < 0) throw new Error(`${label} has no body`)
  let depth = 0
  for (let j = firstBrace; j < src.length; j++) {
    if (src[j] === '{') depth++
    if (src[j] === '}') {
      depth--
      if (depth === 0) return src.slice(firstBrace + 1, j)
    }
  }
  throw new Error(`${label} body never closes`)
}

function extractFunction(src, name) {
  const head = `function ${name}(`
  const at = src.indexOf(head)
  if (at < 0) throw new Error(`AnnotationEditor.qml has no ${head}`)
  return bracedBody(src, src.indexOf('{', at), head)
}

function extractHandler(src, name) {
  const re = new RegExp(`^[ \\t]*${name}[ \\t]*:[ \\t]*\\{`, 'm')
  const m = re.exec(src)
  if (!m) throw new Error(`AnnotationEditor.qml has no ${name} block`)
  return bracedBody(src, src.indexOf('{', m.index), name)
}

function animationBlocks(src) {
  const out = []
  const re = /^[ \t]*NumberAnimation[ \t]*\{/gm
  let m
  while ((m = re.exec(src)) !== null) {
    const body = bracedBody(src, src.indexOf('{', m.index), 'NumberAnimation')
    const id = (/\bid\s*:\s*([A-Za-z_]\w*)/.exec(body) || [])[1]
    const target = (/\bproperty\s*:\s*"([^"]+)"/.exec(body) || [])[1]
    if (id) out.push({ id, target, body })
  }
  return out
}

const PUSH_ANIMS = animationBlocks(EDITOR_QML).filter((b) => b.target === 'push')
const ON_LOAD = extractHandler(EDITOR_QML, 'onLoadStateChanged')
const ON_COMPLETED = extractHandler(EDITOR_QML, 'Component.onCompleted')
const CLOSE_BODY = extractFunction(EDITOR_QML, '_close')
const REVEAL_BODY = extractFunction(EDITOR_QML, 'reveal')

suite('annotation push + reveal', 'one progress, one reveal edge')

// ---------------------------------------------------------------------------
section('one progress drives scale and alpha')

group('push is the only animated source', () => {
  eq('two directional animations write push', PUSH_ANIMS.length, 2)
  for (const b of PUSH_ANIMS) {
    eq(`${b.id} targets push`, b.target, 'push')
    notMatch(`${b.id} has no hardcoded from:`, b.body, /\bfrom\s*:/)
  }
  const targets = animationBlocks(EDITOR_QML).map((b) => b.target)
  notContains('pushScale is never an animation target', targets, 'pushScale')
  notContains('pushOpacity is never an animation target', targets, 'pushOpacity')
  eq('no imperative pushScale write', /\bpushScale\s*=/.test(EDITOR_QML), false)
  eq('no imperative pushOpacity write', /\bpushOpacity\s*=/.test(EDITOR_QML), false)
})

group('scale and alpha are derived from the live progress', () => {
  const scale = /readonly property real pushScale:\s*([^\n]+)/.exec(EDITOR_QML)
  const opacity = /readonly property real pushOpacity:\s*([^\n]+)/.exec(EDITOR_QML)
  eq('pushScale is a readonly derivation', scale !== null, true)
  eq('pushOpacity is a readonly derivation', opacity !== null, true)
  if (!scale || !opacity) return
  const pushScale = new Function('editor', `return ${scale[1]}`)
  const pushOpacity = new Function('editor', `return ${opacity[1]}`)
  eq('settled scale', pushScale({ push: 1 }), 1)
  eq('settled alpha', pushOpacity({ push: 1 }), 1)
  eq('away scale', pushScale({ push: 0 }), 1.09)
  eq('away alpha', pushOpacity({ push: 0 }), 0)
  // The finding's interrupted arrival: half way out, both properties read the
  // one live value; no frame snaps to a fixed endpoint before easing back.
  eq('mid-arrival scale', pushScale({ push: 0.4 }), 1 + 0.09 * 0.6)
  eq('mid-arrival alpha', pushOpacity({ push: 0.4 }), 0.4)
})

group('the two curves stay distinct', () => {
  const arrival = PUSH_ANIMS.find((b) => b.id === 'arrivalAnim')
  const exit = PUSH_ANIMS.find((b) => b.id === 'exitAnim')
  eq('both directional animations exist', !!arrival && !!exit, true)
  if (!arrival || !exit) return
  contains('arrival keeps its long clock', arrival.body, 'duration: editor.arrivalMs')
  contains('arrival keeps OutCubic', arrival.body, 'Easing.OutCubic')
  contains('exit keeps the fade clock', exit.body, 'duration: editor.fadeMs')
  contains('exit keeps Linear', exit.body, 'Easing.Linear')
  const ms = (name) => Number(
    new RegExp(`readonly property int ${name}:\\s*(\\d+)`).exec(EDITOR_QML)[1])
  ne('the clocks are not collapsed', ms('arrivalMs'), ms('fadeMs'))
  contains('arrival sets to at completion', ON_COMPLETED, 'arrivalAnim.to = 1')
  contains('exit sets to in close', CLOSE_BODY, 'exitAnim.to = 0')
})

group('the OVL-3 teardown boundary is intact', () => {
  contains('_close guards the session', CLOSE_BODY, 'editor._closing')
  const timerIds = [...EDITOR_QML.matchAll(/^\s*Timer\s*\{/gm)].length
  eq('eight timers remain', timerIds, 8)
  for (const id of ['exportSettle', 'exportPaintTimer', 'discardTimer',
    'zoomSettleTimer', 'clearTimer', 'settleTimer', 'blurPlateTimer',
    'paintCooldown']) {
    contains(`${id} is still stopped`, CLOSE_BODY, `${id}.stop()`)
  }
})

// ---------------------------------------------------------------------------
section('one edge owns the toolbar reveal')

group('no deferred reveal competes with loadState', () => {
  eq('no Qt.callLater(reveal)', EDITOR_QML.includes('Qt.callLater(reveal)'), false)
  eq('one panel.reveal call site', (EDITOR_QML.match(/panel\.reveal\(\)/g) || []).length, 1)
  contains('the call is in onLoadStateChanged', ON_LOAD, 'panel.reveal()')
  eq('panel has no completion reveal hook',
    /Component\.onCompleted\s*:\s*Qt\.callLater/.test(EDITOR_QML), false)
})

group('the lifted reveal handler is the implementation onLoadStateChanged drives', () => {
  function runReveal(animOn) {
    const slideAnim = { to: 220, started: 0, start() { this.started++ } }
    const panel = { visible: false, revealOffset: 0 }
    const editor = { animOn, loadState: 'ready' }
    new Function('editor', 'panel', 'slideAnim', REVEAL_BODY)(editor, panel, slideAnim)
    return { panel, slideAnim }
  }
  const animated = runReveal(true)
  eq('animated reveal shows the panel', animated.panel.visible, true)
  eq('animated reveal starts off-screen', animated.panel.revealOffset, 220)
  eq('animated reveal sets the slide target live', animated.slideAnim.to, 0)
  eq('animated reveal starts one slide', animated.slideAnim.started, 1)

  const snapped = runReveal(false)
  eq('snapped reveal shows the panel', snapped.panel.visible, true)
  eq('snapped reveal lands at rest', snapped.panel.revealOffset, 0)
  eq('snapped reveal starts no slide', snapped.slideAnim.started, 0)
})

group('loadState drives visibility and the zoom commit', () => {
  function runLoad(state) {
    const slideAnim = { stopped: 0, stop() { this.stopped++ } }
    const panel = { visible: true, reveal() { sim.revealed++ } }
    const sim = { revealed: 0, zoomCommits: 0 }
    const editor = {
      _commitBoardZoom() { sim.zoomCommits++ },
    }
    new Function('editor', 'loadState', 'panel', 'slideAnim', ON_LOAD)(
      editor, state, panel, slideAnim)
    return { sim, panel, slideAnim }
  }
  const ready = runLoad('ready')
  eq('ready reveals exactly once', ready.sim.revealed, 1)
  eq('ready commits the board zoom', ready.sim.zoomCommits, 1)

  const loading = runLoad('loading')
  eq('loading reveals nothing', loading.sim.revealed, 0)
  eq('loading hides the panel', loading.panel.visible, false)
  eq('loading stops the slide', loading.slideAnim.stopped, 1)
  eq('loading commits no zoom', loading.sim.zoomCommits, 0)
})

finish()
