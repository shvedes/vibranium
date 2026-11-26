.pragma library

// Phase 0 boot recorder. Direct port of specs/chat/boot-trace.prototype.cjs.
// All capture state lives in the closure returned by create(); the library
// itself is stateless, so several recorders can coexist in one engine.
// Deliberately ES5/ES2015 only: no Map/Set, no Object.fromEntries, no spread.

var SCHEMA = 2
var DETAIL_CAP = 512

var SOURCES = {
  'provider:services': 1, 'provider:features': 1, 'surface:bar': 1,
  'queue:early': 1, 'queue:entrance': 1, 'queue:deferred': 1, 'queue:replay': 1
}

var ENUMS = {
  source: SOURCES,
  milestone: { settled: 1, played: 1, construction: 1 },
  outcome: { adopted: 1, failed: 1, skipped: 1, callbackReturned: 1, callbackThrew: 1, teardown: 1, admissionComplete: 1 },
  via: { features: 1, fallback: 1, pending: 1 },
  state: { starting: 1, ready: 1, degraded: 1, unhealthy: 1 },
  queueOutcome: { accepted: 1, duplicate: 1 }
}

// Per-kind explicit field tables. Membership is always checked with
// hasOwnProperty so inherited keys (e.g. "toString") are unknown fields.
var SCHEMAS = {
  'boot.begin': { source: 'str', estimateMs: 'nullableNum' },
  'catalog.registered': { valid: 'bool', digest: 'nullableStr' },
  'milestone.decision': { milestone: 'enum:milestone', reason: 'str', participant: 'str', causes: 'refs' },
  'alreadyResolved': { milestone: 'str', participant: 'str' },
  'provider.request': { source: 'enum:source', reason: 'str', causes: 'refs' },
  'provider.result': { source: 'enum:source', outcome: 'enum:outcome', causes: 'refs' },
  'drain.eligibility': { via: 'enum:via', causes: 'refs' },
  'drain.admission': { via: 'enum:via', causes: 'refs' },
  'verdict.decision': { state: 'enum:state', causes: 'refs' },
  'endpoint.firstVerdict': { causes: 'refs' },
  'endpoint.entrancePlayed': { causes: 'refs' },
  'endpoint.drainComplete': { causes: 'refs' },
  'unit.state': { unit: 'str', state: 'str', ownerCategory: 'str', causes: 'refs' },
  'work.open': { source: 'enum:source', token: 'int', kind: 'str' },
  'work.close': { source: 'enum:source', token: 'int', outcome: 'enum:outcome' },
  'integrity.violation': { code: 'str', detail: 'str' },
  'queue.enqueue': { source: 'enum:source', outcome: 'enum:queueOutcome' },
  'queue.dispatch': { source: 'enum:source', token: 'int', waitMs: 'nullableNum' },
  'gateway.registered': { valid: 'bool', target: 'str' }
}

var ENDPOINTS = ['endpoint.firstVerdict', 'endpoint.entrancePlayed', 'endpoint.drainComplete']

