pragma ComponentBehavior: Bound

// Probe: common/state/BootGate.qml - one fire per gate, on the milestone's
// transition and on the already-passed path, plus a ready flag that tracks
// only the named milestone so an early demand can be parked.
import QtQml
import QtQuick
import qs.common

Item {
  id: root

  property string error: ""
  property bool earlyBefore: true
  property bool settledBefore: true
  property bool settledAfter: false
  property int earlyFires: 0
  property var lateGate: null
  property bool lateReadyOnCreate: false
  property int lateFires: 0

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value))
  }

  // Built before either milestone: fires only through the transition watch.
  BootGate {
    id: early
    until: "played"
    onFire: root.earlyFires++
  }

  BootGate {
    id: settledGate
    until: "settled"
  }

  Component {
    id: lateComp
    BootGate {
      until: "played"
      onFire: root.lateFires++
    }
  }

  Component.onCompleted: {
    try {
      root.earlyBefore = early.ready
      root.settledBefore = settledGate.ready
      DesktopLayoutState.noteBootEntranceSettled()
      root.settledAfter = settledGate.ready
      DesktopLayoutState.noteBootEntrancePlayed("bar")
      DesktopLayoutState.noteBootEntrancePlayed("wallpaper")
    } catch (e) {
      root.error = String(e)
    }
  }

  Timer {
    interval: 60
    repeat: false
    running: true
    onTriggered: {
      // Built after the milestone: only the onCompleted fallback can fire it.
      try {
        root.lateGate = lateComp.createObject(root)
        root.lateReadyOnCreate = root.lateGate.ready
      } catch (e) {
        root.error = String(e)
      }
    }
  }

  Timer {
    interval: 180
    repeat: false
    running: true
    onTriggered: {
      root.kv("gate.error", root.error)
      root.kv("gate.earlyBefore", root.earlyBefore)
      root.kv("gate.earlyFires", root.earlyFires)
      root.kv("gate.settledBefore", root.settledBefore)
      root.kv("gate.settledAfter", root.settledAfter)
      root.kv("gate.lateReadyOnCreate", root.lateReadyOnCreate)
      root.kv("gate.lateFires", root.lateFires)
      console.log("##DONE##")
    }
  }
}
