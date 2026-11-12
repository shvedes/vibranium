// Shared demand/lease machinery for a facade over one unit's controller.
//
// Each app surface (the mixer, the viewer, the launcher, the password panel) is
// a resident singleton that builds exactly one controller on first use, holds a
// UnitGate lease for it, and reports a state a consumer can read. When the
// controller should be released is each surface's own policy; the lease, the
// state, the construction counter and the Loader are the same for all of them,
// so they live here instead of being copied into every facade.
import QtQuick
import qs.common

Item {
  id: host

  property string unitId: ""
  // One constant owner per facade: UnitGate matches leases by owner, so a
  // second demand finds the lease that already exists rather than minting a
  // parallel one, and the name is neither Boot's nor a bar module's, so a
  // release here can never take down a lease someone else is holding.
  property string owner: ""
  property Component controllerComponent: null

  // The built controller, or null while the unit is unloaded.
  readonly property var controller: loader.item

  // unloaded | loading | ready | unavailable | failed. A verb that cannot run
  // answers from this instead of vanishing.
  property string phase: "unloaded"
  property string error: ""
  // Controllers built since boot: the visible proof that a facade
  // construction does no work and a demand builds exactly one controller.
  property int constructions: 0

  property var _lease: null
  // Set while a teardown the gate performs from inside a release would
  // otherwise restate "unloaded" in the middle of a demand that is about to
  // report why it failed.
  property bool _unwinding: false

  // Build the controller on demand and keep exactly one. Repeated callers all
  // land here, and every path out (refused lease, failed construction, unload)
  // drops the lease again, so a refused or failed caller leaves the next one a
  // clean unit.
  function demand() {
    if (host.phase === "ready" && host.controller !== null) return host.controller
    const result = UnitGate.ensure(host.unitId, host.owner)
    if (!result || result.ok !== true) {
      // A blocked, failed or unregistered unit still hands back a lease for
      // two of those three; give it straight back so the record cannot collect
      // owners for a demand that never loaded.
      if (result && result.lease) host._lease = result.lease
      host._dropLease()
      const failed = result && result.state === "failed"
      host._setState(failed ? "failed" : "unavailable", failed ? "unit" : "gate")
      return null
    }
    if (result.lease !== host._lease) {
      host._lease = result.lease
      // Retained, not merely held: a stray single release (a failed caller
      // unwinding) must not be able to drop the unit under a live surface.
      UnitGate.retain(result.lease)
    }
    host._setState("loading")
    loader.active = true
    if (host.controller === null) {
      host.unloadFor("unavailable", "load")
      return null
    }
    if (host.controller.startupError !== "") {
      // A Loader cannot raise a construction error to its caller, so the
      // controller reports it and the facade answers unavailable and unloads:
      // the next caller starts from an unloaded unit.
      host.unloadFor("failed", host.controller.startupError)
      return null
    }
    host.constructions++
    host._setState("ready")
    return host.controller
  }

  // Drop the controller and the lease, then state the outcome.
  function unloadFor(next, code) {
    host._unwinding = true
    host.unload()
    host._unwinding = false
    host._setState(next, code)
  }

  // Drop the controller and the lease without touching the reported state. A
  // caller that is about to answer unavailable or failed unwinds through here,
  // so the state it reports is the last one a consumer sees instead of
  // flapping through "unloaded" on the way there.
  function unload() {
    const held = host._lease !== null || loader.item !== null
    loader.active = false
    host._dropLease()
    return held
  }

  // Idempotent and callable with nothing loaded: a facade's teardown hook and
  // a close settle both land here, and the second call is a no-op rather than
  // a double release.
  function teardown() {
    const held = host.unload()
    if (!host._unwinding) host._setState("unloaded")
    return held
  }

  // The gate's teardown hook drops this owner's whole lease set in one call, so
  // the ensure and the retain that came with it go together and a lost release
  // cannot leave the record counting an owner nobody holds.
  function _dropLease() {
    if (host._lease === null) return false
    host._lease = null
    return UnitGate.releaseOwner(host.owner) > 0
  }

  function _setState(next, code) {
    const detail = code || ""
    if (host.phase === next && host.error === detail) return
    host.phase = next
    host.error = detail
    // Nothing polls a demand-loaded unit, so the record is settled here: the
    // gate must not sit in "starting" once the controller is up.
    if (next === "ready") UnitGate.refresh(host.unitId)
  }

  // The controller, and nothing else: a Loader with no source until the first
  // demand, so a facade that is only a registry entry holds no work.
  Loader {
    id: loader
    active: false
    sourceComponent: host.controllerComponent
  }
}
