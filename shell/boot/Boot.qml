pragma ComponentBehavior: Bound
import QtQml
import QtQuick
import QtQuick as QQ
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "BootTrace.js" as BootTrace
import "../common/text/IpcProtocol.js" as Protocol
import "Units.catalog.js" as Units
import "Units.adapter.js" as Adapter
import qs.common
import qs.common as Common
import qs.features.wallpaper
import qs.boot
import qs.features.bar.control
import qs.features.colorPicker
import "generated/floor" as GeneratedFloor
import "generated/bar" as GeneratedBar
import "generated/demand" as GeneratedDemand
// NOTE: qs.services and the other qs.features.* modules are imported by the
// late halves, not here. Importing a module loads its whole file set before
// anything paints, so every module named here is on the time-to-paint path.
// The bar is the largest of those sets by far - its singleton imports the
// whole module registry - so it is a late unit: the wallpaper is the surface
// that compiles and maps first, and the bar arrives when the async half lands
// (see _bootVisuals). Floor and Phase 1 need only the three above.
//
// The late work is split into two components so features do not wait for
// services they never use: BootServices.qml carries the service singletons,
// BootLate.qml carries the feature modules (menu, launcher, apps, pickers,
// annotations, notifications). Both load in the same turn and are adopted
// independently. The bar runtime is a third, demand-loaded instance owned by
// the persisted master switch, not by the boot graph.

