import QtQml
import qs.common

// Authored hook module for one unit. Boot calls these lazily: every
// singleton reference lives inside a function body, never a binding.
QtObject {
  property var boot: null

  function resolve() { void Paths.home }
  function ready() { return typeof Paths.home === "string" && Paths.home !== "" }
}
