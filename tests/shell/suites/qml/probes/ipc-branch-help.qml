// Probe: every nested branch gets its own columnized help page from the
// catalog, without an owner, a controller demand or a view. Dynamic instances
// stay out of parent pages; the branches below use only static metadata.
import QtQuick
import Quickshell
import qs.common
import "common/text/IpcProtocol.js" as P
import "common/text/IpcCatalog.js" as C

Item {
  id: probe
  width: 1
  height: 1

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function show(key, value) { kv(key, JSON.stringify(value)) }
  function env(obj) { return P.encode(obj) }
  function help(path) {
    var r = P.decode(IpcRouter.describe(env({ v: 1, kind: "help", path: path })))
    return r && r.ok ? r.data : null
  }

  Component.onCompleted: {
    try { run() } catch (e) { kv("probe.error", "" + (e && e.message ? e.message : e)) }
    console.log("##DONE##")
  }

  function run() {
    // No registration at all: branch pages are presentation over the catalog.
    var violations = []
    var ids = C.targetIds()
    for (var t = 0; t < ids.length; t++) {
      var root = help([ids[t]])
      if (!root) { violations.push(ids[t] + ":no-page"); continue }
      for (var i = 0; i < root.items.length; i++) {
        var row = C.findRow(root.items[i].id)
        if (row && row.parentHidden === true) violations.push(ids[t] + ":" + row.id)
      }
    }
    show("flat.violations", violations)

    var paths = [
      ["settings", "fonts"],
      ["systemUpdates", "dump"],
      ["printers", "job"],
      ["hyprlandSettings", "set"],
      ["audio", "volume"],
      ["audio", "microphone"],
      ["audio", "sink"],
      ["audio", "source"],
      ["audio", "stream"],
      ["audio", "stream", "n1.2"],
      ["appLauncher", "history"],
      ["bar", "position"],
      ["bar", "layout"],
      ["bar", "module"],
      ["bar", "module", "volume"],
      ["bar", "module", "volume", "island"],
      ["bar", "module", "weather", "opt"],
      ["bar", "module", "weather", "trigger"],
      ["notifications", "dnd"],
      ["notifications", "dismiss"],
      ["menu", "search"],
      ["menu", "item"],
      ["menu", "item", "r1.1.1.2", "confirm"],
      ["menu", "item", "r1.1.1.2", "flow"],
      ["menu", "item", "r1.1.1.2", "info"],
      ["menu", "item", "r1.1.1.2", "step"],
      ["appLauncher", "plugin"],
      ["clipboard", "copy"]
    ]
    var branches = {}
    for (var p = 0; p < paths.length; p++) {
      var key = paths[p].join(" ")
      var page = help(paths[p])
      branches[key] = page ? {
        usage: page.meta.usage,
        summary: page.meta.summary,
        commands: page.items.map(function (i) { return i.usage }),
        examples: page.meta.examples.length,
        noted: page.meta.notes.length
      } : null
    }
    show("branches", branches)

    var barRoot = help(["bar"])
    show("bar.rootCommands", barRoot.items.map(function (i) { return i.usage }))

    var index = P.decode(IpcRouter.describe(env({ v: 1, kind: "index" }))).data
    var bar = index.items.filter(function (i) { return i.id === "bar" })[0]
    show("index.bar", bar.literals)
    var menu = index.items.filter(function (i) { return i.id === "menu" })[0]
    show("index.menu", menu.literals)

    kv("probe.complete", true)
  }
}
