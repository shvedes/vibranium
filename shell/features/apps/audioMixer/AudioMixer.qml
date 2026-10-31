pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters duplicated-name
import QtQuick
import Quickshell
import qs.common

// Native audio mixer - the surface the bar's volume right-click and the
// Settings "Volume mixer" row open. Everything the mixer can do is native
// to the PipeWire graph it is already talking to,
// with one documented exception: routing a stream to another device leaves
// the process, because Quickshell 0.3.1's `Quickshell.Services.Pipewire`
// exposes no link creation and neither `org.pipewire` nor
// `org.pulseaudio.Server` has a Move method. That one operation is a
// `pactl` child, with ids as separate argv elements and no shell anywhere on
// the path.
//
// A resident facade over a demand-loaded controller, the same shape as
// features/pass. The singleton cannot be unloaded, so the split is not "hide
// the singleton": UnitGate leases the unit, a Loader holds the controller,
// and the facade releases both after the close has settled. A shell that
// never opens the mixer pays for none of the graph work - no node-set
// observation, no peak monitors, no window, no `pactl` child - which is what
// the unit's facade activation in Boot's catalog is for.
//
// This file holds no IpcHandler and no `Registry.offer`. Both belong to the
// `app` host (features/apps/AppHost.qml), which is the entry point every app
// is reached through and which dispatches with `Registry.call(name, verb,
// ...)`; an app that also declared its own socket would be a second surface
// for the same window. What this singleton registers is its id and its four
// verbs, which is what `Registry.call("audioMixer", ...)` needs.
Singleton {
  id: root

  readonly property string tag: "audioMixer"
  readonly property string unitId: "audioMixer"

  // Reload survival for visibility (memory-only, never disk): the binding
  // reads through persist, imperative sets write back below.
  PersistentProperties {
    id: persist
    reloadableId: "audioMixer-visible"
    property bool visible: false
  }
  property bool visible: persist.visible

  // This window takes no part in the shell's exclusive-surface protocol, and
  // that is a fact about what it is rather than a shortcut past the mechanism.
  //
  // The protocol keeps one current holder per claim id and fires the previous
  // holder's stored closer as soon as another id claims. That is right for a
  // `WlrLayershell` overlay, which competes with every other overlay for the
  // screen - the menu, the launcher and the pass panel cannot all be up at
  // once - and the mixer copied it from features/pass, which is one.
  //
  // This window is a regular toplevel: it maps as an xdg_toplevel and appears
  // under `hyprctl clients`, not under `hyprctl layers`, and two toplevels
  // coexist by definition, because leaving the mixer open beside a browser is
  // the whole use. So this surface competes for nothing, and taking part in
  // the protocol is exactly what made the compositor close it whenever the
  // menu opened - the menu's claim fired the closer stored here, which was
  // hide(). A real window must stay out of it rather than hold a claim it does
  // not need.

  onVisibleChanged: {
    persist.visible = visible
    // Either direction hands the controller's lifetime to the window: an open
    // cancels a release the grace had pending, and a close is already
    // closeSettle's, so the idle timer has nothing left to decide.
    idleRelease.stop()
    // Nothing belongs here beyond that. The facade holds no graph state of its
    // own, and the controller refreshes the routing map from its own `wanted`
    // handler, so an open has nothing to repeat: what it cannot inherit is the
    // state of the world a moment later, and that refresh already reads fresh.
  }

  // --- controller lifecycle ---
  // One owner string for every demand. UnitGate matches leases by owner, so a
  // constant owner means the second keypress finds the lease that already
  // exists instead of minting a parallel one, and it is not Boot's "boot"
  // nor a bar module's "bar:<id>", so a release here can never take down a
  // lease someone else is holding.
  readonly property string gateOwner: "audioMixer-facade"
  property var _lease: null
  property int _constructions: 0

  // unloaded | loading | ready | unavailable | failed. A verb that cannot
  // run answers from this instead of vanishing.
  property string controllerState: "unloaded"
  property string controllerError: ""
  readonly property bool controllerReady: root.controllerState === "ready"
  // The facade is ready as soon as this singleton exists; the boot drain
  // waits for that, not for a controller.
  readonly property bool facadeReady: root.tag !== ""
  // Controllers built since boot. 0 until the first use, then one per open:
  // the visible proof that a facade construction does no work and a demand
  // builds exactly one controller.
  readonly property int constructions: root._constructions

  // --- public read surface (projected) ---
  readonly property var _controller: controllerLoader.item
  readonly property bool routingReady: root._controller !== null
    ? root._controller.routingReady : false
  readonly property string routingError: root._controller !== null
    ? root._controller.routingError : ""
  readonly property bool routingBusy: root._controller !== null
    ? root._controller.routingBusy : false
  // Devices and streams, as flat arrays. Empty while the controller is gone,
  // which is what a consumer sees between two opens rather than a dangling
  // reference to a window that no longer exists.
  readonly property var outputDevices: root._controller !== null
    ? root._controller.outputDevices : []
  readonly property var inputDevices: root._controller !== null
    ? root._controller.inputDevices : []
  readonly property var playbackStreams: root._controller !== null
    ? root._controller.playbackStreams : []
  readonly property var captureStreams: root._controller !== null
    ? root._controller.captureStreams : []

  Component.onCompleted: {
    Registry.register("audioMixer", root)
    // A reload with the window open lands here with visible already true and
    // nothing behind it - the controller is not built and no surface state is
    // memory - so the open is replayed through show() after clearing the flag:
    // the controller comes back exactly as it was.
    if (root.visible) {
      root.visible = false
      root.show()
    }
  }

  Component.onDestruction: {
    closeSettle.stop()
    idleRelease.stop()
    // The controller goes before the lease does, so no gate observer ever sees
    // the unit released while its child is still alive. The controller's own
    // destruction drops the node-set observation and the in-flight `pactl`
    // child.
    root.teardownController()
    Registry.unregister("audioMixer")
  }

  // --- open / close ---
  //
  // The three verbs, and the facade's whole interactive surface. They are
  // functions and NOT a property pair: a `readonly property bool open` beside
  // `function open()` is one name in QML, the function wins, and every read of
  // the property then returns a function object - which is truthy, so a
  // binding guarded on "is the mixer open" quietly passes while the window is
  // shut. `visible` is the state; `open()` is the verb.
  function show() {
    if (root.visible) return true
    // Demand first: without a controller there is no window to show, so
    // `visible` must not be set either.
    if (root._demand() === null) return false
    closeSettle.stop()
    root.visible = true
    return true
  }
  function hide() {
    if (!root.visible) return
    root.visible = false
    // The window is gone the tick the facade hides it; the settle outlasts
    // that by a frame and a half so nothing is torn down under a surface the
    // compositor is still unmapping. A window that hides and opens again
    // inside the settle stops it.
    closeSettle.restart()
  }
  // The three verbs the `app` host dispatches. Each answers whether the window
  // is up afterwards rather than a bare true, so a caller that reached an
  // unavailable unit learns it from the verb and not only from `status()`.
  function open() { return root.toggle() }
  function close() { root.hide(); return !root.visible }
  function toggle() {
    if (root.visible) {
      root.hide()
      return false
    }
    return root.show()
  }

  // --- demand / teardown ---
  // Build the controller on first use and keep exactly one. Repeated callers -
  // a held key, a second IPC verb, the window's own close button - all land
  // here, and every path out (refused lease, failed construction, unload)
  // drops the lease again, so a refused or failed caller leaves the next one
  // a clean unit.
  function _demand() {
    if (root.controllerState === "ready" && root._controller !== null) return root._controller
    const result = UnitGate.ensure(root.unitId, root.gateOwner)
    if (result === undefined || result === null || result.ok !== true) {
      // A blocked, failed or unregistered unit still hands back a lease for
      // two of those three; give it straight back so the record cannot
      // collect owners for a demand that never loaded.
      if (result !== undefined && result !== null && result.lease !== undefined && result.lease !== null)
        root._lease = result.lease
      root._dropLease()
      root._setState(result !== undefined && result !== null && result.state === "failed" ? "failed" : "unavailable",
        result !== undefined && result !== null && result.state === "failed" ? "unit" : "gate")
      return null
    }
    if (result.lease !== root._lease) {
      root._lease = result.lease
      // Retained, not merely held: a stray single release (a failed caller
      // unwinding) must not be able to drop the unit under a live window.
      UnitGate.retain(result.lease)
    }
    root._setState("loading")
    controllerLoader.active = true
    if (root._controller === null) {
      root._unloadFor("unavailable", "load")
      return null
    }
    if (root._controller.startupError !== "") {
      // A Loader cannot raise a construction error to its caller, so the
      // controller reports it and the facade answers unavailable and unloads:
      // the next caller starts from an unloaded unit.
      root._unloadFor("failed", root._controller.startupError)
      return null
    }
    root._constructions++
    root._setState("ready")
    return root._controller
  }

  // Drop the controller and the lease, then state the outcome. The flag is what
  // keeps the teardown the gate performs on the way out - it runs
  // teardownController() from inside the release - from restating "unloaded"
  // in the middle of a demand that is about to report why it failed, so the
  // state sequence a consumer sees is the facade's own.
  property bool _unwinding: false

  function _unloadFor(next, code) {
    root._unwinding = true
    root._unload()
    root._unwinding = false
    root._setState(next, code)
  }

  // Drop the controller and the lease without touching the reported state. A
  // caller that is about to answer unavailable or failed unwinds through here,
  // so the state it reports is the last one a consumer sees instead of
  // flapping through "unloaded" on the way there.
  function _unload() {
    closeSettle.stop()
    const held = root._lease !== null || controllerLoader.item !== null
    controllerLoader.active = false
    root._dropLease()
    return held
  }

  // Idempotent and callable with nothing loaded: Boot's unit teardown hook and
  // the close settle both land here, and the second call is a no-op rather than
  // a double release.
  function teardownController() {
    const held = root._unload()
    if (!root._unwinding) root._setState("unloaded")
    return held
  }

  // The gate's teardown hook drops this owner's whole lease set in one call,
  // so the ensure and the retain that came with it go together and a lost
  // release cannot leave the record counting an owner nobody holds.
  function _dropLease() {
    if (root._lease === null) return false
    root._lease = null
    return UnitGate.releaseOwner(root.gateOwner) > 0
  }

  // --- idle release ---
  // The close settle only runs when a window was opened, so the one demand that
  // opens nothing - a `status` verb arriving first - had no way back to
  // teardown: the node-set observation, the peak monitors and the window all
  // stayed resident with no window and visible false. The release is
  // armed where the controller is built, so no demand site has to remember to
  // give it back.
  function _releaseIfIdle() {
    // Only a controller the facade accepted: a refused or failed demand
    // reports its own state to the next caller, and a timer landing on it
    // would restate that as "unloaded". A window that is up owns its
    // controller outright - the close settle is the path that gives it back.
    if (root.controllerState !== "ready" || root._controller === null) return false
    if (root.visible) return false
    // A `pactl list` in flight belongs to the controller and reports through a
    // callback that lives there, so releasing now would drop the parse that
    // was about to publish the routing map.
    if (root._controller.routingBusy === true) {
      idleRelease.restart()
      return false
    }
    return root.teardownController()
  }

  function _setState(next, code) {
    const detail = code || ""
    if (root.controllerState === next && root.controllerError === detail) return
    root.controllerState = next
    root.controllerError = detail
    // The unit's own ready probe reads controllerReady, and nothing polls a
    // first_use unit, so the record is settled here instead: the gate must
    // not sit in "starting" once the controller is up.
    if (next === "ready") UnitGate.refresh(root.unitId)
  }

  // --- verbs ---
  //
  // Fixed arity, because Quickshell's IpcHandler enforces exact arity and the
  // `app` host forwards what it was given. The host owns `list`, `help` and
  // `ping`; what an app answers for itself is how it opens, how it closes and
  // what it currently holds.
  //
  // Nothing here reports a node id, a Pulse index, a device name or a stream
  // name: the status verb is a counter set and a state, and a mixer that put a
  // graph detail in an IPC reply would publish the graph to anything able to
  // reach the socket.
  function status() {
    const unit = UnitGate.state(root.unitId)
    return JSON.stringify({
      visible: root.visible,
      controller: root.controllerState,
      controllerError: root.controllerError,
      constructions: root.constructions,
      routingReady: root.routingReady,
      routingError: root.routingError,
      routingBusy: root.routingBusy,
      outputs: root.outputDevices.length,
      inputs: root.inputDevices.length,
      playback: root.playbackStreams.length,
      capture: root.captureStreams.length,
      owners: unit === null ? 0 : unit.ownerCount
    })
  }

  // The controller, and nothing else: a Loader with no source until the first
  // demand, so a facade that is only a registry entry holds no node
  // observation, no peak monitor, no window and no `pactl` child.
  Loader {
    id: controllerLoader
    active: false
    sourceComponent: controllerComp
    // Every construction is a demand, so arming here is what covers the demand
    // that opens no window: the grace starts where the controller arrives, and
    // an open or a close stops it.
    onLoaded: idleRelease.restart()
  }

  Component {
    id: controllerComp

    AudioMixerController {}
  }

  // The settle outlasts the window's own disappearance by a frame and a half.
  // Bounded and one-shot: an open that arrives first stops it.
  Timer {
    id: closeSettle
    interval: Ui.fastMs + 80
    repeat: false
    onTriggered: root.teardownController()
  }

  // The grace a demand that opened no window keeps its controller for. Long
  // enough that an open immediately behind a status call reuses the graph
  // observation the first demand already paid for, short enough that the
  // residue is gone within a second. Bounded and one-shot: a later demand
  // re-arms it and the window's own open or close stops it.
  Timer {
    id: idleRelease
    interval: 1200
    repeat: false
    onTriggered: root._releaseIfIdle()
  }
}
