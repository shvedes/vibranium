pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters duplicated-name
import QtQuick
import Quickshell
import qs.common

// The viewer is the one from `apps/ImageViewer.qml`, a standalone QML
// application that read a private palette, resolved icons itself and took its
// file off argv - three things the shell already does once for everything it
// draws. This module keeps the viewer and drops those three.
//
// A resident facade over a demand-loaded controller, the same shape as
// features/apps/audioMixer. The singleton cannot be unloaded, so the split is
// not "hide the singleton": UnitGate leases the unit, a Loader holds the
// controller, and the facade releases both after the close has settled. A shell
// that never opens a picture pays for none of the viewer's work - no window, no
// decode, no frosted toolbar - which is what the unit's facade activation
// in the catalog is for.
//
// This file holds no IpcHandler and no `Registry.offer`. Both belong to the
// `app` host (features/apps/AppHost.qml), which is the entry point every app is
// reached through and which dispatches with `Registry.call(name, verb, ...)`;
// an app that also declared its own socket would be a second surface for the
// same window. What this singleton registers is its id and its five verbs,
// which is what `Registry.call("imageViewer", ...)` needs.
Singleton {
  id: root

  readonly property string tag: "imageViewer"
  readonly property string unitId: "imageViewer"

  // `visible` is the state, and it is deliberately NOT persisted. The mixer
  // keeps its flag across a shell reload through PersistentProperties; this one
  // does not, because the viewer's content is the file it was opened on and
  // that file is not persisted either. Restoring the flag alone would restore a
  // titled, visible, empty window over no image at all - the window would claim
  // a picture it does not have. A window that opens empty is honest; a window
  // that is visible because a boolean survived a reload is not.
  property bool visible: false

  // This window takes no part in the shell's exclusive-surface protocol, and
  // that is a fact about what it is rather than a shortcut past the mechanism.
  // The protocol keeps one current holder per claim id and closes the previous
  // holder as soon as another id claims, which is right for a WlrLayershell
  // overlay competing for the screen and wrong for a regular toplevel: this
  // window maps as an xdg_toplevel, appears under `hyprctl clients` and is meant
  // to sit beside a file manager while both are open. A real window must stay
  // out of that protocol rather than hold a claim it does not need.
  onVisibleChanged: {
    // Either direction hands the controller's lifetime to the window: an open
    // cancels a release the grace had pending, and a close is already
    // closeSettle's, so the idle timer has nothing left to decide.
    idleRelease.stop()
  }

  // --- controller lifecycle ---
  // One owner string for every demand. UnitGate matches leases by owner, so a
  // constant owner means the second caller finds the lease that is already
  // there instead of minting a parallel one, and it is neither the catalog's
  // own "boot" nor a bar module's "bar:<id>", so a release here can never take
  // down a lease someone else is holding.
  readonly property string gateOwner: "imageViewer-facade"
  property var _lease: null
  property int _constructions: 0

  // unloaded | loading | ready | unavailable | failed. A verb that cannot run
  // answers from this instead of vanishing.
  property string controllerState: "unloaded"
  property string controllerError: ""
  readonly property bool controllerReady: root.controllerState === "ready"
  // The facade is ready as soon as this singleton exists; the boot drain waits
  // for that, not for a controller.
  readonly property bool facadeReady: root.tag !== ""
  // Controllers built since boot. 0 until the first use, then one per open: the
  // visible proof that a facade construction does no work and a demand builds
  // exactly one controller.
  readonly property int constructions: root._constructions

  // --- public read surface (projected) ---
  readonly property var _controller: controllerLoader.item

  // The file the window is showing, or "" for no controller, no window, or a
  // window holding no image. One projection so `status()` and any in-process
  // reader cannot disagree about which file is on screen, and a reader between
  // two opens gets an empty string rather than a reference to a window that no
  // longer exists.
  readonly property string currentPath: root._currentPath()

  Component.onCompleted: Registry.register("imageViewer", root)

  Component.onDestruction: {
    closeSettle.stop()
    idleRelease.stop()
    // The controller goes before the lease does, so no gate observer ever sees
    // the unit released while its child is still alive. The controller's own
    // destruction takes its Loader with it, and the window and the whole image
    // tree under it go with that.
    root.teardownController()
    Registry.unregister("imageViewer")
  }

  // --- open / close ---
  //
  // The three verbs, and the facade's whole interactive surface. They are
  // functions and NOT a property pair: a `readonly property bool open` beside
  // `function open()` is one name in QML, the function wins, and every read of
  // the property then returns a function object - which is truthy, so a
  // binding guarded on "is the viewer open" quietly passes while the window is
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
    // The window is gone the tick the facade hides it; the settle outlasts that
    // by a frame and a half so nothing is torn down under a surface the
    // compositor is still unmapping. A window that opens again inside the
    // settle stops it.
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

  // --- paths ---
  //
  // The one verb that carries an argument, and it carries a path. The order is
  // the contract and it is the mixer's: demand, show, hand over, answer - a
  // caller learns whether the window is up from the answer and does not have to
  // follow every open with a `status()` to find out.
  //
  // The input is validated before anything is demanded, so a refused path costs
  // no unit lease, no controller and no window: a refusal is not an open that
  // went badly, and leaving a controller built behind one would hand the next
  // caller a tree this one never used.
  function openPath(path) {
    const asked = path === undefined || path === null ? "" : String(path).trim()
    if (asked === "") return "refused: no path given"
    const url = root._asUrl(asked)
    if (url === "") {
      // The refusal names the reason rather than reporting a bare false,
      // because the caller's next move follows from it: this is fixed by
      // naming the file absolutely, which the `app` host cannot do on the
      // caller's behalf.
      return "refused: a relative path has no base - pass an absolute path or a file: URL"
    }
    if (root._demand() === null) return "unavailable: " + root._refusal()
    // The show is what makes the window exist: the controller builds it behind
    // the facade's own `visible`, and it is `visible` that this line sets. So
    // the handoff below can rely on there being a window to hand to - and if the
    // controller's screen gate is still closed there is not one, which is what
    // the `refused:` branch below says rather than an `opened:` nothing is on.
    if (!root.show()) return "unavailable: " + root._refusal()
    // The controller answers whether the window took it. A false here is the
    // window's own refusal - an unreadable file, a decode it would not start -
    // and it is not the facade's to second-guess.
    if (root._controller.openPath(url) !== true) return "refused: " + url
    return "opened: " + url
  }

  // The URL a named absolute path or `file:` URL becomes, or "" when the input
  // cannot be resolved without guessing a base. An absolute path is encoded
  // per segment via Paths.toFileUrl and a `file:` URL is normalized the same
  // way, because a raw "#", "?", "%" or space in a file name is a
  // fragment/query/escape delimiter in a URL: concatenating "file://" + path
  // truncates "a#b.png" to "a" and the Image never loads.
  //
  // A relative path is refused rather than resolved. The superseded source
  // resolved argv with `Qt.resolvedUrl` (apps/ImageViewer.qml:1891`), which
  // resolves against the QML file's OWN directory - a base that means something
  // only because the viewer is a file on disk beside its own window, and that
  // has no meaning at all for an argument arriving over IPC, where the caller's
  // working directory is not this process's. Guessing a base here would open
  // whatever happened to sit next to the source file, so the answer refuses and
  // names the reason instead.
  function _asUrl(asked) {
    if (asked.startsWith("file:")) return root._normalizeFileUrl(asked)
    if (asked.startsWith("/")) return Paths.toFileUrl(asked)
    return ""
  }

  // A `file:` URL as a canonical encoded file:// URL. The remainder is decoded
  // to a path and re-encoded per segment, so an already-encoded "%23" and a
  // raw "#" both land on "%23" instead of one double-encoding or the other
  // truncating at the fragment delimiter.
  function _normalizeFileUrl(u) {
    let p = String(u ?? "")
    if (p.startsWith("file://")) {
      p = p.substring(7)
      if (p.startsWith("localhost/"))
        p = p.substring(9)
      else if (p.startsWith("localhost")) {
        const slash = p.indexOf("/")
        p = slash >= 0 ? p.substring(slash) : ""
      }
      if (p !== "" && p[0] !== "/") p = "/" + p
    } else if (p.startsWith("file:")) {
      p = p.substring(5)
      if (p !== "" && p[0] !== "/") p = "/" + p
    }
    try {
      p = decodeURIComponent(p)
    } catch (ignored) {
    }
    return Paths.toFileUrl(p)
  }

  // What a demand that could not build reports. The gate's own code is the
  // reason and the controller state is the fallback, so a caller learns which of
  // the two happened from the one string rather than from a second call.
  function _refusal() {
    if (root.controllerError !== "") return root.controllerError
    return root.controllerState
  }

  // The window's file, or "" for no controller, no window or no image. Every
  // read goes through here so the null case is stated once: a `Loader` with
  // nothing loaded hands back null, and a holder that carries no `currentPath`
  // hands back undefined, and neither is a string.
  function _currentPath() {
    if (root._controller === null || root._controller === undefined) return ""
    const holder = root._controller.window
    if (holder === null || holder === undefined) return ""
    const path = holder.currentPath
    return path === undefined || path === null ? "" : String(path)
  }

  // --- demand / teardown ---
  // Build the controller on first use and keep exactly one. Repeated callers -
  // a second IPC verb, the desktop entry fired twice, the compositor closing the
  // window - all land here, and every path out (refused lease, failed
  // construction, unload) drops the lease again, so a refused or failed caller
  // leaves the next one a clean unit.
  function _demand() {
    if (root.controllerState === "ready" && root._controller !== null) return root._controller
    const result = UnitGate.ensure(root.unitId, root.gateOwner)
    if (result === undefined || result === null || result.ok !== true) {
      // A blocked, failed or unregistered unit still hands back a lease for two
      // of those three; give it straight back so the record cannot collect
      // owners for a demand that never loaded.
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

  // Idempotent and callable with nothing loaded: boot's unit teardown hook and
  // the close settle both land here, and the second call is a no-op rather than
  // a double release.
  function teardownController() {
    const held = root._unload()
    if (!root._unwinding) root._setState("unloaded")
    return held
  }

  // The gate's teardown hook drops this owner's whole lease set in one call, so
  // the ensure and the retain that came with it go together and a lost release
  // cannot leave the record counting an owner nobody holds.
  function _dropLease() {
    if (root._lease === null) return false
    root._lease = null
    return UnitGate.releaseOwner(root.gateOwner) > 0
  }

  // --- idle release ---
  // The close settle only runs when a window was opened, so the one demand that
  // opens nothing - a `status` verb arriving first - had no way back to
  // teardown: the window's own tree stayed resident with no window and visible
  // false. The release is armed where the controller is built, so no demand
  // site has to remember to give it back.
  function _releaseIfIdle() {
    // Only a controller the facade accepted: a refused or failed demand reports
    // its own state to the next caller, and a timer landing on it would restate
    // that as "unloaded". A window that is up owns its controller outright - the
    // close settle is the path that gives it back.
    if (root.controllerState !== "ready" || root._controller === null) return false
    if (root.visible) return false
    return root.teardownController()
  }

  function _setState(next, code) {
    const detail = code || ""
    if (root.controllerState === next && root.controllerError === detail) return
    root.controllerState = next
    root.controllerError = detail
    // The unit's own ready probe reads controllerReady, and nothing polls a
    // demand-loaded unit, so the record is settled here instead: the gate must not
    // sit in "starting" once the controller is up.
    if (next === "ready") UnitGate.refresh(root.unitId)
  }

  // --- verbs ---
  //
  // Fixed arity, because Quickshell's IpcHandler enforces exact arity and the
  // `app` host forwards what it was given. The host owns `list`, `help` and
  // `ping`; what an app answers for itself is how it opens, how it closes, what
  // it is showing and what state its controller is in.
  //
  // `path` is in the payload and the mixer's graph details are not, and the
  // difference is what each app holds: a node id and a stream name describe a
  // graph the shell owns elsewhere and publishes nowhere, while a path is the
  // whole of this app's content and the caller asking named it.
  function status() {
    const unit = UnitGate.state(root.unitId)
    return JSON.stringify({
      visible: root.visible,
      controller: root.controllerState,
      controllerError: root.controllerError,
      constructions: root.constructions,
      path: root.currentPath,
      owners: unit === null ? 0 : unit.ownerCount
    })
  }

  // The controller, and nothing else: a Loader with no source until the first
  // demand, so a facade that is only a registry entry holds no window, no
  // decode and no screen gate.
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

    ImageViewerController {}
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
  // enough that an open immediately behind a status call reuses the tree the
  // first demand already paid for, short enough that the residue is gone
  // within a second. Bounded and one-shot: a later demand re-arms it and the
  // window's own open or close stops it.
  Timer {
    id: idleRelease
    interval: Ui.slowMs
    repeat: false
    onTriggered: root._releaseIfIdle()
  }
}