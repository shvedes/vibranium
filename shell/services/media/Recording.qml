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

  // Live state - watched from the state file so both the shell and
  // external `vb-core-recording` invocations stay in sync.
  property bool ongoing: false
  property bool confirmed: false
  // Epoch ms when the current recording started (detection time for
  // external starts - the state file carries only the PID). Stamped
  // before `ongoing` flips so the bus payload always pairs them.
  property double startedAtMs: 0

  function _publish() {
    Bus.publish("recording.bus", {
      ongoing: root.ongoing,
      startedAt: root.startedAtMs,
      confirmed: root.confirmed
    })
  }

  onOngoingChanged: root._publish()
  onConfirmedChanged: root._publish()

  // Provider id ownership: ProviderHost hands a record to the host Menu
  // once and refuses a re-registration whose owner is a different object,
  // so a record is only ever replaceable by the object that owns it. This
  // unit owns `recording` for as long as it is alive and must release it
  // in its teardown; a refused id would otherwise pin the surface to a
  // dead closure and drop the row's confirm stage.
  function _claimProviderId(id, surface, deferred) {
    if (ProviderHost.registerProvider(id, surface, root)) return true
    ProviderHost.unregisterProvider(id, root)
    if (ProviderHost.registerProvider(id, surface, root)) return true
    // A predecessor that has not finalized yet still holds the id and
    // frees it only from its own teardown, which is itself a deferred
    // step, so a recreated unit gets one late attempt past this turn. The
    // id is bounded and re-entrant: this path can only ever claim a free
    // id, so a late miss is reported and never blocks a live owner.
    if (deferred) {
      DeferredQueue.run(() => { root._claimProviderId(id, surface, false) }, 2, 0, root.tag + " provider retry")
      return false
    }
    return false
  }

  // Menu provider surface: overlays recording-row semantics onto the
  // bundle-declared row by id. ProviderHost holds the surface under this
  // unit as owner and replays it when Menu registers as its host, so drain
  // order does not gate the row.
  function _registerMenuProvider() {
    root._claimProviderId("recording", {
      sub: () => root.ongoing ? "Select to stop recording" : null,
      confirm: () => root.ongoing ? {
        stages: 1,
        hint: "Press <b>Enter</b> again to stop recording",
        armed: "",
        label: "Stop recording",
        action: "recordingStop"
      } : null,
      runConfirm: () => { root.stop(); return true }
    }, false)
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

  function _refresh() {
    const live = root._syncOngoing()
    if (live !== root.ongoing) {
      root.startedAtMs = live ? Date.now() : 0
      root.ongoing = live
    }
    if (live !== root.confirmed) {
      root.confirmed = live
    }
  }

  function _notifyVm() {
    Quickshell.execDetached(["notify-send", "Screen Recorder", "screen recording isn't available in a VM!"])
  }

  function _stopOngoing() {
    const cmd = Paths.vibraniumHome + "/bin/vb-core-recording"
    Quickshell.execDetached([cmd, "--stop"])
    // Optimistic - watcher will confirm via file disappearance, but
    // the menu's guard re-evaluates on a timer (Menu.refreshGuards)
    // and the toggle's checked is file-based, so immediate UI
    // feedback comes from the optimistic guard stamp in Entry.qml
    // (like caffeine/timer). We also flip here so the dropdown
    // collapses instantly even before the file watcher fires.
    root.startedAtMs = 0
    root.ongoing = false
  }

  function _start() {
    const cmd = Paths.vibraniumHome + "/bin/vb-core-recording"
    Quickshell.execDetached([cmd])
    // Optimistic - file will appear shortly; watcher will confirm.
    root.startedAtMs = Date.now()
    root.ongoing = true
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
