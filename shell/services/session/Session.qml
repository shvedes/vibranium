pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import QtQuick
import Quickshell
import Quickshell.Io
import qs.common
import "../../common/text/UnitIpc.js" as UnitIpc

// External session API - non-UI verbs for power management and session
// control, callable from menu rows, keybinds and scripts via
// `qs ipc call session <verb>`. Suspend locks first so wake always lands
// on the lockscreen; logout delegates to vb-core-stop-session; the rest
// are one-shot systemctl verbs. Locking asks the neutral SessionActions
// contract, and the resident lock surface owns the PAM release. Mechanics
// stay in bin/ scripts.
//
// Actions that end the session are gated here, not in a surface. The
// confirmation authority is requestDestructive: a method on this singleton
// that runs the action named in the call, declared outside the IpcHandler so
// no IPC verb reaches it, and limited to the frozen null-prototype allowlist
// of destructive names. The destructive members and their public verbs refuse
// with confirmation_required, so a same-UID IPC caller cannot reach a
// poweroff.
Singleton {
  id: root

  readonly property string tag: "session"

  // loginctl asks logind to lock, so a session the resident lock surface did
  // not engage still ends up locked even though this unit has no PAM context
  // of its own.
  readonly property int lockTimeoutMs: 5000

  // systemctl and vb-core-stop-session hand off to logind and return, so the
  // deadline is a hang guard on the handoff, not on the session ending.
  readonly property int destructiveTimeoutMs: 5000

  // systemctl suspend hands off to logind and returns the same way, so this
  // deadline bounds the handoff rather than the time the machine stays
  // suspended, and it is kept out of the destructive budget because suspend is
  // not one of the gated actions.
  readonly property int suspendTimeoutMs: 5000

  // The complete set of destructive actions, each a literal argv. The table
  // carries a null prototype and is frozen: an inherited name cannot resolve
  // to an argv, and no entry is built from caller data, so no string ever
  // reaches a shell. The keys are the destructive set - logout ends the
  // session exactly as a poweroff does, so it is listed here beside them.
  readonly property var _destructiveArgv: Object.freeze(Object.assign(Object.create(null), {
    "poweroff": ["systemctl", "poweroff"],
    "reboot": ["systemctl", "reboot"],
    "uefi-reboot": ["systemctl", "reboot", "--firmware-setup"],
    "logout": ["vb-core-stop-session"]
  }))

  property bool _lockPending: false
  property bool _destructivePending: false
  property bool _suspendPending: false

  Component.onCompleted: {
    Registry.offer("session", {
      title: "Session",
      description: "session power actions",
      verbNames: [
        "lock",
        "logout",
        "poweroff",
        "reboot",
        "suspend",
        "uefi-reboot",
        "status",
        "help",
        "ping",
      ]
    })
  }

  // Where a request came from. The three origins that exist are `ipc` (a
  // `qs ipc call`, or an external caller of the same verbs), `surface` (an
  // in-tree menu row, keybind or script) and `idle` (IdleDaemon's own fire
  // path). Anything else is whatever the caller said.
  function _via(origin) {
    return origin === undefined || origin === null || String(origin) === ""
      ? "surface"
      : origin
  }

  // The neutral contract decides only whether a lock engaged; the surface
  // keeps the PAM release. A refusal means no resident surface owns the
  // request, so logind is asked instead as an owned child rather than a
  // detached spawn whose failure nothing could observe. The verdict reports
  // only what this call established: a child that is running has not locked
  // the session yet, and its outcome reaches the caller on
  // session.lock.failed.
  //   "ok"       the surface engaged the lock
  //   "pending"  an owned loginctl child is running
  //   "failed"   no surface engaged the lock and no child could be started
  //
  // `via` is the second argument and `reason` the first, so a caller that
  // only means to say why still can: both default, and neither reaches the
  // frozen table or a shell.
  function lock(reason, via) {
    const why = reason === undefined || reason === null ? "session" : reason
    const result = SessionActions.requestLock(why)
    if (result.ok) return "ok"
    return root._lockViaLoginctl(result.code)
  }

  // One owned child at a time. ProcessRegistry destroys the job on its single
  // terminal transition, so the only cleanup here is dropping the pending
  // flag, and the guard keeps a refusal that settled inside start() from being
  // counted a second time when the child later reports. The return is the
  // request verdict, not a lock claim: "pending" when a child is running,
  // including one an earlier call started, and "failed" when none could be.
  function _lockViaLoginctl(refused) {
    if (root._lockPending) return "pending"
    root._lockPending = true
    let job = null
    try {
      job = ProcessRegistry.start(["loginctl", "lock-session"], root.tag + ":lock", {
        maxAttempts: 1,
        timeoutMs: root.lockTimeoutMs,
        onFinished: result => root._onLockSettled(result, refused),
        onFailed: reason => root._onLockFailed(refused, reason)
      })
    } catch (ignored) {
      job = null
    }
    if (job === null) {
      root._onLockFailed(refused, "spawn_refused")
      return "failed"
    }
    return "pending"
  }

  function _onLockSettled(result, refused) {
    if (!root._lockPending) return
    root._lockPending = false
    if (result === null || result === undefined) return
    if (result.code === "ok") return
    root._refuseLock(refused, result.timedOut === true ? "timeout" : result.code)
  }

  function _onLockFailed(refused, reason) {
    if (!root._lockPending) return
    root._lockPending = false
    root._refuseLock(refused, reason)
  }

  // A lock that did not happen, published on the bus: whatever asked and
  // whatever reads the topic get the same verdict, the bus half being the only
  // record that the session is unlocked, which is the state a user cannot see
  // from the outside.
  function _refuseLock(refused, reason) {
    Bus.publish("session.lock.failed", { refused: String(refused), reason: String(reason) })
  }

  // The gated members. Each refuses before anything runs: a `qs ipc call
  // session poweroff` that returns `confirmation_required` runs nothing at all.
  // `via` is the reason the member takes an argument at all: the return value
  // is part of the published contract and cannot move.
  function logout(via) {
    return root._refuseGated("logout")
  }

  function reboot(via) {
    return root._refuseGated("reboot")
  }

  function uefiReboot(via) {
    return root._refuseGated("uefi-reboot")
  }

  function poweroff(via) {
    return root._refuseGated("poweroff")
  }

  function _refuseGated(action) {
    return "confirmation_required"
  }

  // Lock first so wake always lands on the lockscreen, then hand the suspend to
  // logind as an owned child. The verdict is the whole synchronous report: the
  // child's outcome is asynchronous, so a refusal is published instead.
  //   "ok"       an owned child is running
  //   "busy"     a suspend child is already in flight
  //   "failed"   no child could be started
  //
  // The lock it takes keeps this suspend's own origin, so a request raised
  // here is recognisable downstream as part of the suspend rather than as a
  // second unrelated one.
  //
  // No inhibitor bypass here: caffeine holds an idle-only lock, which never
  // blocks an explicit sleep, so a manual suspend needs no -i. That flag
  // would ask logind to ignore foreign block locks too, which is the
  // suspend-ignore-inhibit polkit action and prompts. The idle daemon
  // consults the registries before calling with via idle, so the automatic
  // path stays guarded without it.
  function suspend(via) {
    root.lock("suspend", root._via(via))
    return root._suspendViaSystemctl()
  }

  // The same single-flight shape as the other two owned children: a direct argv
  // so no string reaches a shell, and a guard that covers a preflight refusal
  // settling inside start() as well as the child's own terminal transition.
  function _suspendViaSystemctl() {
    if (root._suspendPending) return "busy"
    root._suspendPending = true
    let job = null
    try {
      job = ProcessRegistry.start(["systemctl", "suspend"], root.tag + ":suspend", {
        maxAttempts: 1,
        timeoutMs: root.suspendTimeoutMs,
        onFinished: result => root._onSuspendSettled(result),
        onFailed: reason => root._onSuspendFailed(reason)
      })
    } catch (ignored) {
      job = null
    }
    if (job === null) {
      root._onSuspendFailed("spawn_refused")
      return "failed"
    }
    // A preflight refusal settles inside start() and already cleared the
    // guard, so no child is running and the request must not read as accepted.
    if (!root._suspendPending) return "failed"
    return "ok"
  }

  function _onSuspendSettled(result) {
    if (!root._suspendPending) return
    root._suspendPending = false
    if (result === null || result === undefined) return
    if (result.code === "ok") return
    root._refuseSuspend(result.timedOut === true ? "timeout" : result.code)
  }

  function _onSuspendFailed(reason) {
    if (!root._suspendPending) return
    root._suspendPending = false
    root._refuseSuspend(reason)
  }

  // A suspend that did not happen is published, not swallowed: the caller only
  // ever holds a request verdict, so the child's outcome has to be readable -
  // and until now that outcome reached the bus and nothing else, so a machine
  // that refused to sleep because a lid was closed looked exactly like a
  // machine that was never asked.
  function _refuseSuspend(reason) {
    Bus.publish("session.suspend.failed", { reason: String(reason) })
  }

  // The only path to a destructive action. This method is the authority: it
  // is declared outside the IpcHandler so no IPC verb reaches it, and it
  // accepts only a name the frozen table holds, so no confirmation is stored,
  // returned, or taken as a parameter and a same-UID IPC caller has no way to
  // supply one at all. One owned child at a time, and the verdict string is
  // the only report of whether the request was accepted.
  //   "ok"                 the action is authorized and a child is started
  //   "unknown_action"     the argument is not a string naming a table entry
  //   "busy"               a destructive child is already in flight
  //   "failed"             no child could be started
  function requestDestructive(action, via) {
    // A non-string argument is refused without a table lookup: a boolean, an
    // object, or an interpolated string cannot name a table entry, so it
    // cannot reach a destructive action.
    if (typeof action !== "string") return "unknown_action"
    const argv = root._destructiveArgv[action]
    if (argv === undefined) return "unknown_action"
    if (root._destructivePending) return "busy"
    root._destructivePending = true
    let job = null
    try {
      job = ProcessRegistry.start(argv, root.tag + ":destructive", {
        maxAttempts: 1,
        timeoutMs: root.destructiveTimeoutMs,
        onFinished: result => root._onDestructiveSettled(action, result),
        onFailed: reason => root._onDestructiveFailed(action, reason)
      })
    } catch (ignored) {
      job = null
    }
    if (job === null) {
      root._onDestructiveFailed(action, "spawn_refused")
      return "failed"
    }
    // A preflight refusal settles inside start() and already cleared the
    // guard, so no child is running and the request must not read as
    // accepted.
    if (!root._destructivePending) return "failed"
    return "ok"
  }

  // Exactly the same single-flight shape as the lock child: ProcessRegistry
  // destroys the job on its one terminal transition, so the only cleanup here
  // is dropping the pending flag, and the guard keeps a refusal that settled
  // inside start() from being counted a second time.
  function _onDestructiveSettled(action, result) {
    if (!root._destructivePending) return
    root._destructivePending = false
    if (result === null || result === undefined) return
    if (result.code === "ok") return
    root._refuseDestructive(action, result.timedOut === true ? "timeout" : result.code)
  }

  function _onDestructiveFailed(action, reason) {
    if (!root._destructivePending) return
    root._destructivePending = false
    root._refuseDestructive(action, reason)
  }

  // A refusal or a failed handoff is published, not swallowed: a destructive
  // action that did not happen is readable by whatever asked for it. Until now
  // that was the ONLY place it became readable - these are the user's most
  // destructive verbs in the shell, and a `poweroff` that logind declined
  // left the user watching a machine that was not going down with nothing
  // saying so.
  function _refuseDestructive(action, reason) {
    Bus.publish("session.destructive.failed", { action: String(action), reason: String(reason) })
  }

  // The bus half of a destructive refusal, kept separate so the two paths that
  // refuse differently - a child that came back with a code, and a config name
  // that never reached a child - publish the same payload shape.
  function _publishDestructiveRefusal(action, reason) {
    Bus.publish("session.destructive.failed", { action: String(action), reason: String(reason) })
  }

  // Maps a config.json action name to its verb. Returns false when the action
  // is unknown or destructive so the caller can report the fault itself.
  function dispatch(action, via) {
    const who = root._via(via)
    switch (action) {
      case "lock":
        root.lock("session", who)
        return true
      case "suspend":
        root.suspend(who)
        return true
      case "logout":
      case "reboot":
      case "poweroff":
      case "uefi-reboot":
        // The gate a config value reaches: routing a name here is not a
        // confirmation, so the destructive family is refused instead of run.
        root._refuseGated(String(action))
        root._publishDestructiveRefusal(String(action), "confirmation_required")
        return false
    }
    // A config value naming nothing the daemon can run. The caller is told
    // `false` and shows its own fault line, so this is the second copy of a
    // failure it already sees.
    return false
  }

  IpcHandler {
    target: "session"
    function help(command: string): string {
      return UnitIpc.help("session", "Session", "session power actions", [
        { name: "lock", help: "lock the session" },
        { name: "logout", help: "end the session" },
        { name: "poweroff", help: "power off" },
        { name: "reboot", help: "reboot" },
        { name: "suspend", help: "suspend" },
        { name: "uefi-reboot", help: "reboot into UEFI firmware setup" },
      ], command)
    }
    function status(): string {
      return JSON.stringify({ unit: "session", healthy: true })
    }
    function ping(): string { return "pong" }

    // lock() and suspend() answer with the member's verdict rather than an
    // unconditional ack, so a caller can tell a request that started from a
    // request that did not.
    //
    // Every body names `via=ipc`, and that is the only thing these verbs
    // changed: `shell/session` has external callers, so a poweroff a script
    // asked for and a poweroff a menu row asked for are different events and
    // the log has to be able to say which. The manifest rows are unchanged -
    // no verb gained a parameter, so a caller that knew nothing about this
    // keeps working and reads the same return strings.
    function lock(): string { return root.lock(undefined, "ipc") }
    // The destructive verbs answer confirmation_required without reaching
    // requestDestructive; the body is the member so the two layers cannot
    // drift. The names and signatures match the manifest rows.
    function logout(): string { return root.logout("ipc") }
    function suspend(): string { return root.suspend("ipc") }
    function reboot(): string { return root.reboot("ipc") }
    function poweroff(): string { return root.poweroff("ipc") }
    function uefiReboot(): string { return root.uefiReboot("ipc") }
  }
}
