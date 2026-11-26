// Probe: a known target or branch stops at a real canonical help page, not
// an error. Genuinely unknown words and bad typed tokens keep their errors.
// No owner is registered: the descriptor comes from the catalog and any
// static describeInstance table, so no view opens and no plugin code loads.
import QtQuick
import Quickshell
import qs.common
import qs.features.apps
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
  function frame(argv) {
    return P.decode(IpcRouter.invoke(P.encode({
      v: 1, kind: "call", argv: argv, literalFrom: null
    })))
  }

  Component.onCompleted: {
    try { run() } catch (e) { kv("probe.error", "" + (e && e.message ? e.message : e)) }
    console.log("##DONE##")
  }

  function run() {
    // Static describe callbacks: the same presentation seams the real owners
    // register. No owner closure is needed because every case stops early.
    var owner = ({ tag: "probe.usage-hint" })
    kv("register.app", IpcRouter.register("app", owner, {}, AppHost._describeApp))
    kv("register.launcher", IpcRouter.register("appLauncher", owner, {}, function (rest) {
      if (!rest || rest[0] !== "plugin") return null
      const id = rest[1] === "command" ? rest[2]
        : rest.length === 2 ? rest[1] : null
      if (!id) return null
      return LL.pluginHelpPage(id)
    }))

    var cases = [
      ["app.call", ["app", "call", "audioMixer"]],
      ["bar.module", ["bar", "module", "volume"]],
      ["launcher.plugin", ["appLauncher", "plugin", "command", "calc"]],
      ["menu.item", ["menu", "item", "r1.1.1.2"]],
      ["updates.dump", ["systemUpdates", "dump", "bogus"]],
      ["bare.app", ["app"]],
      ["bare.bar", ["bar"]],
      ["bare.colorPicker", ["colorPicker"]],
      ["genuine.unknown", ["app", "nonsense"]],
      ["bad.id", ["app", "toggle", "audioMicer"]],
      ["bad.tab", ["app", "call", "audioMixer", "openTab", "nope"]],
      ["typed.bad", ["settings", "set", "key", "not-json"]]
    ]
    for (var i = 0; i < cases.length; i++) {
      var key = cases[i][0]
      var r = frame(cases[i][1])
      kv(key + ".ok", !!(r && r.ok))
      kv(key + ".code", r && !r.ok ? r.error.code : "ok")
      kv(key + ".message", r && !r.ok ? r.error.message : "")
      kv(key + ".format", r && r.ok && r.format ? r.format.kind : "")
      if (r && r.ok && r.data) {
        kv(key + ".usage", r.data.usage)
        kv(key + ".commands", (r.data.commands || []).length)
        kv(key + ".examples", (r.data.examples || []).length)
        kv(key + ".notes", (r.data.notes || []).length)
      }
    }
    kv("unregister.app", IpcRouter.unregister("app", owner))
    kv("unregister.launcher", IpcRouter.unregister("appLauncher", owner))
    kv("probe.complete", true)
  }
}
