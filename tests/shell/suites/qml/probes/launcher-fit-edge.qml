// Probe: LauncherPanel fit settled-edge waiter (LNC-1).
//
// LauncherPanel cannot be constructed offscreen: PanelCard needs a LayerSurface
// and a screen. This probe reads the real file and evaluates its OWN fit
// functions in a headless QtObject. Only the names that cross the component
// boundary are stubbed (panel -> m, list, Qt.callLater, fallback timer); the
// bodies themselves are the file's bytes, brace-balanced out of the source.
// A source change that moves or renames a function is reported as missing.
//
// The contract: a fit armed while geometry is in motion is released by the
// first live edge (swap close, slot motion finished, count, content polish),
// not by a retry budget. A settle wait can never spend a fit retry's turn, and
// there is exactly one labelled bounded fallback for the edgeless case.

import QtQuick

Item {
  id: root
  width: 1
  height: 1

  property string error: ""
  property string source: ""

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function read(path) {
    const xhr = new XMLHttpRequest()
    xhr.open("GET", path, false)
    xhr.send()
    return xhr.status === 200 ? (xhr.responseText || "") : ""
  }

  // One whole `function name(...) { ... }`, with braces in strings and line
  // comments skipped so a comment cannot close the block early.
  function extract(src, name) {
    const re = new RegExp("^[ \\t]*function " + name + "\\s*\\(", "m")
    const m = re.exec(src)
    if (!m) return ""
    let start = m.index
    while (start > 0 && (src[start - 1] === " " || src[start - 1] === "\t")) start--
    const open = src.indexOf("{", m.index + m[0].length - 1)
    if (open < 0) return ""
    let depth = 0
    let quote = ""
    let comment = false
    for (let j = open; j < src.length; j++) {
      const ch = src[j]
      if (comment) {
        if (ch === "\n") comment = false
        continue
      }
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
        if (depth === 0) return src.slice(start, j + 1)
      }
    }
    return ""
  }

  function strings() {
    return {
      candidate: extract(root.source, "_fitCandidate"),
      verdict: extract(root.source, "_fitSlotVerdict"),
      ready: extract(root.source, "_fitReadyEval"),
      drain: extract(root.source, "_drainFit"),
      when: extract(root.source, "whenFit"),
      giveup: extract(root.source, "_fitGiveUp"),
      commit: extract(root.source, "_fitCommit"),
      queue: extract(root.source, "queueFit")
    }
  }

  function buildMachine(bodies) {
    const names = ["candidate", "verdict", "ready", "drain", "when", "giveup", "commit", "queue"]
    let parts = ""
    for (const name of names) parts += "\n" + bodies[name] + "\n"
    // Cross-component names are rewritten; control flow and conditions are not.
    parts = parts.replace(/\bpanel\./g, "m.")
      .replace(/\bQt\.callLater\(/g, "m.later(")
      .replace(/\blist\./g, "m.list.")
      .replace(/\bfitFallback\./g, "m.fallback.")
      .replace(/\bd instanceof LauncherEntry\b/g, "d.entry === true")

    const lines = [
      'import QtQml',
      'QtObject {',
      '  id: m',
      '  property var _fitWaiters: []',
      '  property int _fitFallbackAttempts: 0',
      '  property real _latchedListH: -1',
      '  property bool _fitPending: false',
      '  property var rows: []',
      '  property real availListH: 300',
      '  property int slotLimit: 10',
      '  property real snappedModel: 110',
      '  property int laterCount: 0',
      '  property int latchRestingCalls: 0',
      '  property var pending: []',
      '  property QtObject fallback: QtObject {',
      '    property int starts: 0',
      '    function restart() { m.fallback.starts++ }',
      '    function stop() {}',
      '  }',
      '  property QtObject list: QtObject {',
      '    id: lst',
      '    property bool _inSwap: false',
      '    property int count: 0',
      '    property int fitValue: 120',
      '    property real contentHeight: 300',
      '    property QtObject contentItem: QtObject { property var children: [] }',
      '    function fitHeight(avail, max) { return lst.fitValue }',
      '  }',
      '  readonly property bool _fitReady: m._fitReadyEval()',
      '  function snappedListH(h) { return m.snappedModel }',
      '  function _latchRestingBuffer() { m.latchRestingCalls++ }',
      '  function later(fn) { m.laterCount++; m.pending.push(fn) }',
      '  function drainLater() { const p = m.pending.splice(0); for (const fn of p) fn() }',
      parts,
      '}'
    ]
    return Qt.createQmlObject(lines.join("\n"), root, "launcher_fit_slice.qml")
  }

  function fresh() {
    const m = buildMachine(strings())
    m.rows = [{ uid: "a" }, { uid: "b" }]
    m.snappedModel = 110
    m.list.count = 2
    m.list.fitValue = 120
    m.list._inSwap = false
    m.list.contentItem.children = []
    return m
  }

  // A delegate stub with real QML properties, so changing slotMotionMs
  // re-evaluates the derivation binding exactly as LauncherEntry does.
  function makeEntry(motion, desc) {
    return Qt.createQmlObject(
      'import QtQml\nQtObject { property bool entry: true; property real slotMotionMs: '
        + motion + '; property real descSlotH: ' + desc + '; property real deleteSlotH: 0 }',
      root, "launcher_entry_stub.qml")
  }

  function sourceFacts(bodies) {
    const src = root.source
    const from = src.indexOf("function _fitCandidate")
    const to = src.indexOf("function syncRowsNow")
    const region = from >= 0 && to > from ? src.slice(from, to) : ""
    kv("source.read", src.length > 0)
    kv("source.allFound", namesFound(bodies))
    kv("source.noRetryTimer", src.indexOf("fitRetryTimer") < 0)
    kv("source.noSharedCounter", src.indexOf("_fitAttempts") < 0)
    kv("source.noRetryLadder", src.indexOf("retrySettle") < 0 && src.indexOf("retryFit") < 0)
    kv("source.waitersShape", src.indexOf("property var _fitWaiters") >= 0
      && src.indexOf("function whenFit") >= 0)
    kv("source.derivation", /readonly property bool _fitReady:\s*panel\._fitReadyEval\(\)/.test(src)
      && /on_FitReadyChanged:\s*if \(panel\._fitReady\) panel\._drainFit\(\)/.test(src))
    kv("source.fourEdges", /list\._inSwap/.test(bodies.ready)
      && /list\.count/.test(bodies.ready)
      && /_fitCandidate\(\)/.test(bodies.ready)
      && /slotMotionMs/.test(bodies.verdict))
    kv("source.oneCallLater", (region.match(/Qt\.callLater\(/g) || []).length === 1)
    kv("source.oneFallback", (src.match(/id:\s*fitFallback\b/g) || []).length === 1
      && /_fitFallbackAttempts\s*<\s*\d+/.test(src))
    kv("source.fallbackLabelled", /no further edge|never instantiated|never publishes/i.test(region))
    kv("source.geometryPreserved", src.indexOf("slotRegionH: SlotGrowth.regionForSlot") >= 0
      && src.indexOf("slotOpen: list.revealNeedH > 0") >= 0)
    kv("source.epochsPreserved", src.indexOf("property bool _rowsPending") >= 0
      && src.indexOf("identityRevision: panel.identityRevision") >= 0
      && /const g = panel\._swapGen/.test(src))
    kv("source.restBufferKept", src.indexOf("panel._latchRestingBuffer()") >= 0)
  }

  function namesFound(bodies) {
    for (const k in bodies) if (bodies[k] === "") return false
    return true
  }

  function drive() {
    root.source = read("features/launcher/LauncherPanel.qml")
    const bodies = strings()
    sourceFacts(bodies)
    if (!namesFound(bodies)) return

    // A: arm while the swap window owns geometry; close on its edge.
    let m = fresh()
    m.queueFit()
    kv("arm.waiters", m._fitWaiters.length)
    kv("arm.pending", m._fitPending)
    kv("arm.modelNow", m._latchedListH)
    kv("arm.oneCallLater", m.laterCount)
    kv("arm.fallbackArmed", m.fallback.starts)
    m.list._inSwap = true
    for (let i = 0; i < 30; i++) m._drainFit()
    kv("swap.waited", m._fitWaiters.length)
    kv("swap.notLatched", m._latchedListH)
    m.list._inSwap = false
    kv("swap.readyLive", m._fitReady)
    m._drainFit()
    kv("swap.latched", m._latchedListH)
    kv("swap.pendingCleared", m._fitPending)
    kv("swap.waitersDrained", m._fitWaiters.length)
    kv("swap.restRelatch", m.latchRestingCalls)

    // B: the original bug - a long settle wait must not spend the fit budget.
    m = fresh()
    m.queueFit()
    m.list._inSwap = true
    for (let i = 0; i < 40; i++) m._drainFit()
    m.list._inSwap = false
    m.list.fitValue = -1
    for (let i = 0; i < 40; i++) m._drainFit()
    kv("budget.stillModelHeight", m._latchedListH)
    m.list.fitValue = 120
    m._drainFit()
    kv("budget.fitAfterPolish", m._latchedListH)

    // C: a slot in motion waits for its motion-finished edge.
    m = fresh()
    const moving = makeEntry(5, 0)
    m.list.contentItem.children = [moving]
    m.queueFit()
    m._drainFit()
    kv("slot.waitWhileMoving", m._latchedListH)
    moving.slotMotionMs = 0
    m._drainFit()
    kv("slot.fitAfterMotion", m._latchedListH)

    // D: an open but resting slot gives the region back to the buffer.
    m = fresh()
    m.list.contentItem.children = [makeEntry(0, 30)]
    m.queueFit()
    m._drainFit()
    kv("resting.gaveUp", m._latchedListH)
    kv("resting.pendingCleared", m._fitPending)

    // E: a count mismatch waits for onCountChanged.
    m = fresh()
    m.list.count = 1
    m.queueFit()
    m._drainFit()
    kv("count.waited", m._latchedListH)
    m.list.count = 2
    m._drainFit()
    kv("count.latched", m._latchedListH)
  }

  Component.onCompleted: {
    try {
      drive()
    } catch (e) {
      root.error = String(e && e.message ? e.message : e)
    }
    kv("probe.error", root.error)
    console.log("##DONE##")
  }
}
