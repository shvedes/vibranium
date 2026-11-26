// Probe: the real `qs.common` IpcRouter, driven through v1 envelopes.
// No feature or service is involved: the owner here is a plain JS object with
// constant closures, exactly the shape a retained handler registers.
import QtQuick
import Quickshell
import qs.common
import "common/text/IpcProtocol.js" as P

Item {
  id: probe
  width: 1
  height: 1

  property var _owner: ({ tag: "probe.owner" })
  property var _sessionOwner: ({ tag: "probe.session" })

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function show(key, value) { kv(key, JSON.stringify(value)) }
  function code(text) {
    var r = P.decode(text)
    return r && !r.ok ? r.error.code : "ok"
  }
  function data(text) {
    var r = P.decode(text)
    return r && r.ok ? r.data : null
  }
  function env(obj) { return P.encode(obj) }

  Component.onCompleted: {
    try {
      run()
    } catch (e) {
      kv("probe.error", "" + (e && e.message ? e.message : e))
    }
    console.log("##DONE##")
  }

  function run() {
    kv("incarnation.ascii", /^[A-Za-z0-9._-]+$/.test(IpcRouter.incarnation))
    kv("incarnation.process", IpcRouter.incarnation.indexOf(String(Quickshell.processId)) === 0)

    kv("register.unknownTarget", IpcRouter.register("noSuchTarget", probe._owner, {}))
    kv("register.unknownRow", IpcRouter.register("watch", probe._owner, { "watch.nope": function () {} }))
    kv("register.helpRow", IpcRouter.register("watch", probe._owner, { "watch.help": function () {} }))
    kv("register.good", IpcRouter.register("watch", probe._owner, {
      "watch.status": function (args, ctx) {
        return JSON.stringify({ ok: true, target: ctx.target, id: ctx.id, incarnation: ctx.incarnation })
      },
      "watch.ping": function () { return "pong" }
    }))
    // The lock read is part of session status now. Constant closures standing
    // in for the native reads prove the real router dispatches the catalog
    // rows, including the firmware branch.
    kv("register.sessionStatus", IpcRouter.register("session", probe._sessionOwner, {
      "session.status": function () { return { v: 1, ok: true, data: true, format: { kind: "bool" } } },
      "session.reboot.firmware": function () { return "confirmation_required" },
      "session.ping": function () { return "pong" }
    }))

    let toggles = 0
    IpcRouter.register("appLauncher", probe._owner, {
      "appLauncher.toggle": function () { toggles++; return { v: 1, ok: true } }
    })
    IpcRouter.invokeShortcut("another-prefix:appLauncher.toggle")
    IpcRouter.invokeShortcut("vibranium:shortcut:appLauncher.toggle extra")
    IpcRouter.invokeShortcut("vibranium:shortcut:constructor")
    kv("shortcuts.ignored", toggles)
    IpcRouter.invokeShortcut("vibranium:shortcut:appLauncher.toggle")
    kv("shortcuts.toggle", toggles)
    IpcRouter.unregister("appLauncher", probe._owner)

    kv("bad.envelope", code(IpcRouter.describe("not-a-frame")))
    kv("bad.version", code(IpcRouter.describe(env({ v: 2, kind: "index" }))))
    kv("bad.helpField", code(IpcRouter.describe(env({ v: 1, kind: "help", path: ["watch"], extra: 1 }))))
    kv("bad.callField", code(IpcRouter.invoke(env({ v: 1, kind: "call", argv: ["watch", "ping"], bogus: 1 }))))
    kv("bad.literalFrom", code(IpcRouter.invoke(env({ v: 1, kind: "call", argv: ["watch", "ping"], literalFrom: 9 }))))
    // The cap is on the wire envelope, before decoding: an oversized word can
    // never reach the catalog matcher or an owner closure.
    var oversized = "v1:" + new Array(P.MAX_REQUEST_BYTES + 2).join("x")
    kv("bad.requestOversize", code(IpcRouter.invoke(oversized)))
    kv("bad.describeOversize", code(IpcRouter.describe(oversized)))

    var index = data(IpcRouter.describe(env({ v: 1, kind: "index" })))
    kv("index.isPaged", Array.isArray(index.items))
    kv("index.hasCommon", Array.isArray(index.meta.common) && index.meta.common.length === 3)
    kv("index.targetCount", index.items.length)
    kv("index.sorted", index.items.every(function (t, i) {
      return i === 0 || index.items[i - 1].id < t.id
    }))
    kv("index.noCommonRows", index.items.every(function (t) {
      return t.literals.every(function (s) { return s.indexOf("help") !== 0 })
    }))
    // `lockscreen` used to sit in this sorted first page; its absence here is
    // the index half of the target removal.
    kv("index.noLockscreen", index.items.every(function (t) { return t.id !== "lockscreen" }))

    var help = data(IpcRouter.describe(env({ v: 1, kind: "help", path: ["settings", "fonts"] })))
    kv("help.branch.summary", help.meta.summary)
    kv("help.branch.examples", help.meta.examples.length)
    kv("help.commands", help.items.length)
    kv("help.command.ids", help.items.map(function (c) { return c.id }).join(','))

    var verb = data(IpcRouter.describe(env({ v: 1, kind: "help", path: ["audio", "volumeUp"] })))
    kv("help.unknownTarget", code(IpcRouter.describe(env({ v: 1, kind: "help", path: ["noSuchTarget", "volumeUp"] }))))

    kv("invoke.ping", data(IpcRouter.invoke(env({ v: 1, kind: "call", argv: ["watch", "ping"], literalFrom: null }))))
    show("invoke.status", data(IpcRouter.invoke(env({ v: 1, kind: "call", argv: ["watch", "status"], literalFrom: null }))))
    kv("invoke.extraArg", code(IpcRouter.invoke(env({ v: 1, kind: "call", argv: ["watch", "ping", "extra"], literalFrom: null }))))
    kv("invoke.unknownCommand", code(IpcRouter.invoke(env({ v: 1, kind: "call", argv: ["watch", "nope"], literalFrom: null }))))
    kv("invoke.sessionStatus", data(IpcRouter.invoke(env({ v: 1, kind: "call", argv: ["session", "status"], literalFrom: null }))))
    kv("invoke.sessionFirmware", code(IpcRouter.invoke(env({ v: 1, kind: "call", argv: ["session", "reboot", "firmware"], literalFrom: null }))))
    kv("invoke.sessionIsLockedGone", code(IpcRouter.invoke(env({ v: 1, kind: "call", argv: ["session", "isLocked"], literalFrom: null }))))
    // The whole lockscreen target is gone, so both an invoke and a help
    // describe fail at target discovery rather than command matching.
    kv("invoke.removedUnlock", code(IpcRouter.invoke(env({ v: 1, kind: "call", argv: ["lockscreen", "unlock"], literalFrom: null }))))
    kv("help.removedTarget", code(IpcRouter.describe(env({ v: 1, kind: "help", path: ["lockscreen"] }))))
    kv("bad.removedUnlockAux", code(IpcRouter.invoke(env({ v: 1, kind: "call", argv: ["lockscreen", "unlock"], literalFrom: null, aux: { socketPath: "/tmp/unused" } }))))
    kv("invoke.logRead", code(IpcRouter.invoke(env({ v: 1, kind: "call", argv: ["log", "status"], literalFrom: null }))))
    kv("invoke.wrongOwner", IpcRouter.unregister("watch", {}))
    kv("invoke.correctOwner", IpcRouter.unregister("watch", probe._owner))
    kv("invoke.afterUnregister", code(IpcRouter.invoke(env({ v: 1, kind: "call", argv: ["watch", "status"], literalFrom: null }))))

    // Paging uses a synthetic immutable snapshot; no feature table here is
    // large enough to page on its own.
    var many = []
    for (var i = 0; i < 30; i++) many.push({ id: "row-" + i })
    var snap = IpcRouter._snapshot(many, { marker: "fixed" }, "probe")
    var first = P.decode(IpcRouter._page(snap.snapshot, snap.id, 0, null))
    kv("page.first.count", first.data.items.length)
    kv("page.first.marker", first.data.meta.marker)
    kv("page.first.hasNext", typeof first.next === "object" && typeof first.next.cursor === "string")
    var c = first.next.cursor
    var second = P.decode(IpcRouter.describe(env({ v: 1, kind: "next", cursor: c })))
    kv("page.second.count", second.data.items.length)
    kv("page.second.marker", second.data.meta.marker)
    kv("page.reuse", code(IpcRouter.describe(env({ v: 1, kind: "next", cursor: c }))))
    kv("page.foreign", code(IpcRouter.describe(env({ v: 1, kind: "next", cursor: "other-instance.24" }))))
    kv("page.unknown", code(IpcRouter.describe(env({ v: 1, kind: "next", cursor: "none" }))))

    // A cursor is owned by its snapshot. Evicting the snapshot must retire the
    // cursor too, or the map grows without bound across a long session.
    var doomed = IpcRouter._snapshot(many, { marker: "doomed" }, "probe")
    var doomedPage = P.decode(IpcRouter._page(doomed.snapshot, doomed.id, 0, null))
    var doomedCursor = doomedPage.next.cursor
    for (var d = 0; d < P.MAX_SNAPSHOTS; d++) IpcRouter._snapshot([{ id: "x" }], {}, "probe")
    kv("page.evictedSnapshot", Object.prototype.hasOwnProperty.call(IpcRouter._snapshots, doomed.id))
    kv("page.evictedCursor", Object.prototype.hasOwnProperty.call(IpcRouter._cursors, doomedCursor))
    kv("probe.complete", true)
  }
}
