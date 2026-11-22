// Probe: a settings toggle observed on consecutive frames (SET-1, SET-2).
//
// The real Settings singleton is driven directly. In ONE synchronous turn the
// probe captures the baseline, toggles shell.statusbar.position, and samples
// the store again before the deferred rev bump and the flush run. A commit
// replaces one shard synchronously, so `values` and `value()` are already new;
// a cache signed on the deferred `rev`, or a statusbarPosition that reads the
// flush-owned raw map, still shows the OLD value in that turn.
//
// Baseline and write share a turn on purpose: MiscSettings' rev moves on its
// own async cursor scans, so a turn gap between the two reads can hide the
// stale cache by invalidating it for an unrelated reason.
//
// Structural checks (against the real file handed in by the suite) pin the
// mechanism, so a different fix - making rev synchronous, or writing _lastRaw
// inline - cannot make the frame assertions green by accident.

import QtQuick
import Quickshell
import qs.common

Item {
  id: root
  width: 1
  height: 1

  property int turn: 0
  property bool done: false

  readonly property string settingsSrc: Quickshell.env("SETTINGS_SRC") || ""

  function kv(key, value) { console.log("##KV## " + key + "=" + String(value)) }

  // Captured inside the toggle turn; rev2 is read one turn later.
  property int rev0: -1
  property int rev2: -1

  function slice(s, from, to) {
    const a = s.indexOf(from)
    if (a < 0) return ""
    const b = to ? s.indexOf(to, a + from.length) : -1
    return b < 0 ? s.slice(a) : s.slice(a, b)
  }

  Timer {
    interval: 40
    repeat: true
    running: !root.done
    onTriggered: {
      root.turn++
      const t = root.turn

      // Turn 1..2: let boot (catalog parse, user load, misc scans) settle.
      if (t === 3) {
        // Every read and the write below are in ONE synchronous turn.
        const v0 = Settings.values
        const p0 = Settings.menuPages()
        const rev0 = Settings.rev
        const sb0 = Settings.statusbarPosition
        root.rev0 = rev0

        const ok = Settings.setOption("shell.statusbar.position", "bottom")
        const v1 = Settings.values
        const p1 = Settings.menuPages()
        const rev1 = Settings.rev
        const val1 = Settings.value("shell.statusbar.position")
        const sb1 = Settings.statusbarPosition

        root.kv("toggle.accepted", ok)
        root.kv("same.valueIsNew", val1 === "bottom")
        root.kv("same.valuesIdentityChanged", v1 !== v0)
        root.kv("same.menuPagesRebuilt", p1 !== p0)
        root.kv("same.statusAgreesWithValue", sb1 === val1)
        root.kv("same.statusbarPosition", sb1)
        root.kv("same.revStillDeferred", rev1 === rev0)
        // sb0 is captured so the baseline is observably the old value.
        root.kv("same.baselineStatus", sb0)
      } else if (t === 4) {
        // One event-loop turn later the coalesced bump and the flush ran.
        root.rev2 = Settings.rev
        root.kv("post.revBumped", root.rev2 > root.rev0)
        root.kv("post.statusSettled",
          Settings.statusbarPosition === Settings.value("shell.statusbar.position"))

        const s = root.settingsSrc
        const menuFn = root.slice(s, "function menuPages()", "function menuHasPage")
        const sbFn = root.slice(s, "readonly property string statusbarPosition", "// Zone layout")
        root.kv("src.settled", s.length > 0)
        root.kv("src.menuSignsOnValues",
          menuFn.indexOf("root.values") >= 0 && menuFn.indexOf("root.rev") < 0)
        root.kv("src.menuSignsOnMiscMap", menuFn.indexOf("_miscValues()") >= 0)
        root.kv("src.statusReadsValue", sbFn.indexOf('value("shell.statusbar.position")') >= 0)
        root.kv("src.statusNoRawRead", sbFn.indexOf("_lastRaw") < 0)

        console.log("##DONE##")
        root.done = true
      }
    }
  }
}
