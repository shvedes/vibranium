// Probe: PassPanel delete-pin release and deferred row-sync tokens (LNC-2/3).
//
// PassPanel cannot be constructed offscreen: it needs the Pass service, a
// PanelWindow-backed card and a screen. This probe reads the real file and
// evaluates its OWN function bodies in a headless QtObject. Only the names
// that cross the component boundary are stubbed (panel -> m, list, Pass,
// Idle, Qt.callLater, MotionPolicy, focusCtrl); the bodies themselves are the
// file's bytes, brace-balanced out of the source. A source change that moves
// or renames them makes the probe report a missing function.
//
// The two frame contracts:
//   * a delete pin is released only on a real list edge while the generation
//     that armed it is current - an overlapping delete must keep its pin;
//   * a deferred sync commits its OWN token, view key and page generation,
//     so a newer rebuild cannot make an older closure reset a live slide.

import QtQuick

Item {
  id: root
  width: 1
  height: 1

  property string error: ""
  property string source: ""
  property var machine: null

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
      sync: extract(root.source, "syncRows"),
      release: extract(root.source, "_releaseDeletePinWhenLive"),
      watch: extract(root.source, "_watchDeletePin"),
      rearm: extract(root.source, "_rearmDeletePin")
    }
  }

  // The real bodies go on a QtObject whose stubs publish the edges the two
  // functions read. `_pending*` exist so the old late-read shape still runs;
  // the fixed shape simply never touches them.
  function buildMachine(bodies) {
    let parts = ""
    for (const name of ["sync", "release", "watch", "rearm"]) {
      let body = bodies[name]
      if (name === "watch" && body === "")
        body = "function _watchDeletePin() {}"
      if (name === "rearm" && body === "")
        body = "function _rearmDeletePin() {}"
      parts += "\n" + body + "\n"
    }
    // Only the cross-component names are rewritten, never the control flow.
    parts = parts.replace(/\bpanel\./g, "m.")
      .replace(/\bIdle\.run\(/g, "m.idle(")
      .replace(/\bQt\.callLater\(/g, "m.later(")
      .replace(/\bPass\./g, "m.pass.")
      .replace(/\bMotionPolicy\.enabled\b/g, "m.motion")
      .replace(/\bfocusCtrl\./g, "m.focus.")

    const lines = [
      'import QtQml',
      'QtObject {',
      '  id: m',
      '  property int _flushEpoch: 0',
      '  property bool _rowsPending: false',
      '  property int _pendingFrameToken: -1',
      '  property bool _pendingResumeTracking: false',
      '  property int _swapGen: 0',
      '  property int _pageTransitionGen: 1',
      '  property int _pinGen: 0',
      '  property var _pinRelease: null',
      '  property bool _openSeat: false',
      '  property string frameOwner: "pass"',
      '  property string view: "pageA"',
      '  property string sub: ""',
      '  property string filterText: ""',
      '  property string pendingSelectDir: ""',
      '  property string listError: ""',
      '  property bool _deleteGlide: false',
      '  property var _rows: []',
      '  property string _lastSeq: ""',
      '  property int _epoch: 0',
      '  property var rowData: []',
      '  property int editorIndex: -1',
      '  property bool editorPendingFocus: false',
      '  property string editorMode: ""',
      '  property bool secretOpen: false',
      '  property int resets: 0',
      '  property var frames: null',
      '  property var list: null',
      '  property var pass: null',
      '  property var focus: null',
      '  property bool motion: true',
      '  property var pending: []',
      '  function viewKey() { return m.view }',
      '  function keyedRows() { return [] }',
      '  function resetPageTransition() { m.resets++; m._pageTransitionGen++ }',
      '  function flushFrameDiscard() {}',
      '  function later(fn) { m.pending.push(fn) }',
      '  function idle(fn, ticks) { m.pending.push(fn) }',
      parts,
      '}'
    ]
    const m = Qt.createQmlObject(lines.join("\n"), root, "pass_panel_slice.qml")
    root.machine = m
    m.frames = makeFrames()
    m.list = makeList(m)
    m.pass = { mode: "browse", visible: true }
    m.focus = { reassert: function () {} }
    return m
  }

  // The frame table answers exactly the question commit() asks: is this
  // token still the active one, and was it minted for this view key?
  function makeFrames() {
    return {
      activeKey: "pageA",
      activeToken: -1,
      nextToken: 0,
      tokenKeys: ({}),
      mismatches: 0,
      commits: 0,
      begin: function (owner) {
        const t = ++this.nextToken
        this.activeToken = t
        this.tokenKeys[t] = this.keyAtBegin
        return t
      },
      frameFor: function () { return null },
      commit: function (token, key) {
        this.commits++
        if (this.tokenKeys[token] !== key) this.mismatches++
        if (token !== this.activeToken) return false
        this.activeKey = key
        this.activeToken = -1
        return true
      },
      get tokenLive() { return this.activeToken >= 0 }
    }
  }

  function makeList(m) {
    return {
      currentIndex: 0,
      count: 0,
      _inSwap: false,
      _seatsInstant: true,
      _hlPin: false,
      unpins: 0,
      autoRevealIndex: -1,
      currentItem: null,
      itemAtIndex: function () { return null },
      pinHighlight: function () { this._hlPin = true },
      unpinHighlight: function () { this.unpins++; this._hlPin = false },
      seat: function () {},
      settle: function () {},
      seatTo: function () {},
      reveal: function () {},
      restoreAt: function () {},
      swapRun: function (gen, isLive, settleFn) {
        this._inSwap = true
        settleFn()
        this._inSwap = false
      }
    }
  }

  // Run queued deferreds in scheduling order, including ones they enqueue.
  function drain(m, turns) {
    for (let i = 0; i < turns && m.pending.length > 0; i++) {
      const fn = m.pending.shift()
      fn()
    }
  }

  function drive() {
    root.source = read("features/pass/PassPanel.qml")
    const bodies = strings()
    kv("slice.sourceStatus", root.source.length > 0)
    kv("slice.syncFound", bodies.sync.length > 0)
    kv("slice.releaseFound", bodies.release.length > 0)

    kv("slice.noSharedSlots", root.source.indexOf("_pendingFrameToken") < 0
      && root.source.indexOf("_pendingResumeTracking") < 0)
    kv("slice.capturesLocals", /const\s+token\s*=\s*frameToken/.test(bodies.sync)
      && /const\s+shouldResume\s*=/.test(bodies.sync)
      && /const\s+g\s*=/.test(bodies.sync)
      && /const\s+k\s*=/.test(bodies.sync)
      && /const\s+transitionGen\s*=/.test(bodies.sync))
    kv("slice.flushEpochRetained", root.source.indexOf("_flushEpoch") >= 0
      && /_flushEpoch\s*!==\s*epoch/.test(bodies.sync))

    let m = buildMachine(bodies)
    kv("pin.noClockPoll", bodies.release.indexOf("Date.now") < 0)
    kv("pin.edgeHandlers", /target:\s*list[\s\S]*?onSeatsInstantChanged[\s\S]*?onMotionFinished/.test(root.source))

    // A delete armed the pin (generation 1). The bar cannot travel yet:
    // the swap window still owns the view.
    m._pinGen = 1
    m.list.pinHighlight()
    m._releaseDeletePinWhenLive()
    drain(m, 2)
    kv("pin.beforeNewDelete", m.list.unpins)

    // A second delete arrives before the first release lands. It arms a new
    // pin with a new generation; the first release must retire, not unpin.
    m._pinGen++
    m.list.pinHighlight()
    m._releaseDeletePinWhenLive()
    drain(m, 2)
    kv("pin.midNewMotion", m.list.unpins)

    // The view becomes live. The old polls unpin here without any edge;
    // the generation-scoped release waits for the list signal instead.
    m.list._inSwap = false
    m.list._seatsInstant = false
    drain(m, 4)
    kv("pin.duringNewMotion", m.list.unpins)
    // The edge arrives: only the current generation's release may unpin.
    if (m._pinRelease) m._pinRelease()
    kv("pin.afterEdge", m.list.unpins)

    // --- LNC-3: two syncs queued, then a new page slide opens ---
    m = buildMachine(bodies)
    m.frames.keyAtBegin = "pageA"
    m.frames.begin(m.frameOwner) // token 1, for pageA
    m.syncRows(1, true, false)   // deferred flush A
    m.view = "pageB"
    m.frames.keyAtBegin = "pageB"
    m.frames.begin(m.frameOwner) // token 2 supersedes token 1
    m.syncRows(2, true, false)   // deferred flush B (overlaps A)
    m.view = "pageC"
    m._pageTransitionGen = 2     // a live page slide starts (gen 2)
    m.frames.keyAtBegin = "pageC"
    m.frames.begin(m.frameOwner) // token 3, pinned by the live slide
    drain(m, 8)
    kv("sync.resetsDuringLiveSlide", m.resets)
    kv("sync.mismatchedCommits", m.frames.mismatches)

    // The transition's own sync commits token 3 and closes the window.
    m.syncRows(3, true, false)
    drain(m, 8)
    kv("sync.windowClosed", !m.frames.tokenLive)
    kv("sync.finalKey", m.frames.activeKey)
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
