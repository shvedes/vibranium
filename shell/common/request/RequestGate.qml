pragma Singleton
pragma ComponentBehavior: Bound
// qmllint disable unqualified

import QtQml
import Quickshell

// Monotonic request generations for asynchronous work.
//
// begin() returns an integer generation; current(), invalidate() take the
// opaque handle that current() needs, which is the generation together with
// the pair that owns it. A process start, stream callback, image decode,
// delayed retry, or completion captures the handle and asks current() before
// mutating state, so a callback that outlives its request becomes a no-op
// instead of a race.
//
// The generation space is a plain monotonic counter with no wall-clock
// source: ordering is only ever needed among requests issued in one shell
// process, and generations are not comparable across runs. A handle that was
// superseded, invalidated, or never issued is stale, so a late callback cannot
// re-open a closed request.
//
// Identity is the exact scope and key pair. Two overlays that name the same
// feature but use different keys, or the same key under different scopes,
// hold independent generations and never invalidate each other. Nothing
// derived from user data is recorded here: pairs are stored under an opaque
// key, never echoed, and no request payload is retained.
//
// The gate holds no resource of its own, so a request that must also stop a
// process, timer, or stream stops it at its own ownership site and then
// invalidates the generation.
Singleton {
  id: root

  // Half of the signed 32-bit range, leaving every issued generation
  // distinguishable from an int-typed 0 in a JavaScript comparison.
  readonly property int tokenLimit: 1073741823

  // Long enough for a component and operation name pair, short enough to
  // bound the memory a caller can spend on the gate.
  readonly property int labelLimit: 128

  // Live generation of each pair, or an absent slot when nothing is live.
  // Generations are issued once, so a pair pointing at a generation is the
  // whole test of currency: a superseded or invalidated handle fails it and
  // needs no separate record, which keeps the table bounded by the number of
  // live pairs instead of by the number of requests.
  property var _live: Object.create(null)

  // Highest generation ever issued, so a token is never reused.
  property int _ceiling: 0

  property bool _exhausted: false

  // Starts a new generation for one pair, which retires the previous
  // generation of that pair, so an in-flight callback of the superseded
  // request cannot apply. Returns 0 when the pair is not addressable or the
  // generation space is exhausted, which callers must treat as a refusal
  // rather than as a live request.
  function begin(scope, key) {
    if (!root._validLabel(scope)) return 0
    if (!root._validLabel(key)) return 0
    if (root._exhausted) return 0
    if (root._ceiling >= root.tokenLimit) {
      root._exhausted = true
      root._live = Object.create(null)
      return 0
    }

    root._ceiling = root._ceiling + 1
    root._live[root._slot(scope, key)] = root._ceiling
    return root._ceiling
  }

  function current(token) {
    if (!root._validToken(token)) return false
    return root._live[root._slot(token.scope, token.key)] === token.id
  }

  function invalidate(token) {
    if (!root._validToken(token)) return false
    const slot = root._slot(token.scope, token.key)
    if (root._live[slot] !== token.id) return false
    delete root._live[slot]
    return true
  }

  // Retires the live generation of one pair and leaves every other pair
  // alone, which is what a component needs when it owns a single key.
  function invalidateScope(scope, key) {
    if (!root._validLabel(scope)) return false
    if (!root._validLabel(key)) return false
    const slot = root._slot(scope, key)
    if (root._live[slot] === undefined) return false
    delete root._live[slot]
    return true
  }

  function _validToken(token) {
    if (token === null || typeof token !== "object" || Array.isArray(token)) return false
    if (typeof token.id !== "number") return false
    if (!isFinite(token.id) || Math.floor(token.id) !== token.id || token.id <= 0) return false
    if (token.id > root._ceiling) return false
    if (!root._validLabel(token.scope)) return false
    if (!root._validLabel(token.key)) return false
    return true
  }

  function _validLabel(label) {
    if (typeof label !== "string") return false
    if (label.trim() === "") return false
    return label.length <= root.labelLimit
  }

  // A pair is stored under an opaque key rather than as an object property,
  // so a label can never reach the object's own key space. The length prefix
  // keeps the encoding injective: a scope and key pair maps to one string,
  // and one string decodes to one pair.
  function _slot(scope, key) {
    return scope.length + ":" + scope + key
  }
}
