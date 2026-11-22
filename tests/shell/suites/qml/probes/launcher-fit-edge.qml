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

  // A handler block (`onShownChanged: { ... }`) as a brace-balanced slice.
  function extractBlock(src, anchor) {
    const idx = src.indexOf(anchor)
    if (idx < 0) return ""
    const open = src.indexOf("{", idx + anchor.length)
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
        if (depth === 0) return src.slice(open, j + 1)
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

  // LNC-4 and LNC-5: the snap state machine and the swap generation, read
  // out of the same source bytes as the fit functions above.
  function snapStrings() {
    return {
      setSnap: extract(root.source, "setSnap"),
      fade: extract(root.source, "_maybeSwapFade"),
      syncNow: extract(root.source, "syncRowsNow"),
      sync: extract(root.source, "syncRows"),
      visible: extract(root.source, "onVisibleChanged"),
      entry: extract(root.source, "onEntryChanged"),
      shown: extractBlock(root.source, "onShownChanged:")
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

  // The snap/swap slice evaluated in a headless QtObject. Only component
  // boundaries are rewritten; the control flow and the generation guards are
  // the file's own bytes. `later` is a queue so a frame sequence can be
  // pumped one turn at a time instead of sampling end states.
  function buildSnapMachine(bodies) {
    const names = ["setSnap", "fade", "syncNow", "sync", "visible", "entry", "shown"]
    let parts = ""
    for (const name of names) {
      const body = bodies[name]
      if (body === "") continue
      if (name === "shown") parts += "\nfunction onShown()" + body + "\n"
      else if (name === "fade") parts += "\n"
        + body.replace(/function _maybeSwapFade\s*\(/, "function _fadeImpl(") + "\n"
      else parts += "\n" + body + "\n"
    }
    parts = parts.replace(/\bpanel\./g, "m.")
      .replace(/\bAppLauncher\./g, "m.app.")
      .replace(/\bQt\.callLater\(/g, "m.later(")
      .replace(/\blist\./g, "m.list.")
      .replace(/\bfocusCtrl\./g, "m.focus.")
      .replace(/\bsearchField\./g, "m.field.")

    const lines = [
      'import QtQml',
      'QtObject {',
      '  id: m',
      '  property bool sizeSnap: false',
      '  property int _snapGen: 0',
      '  property string _snapReason: ""',
      '  property bool shown: false',
      '  property bool _modeExitFade: false',
      '  property bool _modeEnterFade: false',
      '  property int _swapGen: 0',
      '  property bool _rowsPending: false',
      '  property bool _openSeat: false',
      '  property var rows: []',
      '  property var _records: []',
      '  property int installCalls: 0',
      '  property int settleCalls: 0',
      '  property int swapRunCalls: 0',
      '  property int fadeCalls: 0',
      '  property var pending: []',
      '  property QtObject app: QtObject {',
      '    property bool visible: false',
      '    property string entry: ""',
      '    property var results: []',
      '  }',
      '  property QtObject field: QtObject { property string text: "" }',
      '  property QtObject focus: QtObject {',
      '    function grabList() {}',
      '    function grabFilter() {}',
      '    function reassert() {}',
      '  }',
      '  property QtObject list: QtObject {',
      '    property int count: 2',
      '    property int currentIndex: 0',
      '    function beginSwap() {}',
      '    function endSwap() {}',
      '    function seat(i, how) {}',
      '    function seatTo(y, a, why) {}',
      '    function settle(i, now) { m.settleCalls++ }',
      '    function swapRun(g, live, fn) { m.swapRunCalls++; if (live(g)) fn() }',
      '  }',
      '  function later(fn) { m.pending.push(fn) }',
      '  function drainLater() { const p = m.pending.splice(0); for (const fn of p) fn() }',
      '  function show() { m.shown = false }',
      '  function closeNotice() {}',
      '  function closeDelete() {}',
      '  function recalcWidth() {}',
      '  function closeTrailingInfo() {}',
      '  function _firstNormalIndex() { return 0 }',
      '  function _rowKey(rec) { return rec ? String(rec.uid ?? "") : "" }',
      '  function installRows() { m.installCalls++; m._records = m.rows }',
      '  function queueFit() {}',
      '  function _needsSwapFade() { return false }',
      '  function playSwapFade() {}',
      '  function _maybeSwapFade() { m.fadeCalls++; return m._fadeImpl() }',
      parts,
      '}'
    ]
    return Qt.createQmlObject(lines.join("\n"), root, "launcher_snap_slice.qml")
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

  // LNC-11: cursor decisions must read the view's model, not the producer's
  // pending array. The functions and the two callbacks are lifted verbatim;
  // only the component boundaries (panel, list, AppLauncher) are rewritten.
  function cursorStrings() {
    return {
      current: extract(root.source, "currentRecord"),
      first: extract(root.source, "_firstNormalIndex"),
      info: extract(root.source, "toggleInfoCurrent"),
      del: extractBlock(root.source, "readonly property bool deleteKeyAvailable:"),
      toggleDel: extract(root.source, "toggleDeleteCurrent"),
      activate: extract(root.source, "activateCurrent"),
      select: extractBlock(root.source, "isSelectable: i =>")
    }
  }

  function buildCursor(b) {
    let parts = "\n" + b.current + "\n" + b.first + "\n" + b.info + "\n"
      + "readonly property bool deleteKeyAvailable: " + b.del + "\n"
      + b.toggleDel + "\n" + b.activate + "\n"
      + "function isSelectable(i)" + b.select + "\n"
    parts = parts.replace(/\bpanel\./g, "m.")
      .replace(/\blist\./g, "m.list.")
      .replace(/\bAppLauncher\./g, "m.app.")

    return Qt.createQmlObject([
      'import QtQml',
      'QtObject {',
      '  id: m',
      '  property var _records: [',
      '    { uid: "sep:", kind: "separator" },',
      '    { uid: "app:live", kind: "app", removable: true, desc: "live desc" }',
      '  ]',
      '  property var rows: [',
      '    { uid: "app:producer", kind: "app", removable: true, desc: "" },',
      '    { uid: "sep:", kind: "separator", desc: "" }',
      '  ]',
      '  property int _infoIndex: -1',
      '  property int _deleteIndex: -1',
      '  property int _deleteStage: 0',
      '  property var activated: null',
      '  property int settles: 0',
      '  property int settleIdx: -1',
      '  property QtObject list: QtObject {',
      '    id: lst',
      '    property int currentIndex: 1',
      '    property int autoRevealIndex: -1',
      '    function isSelectable(i) { return m.isSelectable(i) }',
      '    function settle(i, now) { m.settles++; m.settleIdx = i }',
      '    function seat(i, how) {}',
      '  }',
      '  property QtObject app: QtObject {',
      '    function activate(rec) { m.activated = rec ? rec.uid : "none" }',
      '    function requestDelete(rec) {}',
      '    function confirmDelete() {}',
      '  }',
      '  function closeDelete() { m._deleteIndex = -1; m._deleteStage = 0 }',
      '  function acceptDelete() {}',
      '  function flashNotDeletable(idx) {}',
      parts,
      '}'
    ].join("\n"), root, "launcher_cursor_slice.qml")
  }

  function driveCursor() {
    const b = cursorStrings()
    let found = true
    for (const k in b) if (b[k] === "") found = false
    kv("cursor.source.found", found)
    if (!found) {
      kv("cursor.source.live", false)
      kv("cursor.source.noProducer", false)
      kv("cursor.source.seatLive", false)
      kv("cursor.source.seatAfterInstall", false)
      kv("cursor.first", "missing")
      kv("cursor.selectable", "missing")
      kv("cursor.record", "missing")
      kv("cursor.deleteLive", "missing")
      kv("cursor.info", "missing")
      kv("cursor.activated", "missing")
      return
    }
    const code = codeOnly(root.source)
    kv("cursor.source.live", /function currentRecord\b/.test(code)
      && /_records\[/.test(b.current))
    let readers = ""
    for (const k in b) readers += b[k]
    kv("cursor.source.noProducer", readers.indexOf("panel.rows") < 0)
    kv("cursor.source.seatLive", /_records\[/.test(b.current)
      && /currentRecord/.test(b.first) && /currentRecord/.test(b.select))
    const syncNow = b.syncNow || extract(root.source, "syncRowsNow")
    const sync = b.sync || extract(root.source, "syncRows")
    kv("cursor.source.seatAfterInstall", syncNow !== "" && sync !== ""
      && syncNow.indexOf("installRows()") < syncNow.indexOf("_firstNormalIndex()")
      && sync.indexOf("installRows()") < sync.indexOf("_firstNormalIndex()"))

    try {
      const m = buildCursor(b)
      kv("cursor.first", m._firstNormalIndex())
      kv("cursor.selectable", m.isSelectable(0) + "," + m.isSelectable(1))
      kv("cursor.record", m.currentRecord() ? m.currentRecord().uid : "none")
      kv("cursor.deleteLive", m.deleteKeyAvailable)
      m.toggleInfoCurrent()
      kv("cursor.info", m._infoIndex)
      m.activateCurrent()
      kv("cursor.activated", m.activated ? m.activated : "none")
    } catch (e) {
      root.error = String(e && e.message ? e.message : e)
    }
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

  // The snap writer is also described in comments; count writes in code only.
  function codeOnly(src) {
    return src.split("\n").map(l => l.replace(/\/\/.*$/, "")).join("\n")
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

    driveSnap(snapStrings())
  }

  function driveSnap(bodies) {
    const src = root.source
    kv("snap.source.found", namesFound(bodies))
    if (!namesFound(bodies)) return

    // Structure: both raw sizeSnap writes live in one generation-guarded
    // setSnap. The fade path must not touch snap at all: a hidden sync after
    // close runs it, and disarming there is the grow-to-fit on summon.
    const code = codeOnly(src)
    const rawWrites = (code.match(/panel\.sizeSnap\s*=/g) || []).length
    const writerWrites = (codeOnly(bodies.setSnap).match(/panel\.sizeSnap\s*=/g) || []).length
    kv("snap.source.singleWriter", rawWrites > 0 && rawWrites === writerWrites)
    kv("snap.source.guarded", /function setSnap\(reason, gen\)/.test(src)
      && /gen !== panel\._snapGen/.test(bodies.setSnap))
    kv("snap.source.fadeNeverWrites", bodies.fade.indexOf("sizeSnap") < 0)
    kv("snap.source.closeArms", /setSnap\("close-arm",\s*\+\+panel\._snapGen\)/.test(src))
    kv("snap.source.gateReleases", /panel\.setSnap\("shown",\s*panel\._snapGen\)/.test(bodies.shown))
    kv("snap.source.inputReleases", /AppLauncher\.visible\)\s*panel\.setSnap\("input"/.test(src))
    // LNC-5: the open seat mints a generation in both branches, and the
    // deferred sync captures one at schedule time and checks it at fire.
    kv("swap.source.genInSyncNow", (bodies.syncNow.match(/panel\._swapGen\+\+/g) || []).length === 1
      && bodies.syncNow.indexOf("panel._swapGen++") < bodies.syncNow.indexOf("list.beginSwap"))
    kv("swap.source.capturedGen", /const scheduledGen = panel\._swapGen/.test(bodies.sync)
      && /scheduledGen !== panel\._swapGen/.test(bodies.sync))

    // LNC-5: hidden recompute -> deferred sync -> open seat. The seat steals
    // the install and bumps the generation; the stale closure must retire
    // instead of installing and settling a second row set over it.
    let m = buildSnapMachine(bodies)
    m.rows = [{ uid: "a" }, { uid: "b" }]
    m.app.results = m.rows
    m.syncRows()
    kv("swap.pendingArmed", m._rowsPending)
    const beforeGen = m._swapGen
    m._openSeat = true
    m.app.visible = true
    m.onVisibleChanged()
    kv("swap.genBumped", m._swapGen === beforeGen + 1)
    kv("swap.installsAfterSeat", m.installCalls)
    const seatInstalls = m.installCalls
    m.drainLater()
    kv("swap.staleRetired", m.installCalls === seatInstalls && m.swapRunCalls === 0)

    // LNC-4: open -> typed query -> close -> hidden typed query + recompute
    // -> close -> open. The first sizing of the last open must still snap.
    let n = buildSnapMachine(bodies)
    n.rows = [{ uid: "a" }, { uid: "b" }]
    n.app.results = n.rows
    n.app.visible = true
    n.onVisibleChanged()
    kv("snap.afterFirstOpen", n.sizeSnap)
    n.shown = true
    n.onShown()
    kv("snap.afterGate", n.sizeSnap)
    n.app.entry = "ab"
    n.onEntryChanged()
    kv("snap.afterTyping", n.sizeSnap)

    n.app.visible = false
    n.onVisibleChanged()
    kv("snap.closeArmed", n.sizeSnap)
    kv("snap.closeReason", n._snapReason)
    const armGen = n._snapGen

    // A query arriving while hidden must not release the arm.
    n.app.entry = "c"
    n.onEntryChanged()
    kv("snap.hiddenInputKeepsArm", n.sizeSnap)

    // A hidden recompute republishes rows through the deferred sync, which
    // runs _maybeSwapFade while still hidden. That path must leave the arm.
    n.rows = [{ uid: "x", kind: "calc" }]
    n.syncRows()
    n.drainLater()
    kv("snap.fadeCallsWhileHidden", n.fadeCalls)
    kv("snap.survivesHiddenSync", n.sizeSnap)
    kv("snap.reasonSurvives", n._snapReason)

    // A release carrying an older generation cannot clear the fresh arm.
    n.setSnap("shown", armGen - 1)
    kv("snap.staleReleaseIgnored", n.sizeSnap)

    // Reopen: the first sizing still happens under the snap, then the gate
    // opens and releases it for typing.
    m = n
    m.app.results = m.rows
    m.app.visible = true
    m.onVisibleChanged()
    kv("snap.beforeReopenGate", m.sizeSnap)
    m.shown = true
    m.onShown()
    kv("snap.afterReopenGate", m.sizeSnap)
    kv("snap.releaseReason", m._snapReason)
  }

  Component.onCompleted: {
    try {
      drive()
    } catch (e) {
      root.error = String(e && e.message ? e.message : e)
    }
    try {
      driveCursor()
    } catch (e) {
      root.error = String(e && e.message ? e.message : e)
    }
    kv("probe.error", root.error)
    console.log("##DONE##")
  }
}
