#!/usr/bin/env node
// Suite: Phase 2 loader wiring, pinned against the shipped QML sources.
//
// The behavioural half lives in suites/qml/boot-loader-probe-test.sh, which drives
// the real AsyncLoader in an engine. This suite pins what an offscreen loader
// cannot see: Boot owns exactly one loader per late half and no longer creates
// either component inline, the four adopted/failed handlers keep §1.1's exact
// log/settle/drain order, trace never receives a raw URL or exception detail,
// and no new log kind was introduced by the extraction. No line numbers are
// asserted.
import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, match, contains, notContains, finish, SHELL_DIR
} from '../../lib/assert.mjs'

const read = (rel) => fs.readFileSync(path.join(SHELL_DIR, rel), 'utf8')
const stripComments = (src) => src
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/\/\/[^\n]*/g, '')

function bodyAt(src, at) {
  const open = src.indexOf('{', at)
  if (open < 0) return ''
  let depth = 0
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++
    else if (src[i] === '}') {
      depth--
      if (depth === 0) return src.slice(open, i + 1)
    }
  }
  return ''
}
function bodyOf(src, marker) {
  const at = src.indexOf(marker)
  return at < 0 ? '' : bodyAt(src, at)
}
function bodiesOf(src, marker) {
  const out = []
  let from = 0
  for (;;) {
    const at = src.indexOf(marker, from)
    if (at < 0) return out
    out.push(bodyAt(src, at))
    from = at + marker.length
  }
}
function count(src, regex) { return (src.match(regex) || []).length }
function at(src, needle) { return src.indexOf(needle) }
// Every trace call's argument text, with balanced parentheses so a nested
// object literal cannot end the scan early.
function callArgs(src, prefix) {
  const out = []
  let from = 0
  for (;;) {
    const at = src.indexOf(prefix, from)
    if (at < 0) return out
    const open = src.indexOf('(', at + prefix.length)
    if (open < 0) return out
    let depth = 0
    let quote = null
    for (let i = open; i < src.length; i++) {
      const c = src[i]
      if (quote) {
        if (c === '\\') { i++; continue }
        if (c === quote) quote = null
        continue
      }
      if (c === '"' || c === "'" || c === '`') { quote = c; continue }
      if (c === '(') depth++
      else if (c === ')') {
        depth--
        if (depth === 0) { out.push(src.slice(open + 1, i)); from = i + 1; break }
      }
    }
  }
}
function ordered(body, labels) {
  const positions = labels.map((label) => at(body, label))
  for (let i = 0; i < positions.length; i++) {
    if (positions[i] < 0) return false
    if (i > 0 && positions[i] <= positions[i - 1]) return false
  }
  return true
}
function logKinds(body) {
  const kinds = (body.match(/\bLog\.[A-Za-z]+/g) || []).map((s) => s.slice(4))
  return [...new Set(kinds)].sort().join(',')
}

const bootSrc = stripComments(read('boot/Boot.qml'))
const loaderSrc = stripComments(read('boot/AsyncLoader.qml'))
const qmldir = stripComments(read('boot/qmldir'))

suite('boot-loader', 'two Boot-owned loaders, inline creation removed, §1.1 order preserved, trace hygiene')

// --- module and ownership ----------------------------------------------------
section('qs.boot exports the loader and Boot owns one per late half')

group('module registration', () => {
  match('AsyncLoader is exported by qs.boot', qmldir,
    /^AsyncLoader\s+\S+\s+AsyncLoader\.qml\s*$/m)
})

