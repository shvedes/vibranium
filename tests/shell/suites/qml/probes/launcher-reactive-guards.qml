// Probe: launcher reactive guards (LNC-6, LNC-8, LNC-9, LNC-10).
//
// AppLauncher is a singleton and its controller a Loader child that needs a
// compositor, so neither can be constructed offscreen. This probe reads the
// two real source files and evaluates the exact functions and handler blocks
// in headless QtObject slices. Only names that cross a component boundary are
// stubbed (Process, Timer, UnitGate, SurfaceClaim, Qt.callLater); every guard,
// generation and edge check is the file's own bytes. A rename or move of a
// function is reported as missing rather than silently passing.
//
// The contract pinned here:
//   LNC-6  plugin discovery is generation-guarded; a newer demand retires a
//          running scan's late exit and dirs are cleared when the scan starts.
//   LNC-8  the boot prewarm waits on the real bootEntrance edge, and a UnitGate
//          refusal gets exactly one capped retry that the edge can cancel.
//   LNC-9  a reload replay forces visible false so open() re-takes the claim.
//   LNC-10 every deferred continuation carries an alive guard captured when
//          it was scheduled, so a torn-down controller cannot be touched.

import QtQuick
import Quickshell.Io

Item {
  id: root
  width: 1
  height: 1

  property string error: ""
  property string ctl: ""
  property string facade: ""

  // The collector fact needs a real child process, so the sentinel waits for
  // both the source slices and that two-run probe to finish.
  property bool factsDone: false
  property bool collectorDone: false
  property int collectorExits: 0

  function maybeDone() {
    if (!root.factsDone || !root.collectorDone) return
    kv("probe.error", root.error)
    console.log("##DONE##")
  }

  Process {
    id: collectorProc
    stdout: StdioCollector { id: collectorOut }
    onExited: {
      root.collectorExits++
      if (root.collectorExits === 1) {
        Qt.callLater(function () {
          collectorProc.command = ["sh", "-c", "true"]
          collectorProc.running = true
        })
        return
      }
      kv("collector.runtime.freshAtExit", collectorOut.text === "")
      root.collectorDone = true
      root.maybeDone()
    }
  }
  Timer {
    id: collectorWatchdog
    interval: 4000
    onTriggered: {
      if (root.collectorDone) return
      kv("collector.runtime.freshAtExit", "unverified")
      root.collectorDone = true
      root.maybeDone()
    }
  }

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function read(path) {
    const xhr = new XMLHttpRequest()
    xhr.open("GET", path, false)
    xhr.send()
    return xhr.status === 200 ? (xhr.responseText || "") : ""
  }

  // One whole `function name(...) { ... }`, brace-balanced with quotes and
  // line comments skipped so a comment cannot close the block early.
  function extract(src, name) {
    const re = new RegExp("^[ \\t]*function " + name + "\\s*\\(", "m")
    const m = re.exec(src)
    if (!m) return ""
    let start = m.index
    while (start > 0 && (src[start - 1] === " " || src[start - 1] === "\t")) start--
    const open = src.indexOf("{", m.index + m[0].length - 1)
    if (open < 0) return ""
    const block = balanced(src, open)
    return block === "" ? "" : src.slice(start, open + block.length)
  }

  // The `{ ... }` block that follows `anchor`, searching from `from`.
  function blockAfter(src, from, anchor) {
    const idx = src.indexOf(anchor, from)
    if (idx < 0) return ""
    const open = src.indexOf("{", idx + anchor.length)
    if (open < 0) return ""
    return balanced(src, open)
  }

  function balanced(src, open) {
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

  function codeOnly(src) {
    return src.split("\n").map(l => l.replace(/\/\/.*$/, "")).join("\n")
  }

  function found(bodies) {
    for (const k in bodies) if (bodies[k] === "") return false
    return true
  }

  function bodies() {
    const c = root.ctl
    const f = root.facade
    const comp = f.indexOf("Component.onCompleted:")
    const scanAt = c.indexOf("id: scanProc")
    return {
      discover: extract(c, "discoverPlugins"),
      exited: blockAfter(c, scanAt < 0 ? 0 : scanAt, "onExited:"),
      later: extract(c, "_later"),
      prewarm: extract(f, "_prewarm"),
      open: extract(f, "open"),
      replay: blockAfter(f, comp < 0 ? 0 : comp, "if (root.visible)"),
      timeAsk: extract(c, "requestTime"),
      timeExit: extract(c, "_onTimeProbed"),
      timeDrain: extract(c, "_drainTimeQueue"),
      net: extract(c, "requestNet"),
      tryExec: extract(c, "_onTryExecScanned"),
      binScan: extract(c, "_onBinariesScanned"),
    }
  }

  // ---- LNC-6: plugin discovery slice ------------------------------------
  function buildScan(b) {
    const d = b.discover.replace(/\broot\./g, "m.")
      .replace(/\bscanProc\./g, "m.proc.")
      .replace(/\bLauncherLib\.pluginScanArgv\([^)]*\)/g, "m.argv()")
      .replace(/\bQt\.callLater\(/g, "m.later(")
    const e = b.exited.replace(/\broot\./g, "m.")
      .replace(/\bscanProc\./g, "m.proc.")
      .replace(/\bQt\.callLater\(/g, "m.later(")
    return Qt.createQmlObject([
      'import QtQml',
      'QtObject {',
      '  id: m',
      '  property int scanSeq: 0',
      '  property bool _scanQueued: false',
      '  property bool pluginsResolved: true',
      // Batch B publishes discovery state from the same exit handler. The
      // stub carries it so the exact source block can still be evaluated.
      '  property string discoveryState: "ready"',
      '  property var plugins: []',
      '  property var registered: []',
      '  property var registerLog: []',
      '  property int registerCalls: 0',
      '  property var laterQueue: []',
      '  property var _life: ({ alive: true })',
      '  function _later(fn) { m.laterQueue.push(function() { if (m._life.alive) fn() }) }',
      '  property QtObject proc: QtObject {',
      '    property int seq: 0',
      '    property var dirs: []',
      '    property bool running: false',
      '    property var command: []',
      '  }',
      '  function argv() { return ["scan"] }',
      '  function later(fn) { m.laterQueue.push(fn) }',
      '  function drainLater() { const q = m.laterQueue.splice(0); for (const f of q) f() }',
      '  function _registerPlugins(dirs) { m.registerCalls++; m.registered = dirs.slice(); m.registerLog.push(dirs.join(",")) }',
      '  ' + d,
      // The exit handler receives the process code as an argument; the stub
      // fires the successful path so the directory collector is exercised.
      '  function fireExited() { m.proc.running = false; (function (code) {' + e + '})(0) }',
      '}'
    ].join("\n"), root, "launcher_scan_slice.qml")
  }

  // ---- LNC-8: prewarm slice ---------------------------------------------
  function buildPrewarm(b) {
    const p = b.prewarm.replace(/\broot\./g, "m.")
      .replace(/\bDesktopLayoutState\.bootEntrancePlayed/g, "m.bootEntrancePlayed")
      .replace(/\bprewarmRetry\./g, "m.retry.")
      .replace(/\blease\.demand\(\)/g, "m.demand()")
    return Qt.createQmlObject([
      'import QtQml',
      'QtObject {',
      '  id: m',
      '  property bool _prewarmed: false',
      '  property bool _prewarmPending: false',
      '  property int _prewarmRetries: 0',
      '  property int _prewarmMaxRetries: 1',
      '  property bool bootEntrancePlayed: false',
      '  property string controllerState: "loading"',
      '  property var demandResult: null',
      '  property QtObject retry: QtObject {',
      '    property int starts: 0',
      '    property int stops: 0',
      '    function restart() { m.retry.starts++ }',
      '    function stop() { m.retry.stops++ }',
      '  }',
      '  function demand() { return m.demandResult }',
      '  ' + p,
      '}'
    ].join("\n"), root, "launcher_prewarm_slice.qml")
  }

  // ---- LNC-9: reload replay slice ---------------------------------------
  function buildReplay(b) {
    const o = b.open.replace(/\broot\./g, "m.")
      .replace(/\blease\.demand\(\)/g, "m.demand()")
      .replace(/\bSurfaceClaim\.claim\(/g, "m.claim(")
      .replace(/\bcloseSettle\./g, "m.settle.")
      .replace(/\bopenProbeTimeout\./g, "m.probeTimeout.")
      .replace(/function open\(\)\s*\{/, "function open() { m.visibleAtOpen = m.visible;")
    const r = b.replay.replace(/\broot\./g, "m.")
    return Qt.createQmlObject([
      'import QtQml',
      'QtObject {',
      '  id: m',
      '  property bool visible: true',
      '  property bool _openWaiting: false',
      '  property var _claimToken: null',
      '  property bool _replaying: false',
      '  property string controllerState: "loading"',
      '  property bool visibleAtOpen: false',
      '  property int claimCalls: 0',
      '  property QtObject settle: QtObject { function stop() {} function restart() {} }',
      '  property QtObject probeTimeout: QtObject { function stop() {} function restart() {} }',
      '  property QtObject fakeCtrl: QtObject { function clipProbePending() { return false } }',
      '  function demand() { return m.fakeCtrl }',
      '  function claim(tag, fn, owner) { m.claimCalls++; return { tag: tag } }',
      '  function _openCompute() {}',
      '  ' + o,
      '  function replay() ' + r,
      '}'
    ].join("\n"), root, "launcher_replay_slice.qml")
  }

  // ---- LNC-10: deferred callback guard slice ----------------------------
  function buildLater(b) {
    const l = b.later.replace(/\broot\./g, "m.")
      .replace(/\bQt\.callLater\(/g, "m.enqueue(")
    return Qt.createQmlObject([
      'import QtQml',
      'QtObject {',
      '  id: m',
      '  property var _life: ({ alive: true })',
      '  property int calls: 0',
      '  property var queue: []',
      '  function enqueue(fn) { m.queue.push(fn) }',
      '  ' + l,
      '  function drain() { const q = m.queue.splice(0); for (const f of q) f() }',
      '}'
    ].join("\n"), root, "launcher_later_slice.qml")
  }

  // ---- LNC-12: zone intent queue slice ----------------------------------
  function buildTime(b) {
    const ask = b.timeAsk
      .replace(/\btimeProc\.running = true\b/g,
        "timeProc.running = true; root.started.push(timeProc.zone)")
      .replace(/\broot\./g, "m.")
      .replace(/\btimeProc\./g, "m.proc.")
      .replace(/\bLauncherLib\.timeProbeFormat\(tz\)/g, "m.fmt(tz)")
      .replace(/\bLauncherLib\.timeVerdict\([^)]*\)/g, "m.verdict()")
      .replace(/\bAppLauncher\.visible\b/g, "m.visible")
    const exit = b.timeExit.replace(/\broot\./g, "m.")
      .replace(/\bAppLauncher\.visible\b/g, "m.visible")
      .replace(/\btimeProc\./g, "m.proc.")
      .replace(/\bLauncherLib\.timeVerdict\([^)]*\)/g, "m.verdict()")
    let lines = [
      'import QtQml',
      'QtObject {',
      '  id: m',
      '  property bool visible: false',
      '  property var timeCache: ({})',
      '  property int _timeTtlMs: 1000',
      // Batch B's failed-zone stamp must exist in the slice too.
      '  property var _timeFailures: Object.create(null)',
      '  property string _timePendingZone: ""',
      '  property var _timePendingZones: []',
      '  property var started: []',
      '  property QtObject proc: QtObject {',
      '    id: tp',
      '    property bool running: false',
      '    property string zone: ""',
      '    property string out: ""',
      '    property var environment: ({})',
      '    property var command: []',
      '  }',
      '  function fmt(tz) { return "%H:%M" }',
      '  function verdict() { return { changed: false, reading: {} } }',
      '  function recompute() {}',
      '  ' + ask,
      '  ' + exit,
    ]
    if (b.timeDrain !== "") {
      lines.push('  ' + b.timeDrain.replace(/\broot\./g, "m.").replace(/\btimeProc\./g, "m.proc."))
    }
    lines.push('  function fireExited() { m.proc.running = false; m._onTimeProbed() }')
    lines.push('}')
    return Qt.createQmlObject(lines.join("\n"), root, "launcher_time_slice.qml")
  }

  // ---- LNC-12: send-failure slice ----------------------------------------
  function buildNet(b) {
    const n = b.net.replace(/\broot\./g, "m.")
      .replace(/new XMLHttpRequest\(\)/g, "m.newXhr()")
      .replace(/\bAppLauncher\._netLogPathLimit\b/g, "m.netLogLimit")
      .replace(/\bLog\.at\(\)/g, "m.logAt()")
    return Qt.createQmlObject([
      'import QtQml',
      'QtObject {',
      '  id: m',
      '  property var netCache: ({})',
      '  property var _netPending: ({})',
      '  property var _netLive: []',
      '  property var settled: []',
      '  property int _netRetryMs: 1000',
      '  property int _netTtlMs: 5000',
      '  property int netLogLimit: 40',
      '  function _settleNet(u, body) { m.settled.push(u + "=" + body) }',
      '  function newXhr() {',
      '    return { readyState: 0, open: function () {}, send: function () { throw new Error("boom") } }',
      '  }',
      '  function logAt() { return { allows: function () { return false } } }',
      '  ' + n,
      '}'
    ].join("\n"), root, "launcher_net_slice.qml")
  }

  function sourceFacts(b) {
    const c = codeOnly(root.ctl)
    const f = codeOnly(root.facade)
    kv("source.read", root.ctl.length > 0 && root.facade.length > 0)
    kv("source.allFound", found(b))

    // LNC-6.
    kv("scan.source.seq", b.discover !== ""
      && /property int scanSeq\s*:/.test(c)
      && /const g = \+\+root\.scanSeq/.test(b.discover))
    kv("scan.source.clearAtStart", b.discover.indexOf("scanProc.dirs = []") >= 0)
    kv("scan.source.staleExit", /scanProc\.seq !== root\.scanSeq/.test(b.exited))
    kv("scan.source.requeued", /\b(?:Qt\.callLater|root\._later)\(/.test(b.exited))

    // LNC-8.
    kv("prewarm.source.capped", /property int _prewarmMaxRetries\s*:\s*\d+/.test(f)
      && b.prewarm !== ""
      && /_prewarmRetries\s*<\s*root\._prewarmMaxRetries/.test(b.prewarm))
    const gateBranch = b.prewarm.slice(0, b.prewarm.indexOf("const ctrl"))
    kv("prewarm.source.noGateTimer", b.prewarm !== ""
      && gateBranch.indexOf("prewarmRetry.restart()") < 0)
    kv("prewarm.source.stopOnSuccess", b.prewarm.indexOf("prewarmRetry.stop()") >= 0)
    const edge = blockAfter(f, f.indexOf("Connections {"), "function onBootEntrancePlayedChanged()")
    kv("prewarm.source.edgeCancels", /prewarmRetry\.stop\(\)/.test(edge))

    // LNC-9.
    kv("replay.source.forcesFalse", b.replay.indexOf("root.visible = false") >= 0
      && b.replay.indexOf("root.visible = false") < b.replay.indexOf("root.open()"))
    kv("replay.source.underFlag", b.replay.indexOf("root._replaying = true") >= 0
      && b.replay.indexOf("root._replaying = false") >= 0)
    kv("replay.source.guardKept", /if \(root\._replaying\) return/.test(f))

    // LNC-10.
    kv("later.source.holder", /property var _life:\s*\(\{\s*alive:\s*true\s*\}\)/.test(c))
    kv("later.source.flip", /root\._life\.alive = false/.test(c))
    kv("later.source.wrapper", /function _later\(/.test(c) && /life\.alive/.test(b.later))
    kv("later.source.noRawAuto", c.indexOf("Qt.callLater(root._maybeAutoSelect)") < 0)
    kv("later.source.noRawTryExec", c.indexOf("Qt.callLater(() => root._scanTryExec())") < 0)

    // LNC-12: queued zone intents.
    kv("time.source.queue", /property var _timePendingZones/.test(c)
      && b.timeAsk.indexOf("_timePendingZones") >= 0)
    kv("time.source.drain", b.timeDrain !== ""
      && b.timeExit.indexOf("_drainTimeQueue") >= 0)
    kv("time.source.found", b.timeAsk !== "" && b.timeExit !== "")

    // LNC-12: a throwing send must go through the handle's finish().
    const sendAt = b.net.indexOf("xhr.send()")
    const tail = sendAt >= 0 ? b.net.slice(sendAt) : ""
    kv("net.source.sendCatch", /catch \(e\) \{ finish\(""\) \}/.test(tail))
    kv("net.source.noDirectSettle", tail.indexOf("catch (e) { root._settleNet") < 0)

    // LNC-12: the collector verdicts are read only from the run that exited.
    kv("collector.source.tryExec", b.tryExec.indexOf("tryExecOut.text") >= 0
      && /onExited: root\._onTryExecScanned\(\)/.test(c))
    kv("collector.source.bin", b.binScan.indexOf("binOut.text") >= 0
      && /onExited: root\._onBinariesScanned\(\)/.test(c))
  }

  function drive() {
    root.ctl = read("features/launcher/AppLauncherController.qml")
    root.facade = read("features/launcher/AppLauncher.qml")
    const b = bodies()
    sourceFacts(b)

    // LNC-6: one scan, both dirs registered once, collectors cleared.
    if (b.discover !== "" && b.exited !== "") {
      let s = buildScan(b)
      s.discoverPlugins()
      s.proc.dirs.push("a")
      s.proc.dirs.push("b")
      s.fireExited()
      kv("scan.single.registered", s.registered.join(","))
      kv("scan.single.cleared", s.proc.dirs.length === 0)

      // A reload while the first walk runs must not register the old lines.
      // The stale exit requeues; the fresh scan starts with empty dirs.
      s = buildScan(b)
      s.discoverPlugins()
      s.proc.dirs.push("a")
      s.discoverPlugins()
      s.proc.dirs.push("b")
      s.fireExited()
      s.drainLater()
      s.proc.dirs.push("c")
      s.fireExited()
      kv("scan.overlap.registered", s.registered.join(","))
      kv("scan.overlap.log", s.registerLog.join("|"))
      kv("scan.overlap.calls", s.registerCalls)
    }

    // LNC-8: boot gate is edge-driven; a refusal gets one capped retry.
    if (b.prewarm !== "") {
      let p = buildPrewarm(b)
      p._prewarm()
      kv("prewarm.gate.pending", p._prewarmPending)
      kv("prewarm.gate.starts", p.retry.starts)
      p.bootEntrancePlayed = true
      p._prewarm()
      kv("prewarm.refuse.starts", p.retry.starts)
      kv("prewarm.refuse.count", p._prewarmRetries)
      p._prewarm()
      kv("prewarm.capped.starts", p.retry.starts)
      p.demandResult = {}
      p._prewarm()
      kv("prewarm.success.prewarmed", p._prewarmed)
      kv("prewarm.success.stops", p.retry.stops > 0)
    }

    // LNC-9: a replay while visible must re-run open() and re-take the claim.
    if (b.open !== "" && b.replay !== "") {
      const r = buildReplay(b)
      r._claimToken = null
      r.replay()
      kv("replay.visibleAtOpen", r.visibleAtOpen)
      kv("replay.claimCalls", r.claimCalls)
      kv("replay.tokenNonnull", r._claimToken !== null)
    }

    // LNC-10: a callback scheduled before teardown is retired by the guard.
    if (b.later !== "") {
      const l = buildLater(b)
      l._later(function () { l.calls++ })
      l._life.alive = false
      l.drain()
      kv("later.afterTeardown", l.calls)
    }

    // LNC-12: three zones while one probe is in flight: none may be lost.
    if (b.timeAsk !== "" && b.timeExit !== "" && b.timeDrain !== "") {
      const t = buildTime(b)
      const pending = () => t._timePendingZones.length > 0
        ? t._timePendingZones.join(",") : t._timePendingZone
      t.requestTime("A")
      kv("time.first", t.proc.zone)
      t.requestTime("B")
      kv("time.pendingAfterSecond", pending())
      t.requestTime("C")
      kv("time.pendingAfterThird", pending())
      t.fireExited()
      kv("time.afterFirst", t.proc.zone)
      t.fireExited()
      kv("time.afterSecond", t.proc.zone)
      t.fireExited()
      kv("time.sequence", t.started.join(","))
    } else {
      kv("time.first", "missing")
      kv("time.pendingAfterSecond", "missing")
      kv("time.pendingAfterThird", "missing")
      kv("time.afterFirst", "missing")
      kv("time.afterSecond", "missing")
      kv("time.sequence", "missing")
    }

    // LNC-12: a throwing send settles through handle.done, not around it.
    if (b.net !== "") {
      const n = buildNet(b)
      n.requestNet("http://x", 0)
      kv("net.settled", n.settled.join("|"))
      kv("net.live", n._netLive.filter(h => !h.done).length)
      kv("net.doneHandles", n._netLive.filter(h => h.done).length)
    } else {
      kv("net.settled", "missing")
      kv("net.live", "missing")
      kv("net.doneHandles", "missing")
    }
  }

  Component.onCompleted: {
    try {
      drive()
    } catch (e) {
      root.error = String(e && e.message ? e.message : e)
    }
    root.factsDone = true
    collectorWatchdog.start()
    collectorProc.command = ["sh", "-c", "printf first"]
    collectorProc.running = true
    root.maybeDone()
  }
}
