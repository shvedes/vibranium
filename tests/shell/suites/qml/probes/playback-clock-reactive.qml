// Probe: playback-clock-reactive - live ticks and derived position, sampled.
//
// The surfaces cannot be constructed offscreen (windows, pointer handlers and
// MultiEffect), so the probe lifts the real shownPosition binding out of the
// player view's source and evaluates it in a headless QtObject with a stub
// player. The clock under test is the REAL PlaybackClock singleton: its ticks
// are counted, its idle gate is exercised, and every tick's displayed position
// is compared against the source position it just read. A copied or lagging
// snapshot fails the per-tick comparison; a clock that never advances fails
// the idle or tick-count checks.

import QtQuick
import qs.common

Item {
  id: root

  width: 1
  height: 1

  property string error: ""
  property string expr: ""
  property int heldTicks: 0
  property int idleTicks: 0
  property int idleAtRelease: 0
  property int samples: 0
  property real maxError: 0
  property bool released: true
  property QtObject machine: null

  // The lifted binding names `root`; the created machine takes that id so it
  // reads its own state rather than this probe's. The probe keeps no stub
  // position of its own that could answer in its place.

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function read(path) {
    const xhr = new XMLHttpRequest()
    xhr.open("GET", path, false)
    xhr.send()
    return xhr.status === 200 ? (xhr.responseText || "") : ""
  }

  // One whole `readonly property real shownPosition: ...` line, without the
  // property keyword, so the exact source expression can be evaluated.
  function extractShown(src) {
    const m = /(?:^|\n)[ \t]*readonly property real shownPosition:[ \t]*([^\n]+)/.exec(src)
    return m ? m[1].trim() : ""
  }

  function build(src) {
    const expr = extractShown(src).replace(/\bNP\.reanchorPosition\(/g, "reanchorPosition(")
    root.expr = expr
    if (expr === "") return null
    const lines = [
      'import QtQml',
      'QtObject {',
      '  id: root',
      '  property QtObject player: QtObject { property real position: 0 }',
      '  property bool _seeking: false',
      '  property real previewPosition: 0',
      '  property real lengthSec: 100',
      '  function reanchorPosition(p, len) {',
      '    const n = Number(p && p.position != null ? p.position : 0)',
      '    return isFinite(n) ? (len > 0 ? Math.min(n, len) : n) : 0',
      '  }',
      '  readonly property real shownPosition: ' + expr,
      '}'
    ]
    return Qt.createQmlObject(lines.join("\n"), root, "derived_slice.qml")
  }

  Connections {
    target: PlaybackClock
    function onTick() {
      if (root.released || root.machine === null) {
        root.idleTicks++
        return
      }
      root.heldTicks++
      // Advance the source, then sample the displayed value in the same tick.
      const next = Math.min(100, root.machine.player.position + 0.25)
      root.machine.player.position = next
      const err = Math.abs(root.machine.shownPosition - next)
      if (err > root.maxError) root.maxError = err
      root.samples++
    }
  }

  Timer {
    interval: 250
    repeat: false
    running: true
    onTriggered: {
      kv("clock.idleBefore", root.idleTicks)
      root.released = false
      PlaybackClock.acquire()
    }
  }

  Timer {
    interval: 900
    repeat: false
    running: true
    onTriggered: {
      root.released = true
      root.idleAtRelease = root.idleTicks
      PlaybackClock.release()
      kv("clock.held", root.heldTicks)
      kv("clock.held.gt5", root.heldTicks > 5)
      kv("clock.samples", root.samples)
      kv("clock.samples.gt5", root.samples > 5)
      kv("clock.maxError", Math.round(root.maxError * 1000000) / 1000000)
      kv("clock.maxError.zero", root.maxError < 0.000001)

      if (root.machine !== null) {
        root.machine.player.position = 41.2
        kv("derived.idle", Math.round(root.machine.shownPosition * 100) / 100)
        root.machine._seeking = true
        root.machine.previewPosition = 12.5
        root.machine.player.position = 90
        kv("derived.preview", Math.round(root.machine.shownPosition * 100) / 100)
        root.machine._seeking = false
        kv("derived.release", Math.round(root.machine.shownPosition * 100) / 100)
      }
    }
  }

  Timer {
    interval: 1200
    repeat: false
    running: true
    onTriggered: {
      kv("clock.idleAfter", root.idleTicks - root.idleAtRelease)
      kv("probe.error", root.error)
      console.log("##DONE##")
    }
  }

  function drive() {
    root.error = ""
    try {
      const src = read("features/bar/modules/NowPlaying/LyricsFullscreenOverlay.qml")
      kv("slice.source", src.length > 0)
      root.machine = build(src)
      kv("slice.built", root.machine !== null)
      kv("slice.live", root.expr.indexOf("reanchorPosition(") >= 0
        && root.expr.indexOf("_seeking") >= 0
        && root.expr.indexOf("shownPosition") < 0)
    } catch (e) {
      root.error = "" + (e && e.message ? e.message : e)
    }
  }

  Component.onCompleted: drive()
}
