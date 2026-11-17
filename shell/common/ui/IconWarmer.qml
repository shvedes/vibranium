pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Decodes themed icon rasters ahead of first paint, using MediaArt's warmer
// idiom: hidden `cache: true` Images push each (source, sourceSize) pair into
// Qt's shared decoded-image cache, so a consumer Icon asking for the same pair
// is Image.Ready in the frame it is created instead of showing an empty slot
// for the duration of the async SVG decode.
//
// Qt's decoded-image cache is keyed on both the source string and sourceSize
// (measured on this build). Icons.url() fixes the source; Icon.qml sets its
// sourceSize to the logical canvas times the containing window's DPR. So
// `side` must match the consumer's Icon size token (menu rows use
// Ui.rowIconW) and the DPR below is read from this item's own window, which
// for the menu warmer is the persistent panel window. A mismatch in either
// field decodes a second raster and the new delegate still blanks for a frame.
//
// Requests are deduplicated by (name, colorKey, accentKey) and capped. Theme
// changes need no handler: Icons.url() reads Theme.color, so every warmer's
// source binding re-evaluates onto the new palette's URLs on its own.
Item {
  id: root

  // Triple list: [{ name, colorKey, accentKey }, ...]. A bare string is the
  // ordinary foreground row glyph.
  property var requests: []
  // Logical side of the consuming Icon. Menu rows render at Ui.rowIconW.
  property real side: Ui.rowIconW
  // Bound on live warmers, independent of Icons' recolor-string cache.
  readonly property int capacity: 256
  readonly property int size: root.requests.length
  readonly property int refused: root._refused

  // Exact sourceSize an Icon of `side` builds in this window (Icon.qml:188).
  readonly property real _dpr: {
    const w = Window.window
    const d = w ? w.devicePixelRatio : 0
    return typeof d === "number" && isFinite(d) && d > 0 ? d : 1
  }
  readonly property size rasterSize: Qt.size(root.side * root._dpr, root.side * root._dpr)

  property var _entries: ({})
  property int _refused: 0

  function _key(req) {
    return String(req.name) + "\u0000" + String(req.colorKey) + "\u0000" + String(req.accentKey)
  }

  function _url(req) {
    return Icons.url(String(req.name), String(req.colorKey), String(req.accentKey), "", 0)
  }

  // Add requests to the warm set without dropping earlier ones: Menu warms
  // more than one bundle, and each call must leave the previous glyphs alone.
  function warm(list) {
    const src = Array.isArray(list) ? list : []
    const next = Object.assign({}, root._entries)
    for (let i = 0; i < src.length; i++) {
      const raw = src[i]
      const name = typeof raw === "string"
        ? raw : String(raw && raw.name ? raw.name : "")
      if (name === "") continue
      const req = typeof raw === "string"
        ? { name: name, colorKey: "foreground_0", accentKey: "" }
        : {
          name: name,
          colorKey: String(raw.colorKey ?? "foreground_0"),
          accentKey: String(raw.accentKey ?? "")
        }
      const key = root._key(req)
      if (next[key] === undefined) next[key] = req
    }
    const keys = Object.keys(next)
    const kept = keys.slice(0, root.capacity)
    const out = []
    for (let i = 0; i < kept.length; i++) out.push(next[kept[i]])
    root._refused = Math.max(0, keys.length - kept.length)
    root._entries = next
    root.requests = out
  }

  // Warmers are observable for the probe and for diagnostics: one live Image
  // per admitted request, in the same order as `requests`.
  function warmerAt(index) { return rep.itemAt(index) }
  function urlAt(index) {
    return index >= 0 && index < root.requests.length ? root._url(root.requests[index]) : ""
  }

  Repeater {
    id: rep

    // An URL cannot be produced before the boot scan publishes _raw; an empty
    // source would only make an Image idle until the scan lands.
    model: Icons.ready ? root.requests : []

    Image {
      required property var modelData

      visible: false
      asynchronous: true
      cache: true
      sourceSize: root.rasterSize
      source: root._url(modelData)
    }
  }
}
