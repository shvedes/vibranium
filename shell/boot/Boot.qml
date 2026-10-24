pragma ComponentBehavior: Bound
import QtQml
import QtQuick
import QtQuick as QQ
import Quickshell.Io
import qs.common
import qs.common as Common
import qs.features.wallpaper
import qs.features.bar
import qs.boot
// NOTE: qs.services and the other qs.features.* modules are imported by
// BootLate.qml, not here. Importing a module loads its whole file set
// before anything paints, so every module named here is on the
// time-to-paint path. Floor and Phase-1 need only the four above.

Item {
  id: boot

  readonly property var _catalog: [
    {
      // Log is first because it is what reports the other 50. Nothing may
      // depend on it and nothing waits for it: the singleton resolves its own
      // configuration from the environment at construction, and the settings
      // side is adopted a tick later, so a unit that logs before `settings`
      // is drained still gets a gate rather than an unfiltered stream.
      id: "log",
      criticality: "essential",
      activation: "eager",
      dependencies: [],
      resolver: function() { return boot._resolveDescriptor("log") },
      // Nothing here is awaited, so the predicate observes the resolved
      // configuration rather than asserting a constant.
      ready: function() { return Log.ready === true },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "paths",
      criticality: "essential",
      activation: "eager",
      dependencies: [],
      resolver: function() { return boot._resolveDescriptor("paths") },
      ready: function() { return typeof Paths.home === "string" && Paths.home !== "" },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "watch",
      criticality: "essential",
      activation: "eager",
      dependencies: ["paths"],
      resolver: function() { return boot._resolveDescriptor("watch") },
      ready: function() { return typeof Watch.tag === "string" && Watch.tag !== "" },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "settings",
      criticality: "essential",
      activation: "eager",
      dependencies: ["paths", "watch"],
      resolver: function() { return boot._resolveDescriptor("settings") },
      ready: function() { return Settings.ready === true },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "hyprlandSettings",
      criticality: "essential",
      activation: "eager",
      dependencies: ["settings"],
      resolver: function() { return boot._resolveDescriptor("hyprlandSettings") },
      ready: function() { return HyprlandSettings.ready === true },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "miscSettings",
      criticality: "essential",
      activation: "eager",
      dependencies: ["settings"],
      resolver: function() { return boot._resolveDescriptor("miscSettings") },
      ready: function() { return MiscSettings.ready === true },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "systemFont",
      criticality: "essential",
      activation: "eager",
      dependencies: ["settings"],
      resolver: function() { return boot._resolveDescriptor("systemFont") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "theme",
      criticality: "essential",
      activation: "eager",
      dependencies: ["settings"],
      resolver: function() { return boot._resolveDescriptor("theme") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "ui",
      criticality: "essential",
      activation: "eager",
      dependencies: ["settings", "theme"],
      resolver: function() { return boot._resolveDescriptor("ui") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "icons",
      criticality: "essential",
      activation: "eager",
      dependencies: ["settings", "theme"],
      resolver: function() { return boot._resolveDescriptor("icons") },
      ready: function() { return Icons.ready === true },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "exec",
      criticality: "essential",
      activation: "eager",
      dependencies: ["paths"],
      resolver: function() { return boot._resolveDescriptor("exec") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "state",
      criticality: "essential",
      activation: "eager",
      dependencies: ["paths"],
      resolver: function() { return boot._resolveDescriptor("state") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "idleDaemon",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("idleDaemon") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "inhibitor",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("inhibitor") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "session",
      criticality: "essential",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("session") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "lockscreen",
      criticality: "essential",
      activation: "resident",
      dependencies: ["settings", "session", "state", "watch", "theme"],
      resolver: function() { return boot._resolveDescriptor("lockscreen") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "wallpaper",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "theme", "paths", "state", "watch", "ui"],
      resolver: function() { return boot._resolveDescriptor("wallpaper") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "clipboard",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("clipboard") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "privacy",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("privacy") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "bar",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "theme", "ui", "icons", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("bar") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "osd",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "theme", "ui", "icons", "state"],
      resolver: function() { return boot._resolveDescriptor("osd") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      // The notification daemon. Resident rather than first_use because the
      // server has to own org.freedesktop.Notifications before anything can
      // post to it: a unit that built on first notification would lose the
      // ones sent while it did not exist, and notify-send's answer to a missing
      // name is a silent no-op. The dependency order is load-bearing - the
      // catalog graph check refuses a dependency declared at or after its
      // dependent - and all five of these are essential units drained first.
      id: "notifications",
      criticality: "optional",
      activation: "resident",
      // `privacy` for Privacy.shareOn, the screen-share forced-DND source. It
      // is a service and not a peer unit, so it is named here the way
      // mediaArt names `audio` and powerMenu names `menu`: the daemon reads the
      // service, so the service has to be resolved before it.
      dependencies: ["settings", "theme", "ui", "icons", "state", "privacy"],
      resolver: function() { return boot._resolveDescriptor("notifications") },
      ready: function() { return boot._lateReady("notifications") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "mediaEvents",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("mediaEvents") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "menu",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "ui", "icons"],
      resolver: function() { return boot._resolveDescriptor("menu") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "audio",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("audio") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "mediaArt",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "audio", "mediaEvents"],
      resolver: function() { return boot._resolveDescriptor("mediaArt") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "keyboard",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("keyboard") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "app",
      criticality: "optional",
      // The offer, the IPC target and this unit id are one string. Boot's
      // audit reads the offered ids off the registry and compares them with
      // the drained unit ids, so an offer under any other name would be an
      // "offered but never drained" warning on a shell whose host works.
      // Nothing is loaded here: the host names no app type, and the apps
      // register themselves under their own ids.
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("app") },
      ready: function() { return boot._lateReady("app") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "appLauncher",
      criticality: "optional",
      // Facade resident, controller first use. The descriptor is drained so
      // the singleton - and therefore the `appLauncher` IPC target and the
      // menu providers it claims - exists before any keybinding can call it;
      // _drainNext returns that lease immediately, so nothing heavy runs and
      // the unit is only held while the facade's own demand holds it. The
      // usage read, the index build, the plugin scan and the panel tree are
      // the controller's, and they are built on the first open.
      activation: "facade",
      dependencies: ["settings", "state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("appLauncher") },
      ready: function() { return boot._lateReady("appLauncher") },
      teardown: function() { boot._lateTeardown("appLauncher") },
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "timer",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("timer") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "recording",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("recording") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "update",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "paths", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("update") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "polkit",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "theme", "ui", "icons", "state", "watch", "session"],
      resolver: function() { return boot._resolveDescriptor("polkit") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "emojiPicker",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("emojiPicker") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "keybindings",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("keybindings") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "themePicker",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "theme"],
      resolver: function() { return boot._resolveDescriptor("themePicker") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "themeRemover",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "theme"],
      resolver: function() { return boot._resolveDescriptor("themeRemover") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "cursorPicker",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "theme", "icons"],
      resolver: function() { return boot._resolveDescriptor("cursorPicker") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "wallpaperPicker",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "paths", "theme"],
      resolver: function() { return boot._resolveDescriptor("wallpaperPicker") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "fontPicker",
      criticality: "optional",
      activation: "resident",
      // menu is a dependency, not a race: the boot scan composes a page and
      // injectPage registers it into the search index, which is the menu's
      // own table. Without the edge the arm has to poll for a Menu singleton
      // that is not constructed yet, so font rows stay unsearchable for as
      // long as that poll takes to succeed.
      dependencies: ["settings", "state", "watch", "theme", "menu"],
      resolver: function() { return boot._resolveDescriptor("fontPicker") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "pass",
      criticality: "optional",
      // Facade resident, controller first use, for the same reason as
      // appLauncher: the `pass` IPC target has to answer before anything can
      // ask it, and the store scan, the children and the panel tree are the
      // controller's. The drain constructs the facade and returns its lease.
      activation: "facade",
      dependencies: ["settings", "state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("pass") },
      ready: function() { return boot._lateReady("pass") },
      teardown: function() { boot._lateTeardown("pass") },
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "audioMixer",
      criticality: "optional",
      // Facade resident, controller first use, for the same reason as
      // appLauncher: the mixer answers `app audioMixer` before anything can
      // ask for it, and the node classification, the routing map, the peak
      // handles and the window are the controller's. The drain constructs the
      // facade and returns its lease, so the unit is only held while the
      // facade's own demand holds it.
      activation: "facade",
      dependencies: ["settings", "state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("audioMixer") },
      ready: function() { return boot._lateReady("audioMixer") },
      teardown: function() { boot._lateTeardown("audioMixer") },
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "imageViewer",
      criticality: "optional",
      // Facade resident, controller first use: the singleton answers the app
      // host on every verb and is built once, and the window plus the folder
      // model it needs are built on the first open that asks for them.
      activation: "facade",
      dependencies: ["settings", "state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("imageViewer") },
      ready: function() { return boot._lateReady("imageViewer") },
      teardown: function() { boot._lateTeardown("imageViewer") },
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "annotations",
      criticality: "optional",
      // First use: the headless capture service is resident and asks for a
      // region selector, a picker or an editor through the neutral
      // AnnotationActions contract. Nothing is built until it asks, and the
      // controller is released again once the last request closes, so a
      // shell that never annotates constructs no view at all.
      activation: "first_use",
      dependencies: ["settings", "state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("annotations") },
      ready: function() { return boot._annotationsReady() },
      teardown: function() { boot._teardownAnnotations() },
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "archUpdates",
      criticality: "optional",
      activation: "gated_compat",
      dependencies: ["settings", "state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("archUpdates") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      // Resident rather than gated_compat: the AC policy unit is resident and
      // applies a profile through this one, so it holds no gate lease to open
      // with, and the policy stays `blocked` on this dependency until a bar
      // slot the user may have switched off materializes the singleton. A gate
      // also assumes it is the only opener - a resident caller constructs the
      // singleton from outside it, which leaves `UnitGate`'s state disagreeing
      // with what exists - and the profile daemon is the machine's business,
      // not one bar module's.
      id: "powerProfile",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("powerProfile") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "printers",
      criticality: "optional",
      activation: "gated_compat",
      dependencies: ["settings", "state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("printers") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      // The AC policy: which profile the machine runs on, from the adapter.
      // Resident because a policy that exists only while something is looking
      // at it applies nothing - the adapter changes whether or not a bar, a
      // menu or an OSD is on screen.
      //
      // `powerProfile` is an edge rather than a convenience: the policy reads
      // the daemon's mirror (`profileName`) and then writes, so a singleton
      // still constructing would answer a remembered profile out of a
      // half-built service. The gate blocks rather than races, so the unit is
      // held `blocked` until the dependency settles and `_refreshUnit`'s
      // cascade starts it. The other four are the floor every services unit
      // declares: the settings store it reads its two targets from, and the
      // state, watcher and paths every service's configuration and logging
      // path goes through.
      id: "powerPolicy",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "paths", "powerProfile"],
      resolver: function() { return boot._resolveDescriptor("powerPolicy") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      // Low battery alerts. Resident for the same reason as `powerPolicy`: a
      // device running down is a fact about the machine, so the unit cannot
      // hang off the lifetime of a view. A shell whose battery is at five
      // percent with the bar switched off still says so.
      //
      // It reads `Settings` for the master switch and the two levels, and
      // nothing else the catalog names: the device set is D-Bus, and both the
      // percentage and the level policy come out of `BatteryModel`, a shared
      // library rather than a unit. So the floor is the same four common
      // primitives the other service units declare, and no service edge.
      id: "batteryAlert",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("batteryAlert") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      // Captive-portal and metered-network announcements. Resident for the
      // same reason as `batteryAlert`: the network's verdict is a fact
      // about the machine, so the unit cannot hang off the lifetime of a
      // view. It reads nothing but the NM system bus through short-lived
      // children, and the value tables and argv come out of
      // ConnectivityLib, a library rather than a unit. So the floor is the
      // same primitives minus the settings store it never reads, and no
      // service edge.
      id: "connectivity",
      criticality: "optional",
      activation: "resident",
      dependencies: ["state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("connectivity") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "screenshots",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "paths", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("screenshots") },
      ready: function() { return boot._lateReady("screenshots") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "powerMenu",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "menu", "session"],
      resolver: function() { return boot._resolveDescriptor("powerMenu") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    }
  ]

  property var _queue: []
  property var _deferredQueue: []
  // id -> descriptor and id -> [dependent ids], built once during
  // registration so the dependency cascade and lookups are O(edges)
  // instead of O(units) per step.
  property var _byId: ({})
  property var _dependents: ({})
  property var _report: ({})
  property bool _refreshingReadiness: false
  property bool _reportPending: false
  property bool _coalesceReports: false
  property bool _catalogValid: false
  property string _catalogValidationError: ""
  // The last lifecycle milestone each unit reached. The unit events are
  // emitted on the transition and not on every read, so a run reports what
  // its units did instead of the same line as many times as a state was
  // polled - and a unit that goes ready, loses it, and comes back reports
  // both transitions instead of only the first.
  property var _milestones: ({})
  // `real`, not `int`: a QML `property int` is 32-bit, and Date.now() is
  // ~1.79e12, so an int property truncates it to a negative number and every
  // elapsed figure computed against it comes out as noise - a boot reported
  // as 1791001363123ms. Epoch millis do not fit an int.
  readonly property real _bootStartedAtMs: Date.now()
  // shell.start names the build the line came from. Nothing else in the tree
  // publishes a version, so the boot contract declares its own: it moves when
  // the catalog's shape does, which is the only change that can make two boot
  // logs incomparable.
  //
  // Derived from the catalog rather than written beside it, so the marker and
  // the shape it names cannot drift apart: a unit added and a unit's
  // criticality changed both move it, and the line that reports the outcome
  // carries it, so two boot logs either agree about what produced them or
  // say plainly that they are not comparable.
  //
  // Spelled out rather than packed. This was `catalog/49/14`, which is two
  // numbers wearing a label that names neither of them: read cold it looks
  // like a version, a date or a hash. Its whole job is to be compared against
  // another boot log months later, and a marker nobody can decode without the
  // source fails at exactly that. So it says what it counts.
  readonly property string start: boot._catalog.length + " units, "
    + boot._essentialCount() + " essential"
  // The shell verdict, held for the same reason the milestones are: it is
  // recomputed on every unit event and printed only when it moves.
  property string _shellMilestone: ""
  Component.onCompleted: {
    // Fired first so the late half compiles on a worker thread while the
    // floor and Phase 1 drain on this one. Nothing below waits for it:
    // _beginDrain runs when it lands.
    boot._loadLate()
    if (!boot._registerCatalog()) {
      return
    }
    boot._bootP0()
    // Phase 1: visual surfaces on the first frames after the floor.
    boot._bootVisuals()
    settingsReadyConnection.target = Settings
    hyprlandSettingsReadyConnection.target = HyprlandSettings
    miscSettingsReadyConnection.target = MiscSettings
    iconsReadyConnection.target = Icons
    // Phase 2+ (the drain) needs the late half first: its imports are what
    // resolving any late unit compiles, so the drain waits for it while
    // the floor and Phase 1 are already on screen.
  }

  // The late half of boot (see BootLate.qml). Loaded asynchronously so its
  // ~190ms of type loading happens off the UI thread instead of blocking
  // first paint; the drain starts when it lands.
  property var _late: null
  property var _lateComponent: null
  property bool _drainStarted: false
  // Late-unit demands that arrived before the late half loaded (a bar
  // module hook ensuring its service during Phase 1). The resolver ran
  // with nothing to dispatch to, so the demand is replayed in _adoptLate
  // instead of leaving the unit starting forever.
  property var _pendingLateResolves: []

  function _loadLate() {
    if (boot._late || boot._lateComponent) return
    const comp = Qt.createComponent("BootLate.qml", Component.Asynchronous)
    if (comp.status === Component.Ready) {
      boot._adoptLate(comp)
    } else if (comp.status === Component.Error) {
      Log.error("boot: late half failed to load: " + comp.errorString())
      boot._beginDrain()
    } else {
      boot._lateComponent = comp
      comp.statusChanged.connect(boot._onLateStatus)
    }
  }

  function _onLateStatus() {
    const comp = boot._lateComponent
    if (!comp || comp.status === Component.Loading) return
    comp.statusChanged.disconnect(boot._onLateStatus)
    boot._lateComponent = null
    if (comp.status === Component.Ready) {
      boot._adoptLate(comp)
      return
    }
    Log.error("boot: late half failed to load: " + comp.errorString())
    boot._beginDrain()
  }

  function _adoptLate(comp) {
    boot._late = comp.createObject(boot, { boot: boot })
    if (!boot._late) {
      Log.error("boot: late half failed to instantiate")
      boot._beginDrain()
      return
    }
    annotationLoader.sourceComponent = boot._late.annotationComponent()
    // Replay the demands the late half missed: resolve each stashed unit
    // now that there is something to dispatch to, then refresh it so a
    // unit with no ready predicate (or an already-true one) settles
    // instead of sitting in starting. Units with a pending predicate
    // settle through their own refresh hooks.
    const pending = boot._pendingLateResolves
    boot._pendingLateResolves = []
    for (let i = 0; i < pending.length; i++) {
      try {
        boot._late.resolve(pending[i])
      } catch (error) {
        Log.error("boot: late replay for unit " + pending[i] + " failed: " + String((error && error.message) || error))
        continue
      }
      UnitGate.refresh(pending[i])
    }
    boot._beginDrain()
  }

  function _beginDrain() {
    if (boot._drainStarted) return
    boot._drainStarted = true
    // The drain resolves what the shell needs up front. A first_use unit is
    // none of that: it is built by whoever demands it, through its own
    // UnitGate lease, so draining it here would both do the work the split
    // exists to defer and leave a boot owner the demand can never release.
    // A facade unit is the exception that proves the rule: its resident half
    // is a cheap singleton that must exist so its IPC target answers, so it
    // IS drained - and _drainNext hands the lease straight back.
    // Visual surfaces are constructed in Phase 1 (see _bootVisuals) instead of
    // the idle drain, so they appear on the first frames after the floor. Keep
    // them out of the drain queue so they are not constructed twice.
    const _visualIds = ["wallpaper", "bar"]
    const _deferredIds = ["menu", "mediaArt", "timer", "recording", "update", "polkit", "emojiPicker", "keybindings", "themePicker", "themeRemover", "cursorPicker", "wallpaperPicker", "fontPicker", "powerProfile", "powerPolicy", "batteryAlert", "connectivity", "screenshots", "powerMenu"]
    const _full = boot._catalog.filter(descriptor => descriptor.activation !== "eager" && descriptor.activation !== "gated_compat" && descriptor.activation !== "first_use" && _visualIds.indexOf(descriptor.id) < 0)
    boot._queue = _full.filter(descriptor => _deferredIds.indexOf(descriptor.id) < 0)
    boot._deferredQueue = _full.filter(descriptor => _deferredIds.indexOf(descriptor.id) >= 0)
    // The contract is neutral, so the hook is bound here rather than by the
    // controller: a capture that asks for a view before any controller has
    // existed still gets one, because the demand reaches the layer that is
    // allowed to build it.
    AnnotationActions.bind(boot._ensureAnnotations)
    Idle.run(boot._drainNext, 0, 0, "boot-drain")
  }

  // Self-registration entry point: a unit (or the catalog loader) hands in a
  // descriptor and it is validated + registered with UnitGate, with the
  // dependency bookkeeping updated. Keeping the catalog array as the source
  // today, but the path is now the same one a future self-registering unit
  // would use.
  function register(descriptor) {
    const id = descriptor && descriptor.id ? descriptor.id : "<unknown>"
    let ok = true
    try {
      ok = UnitGate.register(id, descriptor) !== false
    } catch (error) {
      ok = false
    }
    if (ok) {
      const byId = Object.assign({}, boot._byId)
      byId[id] = descriptor
      boot._byId = byId
    }
    return ok
  }

  function _registerCatalog() {
    boot._catalogValid = false
    boot._catalogValidationError = ""
    let registrationError = ""
    for (let i = 0; i < boot._catalog.length; i++) {
      const descriptor = boot._catalog[i]
      const id = descriptor && descriptor.id ? descriptor.id : "<unknown>"
      if (!boot.register(descriptor) && registrationError === "") {
        registrationError = "unable to register catalog unit " + id
      }
    }
    const graphError = boot._graphValidationError()
    if (registrationError !== "") {
      boot._catalogValidationError = registrationError
      return false
    }
    if (graphError !== "") {
      boot._catalogValidationError = graphError
      return false
    }
    const byId = ({})
    const dependents = ({})
    for (let i = 0; i < boot._catalog.length; i++) {
      const descriptor = boot._catalog[i]
      byId[descriptor.id] = descriptor
      dependents[descriptor.id] = dependents[descriptor.id] || []
    }
    for (let i = 0; i < boot._catalog.length; i++) {
      const descriptor = boot._catalog[i]
      for (let j = 0; j < descriptor.dependencies.length; j++) {
        const dependency = descriptor.dependencies[j]
        if (!dependents[dependency]) dependents[dependency] = []
        dependents[dependency].push(descriptor.id)
      }
    }
    boot._byId = byId
    boot._dependents = dependents
    boot._catalogValid = true
    return true
  }

  function _graphValidationError() {
    let gateError = ""
    if (typeof UnitGate.validateGraph === "function") {
      try {
        gateError = boot._validationMessage(UnitGate.validateGraph())
      } catch (error) {
        gateError = "UnitGate graph validation failed: " + String(error)
      }
    }
    const localError = boot._catalogGraphError()
    return gateError !== "" ? gateError : localError
  }

  function _validationMessage(result) {
    if (result === true || result === 0 || result === undefined || result === null) return ""
    if (result === false) return "UnitGate graph validation failed"
    if (typeof result === "string") return result
    if (Array.isArray(result)) {
      return result.length === 0 ? "" : result.join("; ")
    }
    if (typeof result === "object") {
      if (result.ok === true || result.valid === true) return ""
      const detail = result.error !== undefined ? result.error : result.errors !== undefined ? result.errors : result.message
      if (Array.isArray(detail)) return detail.length === 0 ? "UnitGate graph validation failed" : detail.join("; ")
      if (detail !== undefined && detail !== null && String(detail) !== "") return String(detail)
    }
    return "UnitGate graph validation failed"
  }

  function _catalogGraphError() {
    const indexes = ({})
    for (let i = 0; i < boot._catalog.length; i++) {
      const descriptor = boot._catalog[i]
      const id = descriptor && descriptor.id
      if (typeof id !== "string" || id.trim() === "") return "catalog unit has an invalid id"
      if (indexes[id] !== undefined) return "catalog contains duplicate unit " + id
      indexes[id] = i
    }
    for (let i = 0; i < boot._catalog.length; i++) {
      const descriptor = boot._catalog[i]
      const id = descriptor.id
      const dependencies = descriptor.dependencies
      if (!Array.isArray(dependencies)) return "catalog unit " + id + " has invalid dependencies"
      const seen = ({})
      for (let j = 0; j < dependencies.length; j++) {
        const dependency = dependencies[j]
        if (typeof dependency !== "string" || dependency.trim() === "") return "catalog unit " + id + " has an invalid dependency"
        if (seen[dependency]) return "catalog unit " + id + " repeats dependency " + dependency
        seen[dependency] = true
        if (indexes[dependency] === undefined) return "catalog unit " + id + " depends on missing unit " + dependency
        if (indexes[dependency] >= i) return "catalog dependency cycle or later-only dependency: " + id + " -> " + dependency
      }
    }
    return ""
  }

  // Floor, Phase-1 and demand-driven resolvers. Everything else is a late
  // unit and goes through BootLate (see _lateResolve): naming those
  // singletons here would import their modules and load their whole file
  // sets before first paint.
  function _resolveDescriptor(id) {
    switch (id) {
      case "log":              void Log.tag; break
      case "paths":            void Paths.home; break
      case "watch":            void Watch.tag; break
      case "settings":         void Settings.tag; break
      case "hyprlandSettings": void HyprlandSettings.tag; break
      case "miscSettings":     void MiscSettings.tag; break
      case "systemFont":       void SystemFont.tag; break
      case "theme":            void Theme.tag; break
      case "ui":               void Ui.primaryScreen; break
      case "icons":            void Icons.tag; break
      case "exec":             void Exec.run; break
      case "state":            void Common.AppState.tag; break
      case "wallpaper":        void Wallpaper.enabled; break
      case "bar":              void Bar.tag; break
      case "annotations":      annotationLoader.active = true; break
      default:                  return boot._lateResolve(id)
    }
    return true
  }

  // Late-unit dispatch. A demand that lands before the late half has
  // loaded is expected, not broken - Phase-1 surfaces ensure their
  // services while the late half still compiles - so it is stashed for
  // the replay in _adoptLate rather than resolved half-built. The drain
  // itself only starts after the late half lands.
  function _lateResolve(id) {
    if (!boot._late) {
      if (boot._pendingLateResolves.indexOf(id) < 0) {
        boot._pendingLateResolves = boot._pendingLateResolves.concat([id])
      }
      Log.debug("boot: late half not loaded yet for unit " + id + ", demand stashed")
      return false
    }
    return boot._late.resolve(id)
  }

  function _lateReady(id) {
    if (!boot._late) return false
    return boot._late.readyState(id)
  }

  function _lateTeardown(id) {
    if (!boot._late) return
    boot._late.teardown(id)
  }

  function _syncReport() {
    const next = ({})
    for (let i = 0; i < boot._catalog.length; i++) {
      const id = boot._catalog[i].id
      const state = UnitGate.state(id)
      if (!state || state.state === "not_started" || state.state === "blocked") continue
      if (typeof state.constructionMs !== "number" || !isFinite(state.constructionMs)) continue
      next[id] = state.constructionMs
    }
    boot._report = next
  }

  function _requestSyncReport() {
    if (boot._coalesceReports) {
      boot._reportPending = true
      return
    }
    if (boot._reportPending) return
    boot._reportPending = true
    Qt.callLater(() => {
      boot._reportPending = false
      boot._syncReport()
    })
  }

  function _essentialCount() {
    let essential = 0
    for (let i = 0; i < boot._catalog.length; i++) {
      if (boot._catalog[i].criticality === "essential") essential++
    }
    return essential
  }


  function _refreshUnit(id) {
    if (boot._refreshingReadiness) return
    boot._refreshingReadiness = true
    try {
      const worklist = [id]
      while (worklist.length > 0) {
        const refreshedId = worklist.shift()
        UnitGate.refresh(refreshedId)
        const dependentIds = boot._dependents[refreshedId] || []
        for (let k = 0; k < dependentIds.length; k++) {
          const dependentId = dependentIds[k]
          const descriptor = boot._byId[dependentId]
          if (!descriptor) continue
          // A first_use unit is unblocked by its own next demand, not by
          // boot: re-ensuring it here would take a "boot" owner that nothing
          // ever releases, and a unit is only stopped when its last owner
          // lets go. Leaving it blocked is what the demand hook is for.
          if (descriptor.activation === "first_use") continue
          const state = UnitGate.state(descriptor.id)
          if (!state || state.state !== "blocked") continue
          const result = UnitGate.ensure(descriptor.id, "boot")
          if (result && result.state !== "blocked") worklist.push(descriptor.id)
        }
      }
    } finally {
      boot._refreshingReadiness = false
      boot._requestSyncReport()
    }
  }

  function _unitId(value) {
    if (typeof value === "string") return value
    if (value && typeof value.id === "string") return value.id
    return ""
  }

  // One line per unit settle, never per poll. `unitChanged` is raised by
  // every refresh as well as by every transition - the eager drain calls
  // ensure()+refresh() per unit, and the dependency cascade refreshes each
  // step of the way up - so the signal is a read, and the milestone map is
  // what turns it back into the event it stands for.
  //
  // `not_started` is the map's own empty value rather than a milestone, so it
  // is not recorded: a registration is not an arrival, and recording it would
  // print one line per catalog entry before the first of them is built.
  //
  // The parent of this DEBUG is this file's own shell verdict,
  // `shell ready in 412ms, start catalog/49/14`, and this is the data behind
  // it: which unit settled, and when. It used to be UnitGate's per-unit
  // lifecycle line, which was the closer parent - same unit, same instant,
  // directly above - but those lines are DEBUG now, because a boot settles 51
  // units and fifty-odd lines before anything is drawn is not something to
  // print by default. A DEBUG whose parent is a DEBUG is not the shape this
  // tree's contract allows, so the anchor moved out to the verdict.
  //
  // The two elapsed figures go side by side rather than as a verdict on them:
  // a unit whose ready predicate answers on its first poll has readyMs equal to
  // constructionMs, and Date.now() taken twice inside one tick differs by a
  // millisecond either way, so "settled on the first poll" is a claim the
  // measurement cannot make. Only the pair is honest.
  function _unitMilestone(id) {
    const state = UnitGate.state(id)
    if (state === null || state.state === "not_started") return
    if (boot._milestones[id] === state.state) return
    const next = Object.assign({}, boot._milestones)
    next[id] = state.state
    boot._milestones = next
    Log.debug("unit " + id + " reached " + state.state + ": constructed in "
      + state.constructionMs + "ms, ready at " + state.readyMs + "ms")
    // The verdict is a function of the essential records alone, so it can only
    // have moved on a tick where some unit's milestone did.
    boot._shellMilestoneNow()
  }

  // The verdict is a transition and not a value: `starting` is what a shell
  // reads as while it is still coming up, so it is recorded and not printed -
  // a line for it would arrive before the run it is describing. `ready` is the
  // run that was asked for; `degraded` is an essential unit that failed or
  // stopped, which is the one a reader has to act on, so it is the only one
  // that is a warning. The elapsed figure is measured against this file's own
  // construction, and `start` names the catalog the run was drawn from, so a
  // boot log says what it took and what produced it without either being a
  // field the reader has to go and look up.
  function _shellMilestoneNow() {
    const verdict = UnitGate.shellState()
    if (verdict === boot._shellMilestone) return
    boot._shellMilestone = verdict
    if (verdict === "starting") return
    const line = "shell " + verdict + " in "
      + Math.max(0, Date.now() - boot._bootStartedAtMs) + "ms, start " + boot.start
    if (verdict === "degraded") {
      Log.warn(line)
      return
    }
    Log.info(line)
  }

  // --- on-demand annotation controller ---
  //
  // The capture service is resident and headless: it names no annotation
  // type, so the only way a view can appear is a demand that travels the
  // neutral contract. Boot is the composition root, so it is the layer that
  // may import the controller - it holds the Loader, leases the unit under
  // one constant owner, and lets the controller go again once the service
  // has closed its last request.

  readonly property string annotationsOwner: "screenshots-service"

  // The demand side reports WHY a demand built nothing, so the contract can
  // tell a construction that failed from a unit whose dependencies are not
  // ready yet. Only the first is terminal enough to stop asking; the second
  // must stay retryable or a capture keypress during startup would kill the
  // annotation flow for the whole session.
  function _ensureAnnotations() {
    // A demand before the late half loads has no controller component to
    // build yet: stay retryable rather than failing the flow for the
    // whole session over a startup race.
    if (!boot._late) return "pending"
    // The resolver is what activates the loader, so the lease is taken on
    // the demand and the readiness read happens after the controller has
    // adopted - not before.
    const result = UnitGate.ensure("annotations", boot.annotationsOwner)
    if (AnnotationActions.hasController()) {
      if (result && result.lease) UnitGate.retain(result.lease)
      if (annotationLoader.active) UnitGate.refresh("annotations")
      return true
    }
    // Nothing was built, so this demand owns nothing: drop the lease it was
    // handed rather than leaving a unit pinned with a controller-less owner.
    if (result && !result.ok) {
      UnitGate.releaseOwner(boot.annotationsOwner)
      return result.state === "failed" ? false : "pending"
    }
    return false
  }

  function _annotationsReady() {
    return annotationLoader.status === QQ.Loader.Ready && AnnotationActions.hasController()
  }

  function _teardownAnnotations() {
    // Releasing the loader is what unloads the controller; the gate hook is
    // already running, so the lease this held is dropped by the same path
    // the pass facade uses rather than by a second release here.
    // sourceComponent is assigned once when the late half loads and left
    // alone after that, so every demand finds the component. An inactive
    // Loader instantiates nothing anyway.
    annotationLoader.active = false
  }

  // The last request closed. The controller lingers for one grace period so
  // a second capture does not pay for a rebuild; a request that arrives
  // inside the window leaves the timer without a reload.
  function _onAnnotationsDrained() {
    if (AnnotationActions.liveRequests() > 0) return
    annotationRelease.restart()
  }

  function _releaseAnnotationsIfIdle() {
    if (AnnotationActions.liveRequests() > 0) return
    if (!annotationLoader.active) return
    // The guard is NOT "no controller yet" - the controller only goes away
    // when the gate teardown below unloads the loader, so that condition
    // would make the release unreachable and pin the whole annotation tree
    // for the session. A live request is the only thing worth waiting for,
    // and it is checked above.
    UnitGate.releaseOwner(boot.annotationsOwner)
    boot._requestSyncReport()
  }

  function _stateSnapshot() {
    const snapshot = UnitGate.states()
    const result = {
      shell: snapshot && snapshot.shell ? { state: snapshot.shell.state, health: snapshot.shell.health } : { state: "degraded", health: "unknown" },
      units: snapshot && snapshot.units ? snapshot.units : {},
      catalog: {
        valid: boot._catalogValid,
        error: boot._catalogValidationError
      }
    }
    if (!boot._catalogValid) result.shell = { state: "degraded", health: "degraded" }
    return result
  }

  Connections {
    id: unitGateConnection
    target: UnitGate
    ignoreUnknownSignals: true
    function onUnitChanged(value) {
      const id = boot._unitId(value)
      if (id === "") {
        boot._syncReport()
        return
      }
      boot._refreshUnit(id)
      boot._unitMilestone(id)
    }
    function onStatesChanged() { boot._requestSyncReport() }
  }

  // The annotation controller exists only between a request and its
  // release, so both ends of its life are contract signals rather than boot
  // state: a demand builds it, the last release lets it go.
  Loader {
    id: annotationLoader
    active: false
    asynchronous: false
    onLoaded: {
      if (boot._refreshingReadiness) return
      UnitGate.refresh("annotations")
      boot._requestSyncReport()
    }
    onStatusChanged: {
      if (boot._refreshingReadiness) return
      boot._requestSyncReport()
    }
  }

  // Quickshell exports a Timer singleton, so the element is named through
  // the QtQuick alias - the same disambiguation the media Timer uses.
  QQ.Timer {
    id: annotationRelease
    interval: Ui.slowMs
    repeat: false
    onTriggered: boot._releaseAnnotationsIfIdle()
  }

  Connections {
    id: annotationActionsConnection
    target: AnnotationActions
    ignoreUnknownSignals: true
    function onDrained() { boot._onAnnotationsDrained() }
  }

  Connections {
    id: settingsReadyConnection
    target: null
    function onReadyChanged() { boot._refreshUnit("settings") }
  }

  Connections {
    id: hyprlandSettingsReadyConnection
    target: null
    function onReadyChanged() { boot._refreshUnit("hyprlandSettings") }
  }

  Connections {
    id: miscSettingsReadyConnection
    target: null
    function onReadyChanged() { boot._refreshUnit("miscSettings") }
  }

  Connections {
    id: iconsReadyConnection
    target: null
    function onReadyChanged() { boot._refreshUnit("icons") }
  }

  Connections {
    target: BootRegistry
    function on_ReportChanged() { boot._requestSyncReport() }
  }

  function _bootP0() {
    const floor = boot._catalog.filter(descriptor => descriptor.activation === "eager")
    for (let i = 0; i < floor.length; i++) {
      const descriptor = floor[i]
      UnitGate.ensure(descriptor.id, "boot")
      UnitGate.refresh(descriptor.id)
    }
    boot._syncReport()
  }

  function _bootVisuals() {
    // Phase 1: construct the two visual surfaces synchronously right after the
    // floor, so the bar and wallpaper are on screen before the rest of the
    // resident units drain. Their dependencies are all in the floor, so they
    // are ready immediately; the drain queue excludes them (see onCompleted).
    for (const id of ["wallpaper", "bar"]) {
      const descriptor = boot._byId[id]
      if (!descriptor) continue
      try {
        UnitGate.ensure(id, "boot")
        UnitGate.refresh(id)
      } catch (error) {
        // Recorded on the unit's record by UnitGate.
      }
    }
    boot._syncReport()
  }

  function _drainOne(descriptor) {
    try {
      if (descriptor.activation === "facade") {
        const constructed = UnitGate.ensure(descriptor.id, "boot-facade")
        if (constructed && constructed.lease) UnitGate.release(constructed.lease)
      } else {
        UnitGate.ensure(descriptor.id, "boot")
      }
      UnitGate.refresh(descriptor.id)
    } catch (error) {
    }
  }

  function _drainNext() {
    boot._coalesceReports = true
    const BATCH = 4
    for (let b = 0; b < BATCH; b++) {
      const descriptor = boot._queue.shift()
      if (!descriptor) break
      boot._drainOne(descriptor)
    }
    boot._coalesceReports = false
    if (boot._reportPending) boot._reportPending = false
    boot._syncReport()
    if (boot._queue.length > 0) {
      Idle.run(boot._drainNext, 0, 0, "boot-drain")
      return
    }
    if (boot._deferredQueue.length > 0) {
      Idle.run(boot._drainDeferred, 2, 0, "boot-drain-deferred")
    }
  }

  function _drainDeferred() {
    boot._coalesceReports = true
    const BATCH = 4
    for (let b = 0; b < BATCH; b++) {
      const descriptor = boot._deferredQueue.shift()
      if (!descriptor) break
      boot._drainOne(descriptor)
    }
    boot._coalesceReports = false
    if (boot._reportPending) boot._reportPending = false
    boot._syncReport()
    if (boot._deferredQueue.length > 0) {
      Idle.run(boot._drainDeferred, 2, 0, "boot-drain-deferred")
    }
  }

  // retryTimer is gone: every catalog entry declares maxAttempts: 0, so
  // _retryPollingRequired is always false and the timer never ran. Boot
  // already orders retries through UnitGate itself; a poll that can never
  // fire is not a safety net.

  IpcHandler {
    target: "boot"

    function status(): string {
      boot._syncReport()
      return JSON.stringify(boot._report)
    }
    function state(): string {
      return JSON.stringify(boot._stateSnapshot())
    }
  }

  IpcHandler {
    target: "shell"
    function help(): string {
      // Offer ids are boot-catalog names, not IPC target names: three units
      // offer under one name and answer under another. The table lists what
      // `vb-shell` accepts. Targets without an offer (boot, shell,
      // colorPicker, screenshots) stay reachable through `vb-shell -l` and
      // their own `<unit> help`, but have no row here.
      const rename = { archUpdates: "arch-updates", idleDaemon: "idle", powerMenu: "power" }
      const ids = Registry.offers()
      const rows = []
      var width = 0
      for (let i = 0; i < ids.length; i++) {
        const name = rename[ids[i]] || ids[i]
        const meta = Registry._offers[ids[i]]
        const desc = meta && typeof meta.description === "string" ? meta.description : ""
        rows.push({ name: name, desc: desc })
        if (name.length > width) width = name.length
      }
      rows.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
      var units = ""
      for (let j = 0; j < rows.length; j++) {
        var line = "  " + rows[j].name
        for (let k = rows[j].name.length; k < width; k++) line += " "
        line += "  " + rows[j].desc
        units += line.replace(/\s+$/, "") + "\n"
      }
      return "Usage: vb-shell [OPTIONS] <unit> <command> [args...]\n"
        + "       vb-shell help [unit]\n"
        + "       vb-shell <unit> help [command]\n"
        + "\nVibranium shell IPC.\n"
        + "\nOptions:\n"
        + "  -l, --list      List available IPC targets and functions\n"
        + "  -v, --verbose   Enable verbose output\n"
        + "  -h, --help      Display this help and exit\n"
        + "\nUnits:\n" + units
        + "\nExamples:\n"
        + "  vb-shell wallpaper set image.jpg\n"
        + "  vb-shell session lock\n"
        + "  vb-shell audio status\n"
        + "\nRun `vb-shell <unit> help` for unit details.\n"
    }
    function status(): string {
      boot._syncReport()
      return JSON.stringify(boot._report)
    }
    function doctor(): string {
      boot._syncReport()
      return JSON.stringify(boot._audit())
    }
  }

  function _audit() {
     const warnings = []
     if (!boot._catalogValid) warnings.push("catalog: " + (boot._catalogValidationError || "invalid"))
     const ids = Registry.offers()
    for (let i = 0; i < ids.length; i++) {
      const meta = Registry._offers[ids[i]]
      if (!meta.verbNames || meta.verbNames.length === 0) warnings.push(ids[i] + ": no verbs offered")
      if (boot._report[ids[i]] === undefined) warnings.push(ids[i] + ": offered but never drained")
    }
    return warnings
  }
}
