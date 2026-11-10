pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import QtQuick
import Quickshell
import Quickshell.Io
import qs.common
import "../../common/text/UnitIpc.js" as UnitIpc
import "../../common/theme/DeviceIcons.js" as DeviceIcons

// OSD service: transient screen meters. Holds the visible payload
// (kind/value/label/icon/muted), the configurable bottom offset and the
// lock suppression flag, drives the auto-hide Timer, and publishes the
// `qs ipc call osd flash <json>` surface. View is in OSDView.qml; this
// file owns only state and policy.
Singleton {
  id: root

  readonly property string tag: "osd"

  // How long the surface stays mapped after the last show().
  readonly property int visibleMs: 1500
  // How long the overlay window outlives the payload after its exit fade.
  // Mapping a layer-shell surface is the one step of a flash outside this
  // process, so keeping the window mapped across a burst of keypresses
  // leaves a repeat press repainting the card instead of remapping the
  // window. Bounded, so an idle shell holds no fullscreen surface.
  readonly property int lingerMs: 3000

  property bool visible: false
  property bool dismissing: false
  // Written by the lockscreen: session-lock surfaces render above all
  // layer-shell windows, so the desktop surface stays unmapped while
  // locked and an unlock never greets a stale flash. Read through
  // surfaceVisible below, so the rule is written once.
  property bool desktopSuppressed: false
  onDesktopSuppressedChanged: {
    if (!root.desktopSuppressed) return
    hideTimer.stop()
    exitTimer.stop()
    lingerTimer.stop()
    root._lingering = false
    root.visible = false
    root.dismissing = false
  }
  // A payload is up while it is mapped or fading out. The desktop surface
  // maps while that is true, during the linger window after it, and never
  // while the lock is suppressing it.
  readonly property bool payloadVisible: root.visible || root.dismissing
  readonly property bool surfaceVisible: (root.payloadVisible || root._lingering) && !root.desktopSuppressed
  property bool _lingering: false

  // Payload shown while visible. `value` is 0..100, `muted` when set
  // forces the muted glyph/label and dims the meter.
  property string kind: "volume"
  property real value: 0
  property string label: ""
  property string iconName: "volume-max"
  property bool muted: false

  // A fresh payload is not a level change: the card appears AT its level
  // instead of sweeping to it from the last flash's. True only for the turn
  // that starts a payload which was not already up - a repeat press while
  // the card is on screen keeps streaming values, and those DO glide - and
  // cleared on the next turn, which is all the card needs: its fill binds in
  // this same turn, so this marks the one assignment that must not tween.
  property bool fillSnap: false

  // Placement is fixed: always at the bottom side of the screen,
  // `offset` px above the bottom edge (mirrors OSDs that hover above a
  // bottom bar without overlapping it). Validated against the same check
  // the view uses so malformed persisted values never crash the shell -
  // they fall back to the default and the store keeps the bad value until
  // the user fixes it via Settings/IPC.
  // The OSD offers no top/bottom switch: `position` is a constant, kept for
  // IPC compatibility with a caller that still asks for one.
  readonly property string position: "bottom"
  readonly property int offset: {
    root.revDep
    const v = Settings.value("shell.osd.offset")
    return typeof v === "number" && v >= 0 && v <= 400 ? Math.round(v) : 80
  }
  // Boot settle: bindings pass through fallback values while the
  // store lands, which would otherwise fake a placement change and
  // pop a preview on every boot. Starts closed: a change firing
  // before Component.onCompleted (still -1) is a boot artifact, not
  // a user edit. Same _bootAt idiom as the bar pill. The window is
  // construction-relative, so a store that lands after it is not
  // covered by it; both guards below also read Settings.ready, and
  // the two are independent: the window holds off the first real
  // write once the store IS ready, the flag holds off a slow one.
  property double _bootAt: -1
  // Placement preview: editing offset re-maps the live card (or a dummy
  // meter when nothing showed yet) so the new spot reads at once. Change
  // signals fire only on real edits, never on boot or on unrelated
  // settings flushes.
  onOffsetChanged: root.previewMeterPlacement()
  function previewMeterPlacement() {
    if (root._bootAt <= 0 || Date.now() - root._bootAt < 3000) return
    if (!Settings.ready) return
    if (root.visible) {
      hideTimer.restart()
      return
    }
    root.show("volume", 50, "", "volume-max", false)
  }
  // Settings.rev bump gate so position/offset bindings re-evaluate on
  // every settings flush without the singleton subscribing to every key.
  readonly property int revDep: Settings.rev

  // Global animation gate (hypr.animations.enabled), wired at lib level
  // like PanelCard/Island/OverlayWindow so consumers need not bind it.
  readonly property bool animationsEnabled: MotionPolicy.enabled

  // Show the OSD with the given payload. Restarts the hide timer.
  // `value` is clamped: brightness allows -90..100 (negative = gamma
  // dimming, used to tint the bar background dim red), volume/mic 0..100.
  // `label` is kept verbatim (empty means the view hides the text line -
  // used for icon+bar-only displays).
  function show(kind, value, label, icon, muted) {
    const k = String(kind || "volume").toLowerCase()
    const allowed = { volume: 1, microphone: 1, brightness: 1 }
    if (!allowed[k]) return false
    let v = Number(value)
    if (isNaN(v)) v = 0
    v = Math.round(v)
    if (k === "brightness") v = Math.max(-90, Math.min(100, v))
    else v = Math.max(0, Math.min(100, v))
    const lb = String(label || "")
    const ic = String(icon || "").trim()
    // A new payload owns the window: cancel a pending linger so a show
    // that arrives mid-window is not racing its expiry.
    root._cancelLinger()
    exitTimer.stop()
    root.dismissing = false
    root.fillSnap = !root.payloadVisible
    root.kind = k
    root.value = v
    root.muted = muted === true
    root.label = lb
    root.iconName = ic !== "" ? ic : root._iconFor(k, v, root.muted)
    root.visible = true
    if (root.fillSnap) Qt.callLater(root._clearFillSnap)
    hideTimer.restart()
    return true
  }

  function _iconFor(kind, v, muted) {
    if (muted) return "volume-off"
    if (kind === "brightness") return "brightness"
    if (kind === "microphone") return v <= 0 ? "mic-off" : "mic-on"
    // Percent-scale volume leg, canonicalized in
    // common/theme/DeviceIcons.js (fraction scale there, percent here -
    // the OSD stays decoupled from the Audio service; both follow thirds).
    return DeviceIcons.volumeIconFor(Number(v) / 100, false)
  }

  // Wave groups kept opaque on the tiered volume-max glyph (same thirds
  // as _iconFor above, mirrored from Audio.volumeDimTiersFor). The view
  // binds this next to the icon name; non-tiered glyphs ignore it.
  function _dimTiersFor(kind, v, muted) {
    if (kind === "brightness" || kind === "microphone" || muted) return 0
    const n = Number(v)
    if (isNaN(n) || n <= 0) return 0
    if (n < 33) return 1
    if (n < 67) return 2
    return 3
  }

  function hide() {
    hideTimer.stop()
    if (!root.visible) {
      root.dismissing = false
      return
    }
    if (!root.animationsEnabled) {
      root.visible = false
      root.dismissing = false
      root._keepSurface()
      return
    }
    root.dismissing = true
    root.visible = false
    exitTimer.restart()
  }

  // Hold the overlay mapped for the linger window. Called when the payload
  // is fully gone, never while it is still on screen.
  function _keepSurface() {
    if (root.desktopSuppressed) {
      root._lingering = false
      return
    }
    root._lingering = true
    lingerTimer.restart()
  }

  function _cancelLinger() {
    lingerTimer.stop()
    root._lingering = false
  }

  function _clearFillSnap() {
    root.fillSnap = false
  }

  Timer {
    id: hideTimer
    interval: root.visibleMs
    repeat: false
    onTriggered: root.hide()
  }

  Timer {
    id: exitTimer
    interval: Ui.fastMs
    repeat: false
    onTriggered: {
      root.dismissing = false
      root._keepSurface()
    }
  }

  Timer {
    id: lingerTimer
    interval: root.lingerMs
    repeat: false
    onTriggered: root._lingering = false
  }

  // Instantiate the surface once the singleton is boot-touched. The
  // view reads this singleton's properties directly, no prop threading.
  // LazyLoader moves that construction off the boot frame without gating it:
  // `loading: true` with no `active` builds once and stays resident, which is
  // what a bare OSDView {} did minus the boot-frame cost. Deliberately not
  // gated on surfaceVisible - that would unmap and re-map the window between
  // flashes, and a meter has to answer the first keypress instantly.
  LazyLoader {
    loading: true

    OSDView {}
  }

  Component.onCompleted: {
    Registry.offer("osd", {
      title: "OSD",
      description: "on-screen display overlays",
      verbNames: [
        "hide",
        "flash",
        "status",
        "help",
        "ping",
      ]
    })
    Registry.register(root.tag, root)
    root._bootAt = Date.now()
  }
  Component.onDestruction: Registry.unregister(root.tag)

  IpcHandler {
    target: "osd"
    function help(command: string): string {
      return UnitIpc.help("osd", "OSD", "on-screen display overlays", [
        { name: "hide", help: "hide the OSD" },
        { name: "flash", help: "(kind, value, label, icon, muted) flash the OSD" },
      ], command)
    }
    function ping(): string { return "pong" }

    // JSON payload: { kind, value, label, icon, muted }. Named `flash`
    // rather than `show` on purpose: the singleton owns a multi-param
    // show() for in-process callers, and a second `show` on the IPC
    // surface makes CLI dispatch refuse arguments on both. Empty-valued
    // keys are omitted by senders: `qs ipc call` hands the argument
    // through verbatim, and the parse below runs until the value stops
    // being a string, so either encoding lands on the object.
    function flash(json: string): string {
      let o = json
      for (let i = 0; i < 3 && typeof o === "string"; i++) {
        try {
          o = JSON.parse(o)
        } catch (e) {
          return "error: invalid JSON"
        }
      }
      if (o === null || typeof o !== "object" || Array.isArray(o)) return "error: invalid JSON"
      const ok = root.show(o.kind, o.value, o.label, o.icon, o.muted)
      return ok ? "ok" : "error"
    }

    function hide(): string { root.hide(); return "ok" }

    function status(): string {
      return JSON.stringify({
        visible: root.visible,
        dismissing: root.dismissing,
        kind: root.kind,
        value: root.value,
        label: root.label,
        icon: root.iconName,
        muted: root.muted,
        position: root.position,
        offset: root.offset,
        surfaceVisible: root.surfaceVisible,
        animationsEnabled: root.animationsEnabled
      })
    }
  }
}
