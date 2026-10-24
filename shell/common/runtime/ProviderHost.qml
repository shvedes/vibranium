pragma Singleton

import Quickshell
import qs.common

Singleton {
  id: root

  property var _host: null
  property var _providers: Object.freeze({})

  function registerProvider(id, provider, owner) {
    const refusal = root._refusalFor(id, provider, owner)
    if (refusal !== "") {
      // The one report a refusal gets, and the place the refusal string is not
      // thrown away. Every caller that wrapped this in a warning of its own
      // could only say "could not claim", so a caller's own bad argument was
      // reported as somebody else's live owner; `_refusalFor` already knows
      // which of the three it was.
      //
      // WARN rather than DEBUG because a caller handles the refusal by
      // retrying, and one that cannot is a contract violation the reader has
      // to see - the id is bounded because it is the caller's own string, not
      // this file's vocabulary.
      Log.warn("refused provider " + Log.summarize(id) + ": " + refusal
        + ", asked by " + root._ownerName(owner))
      return false
    }
    const record = root._recordFor(id)
    const next = Object.assign({}, root._providers)
    next[id] = Object.freeze({ provider: provider, owner: owner })
    root._providers = Object.freeze(next)
    if (root._host && typeof root._host.registerProvider === "function") {
      root._host.registerProvider(id, provider)
    }
    return true
  }

  // Why a provider id was not taken, as a closed set, or "" when it was.
  //
  // This is the only place that knows. The callers that wrap it had six
  // copies of the same warning sentence and none of them could say which of
  // these three it was, so "a live foreign owner holds it" was printed for a
  // bad argument too - a caller's bug reported as somebody else's.
  function _refusalFor(id, provider, owner) {
    if (!root._validId(id)) return "the id is not usable"
    if (!root._validProvider(provider)) return "the provider is not an object"
    const record = root._recordFor(id)
    if (record === null) return ""
    if (root._isUnowned(record.owner)) {
      if (!root._isUnowned(owner) || record.provider !== provider) return "another provider already offers it"
      return ""
    }
    if (record.owner !== owner) return "another unit already offers it"
    return ""
  }

  // The owner is a live QML object and an object is not a value this log
  // publishes. `tag` is the shell's own name for a singleton, the same
  // derivation DesktopLayoutState._ownerName makes, so one owner cannot be
  // printed under two names.
  //
  // Only the ASKING owner is named and it is the live caller: every unit that
  // registers hands in `root`, which is on the stack and cannot be a
  // half-destroyed object by the time this reads it. The owner a record is
  // already held by is never read here, which is why this needs no guard
  // against a half-destroyed read.
  function _ownerName(owner) {
    if (root._isUnowned(owner)) return "none"
    if (typeof owner === "string") return Log.summarize(owner)
    if (typeof owner.tag === "string" && owner.tag !== "") return owner.tag
    return "unknown"
  }

  function unregisterProvider(id, owner) {
    if (!root._validId(id)) return false
    const record = root._recordFor(id)
    if (record === null) return false
    if (root._isUnowned(record.owner)) {
      if (!root._isUnowned(owner)) return false
    } else if (record.owner !== owner) {
      return false
    }
    const next = Object.assign({}, root._providers)
    delete next[id]
    root._providers = Object.freeze(next)
    if (root._host && typeof root._host.unregisterProvider === "function") {
      root._host.unregisterProvider(id)
    }
    return true
  }

  function providerFor(id) {
    if (!root._validId(id)) return null
    const record = root._recordFor(id)
    return record === null ? null : record.provider
  }

  function _recordFor(id) {
    if (!Object.prototype.hasOwnProperty.call(root._providers, id)) return null
    return root._providers[id]
  }

  function _isUnowned(owner) {
    return owner === undefined || owner === null
  }

  function _validId(id) {
    return typeof id === "string" && id.trim() !== ""
  }

  function _validProvider(provider) {
    return provider !== null && typeof provider === "object" && !Array.isArray(provider)
  }
}
