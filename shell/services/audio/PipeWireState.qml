pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Services.Pipewire
import qs.common

// PipeWireState - the ONE owner of the shell's PipeWire tracker state.
//
// A backend tracker is a subscription on process-global state, so a tracker
// built by whoever happens to need a value is N subscriptions on the same
// objects. This file holds the shell's trackers once, publishes normalized
// read-only state from them, and offers the explicit default-device writes.
// The policy stays with the services: Audio keeps the volume/mute policy and
// the OSD triggers, Privacy keeps the capture classification and the
// cut/restore pipeline, and the bar views keep their own presentation and
// their own view-local selection and hover state.
//
// What it owns, and what it builds on:
//
//   PwObjectTracker        ONE, over the default devices. PwNodeAudio.volume
//                          and .muted and PwNode.properties are documented as
//                          invalid unless the object is bound through a
//                          PwObjectTracker, so the default devices must be
//                          bound by somebody; this is that somebody. The
//                          backend's node set is NOT tracked here: the neutral
//                          mechanism (qs.common AudioNodes) already owns the
//                          one tracker over it, and a second one would be the
//                          duplication this file exists to remove.
//   PwNodeLinkTracker      none of its own. The link groups of a node are
//                          asked of the neutral mechanism, which keeps ONE
//                          tracker per observed node and shares it with every
//                          observer - including the bar's volume module, which
//                          observes the same default source. A tracker of
//                          Privacy's own would be a second subscription on that
//                          one node.
//   PwNodePeakMonitor      one PER NODE, for the whole shell, held only while
//                          a consumer asks for it. Not one: a view shows a
//                          level for several nodes at once - the volume island
//                          for the default sink and the default source, the
//                          mixer for a device and for every stream under it -
//                          so a single monitor cannot serve them. The monitors
//                          are refcounted per node, so the last hold on a node
//                          takes its monitor down with it and a node nobody
//                          reads leaves nothing behind. How many nodes may be
//                          metered at once is capped by maxPeakNodes, which is
//                          what keeps this from becoming "one per view" with
//                          no limit.
//
// The v0.3.1 distinctions, each as the API actually documents them (nothing
// here is a guarantee the docs do not make):
//
//   readiness     Pipewire.ready is true once quickshell finished its initial
//                 sync; the page documents that a pre-sync read "may be
//                 missing", and PwNode.ready's page says a node "may be used
//                 before it is fully bound, but some data may be missing or
//                 incorrect". So a pre-ready object is published as null
//                 rather than as a value: the readers below are gated, the
//                 tracker below is NOT. Binding a node is what makes its
//                 ready state meaningful, so gating the tracker's own object
//                 list on node.ready would be circular - the node would wait
//                 to be bound for a bound-only property to say it is ready.
//   nulls         PwObjectTracker.objects is documented as "the list of
//                 objects to bind. May contain nulls", so a null is not an
//                 API error. It is filtered anyway: Pipewire.defaultAudioSink
//                 and .defaultAudioSource are documented to "briefly become
//                 null" on a device change, and a null that reaches a binding
//                 list is a hole the tracker has to survive. The filter is the
//                 tracker's own requirement, and no suite under
//                 tests/shell/suites/ exercises it.
//   no `enabled`  PwObjectTracker has exactly one property, `objects`. There
//                 is no enabled/disabled switch to set, so the object list
//                 is the only release lever this type offers.
//   link topology PwNodeLinkTracker tracks "non-monitor link connections"
//                 and its linkGroups are documented as "excluding monitors",
//                 deduplicated to one entry per source->target pair. It is
//                 therefore a topology question, not a consumer count: a
//                 monitor link is not a capture, and a pair with two links is
//                 one group. PwLinkGroup.state is invalid unless the group is
//                 itself bound through a PwObjectTracker, so nothing here
//                 reads it.
//   peaks         PwNodePeakMonitor.peaks are documented as "per-channel peak
//                 noise levels (0.0-1.0)" and peak as the maximum of them -
//                 NOT RMS, NOT a VU integration, and the page documents no
//                 refresh rate, no hold or decay model, no reset and no
//                 retained values after a disable. Consumers must treat the
//                 value as a momentary reading, never as an average.
//
// Release, honestly recorded: the v0.3.1 PwObjectTracker page documents no
// automatic backend unbinding, so "clear the object list, destroy the child,
// watch the daemon unbind" stays undemonstrated, diagnostics().releaseDemonstrated
// stays false, and the single owner stays resident by decision rather than by
// oversight. No view ever grows a tracker of its own to make a release cheap.
// This file does demonstrate the QML half against a live graph on this machine -
// one tracker object, one object list, no consumer-count growth - and node
// classification was measured against that same graph: a real AudioInStream
// (type 13, isSink false) and two AudioOutStream playback legs (type 21,
// isSink true). Not demonstrated here: the Privacy cut/restore pipelines and
// the watchdog outcomes, which remain source-level only.
//
// Polling: none. Readiness, the node set, the link groups and the default
// devices all arrive as backend notifies, so there is no timer here to stop
// when no consumer needs it. The 16ms fade in Audio and the 1.5s post-cut
// watchdog in Privacy are demand-driven and stay where their policy is.
Singleton {
  id: root

  readonly property string tag: "pipewireState"

  // --- readiness -----------------------------------------------------
  //
  // `Pipewire.ready` is the service-level gate; `PwNode.ready` is the
  // per-node one. Both are checked, because either alone admits an
  // incomplete read: a ready service can still hand out a node whose own
  // sync is unfinished, and a ready node is meaningless before the service
  // has synced at all.
  readonly property bool graphReady: Pipewire.ready === true

  // A node's own readiness, which is a second gate and the one that decides
  // whether `sink`/`source` publish at all. A node that arrives not-ready and
  // never becomes ready is why a device is present and still absent from the
  // shell.
  function _nodeReady(node) {
    return node !== null && node !== undefined && node.ready === true
  }

  function _ready(node) {
    return root.graphReady && root._nodeReady(node)
  }

  // The default devices, at the transition rather than at the consumer. Two
  // distinct facts arrive here and they are not the same event:
  //
  //   defaultAudioSinkChanged          the EFFECTIVE default moved. A device
  //                                    disappeared and the compositor picked
  //                                    another one, or the user chose.
  //   defaultConfiguredAudioSinkChanged the CONFIGURED (policy) default moved
  //                                    - the thing the shell itself writes
  //                                    through setDefaultSink below.
  //
  // They diverge exactly when a device is unplugged: policy still names the
  // absent device while the effective default is something else.
  //
  // Neither transition carries work of its own: readiness is a binding
  // (`sinkReady`/`sourceReady` below), so a consumer re-evaluates on its own,
  // and the source link handle is re-pointed by `onSourceChanged`.

  // A list's length as a number, 0 for anything else. The backend's own
  // `UntypedObjectModel.values` is documented as possibly null before the sync,
  // and reading `.length` off null inside a binding throws rather than
  // answering - so the guard is the same one `AudioNodes.countOf` applies,
  // duplicated rather than imported because a services file may not reach
  // sideways for it.
  function countOf(list): int {
    if (list === null || list === undefined) return 0
    const n = list.length
    return typeof n === "number" && n >= 0 ? Math.round(n) : 0
  }

  // The raw backend defaults, ungated. These are what the tracker binds (see
  // the header) and what a caller identifies a device by; they are NOT what a
  // consumer should act on. A device is identified by its own node object and
  // by the label it publishes, never by the numeric PipeWire node id: that is
  // graph state, and the shell's redaction contract forbids naming it.
  readonly property var sinkNode: Pipewire.defaultAudioSink
  readonly property var sourceNode: Pipewire.defaultAudioSource

  readonly property bool sinkReady: root._ready(root.sinkNode)
  readonly property bool sourceReady: root._ready(root.sourceNode)

  // The default devices as a consumer may use them: the same object the
  // backend named, or null until the graph and the node are both ready. A
  // consumer that gets null here is being told "not yet", not "no device",
  // and every read below is written to survive that.
  readonly property var sink: root.sinkReady ? root.sinkNode : null
  readonly property var source: root.sourceReady ? root.sourceNode : null

  // --- published graph state -----------------------------------------
  //
  // Raw sets, published whole; the filters that turn them into a device, a
  // stream or a capture row belong to the service that draws them. `links`
  // is read straight off the service: PwLink.source, .target and .id are
  // documented as available without binding (only PwLink.state is not), so
  // binding every link for three members it already had would buy nothing.
  readonly property var nodes: AudioNodes.nodes
  readonly property var links: Pipewire.links ? Pipewire.links.values : []

  // Non-monitor, deduplicated link groups on the default source. Read
  // through the neutral mechanism's handle, so the bar's volume module and
  // this file share one PwNodeLinkTracker for that node instead of each
  // holding their own.
  property var _sourceLink: null
  readonly property int sourceLinkCount: root._sourceLink !== null
    ? root._sourceLink.linkCount : 0

  // The shell's one node-set observation; the neutral mechanism's node-set
  // tracker lives as long as it does.
  property var _nodeSet: null

  // --- the one object tracker -----------------------------------------
  //
  // Null-filtered and deduplicated by the backend's own node identity, so a
  // device change that briefly reports the same device twice binds it once.
  // An object with no usable identity cannot be deduplicated and is bound as
  // it came; there are at most two entries, so that is bounded by
  // construction rather than by a cap.
  readonly property var _boundDevices: {
    const out = []
    const seen = {}
    const add = (node) => {
      if (node === null || node === undefined) return
      const key = AudioNodes.identity(node)
      if (key !== "") {
        if (seen[key] === true) return
        seen[key] = true
      }
      out.push(node)
    }
    add(root.sinkNode)
    add(root.sourceNode)
    return out
  }

  // The shell's single PwObjectTracker. There is no `enabled` property on
  // this type to set, and the object list is fed from the ungated device
  // nodes on purpose (see the header): binding them is a precondition for
  // their volume, mute and property reads being valid at all, so gating the
  // list on readiness would gate the binding on the binding.
  PwObjectTracker {
    id: objectTracker

    objects: root._boundDevices
  }

  // Ask the neutral mechanism for the default source's link groups. A
  // device switch re-points the existing handle instead of taking a second
  // one, so the tracker count follows the node and not the number of
  // consumers or of device switches.
  function _followSource() {
    if (root._sourceLink !== null) {
      root._sourceLink.linkNode = root.source
      return root._sourceLink
    }
    if (root.source === null) return null
    const handle = AudioNodes.observe("services/pipeWireState", root.source)
    if (handle !== null) root._sourceLink = handle
    return handle
  }

  onSourceChanged: root._followSource()
  Component.onCompleted: {
    // One node-set observation for the shell. It is what keeps the neutral
    // mechanism's one node-set tracker alive for as long as the shell runs,
    // which is also what keeps the nodes published above subscribed.
    root._nodeSet = AudioNodes.observeSet("services/pipeWireState")
    root._followSource()
  }
  // The shell's own end of life. QML ownership: both handles are dropped,
  // which is the only release this file performs. Whether that unbinds
  // anything on the daemon side is NOT documented and NOT demonstrated here
  // (see the header), so the trackers above are deliberately not torn down
  // and re-created per view.
  Component.onDestruction: {
    if (root._nodeSet !== null) {
      AudioNodes.release(root._nodeSet)
      root._nodeSet = null
    }
    if (root._sourceLink !== null) {
      AudioNodes.release(root._sourceLink)
      root._sourceLink = null
    }
  }

  // --- the peak monitors ---------------------------------------------
  //
  // One monitor PER NODE, held only while a consumer asks for it, and owned
  // once for the whole shell. `enabled` is bound to that node's handle count,
  // which is also the documented way to stop it binding the node (the page
  // says the monitor "binds nodes similarly to PwObjectTracker when
  // enabled"), so a node nobody is reading costs nothing.
  //
  // Per node, not per consumer and not per output: the volume island shows a
  // level for the default sink AND for the default source at the same time,
  // so a single monitor cannot serve it, and the mixer takes one per visible
  // row for every device and every stream. Refcounting is per node, so this is
  // a bound on how many DISTINCT nodes are metered at once, not a promise that
  // the same node is never metered twice.
  //
  // Hardcoded ceiling: 64 distinct nodes may carry a level meter at once.
  // The mixer takes one peak monitor per visible row, for every device and
  // every stream, so the ceiling has to clear the rows the window shows or
  // the extra ones get no meter. A refusal is counted, not silent - see
  // acquirePeaks and diagnostics().peakRefusals.
  readonly property int maxPeakNodes: 64
  property var _peakEntries: ({})
  property int _peakRefusals: 0

  // How many nodes are being read right now, and how many monitors that costs.
  readonly property int peakActiveNodes: Object.keys(root._peakEntries).length
  readonly property int peakHandleCount: root._totalPeakHandles()

  function _totalPeakHandles(): int {
    let total = 0
    for (const key in root._peakEntries) {
      const entry = root._peakEntries[key]
      if (entry && entry.handles) total += entry.handles.length
    }
    return total
  }

  // A consumer's hold on one node's monitor. Unparented on purpose: a handle
  // parented to this singleton would outlive its own release, so a view that
  // opened and closed a hundred times would leave a hundred hold objects
  // behind with nothing referencing them. The handle carries the live read,
  // so a view binds to its own hold rather than to a shared projection and
  // two consumers of one node cannot be confused for each other.
  Component {
    id: peakHandleComp

    QtObject {
      property string peakOwner: ""
      property var peakNode: null
      property var peakMonitor: null

      readonly property string owner: peakOwner
      // A reading is only reported while the monitor is actually enabled.
      // The API documents no refresh rate, hold, decay, reset, or retained
      // value after a disable, so a value read while disabled would be one
      // whose freshness cannot be vouched for.
      readonly property bool active: peakMonitor !== null && peakMonitor.enabled === true
      readonly property real peak: active ? peakMonitor.peak : 0
      readonly property var peaks: active ? peakMonitor.peaks : []
      readonly property var channels: active ? peakMonitor.channels : []
    }
  }

  Component {
    id: peakMonitorComp

    PwNodePeakMonitor {
      property string peakKey: ""
      property var peakTarget: null
      property var peakHandles: null

      node: peakTarget
      enabled: peakHandles !== null && peakHandles.length > 0
    }
  }

  // Take the monitor for `node`, creating it if this is the first consumer of
  // that node. Refused, with the reason counted, when the owner is unnamed,
  // when the node is absent, when the graph has not synced, when the node
  // itself is not ready, or when the shell is already reading as many nodes
  // as it has - the last is the bound that keeps this from becoming "one per
  // view" with extra steps.
  function acquirePeaks(owner, node) {
    if (typeof owner !== "string" || owner === "") {
      root._peakRefusals++
      return null
    }
    if (node === null || node === undefined) {
      root._peakRefusals++
      return null
    }
    if (!root._ready(node)) {
      // The two gates are one refusal but they are not one fault: a node that
      // is not ready is a graph still syncing, and a graph that is not ready
      // is no PipeWire at all. A view that silently gets no level is the
      // symptom of both.
      root._peakRefusals++
      return null
    }
    const key = AudioNodes.identity(node)
    if (key === "") {
      root._peakRefusals++
      return null
    }
    let entry = root._peakEntries[key]
    if (entry === undefined) {
      if (root.peakActiveNodes >= root.maxPeakNodes) {
        // The bound is the one refusal that is a DESIGN decision rather than a
        // fault, so `diagnostics().peakRefusals` is the only place it is
        // countable. A level meter that silently does not appear is otherwise
        // indistinguishable from a broken one.
        root._peakRefusals++
        return null
      }
      let monitor = null
      try {
        monitor = peakMonitorComp.createObject(root, { peakKey: key })
      } catch (ignored) {
        monitor = null
      }
      if (monitor === null) {
        root._peakRefusals++
        return null
      }
      entry = { key: key, node: node, monitor: monitor, handles: [] }
      root._peakEntries = Object.assign({}, root._peakEntries, { [key]: entry })
    }
    let handle = null
    try {
      handle = peakHandleComp.createObject(null, {
        peakOwner: owner,
        peakNode: node,
        peakMonitor: entry.monitor
      })
    } catch (ignored) {
      handle = null
    }
    if (handle === null) {
      root._peakRefusals++
      return null
    }
    // Assign the monitor's node and handles only now that the handle exists,
    // so the monitor is never bound to a node with no consumer holding it.
    entry.monitor.peakTarget = node
    entry.monitor.peakHandles = entry.handles.concat([handle])
    root._peakEntries = Object.assign({}, root._peakEntries, {
      [key]: Object.assign({}, entry, { handles: entry.monitor.peakHandles })
    })
    return handle
  }

  // Give it back. Answers whether a hold was actually dropped, so a teardown
  // can assert it: an unknown handle, a handle released twice and a non-handle
  // all answer false. The last hold on a node takes its monitor down with it,
  // so a node nobody reads leaves nothing behind.
  function releasePeaks(handle) {
    if (handle === null || handle === undefined) return false
    let released = false
    for (const key in root._peakEntries) {
      const entry = root._peakEntries[key]
      if (!entry || !entry.handles || entry.handles.indexOf(handle) < 0) continue
      const remaining = entry.handles.filter(h => h !== handle)
      // The handle stops resolving to a live monitor the moment it is
      // released, so a view that kept a stale handle cannot keep reading a
      // monitor that is on its way out.
      handle.peakMonitor = null
      released = true
      if (remaining.length > 0) {
        entry.monitor.peakHandles = remaining
        root._peakEntries = Object.assign({}, root._peakEntries, {
          [key]: Object.assign({}, entry, { handles: remaining })
        })
        return true
      }
      // Last hold for this node: unbind, then destroy.
      entry.monitor.peakHandles = []
      entry.monitor.peakTarget = null
      try {
        entry.monitor.destroy()
      } catch (ignored) {
        // A monitor that is already gone is the outcome we wanted anyway.
      }
      const next = Object.assign({}, root._peakEntries)
      delete next[key]
      root._peakEntries = next
      return true
    }
    return released
  }

  // --- default-device changes ------------------------------------------
  //
  // The explicit write the shell makes to the backend's default devices.
  // Gated on the graph being synced (a pre-sync write can land on preference
  // metadata the service documents as possibly null, while a device is
  // changing) and on the node being non-null. A node that is present but not
  // yet ready is accepted: the write is a hint carrying the node's identity,
  // not a read of the node's incomplete state.
  //
  // The volume island still performs this write itself (Spec 08 left the one
  // backend write a per-output view owns untouched); routing it here is the
  // follow-up that needs shell/features, which this change does not touch.
  function setDefaultSink(node) {
    if (!root.graphReady || node === null || node === undefined) return false
    Pipewire.preferredDefaultAudioSink = node
    return true
  }

  function setDefaultSource(node) {
    if (!root.graphReady || node === null || node === undefined) return false
    Pipewire.preferredDefaultAudioSource = node
    return true
  }

  // --- diagnostics -----------------------------------------------------
  //
  // What is actually held, so "one tracker set for the whole shell" is
  // something a caller can read rather than something it has to believe.
  // `releaseDemonstrated` is false on purpose and stays false until a
  // disposable real graph shows the daemon unbinding a cleared, destroyed
  // tracker; until then the owner is resident by decision, not by oversight.
  // `memoEntries` is 0 because this owner memoizes nothing at all: there is
  // no per-key map here to grow, so its only bound is the tracker counts
  // above. The bounded icon/artwork cache contract of spec 09 section 6
  // belongs to shell/common (another owner's files) and is not claimed here.
  function diagnostics() {
    const neutral = AudioNodes.diagnostics()
    return {
      objectTrackers: 1,
      trackedObjects: root._boundDevices.length,
      trackerResident: true,
      releaseDemonstrated: false,
      releasePolicy: "resident",
      // Monitors alive, not a constant: one per node currently being read,
      // and zero when nothing is. A caller can read this instead of
      // believing the claim.
      peakMonitors: root.peakActiveNodes,
      peakNodesBound: root.peakActiveNodes,
      peakConsumers: root.peakHandleCount,
      peakMaxNodes: root.maxPeakNodes,
      peakRefusals: root._peakRefusals,
      memoEntries: 0,
      nodeSetObservers: neutral.observers,
      nodeCount: neutral.nodeCount,
      sourceLinkTrackers: neutral.links[AudioNodes.identity(root.source)] === undefined
        ? 0 : neutral.links[AudioNodes.identity(root.source)].trackers,
      sourceLinkGroups: root.sourceLinkCount
    }
  }
}
