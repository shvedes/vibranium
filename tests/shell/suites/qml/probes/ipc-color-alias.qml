// Probe: the top-level colorPicker target and `bar colorPicker` reach one
// owner method. The stub owner counts calls instead of opening a picker, so
// the probe never claims a screen or a SurfaceClaim seat.
import QtQuick
import Quickshell
import qs.common
import "common/text/IpcProtocol.js" as P
import "common/text/IpcCatalog.js" as C

Item {
  id: probe
  width: 1
  height: 1

  property int pickCalls: 0
  property int closeCalls: 0
  property int statusCalls: 0

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function show(key, value) { kv(key, JSON.stringify(value === undefined ? null : value)) }
  function env(obj) { return P.encode(obj) }
  function data(text) {
    var r = P.decode(text)
    return r && r.ok ? r.data : null
  }
  function invoke(argv) {
    return data(IpcRouter.invoke(env({ v: 1, kind: "call", argv: argv, literalFrom: null })))
  }
  function frame(value) { return { v: 1, ok: true, data: value } }
  function pick() { probe.pickCalls++; return frame({ state: "accepted" }) }
  function close() { probe.closeCalls++; return frame({ state: "unchanged" }) }
  function status() {
    probe.statusCalls++
    return frame({ available: true, picking: (probe.pickCalls > probe.closeCalls), screen: "HDMI-A-1" })
  }

  Component.onCompleted: {
    try { run() } catch (e) { kv("probe.error", "" + (e && e.message ? e.message : e)) }
    console.log("##DONE##")
  }

  function run() {
    var owner = ({ tag: "probe.colorPicker" })
    kv("register.alias", IpcRouter.register("colorPicker", owner, {
      "colorPicker.pick": function () { return probe.pick() },
      "colorPicker.close": function () { return probe.close() },
      "colorPicker.status": function () { return probe.status() },
      "colorPicker.ping": function () { return "pong" }
    }))

    show("alias.pick", invoke(["colorPicker", "pick"]))
    show("alias.close", invoke(["colorPicker", "close"]))
    show("alias.status", invoke(["colorPicker", "status"]))
    kv("calls.pick", probe.pickCalls)
    kv("calls.close", probe.closeCalls)
    kv("calls.status", probe.statusCalls)

    var rootHelp = data(IpcRouter.describe(env({ v: 1, kind: "help", path: ["colorPicker"] })))
    show("help.commands", rootHelp.items.map(function (i) { return i.usage }))
    kv("help.examples", rootHelp.meta.examples.length)
    var index = data(IpcRouter.describe(env({ v: 1, kind: "index" })))
    var entry = index.items.filter(function (i) { return i.id === "colorPicker" })[0]
    kv("index.target", !!entry)
    show("index.literals", entry ? entry.literals : [])
    var bar = C.findTarget("bar")
    kv("bar.deepGone", C.findRow("bar.colorPicker.pick") === null)
    kv("bar.branchGone", !bar.rows.some(function (r) {
      return r.id === "bar.colorPicker"
    }))
    kv("result.gone", C.findRow("colorPicker.result") === null)

    kv("unregister.alias", IpcRouter.unregister("colorPicker", owner))
    kv("probe.complete", true)
  }
}
