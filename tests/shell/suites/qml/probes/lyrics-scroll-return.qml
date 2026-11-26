// Probe: lyrics flick return edge and gliding return (APP-4/APP-5 revision).
//
// LyricsPane is shared by the bar island (reader-driven) and the lock card
// (scrollable: false); the Player view now turns the gate off entirely. A
// ListView with real delegates cannot be flicked offscreen. So the probe reads
// the REAL LyricsPane.qml with XHR and
// evaluates its OWN _follow / _centre / settleGuard body plus the view's
// movement handlers in a headless QtObject with a stub view. The stub exposes
// live `moving`, `flicking`, `contentY`, `atYBeginning`/`atYEnd` and a
// `positionViewAtIndex` counter, and its scrollTo stub records whether the
// return used the NumberAnimation or an instant placement.
//
// Contract pinned here:
//   * no placement (instant OR animated) while the flick is still moving;
//   * the settle timer is gated on live moving/flicking and re-armed on the
//     real movement-end and bounds edges, never fired mid-scroll;
//   * the return is the scrollTo NumberAnimation on view.contentY, with a
//     target different from the current offset, not a one-frame
//     positionViewAtIndex teleport - including when the cue row is not yet
//     created.
//
// The QML namespace names are rewritten to lowercase local stubs where needed
// (QML identifiers cannot start upper case); every rewrite is named inline.

import QtQuick

