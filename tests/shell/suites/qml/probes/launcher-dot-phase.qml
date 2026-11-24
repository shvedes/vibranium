// Probe: LauncherEntry loading dots - one clock, one derived stage.
//
// LauncherEntry imports the menu family, which reaches a PanelWindow and
// cannot be constructed offscreen. This probe reads the real file and builds a
// headless QtObject slice from its dot bindings and Timer block. Only the
// boundary names are rewritten (row. -> m., modelData -> m.modelData); every
// expression and the timer body are the file's own bytes. A rename of any
// anchor is reported as missing rather than passing against a stale copy.
//
// The contract pinned here is the reactive one: the timer is the sole writer
// of the tick, the visible stage is a pure function of that tick, and the
// consecutive frames read ".", "..", "...", "." at the timer's own cadence.

import QtQuick

Item {
  id: root
  width: 1
  height: 1

  property string error: ""
  property string src: ""
  property var slice: null
  property var samples: []
  property int ticks: 0
  property string initial: ""
  property string offlineText: ""

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function read(path) {
    const xhr = new XMLHttpRequest()
    xhr.open("GET", path, false)
    xhr.send()
    return xhr.status === 200 ? (xhr.responseText || "") : ""
  }

  // The brace-balanced block that starts at `anchor`, searched from `from`.
  function blockAfter(src, from, anchor) {
    const at = src.indexOf(anchor, from)
    if (at < 0) return ""
    const open = src.indexOf("{", at)
    if (open < 0) return ""
    let depth = 0
    for (let i = open; i < src.length; i++) {
      if (src[i] === "{") depth++
      else if (src[i] === "}") {
        depth--
        if (depth === 0) return src.slice(at, i + 1)
      }
    }
    return ""
  }

  function finish() {
    kv("probe.error", root.error)
    if (root.slice !== null) {
      // A settled row has no flag, so the same binding must drop the dots
      // without anyone writing the tick.
      root.slice.modelData = { sub: "Fetching inflation data", loadingDots: false }
      root.offlineText = root.slice.subText
    }
    kv("runtime.initial", root.initial)
    kv("runtime.samples", root.samples.join("|"))
    kv("runtime.offline", root.offlineText)
    console.log("##DONE##")
  }

  function note() {
    // The change signal fires before the derived binding re-evaluates, so
    // the frame is sampled on the next turn, not from the signal argument.
    Qt.callLater(function () {
      const text = root.slice.subText
      root.samples.push(text)
      root.ticks++
      kv("runtime.tick" + root.ticks, text)
      if (root.ticks === 4) finish()
    })
  }

  Component.onCompleted: {
    root.src = read("features/launcher/LauncherEntry.qml")
    if (root.src === "") {
      root.error = "source missing"
      finish()
      return
    }

    const a = root.src.indexOf("  readonly property bool loadingDots:")
    const sub = root.src.indexOf("  readonly property string subText:", a)
    const tail = '    : ""'
    const b = root.src.indexOf(tail, sub)
    const runAt = root.src.indexOf("running: row.loadingDots")
    const timerAt = root.src.lastIndexOf("  Timer {", runAt)
    const timer = blockAfter(root.src, timerAt, "  Timer {")
    if (a < 0 || sub < 0 || b < 0 || runAt < 0 || timerAt < 0 || timer === "") {
      root.error = "anchors missing"
      finish()
      return
    }
    const bindings = root.src.slice(a, b + tail.length)

    kv("source.read", "true")
    kv("source.bindingsFound", "true")
    kv("source.oneWriter", (root.src.match(/\bdotTick\s*\+?=/g) || []).length === 1)
    kv("source.noStopReset", timer.indexOf("onRunningChanged") < 0)
    kv("source.derived", /dotStages\[row\.dotTick\s*%/.test(root.src)
      && root.src.indexOf("row.dotText") >= 0)
    kv("source.noCopiedStage", root.src.slice(sub, b).indexOf('"."') < 0)
    kv("source.interval250", timer.indexOf("interval: 250") >= 0)
    kv("source.runningEdge", timer.indexOf("running: row.loadingDots") >= 0)

    const rewrite = s => s.replace(/\brow\./g, "m.").replace(/\bmodelData\b/g, "m.modelData")
    const obj = Qt.createQmlObject([
      "import QtQuick",
      "QtObject {",
      "  id: m",
      "  property var modelData: ({})",
      "  property var sink: null",
      "  " + rewrite(bindings),
      // QtObject has no default child property, so the timer is a typed
      // property here; its body is still the file's own bytes.
      "  property Timer dotClock: " + rewrite(timer).trim(),
      // probe hook: observe each tick without touching the real expressions
      "  onDotTickChanged: if (m.sink) m.sink()",
      "}"
    ].join("\n"), root, "launcher_dot_slice.qml")

    root.slice = obj
    obj.modelData = {
      kind: "fx", uid: "fx:infl", label: "100 USD in 2000",
      sub: "Fetching inflation data", loadingDots: true
    }
    root.initial = obj.subText
    obj.sink = note
  }
}
