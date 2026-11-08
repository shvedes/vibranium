pragma ComponentBehavior: Bound
import QtQml
import QtQuick
import QtQuick as QQ
import Quickshell.Io
import qs.common
import qs.common as Common
import qs.features.wallpaper
import qs.boot
// NOTE: qs.services and the other qs.features.* modules are imported by the
// late halves, not here. Importing a module loads its whole file set before
// anything paints, so every module named here is on the time-to-paint path.
// The bar is the largest of those sets by far - its singleton imports the
// whole module registry - so it is a late unit: the wallpaper is the surface
// that compiles and maps first, and the bar arrives when the async half lands
// (see _bootVisuals). Floor and Phase 1 need only the three above.
//
// The late work is split into two components so the bar does not wait for
// modules it never uses: BootBar.qml carries the services and the bar itself,
// BootLate.qml carries the feature modules (menu, launcher, apps, pickers,
// annotations, notifications). Both load in the same turn and are adopted
// independently.

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
      phase: "floor",
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
      phase: "floor",
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
      phase: "floor",
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
      phase: "floor",
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
      phase: "floor",
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
      phase: "floor",
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
      phase: "floor",
      criticality: "essential",
      activation: "eager",
      dependencies: ["settings"],
      resolver: function() { return boot._resolveDescriptor("systemFont") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "theme",
      phase: "floor",
      criticality: "essential",
      activation: "eager",
      dependencies: ["settings"],
      resolver: function() { return boot._resolveDescriptor("theme") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "ui",
      phase: "floor",
      criticality: "essential",
      activation: "eager",
      dependencies: ["settings", "theme"],
      resolver: function() { return boot._resolveDescriptor("ui") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "icons",
      phase: "floor",
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
      phase: "floor",
      criticality: "essential",
      activation: "eager",
      dependencies: ["paths"],
      resolver: function() { return boot._resolveDescriptor("exec") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "state",
      phase: "floor",
      criticality: "essential",
      activation: "eager",
      dependencies: ["paths"],
      resolver: function() { return boot._resolveDescriptor("state") },
      teardown: null,
      retry: { maxAttempts: 0, backoffMs: 0, maxBackoffMs: 1000 }
    },
    {
      id: "idleDaemon",
      phase: "early",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("idleDaemon") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "inhibitor",
      phase: "early",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("inhibitor") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "session",
      phase: "early",
      criticality: "essential",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("session") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "lockscreen",
      phase: "early",
      criticality: "essential",
      activation: "resident",
      dependencies: ["settings", "session", "state", "watch", "theme"],
      resolver: function() { return boot._resolveDescriptor("lockscreen") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "wallpaper",
      phase: "visual",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "theme", "paths", "state", "watch", "ui"],
      resolver: function() { return boot._resolveDescriptor("wallpaper") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "clipboard",
      phase: "early",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("clipboard") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "privacy",
      phase: "early",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("privacy") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "bar",
      phase: "visual",
      criticality: "optional",
      activation: "resident",
      // `icons` is deliberately not an edge. The icon scan is a `bash find`
      // over every shipped SVG whose result fills bindings in place when it
      // lands (Icons swaps `_raw` wholesale), so the only thing the edge bought
      // was a bar that could not start until the whole asset set had been read
      // - which delayed the entrance latch, and the whole drain behind it.
      dependencies: ["settings", "theme", "ui", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("bar") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "osd",
      phase: "entrance",
      criticality: "optional",
      activation: "resident",
      // Same reasoning as the bar: an icon that is not loaded yet paints
      // nothing for a frame, it does not fail the surface.
      dependencies: ["settings", "theme", "ui", "state"],
      resolver: function() { return boot._resolveDescriptor("osd") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
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
      phase: "early",
      criticality: "optional",
      activation: "resident",
      // `privacy` for Privacy.shareOn, the screen-share forced-DND source. It
      // is a service and not a peer unit, so it is named here the way
      // mediaArt names `audio` and powerMenu names `menu`: the daemon reads the
      // service, so the service has to be resolved before it.
      dependencies: ["settings", "theme", "ui", "state", "privacy"],
      resolver: function() { return boot._resolveDescriptor("notifications") },
      ready: function() { return boot._lateReady("notifications") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "mediaEvents",
      phase: "early",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("mediaEvents") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "menu",
      phase: "deferred",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "ui"],
      resolver: function() { return boot._resolveDescriptor("menu") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "audio",
      phase: "early",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("audio") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "mediaArt",
      phase: "deferred",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "audio", "mediaEvents"],
      resolver: function() { return boot._resolveDescriptor("mediaArt") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "keyboard",
      phase: "early",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("keyboard") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "app",
      phase: "early",
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
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "appLauncher",
      phase: "early",
      criticality: "optional",
      // Facade resident, controller prewarmed. The descriptor is drained so
      // the singleton - and therefore the `appLauncher` IPC target and the
      // menu providers it claims - exists before any keybinding can call it;
      // _drainNext returns that lease immediately, so nothing heavy runs.
      // The usage read, the index build, the plugin scan and the panel tree
      // are the controller's: the facade prewarms it right after drain and
      // keeps it resident, so the first open paints the app list on frame
      // one instead of an empty window.
      activation: "facade",
      dependencies: ["settings", "state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("appLauncher") },
      ready: function() { return boot._lateReady("appLauncher") },
      teardown: function() { boot._lateTeardown("appLauncher") },
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "timer",
      phase: "entrance",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("timer") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "recording",
      phase: "entrance",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("recording") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "update",
      phase: "entrance",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "paths", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("update") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "polkit",
      phase: "early",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "theme", "ui", "state", "watch", "session"],
      resolver: function() { return boot._resolveDescriptor("polkit") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "emojiPicker",
      phase: "deferred",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("emojiPicker") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "keybindings",
      phase: "early",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("keybindings") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "themePicker",
      phase: "deferred",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "theme"],
      resolver: function() { return boot._resolveDescriptor("themePicker") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "themeRemover",
      phase: "deferred",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "theme"],
      resolver: function() { return boot._resolveDescriptor("themeRemover") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "cursorPicker",
      phase: "deferred",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "theme"],
      resolver: function() { return boot._resolveDescriptor("cursorPicker") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "wallpaperPicker",
      phase: "deferred",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "paths", "theme"],
      resolver: function() { return boot._resolveDescriptor("wallpaperPicker") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "fontPicker",
      phase: "deferred",
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
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "pass",
      phase: "early",
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
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "audioMixer",
      phase: "early",
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
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "imageViewer",
      phase: "early",
      criticality: "optional",
      // Facade resident, controller first use: the singleton answers the app
      // host on every verb and is built once, and the window plus the folder
      // model it needs are built on the first open that asks for them.
      activation: "facade",
      dependencies: ["settings", "state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("imageViewer") },
      ready: function() { return boot._lateReady("imageViewer") },
      teardown: function() { boot._lateTeardown("imageViewer") },
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "annotations",
      phase: "first_use",
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
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "archUpdates",
      phase: "on_demand",
      criticality: "optional",
      activation: "gated_compat",
      dependencies: ["settings", "state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("archUpdates") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
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
      phase: "early",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("powerProfile") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "printers",
      phase: "on_demand",
      criticality: "optional",
      activation: "gated_compat",
      dependencies: ["settings", "state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("printers") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
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
      phase: "early",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "paths", "powerProfile"],
      resolver: function() { return boot._resolveDescriptor("powerPolicy") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
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
      phase: "early",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("batteryAlert") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
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
      phase: "early",
      criticality: "optional",
      activation: "resident",
      dependencies: ["state", "watch", "paths"],
      resolver: function() { return boot._resolveDescriptor("connectivity") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "screenshots",
      phase: "early",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "paths", "state", "watch"],
      resolver: function() { return boot._resolveDescriptor("screenshots") },
      ready: function() { return boot._lateReady("screenshots") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    },
    {
      id: "powerMenu",
      phase: "deferred",
      criticality: "optional",
      activation: "resident",
      dependencies: ["settings", "state", "watch", "menu", "session"],
      resolver: function() { return boot._resolveDescriptor("powerMenu") },
      teardown: null,
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 }
    }
  ]

  property var _queue: []
  property var _deferredQueue: []
  // The residents that exist to answer rather than to build, drained before
  // the entrance milestone (see _beginDrain and _earlyDescriptors).
  property var _earlyQueue: []
  property bool _earlyStarted: false
  // id -> descriptor and id -> [dependent ids], built once during
  // registration so the dependency cascade and lookups are O(edges)
  // instead of O(units) per step.
  property var _byId: ({})
  property var _dependents: ({})
  // Construction time per settled unit, keyed by id. Rebuilt only when a
  // reader asks for it (the two `boot` IPC verbs), because it is a diagnostic
  // snapshot and not boot state: nothing in the boot path reads it, so a
  // rebuild on every unit event is a full pass over the catalog for nobody.
  property var _report: ({})
  property bool _refreshingReadiness: false
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
  // Process start, stamped by the launcher that exec'd qs (the systemd unit
  // exports VIBRANIUM_SHELL_START_MS). 0 when the shell was started by hand,
  // in which case the boot figures fall back to this file's construction -
  // which is after Qt initialised and after this module's import set compiled,
  // so it under-reports the boot it names.
  property real processStartedAtMs: 0
  readonly property real _processStartedAtMs:
    boot.processStartedAtMs > 0 && boot.processStartedAtMs <= Date.now()
      ? boot.processStartedAtMs : boot._bootStartedAtMs

  function _sinceProcessStart() {
    return Math.max(0, Date.now() - boot._processStartedAtMs)
  }
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
    // Phase 2+ (the drain) needs both late halves: their imports are what
    // resolving any late unit compiles, so the drain waits for them while
    // the floor and Phase 1 are already on screen.
  }

  // The late halves of boot: BootBar.qml (the bar surface), BootServices.qml
  // (the qs.services singletons) and BootLate.qml (feature modules). All three
  // load asynchronously so their type loading happens off the UI thread
  // instead of blocking first paint. Each half imports only the module set it
  // resolves, so a half's compile is its own set rather than the union; that
  // is what keeps the bar, the surface a boot is waiting on, off the services'
  // and feature modules' file sets. They are adopted independently: the bar
  // half demands the bar and starts the early service tier, while the drain
  // waits for the feature half because the entrance and deferred queues
  // resolve types that live there.
  property var _lateBar: null
  property var _lateBarComponent: null
  property var _lateServices: null
  property var _lateServicesComponent: null
  property var _lateFeatures: null
  property var _lateFeaturesComponent: null
  // Halves that have not landed yet (Ready or Error). A demand that arrives
  // while this is above zero is stashed for the replay; a failed half stops
  // counting too, so one broken half cannot hold demands - or the drain that
  // sits behind them - forever.
  property int _halvesPending: 3
  property bool _drainStarted: false
  // Late-unit demands that arrived before the late half loaded (a bar
  // module hook ensuring its service during Phase 1). The resolver ran
  // with nothing to dispatch to, so the demand is replayed in _adoptLate
  // instead of leaving the unit starting forever.
  property var _pendingLateResolves: []
  // That replay, taken over by the pump once the late half lands.
  property var _replayQueue: []
  // A drain asked for before boot construction settled; the milestone's change
  // runs it (see _beginDrain).
  property bool _drainRequested: false

  function _loadLate() {
    // Order is the bar first (measured: the smallest set is the one on the
    // critical path), then the services the bar's modules read, then the
    // feature modules nothing on the first screen needs.
    boot._loadBarHalf()
    boot._loadServicesHalf()
    boot._loadFeaturesHalf()
  }

  // One half has landed, or failed and will never land.
  function _halfSettled() {
    if (boot._halvesPending > 0) boot._halvesPending--
    // The last half settling is the moment a stashed demand has nowhere left
    // to go: the replay drops what no half owns and releases the drain. It is
    // also the end of the boot's one-time construction - every adoption has
    // run its units - which is what the wallpaper's first fade waits for
    // (DesktopLayoutState.bootConstructionSettled). The replay runs first: it
    // is the turn that constructs the last of those units.
    if (boot._halvesPending === 0) {
      boot._replayNext()
      DesktopLayoutState.noteBootConstructionSettled()
    }
  }

  function _loadBarHalf() {
    if (boot._lateBar || boot._lateBarComponent) return
    const comp = Qt.createComponent("BootBar.qml", Component.Asynchronous)
    if (comp.status === Component.Ready) {
      boot._adoptBarHalf(comp)
    } else if (comp.status === Component.Error) {
      Log.error("boot: bar half failed to load: " + comp.errorString())
      boot._halfSettled()
    } else {
      boot._lateBarComponent = comp
      comp.statusChanged.connect(boot._onBarHalfStatus)
    }
  }

  function _onBarHalfStatus() {
    const comp = boot._lateBarComponent
    if (!comp || comp.status === Component.Loading) return
    comp.statusChanged.disconnect(boot._onBarHalfStatus)
    boot._lateBarComponent = null
    if (comp.status === Component.Ready) {
      boot._adoptBarHalf(comp)
      return
    }
    // The shell degrades to no bar; the feature half still lands and starts
    // the drain, and the entrance milestone falls back to its backstop.
    Log.error("boot: bar half failed to load: " + comp.errorString())
    boot._halfSettled()
  }

  function _loadServicesHalf() {
    if (boot._lateServices || boot._lateServicesComponent) return
    const comp = Qt.createComponent("BootServices.qml", Component.Asynchronous)
    if (comp.status === Component.Ready) {
      boot._adoptServicesHalf(comp)
    } else if (comp.status === Component.Error) {
      Log.error("boot: services half failed to load: " + comp.errorString())
      boot._halfSettled()
    } else {
      boot._lateServicesComponent = comp
      comp.statusChanged.connect(boot._onServicesHalfStatus)
    }
  }

  function _onServicesHalfStatus() {
    const comp = boot._lateServicesComponent
    if (!comp || comp.status === Component.Loading) return
    comp.statusChanged.disconnect(boot._onServicesHalfStatus)
    boot._lateServicesComponent = null
    if (comp.status === Component.Ready) {
      boot._adoptServicesHalf(comp)
      return
    }
    // The shell degrades to no service singletons: the demands that waited on
    // this half have nowhere to go, and _halfSettled lets the replay drop them
    // instead of holding the drain behind a half that will never land.
    Log.error("boot: services half failed to load: " + comp.errorString())
    boot._halfSettled()
  }

  function _loadFeaturesHalf() {
    if (boot._lateFeatures || boot._lateFeaturesComponent) return
    const comp = Qt.createComponent("BootLate.qml", Component.Asynchronous)
    if (comp.status === Component.Ready) {
      boot._adoptLate(comp)
    } else if (comp.status === Component.Error) {
      Log.error("boot: late half failed to load: " + comp.errorString())
      boot._halfSettled()
      boot._beginDrain()
    } else {
      boot._lateFeaturesComponent = comp
      comp.statusChanged.connect(boot._onFeaturesHalfStatus)
    }
  }

  function _onFeaturesHalfStatus() {
    const comp = boot._lateFeaturesComponent
    if (!comp || comp.status === Component.Loading) return
    comp.statusChanged.disconnect(boot._onFeaturesHalfStatus)
    boot._lateFeaturesComponent = null
    if (comp.status === Component.Ready) {
      boot._adoptLate(comp)
      return
    }
    Log.error("boot: late half failed to load: " + comp.errorString())
    boot._halfSettled()
    boot._beginDrain()
  }

  // The bar half landed. Services before the surface (see _startEarly): one
  // budgeted turn of the early tier runs before the bar's construction is
  // demanded, so the bus-name daemons exist while the bar is still compiling
  // instead of one entrance later. It is bounded by frameBudgetMs, so it
  // cannot starve the bar build it precedes.
  function _adoptBarHalf(comp) {
    boot._lateBar = comp.createObject(boot, { boot: boot })
    if (!boot._lateBar) {
      Log.error("boot: bar half failed to instantiate")
      boot._halfSettled()
      return
    }
    boot._startEarly()
    // The demand lives with the half that can serve it: a demand with nothing
    // to dispatch to would leave UnitGate marking the unit ready with the bar
    // nonexistent. The record's construction figure is the bar's own.
    try {
      UnitGate.ensure("bar", "boot")
    } catch (error) {
      // Recorded on the unit's record by UnitGate.
    }
    boot._replayNext()
    boot._halfSettled()
  }

  // The services half landed. Nothing is demanded from it here: the early tier
  // belongs to the bar half's adoption, and a unit whose turn has come is
  // resolved by the replay. Adopting this half is what lets the stashed
  // service demands move on.
  function _adoptServicesHalf(comp) {
    boot._lateServices = comp.createObject(boot, { boot: boot })
    if (!boot._lateServices) {
      Log.error("boot: services half failed to instantiate")
      boot._halfSettled()
      return
    }
    boot._replayNext()
    boot._halfSettled()
  }

  // The feature half landed. The annotation controller component lives here
  // with its import, and the drain is released now: its queues resolve feature
  // types, so it could not start earlier even if the bar half already had.
  function _adoptLate(comp) {
    boot._lateFeatures = comp.createObject(boot, { boot: boot })
    if (!boot._lateFeatures) {
      Log.error("boot: late half failed to instantiate")
      boot._beginDrain()
      return
    }
    annotationLoader.sourceComponent = boot._lateFeatures.annotationComponent()
    boot._replayNext()
    boot._halfSettled()
  }

  // Resolve one unit through whichever half is loaded and owns it. A half
  // answers false for an id it does not own, so this also answers "is the
  // owner here yet" without a second list of ids to keep in step.
  function _resolveLateNow(id) {
    if (boot._lateBar && boot._lateBar.resolve(id)) return true
    if (boot._lateServices && boot._lateServices.resolve(id)) return true
    if (boot._lateFeatures && boot._lateFeatures.resolve(id)) return true
    return false
  }

  // One turn of the late replay: resolve each stashed unit that has an owner
  // now, then refresh it so a unit with no ready predicate (or an already-true
  // one) settles instead of sitting in starting. A demand whose owner half is
  // still compiling keeps its place for that half's adoption. The replay goes
  // through the same frame budget as the drain: resolving a unit constructs a
  // real singleton (a window, a device handle, a history read), and the
  // stashed list is every service the bar demanded during Phase 1 - one
  // unbounded turn of exactly that work is the stall this budget removes.
  function _replayNext() {
    // Demands that arrived while a half was compiling are held off the queue;
    // an adoption (or the turn already scheduled) is what moves them on.
    if (boot._pendingLateResolves.length > 0) {
      boot._replayQueue = boot._replayQueue.concat(boot._pendingLateResolves)
      boot._pendingLateResolves = []
    }
    const deadline = Date.now() + boot.frameBudgetMs
    const pending = []
    let progressed = false
    // Whether this turn stopped on the budget with ids it never reached. Those
    // are owed another turn; the ids that failed are the only ones a turn has
    // actually proved something about.
    let cutShort = false
    while (boot._replayQueue.length > 0) {
      const id = boot._replayQueue.shift()
      let resolved = false
      try {
        resolved = boot._resolveLateNow(id)
      } catch (error) {
        Log.error("boot: late replay for unit " + id + " failed: " + String((error && error.message) || error))
      }
      if (resolved) {
        UnitGate.refresh(id)
        progressed = true
      } else {
        pending.push(id)
      }
      if (Date.now() >= deadline) {
        cutShort = boot._replayQueue.length > 0
        break
      }
    }
    boot._replayQueue = pending.concat(boot._replayQueue)
    if (boot._replayQueue.length > 0) {
      // A turn that ran out of frame budget never looked at what it left, so it
      // comes back for it even when the last half has already settled: the
      // early tier stashes a facade whose half is still compiling, and the
      // replay is the only thing that ever constructs it. Clearing the queue
      // here on a budget cut dropped those demands whole - a facade unit then
      // stayed stopped with nothing behind it, so its IPC target never existed.
      if (cutShort && progressed) {
        boot._requestPump(boot._replayNext)
        return
      }
      // What is left belongs to a half that has not landed. Only reschedule
      // while this turn made progress, so a half that never loads cannot spin
      // the pump; its adoption calls this again.
      if (boot._halvesPending > 0) {
        if (progressed) boot._requestPump(boot._replayNext)
        return
      }
    }
    // No half left that could serve these: the same demand today would sit
    // behind an always-missing half and hold the drain with it.
    boot._replayQueue = []
    if (boot._lateFeatures) boot._beginDrain()
  }

  function _beginDrain() {
    if (boot._drainStarted) return
    // The IPC surface does not wait for the construction milestone. A facade
    // unit's resident half is a singleton whose only job is to answer, and
    // `session` holds the lock/logout verbs, so a keybinding pressed while the
    // bar is still building its modules has to find its target rather than
    // fail. What those units put behind the facade (the launcher's index
    // build) holds itself back on its own milestone - see
    // AppLauncher._prewarm - so nothing expensive moves onto the module build
    // this phase exists to keep clear.
    boot._startEarly()
    // Phase order, not a delay: the drain waits for boot construction to
    // settle, so it cannot overlap the module build the entrance is
    // choreographed around. It does not wait for the entrance itself: every
    // resident service would then come up one animation late for frames the
    // entrance already draws, and the per-turn budget below is what keeps the
    // drain off those frames anyway.
    if (!DesktopLayoutState.bootEntranceSettled) {
      boot._drainRequested = true
      return
    }
    boot._drainRequested = false
    boot._drainStarted = true
    // The entrance queue resolves what the shell needs on screen. A first_use
    // unit is none of that: it is built by whoever demands it, through its own
    // UnitGate lease, and `first_use` is not a drain phase at all. Visual
    // surfaces are constructed by _bootVisuals and _adoptLate instead, which is
    // why neither is in either queue.
    // The phases are data on the descriptor, not two lists here. The pair this
    // replaces was a hardcoded 19-id deferral plus a hardcoded visual pair, so
    // adding a unit meant remembering to leave it out of the drain, and the
    // facades and `session` appeared in both the early queue and this one -
    // they were constructed, released (which runs the facade teardown) and
    // then ensured a second time, and their reported construction was the
    // second, trivial pass.
    //
    // `deferred` is not "everything left over": it is the units whose own
    // construction composes pages, scans directories or builds a panel tree
    // (the menu, the pickers, media art, the power menu). They run after the
    // entrance queue so that work cannot land on the frames the entrance is
    // drawing, which is the reason the drain itself waits for the milestone.
    boot._queue = boot._catalog.filter(descriptor => descriptor.phase === "entrance")
    boot._deferredQueue = boot._catalog.filter(descriptor => descriptor.phase === "deferred")
    // The contract is neutral, so the hook is bound here rather than by the
    // controller: a capture that asks for a view before any controller has
    // existed still gets one, because the demand reaches the layer that is
    // allowed to build it.
    AnnotationActions.bind(boot._ensureAnnotations)
    // Through the pump, like every later turn: Idle.run posts the turn as a
    // callLater, which the render loop services back to back with the other
    // callLaters before it draws - the 105ms frame the pump exists to avoid.
    boot._requestPump(boot._drainNext)
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
      case "annotations":      annotationLoader.active = true; break
      default:                  return boot._lateResolve(id)
    }
    return true
  }

  // Late-unit dispatch. A demand that lands before its half has loaded is
  // expected, not broken - Phase-1 surfaces ensure their services while the
  // halves still compile - so it is stashed for the replay rather than
  // resolved half-built. The drain itself only starts after the feature half
  // lands.
  function _lateResolve(id) {
    if (boot._resolveLateNow(id)) return true
    if (boot._halvesPending > 0) {
      if (boot._pendingLateResolves.indexOf(id) < 0) {
        boot._pendingLateResolves = boot._pendingLateResolves.concat([id])
      }
      Log.debug("boot: late half not loaded yet for unit " + id + ", demand stashed")
      return false
    }
    return false
  }

  function _lateReady(id) {
    if (boot._lateFeatures && boot._lateFeatures.readyState(id)) return true
    if (boot._lateServices && boot._lateServices.readyState(id)) return true
    if (boot._lateBar && boot._lateBar.readyState(id)) return true
    return false
  }

  function _lateTeardown(id) {
    if (boot._lateFeatures) boot._lateFeatures.teardown(id)
  }

  // Rebuild the diagnostic report. Called by the verbs that read it, never by
  // a boot phase.
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

  // The wider boot table, ordered by arrival. `status` keeps its
  // id -> constructionMs shape (the audit and vb-shell read it); this reports
  // the whole record per unit, which is what makes a regression - a unit that
  // constructs fast but lands late because it waited on a dependency -
  // visible instead of guessed at.
  function _timeline() {
    const rows = []
    for (let i = 0; i < boot._catalog.length; i++) {
      const id = boot._catalog[i].id
      const state = UnitGate.state(id)
      if (!state || state.state === "not_started") continue
      rows.push({
        id: id,
        phase: state.phase,
        state: state.state,
        constructionMs: state.constructionMs,
        readyMs: state.readyMs,
        totalMs: state.totalMs
      })
    }
    rows.sort((a, b) => a.totalMs - b.totalMs)
    return rows
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
      + boot._sinceProcessStart() + "ms, start " + boot.start
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
    // A demand before the feature half loads has no controller component to
    // build yet: stay retryable rather than failing the flow for the
    // whole session over a startup race.
    if (!boot._lateFeatures) return "pending"
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
      boot._scheduleRetryFor(id)
    }
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

  // The construction milestone owns when the background phases start (see
  // _beginDrain): the drain request parked there runs on this edge. The two
  // milestones are also the tail the verdict excludes - the bar's module build
  // and the entrance motion - so they are logged against the process start.
  Connections {
    target: DesktopLayoutState
    function onBootEntranceSettledChanged() {
      if (boot._drainRequested) boot._beginDrain()
      if (DesktopLayoutState.bootEntranceSettled) {
        Log.debug("boot: entrance settled in " + boot._sinceProcessStart() + "ms")
      }
    }
    function onBootEntrancePlayedChanged() {
      if (DesktopLayoutState.bootEntrancePlayed) {
        Log.debug("boot: entrance played in " + boot._sinceProcessStart() + "ms")
      }
    }
  }

  function _bootP0() {
    const floor = boot._catalog.filter(descriptor => descriptor.activation === "eager")
    for (let i = 0; i < floor.length; i++) {
      const descriptor = floor[i]
      UnitGate.ensure(descriptor.id, "boot")
      UnitGate.refresh(descriptor.id)
    }
  }

  function _bootVisuals() {
    // Phase 1: construct the visual surfaces right after the floor, before the
    // rest of the resident units drain. The drain queue excludes them (see
    // onCompleted).
    //
    // The wallpaper is constructed here, on this thread: it is the surface the
    // first frame paints, and its file set is small - the view, the transition
    // helper and its shader. The bar is the opposite: Bar.qml imports the
    // module registry, and a module import compiles its whole file set before
    // anything paints, so the bar is a late unit that _adoptLate demands. That
    // is what lets this surface map and fade while the registry is still being
    // compiled on the async half's worker thread. Both have their dependencies
    // in the floor, so neither waits for a service.
    const descriptor = boot._byId["wallpaper"]
    if (descriptor) {
      try {
        UnitGate.ensure("wallpaper", "boot")
        UnitGate.refresh("wallpaper")
      } catch (error) {
        // Recorded on the unit's record by UnitGate.
      }
    }
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

  // What one background turn may spend on this thread, in milliseconds.
  //
  // The entrance animation is drawing through the same thread, and the drain
  // starts the moment the late half lands - ~190ms of async type loading in,
  // which is the tail of that animation. Batching by unit count cannot bound
  // a frame: four facades are a millisecond and four units that build a
  // window, read a history file and open a device are ten times that, which
  // is the hitch this replaces. Only elapsed time holds across units whose
  // cost differs by two orders of magnitude, so every background phase
  // (drain, deferred drain, late replay) spends this per turn and hands the
  // thread back. Half a 60Hz frame leaves the scene-graph sync that draws the
  // animation its own half.
  readonly property real frameBudgetMs: 8

  // One turn of a background phase: run whole units until the budget is gone.
  // At least one unit always runs - an entry already over budget must still
  // make progress, or the pump would reschedule forever without advancing.
  // Returns nothing; callers own the queue and the rescheduling.
  function _budgetedTurn(queue) {
    const deadline = Date.now() + boot.frameBudgetMs
    while (queue.length > 0) {
      boot._drainOne(queue.shift())
      if (Date.now() >= deadline) break
    }
  }

  // The early tier: units that exist to answer or to keep machine state (the
  // session verbs, the lock, the notification bus name, the clipboard, the
  // policy daemons) and that construct no window of their own. The entrance
  // milestone exists to keep *surface* construction off the frames the
  // entrance draws, so these do not belong behind it: a notification sent
  // while the bar was still compiling used to be dropped, and a lock request
  // had no lock to reach.
  //
  // The tier is a phase on the descriptor, not a list here.
  function _earlyDescriptors() {
    return boot._catalog.filter(descriptor => descriptor.phase === "early")
  }

  // Begin the early tier. The first turn runs inline (called from _adoptLate,
  // just before the bar's construction is demanded) and the rest go through the
  // pump, so they land in the gaps between frames instead of in a chain of
  // callLaters the render loop services before it draws.
  function _startEarly() {
    if (boot._earlyStarted) return
    boot._earlyStarted = true
    boot._earlyQueue = boot._earlyDescriptors()
    boot._budgetedTurn(boot._earlyQueue)
    if (boot._earlyQueue.length > 0) boot._requestPump(boot._drainEarly)
  }

  function _drainEarly() {
    boot._budgetedTurn(boot._earlyQueue)
    // Through the pump, not Idle.run: the early tier is now ~20 units, and a
    // chain of callLaters is serviced back to back before the render loop gets
    // its turn - the 105ms frame the pump exists to prevent.
    if (boot._earlyQueue.length > 0) boot._requestPump(boot._drainEarly)
  }

  function _drainNext() {
    boot._budgetedTurn(boot._queue)
    if (boot._queue.length > 0) {
      boot._requestPump(boot._drainNext)
      return
    }
    if (boot._deferredQueue.length > 0) {
      boot._requestPump(boot._drainDeferred)
    }
  }

  function _drainDeferred() {
    boot._budgetedTurn(boot._deferredQueue)
    if (boot._deferredQueue.length > 0) {
      boot._requestPump(boot._drainDeferred)
    }
  }

  // The pump's hand-back to the render loop.
  //
  // A budgeted turn bounds what ONE turn costs, not how many turns share a
  // frame: rescheduling through Idle.run posts the next turn as a callLater,
  // and a stream of those is serviced back to back before the render loop
  // gets its turn - measured on a cold boot as a 105ms frame inside the
  // entrance, because eight residents were constructed in one pass. A
  // one-shot timer of a frame leaves the thread free between turns, so the
  // frame the entrance is drawing lands on schedule and the drain continues
  // in the next gap.
  // A single pump carries every background phase, in arrival order: a phase
  // that is mid-queue when another asks to start (the early tier is still
  // running when the drain is released at the milestone) must not lose its
  // continuation, which is what a one-slot `_pumpedFn` would do - it would
  // overwrite the early turn and leave the rest of that queue undrained.
  property var _pumpedFns: []

  function _requestPump(fn) {
    if (boot._pumpedFns.indexOf(fn) >= 0) return
    boot._pumpedFns = boot._pumpedFns.concat([fn])
    drainPump.restart()
  }

  function _pumpTurn() {
    const pending = boot._pumpedFns
    if (pending.length === 0) return
    boot._pumpedFns = pending.slice(1)
    pending[0]()
    // One function runs per tick, and a finished phase does not reschedule
    // itself - the early drain stops when its queue is empty while the drain
    // it shared the pump with is still queued. Wake whatever is left, or that
    // continuation sits in the queue with no timer running.
    if (boot._pumpedFns.length > 0) drainPump.restart()
  }

  Timer {
    id: drainPump

    interval: 16
    repeat: false
    onTriggered: boot._pumpTurn()
  }

  // Bounded retries. Every non-floor descriptor declares one: a failure is the
  // one arrival nothing else wakes up, and at boot the plausible causes are
  // transient (a bus name not claimed yet, a PipeWire socket not listening, a
  // device handle not exported). The floor's failures are deterministic - a
  // missing path, an unparsable catalog - and retrying them only delays the
  // verdict. The delay is UnitGate's backoff, doubled per attempt and capped
  // by the descriptor.
  property string _retryUnit: ""

  function _scheduleRetryFor(id) {
    const state = UnitGate.state(id)
    if (!state || state.state !== "failed") return
    const descriptor = boot._byId[id]
    if (!descriptor || !descriptor.retry) return
    if (descriptor.retry.maxAttempts <= 0) return
    if (state.retryCount >= descriptor.retry.maxAttempts) return
    boot._retryUnit = id
    retryPump.interval = Math.max(1, Math.min(descriptor.retry.maxBackoffMs,
      descriptor.retry.backoffMs * Math.pow(2, state.retryCount)))
    retryPump.restart()
  }

  function _retryNow() {
    const id = boot._retryUnit
    boot._retryUnit = ""
    if (id === "") return
    if (UnitGate.retry(id)) boot._refreshUnit(id)
  }

  QQ.Timer {
    id: retryPump
    repeat: false
    onTriggered: boot._retryNow()
  }

  IpcHandler {
    target: "boot"

    function status(): string {
      boot._syncReport()
      return JSON.stringify(boot._report)
    }
    function state(): string {
      return JSON.stringify(boot._stateSnapshot())
    }
    function timeline(): string {
      return JSON.stringify(boot._timeline())
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
