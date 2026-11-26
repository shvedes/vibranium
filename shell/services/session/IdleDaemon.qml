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
import "../../common/text/IpcCatalog.js" as IpcCatalog

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

  // One compositor readback is a single short-lived child, so it needs only a
  // ceiling that bounds a wedged hyprctl; it never retries.
  readonly property int _inhibitorProbeMs: 2000

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
    Registry.offer("idle", {
      title: "Idle",
      description: "Manage idle timers and actions",
      verbNames: IpcCatalog.topLevelVerbs("idle")
    })
    Registry.register(root.tag, root)
    IpcRouter.register("idle", root, {
      "idle.enable": function () { return root._enable(true) },
      "idle.disable": function () { return root._enable(false) },
      "idle.reload": function () { return root._reload() },
      "idle.list": function () { return root._list() },
      "idle.add": function (a) { return root._add(a.SECONDS, a.COMMAND) },
      "idle.remove": function (a) { return root._remove(a.ID) },
      "idle.class": function (a) { return root._setClassRow(a.ID, a.CLASS) },
      "idle.status": function () { return root._status() },
      "idle.ping": function () { return root._ok("pong", { kind: "text" }) }
    })
    ProviderHost.registerProvider("idle-add", {
      runFlow: (item, values) => root.commitAddWizard(item, values)
    }, root)
    root.rebuild()
  }
  Component.onDestruction: {
    IpcRouter.unregister("idle", root)
    ProviderHost.unregisterProvider("idle-add", root)
    Registry.unregister(root.tag)
  }

  // Rebuild monitors after a settings write: new epoch, cleared fired
  // map, fresh row objects (destroys the old IdleMonitors). A pending
  // compositor probe belongs to the retired arm and can no longer dispatch
  // an action under the new epoch.
  function rebuild() {
    root.epoch += 1
    root.fired = {}
    root._probePending = null
    root._setRows()
    root._injectPage()
  }

  // The compositor's `timeout` is seconds. A row that reaches here without a
  // finite positive integer is never armed: an undefined/NaN/0 threshold makes
  // an IdleMonitor report idle on the first event, which would run whatever
  // action the row carries (including a suspend command) within a fraction of
  // a second of boot or an unlock. Settings.idleTimers only publishes canonical
  // rows, but this is the last gate before a destructive action, so refuse a
  // malformed row rather than coerce it into a zero.
  function _armTimeout(row) {
    if (!row || typeof row !== "object") return -1
    // Only the canonical field is admissible here. Settings.idleTimers owns
    // the conversion of legacy minutes rows; a row with minutes or with both
    // fields never reached that conversion and must not be armed in a hurry.
    if (!Object.prototype.hasOwnProperty.call(row, "seconds")
      || Object.prototype.hasOwnProperty.call(row, "minutes")) return -1
    const s = row.seconds
    if (typeof s !== "number" || !isFinite(s) || s < 1 || Math.floor(s) !== s) return -1
    return s
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
      const timeout = root._armTimeout(root.timers[i])
      if (timeout < 0) {
        Log.at("idle").warn("refusing a timer without a positive integer seconds value")
        continue
      }
      const m = monitorComp.createObject(root, {
        rowIndex: i,
        rowEpoch: root.epoch,
        timeout: timeout
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
    // A row without a canonical seconds value cannot be armed (see
    // _armTimeout); a callback that outlived a retired generation must not
    // find a different row at the same index and run it either.
    if (root._armTimeout(row) < 0) return
    const meta = root._actionMeta(row)
    if (root._blocked(meta)) {
      // Held, not spent: the row stays eligible, so the next activity edge
      // re-arms it and it fires then.
      return
    }
    // A session action has a second source to ask. The D-Bus registries above
    // only see applications that inhibited over D-Bus, while a browser playing
    // a video asks for the same thing through the Wayland idle-inhibit
    // protocol: no bus name, no queryable object, and whether it suppresses an
    // idle notification is the compositor's decision. The compositor's own
    // client list carries the answer, so a lock or suspend asks it before it
    // runs instead of trusting the monitor's policy alone.
    if (root._needsCompositorGuard(meta)) {
      root._probeCompositor(meta, row, index, capturedEpoch)
      return
    }
    root._dispatch(meta, row, index, capturedEpoch)
  }

  // Whether the action is one an idle inhibitor is asking the session not to
  // take. A declared command class counts the same as the two project actions:
  // the store only records a class for a command that says what it does to the
  // session.
  function _needsCompositorGuard(meta) {
    return meta.kind === "lock" || meta.kind === "suspend"
      || meta.commandClass === "lock" || meta.commandClass === "suspend"
  }

  // Asked and refused to run: the row was not marked, so it retries on the
  // next epoch exactly as if it had never been reached.
  function _dispatch(meta, row, index, capturedEpoch) {
    if (!root._accept(meta, row)) return
    root.fired[String(index)] = capturedEpoch
  }

  // Action metadata for one stored row: an explicit kind plus the class a
  // command row may declare. A command is never reclassified by reading
  // its text - an arbitrary string says nothing about what it does to the
  // session - so only a declared class reaches the inhibitor guard. The
  // store fills a class for the session verbs Vibranium itself runs on read
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

  // Both project actions honor the inhibitor registries: the Wayland idle
  // monitor knows nothing about login1 inhibitor locks, so without this guard
  // caffeine (an "idle" block lock) could not stop an idle timer from locking
  // or suspending the session. The screensaver counter is the other D-Bus
  // source. A command is guarded by the class its row declares and by nothing
  // else - and a Wayland idle inhibitor, which neither registry can see, is
  // asked of the compositor in fire() before the action runs.
  function _blocked(meta) {
    if (meta.kind === "suspend" || meta.commandClass === "suspend") return Inhibitor.sleepBlocked()
    if (meta.kind === "lock" || meta.commandClass === "lock") return Inhibitor.idleBlocked()
    return false
  }

  // What the compositor says about idle inhibitors, from its client list. A
  // Wayland idle inhibitor belongs to a surface, and Hyprland reports one per
  // window as `inhibitingIdle`; nothing else the shell can reach exposes it.
  // The answer is tri-state on purpose: `true` is an inhibitor, `false` is a
  // list that provably holds none, and `null` is an unreadable reply. Only
  // `true` holds the action back, because an unreadable probe must never keep
  // the session unlocked past its own timeout.
  function _compositorInhibitsIdle(text) {
    let rows
    try {
      rows = JSON.parse(String(text))
    } catch (ignored) {
      return null
    }
    if (!Array.isArray(rows)) return null
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i]
      if (row && row.inhibitingIdle === true) return true
    }
    return false
  }

  // One bounded, one-shot probe per arm. The run is kept in a property rather
  // than closed over, so the callbacks below are the same shape as the command
  // action's: they read root and nothing else. At most one probe is in flight;
  // the timer list carries one row per action class, so two arms landing at
  // once are not a case the store can produce. An arm a later one replaces
  // simply tries again on the next activity edge.
  property var _probePending: null

  function _probeCompositor(meta, row, index, capturedEpoch) {
    root._probePending = { meta: meta, row: row, index: index, epoch: capturedEpoch }
    let job = null
    try {
      job = ProcessRegistry.start(["hyprctl", "-j", "clients"], root.tag + ":inhibitor", {
        maxAttempts: 1,
        timeoutMs: root._inhibitorProbeMs,
        onFinished: result => root._probeFinished(result, false),
        onFailed: reason => root._probeFinished(null, true)
      })
    } catch (ignored) {
      job = null
    }
    if (job === null) root._probeFinished(null, true)
  }

  // Only `true` holds the action back: a refused, failed or unreadable probe
  // proceeds exactly as the guard did before this source existed, so a missing
  // hyprctl can never keep the session unlocked past its own timeout.
  function _probeFinished(result, failed) {
    const run = root._probePending
    root._probePending = null
    if (run === null) return
    let blocked = null
    if (failed !== true && result !== null && result !== undefined && result.code === "ok")
      blocked = root._compositorInhibitsIdle(result.stdout)
    if (blocked === true) return
    if (!root.enabled || run.epoch !== root.epoch) return
    if (root.fired[String(run.index)] === run.epoch) return
    root._dispatch(run.meta, run.row, run.index, run.epoch)
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

  // A session release is a fresh idle period even when the compositor's
  // activity monitor saw no edge: input on a lock surface can leave its
  // isIdle unchanged, and a spent row would otherwise stay spent until the
  // suspend timer runs and locks only at the last moment.
  function rearmAfterRelease() {
    root._onActivity()
  }

  // A real activity transition: a new epoch, a cleared fired map, and a
  // fresh monitor set. Re-arming is what invalidates the retired
  // monitors' pending callbacks - fire() drops any callback whose epoch
  // is spent, and the retired activity monitor is not the armed one.
  //
  // Both the activity edge and a session release come through here, and a
  // disabled daemon returns without re-arming, which is correct.
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
      // Quickshell IdleMonitor counts in seconds, the same unit the store
      // and the UI use; the threshold is passed through unchanged.
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
  // toggle, one info-only reference row per timer (command with seconds
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
      t.seconds + ":" + t.action + ":" + (t.command || "") + ":" + (t.commandClass || "")
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
      // ctrl+i shows the generic line. Titles carry the seconds beside them
      // ("Timer 1 (in 900 s)"); the command rides the leading accent
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
        id: "timer-" + t.seconds,
        label: "Timer " + (i + 1) + " (in " + t.seconds + " s)",
        subLead: isCmd ? (cmd !== "" ? cmd : "Run command - not set")
          : t.action === "lock" ? "Lock session" : "Suspend",
        sub: sub,
        body: "",
        desc: (isCmd ? "Run command " + (cmd !== "" ? cmd : "- not set") : "")
          + (isCmd && sub !== "" ? " - " : "") + sub,
        infoOnly: true,
        delCommand: "vb-shell idle remove " + i
      })
    }
    items.push({
      type: "separator",
      id: "idle-sep"
    })
    // Staged Add wizard: seconds, then the command to run. Every timer is
    // a command - there is no action stage to pick from, so a new timer
    // cannot be a bare lock or suspend row and the command's own text is
    // the whole of what the timer does. The inhibitor guard reads the
    // class that command declares: the session verbs Vibranium itself
    // runs declare themselves on read, anything else declares nothing and
    // is never held back. The final commit carries every stage at once; the
    // menu stays open so several timers can be added in a row.
    let minSeconds = 1
    for (let u = 0; u < root.timers.length; u++) {
      // Timers are strictly increasing, so a new one must fire later than
      // every existing entry - the picker cannot offer a sooner second.
      if (root.timers[u].seconds + 1 > minSeconds) minSeconds = root.timers[u].seconds + 1
    }
    // No valid second left inside the wizard's week-long limit: clamp so
    // the picker never builds an inverted range. An imported longer timer
    // is not moved, and the commit validation still refuses an append that
    // would break the increasing order.
    if (minSeconds > 604800) minSeconds = 604800
    // With nothing configured the add row opens on a one-minute wait rather
    // than the first legal second; the picker floor stays at 1, so a shorter
    // wait can still be typed. A non-empty list keeps opening on its own
    // floor, which is the only second that can be added. The stage carries
    // the seed as well as the row: a row's state is seeded once per menu
    // session, so deleting the last timers with the page open would
    // otherwise keep suggesting the second the row first rendered with.
    const suggestedSeconds = root.timers.length === 0 ? 60 : minSeconds
    items.push({
      type: "select",
      id: "idle-add",
      label: "Add timer",
      sub: "Add new idle timer",
      value: suggestedSeconds,
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
        { kind: "number", min: minSeconds, max: 604800, step: 1, value: suggestedSeconds, unit: "s", sub: "Add new idle timer", subAccent: "Trigger in..." },
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

  // Replace row `i` with `row` and commit, returning the commit's verdict.
  function _commitRow(i, row) {
    const next = root.timers.slice()
    next[i] = row
    return root._commitTimers(next)
  }

  // --- actions ----
  //
  // Callable on the singleton root because the menu's onCall/editCall
  // route through the Registry hub (Registry.call resolves methods on
  // the registered object). The public terminal surface is the `idle`
  // gateway below; these in-process methods keep the provider and any
  // other resident caller on the same owner.

  function setAction(index, action) {
    const i = root._timerIndex(index)
    const a = action === "lock" || action === "suspend" || action === "command"
      ? action : ""
    if (i < 0) {
      return "error: no timer at index " + index
    }
    if (a === "") {
      return "error: action must be lock, suspend or command"
    }
    // Switching away from a command row drops its command and the class it
    // declared - the action is the declaration now. Arming a command row
    // keeps any text already collected so the transition is lossless, and
    // keeps a declared class only while the text still is what it was
    // declared for, so the guard can never outlive its reason.
    const prev = root.timers[i]
    const row = { seconds: prev.seconds, action: a }
    if (a === "command") {
      row.command = prev.command !== undefined ? prev.command : ""
      const declared = root._declaredClass(prev)
      if (declared !== "") row.commandClass = declared
    }
    return root._commitRow(i, row)
  }

  // The class a command row may keep: only lock and suspend gate the timer.
  function _declaredClass(row) {
    const c = String(row.commandClass ?? "")
    return c === "lock" || c === "suspend" ? c : ""
  }

  // The row index `index` names, or -1 when it names no timer.
  function _timerIndex(index) {
    const i = Number(index)
    return Number.isInteger(i) && i >= 0 && i < root.timers.length ? i : -1
  }

  // Set (or replace) the command a timer runs; arming the action too
  // so a typed command always fires. A class already declared on the row
  // survives, because the text is still the text that was declared.
  function setCommand(index, command) {
    const i = root._timerIndex(index)
    const c = String(command ?? "")
    if (i < 0) {
      return "error: no timer at index " + index
    }
    if (c.trim() === "") {
      return "error: command cannot be empty"
    }
    const prev = root.timers[i]
    const row = { seconds: prev.seconds, action: "command", command: c }
    const declared = root._declaredClass(prev)
    if (declared !== "") row.commandClass = declared
    return root._commitRow(i, row)
  }

  // Declare what a command timer does to the session, which is the only
  // thing the inhibitor guard reads. "lock" consults the idle blockers,
  // "suspend" the sleep blockers, "none" clears the declaration and leaves
  // the timer ungated. A lock/suspend row already declares its effect as
  // its action, so declaring a class there is refused rather than silently
  // ignored.
  function setClass(index, cls) {
    const i = root._timerIndex(index)
    if (i < 0) {
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
    const written = { seconds: row.seconds, action: "command", command: row.command }
    if (value !== "") written.commandClass = value
    return root._commitRow(i, written)
  }

  // Registry-routed entry point for the Add wizard's onCall template:
  // Menu.runCall resolves methods on the registered singleton root, not
  // on the gateway below. Without this, "idle addFull ..." logs "not
  // callable" and the pick silently does nothing.
  function addFull(seconds, action, command, cls) {
    const m = Number(String(seconds).trim().split(/\s+/)[0])
    if (!(Number.isInteger(m) && m >= 1 && m <= 604800)) {
      return "error: seconds must be an integer 1..604800"
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
      const row = { seconds: m, action: action, command: text }
      if (c !== "") row.commandClass = c
      next.push(row)
    } else {
      next.push({ seconds: m, action: action })
    }
    const err = root._commitTimers(next)
    if (err !== "") return err
    return "ok"
  }

  // The one owner for appending a command timer, shared by the wizard and
  // the `idle add` gateway. Both refuse blank commands and anything that
  // would break strict seconds order or the distinct-action rule before a
  // write. The returned row is the canonical view after the commit: a
  // recognized session command has gained its automatic class.
  function appendCommandTimer(seconds, command) {
    const n = Number(seconds)
    if (!(Number.isInteger(n) && n >= 1 && n <= 604800)) {
      return { ok: false, code: "invalid-argument", error: "seconds must be an integer 1..604800" }
    }
    const text = String(command ?? "")
    if (text.trim() === "") {
      return { ok: false, code: "invalid-argument", error: "command cannot be empty" }
    }
    const row = { seconds: n, action: "command", command: text }
    const next = root.timers.slice()
    next.push(row)
    const invalid = Settings.validateIdleTimers(next)
    if (invalid !== "") return { ok: false, code: "invalid-argument", error: invalid }
    const verdict = root._commitTimers(next)
    if (verdict !== "ok") return { ok: false, code: "backend", error: "the settings store refused the timer" }
    const committed = Settings.idleTimers
    return { ok: true, row: root._timerRow(committed[committed.length - 1] || row, committed.length - 1) }
  }

  // Staged Add wizard commit. `values` maps stage index -> committed value:
  // the seconds text first ("60 s" or "60"), then the command text. The text
  // stage is located by kind so layout shifts stay safe, and a missing text
  // value means the stage was skipped rather than left empty. Every timer is
  // a command - the wizard has no action stage - so the row is always a
  // command row, and the class its command declares is the one the read path
  // fills. Returns true to swallow Entry's generic commit path. `item`
  // arrives as the pristine page row so the stage layout is readable even
  // though delegates may carry a converted copy.
  function commitAddWizard(item, values) {
    const secondsRaw = String(values["0"] ?? "").trim().split(/\s+/)[0]
    const seconds = Number(secondsRaw)
    if (!(Number.isInteger(seconds) && seconds >= 1 && seconds <= 604800)) return true
    let textIdx = -1
    const stages = (item && Array.isArray(item.flow)) ? item.flow : []
    for (let s = 0; s < stages.length; s++) {
      if (!stages[s]) continue
      if (stages[s].kind === "text") textIdx = s
    }
    const command = textIdx >= 0 ? String(values[String(textIdx)] ?? "").trim() : ""
    if (command === "") return true
    root.appendCommandTimer(seconds, command)
    return true
  }

  // --- idle gateway --------------------------------------------------------
  // Typed replies only: no native human prose is parsed anywhere on this
  // surface. Every row here is registered by exact catalog id in
  // Component.onCompleted and returns either an ok frame or a fixed error.

  function _ok(data, format) {
    const frame = { v: 1, ok: true }
    if (data !== undefined) frame.data = data
    if (format) frame.format = format
    return frame
  }
  function _error(code, message) {
    return { v: 1, ok: false, error: { code: code, message: message } }
  }
  function _record() { return { kind: "record" } }

  // The projected row uses zero-based displayed ids and null for absent
  // optional fields, in schedule order. It is a copy: no caller can mutate
  // the live timer list through a reply.
  function _timerRow(t, id) {
    return {
      id: id,
      seconds: t.seconds,
      action: t.action,
      command: t.action === "command" && typeof t.command === "string" ? t.command : null,
      commandClass: t.commandClass === undefined || t.commandClass === null ? null : t.commandClass
    }
  }
  function _rows() {
    const out = []
    for (let i = 0; i < root.timers.length; i++) out.push(root._timerRow(root.timers[i], i))
    return out
  }
  function _table() {
    return { kind: "table", columns: [
      { key: "id", heading: "ID" }, { key: "seconds", heading: "Seconds" },
      { key: "action", heading: "Action" }, { key: "command", heading: "Command" },
      { key: "commandClass", heading: "Class" }
    ] }
  }

  // Strict decimal displayed id: no signs, no whitespace, no numeric-looking
  // coercion. A written list is resolved once before a clone is spliced.
  function _idOf(value) {
    const text = String(value ?? "")
    if (!/^[0-9]+$/.test(text)) return -1
    const i = Number(text)
    if (!Number.isSafeInteger(i) || i < 0 || i >= root.timers.length) return -1
    return i
  }

  function _enable(want) {
    if (root.enabled === want) return _ok()
    const err = Settings.setIdleEnabled(want)
    if (err !== "") return _error("backend", "the settings store refused the change")
    return _ok()
  }

  function _reload() {
    // rebuild() retires the old epoch, monitors and pending probe before it
    // rearms from the current canonical config. It never calls fire() and
    // never changes enablement.
    root.rebuild()
    return _ok()
  }

  function _list() { return _ok(_rows(), _table()) }

  function _add(seconds, command) {
    const result = root.appendCommandTimer(seconds, command)
    if (!result.ok) return _error(result.code, result.error)
    return _ok()
  }

  function _remove(id) {
    const i = root._idOf(id)
    if (i < 0) return _error("not-found", "no timer with that id")
    const next = root.timers.slice()
    next.splice(i, 1)
    const verdict = root._commitTimers(next)
    if (verdict !== "ok") return _error("backend", "the settings store refused the removal")
    return _ok()
  }

  function _setClassRow(id, cls) {
    const i = root._idOf(id)
    if (i < 0) return _error("not-found", "no timer with that id")
    const c = String(cls ?? "")
    if (c !== "lock" && c !== "suspend" && c !== "none") {
      return _error("invalid-argument", "class must be lock, suspend or none")
    }
    const row = root.timers[i]
    if (row.action !== "command") {
      return _error("refused", "a " + row.action + " timer declares its action")
    }
    const want = c === "none" ? "" : c
    const have = root._declaredClass(row)
    if (want === have) return _ok()
    if (want === "" && Settings.declaresOwnCommand(row.command)) {
      return _error("refused", "this command declares its own class")
    }
    const verdict = root.setClass(String(i), c)
    if (verdict !== "ok") return _error("refused", "the settings store refused the class")
    return _ok()
  }

  function _status() {
    return _ok({
      enabled: root.enabled === true,
      epoch: root.epoch,
      capability: root.capability,
      degraded: root.degraded,
      timers: root._rows()
    }, _record())
  }
}
