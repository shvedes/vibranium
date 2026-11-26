// Probe: fullscreen deferral of the Now Playing track flash.
//
//   1. Model check. A burst of next/prev events while fullscreen must leave
//      ONE held event - the last one - with no flash until exit. Replay drops
//      a held key that no longer names the active track, an in-flight flash
//      is parked as an event, and a disabled flash parks nothing.
//   2. Source check. The suite passes the two real files in through the
//      environment, so the structural half of the contract is checked against
//      the files under test rather than a copy of their shape.

import QtQuick
import Quickshell

Item {
  id: root
  width: 400
  height: 240

  readonly property string npSrc: Quickshell.env("BAR_NOWPLAYING_SRC") || ""
  readonly property string barSrc: Quickshell.env("BAR_BAR_SRC") || ""

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

  function block(s, from, to) {
    const a = s.indexOf(from)
    if (a < 0) return ""
    const b = to ? s.indexOf(to, a + from.length) : -1
    return b < 0 ? s.slice(a) : s.slice(a, b)
  }

  function kv(key, value) { console.log("##KV## " + key + "=" + String(value)) }

  // --- defer gate model ----------------------------------------------------

  function newGate() {
    return {
      fullscreen: false,
      active: false,
      held: null,
      starts: 0,
      title: "",
      key: "",
      hasTrack: true,
      flashEnabled: true
    }
  }

  function start(g) {
    if (!g.flashEnabled || !g.hasTrack) return
    g.active = true
    g.starts++
  }

  function park(g, key) {
    g.held = key === null ? null : { key: key }
  }

  function fire(g, key) {
    if (g.fullscreen) {
      root.park(g, key)
      return
    }
    root.start(g)
  }

  function observe(g, title) {
    g.title = title
    g.key = title
    if (g.flashEnabled) root.fire(g, g.key)
  }

  function setFullscreen(g, value) {
    if (g.fullscreen === value) return
    g.fullscreen = value
    if (value) {
      if (g.active) {
        root.park(g, g.key)
        g.active = false
      }
      return
    }
    if (g.held !== null) {
      const key = g.held.key
      root.park(g, null)
      if (key === g.key) root.start(g)
    }
  }

  Component.onCompleted: {
    const plain = root.newGate()
    root.observe(plain, "H")
    root.kv("model.plainFlash", plain.active
      && plain.starts === 1 && plain.held === null)

    const burst = root.newGate()
    root.setFullscreen(burst, true)
    root.observe(burst, "A")
    root.observe(burst, "B")
    root.observe(burst, "C")
    root.kv("model.activeInFullscreen", burst.active)
    root.kv("model.startsInFullscreen", burst.starts)
    root.kv("model.heldInFullscreen", burst.held !== null)
    root.kv("model.heldKey", burst.held !== null ? burst.held.key : "")
    root.setFullscreen(burst, false)
    root.kv("model.activeAfterExit", burst.active)
    root.kv("model.startsAfterExit", burst.starts)
    root.kv("model.heldAfterExit", burst.held === null)
    root.kv("model.titleAfterExit", burst.title)

    const flight = root.newGate()
    root.observe(flight, "D")
    root.setFullscreen(flight, true)
    root.kv("model.parkedInFlight", flight.held !== null
      && flight.held.key === "D" && !flight.active && flight.starts === 1)
    root.setFullscreen(flight, false)
    root.kv("model.startsAfterParkReplay", flight.starts)

    const off = root.newGate()
    off.flashEnabled = false
    root.setFullscreen(off, true)
    root.observe(off, "E")
    root.kv("model.disabledDoesNotPark", off.held === null && off.starts === 0)

    const stale = root.newGate()
    root.setFullscreen(stale, true)
    root.observe(stale, "F")
    stale.key = "G"
    root.setFullscreen(stale, false)
    root.kv("model.staleTokenDropped", stale.held === null && stale.starts === 0)

    // --- source checks ----------------------------------------------------
    const n = root.npSrc
    const b = root.barSrc
    root.kv("src.npPresent", n.length > 0)
    root.kv("src.npHeldEvent", n.indexOf("property var _flashPendingEvent") >= 0
      && n.indexOf("readonly property bool _flashPending: root._flashPendingEvent !== null") >= 0
      && root.countOf(n, "root._flashPendingEvent =") === 1)
    const fireSrc = root.block(n, "function _fireFlash(", "// IPC's explicit")
    root.kv("src.npFireGate", fireSrc.indexOf("root.fullscreenActive") >= 0
      && fireSrc.indexOf("root._parkFlash(key)") >= 0
      && fireSrc.indexOf("root._startFlash()") >= 0)
    const obsSrc = root.block(n, "function _observeTrack()", "// Track-name flash")
    const ipcSrc = root.block(n, "function ipcTrigger(name)", "function _stopFlash()")
    root.kv("src.npBothRoutesDefer", obsSrc.indexOf("root._fireFlash(key)") >= 0
      && ipcSrc.indexOf("root._fireFlash(root.trackKey)") >= 0)
    const fsSrc = root.block(n, "onFullscreenActiveChanged:", "// Opening an island")
    root.kv("src.npReplayToken", fsSrc.indexOf("root._flashPendingEvent.key") >= 0
      && fsSrc.indexOf("root._parkFlash(null)") >= 0
      && fsSrc.indexOf("key === root.trackKey") >= 0
      && fsSrc.indexOf("root._startFlash()") >= 0)
    const invalids = root.block(n, "onHasTrackChanged:", "onFullscreenActiveChanged:")
    root.kv("src.npInvalidations", root.countOf(invalids, "root._parkFlash(null)") === 2)
    root.kv("src.npLiveTitle", n.indexOf("text: root.title") >= 0
      && root.countOf(n, "title: root.title") === 0)
    root.kv("src.npSharedReveal", n.indexOf("FlashReveal {") >= 0
      && n.indexOf("readonly property bool flashActive: nameFlash.active") >= 0
      && root.countOf(n, "root.flashActive =") === 0
      && n.indexOf("interval: 3000") < 0)
    root.kv("src.npOneTransportWriter", root.countOf(n, "root.transportIcon =") === 1
      && root.countOf(n, "transportTimer.stop()") === 1
      && root.countOf(n, "transportTimer.restart()") === 1)

    const trackSrc = root.block(b, 'case "flashTrack"', 'case "flashTemperature"')
    root.kv("src.barDefer", trackSrc.indexOf('state: "deferred", reason: "fullscreen"') >= 0
      && trackSrc.indexOf("item._flashPending") >= 0)

    console.log("##DONE##")
  }
}
