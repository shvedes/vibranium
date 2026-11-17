// Probe: common/ui/IconWarmer - the decoded-raster warmer that makes a menu
// delegate's first paint hit Qt's shared image cache instead of showing an
// empty slot for the async SVG decode. Plain Item so the offscreen harness can
// construct it (the real warmer lives in the persistent menu panel).

import QtQuick
import qs.common

Item {
  id: root

  property int step: 0
  property var warmer: null
  property bool warmed: false

  function kv(key, value) { console.log("##KV## " + key + "=" + String(value)) }

  Component.onCompleted: {
    root.warmer = Qt.createQmlObject(
      'import QtQuick; import qs.common; IconWarmer { side: 20 }', root)
  }

  Timer {
    interval: 50
    repeat: true
    running: true
    onTriggered: {
      root.step++
      if (root.step === 1) {
        // The scan must have published _raw before url() can serve anything.
        if (!Icons.ready) return
        root.warmer.warm([
          { name: "clock", colorKey: "foreground_0", accentKey: "" },
          { name: "clock", colorKey: "foreground_0", accentKey: "" },
          "bluetooth",
          "hyprland"
        ])
        root.kv("requests", root.warmer.size)
        root.kv("refused", root.warmer.refused)
        root.kv("raster.width", root.warmer.rasterSize.width)
        root.kv("raster.height", root.warmer.rasterSize.height)
        return
      }
      if (root.step >= 2 && !root.warmed) {
        let allReady = root.warmer.size > 0
        for (let i = 0; i < root.warmer.size; i++) {
          const w = root.warmer.warmerAt(i)
          if (!w || w.status !== Image.Ready) allReady = false
        }
        if (root.step > 40) {
          root.kv("warmers.ready", false)
          console.log("##DONE##")
          stop()
          return
        }
        if (!allReady) return
        root.warmed = true
        root.kv("warmers.ready", true)

        const url = root.warmer.urlAt(0)
        root.kv("url.len", url.length)
        root.kv("url.matchesIcons", url === Icons.url("clock", "foreground_0", "", "", 0))

        // The exact contract: a brand-new Image with the same source AND
        // sourceSize is Ready in the frame it is created, because the warmer
        // already decoded that pair into Qt's shared cache.
        const same = Qt.createQmlObject(
          'import QtQuick; Image { asynchronous: true; cache: true }', root)
        same.sourceSize = root.warmer.rasterSize
        same.source = url
        root.kv("consumer.same.initialReady", same.status === Image.Ready)

        // A different size is a different cache key and still decodes async:
        // this is what makes the size match load-bearing rather than cosmetic.
        const diff = Qt.createQmlObject(
          'import QtQuick; Image { asynchronous: true; cache: true }', root)
        diff.sourceSize = Qt.size(root.warmer.rasterSize.width + 20,
          root.warmer.rasterSize.height + 20)
        diff.source = url
        root.kv("consumer.diff.initialReady", diff.status === Image.Ready)

        console.log("##DONE##")
        stop()
      }
    }
  }
}
