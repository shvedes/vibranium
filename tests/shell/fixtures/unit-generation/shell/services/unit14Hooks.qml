import QtQml

// Authored hook module: inert at construction.
QtObject {
  id: root
  property var boot: null

  function resolve() { void Synthetic.tag }
  function ready() { return true }
}
