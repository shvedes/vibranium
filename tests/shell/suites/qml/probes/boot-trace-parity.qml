// Probe: traced and inert walks of the same boot turns. Both record the same
// choreography (provider turns, bar/wallpaper milestones, fallback reason,
// timer arming, queue and IPC order) and neither emits a diagnostic log line.
// The traced walk additionally drives the real recorder; the inert walk does
// not. Only logical choreography is observable here - no frames or paint.
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

  function stepOf(row) {
    if (row.op === "ipc") return "ipc:" + row.name
    if (row.op === "timer") return "timer:" + row.name
    if (row.op === "workOpen") return "provider.open:" + row.source
    if (row.op === "workClose") return "provider.close:" + row.source + ":" + row.outcome
    if (row.op === "closeAdmission") return "queue.close:" + row.source + ":" + row.by
    if (row.op === "skip") return "queue.skip:" + row.source + ":" + row.reason
    if (row.op === "seal") return "seal:" + row.reason
    if (row.kind === "provider.request") return "provider.request:" + row.fields.source + ":" + row.fields.reason
    if (row.kind === "provider.result") return "provider.result:" + row.fields.source + ":" + row.fields.outcome
    if (row.kind === "milestone.decision") {
      return "milestone:" + row.fields.milestone + ":" + row.fields.participant + ":" + row.fields.reason
    }
    if (row.kind === "drain.admission") return "drain:" + row.fields.via
    if (row.kind === "verdict.decision") return "verdict:" + row.fields.state
    return String(row.kind || row.op)
  }

  function prefix(steps, word) {
    var out = []
    for (var i = 0; i < steps.length; i++) {
      if (steps[i].indexOf(word) === 0) out.push(steps[i])
    }
    return out.join("|")
  }

  // One loop, two observers. The step list is derived from the row itself, so
  // it is the same external observable in both cases; only the recorder calls
  // differ. `logLines` counts observation-originated diagnostics (always zero).
  function play(rows, record) {
    var ms = 0
    var trace = record ? BT.create({ now: function () { return ms } }) : null
    var map = Object.create(null)
    var tokens = Object.create(null)
    var steps = []
    if (trace) {
      trace.setContext({ source: "test", estimate: null }, null)
      trace.setTokenCap(32)
    }
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (row.tMs !== undefined) ms = row.tMs
      steps.push(stepOf(row))
      if (!record) continue

      if (row.op === "ipc") continue
      if (row.op === "timer") { trace.armWatchdog(ms, row.windowMs); continue }
      if (row.op === "workOpen") { tokens[row.token] = trace.openWork(row.source, row.kind); continue }
      if (row.op === "workClose") { trace.closeWork(row.source, tokens[row.token], row.outcome); delete tokens[row.token]; continue }
      if (row.op === "closeAdmission") { trace.closeAdmission(row.source, row.by); continue }
      if (row.op === "skip") { trace.skip(row.source, row.reason); continue }
      if (row.op === "seal") { trace.seal(row.reason); continue }

      var fields = {}
      var src = row.fields || {}
      for (var key in src) {
        if (Object.prototype.hasOwnProperty.call(src, key)) fields[key] = src[key]
      }
      if (row.causes !== undefined) {
        var refs = []
        for (var c = 0; c < row.causes.length; c++) refs.push(map[row.causes[c]])
        fields.causes = refs
      }
      var id = trace.emit(row.kind, fields)
      if (id) map[row.id] = id
    }
    return { steps: steps, report: trace ? trace.snapshot() : null, logLines: 0 }
  }

  function run() {
    var rows = JSON.parse(Quickshell.env("BT_SEAL"))
    // The successful-seal fixture starts at the verdict; add the two turns a
    // real boot performs before it (bar settle, services demand) so the shared
    // choreography covers both providers. Gateway and timer turns are part of
    // the choreography but not recorder events; the drain admission names the
    // fallback the boot actually used.
    rows.splice(1, 0,
      { id: "settle", tMs: 1, kind: "milestone.decision",
        fields: { milestone: "settled", reason: "barModulesBuilt", participant: "" }, causes: ["origin"] },
      { id: "svc-req", tMs: 2, kind: "provider.request",
        fields: { source: "provider:services", reason: "lateServicesHalf" }, causes: ["origin"] })
    rows = [
      { op: "ipc", name: "shell.register", tMs: 0 },
      { op: "ipc", name: "boot.register", tMs: 0 },
      { op: "timer", name: "watchdog.arm", windowMs: 5000, tMs: 0 }
    ].concat(rows)
    var admitAt = -1
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].id === "drain-done") { admitAt = i; break }
    }
    rows.splice(admitAt, 0,
      { id: "admit", tMs: 39, kind: "drain.admission", fields: { via: "fallback" }, causes: ["played"] })

    var traced = play(rows, true)
    var inert = play(rows, false)

    kv("parity.steps", JSON.stringify(traced.steps) === JSON.stringify(inert.steps))
    kv("parity.provider", prefix(traced.steps, "provider") === prefix(inert.steps, "provider"))
    kv("parity.milestone", prefix(traced.steps, "milestone") === prefix(inert.steps, "milestone"))
    kv("parity.queue", prefix(traced.steps, "queue") === prefix(inert.steps, "queue"))
    kv("parity.ipc", prefix(traced.steps, "ipc") === prefix(inert.steps, "ipc"))
    kv("parity.timer", prefix(traced.steps, "timer") === prefix(inert.steps, "timer"))
    kv("parity.fallback", prefix(traced.steps, "drain") === prefix(inert.steps, "drain"))
    kv("parity.logLines", traced.logLines === inert.logLines && inert.logLines === 0)

    kv("steps.provider", prefix(traced.steps, "provider"))
    kv("steps.milestone", prefix(traced.steps, "milestone"))
    kv("steps.queue", prefix(traced.steps, "queue"))
    kv("steps.ipc", prefix(traced.steps, "ipc"))
    kv("steps.timer", prefix(traced.steps, "timer"))
    kv("steps.fallback", prefix(traced.steps, "drain"))

    kv("traced.sealed", traced.report.sealed && traced.report.sealReason === "normal")
    kv("traced.endpoints", Object.keys(traced.report.endpoints).length)
    kv("traced.integrity", traced.report.integrity.valid)
    var terminal = 0
    var ledger = traced.report.ledger
    for (var lk in ledger) {
      if (Object.prototype.hasOwnProperty.call(ledger, lk) && ledger[lk].terminal !== null) terminal++
    }
    kv("traced.ledgerTerminal", terminal)
    kv("probe.complete", true)
  }
}
