pragma Singleton
pragma ComponentBehavior: Bound
import QtQml
import Quickshell
import qs.common

Singleton {
  id: root

  // The ids carrying activation "gated_compat" in Boot's catalog: units
  // whose consumers name them directly instead of going through UnitGate.
  readonly property var _compatibilityUnits: ["archUpdates", "printers"]
  property var _report: ({})

  Component.onCompleted: root._syncReport()

  // _report is a change signal, not a result. Boot.qml binds on_ReportChanged
  // to it and recomputes the authoritative map from its own catalog, so no
  // consumer reads this value; the property is what makes that binding
  // resolvable.
  function _syncReport() {
    const snapshot = UnitGate.states()
    const units = snapshot && snapshot.units ? snapshot.units : {}
    const next = ({})
    for (const id in units) {
      if (root._compatibilityUnits.indexOf(id) < 0) continue
      const state = UnitGate.state(id)
      if (!state || state.state === "not_started" || state.state === "blocked") continue
      if (typeof state.constructionMs !== "number" || !isFinite(state.constructionMs)) continue
      next[id] = state.constructionMs
    }
    root._report = next
  }

  Connections {
    target: UnitGate
    ignoreUnknownSignals: true
    function onUnitChanged() { root._syncReport() }
    function onStatesChanged() { root._syncReport() }
  }
}
