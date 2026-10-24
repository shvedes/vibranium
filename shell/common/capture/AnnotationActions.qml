pragma Singleton

import Quickshell

// Neutral request/result contract between the headless capture service and
// the on-demand annotation controller. The service never names an
// annotation type: it asks for a view with a typed request, gets a typed
// request id back, and learns the outcome through one signal. The
// controller adopts one stable handler and owns every view object it
// builds, so presentation stays in the feature and capture state stays in
// the service.
//
//   AnnotationActions.adopt(handler)                   // annotation controller
//   const res = AnnotationActions.request("region", spec)      // service
//   AnnotationActions.settle(res.id, outcome)          // annotation controller
//   AnnotationActions.close(res.id)                    // service teardown
//
// The adopted handler takes one typed command record and answers
// true, "busy" or a refusal for an open; the other three commands carry
// the request id and are resolved from the same slots the open filled, so
// a command can never name a view the controller does not hold.
//
// Ids only move forward and a settled outcome fires synchronously inside
// settle(), so a capture flow continues on the same tick it asked for the
// view and an answer for a superseded id is refused instead of
// overwriting a newer one. Every entry point answers a defined value: an
// absent controller is "no_controller", never a silent no-op.
//
// A request record is a frozen, per-kind whitelist and an outcome record is
// a frozen, per-kind code vocabulary, so neither side can smuggle an
// untyped field across the boundary. One exception is deliberate: a region
// acceptance carries the grab result the capture pipeline still has to
// save. That value is an in-process handle, lives only until the service
// releases the id, and is never serialized.
Singleton {
  id: root

  // The one cross-boundary signal. A view that is already gone, an id the
  // service has stopped tracking, or a code the kind does not define is
  // refused, so only a real, matched outcome ever reaches a consumer.
  signal settled(int id, var outcome)

  // Emitted the first time the last live request is released, so the demand
  // side can let the controller go instead of holding a demand-loaded unit
  // for the rest of the session. It is a demand-side hint, not a teardown:
  // a request that arrives during the grace period keeps the controller.
  signal drained()

  readonly property var kinds: Object.freeze(["picker", "region", "editor"])

  // One controller answers requests. A second handler is refused so two
  // controllers cannot both claim a request, and identity comparison is
  // what keeps a re-adopt of the same controller idempotent.
  property var _handler: null
  property int _generation: 0
  // id -> frozen request record. A plain object, not a reactive property:
  // nothing binds to the map, every read goes through spec().
  property var _requests: Object.create(null)
  // The demand hook. The composition root binds a function that builds the
  // controller; common never names an annotation type, so this is a
  // callback, not an import. A service that asks for a view while no
  // controller exists asks the hook first and retries once.
  property var _ensure: null
  // A hook that throws, or that comes back without a controller, is not
  // called again for this contract instance: one refused demand must not
  // turn a capture flow into a construction loop.
  property int _ensureRefusals: 0

  function hasController() {
    return root._handler !== null
  }

  function liveRequests() {
    return Object.keys(root._requests).length
  }

  // Bound by the composition root only. Rebinding the same function is a
  // no-op, so a reload that re-runs the binding cannot orphan a controller
  // that already adopted.
  function bind(ensureFn) {
    if (typeof ensureFn !== "function") return false
    if (root._ensure === ensureFn) return true
    root._ensure = ensureFn
    root._ensureRefusals = 0
    return true
  }

  // The demand side's answer: build the controller, or say why not. The hook
  // may return true (built), false (a construction that failed, terminal) or
  // "pending" (the unit is not ready yet, so the next demand asks again).
  // Returning nothing at all means the hook did not report, which is
  // treated as terminal so a silently broken hook cannot spin.
  //
  // The distinction matters: a capture keypress during startup is refused
  // because settings are not ready yet, and latching that would leave the
  // annotation flow dead for the whole session.
  function ensureController() {
    if (root._handler !== null) return true
    if (root._ensure === null) return false
    if (root._ensureRefusals > 0) return false
    let answered
    try {
      answered = root._ensure()
    } catch (ignored) {
      root._ensureRefusals++
      return false
    }
    if (root._handler !== null) return true
    if (answered === "pending") return false
    root._ensureRefusals++
    return false
  }

  function adopt(handler) {
    if (typeof handler !== "function") return false
    if (root._handler !== null && root._handler !== handler) return false
    root._handler = handler
    return true
  }

  function release(handler) {
    if (root._handler !== handler) return false
    root._handler = null
    return true
  }

  // The typed request entry point. The id is minted and published BEFORE the
  // controller is called, and the record is installed before it too. Both
  // matter: a view that settles synchronously out of its own construction
  // has to be able to find the record and the id it is settling, or the
  // outcome is dropped and the service waits forever for an answer that
  // cannot arrive.
  //
  // A request the controller refused gives its record back but keeps the id
  // spent. An id is never reused, because a late outcome for a refused open
  // would then attach to whatever request reuses the number.
  function request(kind, raw) {
    const normalized = root._spec(kind, raw)
    if (normalized === null) return { ok: false, code: "invalid", id: 0 }
    if (root._handler === null && !root.ensureController()) {
      return { ok: false, code: "no_controller", id: 0 }
    }
    const id = root._generation + 1
    root._generation = id
    root._requests[id] = normalized
    const answer = root._command({ code: "open", id: id, request: normalized })
    if (answer === true) return { ok: true, code: "opened", id: id }
    // The controller did not take the view, so nothing is tracking it.
    delete root._requests[id]
    if (answer === "busy") return { ok: false, code: "busy", id: 0 }
    return { ok: false, code: "refused", id: 0 }
  }

  // The request a live id was created from, or null. This is the identity
  // the capture flow validates against instead of reading fields off a
  // view object it does not own.
  function spec(id) {
    const key = root._key(id)
    if (key === null) return null
    const record = root._requests[key]
    return record === undefined ? null : record
  }

  // The controller's answer. Normalized against the id's kind before the
  // signal fires, so a consumer can switch on a closed vocabulary instead
  // of probing optional fields.
  function settle(id, raw) {
    const key = root._key(id)
    if (key === null) return false
    const record = root._requests[key]
    if (record === undefined) return false
    const outcome = root._outcome(record.kind, raw)
    if (outcome === null) return false
    root.settled(key, outcome)
    return true
  }

  // Output reconciliation: the screen object for a live id is replaced, and
  // the stored record follows so a later spec() read sees the current one.
  function retarget(id, screen) {
    const key = root._key(id)
    if (key === null) return false
    const record = root._requests[key]
    if (record === undefined || screen === null || screen === undefined) return false
    const next = Object.freeze(Object.assign({}, record, { screen: screen }))
    root._requests[key] = next
    root._command({ code: "retarget", id: key, screen: screen })
    return true
  }

  // The service is done with the view: it goes now. Idempotent, so a
  // teardown that races a settled outcome is a no-op rather than a double
  // destroy.
  function close(id) {
    return root._release(id, "close")
  }

  // The view is closing itself (it already answered), so only the tracking
  // is dropped - the controller keeps the object until it is gone.
  function abandon(id) {
    return root._release(id, "abandon")
  }

  function _release(id, code) {
    const key = root._key(id)
    if (key === null) return false
    const record = root._requests[key]
    if (record === undefined) return false
    delete root._requests[key]
    root._command({ code: code, id: key, kind: record.kind })
    // The last release is what lets a demand-loaded controller go. It is
    // only ever a hint: the demand side re-reads liveRequests() when its
    // grace period expires, so a request that opened in between keeps the
    // controller alive.
    if (root.liveRequests() === 0) root.drained()
    return true
  }

  function _command(command) {
    if (root._handler === null) return null
    const frozen = Object.freeze(command)
    try {
      return root._handler(frozen)
    } catch (ignored) {
      return null
    }
  }

  // --- typed records ---
  function _spec(kind, raw) {
    if (root.kinds.indexOf(String(kind)) < 0) return null
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null
    if (raw.screen === null || raw.screen === undefined) return null
    const fields = root._fields(String(kind))
    const record = { kind: String(kind), screen: raw.screen }
    for (let i = 0; i < fields.length; i++) {
      const field = fields[i]
      if (Object.prototype.hasOwnProperty.call(record, field)) continue
      const value = raw[field]
      record[field] = value === undefined ? null : value
    }
    return Object.freeze(record)
  }

  function _outcome(kind, raw) {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null
    const codes = root._codes(String(kind))
    const code = String(raw.code)
    if (codes.indexOf(code) < 0) return null
    const fields = root._outcomes(String(kind))[code]
    const record = { code: code }
    for (let i = 0; i < fields.length; i++) {
      const field = fields[i]
      const value = raw[field]
      record[field] = value === undefined ? null : value
    }
    return Object.freeze(record)
  }

  function _fields(kind) {
    if (kind === "picker") return []
    if (kind === "region") {
      return ["url", "frameW", "frameH", "immediate", "jobId", "flowId"]
    }
    return ["shotPath", "savePath", "saveToDisk", "fileType", "runtimeDir",
      "directSource", "flowId"]
  }

  function _codes(kind) {
    if (kind === "picker") return ["chosen", "cancelled", "closed"]
    if (kind === "region") return ["accepted", "cancelled", "failed"]
    return ["closed"]
  }

  function _outcomes(kind) {
    if (kind === "picker") {
      return { chosen: ["mode"], cancelled: [], closed: [] }
    }
    if (kind === "region") {
      // grab/grabFrameW/grabFrameH carry the accepted frame the capture
      // pipeline still has to save; they are in-process handles, dropped
      // with the request record.
      return {
        accepted: ["x", "y", "w", "h", "grab", "grabFrameW", "grabFrameH"],
        cancelled: [],
        failed: ["reason"]
      }
    }
    return { closed: [] }
  }

  function _key(id) {
    const key = Number(id)
    if (!isFinite(key) || key <= 0 || Math.floor(key) !== key) return null
    if (key > root._generation) return null
    return key
  }
}
