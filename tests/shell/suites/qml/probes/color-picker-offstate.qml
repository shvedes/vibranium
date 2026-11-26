// Probe: the standalone color-picker gateway is resident and seatless with no bar.
import QtQuick
import Quickshell
import qs.common
import qs.features.colorPicker
import "common/text/IpcProtocol.js" as P

Item {
  id: probe
  width: 1
  height: 1

  function kv(key, value) { console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n")) }
  function call(argv) {
    const raw = IpcRouter.invoke(P.encode({ v: 1, kind: "call", argv: argv, literalFrom: null }))
    return P.decode(raw)
  }
  function code(argv) {
    const r = call(argv)
    return r && !r.ok ? r.error.code : "ok"
  }

  Component.onCompleted: {
    try {
      kv("controller.exists", typeof ColorPickerController)
      kv("seat.empty", ColorPickerController.activePicker === null)
      kv("owner.none", ColorPickerController.owner === null)
      kv("fallback.none", ColorPickerController.fallback === null)
      // With no bar module the gateway starts its own URL-loaded session
      // instead of reporting an unavailable picker.
      kv("pick.accepted", code(["colorPicker", "pick"]))
      kv("close.ok", code(["colorPicker", "close"]))
      kv("status.code", code(["colorPicker", "status"]))
      kv("status.picking", JSON.stringify(call(["colorPicker", "status"]).data).indexOf('"picking":false') > 0)
      kv("ping", call(["colorPicker", "ping"]).data)
    } catch (e) {
      kv("probe.error", "" + (e && e.message ? e.message : e))
    }
    console.log("##DONE##")
  }
}
