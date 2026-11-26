// Probe: `app call list <APP>` and `app call <APP> help` through the real
// IpcRouter, headless. The owner is a stub; the help descriptor comes from
// AppHost's static allowlist builder, so no facade, controller or window is
// demanded to answer either spelling.
import QtQuick
import Quickshell
import qs.common
import qs.features.apps
import "common/text/IpcProtocol.js" as P

Item {
  id: probe
  width: 1
  height: 1

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function show(key, value) { kv(key, JSON.stringify(value === undefined ? null : value)) }
  function env(obj) { return P.encode(obj) }
  function data(text) {
    var r = P.decode(text)
    return r && r.ok ? r.data : null
  }
  function code(text) {
    var r = P.decode(text)
    return r && !r.ok ? r.error.code : "ok"
  }
  function help(path) {
    return data(IpcRouter.describe(env({ v: 1, kind: "help", path: path })))
  }
  function invoke(argv) {
    return IpcRouter.invoke(env({ v: 1, kind: "call", argv: argv, literalFrom: null }))
  }
  function frame(value, format) {
    return { v: 1, ok: true, data: value, format: format }
  }

  Component.onCompleted: {
    try { run() } catch (e) { kv("probe.error", "" + (e && e.message ? e.message : e)) }
    console.log("##DONE##")
  }

  property var _dispatch: ({})

  function run() {
    var owner = ({ tag: "probe.app" })
    var map = {
      "app.call.list": function (a) {
        var h = AppHost._callHelp(a.ID)
        return h ? frame(h, { kind: "help" }) : { v: 1, ok: false, error: { code: "not-found", message: "unknown app" } }
      },
      "app.call.audioMixer.openTab": function (a) {
        probe._dispatch.openTab = { TAB: a.TAB }
        return frame({ TAB: a.TAB })
      },
      "app.call.audioMixer.selectTab": function (a) {
        probe._dispatch.selectTab = { TAB: a.TAB }
        return frame({ TAB: a.TAB })
      },
      "app.call.imageViewer.openPath": function (a) {
        probe._dispatch.openPath = { PATH: a.PATH }
        return frame({ PATH: a.PATH })
      },
      "app.call.audioMixer.status": function () { return frame({ tab: null }) },
      "app.call.imageViewer.status": function () { return frame({ open: false }) },
      "app.status": function () { return frame({ ready: true }) },
      "app.ping": function () { return frame("pong") }
    }
    kv("register", IpcRouter.register("app", owner, map, AppHost._describeApp))

    var root = help(["app"])
    show("root.commands", root.items.map(function (i) { return i.usage }))
    kv("root.noDeep", root.items.every(function (i) {
      return i.id.indexOf("app.call.") !== 0 || i.id === "app.call"
    }))
    kv("root.genericCall", root.items.some(function (i) {
      return i.id === "app.call" && i.usage === "call [<ID>]"
    }))
    var callBranch = help(["app", "call"])
    show("call.commands", callBranch.items.map(function (i) { return i.usage }))

    var mixer = help(["app", "call", "audioMixer"])
    kv("mixer.usage", mixer.meta.usage)
    kv("mixer.summary", mixer.meta.summary)
    show("mixer.commands", mixer.items.map(function (i) { return i.id }))
    show("mixer.usages", mixer.items.map(function (i) { return i.usage }))
    show("mixer.examples", mixer.meta.examples)
    kv("mixer.tabIds", JSON.stringify(mixer.items[0].arguments[0].values))
    kv("mixer.tabSummary", mixer.items[0].arguments[0].summary)
    kv("mixer.openTabExample", mixer.meta.examples.some(function (e) {
      return e === "vb-shell app call audioMixer openTab configuration"
    }))
    kv("mixer.selectTabExample", mixer.meta.examples.some(function (e) {
      return e === "vb-shell app call audioMixer selectTab devices"
    }))
    show("mixer.notes", mixer.meta.notes)

    var viewer = help(["app", "call", "imageViewer"])
    kv("viewer.usage", viewer.meta.usage)
    show("viewer.commands", viewer.items.map(function (i) { return i.id }))
    kv("viewer.openPathExample", viewer.meta.examples.some(function (e) {
      return e === "vb-shell app call imageViewer openPath /home/user/Pictures/my-image.png"
    }))

    var unknown = help(["app", "call", "nope"])
    kv("unknown.noFabricatedPage", unknown.items.length === 0)

    var reply = invoke(["app", "call", "list", "audioMixer"])
    var r = P.decode(reply)
    kv("list.ok", r && r.ok)
    kv("list.format", r && r.format && r.format.kind)
    show("list.dataCommands", r && r.data && r.data.commands.map(function (c) { return c.id }))
    kv("list.sameAsHelp", JSON.stringify(r && r.data) === JSON.stringify({
      usage: mixer.meta.usage, summary: mixer.meta.summary,
      arguments: mixer.meta.arguments, options: mixer.meta.options,
      commands: mixer.items, notes: mixer.meta.notes, examples: mixer.meta.examples
    }))
    kv("list.unknown", code(invoke(["app", "call", "list", "nope"])))

    show("dispatch.openTab", data(invoke(["app", "call", "audioMixer", "openTab", "graph"])))
    show("dispatch.openTab.args", probe._dispatch.openTab)
    show("dispatch.selectTab", data(invoke(["app", "call", "audioMixer", "selectTab", "devices"])))
    show("dispatch.selectTab.args", probe._dispatch.selectTab)
    show("dispatch.openPath", data(invoke(["app", "call", "imageViewer", "openPath", "/tmp/a.png"])))
    show("dispatch.openPath.args", probe._dispatch.openPath)

    var index = data(IpcRouter.describe(env({ v: 1, kind: "index" })))
    var entry = index.items.filter(function (i) { return i.id === "app" })[0]
    kv("index.genericCall", entry.literals.indexOf("call") >= 0)
    kv("index.noDeep", entry.literals.every(function (s) {
      return s.indexOf("openTab") < 0 && s.indexOf("openPath") < 0
    }))

    kv("unregister", IpcRouter.unregister("app", owner))
    kv("probe.complete", true)
  }
}
