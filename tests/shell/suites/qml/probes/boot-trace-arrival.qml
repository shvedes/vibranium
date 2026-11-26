// Probe: the real BootTrace recorder inside the QML engine. Both join arrival
// orders, deferred handoff vs skip, the watchdog deadline (including a stalled
// GUI turn), and the earlier-seal race. Clock and fixture semantics match
// specs/chat/fixture-driver.cjs; the rows come from the copied fixtures.
import QtQuick
import Quickshell
import "boot/BootTrace.js" as BT

Item {
  id: root

  property string error: ""

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  Component.onCompleted: {
    try {
      run()
    } catch (e) {
      kv("probe.error", String((e && e.message) || e))
    }
    console.log("##DONE##")
  }

  function selectedKind(report, chain) {
    var c = report.chains[chain]
    if (!c) return null
    for (var i = 0; i < c.chain.length; i++) {
      if (c.chain[i].kind === "drain.admission") {
        return i > 0 ? c.chain[i - 1].kind : null
      }
    }
    return null
  }

  function drive(text) {
    var rows = JSON.parse(text)
    var ms = 0
    var trace = BT.create({ now: function () { return ms } })
    var map = Object.create(null)
    var tokens = Object.create(null)
    trace.setContext({ source: "test", estimate: null }, null)
    trace.setTokenCap(32)
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (row.tMs !== undefined) ms = row.tMs
      if (row.op === "clock") { ms = row.toMs; continue }
      if (row.op === "workOpen") { tokens[row.token] = trace.openWork(row.source, row.kind); continue }
      if (row.op === "workClose") { trace.closeWork(row.source, tokens[row.token], row.outcome); delete tokens[row.token]; continue }
      if (row.op === "closeAdmission") { trace.closeAdmission(row.source, row.by); continue }
      if (row.op === "skip") { trace.skip(row.source, row.reason); continue }
      if (row.op === "alreadyResolved") { trace.alreadyResolved(row.milestone, row.participant || ""); continue }
      if (row.op === "armWatchdog") { trace.armWatchdog(ms, row.windowMs); continue }
      if (row.op === "seal") { trace.seal(row.reason); continue }
      if (row.op === "injectLoss") { trace.injectLoss(row.target, map); continue }

      var fields = {}
      var src = row.fields || {}
      for (var key in src) {
        if (Object.prototype.hasOwnProperty.call(src, key)) fields[key] = src[key]
      }
      if (row.causes !== undefined || row.faultRaw !== undefined) {
        var refs = []
        if (row.faultRaw !== undefined) refs = row.faultRaw
        else {
          for (var c = 0; c < row.causes.length; c++) refs.push(map[row.causes[c]])
        }
        fields.causes = refs
      }
      var id = trace.emit(row.kind, fields)
      if (id) map[row.id] = id
    }
    return {
      trace: trace,
      report: trace.snapshot(),
      map: map,
      setMs: function (v) { ms = v },
      getMs: function () { return ms }
    }
  }

  function kinds(list) {
    var out = []
    for (var i = 0; i < list.length; i++) out.push(list[i].kind)
    return out.sort().join(",")
  }

  function run() {
    // --- both arrival orders ------------------------------------------------
    var f = drive(Quickshell.env("BT_JOIN_FEATURES"))
    kv("features.chain", f.report.chains.drainComplete.status)
    kv("features.predecessor", selectedKind(f.report, "drainComplete"))
    kv("features.parallel", kinds(f.report.chains.drainComplete.parallel))
    kv("features.endpoint", f.report.endpoints.drainComplete)

    var p = drive(Quickshell.env("BT_JOIN_PLAYED"))
    kv("played.chain", p.report.chains.drainComplete.status)
    kv("played.predecessor", selectedKind(p.report, "drainComplete"))
    kv("played.parallel", kinds(p.report.chains.drainComplete.parallel))
    kv("played.endpoint", p.report.endpoints.drainComplete)

    // --- deferred handoff vs skip ------------------------------------------
    var sealRows = JSON.parse(Quickshell.env("BT_SEAL"))
    var handoffRows = []
    for (var i = 0; i < sealRows.length; i++) {
      var row = sealRows[i]
      if (row.op === "skip" && row.source === "queue:deferred") {
        handoffRows.push({ op: "workOpen", token: "def", source: "queue:deferred", kind: "request", tMs: row.tMs })
        handoffRows.push({ op: "workClose", token: "def", source: "queue:deferred", outcome: "adopted", tMs: row.tMs })
        handoffRows.push({ op: "closeAdmission", source: "queue:deferred", by: "adopted", tMs: row.tMs })
      } else {
        handoffRows.push(row)
      }
    }
    var skipped = drive(Quickshell.env("BT_SEAL"))
    var handed = drive(JSON.stringify(handoffRows))
    kv("deferred.skipTerminal", skipped.report.ledger["queue:deferred"].terminal)
    kv("deferred.handoffTerminal", handed.report.ledger["queue:deferred"].terminal)
    kv("deferred.skipSealed", skipped.report.sealed && skipped.report.sealReason === "normal")
    kv("deferred.handoffSealed", handed.report.sealed && handed.report.sealReason === "normal")

    // --- watchdog: no early fire, including a stalled GUI turn --------------
    var wd = drive(JSON.stringify([
      { id: "origin", tMs: 0, kind: "boot.begin", fields: { source: "test", estimateMs: null } },
      { op: "armWatchdog", tMs: 0, windowMs: 5000 }
    ]))
    wd.setMs(4999)
    var before = JSON.stringify(wd.trace.snapshot())
    var spinUntil = Date.now() + 25
    while (Date.now() < spinUntil) { /* occupy the GUI thread briefly */ }
    kv("stall.occupiedMs", Date.now() - spinUntil + 25 >= 25)
    kv("stall.noEarlyFire", wd.trace.watchdogFired(4999))
    kv("stall.reportUnchanged", JSON.stringify(wd.trace.snapshot()) === before)
    kv("watchdog.atDeadline", wd.trace.watchdogFired(5000))
    var wr = wd.trace.snapshot()
    kv("watchdog.sealed", wr.sealed && wr.sealReason === "watchdog")

    // --- an earlier seal wins the race -------------------------------------
    var race = drive(JSON.stringify([
      { id: "origin", tMs: 0, kind: "boot.begin", fields: { source: "test", estimateMs: null } },
      { op: "armWatchdog", tMs: 0, windowMs: 5000 }
    ]))
    race.setMs(10)
    var raced = race.trace.seal("aborted")
    var racedFrozen = JSON.stringify(race.trace.snapshot())
    race.setMs(6000)
    kv("race.sealReason", raced.sealReason)
    kv("race.watchdogAfterSeal", race.trace.watchdogFired(6000))
    kv("race.reportFrozen", JSON.stringify(race.trace.snapshot()) === racedFrozen)

    kv("probe.complete", true)
  }
}
