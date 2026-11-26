// Probe: the rearranged audio and launcher verbs dispatch through the real
// IpcRouter, headless. The stub owner records the named arguments; it never
// touches PipeWire, the launcher controller or a view.
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
  function show(key, value) { kv(key, JSON.stringify(value === undefined ? null : value)) }
  function env(obj) { return P.encode(obj) }
  function call(argv) {
    var r = P.decode(IpcRouter.invoke(env({ v: 1, kind: "call", argv: argv, literalFrom: null })))
    if (!r) return { code: "invalid", data: null }
    return { code: r.ok ? "ok" : r.error.code, data: r.ok ? r.data : null }
  }
  function frame(value) { return { v: 1, ok: true, data: value } }
  property var _seen: ({})
  // Silent orders no longer echo their arguments, so record the call here.
  function record(key, value) {
    probe._seen[key] = value
    return frame(value)
  }

  Component.onCompleted: {
    try { run() } catch (e) { kv("probe.error", "" + (e && e.message ? e.message : e)) }
    console.log("##DONE##")
  }

  function run() {
    var owner = ({ tag: "probe.audio" })
    var audio = {
      "audio.volume.up": function (a) { return record("volume.up.args", { N: a.N || 0 }) },
      "audio.volume.down": function (a) { return record("volume.down.args", { N: a.N || 0 }) },
      "audio.volume.toggle": function () { return record("volume.toggle.args", { toggle: true }) },
      "audio.volume.set": function (a) { return record("volume.set.args", { N: a.N }) },
      "audio.volume.get": function () { return frame({ percent: 80, muted: false }) },
      "audio.microphone.up": function (a) { return record("microphone.up.args", { N: a.N || 0 }) },
      "audio.microphone.down": function (a) { return record("microphone.down.args", { N: a.N || 0 }) },
      "audio.microphone.toggle": function () { return record("microphone.toggle.args", { toggle: true }) },
      "audio.microphone.set": function (a) { return record("microphone.set.args", { N: a.N }) },
      "audio.microphone.get": function () { return frame({ percent: 60, muted: true }) },
      "audio.sink.list": function () { return frame({ list: "sink" }) },
      "audio.sink.set": function (a) { return record("sink.set.args", { ID: a.ID }) },
      "audio.source.list": function () { return frame({ list: "source" }) },
      "audio.source.set": function (a) { return record("source.set.args", { ID: a.ID }) },
      "audio.stream.list": function () { return frame({ list: "apps" }) },
      "audio.stream.route-status": function (a) { return frame({ REQUEST: a.REQUEST }) },
      "audio.status": function () { return frame({ ready: true }) },
      "audio.ping": function () { return frame("pong") }
    }
    var launcher = {
      "appLauncher.history.is-empty": function () { return frame({ empty: true }) },
      "appLauncher.history.show": function () { return frame({ show: true }) },
      "appLauncher.history.clear": function () { return record("history.clear.args", { clear: true }) },
      "appLauncher.status": function () { return frame({ ready: true }) },
      "appLauncher.ping": function () { return frame("pong") }
    }
    kv("register.audio", IpcRouter.register("audio", owner, audio))
    kv("register.launcher", IpcRouter.register("appLauncher", owner, launcher))

    var cases = [
      ["volume.up", ["audio", "volume", "up", "step", "10"]],
      ["volume.down", ["audio", "volume", "down"]],
      ["volume.toggle", ["audio", "volume", "toggle"]],
      ["volume.set", ["audio", "volume", "set", "80"]],
      ["volume.get", ["audio", "volume", "get"]],
      ["microphone.up", ["audio", "microphone", "up"]],
      ["microphone.down", ["audio", "microphone", "down"]],
      ["microphone.toggle", ["audio", "microphone", "toggle"]],
      ["microphone.set", ["audio", "microphone", "set", "60"]],
      ["microphone.get", ["audio", "microphone", "get"]],
      ["sink.list", ["audio", "sink", "list"]],
      ["sink.set", ["audio", "sink", "set", "n1.2"]],
      ["source.list", ["audio", "source", "list"]],
      ["source.set", ["audio", "source", "set", "n1.3"]],
      ["history.empty", ["appLauncher", "history", "is-empty"]],
      ["history.show", ["appLauncher", "history", "show"]],
      ["history.clear", ["appLauncher", "history", "clear"]],
      ["stream.list", ["audio", "stream", "list"]],
      ["stream.routeStatus", ["audio", "stream", "route-status", "r1.1"]]
    ]
    for (var i = 0; i < cases.length; i++) {
      var r = call(cases[i][1])
      kv(cases[i][0] + ".code", r.code)
      show(cases[i][0] + ".data", r.data)
    }
    for (var s = 0; s < Object.keys(probe._seen).length; s++) {
      var key = Object.keys(probe._seen)[s]
      show(key, probe._seen[key])
    }
    var retired = [
      ["old.volumeUp", ["audio", "volumeUp"]],
      ["old.micToggle", ["audio", "micToggle"]],
      ["old.sinks", ["audio", "sinks"]],
      ["old.apps", ["audio", "apps"]],
      ["old.routeStatus", ["audio", "routeStatus", "r1.1"]],
      ["old.setDefault", ["audio", "setDefault", "sink", "n1.2"]],
      ["old.hasHistory", ["appLauncher", "hasHistory"]],
      ["old.rescanApps", ["appLauncher", "rescanApps"]]
    ]
    for (var j = 0; j < retired.length; j++) {
      kv(retired[j][0], call(retired[j][1]).code)
    }

    kv("unregister.audio", IpcRouter.unregister("audio", owner))
    kv("unregister.launcher", IpcRouter.unregister("appLauncher", owner))
    kv("probe.complete", true)
  }
}
