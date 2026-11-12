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
  // The lease, the state and the Loader are the shared UnitLease; what each
  // facade keeps is when to give the controller back.
  readonly property string gateOwner: "audioMixer-facade"

  UnitLease {
    id: lease
    unitId: root.unitId
    owner: root.gateOwner
    controllerComponent: controllerComp
  }

  readonly property alias controllerState: lease.phase
  readonly property alias controllerError: lease.error
  readonly property bool controllerReady: lease.phase === "ready"
  // The facade is ready as soon as this singleton exists; the boot drain
  // waits for that, not for a controller.
  readonly property bool facadeReady: root.tag !== ""
  readonly property alias constructions: lease.constructions

  // --- public read surface (projected) ---
  readonly property bool routingReady: lease.controller !== null
    ? lease.controller.routingReady : false
  readonly property string routingError: lease.controller !== null
    ? lease.controller.routingError : ""
  readonly property bool routingBusy: lease.controller !== null
    ? lease.controller.routingBusy : false
  // Devices and streams, as flat arrays. Empty while the controller is gone,
  // which is what a consumer sees between two opens rather than a dangling
  // reference to a window that no longer exists.
  readonly property var outputDevices: lease.controller !== null
    ? lease.controller.outputDevices : []
  readonly property var inputDevices: lease.controller !== null
    ? lease.controller.inputDevices : []
  readonly property var playbackStreams: lease.controller !== null
    ? lease.controller.playbackStreams : []
  readonly property var captureStreams: lease.controller !== null
    ? lease.controller.captureStreams : []

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
    lease.teardown()
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
    if (lease.demand() === null) return false
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

  // Boot's unit teardown hook calls this by name on every facade, so the shared
  // lease teardown is republished under the name the hook owns.
  function teardownController() {
    return lease.teardown()
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
    if (root.controllerState !== "ready" || lease.controller === null) return false
    if (root.visible) return false
    // A `pactl list` in flight belongs to the controller and reports through a
    // callback that lives there, so releasing now would drop the parse that
    // was about to publish the routing map.
    if (lease.controller.routingBusy === true) {
      idleRelease.restart()
      return false
    }
    return lease.teardown()
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
    onTriggered: lease.teardown()
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
