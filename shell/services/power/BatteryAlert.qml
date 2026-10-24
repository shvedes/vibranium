pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell
import Quickshell.Services.UPower
import qs.common
import "../../common/power/BatteryModel.js" as Model

// Low battery alerts, announced over D-Bus through `notify-send`.
//
// Quickshell's Notifications service cannot be posted to from QML -
// `Notification` is `isCreatable: false` and the server has no send
// method - so `Exec.run` is the only channel, exactly as every other
// in-shell emitter uses it. Nothing reads sysfs, nothing aggregates every
// battery into one number, and no helper script is spawned: the reading is
// `UPowerDevice`, per device, and the levels come from the shared
// `BatteryModel` so this unit and the bar's battery row cannot disagree
// about what a percentage means.
//
// The device set is observed two ways because UPower offers no third.
// `UPower.devices` is an UntypedObjectModel, so its `valuesChanged` sees
// the SET move and nothing else - a device's own percentage and state are
// not observable through the model. So every device gets its own
// `Connections`, built through a `Component` and filed under its
// `Model.deviceKey`, and the model diff only adds and drops watchers.
//
// Alerts fire only while a device's charge is going down, which is the
// device's own answer to "is this running down". Charging, fully charged and
// pending charge mean it is not, so a fully charged device at 5% is not an
// alert: a charge threshold crossed with the adapter in is the one state that
// produces silence here. Unknown means it IS - UPower derives a charge state
// only from a device that reports one, and a Bluetooth HID peripheral reports
// none, so Unknown is its normal on-battery state rather than an absence of
// one. Measured on two devices on one machine: a Logitech HID++ mouse reads
// Discharging, an Xbox Bluetooth controller reads Unknown at every level.
Singleton {
  id: root

  readonly property string tag: "batteryAlert"

  // --- settings (reactive via Settings.rev inside Settings.value) ---

  // The master switch. `!== false` rather than a truth test, so a key the
  // store has not written yet is the shipped default rather than silence:
  // an unread key is not a disabled switch.
  readonly property bool enabled: Settings.value("shell.power.lowBattery") !== false

  // The two integer levels, resolved through the shared helper so the
  // catalog's per-option ranges cannot hand this unit a `critical` at or
  // above its `warn` - a pair no verdict below could honour.
  readonly property var levels: Model.resolveLevels(
    Settings.value("shell.power.warnLevel"),
    Settings.value("shell.power.criticalLevel"))

  // --- devices ---

  readonly property var devices: UPower.devices ? UPower.devices.values : []

  // key -> { device, watcher, fired }. `fired` is the set of levels this
  // device has already announced, which is the whole of the per-device
  // state: what has been said is the only thing a new reading has to be
  // compared against.
  property var _entries: ({})

  // Whether construction has finished seeding the device set. The master
  // switch's change handler below must not fire on the value the binding
  // resolves to while the unit is still being built: that is the boot
  // seeding, and `Component.onCompleted` owns it. Only a later toggle is a
  // user action worth re-checking against.
  property bool _armed: false
  // The UPower type's own spelling, lowercased: a device key and a device
  // label both read it, and a daemon that grows a member reports a new
  // word rather than an unexplained integer.
  function _typeString(d: var): string {
    try { return String(UPowerDeviceType.toString(d.type)).toLowerCase() }
    catch (error) { return "unknown" }
  }

  // A device worth alerting about: a battery-bearing UPower type, and
  // present. LinePower is the adapter and Unknown is nothing in particular,
  // and `isPresent` is only meaningful for Battery-typed devices, so
  // anything but an explicit false counts as present.
  function _tracked(d: var): bool {
    if (d === null || d === undefined) return false
    if (d.isPresent === false) return false
    return Model.isTrackedType(d.type, UPowerDeviceType.LinePower, UPowerDeviceType.Unknown)
  }

  function _keyOf(d: var): string {
    return Model.deviceKey(d.nativePath, root._typeString(d))
  }

  function _store(key: string, entry: var) {
    const next = Object.assign({}, root._entries)
    next[key] = entry
    root._entries = next
  }

  // One key, its watcher and its fired set go together. A device that
  // leaves the model has nothing left to report, and a device that comes
  // back is a new device here - which is the same thing the memory ever
  // was, since it never outlived the device either.
  function _drop(key: string) {
    const entry = root._entries[key]
    if (entry === undefined) return
    if (entry.watcher !== null && entry.watcher !== undefined) entry.watcher.destroy()
    const next = Object.assign({}, root._entries)
    delete next[key]
    root._entries = next
  }

  // The device SET moved: a watcher per arriving device, and the key,
  // watcher and fired set of every departing one dropped. Growth and
  // shrink, because a device leaving is as much a fact as one arriving.
  function _devicesChanged() {
    const live = ({})
    for (let i = 0; i < root.devices.length; i++) {
      const d = root.devices[i]
      if (!root._tracked(d)) continue
      const key = root._keyOf(d)
      // A device with neither a native path nor a type string has no
      // stable key, so it cannot be filed, watched or re-armed: it is
      // skipped rather than filed under a key nobody could trace.
      if (key === "") continue
      live[key] = true
      if (root._entries[key] !== undefined) continue
      // The entry is filed BEFORE the watcher is built, because a
      // watcher can fire from inside createObject and would then find no
      // entry to file a re-arm under.
      const entry = { key: key, device: d, watcher: null, fired: ({}) }
      root._store(key, entry)
      const watcher = watcherComp.createObject(root, { watchKey: key, watchDevice: d })
      if (watcher !== null && watcher !== undefined) {
        root._store(key, Object.assign({}, entry, { watcher: watcher }))
      }
      // The device's own first reading is an event nobody will report:
      // the shell can attach while a device is already below a level, so
      // the initial state is evaluated rather than waited for.
      root._evaluate(key)
    }
    const keys = Object.keys(root._entries)
    for (let i = 0; i < keys.length; i++) {
      if (live[keys[i]] === true) continue
      root._drop(keys[i])
    }
  }

  // One watcher per observed device, built by _devicesChanged and
  // destroyed by _drop. A Connections rather than a binding because a
  // Repeater cannot hold one, and Instantiator is not in this QtQml.
  Component {
    id: watcherComp

    Connections {
      property string watchKey: ""
      property var watchDevice: null

      target: watchDevice

      function onPercentageChanged() { root._evaluate(watchKey) }
      function onStateChanged() { root._evaluate(watchKey) }
    }
  }

  Connections {
    target: UPower.devices

    function onValuesChanged() { root._devicesChanged() }
  }

  // Urgency order. `critical` is always strictly below `warn`
  // (`resolveLevels` keeps it there), so a device that has crossed one has
  // crossed the other and the verdict is always a prefix of this list.
  readonly property var _urgentFirst: ["critical", "warn"]

  function _levelOf(name: string): real {
    return name === "critical" ? root.levels.critical : root.levels.warn
  }

  // One device, on every percentage or state change it reports.
  function _evaluate(key: string) {
    const entry = root._entries[key]
    if (entry === undefined) return
    const d = entry.device
    if (d === null || d === undefined) return
    if (!root.enabled) return
    // Whether the charge is going down, which is NOT the same question as
    // "does the state read Discharging". UPower only derives a charge state for
    // a device that reports one: a Logitech HID++ mouse exposes charging and
    // reads Discharging, while a Bluetooth HID peripheral exposes nothing to
    // derive from and reads Unknown for its whole connection, at every level.
    // Gating on the literal Discharging would watch every gamepad, keyboard
    // and headset forever and never let one announce; Model.isRunningDown
    // carries the reason and takes the enum members as arguments.
    const discharging = Model.isRunningDown(d.state,
      UPowerDeviceState.Charging,
      UPowerDeviceState.FullyCharged,
      UPowerDeviceState.PendingCharge)
    // UPowerDevice.percentage arrives as a 0..1 fraction (probed live), so
    // every threshold below reads real percent through normalizePct.
    const pct = Model.normalizePct(d.percentage)
    const was = entry.fired
    // Re-arm before the verdict. Climbing back ABOVE a level is what makes
    // it announceable again, so a level that stays crossed stays
    // announced: a discharge that dips through both thresholds at once
    // takes one card for the level it crossed rather than one per report.
    // A device that is not discharging has crossed nothing, so the whole
    // set goes - an adapter at 3% and a full device at 3% are the same
    // silence.
    const keep = { warn: false, critical: false }
    if (discharging) {
      if (was.warn === true && pct <= root.levels.warn) keep.warn = true
      if (was.critical === true && pct <= root.levels.critical) keep.critical = true
    }
    // The verdict: the most urgent crossed level, "" for none. The shared
    // one, so the levels this unit announces and the icons the bar paints
    // are two readings of one table.
    const level = discharging
      ? root._pending(Model.alertFor(d.percentage, root.levels), pct, keep)
      : ""
    if (level !== "") keep[level] = true
    // One store per evaluation that changed something: a report that
    // crosses nothing and re-arms nothing - the common case on a healthy
    // battery - touches no map and allocates nothing.
    if (level === "" && keep.warn === was.warn && keep.critical === was.critical) return
    root._store(key, Object.assign({}, entry, { fired: keep }))
    // Announced after the armed set is filed, so the level cannot be
    // announced twice by anything this evaluation triggers.
    if (level !== "") root._announce(d, level)
  }

  // The most urgent crossed level this device has not announced yet, or ""
  // when there is none. The verdict leads the scan; the levels below it are
  // reached only when the verdict is already armed, which takes a settings
  // edit - a device that crossed `critical` crossed `warn` in the same
  // breath and was announced for the urgent one only.
  function _pending(verdict: string, pct: real, keep: var): string {
    const levels = root._urgentFirst
    const start = levels.indexOf(verdict)
    if (start < 0) return ""
    for (let i = start; i < levels.length; i++) {
      const name = levels[i]
      if (keep[name] === true) continue
      if (pct > root._levelOf(name)) continue
      return name
    }
    return ""
  }

  // One card, for one level of one device. The argv is the shared one rather
  // than an arrangement kept here, because the notification card is the other
  // end of it: `NotificationsLib.iconColorOf` reads the hint name and
  // `NotificationCard.iconUrl` resolves it against the live palette. A
  // synthetic fleet drives this same function, so what a demo sends and what
  // this unit sends cannot drift apart.
  function _announce(d: var, level: string) {
    const label = Model.deviceLabel(d.model, root._typeString(d), d.nativePath)
    Log.info("battery " + level + " on " + Log.summarize(label))
    Exec.run(Model.notifyArgv(level, label, d.percentage))
  }

  // The master switch is not a device event: nothing on the bus moves when a
  // user flips it, so no watcher fires and a battery that is already below a
  // level would stay unannounced until its next report. Re-check every device
  // the moment the switch comes back on, so the current reading is honoured
  // instead of the next one. Toggling off is silence and needs no pass.
  onEnabledChanged: {
    if (!root._armed) return
    if (!root.enabled) return
    const keys = Object.keys(root._entries)
    for (let i = 0; i < keys.length; i++) root._evaluate(keys[i])
  }

  Component.onCompleted: {
    // Registered, not offered, and the two are different claims.
    // `register` is the in-process namespace: it publishes this unit under
    // `batteryAlert` for `Registry.call`, which is how a peer reads `enabled`
    // or `levels`. `offer` is an IPC socket surface, a claim that the unit
    // answers `qs ipc call` on verbs of its own - and this one has none,
    // because a discharging battery drives it and the alert it owes is a
    // `notify-send` card, not a reply. The two sets are deliberately
    // different: AudioMixer is the same shape, and `Update` is the same shape
    // in this module.
    //
    // An empty `verbNames` is not the way to say "no verbs". `Boot._audit()`
    // reads an offer with no verbs as a fault, so offering one here would put
    // `batteryAlert: no verbs offered` into every `qs ipc call shell doctor`
    // answer for the life of the session, describing a surface that does not
    // exist. An offer is a promise, and this unit makes none.
    Registry.register(root.tag, root)
    // The devices already on the bus are seeded with their own first
    // reading evaluated, so a shell that starts with a machine already
    // below a level announces it instead of waiting for the next report.
    root._devicesChanged()
    root._armed = true
  }
  Component.onDestruction: {
    // The watchers go with the unit. Each is parented here, so this is the
    // teardown that stops them rather than leaving them to outlive the
    // entries that own them.
    const keys = Object.keys(root._entries)
    for (let i = 0; i < keys.length; i++) root._drop(keys[i])
    Registry.unregister(root.tag)
  }
}