Item {
  id: boot

  // Phase 0 observation. One monotonic clock, one origin: ElapsedTimer is the
  // only clock used by the recorder. A sample taken before onCompleted is
  // negative and the recorder clamps it to zero rather than reporting noise.
  ElapsedTimer { id: bootMono }

  property real bootOriginMs: 0

  function nowMs(): real { return bootMono.elapsedMs() - boot.bootOriginMs }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (event.name === "custom") IpcRouter.invokeShortcut(event.data)
    }
  }

  readonly property var _catalog: Adapter.descriptors(boot)

  // Generated dispatch maps for the ids this component owns. Each row is
  // inert until its id is demanded; hook instances receive this Boot so the
  // bar runtime and the annotation loader are reached only from resolve().
  property var floorHandlers: GeneratedFloor.FloorHandlers { boot: boot }
  property var barHandlers: GeneratedBar.BarHandlers { boot: boot }
  property var demandHandlers: GeneratedDemand.DemandHandlers { boot: boot }

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

  // Shell-relative elapsed time. Pre-QML time is intentionally unknown: the
  // systemd unit carries no launcher stamp and the report says so.
  function _sinceProcessStart() {
    return Math.max(0, Date.now() - boot._bootStartedAtMs)
  }

  // --- Phase 0 capture -----------------------------------------------------
  // Observation only. No latch, provider, lease, timer or log line depends on
  // anything below: every hook notes a fact that has already happened, and a
  // refused emit costs at most an event id. The recorder is one closure per
  // Boot; `nowMs()` above is its only clock.
  property var trace: BootTrace.create({ now: function () { return boot.nowMs() } })
  property bool _traceSealed: false
  property bool _verdictPublished: false
  property bool _drainCompleted: false
  property bool _historicalPlayed: false
  property int _bootBeginId: 0
  property int _catalogDigestId: 0
  property int _entranceSettledDecisionId: 0
  property int _entrancePlayedDecisionId: 0
  property int _constructionDecisionId: 0
  property int _servicesRequestId: 0
  property int _featuresRequestId: 0
  property int _drainAdmissionId: 0
  property int _servicesToken: 0
  property int _featuresToken: 0
  property int _barToken: 0
  property var _essentialStateIds: []
  property var _openTraceTokens: []
  property var _queueAdmissionClosed: ({})
  property bool _servicesDemandObserved: false
  property bool _servicesResultObserved: false
  property bool _featuresDemandObserved: false
  property bool _featuresResultObserved: false
  property bool _barObservationOpened: false

  function _traceRefs() {
    const out = []
    for (let i = 0; i < arguments.length; i++) {
      const id = arguments[i]
      if (typeof id === "number" && id > 0 && Math.floor(id) === id) out.push(id)
    }
    return out.slice(0, 16)
  }

  function _verdictCauses() {
    const out = boot._essentialStateIds.slice()
    if (boot._bootBeginId) out.push(boot._bootBeginId)
    return out.slice(0, 16)
  }

  function _trackTraceToken(source, token) {
    if (!token) return
    boot._openTraceTokens = boot._openTraceTokens.concat([{ source: source, token: token }])
  }

  function _closeTraceToken(source, token, outcome) {
    if (!token) return false
    boot.trace.closeWork(source, token, outcome)
    const next = []
    for (let i = 0; i < boot._openTraceTokens.length; i++) {
      if (boot._openTraceTokens[i].token !== token) next.push(boot._openTraceTokens[i])
    }
    boot._openTraceTokens = next
    boot._maybeSealTrace()
    return true
  }

  function _closePendingTraceTokens() {
    const pending = boot._openTraceTokens.slice()
    boot._openTraceTokens = []
    for (let i = 0; i < pending.length; i++) {
      try {
        boot.trace.closeWork(pending[i].source, pending[i].token, "teardown")
      } catch (error) {
      }
    }
  }

  function _sealTrace(reason) {
    if (boot._traceSealed) return
    const report = boot.trace.seal(reason)
    if (report && report.sealed === true) {
      boot._traceSealed = true
      traceWatchdog.stop()
    }
  }

  // A normal seal is only asked for at a real completion boundary, and only
  // when the recorder's own conditions already hold. A refused normal seal
  // leaves capture open with integrity untouched; the gate asks only at a real
  // completion boundary.
  function _maybeSealTrace() {
    if (boot._traceSealed || !boot._verdictPublished || !boot._drainCompleted) return
    const report = boot.trace.snapshot()
    if (report.sealed) {
      boot._traceSealed = true
      traceWatchdog.stop()
      return
    }
    if (!report.integrity.valid) return
    if (!report.firstVerdict) return
    if (!report.endpoints.entrancePlayed && !boot._historicalPlayed) return
    const rows = report.ledger || ({})
    const keys = Object.keys(rows)
    for (let i = 0; i < keys.length; i++) {
      const row = rows[keys[i]]
      if (row.terminal === null || row.inFlight !== 0) return
    }
    boot._sealTrace("normal")
  }

  // The watchdog polls on the GUI thread and can close trace storage only.
  // A blocked thread cannot tick it; once unblocked, a tick past the deadline
  // seals capture without touching a latch, a queue or a log line.
  QQ.Timer {
    id: traceWatchdog
    interval: 100
    repeat: true
    running: false
    onTriggered: {
      if (boot._traceSealed || boot.trace.snapshot().sealed) {
        boot._traceSealed = true
        traceWatchdog.stop()
        return
      }
      if (boot.trace.watchdogFired(boot.nowMs())) {
        boot._traceSealed = true
        traceWatchdog.stop()
      }
    }
  }

  // The neutral observer interface DesktopLayoutState calls. The decision id
  // is allocated while the caller's boolean is still false, so a synchronous
  // subscriber can link to the cause of the change it is observing.
  function _observeMilestone(milestone, reason, participant, causes) {
    if (!boot.trace) return 0
    const refs = boot._traceRefs(boot._bootBeginId)
    if (Array.isArray(causes)) {
      for (let i = 0; i < causes.length && refs.length < 16; i++) {
        if (typeof causes[i] === "number" && causes[i] > 0) refs.push(causes[i])
      }
    }
    const id = boot.trace.emit("milestone.decision", {
      milestone: milestone,
      reason: reason === undefined || reason === null ? "unknown" : String(reason).slice(0, 64),
      participant: participant === undefined || participant === null ? "" : String(participant).slice(0, 64),
      causes: refs
    })
    if (id && milestone === "settled") boot._entranceSettledDecisionId = id
    if (id && milestone === "played") boot._entrancePlayedDecisionId = id
    if (id && milestone === "construction") boot._constructionDecisionId = id
    return id
  }

  function _observeAlreadyResolved(milestone, participant) {
    if (!boot.trace) return
    // A latch already true before installation is history, not a timed
    // predecessor: it satisfies the played precondition but has no endpoint.
    if (milestone === "played") boot._historicalPlayed = true
    boot.trace.alreadyResolved(milestone,
      participant === undefined || participant === null ? "" : String(participant).slice(0, 64))
  }

  function _installMilestoneObserver() {
    if (DesktopLayoutState.milestoneObserver !== null) return
    DesktopLayoutState.milestoneObserver = boot
    if (DesktopLayoutState.bootConstructionSettled) boot._observeAlreadyResolved("construction", "")
    if (DesktopLayoutState.bootEntranceSettled) boot._observeAlreadyResolved("settled", "")
    if (DesktopLayoutState.bootEntrancePlayed) boot._observeAlreadyResolved("played", "")
  }

  // One accepted demand gets one provider request and one work token, on both
  // the synchronous and asynchronous component paths.
  function _observeServicesDemand() {
    if (boot._servicesDemandObserved) return
    boot._servicesDemandObserved = true
    boot._servicesRequestId = boot.trace.emit("provider.request", {
      source: "provider:services", reason: "lateServicesHalf",
      causes: boot._traceRefs(boot._bootBeginId)
    })
    boot._servicesToken = boot.trace.openWork("provider:services", "request")
    boot._trackTraceToken("provider:services", boot._servicesToken)
  }

  function _observeServicesResult(outcome) {
    if (!boot._servicesDemandObserved || boot._servicesResultObserved) return
    boot._servicesResultObserved = true
    boot.trace.emit("provider.result", {
      source: "provider:services", outcome: outcome,
      causes: boot._traceRefs(boot._servicesRequestId, boot._bootBeginId)
    })
    boot._closeTraceToken("provider:services", boot._servicesToken, outcome)
    boot._servicesToken = 0
    boot.trace.closeAdmission("provider:services", outcome)
    boot._maybeSealTrace()
  }

  function _observeFeaturesDemand(reason) {
    if (boot._featuresDemandObserved) return
    boot._featuresDemandObserved = true
    boot._featuresRequestId = boot.trace.emit("provider.request", {
      source: "provider:features",
      reason: reason === undefined || reason === null ? "featuresNeeded" : String(reason).slice(0, 64),
      causes: boot._traceRefs(boot._entranceSettledDecisionId, boot._entrancePlayedDecisionId,
        boot._bootBeginId)
    })
    boot._featuresToken = boot.trace.openWork("provider:features", "request")
    boot._trackTraceToken("provider:features", boot._featuresToken)
  }

  function _observeFeaturesResult(outcome) {
    if (!boot._featuresDemandObserved || boot._featuresResultObserved) return
    boot._featuresResultObserved = true
    boot.trace.emit("provider.result", {
      source: "provider:features", outcome: outcome,
      causes: boot._traceRefs(boot._featuresRequestId, boot._entranceSettledDecisionId,
        boot._bootBeginId)
    })
    boot._closeTraceToken("provider:features", boot._featuresToken, outcome)
    boot._featuresToken = 0
    boot.trace.closeAdmission("provider:features", outcome)
    boot._maybeSealTrace()
  }

  function _closeQueueLedger(source, reason) {
    if (boot._queueAdmissionClosed[source] === true) return
    boot._queueAdmissionClosed[source] = true
    boot.trace.closeAdmission(source, reason)
    boot._maybeSealTrace()
  }

  function _drainVia() {
    if (boot._lateFeatures) return "features"
    if (boot._halvesPending === 0) return "fallback"
    return "pending"
  }

  function _drainCauses() {
    return boot._traceRefs(boot._entrancePlayedDecisionId, boot._entranceSettledDecisionId,
      boot._featuresRequestId, boot._bootBeginId)
  }

  function _completeDrain() {
    if (!boot._drainStarted) return
    boot._drainCompleted = true
    // A source that never arrived is known to have no work at this boundary;
    // a source that arrived still has to close through its own real path.
    const sources = ["provider:services", "provider:features", "surface:bar",
      "queue:early", "queue:entrance", "queue:deferred", "queue:replay"]
    for (let i = 0; i < sources.length; i++) {
      const row = boot.trace.snapshot().ledger[sources[i]]
      if (row && !row.arrived && row.terminal === null) {
        boot.trace.skip(sources[i], "noDemandAtDrainComplete")
      }
    }
    boot.trace.emit("endpoint.drainComplete", {
      causes: boot._traceRefs(boot._drainAdmissionId, boot._entrancePlayedDecisionId,
        boot._bootBeginId)
    })
    boot._maybeSealTrace()
  }

  function _pumpSource(fn) {
    if (fn === boot._drainEarly) return "queue:early"
    if (fn === boot._drainNext) return "queue:entrance"
    if (fn === boot._drainDeferred) return "queue:deferred"
    if (fn === boot._replayNext) return "queue:replay"
    return ""
  }

  // Both routes hand out the same bounded report. The base fields are never
  // pruned; only the optional causal projection is, parallel branches first
  // and then chain tails, and only on a detached copy of the snapshot.
  function _wireBytes(report) {
    return Protocol.asciiBytes(Protocol.encode(Protocol.ok(report, "boottime")))
  }

  function _markReplyOmission(chain) {
    chain.status = "partial"
    if (!Array.isArray(chain.unobserved)) chain.unobserved = []
    for (let i = 0; i < chain.unobserved.length; i++) {
      if (chain.unobserved[i] && chain.unobserved[i].reason === "replyOmission") return false
    }
    chain.unobserved.push({ reason: "replyOmission" })
    return true
  }

  function _fitBootReport(report) {
    if (boot._wireBytes(report) <= Protocol.MAX_REPLY_BYTES) return report
    const fitted = JSON.parse(JSON.stringify(report))
    const chains = fitted.chains || ({})
    const keys = Object.keys(chains)
    let omitted = 0
    for (let i = 0; i < keys.length; i++) {
      const chain = chains[keys[i]]
      if (Array.isArray(chain.parallel) && chain.parallel.length > 0) {
        chain.parallel = []
        if (boot._markReplyOmission(chain)) omitted++
      }
      if (boot._wireBytes(fitted) <= Protocol.MAX_REPLY_BYTES) break
    }
    let guard = 0
    while (boot._wireBytes(fitted) > Protocol.MAX_REPLY_BYTES && guard < 64) {
      let changed = 0
      for (let i = 0; i < keys.length; i++) {
        const chain = chains[keys[i]]
        if (Array.isArray(chain.chain) && chain.chain.length > 1) {
          chain.chain.pop()
          if (boot._markReplyOmission(chain)) changed++
        }
      }
      if (changed === 0) break
      omitted += changed
      guard++
    }
    fitted.coverage.replyOmitted = (fitted.coverage.replyOmitted || 0) + omitted
    fitted.truncated = true
    return fitted
  }

  function jsonOf(value): string { return JSON.stringify(value) }

  function _bootReport() {
    return boot._fitBootReport(boot.trace.snapshot())
  }

  // Called after each register() closes, never inside its inline route map:
  // the map stays a plain route table, and a failed transport observation
  // cannot abort capture, change the registration result or print a line.
  function _noteGatewayRegistration(target, valid) {
    try {
      boot.trace.emit("gateway.registered", {
        valid: Boolean(valid), target: String(target)
      })
    } catch (error) {
    }
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
    // Clock boundary: one monotonic origin, no launcher stamp. Pre-QML time is
    // unknown and the report states that instead of estimating it.
    boot.bootOriginMs = bootMono.elapsedMs()
    const origin = { source: "unknown", estimate: null }
    boot.trace.setContext(origin, Units.digest())
    boot._bootBeginId = boot.trace.emit("boot.begin", {
      source: origin.source, estimateMs: origin.estimate
    })
    boot.trace.armWatchdog(boot.nowMs(), 5000)
    traceWatchdog.start()
    boot._installMilestoneObserver()
    // The two transport targets are registered before anything can ask for
    // help or status. These are constant closures over boot's own projections;
    // the router owns parsing, validation and paging.
    const shellRegistered = IpcRouter.register("shell", boot, {
      "shell.status": function () { return boot._shellStatus() },
      "shell.doctor": function () { return boot._shellDoctor() },
      "shell.ping": function () { return "pong" }
    })
    boot._noteGatewayRegistration("shell", shellRegistered)
    const bootRegistered = IpcRouter.register("boot", boot, {
      "boot.status": function () { return boot._shellStatus() },
      "boot.state": function () { return boot._bootState() },
      "boot.timeline": function () { return boot._bootTimeline() },
      "boot.time": function () { return jsonOf(boot._bootReport()) },
      "boot.ping": function () { return "pong" }
    })
    boot._noteGatewayRegistration("boot", bootRegistered)
    // The loaders own the URL loads; Boot keeps the observation and adoption
    // handlers. Direct signal connections preserve the inline/deferred caller
    // order without installing a loader observer in production. `failed`
    // carries the loader's error class: loadError, createObjectNull or
    // createObjectThrew (the last two take Boot's instantiate fallback).
    servicesLoader.failed.connect(boot._onServicesFailed)
    servicesLoader.adopted.connect(boot._adoptServicesHalf)
    featuresLoader.failed.connect(boot._onFeaturesFailed)
    featuresLoader.adopted.connect(boot._adoptLate)
    // Fired first so the late half compiles on a worker thread while the
    // floor and Phase 1 drain on this one. Nothing below waits for it:
    // _beginDrain runs when it lands.
    boot._loadLate()
    const catalogOk = boot._registerCatalog()
    boot._catalogDigestId = boot.trace.emit("catalog.registered", {
      valid: catalogOk === true, digest: boot.start
    })
    if (!catalogOk) {
      boot._sealTrace("aborted")
      return
    }
    boot._catalogRegistered = true
    // The bar lease can only be acquired once its descriptor is registered.
    boot._reconcileBar()
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

  Component.onDestruction: {
    // Retire queued callbacks and close their open tokens while the recorder
    // still exists, before anything below detaches or closes trace storage.
    bootPump.shutdown()
    // Cancel both URL loads before anything detaches or closes trace storage.
    // Teardown is cancellation: a stale Ready/Error callback cannot adopt a
    // half or invoke a Boot fallback, and no failed result is fabricated.
    servicesLoader.teardown()
    featuresLoader.teardown()
    // Owner-guarded detach: never clear an observer installed by somebody
    // else. Teardown observation is best effort and cannot throw.
    if (DesktopLayoutState.milestoneObserver === boot) DesktopLayoutState.milestoneObserver = null
    IpcRouter.unregister("shell", boot)
    IpcRouter.unregister("boot", boot)
    try {
      boot._closePendingTraceTokens()
      traceWatchdog.stop()
    } catch (error) {
    }
  }

  // Shared projections. The native handlers below keep their signatures and
  // replies; the router calls these same functions so there is one source.
  function _shellStatus(): string {
    boot._syncReport()
    return JSON.stringify(boot._report)
  }

  function _shellDoctor(): string {
    boot._syncReport()
    return JSON.stringify(boot._audit())
  }

  function _bootState(): string { return JSON.stringify(boot._stateSnapshot()) }
  function _bootTimeline(): string { return JSON.stringify(boot._timeline()) }

  // The late halves of boot: the resident Bar control, BootServices.qml
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
  property var _lateFeatures: null
  // Each late half is one URL load owned by this Boot. The loader compiles the
  // component asynchronously and creates its object with this Boot as owner;
  // Boot still decides *when* to request and observes the provider work itself.
  // `observer` stays null in production: the pilot trace's provider events come
  // from Boot's own observation functions, never from the loader's test seam.
  AsyncLoader {
    id: servicesLoader
    sourceUrl: "BootServices.qml"
    owner: boot
    createProperties: ({ boot: boot })
    observer: null
  }
  AsyncLoader {
    id: featuresLoader
    sourceUrl: "BootLate.qml"
    owner: boot
    createProperties: ({ boot: boot })
    observer: null
  }
  // Halves that have not landed yet (Ready or Error). A demand that arrives
  // while this is above zero is stashed for the replay; a failed half stops
  // counting too, so one broken half cannot hold demands - or the drain that
  // sits behind them - forever.
  property int _halvesPending: 3
  // The halves whose adoption builds units on this thread: the bar (its
  // demand constructs the surface) and the services. The feature half only
  // dispatches - BootLate.qml builds nothing at construction - so the surfaces
  // waiting on the construction milestone must not be held behind its compile,
  // which is the longest of the three.
  property int _constructHalvesPending: 2
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

  // The bar runtime is a URL-loaded instance, not a boot singleton. The URL is
  // empty on a cold shell and only set while the master switch is on.
  property int _barGeneration: 0
  property bool _barDecisionMade: false
  property bool _barLeaseHeld: false
  property var _barRuntimeItem: null
  // The early tier and the bar lease must not start until every descriptor is
  // registered; a unit change raised mid-registration is not a demand yet.
  property bool _catalogRegistered: false

  function _loadLate() {
    // Order is the bar first (measured: the smallest set is the one on the
    // critical path), then the services the bar's modules read.
    //
    // The feature half waits for the bar's entrance (see the
    // bootEntranceSettled handler) instead of loading here. Its compile is the
    // longest of the three, and it shares the type loader with the bar's
    // per-module builds: started alongside them it measured as the reason a
    // bar module that builds in ~5ms took ~30ms each, which is ~570ms on the
    // bar's path to screen. Nothing on the first screen resolves a feature
    // type, and the entrance queue drains after the entrance anyway, so the
    // wait costs the first screen nothing.
    // The resident control is light: resolving `Bar` here loads no visual bar
    // type. It registers `bar` IPC and the menu providers before any demand,
    // so Settings and the CLI work even when the runtime never mounts.
    void BarControl.tag
    void ColorPickerController.tag
    boot._loadServicesHalf()
  }

  // One half has landed, or failed and will never land. `heavy` marks a half
  // whose adoption constructs units on this thread; see
  // _constructHalvesPending.
  function _halfSettled(heavy) {
    if (boot._halvesPending > 0) boot._halvesPending--
    if (boot._constructHalvesPending > 0 && heavy === true) boot._constructHalvesPending--
    // The construction milestone: the wallpaper's first fade waits for it
    // (DesktopLayoutState.bootConstructionSettled) and nothing else does, so
    // it names the end of the turns that block this thread rather than the end
    // of the feature half's compile. Each heavy adoption replays its stashed
    // demands before this, so the turn that constructs the last of its units
    // has already run.
    if (boot._constructHalvesPending === 0) {
      DesktopLayoutState.noteBootConstructionSettled("lateHalvesSettled")
    }
    // The last half settling is the moment a stashed demand has nowhere left
    // to go: the replay drops what no half owns and releases the drain.
    if (boot._halvesPending === 0) boot._replayNext()
  }

  // Every half that cannot land goes through here. Settling is what releases
  // its slot: only _halfSettled decrements _halvesPending, so a failure that
  // logged and returned instead left the replay stashing demands and the drain
  // parked with units in starting. The late paths call _beginDrain right after,
  // when the last half settling means no owner is left to release it.
  function _failHalf(label, heavy) {
    Log.error("boot: " + label)
    boot._halfSettled(heavy)
  }

  // The visual bar is not a boot half any more. The resident `Bar` control is
  // constructed by this module's import; the visual runtime is demand-loaded
  // by URL only while the persisted master switch is on. A cold disabled shell
  // resolves no visual bar type and constructs no bar window.
  function _barDemand() {
    return Settings.ready === true && Settings.statusbarEnabled === true
  }

  function _mountBarRuntime() {
    if (!boot._barDemand()) return false
    if (boot._barRuntimeItem || barRuntimeLoader.status === Loader.Loading) return true
    boot._barGeneration++
    barRuntimeLoader.active = true
    barRuntimeLoader.setSource(Qt.resolvedUrl("../features/bar/BarRuntime.qml"), {
      control: BarControl,
      generation: boot._barGeneration
    })
    return true
  }

  function _unmountBarRuntime() {
    // Invalidate the outstanding load identity before clearing the URL, so a
    // late Loaded or Error handler cannot attach a retired runtime.
    boot._barGeneration++
    boot._barRuntimeItem = null
    barRuntimeLoader.active = false
    barRuntimeLoader.source = ""
  }

  function _barRuntimeAccepted(item) {
    if (!item || item.generation !== boot._barGeneration || !boot._barDemand()) {
      return false
    }
    boot._barRuntimeItem = item
    boot._settleBarHalf("adopted")
    UnitGate.refresh("bar")
    return true
  }

  // The bar's construction slot is settled exactly once per boot. A later
  // enable has no boot slot to decrement; it uses the runtime's local reveal.
  // The startup decision obligation is opened on the first entry and settled
  // through this same guard; the Loader generation is a separate runtime fact.
  function _settleBarHalf(outcome) {
    if (!boot._barObservationOpened) {
      boot._barObservationOpened = true
      boot._barToken = boot.trace.openWork("surface:bar", "startupDecision")
      boot._trackTraceToken("surface:bar", boot._barToken)
    }
    if (boot._barDecisionMade) return
    boot._barDecisionMade = true
    const decision = outcome === "skipped" ? "skipped" : "adopted"
    boot._closeTraceToken("surface:bar", boot._barToken, decision)
    boot._barToken = 0
    if (decision === "skipped") {
      boot.trace.skip("surface:bar", "barAbsent")
    } else {
      boot.trace.closeAdmission("surface:bar", decision)
    }
    // The services half owns the first early-tier turn. Starting it here can
    // land before _bootP0(), leaving facade dependencies blocked with no
    // later edge to re-ensure them (AppLauncher's IPC target among them).
    boot._halfSettled(true)
    boot._maybeSealTrace()
  }

  // A known-absent bar settles the entrance wait and retires only its played
  // obligation, leaving an enabled wallpaper's own fade to report its finish.
  function _barAbsent() {
    if (boot._barDecisionMade) return
    boot._settleBarHalf("skipped")
    DesktopLayoutState.noteBootEntranceSettled("barAbsent")
    DesktopLayoutState.retireBootEntranceParticipant("bar")
    boot._loadFeaturesHalf("barAbsent")
  }

  // One owner for the master setting across the whole shell process.
  function _reconcileBar() {
    if (!boot._catalogRegistered || !Settings.ready) return
    const want = Settings.statusbarEnabled === true
    if (want) {
      // Re-ensuring is idempotent and re-checks blocked dependencies, so this
      // also lands the bar once its floor dependencies become ready.
      const result = UnitGate.ensure("bar", "bar-settings")
      if (result && result.lease) boot._barLeaseHeld = true
      // The initial construction slot is the settings decision, not the
      // runtime's compile. Wallpaper's first fade waits on this milestone, so
      // holding it for a module-heavy URL load would put a second, later
      // compile on the first-paint path.
      boot._settleBarHalf("adopted")
      return
    }
    if (boot._barLeaseHeld) {
      boot._barLeaseHeld = false
      UnitGate.releaseOwner("bar-settings")
    }
    boot._unmountBarRuntime()
    boot._barAbsent()
  }

  // One accepted demand per half. A loader that is loading or already adopted
  // owns an outstanding request; a terminal failure is not refusal, so a later
  // demand is allowed to request again. The loader's own load() guard is a
  // second line of defence, not a reason to emit a duplicate provider.request.
  function _loadServicesHalf() {
    if (boot._lateServices || servicesLoader.state === "loading"
        || servicesLoader.state === "adopted" || servicesLoader.instance !== null) return
    boot._observeServicesDemand()
    servicesLoader.load()
  }

  function _onServicesFailed(errorClass, attemptId, detail) {
    if (errorClass !== "loadError") {
      // Null (or throwing) createObject: no second Log.error line here; the
      // shared instantiate fallback logs through _failHalf as before.
      boot._observeServicesResult("failed")
      boot._failHalf("services half failed to instantiate", true)
      return
    }
    // The shell degrades to no service singletons: the demands that waited on
    // this half have nowhere to go, and _halfSettled lets the replay drop them
    // instead of holding the drain behind a half that will never land. Log,
    // observation, settle is the order on both the synchronous and deferred
    // component paths.
    Log.error("boot: services half failed to load: " + detail)
    boot._observeServicesResult("failed")
    boot._halfSettled(true)
  }

  // A component that resolves Error inside load() emits before load() returns;
  // a deferred one emits on statusChanged. The original late half logged before
  // observing on the first path and observed before _failHalf logged on the
  // second, so the flag preserves that caller order without a loader observer.
  property bool _featuresLoadSync: false

  function _loadFeaturesHalf(reason) {
    if (boot._lateFeatures || featuresLoader.state === "loading"
        || featuresLoader.state === "adopted" || featuresLoader.instance !== null) return
    boot._observeFeaturesDemand(reason)
    boot._featuresLoadSync = true
    featuresLoader.load()
    boot._featuresLoadSync = false
  }

  function _onFeaturesFailed(errorClass, attemptId, detail) {
    if (errorClass !== "loadError") {
      boot._observeFeaturesResult("failed")
      boot._failHalf("late half failed to instantiate")
      boot._beginDrain()
      return
    }
    if (boot._featuresLoadSync) {
      Log.error("boot: late half failed to load: " + detail)
      boot._observeFeaturesResult("failed")
      boot._halfSettled()
    } else {
      boot._observeFeaturesResult("failed")
      boot._failHalf("late half failed to load: " + detail)
    }
    boot._beginDrain()
  }

  // The services half landed. Nothing is demanded from it here: the early tier
  // belongs to the bar half's adoption, and a unit whose turn has come is
  // resolved by the replay. Adopting this half is what lets the stashed
  // service demands move on.
  function _adoptServicesHalf(object) {
    // The loader has already created this object with boot as owner. A null
    // here is a defensive no-op: the loader reports a null createObject as a
    // failed edge and never emits adopted for it.
    boot._lateServices = object
    if (!boot._lateServices) return
    boot._observeServicesResult("adopted")
    Log.debug("boot: services half adopted in " + boot._sinceProcessStart() + "ms")
    // The early tier is the service singletons and the daemons that answer
    // IPC, and this half is what builds most of them. Starting it here instead
    // of only at the bar's adoption is what keeps the bar's module compile off
    // the readiness path of `session` and `lockscreen`: a demand whose owner
    // is still compiling is stashed for the replay, so the units this half
    // does own are built now and the others wait for their own half.
    boot._startEarly()
    boot._replayNext()
    boot._halfSettled(true)
  }

  // The feature half landed. The annotation controller component lives here
  // with its import, and the drain is released now: its queues resolve feature
  // types, so it could not start earlier even if the bar half already had.
  function _adoptLate(object) {
    // Already created by the loader with boot as owner; see _adoptServicesHalf
    // for why the null branch is only a defensive no-op.
    boot._lateFeatures = object
    if (!boot._lateFeatures) return
    boot._observeFeaturesResult("adopted")
    Log.debug("boot: late half adopted in " + boot._sinceProcessStart() + "ms")
    // `lockscreen` is essential and lives in this half, so the tier starts here
    // too when the bar's adoption did not already start it. Idempotent.
    boot._startEarly()
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
    let head = 0
    while (head < boot._replayQueue.length) {
      const id = boot._replayQueue[head++]
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
        cutShort = head < boot._replayQueue.length
        break
      }
    }
    // Whatever the turn never reached, behind the ids that failed.
    boot._replayQueue = pending.concat(boot._replayQueue.slice(head))
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
    boot._closeQueueLedger("queue:replay", "noHalfCanServe")
    if (boot._lateFeatures) boot._beginDrain()
  }

  function _beginDrain() {
    // The guard inputs are visible here: the feature half, or no half left
    // that could land, or a half still compiling. Eligibility is noted even
    // when this call is parked; admission is noted only when it starts.
    boot.trace.emit("drain.eligibility", {
      via: boot._drainVia(), causes: boot._drainCauses()
    })
    if (boot._drainStarted) return
    // The entrance queue resolves its units through the feature half, so a
    // release that lands while that half is still compiling would demand types
    // it cannot dispatch yet: each demand is stashed for the replay, but the
    // gate records the first failure. The half's adoption calls this again
    // through _replayNext, and a failed half has already decremented
    // _halvesPending, so the request is parked only while a landing is still
    // possible.
    if (!boot._lateFeatures && boot._halvesPending > 0) {
      boot._drainRequested = true
      return
    }
    // The IPC surface does not wait for the construction milestone. A facade
    // unit's resident half is a singleton whose only job is to answer, and
    // `session` holds the lock/logout verbs, so a keybinding pressed while the
    // bar is still building its modules has to find its target rather than
    // fail. What those units put behind the facade (the launcher's index
    // build) holds itself back on its own milestone - see
    // AppLauncher._prewarm - so nothing expensive moves onto the module build
    // this phase exists to keep clear.
    boot._startEarly()
    // Phase order, not a delay: the early tier (session, lock, notifications,
    // the IPC daemons) already came up at half adoption, so the gate here only
    // holds the entrance and deferred queues - the units that compose pages,
    // scan directories and build panel trees. A single one of those can spend
    // far more than frameBudgetMs in one call, so the budget alone cannot keep
    // them off the frames the entrance is drawing. Wait for the motion's own
    // end instead, the same milestone the prewarms read, and the drain lands
    // on the first quiet frame.
    if (!DesktopLayoutState.bootEntrancePlayed) {
      boot._drainRequested = true
      return
    }
    boot._drainRequested = false
    boot._drainStarted = true
    boot._drainAdmissionId = boot.trace.emit("drain.admission", {
      via: boot._drainVia(), causes: boot._drainCauses()
    })
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
    // Mutated in place: _byId is a lookup table every caller reads through a
    // function, never a map a binding observes, and copying it per unit made
    // registering the 51 unit catalog 51 copies of a growing map.
    if (ok) boot._byId[id] = descriptor
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
    // One pass for both indexes. register() has already filled _byId; this
    // rebuilds it beside the reverse edges so the two are the catalog's own
    // view rather than whatever a partial registration left behind.
    const byId = ({})
    const dependents = ({})
    for (let i = 0; i < boot._catalog.length; i++) {
      const descriptor = boot._catalog[i]
      byId[descriptor.id] = descriptor
      if (!dependents[descriptor.id]) dependents[descriptor.id] = []
      const edges = descriptor.dependencies
      for (let j = 0; j < edges.length; j++) {
        const dependency = edges[j]
        const list = dependents[dependency] || (dependents[dependency] = [])
        list.push(descriptor.id)
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

  // Boot owns the floor, bar and demand rows. They are checked in that order;
  // an id in none of them goes to the late halves. Keeping the lookup to those
  // three maps is what leaves stash/replay and adoption order unchanged for
  // services and feature ids.
  function _ownedHandler(id) {
    if (Object.prototype.hasOwnProperty.call(floorHandlers.handlers, id)) return floorHandlers.handlers[id]
    if (Object.prototype.hasOwnProperty.call(barHandlers.handlers, id)) return barHandlers.handlers[id]
    if (Object.prototype.hasOwnProperty.call(demandHandlers.handlers, id)) return demandHandlers.handlers[id]
    return null
  }

  function _resolveDescriptor(id) {
    const row = boot._ownedHandler(id)
    if (row) {
      // The bar is the only owned row that can refuse: with the master switch
      // off there is no runtime to mount, and false is that gate answer.
      if (row.resolve() === false) return false
      return true
    }
    return boot._lateResolve(id)
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

  // Only the two halves that own a readiness edge are asked. The bar half has
  // none - the bar unit settles on its dependencies - so asking it was a call
  // whose every answer was false by construction.
  function _lateReady(id) {
    if (boot._lateFeatures && boot._lateFeatures.readyState(id)) return true
    if (boot._lateServices && boot._lateServices.readyState(id)) return true
    return false
  }

  // The facade controllers all live in the feature half, which is the only
  // half with a teardown to dispatch (see BootLate.teardown).
  function _lateTeardown(id) {
    if (boot._lateFeatures) boot._lateFeatures.teardown(id)
  }

  // Boot-owned readiness/teardown kept local to Boot after the catalog
  // extraction. The catalog adapter's wrappers call these; the generated rows
  // carry only the predicates and releases their declarations require, and
  // every other id falls through to the late provider dispatchers, so provider
  // ownership and demand/replay order are unchanged.
  function _unitReady(id) {
    const row = boot._ownedHandler(id)
    if (row && row.ready) return row.ready() === true
    return boot._lateReady(id)
  }

  function _unitTeardown(id) {
    const row = boot._ownedHandler(id)
    if (row && row.teardown) {
      row.teardown()
      return
    }
    boot._lateTeardown(id)
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
      // Cursor: the cascade only appends, and every dependent it appends is
      // visited once.
      for (let head = 0; head < worklist.length; head++) {
        const refreshedId = worklist[head]
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
    // Mutated in place: the map is this function's record of what it has
    // already reported, and nothing binds to it. Copying it made every settle
    // a fresh map of every unit that had settled before.
    boot._milestones[id] = state.state
    const descriptor = boot._byId[id]
    if (descriptor && descriptor.criticality === "essential") {
      const stateId = boot.trace.emit("unit.state", {
        unit: id, state: state.state,
        ownerCategory: descriptor.activation || "resident",
        causes: boot._traceRefs(boot._bootBeginId)
      })
      if (stateId) boot._essentialStateIds = boot._essentialStateIds.concat([stateId]).slice(-8)
    }
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
    const verdictId = boot.trace.emit("verdict.decision", {
      state: verdict, causes: boot._verdictCauses()
    })
    boot.trace.emit("endpoint.firstVerdict", {
      causes: boot._traceRefs(verdictId, boot._bootBeginId)
    })
    boot._verdictPublished = true
    boot._maybeSealTrace()
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

  // The demand provider reaches the loader through Boot, which keeps the
  // controller component supply in the late half.
  function _activateAnnotations() {
    annotationLoader.active = true
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
      boot._armRetry()
      // A first_use unit is skipped by the dependency cascade: its owner must
      // re-ensure it on the readiness edges its own dependencies produce.
      boot._reconcileBar()
    }
  }

  // The visual bar runtime. `setSource` is called only with a current settings
  // demand; clearing the URL is how a master disable retires the instance.
  Loader {
    id: barRuntimeLoader
    active: false
    asynchronous: true
    onLoaded: {
      // A load that finished after a disable carries a stale generation and
      // must attach nothing, publish nothing and arm no retry.
      boot._barRuntimeAccepted(item)
    }
    onStatusChanged: {
      if (status !== Loader.Error) return
      if (!boot._barDecisionMade) {
        Log.error("boot: bar runtime failed to load")
        boot._barAbsent()
      }
    }
  }

  // A hydration failure or a hang must not hold boot behind a bar that never
  // arrives. The milestone backstops still cover the entrance and the drain.
  QQ.Timer {
    interval: 2000
    repeat: false
    running: true
    onTriggered: {
      if (!boot._barDecisionMade) boot._barAbsent()
    }
  }

  Connections {
    target: Settings
    ignoreUnknownSignals: true
    function onReadyChanged() { boot._reconcileBar() }
    function onStatusbarEnabledChanged() { boot._reconcileBar() }
  }

  // Capture dots own their lifetime. They are mounted with the shell, not by
  // the bar runtime, so a bar toggle or reload never unmaps them.
  Loader {
    id: privacyIndicatorsLoader
    asynchronous: true
    source: Qt.resolvedUrl("../features/privacy/PrivacyIndicators.qml")
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

  // The construction milestone starts the feature half's compile; the played
  // milestone releases the drain request parked in _beginDrain. Both milestones
  // are the tail the verdict excludes - the bar's module build and the entrance
  // motion - so they are logged against the process start.
  Connections {
    target: DesktopLayoutState
    function onBootEntranceSettledChanged() {
      // The feature half's turn: the bar is on screen, so its compile no longer
      // competes with the bar's module builds (see _loadLate). The entrance
      // backstop settles this milestone even when no bar reported, so a shell
      // whose bar never latches still loads the half.
      if (DesktopLayoutState.bootEntranceSettled) boot._loadFeaturesHalf("entranceSettled")
      if (DesktopLayoutState.bootEntranceSettled) {
        Log.debug("boot: entrance settled in " + boot._sinceProcessStart() + "ms")
      }
    }
    function onBootEntrancePlayedChanged() {
      if (DesktopLayoutState.bootEntrancePlayed) {
        boot.trace.emit("endpoint.entrancePlayed", {
          causes: boot._traceRefs(boot._entrancePlayedDecisionId,
            boot._entranceSettledDecisionId, boot._bootBeginId)
        })
        boot._beginDrain()
        Log.debug("boot: entrance played in " + boot._sinceProcessStart() + "ms")
      }
    }
  }

  function _bootP0() {
    const floor = boot._catalog.filter(descriptor => descriptor.activation === "eager")
    for (let i = 0; i < floor.length; i++) {
      // One floor unit that throws must not take the rest of the floor with
      // it. An uncaught throw here aborts Component.onCompleted, which leaves
      // the visual phase unbuilt and the readiness connections unattached -
      // the whole shell with no surface, from one service. Every other phase
      // already isolates a unit this way (_drainOne, _bootVisuals), and the
      // gate records the error on the unit's own record.
      try {
        UnitGate.ensure(floor[i].id, "boot")
        UnitGate.refresh(floor[i].id)
      } catch (error) {
      }
    }
  }

  function _bootVisuals() {
    // Phase 1: construct the visual surfaces right after the floor, before the
    // rest of the resident units drain. The drain queue excludes them (see
    // onCompleted).
    //
    // The wallpaper is constructed here, on this thread: it is the surface the
    // first frame paints, and its file set is small - the view, the transition
    // helper and its shader. The bar is the opposite: BarControl.qml imports the
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
    // A cursor, not shift(): a drain is one element per unit of a queue that
    // may hold the whole catalog, and shift() moves the rest of it per unit.
    // _drainOne can push onto the same queue (the dependency cascade), and
    // reading the length each step picks those up exactly as shifting did.
    let head = 0
    while (head < queue.length) {
      boot._drainOne(queue[head++])
      if (Date.now() >= deadline) break
    }
    // Hand it back holding only what this turn never reached: the callers
    // decide by its length whether to reschedule, so a consumed head left in
    // place would look like work still owed. One splice per turn, not a move
    // per unit.
    if (head > 0) queue.splice(0, head)
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
    if (boot._earlyQueue.length > 0) {
      boot._requestPump(boot._drainEarly)
    } else {
      boot._closeQueueLedger("queue:early", "earlyQueueExhausted")
    }
  }

  function _drainEarly() {
    boot._budgetedTurn(boot._earlyQueue)
    // Through the pump, not Idle.run: the early tier is now ~20 units, and a
    // chain of callLaters is serviced back to back before the render loop gets
    // its turn - the 105ms frame the pump exists to prevent.
    if (boot._earlyQueue.length > 0) {
      boot._requestPump(boot._drainEarly)
    } else {
      boot._closeQueueLedger("queue:early", "earlyQueueExhausted")
    }
  }

  function _drainNext() {
    boot._budgetedTurn(boot._queue)
    if (boot._queue.length > 0) {
      boot._requestPump(boot._drainNext)
      return
    }
    boot._closeQueueLedger("queue:entrance", "entranceQueueExhausted")
    if (boot._deferredQueue.length > 0) {
      boot._requestPump(boot._drainDeferred)
    } else {
      // The handoff established that there is no deferred work to do.
      boot._closeQueueLedger("queue:deferred", "emptyAtHandoff")
      boot._completeDrain()
    }
  }

  function _drainDeferred() {
    boot._budgetedTurn(boot._deferredQueue)
    if (boot._deferredQueue.length > 0) {
      boot._requestPump(boot._drainDeferred)
    } else {
      boot._closeQueueLedger("queue:deferred", "emptyAtHandoff")
      boot._completeDrain()
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
  // continuation. BootPump owns that FIFO and its one-shot timer; Boot only
  // classifies the source and supplies the one monotonic clock.
  BootPump {
    id: bootPump
    observer: boot
    now: function () { return boot.nowMs() }
  }

  // Observer adapter for BootPump. The pump calls these guarded, and each is
  // inert when capture is absent or sealed; an observation failure never
  // reaches the pump's control flow.
  function openWork(source, kind) {
    if (!boot.trace || boot._traceSealed) return 0
    try {
      return boot.trace.openWork(source, kind)
    } catch (error) {
      return 0
    }
  }

  function closeWork(source, token, outcome) {
    if (!token || !boot.trace || boot._traceSealed) return
    try {
      boot.trace.closeWork(source, token, outcome)
      // The last phase closes its own admission inside the callback, so this
      // is where all ledger rows finally become terminal - the same normal
      // seal boundary the inline pump turn used to reach.
      boot._maybeSealTrace()
    } catch (error) {
    }
  }

  function enqueue(source, outcome) {
    if (!boot.trace || boot._traceSealed) return
    try {
      boot.trace.emit("queue.enqueue", { source: String(source), outcome: String(outcome) })
    } catch (error) {
    }
  }

  function dispatch(source, token, waitMs) {
    if (!token || !boot.trace || boot._traceSealed) return
    try {
      boot.trace.emit("queue.dispatch", {
        source: String(source), token: Number(token), waitMs: Number(waitMs)
      })
    } catch (error) {
    }
  }

  function noteFailure(code) {
    if (!boot.trace || boot._traceSealed) return
    try {
      boot.trace.emit("integrity.violation", { code: String(code).slice(0, 64), detail: "observerThrow" })
    } catch (error) {
    }
  }

  function _requestPump(fn) { return bootPump.enqueue(fn, boot._pumpSource(fn)) }

  // Bounded retries. Every non-floor descriptor declares one: a failure is the
  // one arrival nothing else wakes up, and at boot the plausible causes are
  // transient (a bus name not claimed yet, a PipeWire socket not listening, a
  // device handle not exported). The floor's failures are deterministic - a
  // missing path, an unparsable catalog - and retrying them only delays the
  // verdict. The delay is UnitGate's backoff, doubled per attempt and capped
  // by the descriptor.
  //
  // The due set is the gate's, not a slot here. A single pending id meant two
  // units failing in the same turn replaced each other - and one unclaimed bus
  // name fails several services at once - so the unit that lost the slot never
  // retried at all. Each armed turn asks every failed unit for its own
  // nextRetryMs instead, and fires when the earliest one is due.
  property real _retryDue: 0

  function _nextRetryAt() {
    let earliest = 0
    for (let i = 0; i < boot._catalog.length; i++) {
      const due = UnitGate.retryAt(boot._catalog[i].id)
      if (due <= 0) continue
      if (earliest === 0 || due < earliest) earliest = due
    }
    return earliest
  }

  function _armRetry() {
    const due = boot._nextRetryAt()
    if (due === 0) {
      boot._retryDue = 0
      retryPump.stop()
      return
    }
    // A unit change that moves nothing must not push an armed retry back:
    // the timer already counts down to this exact instant.
    if (boot._retryDue === due && retryPump.running) return
    boot._retryDue = due
    retryPump.interval = Math.max(1, Math.ceil(due - Date.now()))
    retryPump.restart()
  }

  function _retryNow() {
    const due = []
    for (let i = 0; i < boot._catalog.length; i++) {
      const id = boot._catalog[i].id
      if (UnitGate.retryDue(id)) due.push(id)
    }
    for (let i = 0; i < due.length; i++) {
      if (UnitGate.retry(due[i])) boot._refreshUnit(due[i])
    }
    boot._armRetry()
  }

  QQ.Timer {
    id: retryPump
    repeat: false
    onTriggered: boot._retryNow()
  }

  IpcHandler {
    target: "boot"

    function status(): string { return boot._shellStatus() }
    function state(): string { return boot._bootState() }
    function timeline(): string { return boot._bootTimeline() }
    function time(): string { return jsonOf(boot._bootReport()) }
    function help(): string {
      return "Usage: vb-shell boot <command> [args...]\n"
        + "\nBoot lifecycle and startup timeline.\n"
        + "\n  time                Show the boot timeline tree\n"
        + "\nRun `vb-shell boot help` for the command list, or `vb-shell help boot`.\n"
    }
    function ping(): string { return "pong" }
  }

  IpcHandler {
    target: "shell"
    function help(): string {
      // Offer ids are boot-catalog names, not IPC target names: two units
      // offer under one name and answer under another. The table lists what
      // `vb-shell` accepts. Targets without an offer (boot, shell,
      // colorPicker, screenshots) stay reachable through `vb-shell -l` and
      // their own `<unit> help`, but have no row here.
      const rename = { idleDaemon: "idle", powerMenu: "power" }
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
        + "  -j, --json      Emit typed JSON instead of text\n"
        + "  -v, --verbose   Enable verbose output\n"
        + "  -h, --help      Display this help and exit\n"
        + "\nUnits:\n" + units
        + "\nExamples:\n"
        + "  vb-shell wallpaper set image.jpg\n"
        + "  vb-shell session lock\n"
        + "  vb-shell audio status\n"
        + "\nRun `vb-shell <unit> help` for unit details.\n"
    }
    function status(): string { return boot._shellStatus() }
    function doctor(): string { return boot._shellDoctor() }
    function ping(): string { return "pong" }

    // Reserved transport. The Python client sends one `v1:` envelope as a
    // single argv word; Quickshell's fixed-arity string handlers carry it
    // unchanged to the router. These are not public CLI verbs.
    function describe(request: string): string { return IpcRouter.describe(request) }
    function invoke(request: string): string { return IpcRouter.invoke(request) }
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
