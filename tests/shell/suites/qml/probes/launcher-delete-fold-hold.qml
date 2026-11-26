import QtQuick
import qs.common

// A confirmation slot folded across a row-set swap. LauncherPanel cannot be
// constructed offscreen, but the failure is in the model swap itself: ListView
// replaces its delegate, so a slot still folding is born closed in the new
// row and vanishes in one frame. This probe drives the same slot and model
// swap twice: once publishing the new rows immediately, once holding them
// until the fold has run. Heights are sampled per turn - the end state is the
// same either way.

Item {
  id: root
  width: 640
  height: 200

  property int step: 0
  property bool armed: true
  property var noHold: []
  property var held: []
  property var one: [{ uid: "a", label: "Alpha" }]
  property var many: {
    const out = []
    for (let i = 0; i < 51; i++) out.push({ uid: "x" + i, label: "App " + i })
    return out
  }

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function slotAt(view) {
    const d = view.itemAtIndex(0)
    return d ? d.children[0].height : -1
  }

  List {
    id: swapped
    x: 0
    width: 300
    height: 120
    model: root.one
    interactive: false
    isSelectable: () => true
    delegate: Item {
      required property var modelData
      required property int index
      width: swapped.width
      property bool delOpen: root.armed && index === 0
      height: 40 + del.height
      ConfirmSlot {
        id: del
        width: parent.width
        open: parent.delOpen
        stage: 1
      }
    }
  }

  List {
    id: heldView
    x: 320
    width: 300
    height: 120
    model: root.one
    interactive: false
    isSelectable: () => true
    delegate: Item {
      required property var modelData
      required property int index
      width: heldView.width
      property bool delOpen: root.armed && index === 0
      height: 40 + del.height
      ConfirmSlot {
        id: del
        width: parent.width
        open: parent.delOpen
        stage: 1
      }
    }
  }

  Timer {
    interval: 16
    repeat: true
    running: true
    onTriggered: {
      root.step++
      const s = root.step
      if (s === 2) {
        root.armed = false
        swapped.model = root.many
      }
      if (s >= 2 && s <= 14) {
        root.noHold.push(slotAt(swapped))
        root.held.push(slotAt(heldView))
      }
      if (s === 9) heldView.model = root.many
      if (s === 16) {
        kv("probe.error", "none")
        kv("trace.noHold", root.noHold.join(","))
        kv("trace.held", root.held.join(","))
        kv("swap.snapped", root.noHold[1] < 0.5)
        const before = root.held.slice(0, 6)
        kv("hold.folded", before.some((h) => h > 0.5 && h < before[0] - 0.5))
        kv("hold.neverRegrew", root.held.slice(6).every(
          (h) => h <= before[before.length - 1] + 0.5))
        kv("hold.newRowClosed", slotAt(heldView) < 0.5)
        console.log("##DONE##")
        stop()
      }
    }
  }
}
