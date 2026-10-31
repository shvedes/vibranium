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
  property var _topics: ({})

  // --- pub/sub ---
  function publish(topic, payload) {
    const stored = root._topics[topic]
    // Existence is read with the same test the lookup below uses, so the
    // two cannot disagree about a topic whose entry is falsy - and it has
    // to be read before the write, because the write is what creates the
    // topic.
    const entry = stored || { payload: null }
    entry.payload = payload
    root._topics = Object.assign({}, root._topics, { [topic]: entry })
  }

  function latest(topic) {
    const entry = root._topics[topic]
    if (!entry) return null
    return entry.payload
  }
}
