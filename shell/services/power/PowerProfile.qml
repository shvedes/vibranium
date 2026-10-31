pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.common
import "../../common/power/BatteryModel.js" as BatteryModel
import "../../common/text/UnitIpc.js" as UnitIpc

// Power profile state and shell control surface, fully over D-Bus through
// Quickshell's generated PowerProfiles singleton: `profile` is both read
// and written by it (writes call SetActiveProfile on the daemon), and
// profile changes arrive through profileChanged. Nothing shells out - no
// powerprofilesctl, no state files. The singleton feeds
// the per-monitor PowerProfile widgets, the `qs ipc call powerProfile`
// verbs (next/prev/set/get/list) and `apply()` - the public write entry point
// `power/PowerPolicy` drives the AC policy through. A single instance means
// one observer and one IPC target regardless of how many monitors render the
// widget or how many policies want a profile, and it is `resident` in the boot
// catalog: the profile is the machine's business rather than a bar module's, so
// a resident unit asking a gated singleton for a write would construct it
// behind the gate's back and leave `UnitGate`'s state disagreeing with reality.
Singleton {
  id: root

  readonly property string tag: "powerProfile"

  // Canonical cycle order, matching the daemon's profile enumeration.
  readonly property var canonical: ["balanced", "performance", "power-saver"]

  // --- UPower device set ---
  //
  // Registration and de-registration of a device, observed HERE rather than in
  // the bar's Battery module. That module is the only other reader of
  // `UPower.devices`, but a bar module is constructed only while it is in the
  // layout, so a device arriving with the battery row switched off would reach
  // nothing. A device coming and going is a fact about the machine, not about
  // whether a panel happens to be on screen.
  readonly property var _upowerDevices: UPower.devices ? UPower.devices.values : []
  property var _knownDevices: ({})

  // The device's TYPE and not its model name. The name is what the battery
  // island paints for the user, and it is a piece of hardware someone chose;
  // the type is the closed UPower enumeration and is what tells a reader
  // whether the change matters (a battery appearing is not an AC adapter
  // appearing).
  function _deviceType(d) {
    try { return String(UPowerDeviceType.toString(d.type)).toLowerCase() }
    catch (error) { return "unknown" }
  }

  // The enumeration's own spelling of the type, before `_deviceType` lowercases
  // it. The lowercased label is the closed vocabulary the INFO line prints, and
  // it is the only thing the log would ever show, so the member name - the form
  // a `Type=` rule or a bug report about the daemon would be written in - is not
  // in the log at all. `toString` is the one read that can supply it, and calling
  // it here rather than printing the raw number means a daemon that grows a
  // member reports a new word rather than an unexplained integer.
  function _rawDeviceType(d) {
    try { return String(UPowerDeviceType.toString(d.type)) }
    catch (error) { return "unknown" }
  }

  // The device's own key, from the shared helper rather than from a second
  // spelling of it here. The native path leads because UPower reports no
  // identity for a device beyond it: `UPowerDevice` carries neither a bus
  // name nor an id, so a key built from either is the bare type and every
  // battery in the machine collapses into one entry. That argument is carried
  // in full at `common/power/BatteryModel.js`'s `deviceKey`, and it is the
  // same function `power/BatteryAlert` files its per-device state under, so
  // two readers of one device set cannot disagree about which device they are
  // looking at. A "" key - a device with neither a path nor a type string - is
  // skipped by `_devicesChanged` below.
  function _deviceKey(d) {
    return BatteryModel.deviceKey(d.nativePath, root._deviceType(d))
  }

  // Growth AND shrink, because a device leaving is as much a fact as one
  // arriving - and unlike the MPRIS set, this one is a closed, small set that
  // does not churn on every re-announce.
  function _devicesChanged() {
    const next = ({})
    for (let i = 0; i < root._upowerDevices.length; i++) {
      const d = root._upowerDevices[i]
      const key = root._deviceKey(d)
      if (key === "") continue
      next[key] = true
      if (root._knownDevices[key] === true) continue
      Log.info("registered device (" + root._deviceType(d) + "), total " + root._upowerDevices.length)
      // Rides the arrival, not the evaluation, so this is one line per device
      // rather than one per re-announce. The key is what every later statement
      // about this device is filed under and the INFO line above never shows
      // it, which is what leaves two devices that agree on type and arrive in
      // the same breath indistinguishable below the type word.
      const added = Log.at()
      if (added.allows("debug")) {
        added.debug("registered device (" + root._deviceType(d) + "): filed under "
          + Log.summarize(key) + ", UPower type " + root._rawDeviceType(d))
      }
    }
    const keys = Object.keys(root._knownDevices)
    for (let i = 0; i < keys.length; i++) {
      if (next[keys[i]] === true) continue
      Log.info("unregistered device, total " + root._upowerDevices.length)
      // The departing device is gone from `_upowerDevices` by now, so the key
      // is the last thing it had: the INFO line names no type and no identity
      // here because neither is still readable, and a log that says only
      // `unregistered device` cannot say WHICH one, which is the whole question
      // when a machine's battery is what went missing.
      const removed = Log.at()
      if (removed.allows("debug")) {
        removed.debug("unregistered device: filed under " + Log.summarize(keys[i]))
      }
    }
    root._knownDevices = next
  }

  // The set diff, on the model's own signal. `UPower.devices` is an
  // UntypedObjectModel, whose `values` property emits `valuesChanged` and
  // which declares no other signal of its own, so the handler name has to
  // match that one exactly: a handler for anything else names nothing the
  // object has and never runs. A per-device property change is not
  // observable here either - a device's own percentage or state needs its
  // own watcher, which is `power/BatteryAlert`'s shape.
  Connections {
    target: UPower.devices

    function onValuesChanged() { root._devicesChanged() }
  }

  // Profiles this system can switch to: power-saver and balanced always,
  // performance only when the daemon reports it (the D-Bus setter refuses
  // it otherwise).
  readonly property var available:
    PowerProfiles.hasPerformanceProfile
    ? root.canonical : ["balanced", "power-saver"]

  // --- live D-Bus state ---

  // Any raw enum outside the three members means the daemon has not been
  // reached yet (or went away), which reads as unavailable.
  readonly property bool unavailable:
    PowerProfiles.profile !== PowerProfile.PowerSaver
    && PowerProfiles.profile !== PowerProfile.Balanced
    && PowerProfiles.profile !== PowerProfile.Performance

  // Canonical D-Bus profile names, matching the daemon's own names.
  readonly property string profileName:
    root.unavailable ? "unavailable"
    : PowerProfiles.profile === PowerProfile.Performance ? "performance"
    : PowerProfiles.profile === PowerProfile.PowerSaver ? "power-saver"
    : "balanced"

  // performance/power-saver get their own glyphs, balanced paints nothing,
  // an unreachable daemon shows the generic one.
  readonly property string iconName:
    root.unavailable ? "power"
    : PowerProfiles.profile === PowerProfile.Performance ? "power-performance"
    : PowerProfiles.profile === PowerProfile.PowerSaver ? "power-power-saver"
    : ""

  Component.onCompleted: {
    Registry.offer("powerProfile", {
      title: "Power profile",
      description: "power profile switching",
      verbNames: [
        "get",
        "list",
        "next",
        "prev",
        "set",
        "status",
        "help",
        "ping",
      ]
    })
  
    // The UPower device set, seeded without reporting: devices already on the
    // bus when the shell starts were not registered by anything this shell
    // observed. QML allows one Component.onCompleted per object, so this rides
    // here rather than claiming a second handler.
    const seen = ({})
    for (let i = 0; i < root._upowerDevices.length; i++) {
      const key = root._deviceKey(root._upowerDevices[i])
      if (key !== "") seen[key] = true
    }
    root._knownDevices = seen
  }

  // --- switching (D-Bus set) ---

  function _enumFor(name: string): var {
    switch (name) {
      case "power-saver": return PowerProfile.PowerSaver
      case "performance": return PowerProfile.Performance
      case "balanced": return PowerProfile.Balanced
    }
    return null
  }

  // --- what the daemon last said, and what we last asked ---

  // `profileName` is a binding over the generated service's LOCAL mirror, and
  // the service sets that mirror and emits profileChanged INSIDE the
  // assignment. Measured on 0.3.1, not assumed:
  //
  //   PowerProfiles.profile = Performance   profileChanged fires, and
  //                                       profile reads 2 before the next line
  //
  // So the property is not a readback of the daemon and the signal is not a
  // round trip arriving later. Two consequences shape everything below:
  //
  //   - there is no latency to wait on. The elapsed time between the write and
  //     the answer is 0.0 by construction.
  //   - the only evidence that the daemon took a write is that the mirror
  //     MOVED. A daemon that refuses leaves the mirror where it was, and
  //     emits no signal at all, so "asked, and nothing answered" is
  //     observable even though "answered wrongly" is not.
  //
  // A daemon that is not running is not separately detectable: the mirror
  // holds its constructed default, which is a legal enum member, so
  // `unavailable` is false with no daemon present. Quickshell does warn
  // ("Could not start PowerProfilesDaemon") but under its own category.
  property string _confirmed: ""
  // The write in flight, or null. Set BEFORE the assignment, because the
  // answer arrives during it.
  property var _asked: null

  // --- the daemon, answering ---

  Connections {
    target: PowerProfiles

    // Measured on 0.3.1: the signal arrives INSIDE the assignment, before the
    // write returns. That is load-bearing here: the request is cleared at the
    // top, so a signal that answers one always finds it, and the post-write
    // check in _setNamed (which reports a request nothing answered) can only
    // fire when nothing answered.
    //
    // The first answer is also how the daemon is known to be there at all: no
    // signal of any kind arrives while it is absent. It seeds the baseline,
    // because a profile the shell has just discovered is not a profile that
    // moved - except when it is the answer to a request this shell made, and
    // then the request already carries the `from` the seed does not have.
    function onProfileChanged() {
      const now = root.profileName
      const asked = root._asked
      root._asked = null
      if (root._confirmed === "") root._confirmed = now
      if (asked === null && now === root._confirmed) return
      root._confirmed = now
    }
  }

  // The one place a profile is written, so the three user verbs go through
  // here rather than one verb each: next/prev and set differ only in how they
  // pick the name. The refusal path returns before the write, so a name the
  // daemon cannot take never reaches the assignment.
  //
  // The profile is daemon state, not a settings key - it does not pass through
  // Settings, HyprlandSettings or MiscSettings - so nothing else reports it.
  //
  // Returns whether the write was ATTEMPTED, not whether the daemon moved: the
  // only evidence of that is the mirror moving, and that has already been read
  // and logged at the foot of this function by the time a caller could use it.
  function _setNamed(name: string): bool {
    const value = root._enumFor(name)
    if (value === null || root.available.indexOf(name) < 0) return false
    const from = root.profileName
    // A request for the profile already active is not a change, and the
    // daemon accepting it is not evidence the desktop did anything. Compare
    // before the write: profileName is a binding over the local mirror, so
    // reading it after would compare the new value against itself.
    if (from === name) return false
    // Reported before the write, and as the transition it is rather than the
    // outcome: the daemon accepting the request is not evidence the desktop
    // moved, which is the same reason the comparison above happens here. Both
    // names come from UPower's own enumeration, so this is a fixed vocabulary
    // and not user data.
    Log.info("power profile " + from + " > " + name)
    // Before the assignment: the answer arrives during it.
    root._asked = { name: name, from: from }
    PowerProfiles.profile = value
    // Read here rather than in `onProfileChanged`, because the whole point is
    // to stand beside the write: a DEBUG line emitted from the signal handler
    // is a separate record whose position in the log says nothing about which
    // request it belongs to. The only evidence that the daemon took the write
    // is that the mirror MOVED, and both names come from the closed UPower
    // enumeration, so the verdict costs no privacy and no second round trip.
    const answered = root._asked === null
    const settled = root.profileName
    const moved = Log.at()
    if (moved.allows("debug")) {
      moved.debug("power profile " + from + " > " + name + ": enum " + value
        + ", daemon " + (answered ? settled : "answered nothing")
        + ", match " + (settled === name))
    }
    // A request that is still pending here means no signal fired, which means
    // the mirror did not move, which means nothing took the write. That is
    // the daemon being absent or refusing, and it is the one state this
    // surface cannot otherwise see: with no daemon the mirror holds a legal
    // default, so `unavailable` reads false and everything else looks like a
    // healthy session.
    if (root._asked !== null) root._asked = null
    return true
  }

  // --- the public write entry point ---
  //
  // `power/PowerPolicy` decides which profile a power source implies and calls
  // this, rather than touching `PowerProfiles.profile` itself: a second write
  // path is a second definition of what `available` means, and the AC policy
  // would then be able to hand the daemon a name the IPC verbs refuse - which
  // is a request whose only outcome is silence, with nothing in the log to
  // say the policy and the daemon disagreed. Delegating rather than
  // duplicating is what keeps the one refusal, the one INFO line and the one
  // DEBUG verdict shared by every caller.
  //
  // A caller that names the profile already active, or one the daemon cannot
  // take, gets `false`: no write was attempted. It is not an error, and a
  // policy does not need to distinguish it from a successful write to a
  // profile the daemon refused - `_setNamed` reports that case at DEBUG.
  function apply(name: string): bool {
    return root._setNamed(String(name ?? ""))
  }

  // Next/prev index with wraparound over the writable profile list; an
  // unknown/absent current (daemon down) starts from the list edge.
  function _cycleIndex(forward: bool): int {
    const idx = root.available.indexOf(root.profileName)
    if (idx < 0) return forward ? 0 : root.available.length - 1
    return forward
      ? (idx + 1) % root.available.length
      : (idx - 1 + root.available.length) % root.available.length
  }

  // --- IPC ---

  IpcHandler {
    target: "powerProfile"
    function help(command: string): string {
      return UnitIpc.help("powerProfile", "Power profile", "power profile switching", [
        { name: "get", help: "current profile" },
        { name: "list", help: "available profiles" },
        { name: "next", help: "cycle to the next profile" },
        { name: "prev", help: "cycle to the previous profile" },
        { name: "set", help: "(profile) switch profile" },
      ], command)
    }
    function status(): string {
      return JSON.stringify({ unit: "powerProfile", healthy: true })
    }
    function ping(): string { return "pong" }

    function next(): string {
      root._setNamed(root.available[root._cycleIndex(true)])
      return "ok"
    }

    function prev(): string {
      root._setNamed(root.available[root._cycleIndex(false)])
      return "ok"
    }

    // Only profiles this system can actually switch to reach the daemon.
    function set(profile: string): string {
      if (root.available.indexOf(profile) < 0) return "error"
      root._setNamed(profile)
      return "ok"
    }

    function get(): string {
      return root.profileName
    }

    function list(): string {
      return root.available.join("\n")
    }
  }
}
