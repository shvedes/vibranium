// Probe: modules/Downloader/IconSweep.qml - the top-to-bottom accent
// wave and its idle parking. The sweep is forced even when global motion is
// off, because it is the bar's only busy indicator. Plain Item, so the
// offscreen backend can construct it (unlike the bar module itself).

import QtQuick
import qs.features.bar.modules.Downloader

Item {
  id: root

  property int step: 0
  property real first: -99
  property real second: -99
  property real parked: -99

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value))
  }

  IconSweep {
    id: sweep
    canvas: 16
    active: true
  }

  Timer {
    interval: 250
    repeat: true
    running: true
    onTriggered: {
      root.step++
      if (root.step === 1) root.first = sweep.phase
      if (root.step === 7) root.second = sweep.phase
      if (root.step === 8) {
        sweep.active = false
        root.parked = sweep.phase
      }
      if (root.step === 10) {
        root.kv("sweep.canvas", sweep.canvas)
        root.kv("sweep.band", sweep.bandH)
        root.kv("sweep.frameMs", sweep.frameMs)
        root.kv("sweep.motion", sweep.animOn)
        root.kv("sweep.first", root.first)
        root.kv("sweep.second", root.second)
        root.kv("sweep.parkedDelta", root.parked + sweep.bandH)
        root.kv("sweep.visibleInactive", sweep.visible)
        console.log("##DONE##")
        stop()
      }
    }
  }
}
