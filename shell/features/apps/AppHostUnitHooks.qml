import QtQml
import qs.features.apps

// Authored hook for the "app" unit. Inert at construction: the singleton is
// only touched when boot resolves the unit and asks for ready.
// Source: shell/boot/BootLate.qml:79-83.
QtObject {
  id: root

  property var boot: null

  function ready() {
    return AppHost.tag === "app"
  }
}