const loaderBlocks = bodiesOf(bootSrc, 'AsyncLoader {')
group('exactly two loaders, one per URL', () => {
  eq('Boot declares two AsyncLoader instances', loaderBlocks.length, 2)
  const services = loaderBlocks.find((b) => b.includes('BootServices.qml')) || ''
  const features = loaderBlocks.find((b) => b.includes('BootLate.qml')) || ''
  contains('the services loader exists', services, '{')
  contains('the features loader exists', features, '{')
  match('the services loader names BootServices.qml', services,
    /sourceUrl\s*:\s*["']BootServices\.qml["']/)
  match('the features loader names BootLate.qml', features,
    /sourceUrl\s*:\s*["']BootLate\.qml["']/)
  for (const [label, body] of [['services', services], ['features', features]]) {
    match(label + ' uses Boot as its creation owner', body, /owner\s*:\s*boot\b/)
    match(label + ' passes { boot: boot } as create properties', body,
      /createProperties\s*:\s*\(\{\s*boot\s*:\s*boot\s*\}\)/
    )
    match(label + ' has no production observer', body, /observer\s*:\s*null\b/)
    notContains(label + ' does not inject a test factory', body, 'componentFactory')
  }
})

section('Boot no longer creates either half inline')

group('the old inline component path is gone', () => {
  eq('no inline Qt.createComponent for either late half',
    count(bootSrc, /Qt\.createComponent\(\s*["']Boot(?:Services|Late)\.qml/g), 0)
  for (const marker of ['_lateServicesComponent', '_lateFeaturesComponent',
    '_onServicesHalfStatus', '_onFeaturesHalfStatus']) {
    eq('Boot.qml no longer declares ' + marker, bootSrc.includes(marker), false)
  }
  contains('the services half requests through its loader',
    bodyOf(bootSrc, 'function _loadServicesHalf('), 'servicesLoader.load()')
  contains('the features half requests through its loader',
    bodyOf(bootSrc, 'function _loadFeaturesHalf('), 'featuresLoader.load()')
})

group('the four loader signals are wired directly to Boot handlers', () => {
  for (const line of [
    'servicesLoader.failed.connect(boot._onServicesFailed)',
    'servicesLoader.adopted.connect(boot._adoptServicesHalf)',
    'featuresLoader.failed.connect(boot._onFeaturesFailed)',
    'featuresLoader.adopted.connect(boot._adoptLate)'
  ]) {
    contains('Boot connects ' + line, bootSrc, line)
  }
  const destruction = bodiesOf(bootSrc, 'Component.onDestruction:').join('\n')
  contains('destruction cancels the services load', destruction, 'servicesLoader.teardown()')
  contains('destruction cancels the features load', destruction, 'featuresLoader.teardown()')
})

// --- §1.1 caller/failure order ---------------------------------------------
section('§1.1 caller and failure order is unchanged')

const adoptServices = bodyOf(bootSrc, 'function _adoptServicesHalf(')
const onServicesFailed = bodyOf(bootSrc, 'function _onServicesFailed(')
const adoptLate = bodyOf(bootSrc, 'function _adoptLate(')
const onFeaturesFailed = bodyOf(bootSrc, 'function _onFeaturesFailed(')

group('services adoption: create, log, start, replay, settle', () => {
  match('_adoptServicesHalf takes the already-created object', bootSrc,
    /function _adoptServicesHalf\(object\)/)
  contains('the loader instance is stored', adoptServices, 'boot._lateServices = object')
  const steps = ['boot._lateServices = object', 'boot._observeServicesResult("adopted")',
    'Log.debug(', 'boot._startEarly()', 'boot._replayNext()', 'boot._halfSettled(true)']
  for (const step of steps) contains('services adoption calls ' + step, adoptServices, step)
  eq('the six services adoption calls keep §1.1 order', ordered(adoptServices, steps), true)
})

const servicesNonLoad = bodyAt(onServicesFailed, at(onServicesFailed, 'if (errorClass !== "loadError")'))
const servicesLoadBranch = onServicesFailed.replace(servicesNonLoad, '')
group('services failure: log, observe, settle; no object or replay', () => {
  const steps = ['Log.error(', 'boot._observeServicesResult("failed")', 'boot._halfSettled(true)']
  for (const step of steps) contains('services failure calls ' + step, servicesLoadBranch, step)
  eq('the three services failure calls keep §1.1 order',
    ordered(servicesLoadBranch, steps), true)
  notContains('no early tier on a failed services half', servicesLoadBranch, '_startEarly')
  notContains('no replay on a failed services half', servicesLoadBranch, '_replayNext')
  eq('the instantiate fallback observes then settles through _failHalf',
    ordered(servicesNonLoad, ['boot._observeServicesResult("failed")', 'boot._failHalf(']), true)
})

group('features adoption: create, log, start, annotate, replay, settle', () => {
  match('_adoptLate takes the already-created object', bootSrc,
    /function _adoptLate\(object\)/)
  contains('the loader instance is stored', adoptLate, 'boot._lateFeatures = object')
  const steps = ['boot._lateFeatures = object', 'boot._observeFeaturesResult("adopted")',
    'Log.debug(', 'boot._startEarly()',
    'annotationLoader.sourceComponent = boot._lateFeatures.annotationComponent()',
    'boot._replayNext()', 'boot._halfSettled()']
  for (const step of steps) contains('features adoption calls ' + step, adoptLate, step)
  eq('the seven features adoption calls keep §1.1 order', ordered(adoptLate, steps), true)
})

const featuresNonLoad = bodyAt(onFeaturesFailed, at(onFeaturesFailed, 'if (errorClass !== "loadError")'))
const featuresLoadBranch = onFeaturesFailed.replace(featuresNonLoad, '')
group('features failure: settle then drain, with the original sync/deferred log order', () => {
  match('the sync/deferred distinction still exists', bootSrc, /property bool _featuresLoadSync/)
  for (const step of ['boot._observeFeaturesResult("failed")', 'boot._halfSettled()',
    'boot._failHalf(', 'boot._beginDrain()', 'Log.error(']) {
    contains('features failure calls ' + step, featuresLoadBranch, step)
  }
  eq('the instantiate fallback observes, fails, then drains',
    ordered(featuresNonLoad, ['boot._observeFeaturesResult("failed")',
      'boot._failHalf(', 'boot._beginDrain()']), true)
  const syncBranch = bodyOf(featuresLoadBranch, 'if (boot._featuresLoadSync)')
  eq('synchronous Error logs before it observes and settles',
    ordered(syncBranch, ['Log.error(', 'boot._observeFeaturesResult("failed")',
      'boot._halfSettled()']), true)
  match('deferred Error observes before _failHalf logs', featuresLoadBranch,
    /else\s*\{[\s\S]{0,200}boot\._observeFeaturesResult\("failed"\)[\s\S]{0,200}boot\._failHalf\(/
  )
  eq('_beginDrain is the last call on both features failure paths',
    at(featuresLoadBranch, 'boot._beginDrain()') >
    Math.max(at(featuresLoadBranch, 'boot._halfSettled()'),
      at(featuresLoadBranch, 'boot._failHalf(')), true)
})

// --- trace hygiene and log kinds -------------------------------------------
section('the extraction adds no trace detail and no default log kind')

// Only the Phase 2 loader-related observation functions are in scope here.
// The Phase 0 integrity observer has its own fixed, bounded detail field.
const loaderTraceFns = [bootSrc.indexOf('function _observeServicesDemand('),
  bootSrc.indexOf('function _observeServicesResult('),
  bootSrc.indexOf('function _observeFeaturesDemand('),
  bootSrc.indexOf('function _observeFeaturesResult('),
  bootSrc.indexOf('function _loadServicesHalf('),
  bootSrc.indexOf('function _loadFeaturesHalf('),
  bootSrc.indexOf('function _onServicesFailed('),
  bootSrc.indexOf('function _onFeaturesFailed('),
  bootSrc.indexOf('function _adoptServicesHalf('),
  bootSrc.indexOf('function _adoptLate(')].map((at) => bodyAt(bootSrc, at)).join('\n')
const traceArgs = callArgs(loaderTraceFns, 'boot.trace.').join('\n')
group('trace never receives a raw URL or exception detail', () => {
  for (const token of ['sourceUrl', 'errorString', 'attemptId', 'BootServices.qml',
    'BootLate.qml', 'createComponent', 'detail', '.message']) {
    notContains('no trace call carries ' + token, traceArgs, token)
  }
  // The provider result outcome is a fixed word chosen by Boot, never a
  // loader detail string.
  const observeResult = bodyOf(bootSrc, 'function _observeServicesResult(') +
    bodyOf(bootSrc, 'function _observeFeaturesResult(')
  match('provider.result uses a fixed outcome word', observeResult,
    /outcome\s*:\s*outcome\b/)
  notContains('the result observer does not read the loader detail', observeResult, 'detail')
})

group('only the existing Log.error and Log.debug kinds are used', () => {
  const handlers = [adoptServices, onServicesFailed, adoptLate, onFeaturesFailed,
    bodyOf(bootSrc, 'function _loadServicesHalf('),
    bodyOf(bootSrc, 'function _loadFeaturesHalf(')].join('\n')
  eq('loader handlers use no new log kind', logKinds(handlers), 'debug,error')
  notContains('the loader itself never logs', loaderSrc, 'Log.')
})

// --- AsyncLoader.qml contract ----------------------------------------------
section('AsyncLoader.qml keeps the narrow extraction contract')

group('one URL, one generation, one injectable factory', () => {
  contains('sourceUrl is a url property', loaderSrc, 'property url sourceUrl: ""')
  match('componentFactory defaults to the real Qt call', loaderSrc,
    /property var componentFactory:\s*function\s*\([^)]*\)\s*\{\s*return Qt\.createComponent\(url, mode\)/)
  match('every accepted load asks the factory for an asynchronous component', loaderSrc,
    /componentFactory\(loader\.sourceUrl, Component\.Asynchronous\)/)
  match('adoption and failure are public signals', loaderSrc,
    /signal adopted\(var object, int attemptId\)/)
  match('failed carries an error class, attempt id and bounded detail', loaderSrc,
    /signal failed\(string errorClass, int attemptId, string detail\)/)
  match('single-flight plus the instance guard reject later requests', loaderSrc,
    /state === "loading" \|\| loader\.instance !== null/)
  match('a terminal failure permits another attempt', loaderSrc,
    /state = "failed"/)
})

group('handler generation is stored, detached once and generation-guarded', () => {
  contains('the active record holds the component and its handler', loaderSrc, 'record.handler = onStatus')
  match('teardown disconnects the exact stored handler', loaderSrc,
    /record\.component\.statusChanged\.disconnect\(record\.handler\)/)
  match('generation is validated before adoption publication', loaderSrc,
    /gen !== loader\.generation \|\| loader\._active !== record/)
  match('createObjectNull is a failure edge, not an adopted edge', loaderSrc,
    /outcomeClass = "createObjectNull"/)
  const cancel = bodyOf(loaderSrc, 'function _cancel(')
  notContains('cancellation emits no public failed signal', cancel, 'failed(')
  match('cancellation reports a teardown outcome to the observer', cancel,
    /attemptClose\([^)]*["']teardown["']\)/)
  match('detail text is bounded before publication', loaderSrc, /slice\(0, 160\)/)
  eq('the loader owns no timer', count(loaderSrc, /\bTimer\s*\{/g), 0)
  eq('the loader owns no trace', count(loaderSrc, /\btrace\b/g), 0)
})

finish()
