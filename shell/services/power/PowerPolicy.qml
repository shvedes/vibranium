pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell
import Quickshell.Services.UPower
import qs.common
import qs.services as Core

// AC power policy: which power profile the machine runs on, decided by
// whether the adapter is plugged in.
//
// `UPower.onBattery` is the only honest AC reading this tree has.
// UPowerDevice carries no `online` property, and it cannot grow one here:
// the freedesktop spec makes `Online` a line-power-only field and `State`
// a battery-only one, so a battery's own state can never stand in for the
// adapter. `onBattery` answers the composite question for the whole
// machine, and it is inert where the question does not exist - a desktop
// with no line-power device reads `false` and never changes, so it never
// sees a transition and never has a profile imposed on it.
//
// The policy is edge-triggered and seeds without applying: a machine that
// boots on AC keeps whatever profile it had. Starting up is not a
// transition, so a construction-time apply would undo a profile the user
// chose by hand on every login.
//
// Nothing is read out of sysfs and nothing is written to disk. The
// remembered profile lives in memory only, for the same reason Inhibitor's
// `active` does: the session it describes is the shell, and a flag on disk
// would outlive both the lock and the session, able only to report a
// machine state nobody has observed yet.
//
// Every reading and every write here is D-Bus: `UPower.onBattery` for the
// source, and the profile daemon through `PowerProfile`, which owns the
// one write path and reports it.
Singleton {
  id: root

  readonly property string tag: "powerPolicy"

  // --- settings (reactive via Settings.rev inside Settings.value) ---

  // The two profile targets, read through the settings store rather than
  // an env projection. Both are live bindings, so an edit takes effect on
  // the NEXT transition: this unit acts on a power source change and on
  // nothing else, which is what keeps one event to one log line.
  readonly property string acProfile: Settings.value("shell.power.acProfile")
  readonly property string batteryProfile: Settings.value("shell.power.batteryProfile")

  // --- power source ---

  // The source this shell last saw, seeded at construction. The direction
  // of a transition and its log line are both read off it, so a repeated
  // report of the same value cannot apply a profile twice.
  property bool _onBattery: false

  // The profile that was active when the adapter was pulled, which is what
  // the `last` literal restores on the way back. Empty until the first AC
  // transition, and never persisted: see the header on why that is the
  // only honest lifetime for it.
  property string _lastProfile: ""

  Component.onCompleted: {
    // Registered, not offered, and the two are different claims.
    // `register` is the in-process namespace: it publishes this unit under
    // `powerPolicy` for `Registry.call`, which is how a peer reads
    // `acProfile` or `batteryProfile`. `offer` is an IPC socket surface, a
    // claim that the unit answers `qs ipc call` on verbs of its own - and
    // this one has none, because the adapter drives it and the settings
    // store configures it. The two sets are deliberately different:
    // AudioMixer is the same shape, and `Update` is the same shape in this
    // module.
    //
    // An empty `verbNames` is not the way to say "no verbs". `Boot._audit()`
    // reads an offer with no verbs as a fault, so offering one here would put
    // `powerPolicy: no verbs offered` into every `qs ipc call shell doctor`
    // answer for the life of the session, describing a surface that does not
    // exist. An offer is a promise, and this unit makes none.
    Registry.register(root.tag, root)
    // Seed, apply nothing. The first `onBatteryChanged` is a real
    // transition whichever value it carries, and a boot is not one.
    root._onBattery = UPower.onBattery === true
  }
  Component.onDestruction: Registry.unregister(root.tag)

  Connections {
    target: UPower

    function onOnBatteryChanged() { root._transition() }
  }

  // One power source change: the source is logged, then the profile the
  // policy names for that source is applied. The profile itself is not
  // logged here - `PowerProfile` reports its own write, and two lines
  // describing one event is one line too many.
  function _transition() {
    const to = UPower.onBattery === true
    if (to === root._onBattery) return
    const from = root._onBattery
    root._onBattery = to
    Log.info("power source " + root._sourceName(from) + " > " + root._sourceName(to))
    if (to) {
      Core.PowerProfile.apply(root._batteryTarget())
      return
    }
    // Remembered BEFORE the write, and that ordering is load-bearing:
    // `profileName` is a binding over the daemon's local mirror and reads
    // the new value the moment the assignment lands, so a `last` restored
    // from a read taken after it would restore the profile the AC policy
    // has just applied.
    root._lastProfile = Core.PowerProfile.profileName
    Core.PowerProfile.apply(root._resolve(root.acProfile, ["performance", "balanced"]))
  }

  // "battery" and "ac", the two words the transition line is written in.
  function _sourceName(onBattery: bool): string {
    return onBattery ? "battery" : "ac"
  }

  // The battery target. `last` is the profile remembered at the last AC
  // transition, and a name that resolves to nothing - an empty memory, or
  // a remembered name the daemon can no longer take, including the
  // `unavailable` mirror a daemon that never answered leaves behind - walks
  // the same fallback chain as any other unusable name.
  function _batteryTarget(): string {
    const asked = String(root.batteryProfile ?? "")
    return root._resolve(asked === "last" ? root._lastProfile : asked, ["balanced"])
  }

  // One wanted name, filtered through what the daemon can actually take,
  // then through the fallbacks in order. A name the daemon would refuse
  // never reaches it, and the chain ends on `available[0]`, which is
  // never out of range: `available` carries at least `balanced` and
  // `power-saver` whether or not the daemon reports a performance profile.
  function _resolve(name: string, fallbacks: var): string {
    const available = Core.PowerProfile.available
    const wanted = String(name ?? "")
    if (available.indexOf(wanted) >= 0) return wanted
    for (let i = 0; i < fallbacks.length; i++) {
      const next = String(fallbacks[i] ?? "")
      if (available.indexOf(next) >= 0) return next
    }
    return available[0]
  }
}
