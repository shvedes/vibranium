// Probe: `appLauncher plugin <ID> help` through the real IpcRouter, headless.
// The owner is a plain JS object; the describe callback is the same static
// LauncherLib table AppLauncher registers. No plugin code, controller or
// window is constructed.
import QtQuick
import Quickshell
import qs.common
import "common/text/IpcProtocol.js" as P
import "features/launcher/LauncherLib.js" as LL

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
  function message(text) {
    var r = P.decode(text)
    return r && !r.ok ? r.error.message : ""
  }
  function format(text) {
    var r = P.decode(text)
    return r && r.ok && r.format ? r.format.kind : ""
  }
  function data(text) {
    var r = P.decode(text)
    return r && r.ok ? r.data : null
  }
  function help(path) {
    return data(IpcRouter.describe(env({ v: 1, kind: "help", path: path })))
  }
  function invoke(argv) {
    return IpcRouter.invoke(env({ v: 1, kind: "call", argv: argv, literalFrom: null }))
  }
  function frame(value) { return { v: 1, ok: true, data: value } }
  function describePlugin(rest) {
    if (!rest || rest[0] !== "plugin") return null
    const id = rest[1] === "command" ? rest[2]
      : rest.length === 2 ? rest[1] : null
    if (!id) return null
    return LL.pluginHelpPage(id)
  }

  Component.onCompleted: {
    try { run() } catch (e) { kv("probe.error", "" + (e && e.message ? e.message : e)) }
    console.log("##DONE##")
  }

  function run() {
    var owner = ({ tag: "probe.appLauncher" })
    var map = {
      "appLauncher.status": function () { return frame({ ready: true }) },
      "appLauncher.ping": function () { return { v: 1, ok: true, data: "pong", format: { kind: "text" } } },
      "appLauncher.plugin.command.calc.eval": function (a) { return frame({ EXPR: a.EXPR }) },
      "appLauncher.plugin.command.unit.convert": function (a) { return frame({ QUERY: a.QUERY }) },
      "appLauncher.plugin.command.constants.lookup": function (a) { return frame({ QUERY: a.QUERY }) },
      "appLauncher.plugin.command.color.parse": function (a) { return frame({ COLOR: a.COLOR }) },
      "appLauncher.plugin.command.time.lookup": function (a) { return frame({ ZONE_OR_CITY: a.ZONE_OR_CITY }) },
      "appLauncher.plugin.command.time.convert": function (a) { return frame({ QUERY: a.QUERY }) },
      "appLauncher.plugin.command.fx.convert": function (a) { return frame({ QUERY: a.QUERY }) },
      "appLauncher.plugin.command.websearch.url": function (a) { return frame({ QUERY: a.QUERY }) }
    }
    kv("register", IpcRouter.register("appLauncher", owner, map, describePlugin))
    var ping = P.decode(invoke(["appLauncher", "ping"]))
    kv("ping.data", ping.data)
    kv("ping.format", ping.format.kind)
    show("status.data", data(invoke(["appLauncher", "status"])))

    var rootHelp = help(["appLauncher"])
    kv("root.noRescan", !rootHelp.items.some(function (i) { return i.id === "appLauncher.rescan" }))
    kv("root.noDiscover", !rootHelp.items.some(function (i) {
      return i.id === "appLauncher.plugin.discover"
    }))
    kv("root.noChildPlugins", rootHelp.items.filter(function (i) {
      return i.id.indexOf("appLauncher.plugin.") === 0
        && i.id !== "appLauncher.plugin.command"
    }).length === 0)
    kv("root.genericPlugin", rootHelp.items.some(function (i) {
      return i.id === "appLauncher.plugin" && i.usage === "plugin"
    }))

    var pluginBranch = help(["appLauncher", "plugin", "command"])
    show("branch.commands", pluginBranch.items.map(function (i) { return i.usage }))

    var colorHelp = help(["appLauncher", "plugin", "command", "color"])
    kv("color.usage", colorHelp.meta.usage)
    kv("color.summary", colorHelp.meta.summary)
    show("color.commands", colorHelp.items.map(function (i) { return i.id }))
    kv("color.isolated", colorHelp.items.length === 1
      && colorHelp.items[0].id === "appLauncher.plugin.command.color.parse")
    kv("color.arg", JSON.stringify(colorHelp.items[0].arguments))
    kv("color.examples", JSON.stringify(colorHelp.items[0].examples))
    kv("color.notes", JSON.stringify(colorHelp.meta.notes))
    kv("color.examplesPage", JSON.stringify(colorHelp.meta.examples))

    var calcHelp = help(["appLauncher", "plugin", "command", "calc"])
    show("calc.commands", calcHelp.items.map(function (i) { return i.id }))
    kv("calc.arg", JSON.stringify(calcHelp.items[0].arguments))
    var timeHelp = help(["appLauncher", "plugin", "command", "time"])
    kv("time.commands", timeHelp.items.length)
    kv("time.lookupArg", JSON.stringify(timeHelp.items[0].arguments))
    var binaryHelp = help(["appLauncher", "plugin", "command", "binary"])
    kv("binary.commands", binaryHelp.items.length)
    kv("binary.notes", JSON.stringify(binaryHelp.meta.notes))

    var unknown = help(["appLauncher", "plugin", "command", "nope"])
    kv("unknown.commands", unknown.items.length)
    kv("unknown.noFabricatedPage", unknown.meta.usage === "vb-shell appLauncher plugin"
      || unknown.meta.usage === "vb-shell appLauncher")

    var index = data(IpcRouter.describe(env({ v: 1, kind: "index" })))
    var entry = index.items.filter(function (i) { return i.id === "appLauncher" })[0]
    show("index.literals", entry.literals)
    kv("index.genericPlugin", entry.literals.indexOf("plugin") >= 0)
    kv("index.noChildPlugins", entry.literals.filter(function (s) {
      return s === "eval" || s === "convert"
        || s === "parse" || s === "lookup" || s === "url"
    }).length === 0)

    show("dispatch.calc", data(invoke(["appLauncher", "plugin", "command", "calc", "eval", "5+5"])))
    show("dispatch.websearch", data(invoke(["appLauncher", "plugin", "command", "websearch", "url", "shell ipc"])))
    show("dispatch.unit", data(invoke(["appLauncher", "plugin", "command", "unit", "convert", "1 light years"])))
    show("dispatch.time", data(invoke(["appLauncher", "plugin", "command", "time", "lookup", "Berlin"])))
    kv("dispatch.wrongPlugin", code(invoke(["appLauncher", "plugin", "command", "color", "eval", "5+5"])))
    kv("dispatch.wrongPlugin.message", message(invoke(["appLauncher", "plugin", "command", "color", "eval", "5+5"])))
    kv("dispatch.wrongPlugin.format", format(invoke(["appLauncher", "plugin", "command", "color", "eval", "5+5"])))
    kv("dispatch.wrongVerb", code(invoke(["appLauncher", "plugin", "command", "calc", "parse", "5+5"])))
    kv("dispatch.genericNotCallable", code(invoke(["appLauncher", "plugin", "calc"])))

    kv("unregister", IpcRouter.unregister("appLauncher", owner))
    kv("probe.complete", true)
  }
}