function create(clock) {
  var seq = 0, tokenSeq = 0, sealed = false, sealReason = null, sealedAtMs = 0
  var finalReport = null, integrity = true, watchdogDue = -1, digest = null
  var details = [], byId = Object.create(null)
  var lossRanges = [], lostIds = [], lossTruncated = false
  var reservedById = Object.create(null), firstVerdictReserved = false
  var endpointSlots = Object.create(null)
  var verdictFirst = null, verdictCurrent = null, verdictAtSeal = null
  var tokens = Object.create(null), violations = []
  var loss = { captureDropped: 0, replyOmitted: 0 }
  var context = { source: 'unknown', estimate: null }
  var tokenCap = 32, historicalPlayed = false
  var ledger = {}
  var sourceKeys = Object.keys(SOURCES)
  for (var s = 0; s < sourceKeys.length; s++) {
    var sourceId = sourceKeys[s]
    ledger[sourceId] = { arrived: false, admissionClosed: false, terminal: null, inFlight: 0, by: null }
  }

  function violation(code, detail) {
    if (violations.length < 16) violations.push({ code: code, detail: String(detail).slice(0, 64) })
    integrity = false
  }

  // lostIds is an explicit FIFO array; the prototype used a Set.
  function isLost(id) {
    for (var i = 0; i < lostIds.length; i++) if (lostIds[i] === id) return true
    for (var j = 0; j < lossRanges.length; j++) {
      var range = lossRanges[j]
      if (id >= range[0] && id <= range[1]) return true
    }
    return false
  }
  function addLost(id) {
    if (lostIds.indexOf(id) < 0) lostIds.push(id)
    if (lostIds.length > 16) { lostIds.shift(); lossTruncated = true }
  }
  function noteLoss(id) {
    var last = lossRanges[lossRanges.length - 1]
    if (last && id === last[1] + 1) last[1] = id
    else {
      lossRanges.push([id, id])
      if (lossRanges.length > 8) { lossRanges.shift(); lossTruncated = true }
    }
  }

  function validType(type, value) {
    if (value === null) return type === 'nullableNum' || type === 'nullableStr'
    if (type === 'bool') return typeof value === 'boolean'
    if (type === 'str') return typeof value === 'string' && value.length <= 64
    if (type === 'nullableStr') return typeof value === 'string' && value.length <= 64
    if (type === 'num' || type === 'nullableNum') return typeof value === 'number' && isFinite(value)
    if (type === 'int') return typeof value === 'number' && Math.floor(value) === value
    if (type === 'refs') {
      if (!Array.isArray(value) || value.length > 16) return false
      for (var i = 0; i < value.length; i++) {
        if (typeof value[i] !== 'number' || Math.floor(value[i]) !== value[i]) return false
      }
      return true
    }
    if (type.indexOf('enum:') === 0) {
      var domain = ENUMS[type.slice(5)]
      return !!domain && typeof value === 'string' && domain[value] === 1
    }
    return false
  }

  function check(kind, fields) {
    if (!Object.prototype.hasOwnProperty.call(SCHEMAS, kind)) { violation('unknownKind', kind); return null }
    var schema = SCHEMAS[kind]
    var out = Object.create(null)
    var supplied = fields || {}
    var givenKeys = Object.keys(supplied)
    for (var g = 0; g < givenKeys.length; g++) {
      if (!Object.prototype.hasOwnProperty.call(schema, givenKeys[g])) { violation('unknownField', givenKeys[g]); return null }
    }
    var schemaKeys = Object.keys(schema)
    for (var k = 0; k < schemaKeys.length; k++) {
      var key = schemaKeys[k]
      var value = fields && fields[key]
      if (value === undefined) continue
      if (!validType(schema[key], value)) { violation('valueDomain', key); return null }
      out[key] = key === 'causes' ? value.slice() : value
    }
    if (out.causes) {
      for (var c = 0; c < out.causes.length; c++) {
        var id = out.causes[c]
        if (id <= 0 || id > seq) { violation('forwardCause', id); return null }
        // Any id in [1..seq] was allocated; classification may later be lost.
        if (id > seq) { violation('forwardCause', id); return null }
      }
    }
    return out
  }

  function emit(kind, fields) {
    if (sealed) return null
    var checked = check(kind, fields)
    if (!checked) return null
    // Duplicate endpoint reports return the FIRST id without allocating.
    if (ENDPOINTS.indexOf(kind) >= 0 && endpointSlots[kind]) return endpointSlots[kind].eventId
    var eventId = ++seq
    var t = clock.now()
    var event = { eventId: eventId, kind: kind, tMs: t < 0 ? 0 : t }
    var checkedKeys = Object.keys(checked)
    for (var ck = 0; ck < checkedKeys.length; ck++) event[checkedKeys[ck]] = checked[checkedKeys[ck]]
    if (t < 0) event.preOrigin = true
    if (details.length < DETAIL_CAP) {
      details.push(event)
      byId[eventId] = event
    } else {
      noteLoss(eventId)
      loss.captureDropped++
    }
    // Reserved layer: only a bounded set (first endpoint per name + first verdict).
    if (ENDPOINTS.indexOf(kind) >= 0 || (kind === 'verdict.decision' && !firstVerdictReserved)) {
      reservedById[eventId] = event
      if (kind === 'verdict.decision') firstVerdictReserved = true
    }
    if (ENDPOINTS.indexOf(kind) >= 0 && !endpointSlots[kind]) endpointSlots[kind] = event
    if (kind === 'verdict.decision') {
      var fact = { state: event.state, atMs: event.tMs, eventId: eventId }
      if (!verdictFirst) copyFact(fact, true)
      verdictCurrent = fact
    }
    return eventId
  }

  function copyFact(fact, asFirst) {
    var copy = { state: fact.state, atMs: fact.atMs, eventId: fact.eventId }
    if (asFirst) verdictFirst = copy
    return copy
  }
  function copyVerdict(fact) {
    if (!fact) return null
    return { state: fact.state, atMs: fact.atMs, eventId: fact.eventId }
  }

  function openWork(source, kind) {
    if (!SOURCES[source]) { violation('unknownSource', source); return 0 }
    if (Object.keys(tokens).length >= tokenCap) { violation('tokenOverflow', source); return 0 }
    var token = ++tokenSeq
    tokens[token] = { owner: source, closed: false }
    ledger[source].arrived = true
    ledger[source].inFlight++
    emit('work.open', { source: source, token: token, kind: kind || 'request' })
    return token
  }
  function closeWork(source, token, outcome) {
    if (!token) return false
    if (!SOURCES[source]) { violation('unknownSource', source); return false }
    var entry = tokens[token]
    if (!entry || entry.owner !== source || entry.closed) { violation('badClose', source); return false }
    delete tokens[token]
    ledger[source].inFlight--
    emit('work.close', { source: source, token: token, outcome: outcome })
    maybeComplete(source)
    return true
  }
  function closeAdmission(source, by) {
    if (!SOURCES[source]) { violation('unknownSource', source); return }
    ledger[source].admissionClosed = true
    ledger[source].by = by
    maybeComplete(source)
  }
  function skip(source, reason) {
    if (!SOURCES[source]) { violation('unknownSource', source); return }
    ledger[source].admissionClosed = true
    ledger[source].by = reason
    ledger[source].terminal = 'skipped'
  }
  function maybeComplete(source) {
    var row = ledger[source]
    if (row.admissionClosed && row.inFlight === 0 && row.terminal === null) row.terminal = 'admissionComplete'
  }
  function alreadyResolved(milestone, participant) {
    if (milestone === 'played') historicalPlayed = true
    emit('alreadyResolved', { milestone: milestone, participant: participant || '' })
  }
  function normalAllowed() {
    if (!integrity || !verdictFirst) return false
    if (!endpointSlots['endpoint.entrancePlayed'] && !hasHistoricalPlayed()) return false
    if (Object.keys(tokens).length > 0) return false
    for (var i = 0; i < sourceKeys.length; i++) if (ledger[sourceKeys[i]].terminal === null) return false
    return true
  }
  function hasHistoricalPlayed() { return historicalPlayed }
  function openSources() {
    var out = []
    for (var i = 0; i < sourceKeys.length; i++) {
      var id = sourceKeys[i]
      if (ledger[id].arrived && ledger[id].terminal === null) out.push(id)
    }
    return out
  }
  function seal(reason) {
    if (sealed) return detached(finalReport)
    if (reason === 'normal' && !normalAllowed()) {
      // A refused normal seal is not an integrity violation: leave capture
      // running and integrity untouched so the caller can fix the conditions.
      return snapshot()
    }
    if (['normal', 'aborted', 'watchdog'].indexOf(reason) < 0) {
      violation('unknownSealReason', reason)
      return snapshot()
    }
    sealed = true
    sealReason = reason
    sealedAtMs = clock.now()
    verdictAtSeal = copyVerdict(verdictCurrent)
    finalReport = project(true)
    return detached(finalReport)
  }
  function armWatchdog(nowMs, windowMs) { if (!sealed && watchdogDue < 0) watchdogDue = nowMs + windowMs }
  function watchdogFired(nowMs) {
    if (sealed || watchdogDue < 0 || nowMs < watchdogDue) return false
    seal('watchdog')
    return true
  }
  function snapshot() { return sealed ? detached(finalReport) : detached(project(false)) }

  function project(isSealed) {
    var endpoints = {}
    for (var e = 0; e < ENDPOINTS.length; e++) {
      var epKey = ENDPOINTS[e]
      if (endpointSlots[epKey]) endpoints[epKey.slice(9)] = endpointSlots[epKey].tMs
    }
    var ledgerCopy = {}
    for (var l = 0; l < sourceKeys.length; l++) {
      var lk = sourceKeys[l]
      ledgerCopy[lk] = copyLedgerRow(ledger[lk])
    }
    var report = {
      schema: SCHEMA, sealed: isSealed, sealReason: isSealed ? sealReason : null,
      sealedAtMs: isSealed ? sealedAtMs : null,
      observedThroughMs: clock.now(),
      integrity: { valid: integrity, violations: violations.slice() },
      origin: { source: context.source, launcherToQmlEstimateMs: context.estimate },
      endpoints: endpoints,
      firstVerdict: copyVerdict(verdictFirst),
      verdictAtSeal: isSealed ? copyVerdict(verdictAtSeal) : null,
      currentVerdict: copyVerdict(verdictCurrent),
      ledger: ledgerCopy,
      chains: {}, graphDigest: digest,
      coverage: {
        captureDropped: loss.captureDropped, replyOmitted: loss.replyOmitted,
        preOriginEvents: countPreOrigin(),
        lossRanges: lossRanges.length, explicitLosses: lostIds.length,
        reservedEntries: Object.keys(reservedById).length,
        lossTruncated: lossTruncated,
        missingInstrumentation: []
      },
      truncated: loss.captureDropped + loss.replyOmitted > 0
    }
    for (var q = 0; q < ENDPOINTS.length; q++) {
      var chainKey = ENDPOINTS[q]
      var slot = endpointSlots[chainKey]
      report.chains[chainKey.slice(9)] = slot ? walk(slot) : { status: 'unobserved', chain: [], unobserved: [chainKey] }
    }
    return report
  }
  function copyLedgerRow(row) {
    return {
      arrived: row.arrived, admissionClosed: row.admissionClosed, terminal: row.terminal,
      inFlight: row.inFlight, by: row.by
    }
  }
  function countPreOrigin() {
    var n = 0
    for (var i = 0; i < details.length; i++) if (details[i].preOrigin) n++
    return n
  }

  function walk(endpointEvent) {
    var chain = [], parallel = []
    var cur = endpointEvent
    var seen = Object.create(null)
    var partial = []
    while (cur && cur.causes && cur.causes.length) {
      var best = null
      var candidates = []
      for (var i = 0; i < cur.causes.length; i++) {
        var id = cur.causes[i]
        var candidate = byId[id] || reservedById[id]
        if (!candidate) { partial.push({ id: id, reason: isLost(id) ? 'captureLoss' : 'unknown' }); continue }
        candidates.push(candidate)
        if (!best || candidate.tMs > best.tMs || (candidate.tMs === best.tMs && candidate.eventId > best.eventId)) best = candidate
      }
      for (var c = 0; c < candidates.length; c++) {
        var other = candidates[c]
        if (other !== best) parallel.push({ eventId: other.eventId, kind: other.kind, tMs: other.tMs, participant: other.participant })
      }
      if (!best || seen[best.eventId]) break
      seen[best.eventId] = true
      chain.unshift({ eventId: best.eventId, kind: best.kind, tMs: best.tMs, participant: best.participant })
      cur = best
    }
    if (!cur || cur.kind !== 'boot.begin') partial.push({ reason: 'root' })
    return { status: partial.length ? 'partial' : 'complete', chain: chain, parallel: parallel, unobserved: partial }
  }

  function detached(value) { return JSON.parse(JSON.stringify(value)) }

  return {
    emit: emit,
    openWork: openWork,
    closeWork: closeWork,
    closeAdmission: closeAdmission,
    skip: skip,
    alreadyResolved: alreadyResolved,
    armWatchdog: armWatchdog,
    watchdogFired: watchdogFired,
    seal: seal,
    snapshot: snapshot,
    setContext: function (env, d) {
      context = env || { source: 'unknown', estimate: null }
      digest = d || null
    },
    setTokenCap: function (n) { tokenCap = n },
    injectLoss: function (fixtureId, map) {
      var id = map[fixtureId]
      if (id && byId[id]) {
        addLost(id)
        delete byId[id]
        loss.captureDropped++
      }
    }
  }
}
