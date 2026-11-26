import QtQml
import qs.features.notifications

// Authored hook for the "notifications" unit. Inert at construction: the
// singleton is only touched when boot resolves the unit and asks for ready.
// Source: shell/boot/BootLate.qml:69-73.
QtObject {
  id: root

  property var boot: null

  function ready() {
    return Notifications.tag === "notifications"
  }
}
