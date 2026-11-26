import QtQml

// Authored hook module: inert at construction.
QtObject {
  id: root
  property var boot: null

  function resolve() { return root.boot.activate() }
  function ready() { return root.boot.ready() }
  function teardown() { root.boot.release() }
}
