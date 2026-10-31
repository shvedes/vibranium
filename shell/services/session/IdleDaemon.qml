pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
// qs.services exports a Timer singleton, and the later unaliased import
// shadows QtQml's, so the settle probe names its timer through the alias.
import QtQml as QtQmlTypes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.common
import qs.services
import "../../common/text/UnitIpc.js" as UnitIpc

// Internal idle daemon. Config lives in the settings store under
// shell.idle (validated and persisted by Settings); this singleton owns
// the Wayland idle monitors and the firing order. Two monitor policies
// share one idle epoch: a policy monitor per configured timer carries
// the threshold and honors inhibitors, and a single activity monitor
// with timeout 0 and no inhibitor policy is the only source of a
// user-activity edge. A real edge bumps the epoch and re-arms both sets;
// an action the fire path accepts is spent for that epoch, and one an
// inhibitor blocks is not.
Singleton {
  id: root

  readonly property string tag: "idle"

  // Validated configuration surface from the settings store; both re-run
  // on any store mutation so the daemon always tracks persisted state.
  readonly property bool enabled: Settings.idleEnabled
  readonly property var timers: Settings.idleTimers

  // Idle epoch - bumped on every rebuild (settings write) and on user
  // activity. Fired rows remember the epoch they ran in, so stale
  // callbacks and double fires are impossible.
  property int epoch: 0
  property var fired: ({})

  // Live policy monitors, one per configured timer, plus the single
  // activity monitor, populated only while the daemon is enabled.
  // Replaced wholesale on rebuild so stale monitors (and their
  // callbacks) are destroyed with the old set.
  property var _monitors: []
  property var _activity: null

  // Protocol state: "unknown" while nothing is armed, so the protocol was
  // never measured; "probing" while the armed monitors wait for their
  // first report; "ext-idle-notify-v1" once a current monitor has
  // reported; and "unavailable" when the settle window closed with
  // nothing. An action can only be dispatched from a report, so a
  // compositor without the protocol cannot fire a timer. Only a measured
  // absence is a fault: a daemon that was never armed says nothing about
  // the compositor, and reporting it as unavailable would name a fault
  // that was never looked for.
  readonly property string capability: root._capability
  readonly property bool available: root._capability === "ext-idle-notify-v1"
  readonly property bool degraded: root._capability === "unavailable"
  property string _capability: "unknown"
  readonly property int _settleMs: 3000

  // Activity bookkeeping for the current arm: the last state the
  // activity monitor reported, and whether that arm still owes its
  // baseline report. Only a true -> false transition beyond that
  // baseline is a user edge, so a re-armed monitor's re-enable report
  // cannot fabricate one.
  property bool _activityIdle: true
  property bool _activityBaseline: true

  // Ceiling on one command action. A timer command is user text, so the
  // job is bounded rather than trusted: past the ceiling the job settles
  // as a timeout and the row is reported, never left running.
  readonly property int _commandTimeoutMs: 120000

  // Config signature: string equality means monitors are rearmed only
  // when the idle config actually changed, never on unrelated store
  // churn (every settings mutation bumps the shared rev).
  readonly property string _cfgSig: {
    Settings.rev
    return JSON.stringify({
      enabled: Settings.idleEnabled,
      timers: Settings.idleTimers
    })
  }
  on_CfgSigChanged: root.rebuild()

  Component.onCompleted: {
    Registry.offer("idleDaemon", {
      title: "Idle daemon",
      description: "idle timers + actions",
      verbNames: [
        "add",
        "addFull",
        "remove",
        "set",
        "setAction",
        "setClass",
        "setCommand",
        "setEnabled",
        "setMinutes",
        "status",
        "help",
        "ping",
      ]
    })
    Registry.register(root.tag, root)
    ProviderHost.registerProvider("idle-add", {
      runFlow: (item, values) => root.commitAddWizard(item, values)
    }, root)
    root.rebuild()
  }
  Component.onDestruction: {
    ProviderHost.unregisterProvider("idle-add", root)
    Registry.unregister(root.tag)
  }

  // Rebuild monitors after a settings write: new epoch, cleared fired
  // map, fresh row objects (destroys the old IdleMonitors).
  function rebuild() {
    root.epoch += 1
    root.fired = {}
    root._setRows()
    root._injectPage()
  }

  function _setRows() {
    // Old monitors die first: their callbacks cannot outlive a rebuild.
    const stale = root._monitors
    const staleActivity = root._activity
    root._monitors = []
    root._activity = null
    for (let i = 0; i < stale.length; i++) stale[i].destroy()
    if (staleActivity !== null) staleActivity.destroy()
    if (!root.enabled || root.timers.length === 0) {
      // Nothing is armed, so there is no probe to run and the capability
      // keeps the value its last arm established.
      settleWatch.stop()
      return
    }
    const monitors = []
    for (let i = 0; i < root.timers.length; i++) {
      const t = root.timers[i]
      const m = monitorComp.createObject(root, {
        rowIndex: i,
        rowEpoch: root.epoch,
        timeout: t.minutes * 60
      })
      monitors.push(m)
    }
    root._monitors = monitors
    // One activity monitor per arm: timeout 0 makes the compositor treat
    // the session as idle at once, so every reset it sends is a real
    // input edge, and respectInhibitors false keeps an inhibitor change
    // out of the only signal that counts as user activity.
    root._activity = activityComp.createObject(root, {
      timeout: 0,
      respectInhibitors: false
    })
    // A fresh monitor is treated as idle with its first report still owed:
    // a timeout-0 monitor is idle the moment the compositor answers, so
    // that report lands at arm time and an input edge is never mistaken
    // for it.
    root._activityIdle = true
    root._activityBaseline = true
    root._capability = "probing"
    settleWatch.restart()
  }

  // One idle threshold expired for `index`. The row and the epoch
  // captured at arm time are checked, the authoritative inhibitor is
  // asked, the action goes to its own contract, and only an accepted
  // action is spent - a blocked row is never marked, so it stays
  // eligible for the next activity edge or rebuild epoch.
  function fire(index, capturedEpoch) {
    if (!root.enabled || capturedEpoch !== root.epoch) return
    const key = String(index)
    const row = root.timers[index]
    if (!row || root.fired[key] === capturedEpoch) return
    const meta = root._actionMeta(row)
    if (root._blocked(meta)) {
      // Held, not spent: the row stays eligible, so the next activity edge
      // re-arms it and it fires then.
      return
    }
    // Asked and refused to run: the row was not marked, so it retries on the
    // next epoch exactly as if it had never been reached.
    if (!root._accept(meta, row)) return
    root.fired[key] = capturedEpoch
  }

  // Action metadata for one stored row: an explicit kind plus the class a
  // command row may declare. A command is never reclassified by reading
  // its text - an arbitrary string says nothing about what it does to the
  // session - so only a declared class reaches the inhibitor guard. The
  // store fills a class for the project's own session verbs on read
  // (SettingsLib.normalizeIdleTimers), and the Add wizard and `setClass`
  // write one directly; everything else stays undeclared and ungated.
  function _actionMeta(row) {
    if (row.action === "lock") return { kind: "lock", commandClass: "" }
    if (row.action === "suspend") return { kind: "suspend", commandClass: "" }
    const declared = String(row.commandClass === undefined || row.commandClass === null
      ? ""
      : row.commandClass)
    return {
      kind: "command",
      commandClass: declared === "lock" || declared === "suspend" ? declared : ""
    }
  }

  // Both project actions honor logind's inhibitor registry: the Wayland
  // idle monitor knows nothing about login1 inhibitor locks, so without
  // this guard caffeine (an "idle" block lock) could not stop an idle timer
  // from locking or suspending the session. A command is guarded by the
  // class its row declares and by nothing else.
  function _blocked(meta) {
    if (meta.kind === "suspend" || meta.commandClass === "suspend") return Inhibitor.sleepBlocked()
    if (meta.kind === "lock" || meta.commandClass === "lock") return Inhibitor.idleBlocked()
    return false
  }

  // Lock owns music pause/auth through Lockscreen; suspend goes through
  // Session.suspend() (locks first, then systemctl suspend). Both are the
  // project's own actions and both accept, so the caller spends the row. A
  // command accepts when the job layer owns it and refuses when there is
  // no text to run or no job to run it in, which leaves the row eligible.
  //
  // The `via=idle` on both calls is what tells a lock the daemon asked for
  // apart from a lock a menu row or a script asked for.
  function _accept(meta, row) {
    if (meta.kind === "lock") {
      Session.lock("idle", "idle")
      return true
    }
    if (meta.kind === "suspend") {
      Session.suspend("idle")
      return true
    }
    return root._runCommand(row.command)
  }

  // Run a user-configured command action as one owned job. An empty
  // command is a transitional store state with nothing to run, so it is
  // skipped instead of spawning a bare shell. The command is
  // user-authored shell source, and its failure is reported as the job's
  // stable code and exit code: neither the command nor its output ever
  // reaches a notification or an IPC result.
  function _runCommand(cmd) {
    const c = String(cmd ?? "").trim()
    if (c === "") return false
    let job = null
    try {
      job = ProcessRegistry.start(["/bin/bash", "-c", c], root.tag + ":command", {
        maxAttempts: 1,
        timeoutMs: root._commandTimeoutMs,
        onFinished: result => root._onCommandSettled(result),
        onFailed: reason => root._reportFailure(String(reason), -1)
      })
    } catch (ignored) {
      job = null
    }
    if (job === null) {
      root._reportFailure("spawn_refused", -1)
      return false
    }
    return true
  }

  // A settled job that never delivered the command - destroyed with the
  // daemon, cancelled with a rebuild - is a lifecycle outcome, not a
  // fault worth a notification.
  function _onCommandSettled(result) {
    if (result === null || result === undefined) return
    const code = String(result.code)
    if (code === "ok" || code === "cancelled" || code === "destroyed") return
    root._reportFailure(code, Number(result.exitCode))
  }

  // Bounded failure bubble: the job code and the numeric exit status,
  // which are the only parts of a failed command that carry nothing the
  // user typed.
  function _reportFailure(code, exitCode) {
    const suffix = exitCode >= 0 ? " (exit " + String(exitCode) + ")" : ""
    Exec.run([
      "notify-send", "-a", "Vibranium", "-u", "critical", "-t", "8000",
      "Idle timer command failed",
      "Outcome: " + code + suffix
    ])
  }

  // Any report from a current monitor proves the compositor speaks
  // ext-idle-notify-v1, which is the only channel this daemon has: the
  // monitor reports idle time and nothing finer, so key, pointer, and
  // touch input stay unobservable here.
  function _proveProtocol() {
    if (root._capability === "ext-idle-notify-v1") return
    root._capability = "ext-idle-notify-v1"
    settleWatch.stop()
  }

  // The settle window closed with no report from any armed monitor: the
  // compositor does not implement the protocol, so the daemon reports
  // unavailable and stays armed but silent. The next rebuild probes
  // again, so a compositor change recovers without a shell restart.
  function _onSettleTimeout() {
    if (root._capability === "ext-idle-notify-v1") return
    root._capability = "unavailable"
  }

  QtQmlTypes.Timer {
    id: settleWatch
    interval: root._settleMs
    repeat: false
    onTriggered: root._onSettleTimeout()
  }

  // A real user-activity edge, and only that: the armed activity monitor
  // reports it, a retired one is dropped, the first report of a fresh arm
  // is only its baseline, and a repeated state is not a transition. An
  // inhibitor change moves a policy monitor's isIdle but cannot move
  // this one, so it can never reach here.
  function _onActivityReport(monitor, isIdle) {
    if (monitor !== root._activity) return
    root._proveProtocol()
    if (root._activityBaseline) {
      root._activityBaseline = false
      root._activityIdle = isIdle
      return
    }
    if (isIdle === root._activityIdle) return
    root._activityIdle = isIdle
    if (isIdle) return
    root._onActivity()
  }

  // A real activity transition: a new epoch, a cleared fired map, and a
  // fresh monitor set. Re-arming is what invalidates the retired
  // monitors' pending callbacks - fire() drops any callback whose epoch
  // is spent, and the retired activity monitor is not the armed one.
  //
  // This is the resume path, and the one place a timer can silently stop
  // being able to fire: a disabled daemon returns here without re-arming,
  // which is correct.
  function _onActivity() {
    if (!root.enabled) return
    root.epoch += 1
    root.fired = {}
    root._setRows()
  }

  // One live IdleMonitor per timer row, created and destroyed by
  // _setRows. Each object captures its row index and the epoch it was
  // created under; the checks at fire time drop any callback that
  // outlived its monitor (rebuild destroys the object anyway - this is
  // the second half of the same guarantee). The threshold policy honors
  // inhibitors, so its own isIdle can move without any user input.
  Component {
    id: monitorComp

    IdleMonitor {
      // Quickshell IdleMonitor counts in seconds, so minutes convert
      // once here at arm time; the UI and store stay minute-based.
      property int rowIndex: 0
      property int rowEpoch: 0
      respectInhibitors: true

      onIsIdleChanged: {
        if (!isIdle) return
        root._proveProtocol()
        if (root.enabled && root.epoch === rowEpoch)
          root.fire(rowIndex, rowEpoch)
      }
    }
  }

  // The activity monitor carries no threshold and no inhibitor policy:
  // its only job is the input edge, which is why its handler reads the
  // armed object instead of trusting the signal alone.
  Component {
    id: activityComp

    IdleMonitor {
      id: activityMonitor
      timeout: 0
      respectInhibitors: false

      onIsIdleChanged: root._onActivityReport(activityMonitor, isIdle)
    }
  }

  // --- settings page ----
  //
  // Shadow page for the schema's "idle" entry: the schema page owns the
  // index link and the enabled toggle, this injected page renders the
  // live timer list. Re-injected on every rebuild so an add/remove/edit
  // shows up (or disappears) while the menu is open. Rows are plain:
  // toggle, one info-only reference row per timer (command with minutes
  // on the accent tail, Delete/Ctrl+D removes with confirmation), then
  // a separator and the Add timer row - no editable rows at all.
  //
  // The timer list is the page's content and is listed whether the daemon
  // runs or not: the toggle on top says which of the two it is, and a list
  // that vanished with the toggle left the page empty for every session
  // with the daemon off - the timers were configured, they were just never
  // on screen. The page therefore carries no visibility condition of its
  // own. The menu reads a condition in the store's normalized shape, and a
  // condition written in any other shape never fires, so a row that looks
  // conditional and behaves unconditionally is worse than no condition at
  // all.
  property string _lastInjectSig: ""
  function _injectPage() {
    // Pure function of the capability and the timer list, declared class
    // included: skip when identical content is already published (boot
    // calls rebuild() then _injectPage() back to back). A discarded page
    // table drops the signature, so the next attempt always rebuilds.
    const sig = root.capability + "|" + root.timers.map(t =>
      t.minutes + ":" + t.action + ":" + (t.command || "") + ":" + (t.commandClass || "")
    ).join(",")
    if (sig === root._lastInjectSig) return
    const items = []

    items.push({
      type: "toggle",
      var: "shell.idle.enabled",
      label: "Idle daemon",
      sub: "Lock and suspend automatically"
    })
    // A compositor without the idle protocol leaves the daemon armed and
    // silent, so the page says so instead of presenting timers that can
    // never fire. The capability is part of the inject signature, so the
    // state appears on the next injection rather than only at boot.
    if (root.degraded) {
      items.push({
        type: "expandable",
        id: "idle-unavailable",
        label: "Idle timers unavailable",
        subLead: "No idle time is reported",
        sub: "",
        body: "",
        desc: "The compositor does not implement ext-idle-notify-v1, so no timer can fire",
        infoOnly: true
      })
    }
    for (let i = 0; i < root.timers.length; i++) {
      const t = root.timers[i]
      // Reference rows, not controls: click/Enter never expands (infoOnly),
      // ctrl+i shows the generic line. Titles carry the minutes beside them
      // ("Timer 1 (in 15 minutes)"); the command rides the leading accent
      // slot full-width, no faint copy. The base sub states what decides
      // the row: the inhibitor guard covers it, or the daemon is off and
      // nothing fires at all. A daemon that is off outranks the inhibitor
      // state - a timer it never arms is not held back by anything, it
      // simply does not run.
      const isCmd = t.action === "command"
      const cmd = isCmd ? t.command.trim() : ""
      const meta = root._actionMeta(t)
      const gate = meta.kind === "lock" || meta.commandClass === "lock"
        ? "held back by the idle inhibitor"
        : meta.kind === "suspend" || meta.commandClass === "suspend"
          ? "held back by the sleep inhibitor" : ""
      const sub = !root.enabled ? "the daemon is off"
        : (gate === "" ? "not held back by inhibitors" : gate)
      items.push({
        type: "expandable",
        id: "timer-" + t.minutes,
        label: "Timer " + (i + 1) + " (in " + t.minutes + " minutes)",
        subLead: isCmd ? (cmd !== "" ? cmd : "Run command - not set")
          : t.action === "lock" ? "Lock session" : "Suspend",
        sub: sub,
        body: "",
        desc: (isCmd ? "Run command " + (cmd !== "" ? cmd : "- not set") : "")
          + (isCmd && sub !== "" ? " - " : "") + sub,
        infoOnly: true,
        delCommand: "qs -p \"$VIBRANIUM/shell\" ipc call idle remove " + i
      })
    }
    items.push({
      type: "separator",
      id: "idle-sep"
    })
    // Staged Add wizard: minutes, then the command to run. Every timer is
    // a command - there is no action stage to pick from, so a new timer
    // cannot be a bare lock or suspend row and the command's own text is
    // the whole of what the timer does. The inhibitor guard reads the
    // class that command declares: the project's own session verbs
    // declare themselves on read, anything else declares nothing and is
    // never held back. The final commit carries every stage at once; the
    // menu stays open so several timers can be added in a row.
    let minMinutes = 1
    for (let u = 0; u < root.timers.length; u++) {
      // Timers are strictly increasing, so a new one must fire later than
      // every existing entry - the picker cannot offer a sooner minute.
      if (root.timers[u].minutes + 1 > minMinutes) minMinutes = root.timers[u].minutes + 1
    }
    // No valid minute left (a timer already sits at the 10080 cap): clamp
    // so the picker never builds an inverted range; the commit validation
    // still rejects anything that breaks the increasing order.
    if (minMinutes > 10080) minMinutes = 10080
    items.push({
      type: "select",
      id: "idle-add",
      label: "Add timer",
      sub: "Add new idle timer",
      value: minMinutes,
      marker: false,
      keepOpen: true,
      hideValue: true,
      // The row's own placeholder is the hint the command field shows and
      // the words the row is found by; the stage declares the same one, so
      // the two never disagree.
      placeholder: "e.g. vb-shell session lock",
      flow: [
        // Base sub stays identical to the collapsed copy on every stage:
        // only the accent tail flips per step. A flipping base sub proved
        // fragile across the collapse transition (settled visible=false
        // with healthy text), while accent flips land every time - so the
        // narration rides the tail and the base never moves.
        { kind: "number", min: minMinutes, max: 10080, step: 1, unit: "min", sub: "Add new idle timer", subAccent: "Trigger in..." },
        { kind: "text", placeholder: "e.g. vb-shell session lock", sub: "Add new idle timer", subAccent: "Command to run on trigger..." }
      ],
      onCall: "idle addFull %v"
    })
    // The signature is committed only once the page is registered, or held for
    // a surface that has not appeared yet. A refused page keeps no signature,
    // so the next rebuild tries again instead of remembering a page that is
    // not there.
    const answer = PageHost.publish({
      id: "idle",
      title: "Idle",
      width: 340,
      items: items
    })
    if (answer.ok || answer.code === "no_surface") root._lastInjectSig = sig
  }

  // A new page container generation discards every published page, so a cold
  // menu open would show the schema page (toggle only) without the timer
  // rows. The signature is dropped and the page republished one tick after the
  // surface reports the discard, after the load sequence has finished.
  Connections {
    target: PageHost

    function onPagesDropped() {
      root._lastInjectSig = ""
      Qt.callLater(root._injectPage)
    }
  }

  // --- settings mutations ----

  function _commitTimers(next) {
    const had = root.timers.length
    const err = Settings.setIdleTimers(next)
    if (err !== "") return "error: " + err
    // QoL invariant, implicit paths only (explicit set/setEnabled verbs
    // honor their flags verbatim): removing the last timer switches the
    // daemon off, adding the first switches it back on - otherwise a
    // re-added timer would sit listed and disarmed.
    if (next.length === 0 && had > 0 && root.enabled) {
      Settings.setIdleEnabled(false)
    } else if (next.length > had && !root.enabled) {
      Settings.setIdleEnabled(true)
    }
    return "ok"
  }

  // --- actions ----
  //
  // Callable on the singleton root because the menu's onCall/editCall
  // route through the Registry hub (Registry.call resolves methods on
  // the registered object, not on the IpcHandler below). The IpcHandler
  // serves the external `qs ipc call` CLI and wraps these same methods.

  function setAction(index, action) {
    const i = Number(index)
    const a = action === "lock" || action === "suspend" || action === "command"
      ? action : ""
    if (!(Number.isInteger(i) && i >= 0 && i < root.timers.length)) {
      return "error: no timer at index " + index
    }
    if (a === "") {
      return "error: action must be lock, suspend or command"
    }
    const next = root.timers.slice()
    // Switching away from a command row drops its command and the class it
    // declared - the action is the declaration now. Arming a command row
    // keeps any text already collected so the transition is lossless, and
    // keeps a declared class only while the text still is what it was
    // declared for, so the guard can never outlive its reason.
    const row = { minutes: next[i].minutes, action: a }
    if (a === "command") {
      row.command = next[i].command !== undefined ? next[i].command : ""
      const declared = String(next[i].commandClass ?? "")
      if (declared === "lock" || declared === "suspend")
        row.commandClass = declared
    }
    next[i] = row
    const err = root._commitTimers(next)
    if (err !== "") return err
    return "ok"
  }

  // Set (or replace) the command a timer runs; arming the action too
  // so a typed command always fires. A class already declared on the row
  // survives, because the text is still the text that was declared.
  function setCommand(index, command) {
    const i = Number(index)
    const c = String(command ?? "")
    if (!(Number.isInteger(i) && i >= 0 && i < root.timers.length)) {
      return "error: no timer at index " + index
    }
    if (c.trim() === "") {
      return "error: command cannot be empty"
    }
    const next = root.timers.slice()
    const row = { minutes: next[i].minutes, action: "command", command: c }
    const declared = String(next[i].commandClass ?? "")
    if (declared === "lock" || declared === "suspend") row.commandClass = declared
    next[i] = row
    const err = root._commitTimers(next)
    if (err !== "") return err
    return "ok"
  }

  // Declare what a command timer does to the session, which is the only
  // thing the inhibitor guard reads. "lock" consults the idle blockers,
  // "suspend" the sleep blockers, "none" clears the declaration and leaves
  // the timer ungated. A lock/suspend row already declares its effect as
  // its action, so declaring a class there is refused rather than silently
  // ignored.
  function setClass(index, cls) {
    const i = Number(index)
    if (!(Number.isInteger(i) && i >= 0 && i < root.timers.length)) {
      return "error: no timer at index " + index
    }
    const c = String(cls ?? "").trim()
    const value = c === "none" || c === "clear" ? "" : c
    if (value !== "" && value !== "lock" && value !== "suspend") {
      return "error: class must be lock, suspend or none"
    }
    const row = root.timers[i]
    if (row.action !== "command") {
      return "error: timer " + index + " is a " + row.action + " timer, its action is the declaration"
    }
    if (value === "" && Settings.declaresOwnCommand(row.command)) {
      return "error: '" + String(row.command).trim()
        + "' is one of Vibranium's own session verbs, so it stays declared"
    }
    const next = root.timers.slice()
    const written = { minutes: next[i].minutes, action: "command", command: next[i].command }
    if (value !== "") written.commandClass = value
    next[i] = written
    const err = root._commitTimers(next)
    if (err !== "") return err
    return "ok"
  }

  // Registry-routed entry point for the Add wizard's onCall template:
  // Menu.runCall resolves methods on the registered singleton root, not
  // on the IpcHandler below (same reason setAction/setCommand live up
  // here). Without this, "idle addFull ..." logs "not callable" and the
  // pick silently does nothing.
  function addFull(minutes, action, command, cls) {
    const m = Number(String(minutes).trim().split(/\s+/)[0])
    if (!(Number.isInteger(m) && m >= 1 && m <= 10080)) {
      return "error: minutes must be an integer 1..10080"
    }
    if (action !== "lock" && action !== "suspend" && action !== "command") {
      return "error: action must be lock, suspend or command"
    }
    const c = String(cls ?? "").trim()
    if (c !== "" && c !== "lock" && c !== "suspend") {
      return "error: class must be lock or suspend"
    }
    if (action !== "command" && c !== "") {
      return "error: a " + action + " timer declares its action, not a class"
    }
    const next = root.timers.slice()
    if (action === "command") {
      const text = String(command ?? "").trim()
      if (text === "") {
        return "error: command cannot be empty"
      }
      const row = { minutes: m, action: action, command: text }
      if (c !== "") row.commandClass = c
      next.push(row)
    } else {
      next.push({ minutes: m, action: action })
    }
    const err = root._commitTimers(next)
    if (err !== "") return err
    return "ok"
  }

  // Staged Add wizard commit. `values` maps stage index -> committed
  // value: the minutes text first ("15 min" or "15"), then the command
  // text. The text stage is located by kind so layout shifts stay safe,
  // and a missing text value means the stage was skipped rather than left
  // empty. Every timer is a command - the wizard has no action stage - so
  // the row is always a command row, and the class its command declares
  // is the one the read path fills. Returns true to swallow Entry's
  // generic commit path. `item` arrives as the pristine page row so the
  // stage layout is readable even though delegates may carry a converted
  // copy.
  function commitAddWizard(item, values) {
    const minutesRaw = String(values["0"] ?? "").trim().split(/\s+/)[0]
    const m = Number(minutesRaw)
    if (!(Number.isInteger(m) && m >= 1 && m <= 10080)) return true
    let textIdx = -1
    const stages = (item && Array.isArray(item.flow)) ? item.flow : []
    for (let s = 0; s < stages.length; s++) {
      if (!stages[s]) continue
      if (stages[s].kind === "text") textIdx = s
    }
    const command = textIdx >= 0 ? String(values[String(textIdx)] ?? "").trim() : ""
    if (command === "") return true
    const next = root.timers.slice()
    next.push({ minutes: m, action: "command", command: command })
    // The picker offers a strictly increasing range, so a wizard add can
    // still be rejected by the store - and this path returns true and shows
    // nothing.
    const err = Settings.validateIdleTimers(next)
    if (err !== "") return true
    const committed = root._commitTimers(next)
    if (committed !== "ok") return true
    return true
  }

  // --- ipc ----

  IpcHandler {
    target: "idle"
    function help(command: string): string {
      return UnitIpc.help("idle", "Idle daemon", "idle timers + actions", [
        { name: "add", help: "(minutes, action) add a timer" },
        { name: "addFull", help: "(minutes, action, [command], [cls]) staged add" },
        { name: "remove", help: "(index) remove a timer" },
        { name: "set", help: "(json) replace the timer list" },
        { name: "setAction", help: "(index, action) set an action" },
        { name: "setClass", help: "(index, class) declare a command's effect: lock, suspend, none" },
        { name: "setCommand", help: "(index, command) set a command" },
        { name: "setEnabled", help: "(v) enable/disable the daemon" },
        { name: "setMinutes", help: "(index, minutes) retime a timer" },
      ], command)
    }
    function ping(): string { return "pong" }

    function status(): string {
      return JSON.stringify({
        enabled: root.enabled,
        epoch: root.epoch,
        capability: root.capability,
        degraded: root.degraded,
        timers: root.timers
      })
    }

    // Full config replace: {"enabled": true, "timers": [...]}. Validated
    // atomically - a rejected value leaves the prior config unchanged.
    function set(json: string): string {
      let cfg
      try {
        cfg = JSON.parse(json)
      } catch (e) {
        return "error: invalid JSON"
      }
      if (typeof cfg !== "object" || cfg === null || Array.isArray(cfg)) {
        return "error: config must be an object"
      }
      if (cfg.enabled !== true && cfg.enabled !== false) {
        return "error: enabled must be true or false"
      }
      const list = Array.isArray(cfg.timers) ? cfg.timers : []
      const err = Settings.validateIdleTimers(list)
      if (err !== "") return "error: " + err
      if (cfg.enabled) {
        // Enabling with timers first, so the empty-while-enabled rule
        // never has a window to reject the order.
        const r1 = Settings.setIdleTimers(list)
        if (r1 !== "") return "error: " + r1
        const r2 = Settings.setIdleEnabled(true)
        if (r2 !== "") return "error: " + r2
      } else {
        // Disable first - an empty timer list is legal only while off.
        const r1 = Settings.setIdleEnabled(false)
        if (r1 !== "") return "error: " + r1
        const r2 = Settings.setIdleTimers(list)
        if (r2 !== "") return "error: " + r2
      }
      return "ok"
    }

    // An explicit enable or disable, from a caller that named it rather than
    // arriving through the remove-a-timer QoL rule.
    function setEnabled(v: string): string {
      if (v !== "true" && v !== "false") {
        return "error: enabled must be true or false"
      }
      const err = Settings.setIdleEnabled(v === "true")
      if (err !== "") return "error: " + err
      return "ok"
    }

    // Append a timer strictly longer than the current last one. The
    // menu's picker commits "N min" (unit suffix inside the field), so
    // the leading integer is parsed; bare integers keep working.
    function add(minutes: string, action: string): string {
      const m = Number(String(minutes).trim().split(/\s+/)[0])
      if (!(Number.isInteger(m) && m > 0)) {
        return "error: minutes must be a positive integer"
      }
      const a = action === "lock" || action === "suspend" ? action : ""
      if (a === "") {
        return "error: action must be lock or suspend"
      }
      const next = root.timers.slice()
      next.push({ minutes: m, action: a })
      const err = root._commitTimers(next)
      if (err !== "") return err
      return "ok"
    }

    // Scripted twin of the Add wizard: addFull <minutes> <action>
    // [command...] [class]. Command required (non-empty) for command
    // timers, forbidden otherwise; the class declares a command timer's
    // effect for the inhibitor guard. Same validation as the wizard
    // commit.
    function addFull(minutes: string, action: string, command: string, cls: string): string {
      return root.addFull(minutes, action, command, cls)
    }

    // Remove by index. Every timer can go, even the last one - an
    // enabled daemon with an empty list simply arms nothing.
    function remove(index: string): string {
      const i = Number(index)
      if (!(Number.isInteger(i) && i >= 0 && i < root.timers.length)) {
        return "error: no timer at index " + index
      }
      const next = root.timers.slice()
      next.splice(i, 1)
      const err = root._commitTimers(next)
      if (err !== "") return err
      return "ok"
    }

    function setMinutes(index: string, minutes: string): string {
      const i = Number(index)
      const m = Number(minutes)
      if (!(Number.isInteger(i) && i >= 0 && i < root.timers.length)) {
        return "error: no timer at index " + index
      }
      if (!(Number.isInteger(m) && m > 0)) {
        return "error: minutes must be a positive integer"
      }
      const next = root.timers.slice()
      // Retiming must not change what the row does: the command and a
      // declared class ride along, or a retimed timer would fire an empty
      // command or lose its inhibitor guard.
      const row = { minutes: m, action: next[i].action }
      if (next[i].action === "command") {
        row.command = next[i].command
        const declared = String(next[i].commandClass ?? "")
        if (declared === "lock" || declared === "suspend") row.commandClass = declared
      }
      next[i] = row
      const err = root._commitTimers(next)
      if (err !== "") return err
      return "ok"
    }

    function setAction(index: string, action: string): string {
      return root.setAction(index, action)
    }

    function setCommand(index: string, command: string): string {
      return root.setCommand(index, command)
    }

    function setClass(index: string, cls: string): string {
      return root.setClass(index, cls)
    }
  }
}
