pragma Singleton

import QtQml
import Quickshell

// Discrete event bus across layers. Two canonical patterns: services
// publish discrete state on change; bar modules read it back with
// latest() in a readonly property binding. latest() replays the last
// payload so a binding created after a publish still sees current
// state.
//
//   Bus.publish("inhibitor.bus", { active: true })
//   readonly property var state: Bus.latest("inhibitor.bus")
//
// Topics are discrete service state only (inhibitor/timer/recording/
// update); volume/workspaces stay direct service bindings and never
// go through Bus.
Singleton {
  id: root

  // topic -> { payload: any }  (fresh object per write)
  //
  // Prototype-less, the same store shape Registry uses. A plain object reads
  // an inherited member for a topic named "constructor" or "toString", so
  // latest("constructor") answered a Function for a topic nobody had
  // published, and a publish to such a name wrote through the inherited
  // value first. Every topic in the tree is a source literal, but the store
  // must not depend on that.
  property var _topics: Object.create(null)

  // --- pub/sub ---
  function publish(topic, payload) {
    const stored = root._topics[topic]
    // Existence is read with the same test the lookup below uses, so the
    // two cannot disagree about a topic whose entry is falsy - and it has
    // to be read before the write, because the write is what creates the
    // topic.
    const entry = stored || { payload: null }
    entry.payload = payload
    root._topics = Object.assign(Object.create(null), root._topics, { [topic]: entry })
  }

  function latest(topic) {
    const entry = root._topics[topic]
    if (!entry) return null
    return entry.payload
  }
}
