import QtQml
import qs.common

// Authored hook module for one unit. Boot calls these lazily: every
// singleton reference lives inside a function body, never a binding.
QtObject {
  property var boot: null

  function ready() { return HyprlandSettings.ready === true }
}
