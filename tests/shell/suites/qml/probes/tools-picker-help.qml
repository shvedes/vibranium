// Probe: the public pick leaf publishes its option and no notes.
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

  Component.onCompleted: {
    try {
      const reply = P.decode(IpcRouter.describe(P.encode({
        v: 1, kind: "help", path: ["tools", "picker", "pick"]
      })))
      const desc = reply && reply.ok ? reply.data : null
      kv("help.ok", reply && reply.ok)
      const meta = desc && desc.meta ? desc.meta : {}
      kv("help.notes", JSON.stringify(meta.notes || []))
      kv("help.options", JSON.stringify(meta.options || []))
      kv("help.usage", meta.usage || "")
    } catch (e) {
      kv("probe.error", "" + (e && e.message ? e.message : e))
    }
    console.log("##DONE##")
  }
}
