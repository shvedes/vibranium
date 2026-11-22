// Probe: the two bar pill clocks (BAR-1, BAR-2, BAR-3).
//
// Two checks share this probe:
//
//   1. Frame check. A pill whose width is one binding of animated scalars is
//      sampled on consecutive turns. It must equal that binding at every
//      turn (no lagging second clock) and its curve must be monotone (no
//      correction frame). A cycle's shownRow is sampled across the 0.5
//      midpoint: the outgoing row must never be painted after the land.
//
//   2. Source check. The suite passes the two real module files in through
//      the environment, so the structural half of the contract is checked
//      against the files under test, not against a copy of them. A shape
//      probe alone would stay green however the real files were edited.
//
// The mini model uses the real BatteryModel.cycleKey for the row walk; the
// row derivation and the width expression are the ones the fixed modules use.

import QtQuick
import Quickshell
import "common/power/BatteryModel.js" as Model

Item {
  id: root
  width: 400
  height: 240

  property bool done: false
  property int turn: 0

  // --- source under test, handed in by the suite ---------------------------

  readonly property string batterySrc: Quickshell.env("BAR_BATTERY_SRC") || ""
  readonly property string nowPlayingSrc: Quickshell.env("BAR_NOWPLAYING_SRC") || ""

  function countOf(s, needle) {
    let n = 0
    let at = 0
    while (true) {
      const found = s.indexOf(needle, at)
      if (found < 0) return n
      n++
      at = found + needle.length
    }
  }

  function kv(key, value) { console.log("##KV## " + key + "=" + String(value)) }

  // --- the cycle row derivation (BAR-1) -----------------------------------

  readonly property var rows: [
    { key: "dev-a", percentage: 30 },
    { key: "dev-b", percentage: 55 },
    { key: "dev-c", percentage: 80 }
  ]

  // displayRow is the one source (the Settings write updates it at the land).
  property var displayRow: rows[0]
  property var cycleFromRow: rows[0]
  property real cycleK: 1
  readonly property var paintRow: root.cycleK < 0.5 ? root.cycleFromRow : root.displayRow
  readonly property var shownRow: root.paintRow !== null ? root.paintRow : root.displayRow
  property string _cycleKey: ""

  function cycle(step) {
    root.cycleFromRow = root.shownRow
    const key = Model.cycleKey(root.rows, root.cycleFromRow ? root.cycleFromRow.key : "", step)
    if (key === "") return false
    root._cycleKey = key
    root.cycleK = 0
    return true
  }

  // The land writes the pick; in the module this is the edge where
  // Settings.setRawSection publishes the new key and displayRow follows.
  function land() {
    const key = root._cycleKey
    root._cycleKey = ""
    if (key === "") return
    const row = Model.rowForKey(root.rows, key)
    if (row !== null) root.displayRow = row
  }

  property string midBefore: ""
  property string midAt: ""
  property string midAfter: ""

  // --- the single-clock width (BAR-2 / BAR-3) -----------------------------

  property real textSlide: 0
  Behavior on textSlide { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
  property real nameWidth: 40
  Behavior on nameWidth { NumberAnimation { duration: 80; easing.type: Easing.OutCubic } }

  Item {
    id: pill
    width: Math.round(20 + root.textSlide * (root.nameWidth + 8))
  }

  function target() { return Math.round(20 + root.textSlide * (root.nameWidth + 8)) }
  property int lagFrames: 0
  property int nonMonotone: 0
  property int lastWidth: -1

  Timer {
    interval: 25
    repeat: true
    running: !root.done
    onTriggered: {
      root.turn++
      const t = root.turn

      // Row derivation at the three edges of the 0.5 cycle breaker.
      if (t === 2) {
        root.cycle(1)                         // dev-a -> dev-b
        root.land()
        root.cycleK = 0.49
        root.midBefore = root.shownRow.key
      } else if (t === 3) {
        root.cycleK = 0.5
        root.midAt = root.shownRow.key
      } else if (t === 4) {
        root.cycleK = 0.51
        root.midAfter = root.shownRow.key
        // A fast second wheel mid-cycle lands dev-c; the outgoing row is
        // dev-b until the midpoint, then dev-c.
        root.cycle(1)
        root.land()
        root.cycleK = 0.49
        root.kv("cycle.secondFrom", root.shownRow.key)
        root.cycleK = 0.5
        root.kv("cycle.secondAtMid", root.shownRow.key)
        root.cycleK = 1
      }

      // Width: start the reveal, then swap the name while it is settled
      // open (the spammed next/prev case). One binding, no width Behavior.
      if (t === 6) {
        root.textSlide = 1
        root.nameWidth = 120
      }
      if (t > 6 && t < 20) {
        const w = pill.width
        if (w !== root.target()) root.lagFrames++
        if (root.lastWidth >= 0 && w < root.lastWidth) root.nonMonotone++
        root.lastWidth = w
      }

      if (t === 20) {
        root.kv("cycle.beforeMid", root.midBefore)
        root.kv("cycle.atMid", root.midAt)
        root.kv("cycle.afterMid", root.midAfter)
        root.kv("width.lagFrames", root.lagFrames)
        root.kv("width.nonMonotone", root.nonMonotone)

        // Structural checks, against the real files.
        const b = root.batterySrc
        const n = root.nowPlayingSrc
        root.kv("src.batteryPresent", b.length > 0)
        root.kv("src.batteryNoWidthBehavior", b.indexOf("Behavior on width") < 0)
        root.kv("src.batteryCycleKDriven", b.indexOf("property real cycleK") >= 0
          && b.indexOf('property: "cycleK"') >= 0)
        root.kv("src.batteryCycleFromOnce", root.countOf(b, "root.cycleFromRow =") === 1)
        root.kv("src.batteryNoPaintWrites", root.countOf(b, "root.paintRow =") === 0)
        root.kv("src.batteryMidDerivation", b.indexOf("cycleK < 0.5 ?") >= 0)
        root.kv("src.batteryBreakerKept", b.indexOf("ScriptAction") >= 0)
        root.kv("src.batteryLandWriteKept",
          b.indexOf('Settings.setRawSection("battery", "device", key)') >= 0)
        root.kv("src.batteryFlashGateKept", b.indexOf("root._flashPending") >= 0
          && b.indexOf("root.fullscreenActive") >= 0)

        root.kv("src.npPresent", n.length > 0)
        root.kv("src.npNoWidthBehavior", n.indexOf("Behavior on width") < 0)
        root.kv("src.npNameScalar", n.indexOf("root.nameWidth") >= 0
          && n.indexOf("root.titleSlide * (root.nameWidth") >= 0)
        root.kv("src.npLiveTitle", n.indexOf("text: root.title") >= 0)
        const kickAt = n.indexOf("function kickName()")
        const kick = kickAt >= 0 ? n.slice(kickAt, kickAt + 600) : ""
        root.kv("src.npKickLiveTitle", kick.indexOf("root.title") >= 0)

        console.log("##DONE##")
        root.done = true
      }
    }
  }
}
