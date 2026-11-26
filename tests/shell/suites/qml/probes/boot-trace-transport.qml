// Probe: boot.time through the REAL registered router path, plus wire fit.
//
// The real Boot component cannot be constructed in an offscreen engine (it
// pulls in LayerSurface / PanelWindow), so the owner here is a stand-in with
// the same constant closure Boot registers. The router, catalog, codec and
// frozen report are all real; this probe proves the route and the frame, not
// the shell's own construction.
import QtQuick
import Quickshell
import qs.common
import "common/text/IpcProtocol.js" as P
import "common/text/IpcCatalog.js" as Catalog

Item {
  id: root

  property var frozen: null
  property var owner: ({ tag: "probe.boot.owner" })
  property string error: ""

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  Component.onCompleted: {
    try {
      run()
    } catch (e) {
      kv("probe.error", String((e && e.message) || e))
    }
    console.log("##DONE##")
  }

  function run() {
    root.frozen = JSON.parse(Quickshell.env("BOOT_TRACE_FROZEN_REPORT"))
    var text = JSON.stringify(root.frozen)

    kv("catalog.kind", Catalog.findRow("boot.time").output.kind)
    var registered = IpcRouter.register("boot", root.owner, {
      "boot.time": function () { return JSON.stringify(root.frozen) }
    })
    kv("register.bootTime", registered)

    var frame = IpcRouter.invoke(P.encode({ v: 1, kind: "call", argv: ["boot", "time"], literalFrom: null }))
    var decoded = P.decode(frame)
    kv("gateway.ok", !!decoded && decoded.ok === true)
    kv("gateway.format", decoded && decoded.format ? decoded.format.kind : "")
    kv("gateway.report", JSON.stringify(decoded && decoded.data))
    kv("gateway.matchesFrozen", JSON.stringify(decoded && decoded.data) === text)

    var wire = P.encode(P.ok(root.frozen, "boottime"))
    var wireDecoded = P.decode(wire)
    kv("wire.bytes", P.asciiBytes(wire))
    kv("wire.limit", P.MAX_REPLY_BYTES)
    kv("wire.fits", P.asciiBytes(wire) <= P.MAX_REPLY_BYTES)
    kv("wire.format", wireDecoded && wireDecoded.format)
    kv("wire.decodedEquals", JSON.stringify(wireDecoded && wireDecoded.data) === text)
    kv("wire.escapedNonAscii", wire.indexOf("\\u65e5\\u672c\\u8a9e") >= 0)

    IpcRouter.unregister("boot", root.owner)
    kv("probe.complete", true)
  }
}
