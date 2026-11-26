// Probe: batch C catalog grammar and ownership in the real IpcRouter.
// The owners are plain JS objects with constant closures; no bar, clipboard
// or picker singleton is constructed and no window is opened.
import QtQuick
import Quickshell
import qs.common
import "common/text/IpcProtocol.js" as P

Item {
  id: probe
  width: 1
  height: 1

  property var _barOwner: ({ tag: "probe.bar" })
  property var _clipOwner: ({ tag: "probe.clip" })
  property var _emojiOwner: ({ tag: "probe.emoji" })
  // Silent actions no longer echo their arguments, so the probe records them
  // out of band. The assertion still proves the exact typed args arrived.
  property var _seen: ({})

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function show(key, value) { kv(key, JSON.stringify(value === undefined ? null : value)) }
  function code(text) {
    var r = P.decode(text)
    return r && !r.ok ? r.error.code : "ok"
  }
  function data(text) {
    var r = P.decode(text)
    return r && r.ok ? r.data : null
  }
  function env(obj) { return P.encode(obj) }
  function call(argv) {
    return IpcRouter.invoke(env({ v: 1, kind: "call", argv: argv, literalFrom: null }))
  }

  Component.onCompleted: {
    try { run() } catch (e) { kv("probe.error", "" + (e && e.message ? e.message : e)) }
    console.log("##DONE##")
  }

  function frame(value) { return { v: 1, ok: true, data: value } }

  function run() {
    kv("register.bar", IpcRouter.register("bar", probe._barOwner, {
      "bar.enable": function () {
        probe._seen["bar.enable.calls"] = (probe._seen["bar.enable.calls"] || 0) + 1
        return frame({ enabled: true })
      },
      "bar.module.ID.opt.KEY.set": function (a) {
        probe._seen["bar.opt.set.args"] = a
        return frame(a)
      },
      "bar.module.ID.opt.list": function () { return frame("fixed") },
      "bar.module.ID.island.is-open": function (a) { return frame(a) },
      "bar.module.ID.trigger": function (a) { return frame(a) },
      "bar.status": function () { return '{"outputs":["HDMI-A-1"]}' },
      "bar.ping": function () { return "pong" }
    }))
    kv("register.clipboard", IpcRouter.register("clipboard", probe._clipOwner, {
      "clipboard.copy.entry": function (a) {
        probe._seen["clip.copy.args"] = a
        return frame(a)
      },
      "clipboard.list.regular": function () { return frame(["projected"]) },
      "clipboard.status": function () { return '{"copyBusy":false}' },
      "clipboard.ping": function () { return "pong" }
    }))
    kv("register.emojiPicker", IpcRouter.register("emojiPicker", probe._emojiOwner, {
      "emojiPicker.copy": function (a) {
        probe._seen["emoji.copy.args"] = a
        return frame(a)
      },
      "emojiPicker.status": function () { return '{"open":false,"catalogReady":true}' },
      "emojiPicker.ping": function () { return "pong" }
    }))

    show("bar.enable", data(call(["bar", "enable"])))
    show("bar.enable.calls", probe._seen["bar.enable.calls"])
    show("bar.opt.set", data(call(["bar", "module", "weather", "opt", "ShowTemp", "true"])))
    show("bar.opt.set.args", probe._seen["bar.opt.set.args"])
    // Fixed `list` wins over the `KEY` placeholder at the same position.
    kv("bar.opt.list.code", code(call(["bar", "module", "weather", "opt", "list"])))
    show("bar.opt.list", data(call(["bar", "module", "weather", "opt", "list"])))
    show("bar.island.screen", data(call(["bar", "module", "clock", "island", "is-open",
      "screen", "HDMI-A-1"])))
    show("bar.trigger", data(call(["bar", "module", "battery", "trigger", "flashCharge"])))
    show("bar.trigger.bad", code(call(["bar", "module", "battery", "trigger", "nope"])))
    show("bar.status", data(call(["bar", "status"])))
    kv("bar.ping", data(call(["bar", "ping"])))
    kv("bar.help.branch", data(IpcRouter.describe(env({ v: 1, kind: "help",
      path: ["bar", "module"] }))).meta.summary)

    show("clip.copy", data(call(["clipboard", "copy", "entry", "regular", "0"])))
    show("clip.copy.args", probe._seen["clip.copy.args"])
    show("clip.copy.bucket", code(call(["clipboard", "copy", "entry", "other", "0"])))
    show("clip.list", data(call(["clipboard", "list"])))
    show("clip.status", data(call(["clipboard", "status"])))
    // Client-owned stream rows are never executed in the router.
    kv("clip.clientRoute", code(call(["clipboard", "copy", "text", "hello"])))

    show("emoji.copy", data(call(["emojiPicker", "copy", "😀"])))
    show("emoji.copy.args", probe._seen["emoji.copy.args"])
    show("emoji.status", data(call(["emojiPicker", "status"])))
    kv("emoji.help", data(IpcRouter.describe(env({ v: 1, kind: "help",
      path: ["emojiPicker"] }))).items.length > 0)

    kv("unregister.bar", IpcRouter.unregister("bar", probe._barOwner))
    kv("unregister.clip", IpcRouter.unregister("clipboard", probe._clipOwner))
    kv("unregister.emoji", IpcRouter.unregister("emojiPicker", probe._emojiOwner))
    kv("bar.afterUnregister", code(call(["bar", "enable"])))
    kv("probe.complete", true)
  }
}
