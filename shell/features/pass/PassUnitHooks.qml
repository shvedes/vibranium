import QtQml
import qs.features.pass

// Authored hooks for the "pass" unit. Inert at construction: the Connections
// target starts null so Pass is not instantiated before its turn. The lazy
// observation is attached once, on first resolve, and carries only later
// readiness transitions (boot refreshes the unit right after resolve()).
// Source: shell/boot/BootLate.qml:124-131 and 190-200.
QtObject {
  id: root

  property var boot: null
  property Connections passConnection: Connections {
    target: null
    function onInitializedChanged() {
      if (root.boot) root.boot._refreshUnit("pass")
    }
  }

  function resolve() {
    void Pass.tag
    _observePass()
  }

  function ready() {
    return Pass.facadeReady === true
  }

  function teardown() {
    Pass.teardownController()
  }

  function _observePass() {
    if (passConnection.target === null) passConnection.target = Pass
  }
}
