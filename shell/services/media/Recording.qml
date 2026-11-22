pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "../../common/text/UnitIpc.js" as UnitIpc

// Native recording service - single source of truth for `Utilities` dropdown
// next to `Timer`. Mirrors `Timer`'s in-memory model but watches the
// `vb-core-recording` state file (`$VIBRANIUM_RUNTIME/recording-ongoing`)
// so the menu can show a live "recording" indicator and the same
// 2-step stop button as the timer.
//
// States:
//   VM       -> notify + abort
//   ongoing  -> stop
//   idle     -> start (screen)
//
// `Utilities` entry `id:"recording"` (type `action`) drives `toggle`
// via `call`; when `ongoing` the same row expands to a red stop
// confirmation (like timer).
Singleton {
  id: root

  readonly property string tag: "recording"

  // Live state - written only by _refresh() from the watched state file, so
  // both the shell and external `vb-core-recording` invocations stay in sync.
  // No click verb writes these three: a coalesced watch tick landing while the
  // marker still exists must not re-publish a state a click just retired.
  property bool ongoing: false
  property bool confirmed: false
  // Epoch ms when the current recording started (detection time for
  // external starts - the state file carries only the PID). Stamped
  // before `ongoing` flips so the bus payload always pairs them.
  property double startedAtMs: 0

  // Click feedback is a separate observable fact. The menu guard and its
  // armed colour read shownOngoing, which folds this intent over the file
  // reading until the file catches up; the bus still publishes file truth.
  // null or { want: "start" | "stop", since: epoch ms, id: generation }.
  property var pendingIntent: null
  readonly property bool shownOngoing: root.pendingIntent
    ? root.pendingIntent.want === "start"
    : root.ongoing
  property int _intentSeq: 0

  // The stop helper waits up to 5 s for the recorder to exit, then finalizes
  // the container before it removes the marker. The grace must outlive all of
  // that or a late expiry would re-open a menu the click already collapsed.
  // One deadline only: the real retirement edge is _refresh() seeing the file
  // reach the intended state.
  readonly property int _intentGraceMs: 8000

  function _publish() {
    Bus.publish("recording.bus", {
      ongoing: root.ongoing,
      startedAt: root.startedAtMs,
      confirmed: root.confirmed
    })
  }

  onOngoingChanged: root._publish()
  onConfirmedChanged: root._publish()

  // Bounded fallback for a helper that never changes the marker. The captured
  // id retires a late fire that belongs to an older click.
  Timer {
    id: intentExpiry
    property int intentId: -1
    interval: root._intentGraceMs
    onTriggered: {
      if (root.pendingIntent && root.pendingIntent.id === intentExpiry.intentId)
        root.pendingIntent = null
    }
  }

  // Menu provider surface: overlays recording-row semantics onto the
  // bundle-declared row by id. ProviderHost holds the surface under this
  // unit as owner and replays it when Menu registers as its host, so drain
  // order does not gate the row.
  function _registerMenuProvider() {
    ProviderHost.claimProvider("recording", {
      sub: () => root.shownOngoing ? "Select to stop recording" : null,
      confirm: () => root.shownOngoing ? {
        stages: 1,
        hint: "Press <b>Enter</b> again to stop recording",
        armed: "",
        label: "Stop recording",
        action: "recordingStop"
      } : null,
      runConfirm: () => { root.stop(); return true }
    }, root)
  }

  // Watch governor subscription
  property var _watchUnsub: null

  Component.onCompleted: {
    Registry.offer("recording", {
      title: "Recording",
      description: "screen recorder",
      verbNames: [
        "close",
        "open",
        "start",
        "stop",
        "toggle",
        "status",
        "help",
        "ping",
      ]
    })
    Registry.register("recording", root)
    root._registerMenuProvider()
    // Initial probe, then watcher keeps it live. The probe's result (and
    // the first bus payload) lands when the watcher fires.
    root._publish()
    root._refresh()
    // Watch governor - coalesced per tick, handles absent-file creation
    Qt.callLater(() => {
      root._watchUnsub = Watch.subscribe(Paths.vibraniumRuntime + "/recording-ongoing", (text) => {
        root._refresh()
      })
    })
  }
  Component.onDestruction: {
    // Teardown releases the provider id: the surface closes over this
    // root, so a survivor would keep a dead confirm closure.
    ProviderHost.unregisterProvider("recording", root)
    if (root._watchUnsub) root._watchUnsub()
    intentExpiry.stop()
    Bus.publish("recording.bus", {
      ongoing: false,
      startedAt: 0,
      confirmed: false
    })
    Registry.unregister("recording")
  }

  // Synchronous probe for imperative callers (keybind/shim) that need
  // an immediate answer without waiting for the watcher tick.
  FileView {
    id: probeFile
    printErrors: false
  }

  function _isVm(): bool {
    return Quickshell.env("CHASSIS_TYPE") === "vm"
  }

  function _syncOngoing(): bool {
    probeFile.path = ""
    probeFile.path = Paths.vibraniumRuntime + "/recording-ongoing"
    if (!probeFile.waitForJob()) return false
    return probeFile.text().trim() !== ""
  }

  function _setIntent(want) {
    root._intentSeq++
    root.pendingIntent = { want: want, since: Date.now(), id: root._intentSeq }
    intentExpiry.intentId = root._intentSeq
    intentExpiry.restart()
  }

  function _refresh() {
    const live = root._syncOngoing()
    // The file is the only writer of these values. A stale tick that lands
    // while the marker still exists re-reads the same state and publishes
    // nothing, instead of undoing the click's intent. No optimistic write is
    // left here, so the watcher needs no epoch guard.
    if (live !== root.ongoing) {
      root.startedAtMs = live ? Date.now() : 0
      root.ongoing = live
    }
    if (live !== root.confirmed) {
      root.confirmed = live
    }
    // A one-shot bridge: retire only when the file reaches the requested
    // state. The deadline in intentExpiry covers a helper that never does.
    const intent = root.pendingIntent
    if (intent && live === (intent.want === "start")) {
      root.pendingIntent = null
      intentExpiry.stop()
    }
  }

  function _notifyVm() {
    Exec.notify("Screen Recorder", "screen recording isn't available in a VM!")
  }

  function _stopOngoing() {
    const cmd = Paths.vibraniumHome + "/bin/vb-core-recording"
    Quickshell.execDetached([cmd, "--stop"])
    // Instant collapse comes from pendingIntent through shownOngoing. The
    // watcher owns the three file-backed values, so a coalesced tick during
    // finalization cannot publish stop -> start -> stop.
    root._setIntent("stop")
  }

  function _start() {
    const cmd = Paths.vibraniumHome + "/bin/vb-core-recording"
    Quickshell.execDetached([cmd])
    // Same route as stop: spawn, then record the click as a pending intent.
    root._setIntent("start")
  }

  // Public API --------------------------------------------------------------

  function start(): bool {
    if (root._isVm()) {
      root._notifyVm()
      return false
    }
    if (root._syncOngoing()) {
      return false
    }
    root._start()
    return true
  }

  function stop(): bool {
    if (!root._syncOngoing()) {
      return false
    }
    root._stopOngoing()
    return true
  }

  function toggle(): string {
    if (root._isVm()) {
      root._notifyVm()
      return "vm"
    }
    if (root._syncOngoing()) {
      root._stopOngoing()
      return "stop"
    }
    root._start()
    return "start"
  }

  // Direct start entry, also reachable over IPC as `recording open`.
  // CTRL+ALT+R drives `toggle` instead (binds.lua).
  function open(): bool {
    if (root._isVm()) {
      root._notifyVm()
      return false
    }
    if (root._syncOngoing()) {
      root._stopOngoing()
      return false
    }
    root._start()
    return true
  }

  function close(): bool {
    if (root._syncOngoing()) {
      root._stopOngoing()
      return true
    }
    return false
  }

  IpcHandler {
    target: "recording"
    function help(command: string): string {
      return UnitIpc.help("recording", "Recording", "screen recorder", [
        { name: "close", help: "hide the panel" },
        { name: "open", help: "show the panel" },
        { name: "start", help: "start recording" },
        { name: "stop", help: "stop recording" },
        { name: "toggle", help: "start/stop" },
      ], command)
    }
    function ping(): string { return "pong" }

    function start(): string {
      return root.start() ? "ok" : "error"
    }
    function stop(): string { return root.stop() ? "ok" : "error" }
    function toggle(): string { return root.toggle() }
    function open(): string { return root.open() ? "ok" : "error" }
    function close(): string { return root.close() ? "ok" : "error" }
    function status(): string {
      return JSON.stringify({
        vm: root._isVm(),
        ongoing: root.ongoing,
        confirmed: root.confirmed,
        live: root._syncOngoing()
      })
    }
  }
}
