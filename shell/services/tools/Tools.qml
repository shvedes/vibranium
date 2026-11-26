pragma Singleton
pragma ComponentBehavior: Bound

// Standalone region picker. Capture flows and any other feature ask this
// service for the region view; the public CLI `pick` is one consumer of the
// same slot. The service owns the request id and hands in-process outcomes
// (including the grab handle a crop needs) to the flow that opened it, while
// the gateway projects only x/y/w/h to callers outside the shell.
//
// One request is live at a time. A public pick answers "accepted" until the
// overlay settles; repeated calls then report the rectangle, or a cancelled
// outcome as a bare RC 1. No view or handle crosses the public boundary.
import QtQuick
import Quickshell
import qs.common
import "../../common/text/IpcProtocol.js" as Protocol

Singleton {
  id: root

  readonly property string tag: "tools"

  property int _request: 0
  property var _outcome: null
  property bool _public: false
  property ShellScreen _publicScreen: null

  Component.onCompleted: {
    IpcRouter.register("tools", root, {
      "tools.picker.pick": function (_, ctx) {
        return root._pick(ctx.words.includes("silent"), ctx.words.includes("logical"))
      },
      "tools.picker.stop": function () { return root._stop() },
      "tools.ping": function () { return Protocol.ok("pong") },
      "tools.status": function () {
        return Protocol.ok({ picker: root._request !== 0 ? "active" : "idle" },
          { kind: "record" })
      }
    })
  }

  Component.onDestruction: IpcRouter.unregister("tools", root)

  Connections {
    target: AnnotationActions
    function onSettled(id, outcome) {
      if (id !== root._request) return
      const wasPublic = root._public
      if (wasPublic) root._outcome = outcome
      root._public = false
      root._request = 0
      if (wasPublic) AnnotationActions.close(id)
    }
  }

  // In-process region slot. A flow that needs the grab result opens through
  // here and reads the outcome through its own AnnotationActions connection;
  // `_public` marks the CLI gateway, whose answer is a rectangle.
  function requestRegion(spec) {
    if (root._request !== 0 || root._outcome !== null)
      return { ok: false, code: "busy", id: 0 }
    const opened = AnnotationActions.request("region", spec)
    if (!opened.ok) return opened
    root._public = false
    root._request = opened.id
    return opened
  }

  function regionSpec(id) { return AnnotationActions.spec(id) }
  function retargetRegion(id, screen) { return AnnotationActions.retarget(id, screen) }
  function closeRegion(id) {
    if (id === root._request) {
      root._request = 0
      root._public = false
    }
    return AnnotationActions.close(id)
  }
  function _pick(silent, logical) {
    if (root._outcome !== null) {
      const outcome = root._outcome
      root._outcome = null
      const screen = root._publicScreen
      root._publicScreen = null
      const code = String(outcome.code)
      if (code !== "accepted")
        return Protocol.error("cancelled", "the selection was discarded")
      const x = Number(outcome.x) || 0
      const y = Number(outcome.y) || 0
      const w = Number(outcome.w) || 0
      const h = Number(outcome.h) || 0
      if (logical) {
        if (screen === null)
          return Protocol.error("unavailable", "the selected screen is no longer available")
        // The crop rectangle is in frame pixels. Round both edges on the desktop grid.
        const sx = outcome.grabFrameW > 0 ? screen.width / outcome.grabFrameW : 1
        const sy = outcome.grabFrameH > 0 ? screen.height / outcome.grabFrameH : 1
        const left = Math.round(x * sx)
        const top = Math.round(y * sy)
        return Protocol.ok({
          x: screen.x + left, y: screen.y + top,
          w: Math.max(1, Math.round((x + w) * sx) - left),
          h: Math.max(1, Math.round((y + h) * sy) - top)
        }, { kind: "record" })
      }
      return Protocol.ok({ x: x, y: y, w: w, h: h }, { kind: "record" })
    }
    if (root._request !== 0)
      return Protocol.ok({ pending: true }, { kind: "record" })
    const screen = Ui.primaryScreen
    const opened = root.requestRegion({
      screen: screen,
      url: "", frameW: 0, frameH: 0, immediate: true,
      silent: silent === true, jobId: 0, flowId: 0
    })
    if (!opened.ok)
      return Protocol.error(opened.code === "busy" ? "busy" : "unavailable",
        "the region picker is not available")
    root._public = true
    root._publicScreen = screen
    return Protocol.ok({ pending: true }, { kind: "record" })
  }

  function _stop() {
    if (root._request !== 0) {
      const id = root._request
      // A flow consumer learns the dismissal through the same settled signal
      // it uses for an Escape, so it can release its claim and its overlay.
      if (!root._public) AnnotationActions.settle(id, { code: "cancelled" })
      root.closeRegion(id)
    }
    root._outcome = null
    root._publicScreen = null
    return Protocol.ok(undefined)
  }
}
