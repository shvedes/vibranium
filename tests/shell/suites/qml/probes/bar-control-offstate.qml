// Probe: the resident bar control answers config/IPC with no visual bar loaded.
// It imports only the control module and the pure common layer.
import QtQuick
import Quickshell
import qs.common
import qs.features.bar.control
import "common/text/IpcProtocol.js" as P

Item {
  id: probe
  width: 1
  height: 1

  function kv(key, value) { console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n")) }
  function show(key, value) { kv(key, JSON.stringify(value)) }
  function env(obj) { return P.encode(obj) }
  function call(argv) {
    const raw = IpcRouter.invoke(env({ v: 1, kind: "call", argv: argv, literalFrom: null }))
    const decoded = P.decode(raw)
    return decoded
  }
  function data(argv) {
    const r = call(argv)
    return r && r.ok ? r.data : null
  }
  function code(argv) {
    const r = call(argv)
    return r && !r.ok ? r.error.code : "ok"
  }

  Component.onCompleted: {
    try { run() } catch (e) { kv("probe.error", "" + (e && e.message ? e.message : e)) }
    console.log("##DONE##")
  }

  function run() {
    kv("control.initialized", BarControl.initialized)
    kv("control.exists", typeof BarControl)
    kv("control.noRuntime", BarControl.runtime === null)

    Settings.setOption("shell.statusbar.enabled", false)
    Settings.setOption("shell.statusbar.position", "top")
    kv("control.disabled", BarControl.enabled === false)
    kv("control.effectiveOff", BarControl.effectiveEnabled === false)

    show("ipc.status.enabled", data(["bar", "status"]).enabled)
    show("ipc.status.effective", data(["bar", "status"]).effectiveEnabled)
    kv("ipc.status.outputsArray", Array.isArray(data(["bar", "status"]).outputs))
    kv("ipc.status.moduleRecord", data(["bar", "status"]).modules.length > 0)
    kv("ipc.status.outputUnloaded", data(["bar", "status"]).modules.every(m =>
      m.screens.every(s => s.loaded === false && s.visible === false && s.islandOpen === false)))

    // A disabled slot keeps its zone place and is reported as disabled.
    kv("layout.hasZones", ["left", "center", "right", "disabled"].every(k =>
      Array.isArray(data(["bar", "layout", "get"])[k])))
    const raw = Settings.value("shell.statusbar.layout")
    kv("layout.readWrite", code(["bar", "layout", "set", JSON.stringify(raw)]))

    // Transient hide: `show` while disabled clears the override.
    kv("hide.set", code(["bar", "hide"]))
    kv("hide.state", data(["bar", "status"]).hidden)
    kv("show.clear", code(["bar", "show"]))
    kv("show.state", data(["bar", "status"]).hidden)

    // Live operations report unavailable instead of creating UI.
    kv("island.unavailable", code(["bar", "module", "clock", "island", "is-open"]))
    kv("trigger.unavailable", code(["bar", "module", "nowPlaying", "trigger", "flashTrack"]))

    kv("module.status", code(["bar", "module", "clock", "status"]))
    kv("opt.get", code(["bar", "module", "clock", "opt", "Seconds"]))
    kv("ping", data(["bar", "ping"]))
  }
}
