import QtQuick
import qs.common

// Dropdown close that shrinks the card. MenuPanel cannot be constructed
// offscreen (it needs a LayerSurface), so this evaluates the REAL
// _followSlotRow bytes out of MenuPanel.qml in a headless QtObject. Only the
// component boundaries are stubbed (panel, list, Menu, the height tween); the
// release branch under test is the file's own text. The card height is
// sampled per turn: a close that lands in one frame is the bug, whatever the
// end state says.

Item {
  id: root
  width: 1
  height: 1

  property string source: ""
  property string error: ""
  property bool completed: false
  property var heights: []
  property int releaseCalls: 0

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function read(path) {
    const xhr = new XMLHttpRequest()
    xhr.open("GET", path, false)
    xhr.send()
    return xhr.status === 200 ? (xhr.responseText || "") : ""
  }

  // One whole function, with braces in strings and // comments skipped.
  function extract(src, name) {
    const re = new RegExp("^[ \\t]*function " + name + "\\s*\\(", "m")
    const m = re.exec(src)
    if (!m) return ""
    const open = src.indexOf("{", m.index + m[0].length - 1)
    if (open < 0) return ""
    let depth = 0
    let quote = ""
    let comment = false
    for (let j = open; j < src.length; j++) {
      const ch = src[j]
      if (comment) { if (ch === "\n") comment = false; continue }
      if (quote) {
        if (ch === "\\") { j++; continue }
        if (ch === quote) quote = ""
        continue
      }
      if (ch === "/" && src[j + 1] === "/") { comment = true; j++; continue }
      if (ch === "'" || ch === '"' || ch === "`") { quote = ch; continue }
      if (ch === "{") depth++
      else if (ch === "}") {
        depth--
        if (depth === 0) return src.slice(open, j + 1)
      }
    }
    return ""
  }

  readonly property string cfgDir: {
    const base = Qt.resolvedUrl(".").toString().replace("file://", "")
    return base.charAt(base.length - 1) === "/" ? base : base + "/"
  }

  property QtObject model: null
  property QtObject releaseAnim: null

  function build() {
    const src = root.source
    const follow = extract(src, "_followSlotRow")
    if (follow === "") {
      root.error = "missing _followSlotRow in MenuPanel.qml"
      return
    }

    // The one height tween, mirroring MenuPanel.heightAnim: one clock, one
    // writer (_animatedListH). No second tween, no retry timer.
    const anim = Qt.createQmlObject([
      'import QtQuick',
      'import qs.common',
      'NumberAnimation {',
      '  property real fromH: 0',
      '  property real toH: 0',
      '  property int starts: 0',
      '  from: fromH; to: toH',
      '  duration: Ui.resizeMs',
      '  easing.type: Easing.OutCubic',
      '}'
    ].join("\n"), root, "menu_release_anim.qml")

    let body = follow
      .replace(/\bpanel\./g, "m.")
      .replace(/\bMenu\.slotClosing\b/g, "m.menu.slotClosing")
      .replace(/\blist\.currentItem\b/g, "m.list.currentItem")

    const lines = [
      'import QtQml',
      'import qs.common',
      'QtObject {',
      '  id: m',
      '  property real _slotRegionH: -1',
      '  property real _claimListH: -1',
      '  property bool _handoffReveal: false',
      '  property real _animatedListH: -1',
      '  property bool _heightAnimating: false',
      '  property bool _transitionActive: false',
      '  property bool shown: true',
      '  property real _restingBase: 200',
      '  property real screenMaxListH: 900',
      '  property bool _closePageMode: false',
      '  property var _closeRow: null',
      '  property bool _nestedSeatPending: false',
      '  property bool _trackingCloseSeat: false',
      '  property QtObject menu: QtObject { property bool slotClosing: false }',
      '  property QtObject list: QtObject { property var currentItem: null }',
      '  property QtObject anim: null',
      '  function _restingFallbackH() { return m._restingBase }',
      '  function _startHeightTransition(target, gen, fromH) {',
      '    if (!(target > 0)) return',
      '    const from = fromH !== undefined ? fromH : m._slotRegionH',
      '    if (!(from > m._restingBase + 0.5)) return',
      '    m.anim.starts++',
      '    m._heightAnimating = true',
      '    m._animatedListH = from',
      '    m.anim.fromH = from',
      '    m.anim.toH = target',
      '    m.anim.restart()',
      '  }',
      '  function panelHeight() {',
      '    if (m._heightAnimating && m._animatedListH > 0) return m._animatedListH',
      '    if (m._slotRegionH > 0) return m._slotRegionH',
      '    return m._restingBase',
      '  }',
      '  function _followSlotRow()' + body,
      '}'
    ].join("\n")
    const obj = Qt.createQmlObject(lines, root, "menu_follow_slice.qml")
    root.model = obj
    root.releaseAnim = anim
    obj.anim = anim
    anim.target = obj
    anim.property = "_animatedListH"
    kv("source.followFound", "true")
  }

  Connections {
    target: root.releaseAnim
    function onFinished() {
      if (root.model) root.model._heightAnimating = false
      root.releaseCalls++
    }
  }

  function sample() {
    root.heights.push(Math.round(root.model.panelHeight() * 10) / 10)
  }

  Component.onCompleted: {
    root.source = read(cfgDir + "features/menu/MenuPanel.qml")
    kv("probe.error", root.source === "" ? "source not read" : "none")
    build()
  }

  Timer {
    interval: 16
    repeat: true
    running: !root.completed && root.model !== null
    property int turn: 0
    onTriggered: {
      turn++
      if (turn === 1) {
        root.model.list.currentItem = { height: 600, restHeight: 100 }
        root.model._claimListH = 600
        root.model._followSlotRow()
        kv("open.region", Math.round(root.model._slotRegionH * 10) / 10)
      } else if (turn === 2) {
        // The close edge: Entry clears autoRevealIndex, _latchClaim clears the
        // claim, and the row is still at full height. This is the turn whose
        // frames decide whether the card glides or snaps.
        root.model._claimListH = -1
        root.model.menu.slotClosing = true
        root.model._followSlotRow()
        sample()
      } else if (turn <= 16) {
        sample()
      } else {
        sample()
        kv("trace.h", root.heights.join(","))
        kv("trace.animStarts", root.releaseAnim.starts)
        const mids = root.heights.filter(function(h) {
          return h > 205 && h < 595
        })
        kv("frame.intermediate", mids.length >= 2 ? "true" : "false")
        kv("frame.landed", root.heights[root.heights.length - 1] === 200
          ? "true" : "false")
        kv("completed", "true")
        console.log("##DONE##")
        root.completed = true
      }
    }
  }
}
