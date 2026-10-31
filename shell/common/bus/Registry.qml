pragma Singleton

import QtQml
import Quickshell

// Registry bridge for QS components to talk directly without spawning
// `qs ipc call` processes. Any singleton can register itself under a name
// and peers can invoke its methods or read its properties through this hub.
//
//   Registry.register("appLauncher", AppLauncher)
//   Registry.call("appLauncher", "clearUsageHistory")
//   Registry.get("appLauncher", "hasUsageHistory")
//
// Discrete cross-layer events go through Bus; the registry is for direct
// command/read of a registered unit.
//
// No module imports the hub's clients, so circular dependencies are avoided:
// both sides import only `qs.common`.
//
// The return values are unchanged: `call()` still answers null for a name
// that is not registered and for a member that is not callable, because
// callers compare against that null.
Singleton {
  id: root

  property var _registry: Object.create(null)
  property var _offers: Object.create(null)   // id -> { title, description, verbNames }

  function offer(id, meta) {
    if (typeof id !== "string" || id === "") return
    const next = Object.assign(Object.create(null), root._offers)
    next[id] = meta
    root._offers = next
  }

  function offers() { return Object.keys(root._offers) }

  function register(name, obj) {
    if (typeof name !== "string" || name === "" || !obj) {
      return
    }
    const next = Object.assign(Object.create(null), root._registry)
    next[name] = obj
    root._registry = next
    // The other half of `offer`, and the two are not the same set: a unit that
    // offers has an IPC socket surface, a unit that registers can be COMMANDED
    // in-process. Most units need only one, so the two counts differ, and many
    // units offer without registering - which means `Registry.call` on one of
    // them answers null forever, with the same null a typo produces. That is
    // the shape of the design, not a wiring bug.
  }

  // The registered names, sorted. A read rather than a property because
  // `_registry` holds live QObjects and a caller that only wants the names
  // should not be handed the objects.
  function registeredIds() {
    return Object.keys(root._registry).sort()
  }

  function unregister(name) {
    if (!Object.prototype.hasOwnProperty.call(root._registry, name)) {
      return
    }
    const next = Object.assign(Object.create(null), root._registry)
    delete next[name]
    root._registry = next
  }

  // `null` is the one answer every caller checks, and it answers for two
  // unrelated reasons: a name nothing registered, and a member that is not
  // callable. Callers cannot tell them apart - the caller's `=== null` test is
  // what hides the difference - so the two refusals stay two separate branches.
  //
  // The two refusals mean opposite things and only one of them is a problem:
  // an unknown name is a unit that is not registered, which for a
  // non-eager unit (facade, first_use, gated_compat) is CORRECT until
  // something uses it; a non-callable member is a caller naming a verb that
  // does not exist, which is always a bug on the caller's side.
  function call(name, method) {
    const args = Array.prototype.slice.call(arguments, 2)

    const target = root._registry[name]
    if (!target) {
      return null
    }
    const fn = target[method]
    if (typeof fn !== "function") {
      return null
    }

    // A callee's throw is propagated, never contained. Swallowing it would make
    // a broken callee look like a `null` answer to every caller that does
    // `if (Registry.call(...) === true)`, which converts a crash into a silent
    // no-op - so the exception reaches the caller unchanged.
    return fn.apply(target, args)
  }

  function get(name, prop) {
    const target = root._registry[name]
    if (!target) return undefined
    return target[prop]
  }

}
