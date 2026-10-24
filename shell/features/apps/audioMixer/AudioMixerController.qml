pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters duplicated-name
import QtQuick
import qs.common
import qs.services as Core
import "MixerModel.js" as Model
import "GraphModel.js" as Graph

// Demand-loaded child of the AudioMixer facade. Everything the mixer reads
// off the graph and everything the window draws is built here and goes with
// it, so a shell that never opens the mixer never pays for any of it.
//
// Two subscriptions live for exactly as long as this object:
//
//   AudioNodes.observeSet("audioMixer")   the ONE object tracker over the
//                                         whole node set. Without it a node's
//                                         `audio.volume` and `audio.muted`
//                                         are invalid reads, which is a
//                                         silent 0 rather than an error, so a
//                                         mixer that skipped it would draw a
//                                         column of dead rows.
//   PipeWireState.acquirePeaks(...)       held by the meter rows themselves
//                                         and released on their destruction.
//
// What is linked to what is NOT a subscription. It is read off the graph's own
// link list and projected onto the device set; see the note on `deviceLinks`
// for why a per-node link tracker is the wrong source for it.
//
// The routing map is the one thing this app cannot read from the graph:
// `pactl move-sink-input` addresses objects by the PULSE index, which is
// numbered independently of the graph's, so one `pactl list` per refresh is
// the translation table. It is also the fast answer to which device a stream is
// on, because a sink input names its sink there and in no other place the shell
// can read without waiting; see `streamTargets`. The card map is the same shape
// of problem for a different reason: `pactl list cards` is CARD data, and only
// that child knows which profiles a card offers. Every invocation is an argv
// list through Exec.runJob, never a shell string, because a node name is
// client-supplied text. The owner string is this app's own, so a teardown can
// cancel every child in one call.
//
// The four row lists and the link projection are published as properties
// rather than as bindings over the graph, and all five are the same
// anti-flicker discipline: the graph republishes its whole node set on any node
// arriving or leaving, and its whole link list on any link moving, so a
// binding would rebuild every row several times a second, and rows that
// rebuild tear their peak holds down and take them again.
// `MixerModel.stableList` returns the incumbent when the members are
// unchanged, `MixerModel.deviceLinks` does the same for a device's pairs, and
// both rebuilds are coalesced behind `Qt.callLater` and a short timer - the
// pair the bar's volume island uses.
Item {
  id: root

  // Set when construction itself could not finish, so the facade can answer
  // unavailable instead of reporting a controller that is not there.
  property string startupError: ""

  // --- the graph ---
  readonly property var nodes: AudioNodes.nodes
  readonly property bool graphReady: Core.PipeWireState.graphReady

  // The four row sets, as functions over a node list rather than inline
  // bindings: the policy is this app's either way, and a projection that is a
  // function is one that can be run against a synthetic list.
  //
  // Three things are dropped before classification decides anything:
  //
  //   node.audio === null  the node is not an audio node at all. `isSink` and
  //                         `isStream` are false for a PipeWire MIDI bridge or
  //                         a dummy driver exactly as they are for a
  //                         microphone, so on this machine the INPUT DEVICES
  //                         list would open with Dummy-Driver, Freewheel-
  //                         Driver, Midi-Bridge and bluez_midi.server above
  //                         the mic. `PwNode.audio` is non-null only for an
  //                         audio node and is available without binding, which
  //                         is why this is a usable test before the tracker
  //                         has anything to say - and it is the same test the
  //                         bar's volume island applies to its own candidates.
  //   a `.monitor` name    a source monitor classifies as an input device,
  //                         which is correct as a classification and wrong as
  //                         an offer: a monitor exists to be recorded off an
  //                         output, so listing one makes every machine with a
  //                         speaker show a duplicate under INPUT DEVICES.
  //   the shell's own taps only for the two STREAM kinds, and this is the one
  //                         that BREAKS A LOOP rather than tidying a list: see
  //                         MixerModel.isShellTap and the note at its call
  //                         site below.
  //
  // So classify() stays exactly as the two documented booleans define it, and
  // the LIST applies the policy. That is where a policy belongs.
  function nodesOfKind(list, kind) {
    const out = []
    if (list === null || list === undefined) return out
    for (let i = 0; i < list.length; i++) {
      const node = list[i]
      if (node === null || node === undefined) continue
      if (node.audio === null || node.audio === undefined) continue
      if (Model.isMonitorName(Model.nodeName(node))) continue
      if (Model.classify(node) !== kind) continue
      // The shell's own peak taps are rejected HERE, and that is what breaks
      // the loop that made the Apps tab flicker: a tap this list drops is
      // never drawn, a row never takes a peak handle for it, and no handle
      // means no second tap. Debouncing this same list would only have made
      // the loop slower while still drawing rows for the shell itself. Only
      // the two stream kinds are tested, because a device is never the
      // shell's own capture stream.
      if (Model.isStreamKind(kind) && !Model.isApplicationStream(node)) continue
      out.push(node)
    }
    return out
  }

  // The four published row sets. Plain properties rather than bindings over
  // the node set, because the graph republishes that set WHOLE on any node
  // arriving or leaving - which here includes the shell's own peak taps
  // coming and going - and a binding would rebuild all four lists, and with
  // them every row, several times a second.
  property var _outputDevices: []
  property var _inputDevices: []
  property var _playbackStreams: []
  property var _captureStreams: []

  readonly property var outputDevices: root._outputDevices
  readonly property var inputDevices: root._inputDevices
  readonly property var playbackStreams: root._playbackStreams
  readonly property var captureStreams: root._captureStreams

  // The capture-side list the Recording tab renders. An alias rather than a
  // second array: it is the same rows, filtered once, so the two lists cannot
  // drift apart.
  readonly property var recordingStreams: root._captureStreams

  // The Graph tab's node list: EVERY audio node, all four kinds at once,
  // because the graph is the whole topology and not one column of it.
  property var _graphNodes: []

  readonly property var graphNodes: root._graphNodes

  // The Graph tab's LINK list: the graph's own links grouped into one entry
  // per node pair by Graph.groupLinks, which is written in _recomputeLinks()
  // below. A property with one writer rather than a binding, for the same
  // reason deviceLinks is: groupLinks takes the incumbent list as its
  // stability input, and a binding cannot be handed the value it is about to
  // replace.
  property var _graphLinks: []

  readonly property var graphLinks: root._graphLinks

  // The same three drops as nodesOfKind, on a list that is not sorted into a
  // kind. The graph tab draws a node whatever it IS, so what it applies is the
  // policy and not the classification: an unplaceable node is still dropped
  // rather than guessed at, and a node with no audio of its own is not on a
  // canvas.
  //
  // The shell's own peak taps are dropped by the same one test the row lists
  // use. `Model.isApplicationStream` is `!Model.isShellTap`, and `isShellTap`
  // is already both halves - `Model.isShellOwnName` for the name and the
  // peak-detect media class - so naming it once here covers the two. It matters
  // here for the same reason it matters there: a tap that is never drawn is
  // never given a peak handle, and a handle creates another tap.
  function audioNodes(list) {
    const out = []
    if (list === null || list === undefined) return out
    for (let i = 0; i < list.length; i++) {
      const node = list[i]
      if (node === null || node === undefined) continue
      if (node.audio === null || node.audio === undefined) continue
      if (Model.isMonitorName(Model.nodeName(node))) continue
      if (Model.classify(node) === null) continue
      if (!Model.isApplicationStream(node)) continue
      out.push(node)
    }
    return out
  }

  // One recomputation, then one publish per set - the four row sets plus the
  // graph tab's own list, which is the same filter without the kind. Each is a
  // stableList(), so a graph tick that moved nothing costs no rows - which is
  // what keeps a row from tearing its peak hold down and taking it again on
  // every notification, and what keeps a card on the graph from being rebuilt.
  function _recomputeRows() {
    const nodes = root.nodes
    root._outputDevices = Model.stableList(
      root._outputDevices, root.nodesOfKind(nodes, "outputDevice"))
    root._inputDevices = Model.stableList(
      root._inputDevices, root.nodesOfKind(nodes, "inputDevice"))
    root._playbackStreams = Model.stableList(
      root._playbackStreams, root.nodesOfKind(nodes, "playbackStream"))
    root._captureStreams = Model.stableList(
      root._captureStreams, root.nodesOfKind(nodes, "captureStream"))
    root._graphNodes = Model.stableList(
      root._graphNodes, root.audioNodes(nodes))
  }

  // A burst of graph notifications must not cost a burst of rebuilds.
  // `Qt.callLater` collapses one burst of notifications into a single timer
  // restart and the timer collapses a burst of turns into a single rebuild:
  // the pair the bar's volume island uses for the same reason. Deferred rather
  // than eager throughout, because the notification is not the work.
  function _scheduleRows() {
    Qt.callLater(() => rowsTimer.restart())
  }

  onNodesChanged: root._scheduleRows()

  Timer {
    id: rowsTimer
    interval: 75
    repeat: false
    onTriggered: root._recomputeRows()
  }

  // Every device, which is the set the link projection covers: the point of the
  // projection is that a DEVICE knows what is attached to it, so a stream is
  // not followed on its own.
  readonly property var allDevices: root.outputDevices.concat(root.inputDevices)

  // device node id -> `{ links: [{ source, target }] }`: the graph's own link
  // list projected onto each device. `links` is deliberately the same shape an
  // AudioNodes handle publishes, because that is what a device row reads and
  // what `attachedStreams` takes.
  //
  // A property with one writer rather than a binding: the projection needs the
  // incumbent map as its stability input, and a binding cannot be handed the
  // value it is about to replace. `_recomputeLinks()` is the one writer, and it
  // runs when the device set moves or the graph's links move.
  property var _deviceLinks: ({})

  readonly property var deviceLinks: root._deviceLinks

  // One recomputation, then one publish, coalesced behind the same
  // callLater-plus-timer pair the row sets use: the graph republishes its link
  // list whenever ANY link moves, including the mixer's own peak taps coming
  // and going, so an eager recomputation would be a burst of rebuilds per
  // tick. The projection itself is identity-stable (see
  // MixerModel.deviceLinks), so a tick that moved nothing costs no rows.
  function _recomputeLinks() {
    root._deviceLinks = Model.deviceLinks(
      AudioNodes.linkValues, root.allDevices, root._deviceLinks)
    root._graphLinks = Graph.groupLinks(
      AudioNodes.linkValues, root._graphLinks, Model.nodeKey)
  }

  function _scheduleLinks() {
    Qt.callLater(() => linksTimer.restart())
  }

  onAllDevicesChanged: root._scheduleLinks()

  Connections {
    target: AudioNodes

    function onLinkValuesChanged() { root._scheduleLinks() }
  }

  Timer {
    id: linksTimer
    interval: 75
    repeat: false
    onTriggered: root._recomputeLinks()
  }

  // The node-set observation. It names no node, so it takes no link tracker:
  // it exists to keep the one object tracker over the node set alive, which
  // is a precondition for every volume read in this app.
  property var _nodeSet: null

  // --- the routing map ---
  //
  // { sinks, sources, monitors, sinkInputs, sourceOutputs }, each keyed by the
  // PipeWire node id and valued with the Pulse index. Empty until the first
  // `pactl list` lands, and empty objects are what a row reads when it asks
  // about a node the daemon does not carry - a stream with no Pulse index
  // cannot be moved, and the picker says so rather than offering a target
  // that cannot work.
  property var pulse: Model.emptyPulseObjects()
  // The same capture's answer to the other half of "which device": a sink
  // input's own `Sink:` field and a source output's own `Source:` field, keyed
  // by the STREAM's node id. One child answers both - the block kinds are the
  // same `pactl list` - so this is parsed beside `pulse` from the same capture
  // rather than read on its own.
  property var routes: Model.emptyStreamRoutes()
  property bool routingBusy: false
  property string routingError: ""
  // The map is only as good as its last refresh, so it is stamped: a caller
  // can tell "no such device" from "we have not asked yet".
  property double routingAt: 0
  readonly property bool routingReady: root.routingAt > 0

  // stream node id -> device node id: which device each stream plays through or
  // records into.
  //
  // The routing map answers this on the first capture, and the link topology
  // answers the same question as the fallback. The map leads because it is
  // already resolved: it is a property this controller wrote when the `pactl
  // list` landed, where a link tracker answers only once the daemon has pushed it
  // a topology - and on a fresh open that left every row's chip with nothing to
  // print until it did.
  //
  // The topology stays for what the map cannot cover at all - a stream the
  // daemon holds no Pulse object for, a filter leg, a node registered only to
  // PipeWire - and because it is the source that follows a move the instant the
  // daemon rewires the graph.
  //
  // A stream in neither is a stream neither source can place, which is the
  // absence a row reads as "no target" once the map has been read at all.
  readonly property var streamTargets: Model.mergeTargets(
    Model.pulseStreamTargets(root.routes, root.pulse),
    Model.streamTargets(root.deviceLinks))

  readonly property string routeOwner: "audioMixer:routing"
  readonly property string moveOwner: "audioMixer:move"
  readonly property int routeTimeoutMs: 5000

  // One refresh: a single `pactl list`, with the parse and the publish in the
  // job's own completion so the window's first frame is never blocked on a
  // child. Overlapping refreshes are collapsed rather than queued - a stale
  // second answer would put an older routing map back on screen.
  function refreshRouting() {
    if (root.routingBusy) {
      root._routingQueued = true
      return false
    }
    root.routingBusy = true
    root.routingError = ""
    const job = Exec.runJob(["pactl", "list"], root.routeOwner, {
      timeoutMs: root.routeTimeoutMs,
      onFinished: result => root._adoptRouting(result)
    })
    // A job the registry refused is reported by a null and nothing else, and
    // no completion will ever run: leaving `routingBusy` true would wedge every
    // later refresh AND the facade's idle release, which declines to hand a
    // controller back while a routing read is in flight.
    if (job === null || job === undefined) root._adoptRouting(null)
    return true
  }

  function _adoptRouting(result) {
    root.routingBusy = false
    if (result === null || result === undefined) {
      root.routingError = "no result"
    } else if (result.cancelled === true || result.destroyed === true) {
      // A teardown cancelled this child. It reported nothing about the
      // daemon, so it says nothing here either - the error line is the user's
      // and a cancel is the shell's own doing.
      root.routingError = ""
    } else if (result.code !== "ok") {
      // A timeout and a nonzero exit are the same user-visible fact - the
      // routing pickers are inert - and the code names the difference for the
      // status verb without putting the daemon's own stderr on screen.
      root.routingError = String(result.code || "pactl failed")
    } else {
      // One capture, both parses: the two answers are different questions about
      // the same text, and a second child would be a second fork and a second
      // moment at which the two could disagree about the same stream.
      const capture = String(result.stdout || "")
      root.pulse = Model.parsePulseObjects(capture)
      root.routes = Model.parseStreamRoutes(capture)
      root.routingAt = Date.now()
      root.routingError = ""
    }
    if (!root._routingQueued) return
    root._routingQueued = false
    Qt.callLater(() => root.refreshRouting())
  }

  property bool _routingQueued: false

  // The slow refresh, armed only while the window is up. A stream's Pulse
  // index does not change while it exists, but a stream appearing or a device
  // arriving does, and both arrive as a daemon event this app is not
  // subscribed to: the map is the only place that would learn about them.
  // Slow on purpose - the map is a lookup table, not a level meter, and a
  // `pactl list` is a fork per tick.
  Timer {
    id: routeTimer
    interval: 5000
    repeat: true
    running: false
    onTriggered: root.refreshRouting()
  }

  // --- routing a stream ---
  //
  // The one operation that leaves the process. Both numbers are Pulse
  // indices, so both come out of the map rather than off the node: a node id
  // handed to `pactl` as an index moves whatever happens to carry that
  // number. The map is refreshed right after the move, because the change is
  // the daemon's and the link topology this app draws from follows it a beat
  // later.
  function routeStream(node, device, capture) {
    const streamKey = Model.nodeKey(node)
    const deviceKey = Model.nodeKey(device)
    if (streamKey === "" || deviceKey === "") return false
    const streamIndex = Model.pulseIndex(
      capture === true ? root.pulse.sourceOutputs : root.pulse.sinkInputs, streamKey)
    const deviceIndex = Model.pulseIndex(
      capture === true ? root.pulse.sources : root.pulse.sinks, deviceKey)
    if (streamIndex < 0 || deviceIndex < 0) {
      root.routingError = "no pulse index"
      return false
    }
    const argv = Model.moveArgv(capture === true, streamIndex, deviceIndex)
    if (argv.length === 0) return false
    const job = Exec.runJob(argv, root.moveOwner, {
      timeoutMs: root.routeTimeoutMs,
      onFinished: result => root._afterMove(result)
    })
    if (job === null || job === undefined) root.routingError = "move refused"
    return true
  }

  // The move reported. A refusal is a fact the user needs: the row's chip has
  // already closed and the device list has folded away, so a failed move with
  // no line anywhere reads as a mixer that ignored the click. The refresh runs
  // either way, because a move the daemon refused still leaves the graph where
  // it was and the row's "you are here" dot has to agree.
  function _afterMove(result) {
    if (result !== null && result !== undefined && result.code === "ok") {
      root.routingError = ""
    } else if (result !== null && result !== undefined
      && (result.cancelled === true || result.destroyed === true)) {
      // The controller went away mid-move. It is not a failure to report to a
      // user who is no longer looking.
      root.routingError = ""
      return
    } else {
      root.routingError = "move failed"
    }
    // `restart()` unconditionally sets the timer running, so it is guarded on
    // the window: an unconditional restart here would arm a `pactl list` every
    // five seconds for a closed window, which is exactly the cost the open-gate
    // exists to avoid.
    if (root.wanted) routeTimer.restart()
    Qt.callLater(() => root.refreshRouting())
  }

  // --- device configuration ---
  //
  // Profile/mode selection, disable, and per-channel levels: the fraction of
  // wiremix and pavucontrol this app could not do before. None of it is a card
  // operation in the graph API, so it comes from one `pactl list cards` read
  // plus the node's own channel map, and only the profile WRITE needs a child.
  //
  // Profile data is CARD data, keyed to a card and not to an index: `pactl`
  // numbers its objects independently of the graph's, so a node maps to its
  // card through MixerModel.nodeCardKey() rather than by position. That join is
  // what makes the index below safe - `wpctl set-profile` reads the index
  // against the NODE's own card, so another card's list would set a profile the
  // user never chose.
  property var _cards: Model.emptyCardProfiles()
  // The facade's idle release watches `routingBusy` and not this, because it
  // does not know of it: a card read in flight when a controller is handed
  // back is cancelled by the teardown below rather than waited for, and the
  // cancelled branch of _adoptConfig() reports nothing, so the cached list is
  // simply the previous one. That is the whole consequence of being the second
  // read, and it is why there is only one of them.
  property bool configBusy: false
  property string configError: ""
  // A failed WRITE is a different fact from a failed READ and gets its own
  // line: `deviceProfiles().error` echoes the read, and reporting a write
  // failure from there would name the wrong one.
  property string profileError: ""
  property double configAt: 0
  readonly property bool configReady: root.configAt > 0
  property bool _configQueued: false
  // How many retries a failing card read has spent. Reset by a successful
  // read, so a later failure retries again rather than inheriting the
  // exhaustion of a failure that has since been answered.
  property int _configTries: 0

  readonly property string configOwner: "audioMixer:config"
  readonly property string profileOwner: "audioMixer:profile"
  readonly property int configTimeoutMs: 5000

  // One read of the whole card map, cached. Refreshed on the open, on demand
  // through refreshConfiguration(), and after every profile write. Overlapping
  // refreshes collapse rather than queue: a stale second answer would put an
  // older profile list back under the row that is on screen.
  function refreshConfiguration() {
    if (root.configBusy) {
      root._configQueued = true
      return false
    }
    root.configBusy = true
    root.configError = ""
    const job = Exec.runJob(["pactl", "list", "cards"], root.configOwner, {
      timeoutMs: root.configTimeoutMs,
      onFinished: result => root._adoptConfig(result)
    })
    if (job === null || job === undefined) root._adoptConfig(null)
    return true
  }

  function _adoptConfig(result) {
    root.configBusy = false
    if (result === null || result === undefined) {
      root.configError = "no result"
      root._armConfigRetry()
    } else if (result.cancelled === true || result.destroyed === true) {
      // A teardown cancelled this child. It reported nothing about the daemon,
      // so it says nothing here either and the cached list stands.
      root.configError = ""
    } else if (result.code !== "ok") {
      root.configError = String(result.code || "pactl failed")
      root._armConfigRetry()
    } else {
      root._cards = Model.parseCardProfiles(String(result.stdout || ""))
      root.configAt = Date.now()
      root.configError = ""
      root._configTries = 0
    }
    if (!root._configQueued) return
    root._configQueued = false
    Qt.callLater(() => root.refreshConfiguration())
  }

  // One retry for a read that finished without an answer. `configReady` is
  // `configAt > 0`, so a read that never succeeded leaves EVERY chip on the
  // Configuration tab inert, and the only other trigger for a card read is the
  // window opening - which the user is already inside. A failure AFTER a good
  // read leaves the cached map in place and every chip working, so it is not
  // this path's case. One attempt, not a poll: a daemon this app cannot reach
  // must not cost a fork every few seconds for as long as the mixer is up,
  // which is what the routing map's 5s timer is for and this read is not.
  function _armConfigRetry() {
    if (root._configTries >= root.configRetryLimit) return
    root._configTries++
    configTimer.restart()
  }

  readonly property int configRetryLimit: 1
  readonly property int configRetryDelayMs: 800

  Timer {
    id: configTimer

    interval: root.configRetryDelayMs
    repeat: false
    running: false
    onTriggered: root.refreshConfiguration()
  }

  // The card this device belongs to, or null. Every "no card" path is refused
  // rather than guessed: a profile index is read against one specific card,
  // and the wrong card's list is a wrong write rather than a wrong label.
  function _cardFor(deviceNode) {
    const key = Model.nodeCardKey(deviceNode)
    if (key === "") return null
    if (root._cards.ambiguous[key] === true) return null
    const card = root._cards.byKey[key]
    return card === undefined ? null : card
  }

  // The profile list of a device's card, as
  // { current, profiles: [{ index, name, description, available, sinks,
  // sources }], readable, error }.
  //
  // `current` is the card's own `Active Profile:`, which is the profile the
  // CARD is on rather than the one this node happens to be on, because
  // choosing a profile moves the card.
  //
  // `readable` is false for every reason a caller cannot have a list and
  // `error` says which: "this card has no profiles" and "profiles not read
  // yet" are different things to draw, and an index of 0 against a list nobody
  // has is not a disable. Both are Model constants rather than literals, so
  // MixerModel.profileReadState() reads the same words this writes.
  function deviceProfiles(deviceNode) {
    if (!root.configReady) {
      return Model.noCardProfiles(root.configError !== ""
        ? root.configError : Model.PROFILE_UNREAD)
    }
    const card = root._cardFor(deviceNode)
    if (card === null) return Model.noCardProfiles(Model.PROFILE_NO_CARD)
    return {
      current: card.active,
      profiles: card.profiles,
      readable: true,
      error: ""
    }
  }

  // Apply a profile by its card-relative index. Index 0 is legal and is the
  // profile that disables the device, which is the entry the parser spells out
  // as such: the daemon's own word for it is "Off", which does not tell a user
  // they are about to take the device out of the graph.
  function setDeviceProfile(deviceNode, index) {
    const list = root.deviceProfiles(deviceNode)
    if (list.readable !== true) {
      root.profileError = list.error
      return false
    }
    const argv = Model.setProfileArgv(Model.nodeKey(deviceNode), index)
    if (argv.length === 0) {
      root.profileError = "no such profile"
      return false
    }
    // The index has to name a profile on THIS card's list. The cached list can
    // be a beat behind the daemon - a card arriving brings profiles with it -
    // and an index past the end is a different profile somewhere else.
    let known = false
    for (let i = 0; i < list.profiles.length; i++) {
      if (list.profiles[i].index === index) {
        known = true
        break
      }
    }
    if (!known) {
      root.profileError = "no such profile"
      return false
    }
    const job = Exec.runJob(argv, root.profileOwner, {
      timeoutMs: root.configTimeoutMs,
      onFinished: result => root._afterProfile(result)
    })
    if (job === null || job === undefined) {
      root.profileError = "wpctl refused"
      return false
    }
    return true
  }

  function _afterProfile(result) {
    if (result !== null && result !== undefined && result.code === "ok") {
      root.profileError = ""
    } else if (result !== null && result !== undefined
      && (result.cancelled === true || result.destroyed === true)) {
      // The controller went away mid-write. Nobody is looking at the row that
      // asked for it, so there is nothing to report.
      root.profileError = ""
      return
    } else {
      root.profileError = "wpctl failed"
    }
    // The daemon owns the result: which profiles exist and which one is active
    // both move under us, and the read is the only place either is published.
    Qt.callLater(() => root.refreshConfiguration())
  }

  // The node's own `PwNodeAudio`, or null.
  function _deviceAudio(deviceNode) {
    if (deviceNode === null || deviceNode === undefined) return null
    try {
      const audio = deviceNode.audio
      return audio === undefined ? null : audio
    } catch (ignored) {
      return null
    }
  }

  // A device's channel map and the per-channel levels behind it, as
  // { names, volumes, channelCount, known }. `names` are the API's own channel
  // names ("FrontLeft", ...), and MixerModel.channelLabel() is what turns one
  // into text to print.
  //
  // `known` is the test a peak monitor needs: Quickshell's monitor refuses a
  // node whose channels are still `Unknown`, so a device that has not settled
  // is reported as unknown rather than as a set of channel rows that would be
  // wrong.
  //
  // There is NO per-channel mute here, and that is an API limit rather than an
  // omission: `PwNodeAudio` publishes `muted` for the node as a whole and
  // `volumes` for the channels, and nothing else. A row that wanted one would
  // have to invent it.
  function channelInfo(deviceNode) {
    const empty = { names: [], volumes: [], channelCount: 0, known: false }
    const audio = root._deviceAudio(deviceNode)
    if (audio === null) return empty
    let channels = null
    let volumes = null
    try {
      channels = audio.channels
      volumes = audio.volumes
    } catch (ignored) {
      return empty
    }
    if (!Array.isArray(channels)) return empty
    if (!Array.isArray(volumes)) volumes = []
    const names = []
    for (let i = 0; i < channels.length; i++) {
      names.push(Model.channelName(channels[i]))
    }
    return {
      names: names,
      volumes: volumes.slice(),
      channelCount: names.length,
      known: Model.channelsKnown(channels)
    }
  }

  // One channel's level, written through the node's own writable volume list.
  // The list is assigned whole: `PwNodeAudio.volumes` is a float list with a
  // setter, so the new list is the current one with one element replaced, and
  // an assignment into one of its elements would be discarded.
  function setChannelVolume(deviceNode, channel, value) {
    const audio = root._deviceAudio(deviceNode)
    if (audio === null) return false
    if (typeof channel !== "number" || !isFinite(channel)) return false
    const index = Math.round(channel)
    if (index < 0 || index !== channel) return false
    if (typeof value !== "number" || !isFinite(value)) return false
    let volumes = null
    try {
      volumes = audio.volumes
    } catch (ignored) {
      return false
    }
    if (!Array.isArray(volumes) || index >= volumes.length) return false
    const next = []
    for (let i = 0; i < volumes.length; i++) {
      next.push(i === index ? value : Number(volumes[i]))
    }
    try {
      audio.volumes = next
      return true
    } catch (ignored) {
      return false
    }
  }

  // --- ports ---
  //
  // Quickshell 0.3.1's `PwNode` publishes no `ports` property at all, so a
  // node's port names cannot be read off the graph and have to be parsed out of
  // `pw-link`: `-o` for the output direction, `-i` for the input one. Two
  // children rather than one per node, because the whole graph is two lines of
  // output each and a per-node child would be a fork per card.
  //
  // The parse is Graph.portsByNode over Graph.parsePorts, keyed by the node
  // NAME - the text on the left of each `node:port` line - which is why a card
  // and its ports meet through Model.nodeName and not through an id: the two
  // come from different tools.
  //
  // Cached, and read on the open and on demand. Port names do not move under a
  // window that is idle, and there is no subscription for a node's port set to
  // be derived from, so a slow timer here would fork twice every tick to learn
  // nothing. A node that arrives after the last read is answered by the canvas
  // button, which is the honest way to say "ask again".
  property var _outputPorts: ({})
  property var _inputPorts: ({})
  property int _portsPending: 0
  property bool _portsQueued: false
  property string portsError: ""
  property double portsAt: 0
  readonly property bool portsReady: root.portsAt > 0
  readonly property var outputPorts: root._outputPorts
  readonly property var inputPorts: root._inputPorts

  readonly property string portOwner: "audioMixer:ports"
  readonly property string linkOwner: "audioMixer:graphLink"
  readonly property int linkTimeoutMs: 5000

  function refreshPorts() {
    if (root._portsPending > 0) {
      root._portsQueued = true
      return false
    }
    root.portsError = ""
    root._readPorts(["pw-link", "-o"], true)
    root._readPorts(["pw-link", "-i"], false)
    return true
  }

  // One child, and its own settle path. The in-flight count is incremented
  // before the spawn and settled in the completion, including the null a
  // refused job returns: a registry that refuses an argv reports nothing and
  // runs no completion, so a count that waited for one would leave every later
  // refresh queued behind a read that will never answer.
  function _readPorts(argv, outputs) {
    root._portsPending++
    const job = Exec.runJob(argv, root.portOwner, {
      timeoutMs: root.linkTimeoutMs,
      onFinished: result => root._adoptPorts(result, outputs)
    })
    if (job === null || job === undefined) root._adoptPorts(null, outputs)
  }

  function _adoptPorts(result, outputs) {
    root._portsPending = Math.max(0, root._portsPending - 1)
    if (result === null || result === undefined) {
      root.portsError = "no result"
    } else if (result.cancelled === true || result.destroyed === true) {
      // A teardown cancelled this child. It reported nothing about the graph,
      // so it says nothing here and the cached lists stand.
      root.portsError = ""
      return
    } else if (result.code !== "ok") {
      root.portsError = String(result.code || "pw-link failed")
    } else {
      const parsed = Graph.parsePorts(String(result.stdout || ""))
      if (outputs === true) root._outputPorts = Graph.portsByNode(parsed)
      else root._inputPorts = Graph.portsByNode(parsed)
      root.portsAt = Date.now()
      root.portsError = ""
    }
    if (root._portsPending > 0) return
    if (!root._portsQueued) return
    root._portsQueued = false
    Qt.callLater(() => root.refreshPorts())
  }

  // --- connecting, disconnecting and rerouting ---
  //
  // Three writes, all of them through `pw-link`, because Quickshell 0.3.1 has
  // no way to make or destroy a link natively: `PwLink` is read-only, there is
  // no `PwNode.move`, and neither `org.pipewire` nor `org.pulseaudio.Server`
  // publishes a `Move*` method. `pw-link <output> <input>` creates one and
  // `pw-link -d <LINK-ID>` destroys one.
  //
  // THE RULE THIS SECTION EXISTS TO KEEP: nothing here runs unless the user
  // asked for that exact pair. Not on a drag, not on a hover, not on the open,
  // not on a layout pass, and not after a write. There is no repair pass, no
  // reconnect on teardown, and no retry: a refused write is reported and stops.
  //
  // The ids and the names travel as separate argv elements and never as one
  // shell string, because a node name is client-supplied text; Graph.safeArg
  // refuses an element that starts with `-` so a name cannot become an option
  // of pw-link's own.
  //
  // The steps run ONE AT A TIME in the order the pairing made them, and the
  // queue STOPS at the first failure. A stereo connection is two link objects,
  // so a first step that failed and a second that succeeded is a half-open
  // pair left behind - which is the worse outcome, not the safer one.
  property var _linkQueue: []
  property int _linkAt: 0
  property int _linkPending: 0
  property string graphError: ""
  // The caller that wants to know how the queue ended, as
  // `done(ok)`. Null for every write that only has to run: the three graph-tab
  // writes leave their outcome on screen by redrawing from the graph, and the
  // monitor is the one write here whose result a control's own state is read
  // from - a toggle published before the daemon had answered would be a toggle
  // claiming a route the daemon refused to make.
  property var _linkDone: null

  function _dispatch(steps, done) {
    if (root._linkPending > 0) return "a graph write is already in flight"
    if (!Array.isArray(steps) || steps.length === 0) return "nothing to run"
    root.graphError = ""
    root._linkQueue = steps
    root._linkAt = 0
    root._linkPending = steps.length
    root._linkDone = typeof done === "function" ? done : null
    root._nextStep()
    return true
  }

  function _nextStep() {
    const steps = root._linkQueue
    if (!Array.isArray(steps) || root._linkAt >= steps.length) {
      root._linkQueue = []
      root._linkAt = 0
      root._linkPending = 0
      root._finishQueue(true)
      return
    }
    const step = steps[root._linkAt]
    root._linkAt++
    const job = Exec.runJob(step.argv, root.linkOwner, {
      timeoutMs: root.linkTimeoutMs,
      // Stated rather than inherited: this is a write to a live graph, and a
      // write that is tried twice on a daemon that merely took a moment is a
      // second link or a second cut the user never asked for.
      maxAttempts: 1,
      onFinished: result => root._afterStep(step, result)
    })
    if (job === null || job === undefined) root._afterStep(step, null)
  }

  // The queue's own outcome, handed to the one caller that asked for it and to
  // nobody else. Every terminal path goes through here - drained, refused,
  // cancelled - so a caller never has to know which of the three it is looking
  // at.
  function _finishQueue(ok) {
    const done = root._linkDone
    root._linkDone = null
    if (done !== null) done(ok)
  }

  function _afterStep(step, result) {
    root._linkPending = Math.max(0, root._linkPending - 1)
    let failed = false
    if (result === null || result === undefined) {
      root.graphError = "no result"
      failed = true
    } else if (result.cancelled === true || result.destroyed === true) {
      // A teardown cancelled this child mid-queue. Nothing else in the queue
      // runs: the controller is going away, and a queue that kept writing
      // behind a closing window is the one place this file could surprise.
      root._linkQueue = []
      root._linkAt = 0
      root._linkPending = 0
      root._finishQueue(false)
      return
    } else if (result.code !== "ok") {
      root.graphError = String(step.fail)
      failed = true
    }
    if (failed) {
      // Stop, and say what stopped. The canvas redraws from the graph either
      // way, so a refused link is absent from the next frame rather than
      // lingering as a line the user drew and the daemon refused.
      root._linkQueue = []
      root._linkAt = 0
      root._linkPending = 0
      root._finishQueue(false)
      return
    }
    root._nextStep()
  }

  // What a connect between these two nodes WOULD write, with no child in it.
  //
  // A refusal string when the connect cannot be composed at all, and otherwise
  // `{ pairs, lines, refusals, sourceKey, targetKey, sourceName, targetName }`.
  // `lines` is the list the user reads before committing and the list the
  // children run, in that order; `refusals` is every port that has no
  // counterpart, named, because a connect that quietly made half its pairs is
  // worse than one that made none.
  function planConnect(sourceNode, targetNode) {
    if (sourceNode === null || sourceNode === undefined) return "no source node"
    if (targetNode === null || targetNode === undefined) return "no target node"
    const sourceKey = Model.nodeKey(sourceNode)
    const targetKey = Model.nodeKey(targetNode)
    if (sourceKey === "" || targetKey === "") return "a node has no PipeWire id"
    if (sourceKey === targetKey) return "a node cannot be linked to itself"
    if (!root.portsReady) return "ports not read yet"
    const sourceName = Model.nodeName(sourceNode)
    const targetName = Model.nodeName(targetNode)
    if (sourceName === "" || targetName === "") return "a node has no name to match ports by"
    const outputs = Graph.recordsOf(root._outputPorts, sourceName)
    const inputs = Graph.recordsOf(root._inputPorts, targetName)
    if (outputs.length === 0) return sourceName + " has no output ports"
    if (inputs.length === 0) return targetName + " has no input ports"
    const pairing = Graph.pairPorts(outputs, inputs)
    const lines = []
    for (let i = 0; i < pairing.pairs.length; i++) {
      lines.push(Graph.portPath(pairing.pairs[i].output) + " -> "
        + Graph.portPath(pairing.pairs[i].input))
    }
    const refusals = []
    for (let i = 0; i < pairing.refused.length; i++) {
      refusals.push(Graph.refusalText(pairing.refused[i]))
    }
    if (pairing.pairs.length === 0) {
      return refusals.length === 0 ? "no port pair to make" : refusals.join("; ")
    }
    return {
      pairs: pairing.pairs,
      lines: lines,
      refusals: refusals,
      sourceKey: sourceKey,
      targetKey: targetKey,
      sourceName: sourceName,
      targetName: targetName
    }
  }

  // Link two nodes by channel suffix. Returns true when the write was
  // dispatched, or the refusal string that stopped it. The pairs were already
  // shown by the caller - planConnect is what it showed them from.
  function connectNodes(sourceNode, targetNode) {
    const plan = root.planConnect(sourceNode, targetNode)
    if (typeof plan === "string") return plan
    return root._dispatch(Graph.connectSteps(plan.pairs))
  }

  // Remove one link group. `target` is an entry of graphLinks - the whole
  // pair, so a stereo connection goes as its two link objects rather than
  // leaving one channel open on a pair the user believes is gone. A bare array
  // of ids is accepted too, because that is the other shape a caller holds.
  function disconnectLink(target) {
    const ids = root._idsOf(target)
    if (ids.length === 0) return "no link id to remove"
    const steps = Graph.disconnectSteps(ids)
    if (steps.length === 0) return "no link id to remove"
    return root._dispatch(steps)
  }

  // Reroute: disconnect and connect as ONE queue, so the two halves cannot
  // interleave with another action and the connect is never attempted over a
  // cut that failed. The cut is first, because a reroute that added the new
  // link and failed to remove the old one has left the graph with both.
  function rerouteLink(target, targetNode) {
    const sourceNode = root._sourceOf(target)
    if (sourceNode === null) return "the link's source node is not on the canvas"
    const ids = root._idsOf(target)
    if (ids.length === 0) return "no link id to remove"
    const plan = root.planConnect(sourceNode, targetNode)
    if (typeof plan === "string") return plan
    const steps = Graph.disconnectSteps(ids).concat(Graph.connectSteps(plan.pairs))
    if (steps.length === 0) return "nothing to run"
    return root._dispatch(steps)
  }

  function _idsOf(target) {
    if (target === null || target === undefined) return []
    if (Array.isArray(target)) return target
    if (!Array.isArray(target.ids)) return []
    return target.ids
  }

  // The node on the source side of a link group, looked up in this controller's
  // own node list. Null rather than the first node that happens to be present:
  // a reroute whose source the canvas cannot name is refused rather than
  // guessed, and a guess here would cut the wrong link's worth of channels and
  // then connect the pair somewhere else.
  function _sourceOf(target) {
    if (target === null || target === undefined) return null
    const key = String(target.sourceKey || "")
    if (key === "") return null
    const nodes = root._graphNodes
    for (let i = 0; i < nodes.length; i++) {
      if (Model.nodeKey(nodes[i]) === key) return nodes[i]
    }
    return null
  }

  // --- the monitor ---
  //
  // Persistent default-device loopback is owned by services/audio/Audio.qml;
  // this app-local monitor remains tied to its row and controller lifetime.
  // "Hear my voice" on an input device: this device's own audio routed into the
  // output so the user can hear the microphone. It is a graph link, not a route
  // - `pactl` has no verb for it - so it is written the way the canvas writes:
  // `pw-link <source> <target>` makes one and `pw-link -d <the same two names>`
  // takes it away, which is the whole reason the removal needs no link id -
  // pw-link cuts a pair by name, and the pair this route owns is the one the
  // plan built.
  //
  // THE DIRECTION, which is the opposite of the one a reader reaches for
  // first. The route is the input device's CAPTURE outputs into the sink's
  // PLAYBACK inputs, paired by channel suffix through Graph.pairPorts. The
  // obvious alternative - the sink's MONITOR outputs into the device's PLAYBACK
  // inputs - cannot be composed on this machine at all: a source node in
  // PipeWire is read-only, so the ALSA microphone carries `capture_*` outputs
  // and no input port whatsoever (`pw-link -i` prints no line for it,
  // `pw-cli info 53` reports `input ports: 0/0`), so the plan refused every
  // click with "has no playback ports to hear it on" and no link was ever
  // attempted. That is not a device that cannot be monitored; it is a direction
  // the graph does not carry. This direction needs the device to have outputs
  // and the sink to have inputs, which is true of every capture device and
  // every sink, and it is what wiremix's own Monitor writes. The two port maps
  // are read accordingly - see planMonitor - and
  // MixerModel.captureOutputs records the same reasoning at the selector, so a
  // reader who starts here is stopped at the second file too. Do not restore
  // `monitor_` on the source side: it reads correctly and refuses forever.
  //
  // The sink is NOT the default output verbatim. The default output on this
  // machine is `eq_input`, a Parametric EQ sink inside a `filter-chain-*` group,
  // and "hear my voice" through a filter leg is not hearing my voice - it is
  // hearing whatever the graph happens to play. MixerModel.resolveMonitorSink
  // is the rule and skips virtual/filter sinks for the hardware behind them;
  // it degrades to the default when there is no hardware to prefer and refuses
  // only when the graph has no output sink at all.
  //
  // THE RULE THIS SECTION EXISTS TO KEEP, shared with the three graph writes
  // above: nothing here runs unless the user asked for that exact pair, and the
  // route does not outlive the control that offers it. The toggle is off by
  // construction, and the route is torn down the moment the control is not on
  // screen - the window closing, the tab moving off the devices tab, or the
  // controller being released. The state is cleared the moment a removal is ASKED
  // FOR rather than when it lands, because a toggle that still reads "on" while
  // the route is on its way out is worse than no toggle at all.
  readonly property string monitorOwner: "audioMixer:monitor"

  // The device being monitored, "" for none. The whole of the toggle's state,
  // and per-device rather than a flag on the window: two microphones may be on
  // the devices tab at once and each row answers for itself.
  property string monitorKey: ""

  // The sink the live monitor points at, by name, for the row's accessible
  // description. Cleared with the route: a note naming a sink that is no longer
  // being listened to is a lie about the graph.
  property string monitorSinkName: ""

  // The port pairs the live monitor is made of, as `[{ source, input }]` with
  // both halves `node:port` strings, or [] when nothing is owed. This is the
  // whole of what a removal needs, and emptying it IS the idempotence: a second
  // teardown path finds nothing owed and writes nothing.
  //
  // Teardown cuts the RECORDED pairs and never re-derives the plan, and that is
  // the rule it rests on. A plan re-derived at teardown would be composed
  // against a graph that has since moved - another stream, a different default
  // sink, a device gone - and would cut whatever that plan happens to name now,
  // which is not the route the user turned on. On the window close there is no
  // longer a graph to re-derive against at all.
  property var monitorPairs: []

  // Whether a removal is owed and has not finished. It keeps the paths from
  // dispatching two removals over one route - the window closing right after a
  // tab change, which is exactly the pair of paths that arrive together.
  property bool monitorRemoving: false

  // The last refusal this route reported, cleared when a new attempt starts.
  // One field for the whole controller rather than one per device, for the
  // reason `profileError` is: this is a refused WRITE, and printing it on every
  // input row would repeat one complaint beside four microphones.
  property string monitorNote: ""

  // Which of the two refusals this note is: `Model.MONITOR_UNAVAILABLE`,
  // `Model.MONITOR_FAILED`, or "" when there is no note. "This microphone
  // exposes no capture ports" and "the shell was busy" reach the row as one
  // string, and a row that paints the string without this cannot tell the user
  // which half of it they can act on.
  property string monitorBlocked: ""

  // The device the note belongs to, "" for none. The note is the controller's
  // and the reason is the row's - the same split `profileError` makes against
  // `row._attempted`: four microphones and one refusal is one line on one row,
  // not the same complaint under four controls.
  property string monitorNoteKey: ""

  // Publish a refusal: its text, which of the two kinds it is, and the row it
  // belongs to. One function so that no path can set the text and leave the
  // class behind, which would paint a fact about the hardware as a fault.
  function _note(note, blocked, deviceKey) {
    root.monitorNote = String(note === undefined || note === null ? "" : note)
    root.monitorBlocked = String(blocked === undefined || blocked === null
      ? "" : blocked)
    root.monitorNoteKey = String(deviceKey === undefined || deviceKey === null
      ? "" : deviceKey)
  }

  // Take a refusal down. Called by every path that lands one: a refusal that
  // outlives the click that produced it is a line describing a route state the
  // user has already moved past.
  function _clearNote() {
    root.monitorNote = ""
    root.monitorBlocked = ""
    root.monitorNoteKey = ""
  }

  // Whether this device is the one being monitored.
  function monitorOn(deviceKey) {
    const key = String(deviceKey === null || deviceKey === undefined ? "" : deviceKey)
    if (key === "") return false
    return root.monitorKey === key && !root.monitorRemoving
  }

  // The sink a monitor would be pointed at right now, or null. A node object
  // rather than a name because the plan needs its ports, and its own name is one
  // read off it.
  function monitorSink() {
    return Model.resolveMonitorSink(Core.PipeWireState.sink, root.outputDevices)
  }

  // A refusal the plan cannot write past, as `{ note, blocked }`. An object
  // rather than a bare string because the row paints the text and needs the
  // class beside it, and a class cannot be parsed back out of a sentence.
  function _refuse(note, blocked) {
    return { note: note, blocked: blocked }
  }

  // What a monitor of this device WOULD write, with no child in it. A refusal
  // object when it cannot be composed, and otherwise the plan the toggle
  // commits: the pairs, the lines, the refusals and the two node identities.
  // Every refusal is named, and a refusal writes NOTHING - a plan that cannot be
  // composed half way is the outcome the pairing exists to prevent.
  //
  // WHICH MAP HOLDS WHICH DIRECTION, since reading either of them the other way
  // round is the mistake this plan has already made once. `_outputPorts` is the
  // `pw-link -o` parse, so the device's `capture_*` records are in THAT one -
  // they are the microphone's outputs, a source node having no input port at
  // all - while `_inputPorts` is the `pw-link -i` parse, so the sink's
  // `playback_*` records are in the OTHER. Each map is asked about the direction
  // it was collected for and about nothing else.
  function planMonitor(deviceNode) {
    if (deviceNode === null || deviceNode === undefined) {
      return root._refuse("no input device", Model.MONITOR_FAILED)
    }
    if (Model.classify(deviceNode) !== "inputDevice") {
      return root._refuse("only an input device can be monitored", Model.MONITOR_FAILED)
    }
    const deviceKey = Model.nodeKey(deviceNode)
    if (deviceKey === "") {
      return root._refuse("the device has no PipeWire id", Model.MONITOR_FAILED)
    }
    if (!root.portsReady) return root._refuse("ports not read yet", Model.MONITOR_FAILED)
    const sink = root.monitorSink()
    if (sink === null) {
      return root._refuse("no output device to monitor into", Model.MONITOR_UNAVAILABLE)
    }
    const sinkKey = Model.nodeKey(sink)
    if (sinkKey === "") {
      return root._refuse("the output device has no PipeWire id", Model.MONITOR_FAILED)
    }
    const sinkName = Model.nodeName(sink)
    const deviceName = Model.nodeName(deviceNode)
    if (sinkName === "" || deviceName === "") {
      return root._refuse("a node has no name to match ports by", Model.MONITOR_FAILED)
    }
    const outs = Model.captureOutputs(root._outputPorts, deviceName)
    const ins = Model.playbackInputs(root._inputPorts, sinkName)
    // Both of these are facts about the graph rather than faults: the click was
    // read, the plan was composed as far as the hardware allows, and no port
    // exists for the rest of the route. Reported as `failed` they would tell
    // the user to try again against a graph that answers identically.
    if (outs.length === 0) {
      return root._refuse(deviceName + " has no capture ports to hear it from",
        Model.MONITOR_UNAVAILABLE)
    }
    if (ins.length === 0) {
      return root._refuse(sinkName + " has no playback ports to play it on",
        Model.MONITOR_UNAVAILABLE)
    }
    const pairing = Graph.pairPorts(outs, ins)
    const lines = []
    for (let i = 0; i < pairing.pairs.length; i++) {
      lines.push(Graph.portPath(pairing.pairs[i].output) + " -> "
        + Graph.portPath(pairing.pairs[i].input))
    }
    const refusals = []
    for (let i = 0; i < pairing.refused.length; i++) {
      refusals.push(Graph.refusalText(pairing.refused[i]))
    }
    if (pairing.pairs.length === 0) {
      return root._refuse(refusals.length === 0 ? "no port pair to make" : refusals.join("; "),
        Model.MONITOR_UNAVAILABLE)
    }
    // The pattern check, over the WHOLE plan rather than one pair of it: pw-link
    // matches both of its port arguments as globs, and half a monitor is the
    // outcome this directory refuses everywhere else. The direction the two
    // names travel in does not change that - they are the same two glob
    // patterns whichever end is the source. The refusal is returned rather than
    // published here: this function decides what a monitor WOULD write and
    // touches no state of its own.
    for (let i = 0; i < pairing.pairs.length; i++) {
      const out = Graph.portPath(pairing.pairs[i].output)
      const input = Graph.portPath(pairing.pairs[i].input)
      if (Model.monitorNameSafe(out) && Model.monitorNameSafe(input)) continue
      return root._refuse(out + " is not a safe pw-link argument", Model.MONITOR_UNAVAILABLE)
    }
    return {
      pairs: pairing.pairs,
      lines: lines,
      refusals: refusals,
      sinkKey: sinkKey,
      sinkName: sinkName,
      deviceKey: deviceKey,
      deviceName: deviceName
    }
  }

  // The toggle's one verb: on if it is off, off if it is on, and a refusal
  // rather than a state change when neither can be done.
  //
  // The state is published from the queue's completion and NOT here. A refused
  // `pw-link` that still lit the toggle would be a row claiming a route that is
  // not there, which is the one state this control must never be in.
  function toggleMonitor(deviceNode) {
    if (root.monitorOn(Model.nodeKey(deviceNode))) return root.clearMonitor()
    const plan = root.planMonitor(deviceNode)
    if (!Array.isArray(plan.pairs)) {
      root._note(plan.note, plan.blocked, Model.nodeKey(deviceNode))
      return false
    }
    root._clearNote()
    const sent = root._dispatch(Graph.connectSteps(plan.pairs),
      ok => root._afterMonitor(plan, ok))
    if (typeof sent === "string") {
      root._note(sent, Model.MONITOR_FAILED, plan.deviceKey)
      return false
    }
    return true
  }

  // A plan's pairs as the `{ source, input }` strings the teardown paths cut
  // by. Both halves are `node:port` paths and stay separate argv elements the
  // whole way down, so nothing here is ever a string a shell could read: a node
  // name is client-supplied text.
  function _owedOf(plan) {
    const pairs = []
    for (let i = 0; i < plan.pairs.length; i++) {
      pairs.push({
        source: Graph.portPath(plan.pairs[i].output),
        input: Graph.portPath(plan.pairs[i].input)
      })
    }
    return pairs
  }

  function _afterMonitor(plan, ok) {
    if (!ok) {
      root._note("pw-link refused the monitor", Model.MONITOR_FAILED, plan.deviceKey)
      root.monitorPairs = []
      // EVERY PAIR GOES OR NONE DOES. The queue stops at the first failure, so a
      // stereo route whose left channel linked and whose right one did not is a
      // live half route, and `monitorPairs` is the only record of what this
      // route is - dropping it there would orphan the other channel for the rest
      // of the session. The plan's own pairs are cut, one child each, through
      // the same stop-at-first-failure queue. A cut of a pair that was never
      // made answers "No such file or directory" and changes nothing, which is
      // the cheap price of a route that is never left half open.
      root._dispatch(Model.monitorDisconnectSteps(root._owedOf(plan)))
      return
    }
    root._clearNote()
    root.monitorKey = plan.deviceKey
    root.monitorSinkName = plan.sinkName
    root.monitorPairs = root._owedOf(plan)
    root.monitorRemoving = false
  }

  // Tear the monitor down, from any path. Idempotent by emptying `monitorPairs`
  // first: a path that arrives when nothing is owed returns false and writes
  // nothing, which is what lets a row, a tab change, the window's close and the
  // controller's own destruction all call this without any of them knowing
  // whether another already ran.
  //
  // The state goes BEFORE the write is queued, and that order is the whole point
  // of the function: a toggle reading "on" while the route is being taken away
  // is the state the user must never be left in, and the removal itself is a
  // child that may take a moment to land.
  function clearMonitor() {
    const pairs = root.monitorPairs
    root.monitorPairs = []
    root.monitorKey = ""
    root.monitorSinkName = ""
    if (root.monitorRemoving) return false
    if (!Array.isArray(pairs) || pairs.length === 0) return false
    const steps = Model.monitorDisconnectSteps(pairs)
    if (steps.length === 0) return false
    root.monitorRemoving = true
    const sent = root._dispatch(steps, ok => {
      root.monitorRemoving = false
      // A refused removal leaves the route on the graph, so the note outlives the
      // toggle going off and says so. A removal that landed clears whatever the
      // last create said: the note belongs to a click, and a later toggle that
      // worked must not leave the earlier refusal standing above a route that is
      // behaving exactly as asked.
      if (ok) root._clearNote()
      else {
        root._note("pw-link refused to remove the monitor", Model.MONITOR_FAILED,
          root.monitorNoteKey)
      }
    })
    if (typeof sent === "string") {
      // The queue was busy, so the removal did not go out. The pairs go back:
      // dropping them here would leave the route on the graph with nothing left
      // that knows it exists, and the backstop below is then the only thing
      // that could still take it away.
      root.monitorPairs = pairs
      root.monitorRemoving = false
      root._note(sent, Model.MONITOR_FAILED, root.monitorNoteKey)
      return false
    }
    return true
  }

  // The last teardown path, and the one that cannot use the queue: by the time
  // this runs the object that walks a sequential queue is being destroyed, so
  // there is nothing left to order the steps with. Each owed pair goes out as
  // its own child instead, and the monitor owner is deliberately NOT cancelled
  // by the destruction handler - a `pw-link -d` that outlives its controller is
  // a removal that still lands, and a teardown is the one write whose failure
  // mode is silence rather than a surprise. Every other path has emptied
  // `monitorPairs` before this runs, so what is left here is exactly a removal
  // that never went out.
  function _backstopMonitor() {
    const pairs = root.monitorPairs
    root.monitorPairs = []
    root.monitorKey = ""
    root.monitorSinkName = ""
    root.monitorRemoving = false
    if (!Array.isArray(pairs) || pairs.length === 0) return false
    const steps = Model.monitorDisconnectSteps(pairs)
    for (let i = 0; i < steps.length; i++) {
      Exec.runJob(steps[i].argv, root.monitorOwner, {
        timeoutMs: root.linkTimeoutMs,
        maxAttempts: 1
      })
    }
    return true
  }

  // --- lifetime ---
  // Whether the window is up, read off the facade rather than owned here: the
  // close settle and the lease both live there, and a second copy of the flag
  // is a second thing that can disagree with the window.
  readonly property bool wanted: AudioMixer.visible

  Component.onCompleted: {
    // One Component.onCompleted in this object, so the two construction steps
    // that can fail share it. A throw here would leave the facade holding a
    // controller that never worked, so it is turned into startupError instead
    // of propagating: a Loader cannot raise a construction error to its
    // caller.
    try {
      // The node-set observation FIRST: every volume read in this app is
      // invalid without it, and a row that opened before it would draw a
      // dead level for a frame.
      root._nodeSet = AudioNodes.observeSet("audioMixer")
      root.refreshRouting()
      root.refreshConfiguration()
      // The port enumeration is not seeded from a subscription, because there
      // is none to seed from: a node's port names come from `pw-link` and
      // nothing on the graph announces a change to them. One read at
      // construction is what puts ports on the first frame rather than after
      // the user has clicked a card and been told there are none.
      root.refreshPorts()
      // The node set is already published by the time a controller is
      // demanded, so nothing would arrive to trigger the first rebuild: the
      // four lists are seeded here instead, deferred for the same reason
      // every later rebuild is. The link projection is seeded the same way,
      // for the same reason.
      root._scheduleRows()
      root._scheduleLinks()
    } catch (ignored) {
      root.startupError = "startup"
      root.routingError = "pactl list failed"
    }
  }

  Component.onDestruction: {
    // Every subscription this controller holds is dropped here, in one place:
    // the node-set observation, the pending row and link rebuilds, and the
    // children the routing and configuration calls started. A second
    // destruction handler elsewhere in the object is the same teardown split
    // in two, and the first one to be missed is the one that leaks.
    //
    // The monitor's backstop goes FIRST, before any cancellation: a route the
    // user asked for is still on the graph at this point, and everything below
    // is about stopping this controller's work rather than undoing it.
    root._backstopMonitor()
    routeTimer.stop()
    configTimer.stop()
    rowsTimer.stop()
    linksTimer.stop()
    // cancelOwner covers the routing refresh, the move, the card read, the
    // profile write, the two port reads and the graph writes: six owners, one
    // call each, and a child that outlives its owner's teardown is a fork the
    // shell cannot account for. The graph owner matters most of the six: a
    // `pw-link` left running behind a closing window is a write to the user's
    // audio that nothing on screen is there to answer for.
    //
    // `monitorOwner` is NOT in that list, and that is the one exception with a
    // reason: the children it owns are the monitor's REMOVALS, dispatched by
    // _backstopMonitor() two lines above from a controller that is already
    // leaving. Cancelling them would leave the route on the graph with nothing
    // left to take it away, which is the one outcome this path exists to
    // prevent; the registry outlives the controller and disposes each job as it
    // settles.
    ProcessRegistry.cancelOwner(root.routeOwner)
    ProcessRegistry.cancelOwner(root.moveOwner)
    ProcessRegistry.cancelOwner(root.configOwner)
    ProcessRegistry.cancelOwner(root.profileOwner)
    ProcessRegistry.cancelOwner(root.portOwner)
    ProcessRegistry.cancelOwner(root.linkOwner)
    if (root._nodeSet !== null) {
      AudioNodes.release(root._nodeSet)
      root._nodeSet = null
    }
  }

  onWantedChanged: {
    // The routing map and the card map are refreshed on the open, not on every
    // frame, and the slow timer only runs while the window is up: a closed
    // window pays nothing, and a stream or a card that appeared while the
    // window was closed is picked up by the open. The card map has no slow
    // timer because a profile list does not change under a window that is
    // idle - a profile write re-reads it, and that is the only thing that
    // moves it. The port enumeration joins them on the open: a node that was
    // created while the window was shut brings its ports with it, and a canvas
    // that listed it with none is a canvas that refuses to connect it.
    //
    // The monitor is torn down on the way DOWN and not on the way up: the
    // window closing is one of the three paths that must stop the route, and it
    // is the earliest of them - the controller itself is still alive for the
    // facade's whole close settle, so this is where a full sequential removal
    // runs rather than the destruction backstop.
    if (!root.wanted) {
      routeTimer.stop()
      configTimer.stop()
      root.clearMonitor()
      return
    }
    root.refreshRouting()
    root.refreshConfiguration()
    root.refreshPorts()
    routeTimer.restart()
  }

  Loader {
    id: windowLoader
    // A PanelWindow with no screen to place itself on is a surface the
    // compositor decides about, so the load waits for a real one. Ui.primaryScreen
    // is already filtered to screens with a name and a non-zero size, and it is
    // null before the first screen report arrives.
    active: root.wanted && Ui.primaryScreen !== null && Ui.primaryScreen !== undefined
    sourceComponent: windowComp
  }

  Component {
    id: windowComp

    // Required rather than defaulted: the window is handed the controller so it
    // reads the graph through one owner instead of reaching for a second
    // reference of its own.
    AudioMixerWindow {
      controller: root
    }
  }
}