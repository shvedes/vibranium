// Probe: the systemUpdates rows in the real IpcRouter, headless. The owner is
// a plain JS object; dumps return canned JSON tokens, and no process, fetch
// or package update is started.
import QtQuick
import Quickshell
import qs.common
import "common/text/IpcProtocol.js" as P

Item {
  id: probe
  width: 1
  height: 1

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function show(key, value) { kv(key, JSON.stringify(value)) }
  function env(obj) { return P.encode(obj) }
  function code(text) {
    var r = P.decode(text)
    return r && !r.ok ? r.error.code : "ok"
  }
  function data(text) {
    var r = P.decode(text)
    return r && r.ok ? r.data : null
  }
  function invoke(argv) {
    return IpcRouter.invoke(env({ v: 1, kind: "call", argv: argv, literalFrom: null }))
  }
  function help(path) {
    return data(IpcRouter.describe(env({ v: 1, kind: "help", path: path })))
  }
  function frame(value) { return { v: 1, ok: true, data: value } }

  property var _updateArgs: null

  readonly property var official: ({
    name: "coreutils", current: "9.1", candidate: "9.4-1",
    repository: "core", size: "4.0 MiB", source: "official"
  })
  readonly property var aur: ({
    name: "artcraft-launcher-bin", current: "1.0", candidate: "2.0",
    repository: "aur", size: "1.2 MiB", source: "aur"
  })

  Component.onCompleted: {
    try { run() } catch (e) { kv("probe.error", "" + (e && e.message ? e.message : e)) }
    console.log("##DONE##")
  }

  function run() {
    var owner = ({ tag: "probe.systemUpdates" })
    var map = {
      "systemUpdates.refresh": function () { return frame({ state: "accepted" }) },
      "systemUpdates.update": function (a, c) {
        probe._updateArgs = { mode: c.tokens.mode, packages: a.packages, raw: c.tokens.packages }
        return "ok"
      },
      "systemUpdates.dump": function () { return JSON.stringify([probe.official, probe.aur]) },
      "systemUpdates.dump.all": function () { return JSON.stringify([probe.official, probe.aur]) },
      "systemUpdates.dump.aur": function () { return JSON.stringify([probe.aur]) },
      "systemUpdates.status": function () { return frame({ state: "ready", count: 2 }) },
      "systemUpdates.ping": function () { return frame("pong") }
    }
    kv("register", IpcRouter.register("systemUpdates", owner, map))

    kv("refresh", code(invoke(["systemUpdates", "refresh"])))
    show("dump.all", data(invoke(["systemUpdates", "dump"])))
    show("dump.explicitAll", data(invoke(["systemUpdates", "dump", "all"])))
    show("dump.aur", data(invoke(["systemUpdates", "dump", "aur"])))
    show("dump.format", P.decode(invoke(["systemUpdates", "dump", "aur"])).format)

    kv("badJsonToken", code(invoke(["systemUpdates", "update", "aur", "artcraft-launcher-bin"])))
    kv("wrongVerb", code(invoke(["systemUpdates", "nope"])))
    kv("wrongDump", code(invoke(["systemUpdates", "dump", "other"])))
    var wrongDump = P.decode(invoke(["systemUpdates", "dump", "other"]))
    kv("wrongDump.format", wrongDump && wrongDump.ok && wrongDump.format ? wrongDump.format.kind : "")
    kv("wrongDump.usage", wrongDump && wrongDump.ok ? wrongDump.data.usage : "")
    kv("update.reply", code(invoke(["systemUpdates", "update", "aur", '["artcraft-launcher-bin"]'])))
    show("update.jsonArray", probe._updateArgs)
    kv("update.emptyReply", code(invoke(["systemUpdates", "update", "repo", ""])))
    show("update.emptyList", probe._updateArgs)

    var leaf = help(["systemUpdates", "update"])
    var jsonArg = leaf.meta.arguments.filter(function (a) { return a.type === "json" })[0]
    kv("help.argSummary", jsonArg && jsonArg.summary)
    kv("help.example", String(leaf.meta.examples).indexOf('["artcraft-launcher-bin"]') >= 0)
    var root = help(["systemUpdates"])
    kv("help.genericDump", root.items.some(function (i) { return i.usage === "dump [<BUCKET>]" }))
    var bucket = help(["systemUpdates", "dump"])
    kv("help.dumps", ["dump", "all", "aur"].every(function (u) {
      return bucket.items.some(function (i) { return i.usage === u })
    }))

    kv("unregister", IpcRouter.unregister("systemUpdates", owner))
    kv("probe.complete", true)
  }
}