Item {
  id: root

  width: 1
  height: 1

  property string error: ""
  property string source: ""
  property string missing: ""
  property bool machineBuilt: false

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function read(path) {
    const xhr = new XMLHttpRequest()
    xhr.open("GET", path, false)
    xhr.send()
    return xhr.status === 200 ? (xhr.responseText || "") : ""
  }

  function extract(src, name) {
    const re = new RegExp("^[ \\t]*function " + name + "\\s*\\(", "m")
    const m = re.exec(src)
    if (!m) return ""
    const open = src.indexOf("{", m.index + m[0].length - 1)
    if (open < 0) return ""
    let depth = 0
    let quote = ""
    let lineComment = false
    let blockComment = false
    for (let j = open; j < src.length; j++) {
      const ch = src[j]
      if (lineComment) { if (ch === "\n") lineComment = false; continue }
      if (blockComment) {
        if (ch === "*" && src[j + 1] === "/") { blockComment = false; j++ }
        continue
      }
      if (quote) { if (ch === "\\") { j++; continue } if (ch === quote) quote = ""; continue }
      if (ch === "/" && src[j + 1] === "/") { lineComment = true; j++; continue }
      if (ch === "/" && src[j + 1] === "*") { blockComment = true; j++; continue }
      if (ch === "'" || ch === '"' || ch === "`") { quote = ch; continue }
      if (ch === "{") depth++
      else if (ch === "}") {
        depth--
        if (depth === 0) return src.slice(m.index, j + 1)
      }
    }
    return ""
  }

  function handlerAfter(src, anchor, name) {
    const a = anchor === "" ? 0 : src.indexOf(anchor)
    if (a < 0) return ""
    const re = new RegExp("\\b" + name + "\\s*:", "g")
    re.lastIndex = a
    const m = re.exec(src)
    if (!m) return ""
    let i = m.index + m[0].length
    while (i < src.length && /\s/.test(src[i])) i++
    if (src[i] !== "{") {
      let j = i
      while (j < src.length && src[j] !== "\n" && src[j] !== "\r") {
        if (src[j] === "{") { i = j; break }
        j++
      }
    }
    if (src[i] === "{") {
      let depth = 0
      let quote = ""
      let lineComment = false
      let blockComment = false
      for (let j = i; j < src.length; j++) {
        const ch = src[j]
        if (lineComment) { if (ch === "\n") lineComment = false; continue }
        if (blockComment) {
          if (ch === "*" && src[j + 1] === "/") { blockComment = false; j++ }
          continue
        }
        if (quote) { if (ch === "\\") { j++; continue } if (ch === quote) quote = ""; continue }
        if (ch === "/" && src[j + 1] === "/") { lineComment = true; j++; continue }
        if (ch === "/" && src[j + 1] === "*") { blockComment = true; j++; continue }
        if (ch === "'" || ch === '"' || ch === "`") { quote = ch; continue }
        if (ch === "{") depth++
        else if (ch === "}") {
          depth--
          if (depth === 0) return src.slice(i, j + 1)
        }
      }
      return ""
    }
    let j = i
    while (j < src.length && src[j] !== "\n" && src[j] !== "\r") j++
    return src.slice(i, j).trim()
  }

  function buildMachine() {
    const src = root.source
    const follow = extract(src, "_follow")
    const centre = extract(src, "_centre")
    const estimated = extract(src, "_estimatedCueY")
    const settle = handlerAfter(src, "id: settleGuard", "onTriggered")
    const start = handlerAfter(src, "onMovementStarted:", "onMovementStarted")
    const ended = handlerAfter(src, "", "onMovementEnded")
    const boundsStart = handlerAfter(src, "", "onAtYBeginningChanged")
    const boundsEnd = handlerAfter(src, "", "onAtYEndChanged")
    const missing = []
    if (follow === "") missing.push("_follow")
    if (centre === "") missing.push("_centre")
    if (settle === "") missing.push("settleGuard.onTriggered")
    if (start === "") missing.push("onMovementStarted")
    root.missing = missing.join(",")
    if (missing.length > 0) return null

    // QML identifiers cannot start upper case: the two ListView placement
    // constants are rewritten to plain numbers in the lifted bytes.
    const centreJs = centre.replace(/ListView\.Center/g, "1")
      .replace(/ListView\.Beginning/g, "0")

    const lines = [
      'import QtQml',
      'QtObject {',
      '  id: root',
      '  property bool active: true',
      '  property bool synced: true',
      '  property int currentIndex: 8',
      '  property int activeIndex: 8',
      '  property bool _pinnedByUser: true',
      '  property bool _freshSheet: false',
      '  property bool _freshAnchor: false',
      '  property int _freshAnchorIndex: -1',
      '  property bool _placing: false',
      '  property bool _returnPending: false',
      '  property bool glide: true',
      '  property bool animOn: true',
      '  property bool rowExists: true',
      '  property int instantPlacements: 0',
      '  property int scrollStarts: 0',
      '  property int scrollStops: 0',
      '  property real scrollTarget: -1',
      '  property real fromContentY: 0',
      '  property var frames: []',
      '  readonly property bool _scrolling: view.moving || view.flicking',
      '  property QtObject view: QtObject {',
      '    property bool moving: false',
      '    property bool flicking: false',
      '    property bool atYBeginning: false',
      '    property bool atYEnd: false',
      '    property real contentY: 0',
      '    property real contentHeight: 1200',
      '    property real height: 400',
      '    property int count: 24',
      '    property real spacing: 6',
      '    property var headerItem: QtObject { property real y: -200; property real height: 200 }',
      '    property var footerItem: QtObject { property real height: 200 }',
      '    function itemAtIndex(i) {',
      '      if (!root.rowExists) return null',
      '      return { y: 200 + i * 40, height: 40 }',
      '    }',
      '    function forceLayout() {}',
      '    function positionViewAtIndex(i, mode) { root.instantPlacements++ }',
      '    function positionViewAtBeginning() { root.instantPlacements++ }',
      '  }',
      '  property QtObject scrollTo: QtObject {',
      '    property real to: 0',
      '    property bool running: false',
      '    function stop() { running = false; root.scrollStops++ }',
      '    function start() {',
      '      root.scrollStarts++',
      '      root.scrollTarget = to',
      '      root.fromContentY = view.contentY',
      '      root.frames = [ view.contentY ]',
      '      running = true',
      '      // Sample the NumberAnimation path at three points; a real',
      '      // number animation produces these intermediate contentY values.',
      '      root.frames.push(view.contentY + (to - view.contentY) * 0.5)',
      '      root.frames.push(to)',
      '    }',
      '  }',
      '  property QtObject settleGuard: QtObject {',
      '    property bool running: false',
      '    property int restarts: 0',
      '    function restart() { running = true; root.settleRestarts++ }',
      '    function fire() { running = false; ' + settle + ' }',
      '  }',
      '  property int settleRestarts: 0',
      '  function movementStarted() { ' + start + ' }',
      '  function movementEnded() { ' + (ended === "" ? "" : ended) + ' }',
      '  function boundsStart() { ' + (boundsStart === "" ? "" : boundsStart) + ' }',
      '  function boundsEnd() { ' + (boundsEnd === "" ? "" : boundsEnd) + ' }',
      estimated,
      follow,
      centreJs,
      '}'
    ]
    return Qt.createQmlObject(lines.join("\n"), root, "lyrics_scroll_slice.qml")
  }

  function drive() {
    root.error = ""
    try {
      root.source = read("common/LyricsPane.qml")
      kv("slice.source", root.source.length > 0)
      const src = root.source

      const follow = extract(src, "_follow")
      const centre = extract(src, "_centre")
      const settle = handlerAfter(src, "id: settleGuard", "onTriggered")
      const ended = handlerAfter(src, "", "onMovementEnded")
      const boundsStart = handlerAfter(src, "", "onAtYBeginningChanged")
      const boundsEnd = handlerAfter(src, "", "onAtYEndChanged")

      // Source shape: the live moving gate and the stop/bounds re-arms.
      kv("shape.followGatesMoving", follow.indexOf("_scrolling") >= 0
        || (follow.indexOf("moving") >= 0 && follow.indexOf("flicking") >= 0))
      kv("shape.settleGatesMoving", settle.indexOf("_scrolling") >= 0
        || (settle.indexOf("moving") >= 0 && settle.indexOf("flicking") >= 0))
      kv("shape.movementEndRearms", ended.indexOf("settleGuard.restart()") >= 0)
      kv("shape.boundsRearm", boundsStart.indexOf("settleGuard.restart()") >= 0
        || boundsEnd.indexOf("settleGuard.restart()") >= 0)
      kv("shape.centreGlides", centre.indexOf("scrollTo.to =") >= 0
        && centre.indexOf("scrollTo.start()") >= 0)
      // The old instant path listed `row === null` beside _freshSheet; that is
      // the one-frame teleport when a cue is off-screen mid-flick.
      kv("shape.noRowNullTeleport", centre.indexOf("row === null") < 0
        && centre.indexOf("|| row === null") < 0)
      kv("shape.scrollToIsContentYAnimation",
        /property:\s*"contentY"/.test(src) && /target:\s*view/.test(src)
        && /id:\s*scrollTo/.test(src))

      const m = buildMachine()
      root.machineBuilt = m !== null
      kv("slice.missing", root.missing)
      if (m !== null) {
        // --- mid-flick: neither timer nor cue edge may place the view ---
        m.view.moving = true
        m.view.flicking = true
        m._freshSheet = true
        m._pinnedByUser = false
        m.rowExists = false
        m.scrollStarts = 0; m.instantPlacements = 0
        m.settleGuard.fire()
        m._follow()
        kv("mid.noInstantWhileFlicking", m.instantPlacements === 0)
        kv("mid.noAnimatedWhileFlicking", m.scrollStarts === 0)
        kv("mid.freshSheetHeld", m._freshSheet)

        // --- the real stop edge re-arms the timer, and the return glides ---
        // Reset the counters and re-stage the cut so this phase measures only
        // the return, not the placements the unfixed tree made mid-flick.
        m.view.moving = false
        m.view.flicking = false
        m.rowExists = true
        m._freshSheet = true
        m._pinnedByUser = true
        m.instantPlacements = 0
        m.scrollStarts = 0
        m.movementEnded()
        kv("stop.timerRearmedOnMovementEnd", m.settleRestarts >= 1)
        m.settleGuard.fire()
        kv("stop.noTeleport", m.instantPlacements === 0)
        kv("stop.glideStarted", m.scrollStarts === 1)
        kv("stop.freshSheetCleared", m._freshSheet === false)
        kv("stop.pinReleased", m._pinnedByUser === false)
        kv("stop.targetIsAhead", m.scrollTarget > m.fromContentY)
        kv("stop.hasIntermediateFrame", m.frames.length >= 3
          && m.frames[1] !== m.frames[0] && m.frames[1] !== m.frames[2])

        // --- bounds edge is also a legitimate arm, not a wall-clock guess ---
        const b = buildMachine()
        b.view.moving = false
        b.view.flicking = false
        b.view.atYEnd = true
        b.boundsEnd()
        kv("bounds.timerRearmed", b.settleRestarts >= 1)
      }

      kv("probe.error", root.error)
    } catch (e) {
      root.error = "" + (e && e.message ? e.message : e)
      kv("probe.error", root.error)
    }
    console.log("##DONE##")
  }

  Component.onCompleted: drive()
}
