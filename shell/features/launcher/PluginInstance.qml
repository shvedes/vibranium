import QtQml
import Quickshell

// Per-plugin JS host: one instance per plugin directory. Evaluating
// the plugin source inside this instance's own function scope gives
// each folder its own engine state; destroying the instance unloads
// it. No .pragma library here on purpose - sharing is the bug.
QtObject {
  id: host
  property var impl: null
  property string error: ""
  function evaluate(source) {
    var VibraniumPlugin = null
    try {
      eval(source)
    } catch (e) {
      host.error = "" + (e.message || e)
      return false
    }
    if (VibraniumPlugin === null) {
      host.error = "did not assign VibraniumPlugin"
      return false
    }
    if (typeof VibraniumPlugin.items !== "function"
      || typeof VibraniumPlugin.activate !== "function") {
      host.error = "items/activate must be functions"
      return false
    }
    host.impl = VibraniumPlugin
    return true
  }
}
