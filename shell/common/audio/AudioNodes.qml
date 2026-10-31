pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Services.Pipewire
import "../theme/DeviceIcons.js" as DeviceIcons

// AudioNodes - ONE object tracker over the backend's node set, ONE link
// tracker per observed node, many observers.
//
// Neutral mechanism, no policy: it subscribes to the node set the backend
// publishes, tracks whatever node a caller names, and answers two
// questions - what is linked to that node, and how many nodes are live.
// `handle.linkCount` is the size of that answer and `handle.links` is the
// answer itself: a list of `{ source, target }` pairs carrying the two node
// objects of each link group the backend reports. That list is unfiltered - a
// monitor, a filter leg and a device-to-device pair are all in it - because
// what a caller is willing to draw from a link is its own policy, and this
// file has none. What a playback device, a capture device, a stream or a
// microphone IS, which device is the default and what a link group MEANS stay
// with the caller. A caller's policy does not move into a common file merely
// to make it loadable: the caller still reads the device it read before, from
// the same place, and still applies its own filter to the node set it is
// handed.
//
// Why it exists: a backend tracker is a subscription on process-global
// state, so a tracker built inside a per-output delegate is N
// subscriptions on the same node objects and N link-group bindings for one
// global default device. Here the count follows the NODE, not the
// consumer: every observer of the node set shares one PwObjectTracker,
// every observer of one node shares one PwNodeLinkTracker, and the last
// observer leaving destroys both.
//
// Lifecycle:
//   observe(owner, node) -> handle (read-only `linkCount`, `links`,
//                           `revision`), answering the node's current
//                           topology on the turn it is issued
//   observeSet(owner)    -> handle for a caller that filters the set but
//                           names no node; no link tracker is created
//   release(handle)      -> drop one observation, of either kind; the last
//                           one releases the object tracker and every link
//                           tracker
// The handle is the reference the count is keyed on, so two consumers of one
// feature never share a count. The owner string is the consumer's own name
// and is carried for diagnostics only; it is not an identity, so a reload
// that mints the same name again cannot inherit or strand an observation.
// A handle's `linkNode` is writable and the observation follows it, so a
// device switch moves the handle onto the new node's entry - one tracker
// still, and the caller does not have to re-issue its handle.
//
// observeSet() is a peer of observe(), not a weaker form of it. observe()
// refuses a caller that names no node, because a node is what keys an entry
// and an unkeyable observation cannot be counted without guessing - and a
// guess would merge two devices into one tracker. A caller that only reads
// the set needs no entry at all, so it says so instead of naming a node it
// does not follow, and gets the node-set subscription with no link tracker
// behind it. The two kinds share one lifetime: the object tracker is created
// with the first observation of either kind and destroyed with the last.
Singleton {
  id: root

  readonly property string tag: "audioNodes"

  // The backend's node set, published whole: one tracked set, many
  // consumers, each of which applies its own filter to it. It is live
  // only while somebody observes it, and it stays one value however many
  // observers there are - a consumer count that grows while this stays at
  // one is the whole point.
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []

  // The single PwObjectTracker over `nodes`, created with the first
  // observer and destroyed with the last. The handle lists are the
  // reference count, so an observer that only wants the node set still
  // counts.
  property var _objectTracker: null
  property var _handles: []
  // Handles that named no node: they are counted in the node set and in
  // nothing else, so the count of what is held is the count of handles
  // rather than a total recomputed from two different places.
  property var _setHandles: []

  // node key -> { key, node, tracker, linkCount, links, handles: [] }
  // The map is replaced wholesale on every mutation so a reader that
  // captured it re-reads instead of holding a stale entry object.
  property var _entries: ({})

  // Aggregate revision: bumped whenever an observed node's link topology
  // moves, and when an observation is added or dropped. Per-node consumers
  // follow their own handle's revision instead; this is for a caller that
  // wants to know something moved.
  property int rev: 0

  // A node's link groups changed: republish the new topology to every
  // observer of that node, so a caller binding on `linkCount` or on
  // `links` re-evaluates from the one tracker rather than from a per-output
  // copy.
  //
  // The unknown-key return is reachable rather than defensive: a tracker fills
  // `linkGroups` while it is being built, so for a node whose links already
  // exist it raises this from inside the `createObject` that made it, which is
  // before _ensureEntry has registered anything under the key. _ensureEntry
  // reads that same view off the tracker and seeds the entry with it.
  function _republish(key) {
    const entry = root._entries[key]
    if (entry === undefined) return
    const view = root._linkView(entry)
    // A tracker fires this on a list change, so the cheap test is against
    // the previous view rather than a count: a swapped endpoint pair leaves
    // `linkCount` where it was and is still a topology change.
    if (view.count === entry.linkCount && root._sameLinks(view.links, entry.links)) return
    // The link topology of ONE node moved. This is the event that answers "the
    // mic-in-use light just came on", and it is published from the tracker that
    // noticed rather than from the consumer drawing the indicator - the
    // consumer cannot tell a topology change from its own re-render.
    root._publish(key, Object.assign({}, entry, {
      linkCount: view.count,
      links: view.links,
      revision: entry.revision + 1
    }))
    root.rev++
  }

  // The tracker's link groups as `{ count, links }`: the number a caller
  // counts and the pairs a caller walks, read once so the two cannot
  // disagree about what was on the tracker.
  //
  // `linkCount` stays the group's length even when a pair is skipped below, so
  // a caller counting groups and a caller walking pairs never see different
  // totals for the same tracker - the two answers are the same event.
  //
  // PwLinkGroup.source and .target are node objects, so the pair carries the
  // objects themselves: a consumer that wants a level reads it off the
  // endpoint rather than looking the node up again. PwLinkGroup.state is NOT
  // read - state is invalid unless the group is itself bound through a
  // PwObjectTracker, and a caller that wanted it would have to own that
  // binding itself.
  function _linkView(entry): var {
    const tracker = entry.tracker !== null && entry.tracker !== undefined ? entry.tracker : null
    const groups = tracker === null ? null : tracker.linkGroups
    const count = root.countOf(groups)
    const links = []
    for (let i = 0; i < count; i++) {
      const pair = root._linkPairAt(groups, i)
      if (pair !== null) links.push(pair)
    }
    return { count: count, links: links }
  }

  // One group as `{ source, target }`, or null. Guarded twice over: the group
  // list is rebuilt by the backend when a group goes away, so an index can name
  // a pointer that is already gone, and an endpoint on a group whose node has
  // left reads as undefined.
  function _linkPairAt(groups, index) {
    try {
      const group = groups[index]
      if (group === undefined || group === null) return null
      const source = group.source
      const target = group.target
      if (source === undefined || target === undefined) return null
      if (source === null || target === null) return null
      return { source: source, target: target }
    } catch (ignored) {
      return null
    }
  }

  // Element-wise equality over the projection. Link groups are deduplicated to
  // one entry per source->target pair and a node has a handful of them, so
  // this runs on a tracker notification and not per frame. Endpoint identity
  // is the QObject pointer the backend published, which is what makes two
  // reports of one group compare equal.
  function _sameLinks(a, b) {
    if (a === b) return true
    if (!Array.isArray(a) || !Array.isArray(b)) return false
    if (a.length !== b.length) return false
    for (let i = 0; i < a.length; i++) {
      if (a[i].source !== b[i].source || a[i].target !== b[i].target) return false
    }
    return true
  }

  // The backend's own identity for a node, so two outputs naming the same
  // device join ONE entry. "" for anything without a usable id, and
  // observe() refuses that: an unkeyed observation cannot be counted, and a
  // guessed key would merge two devices into one tracker.
  function identity(node): string {
    if (node === null || node === undefined) return ""
    const id = node.id
    if (typeof id !== "number" || !(id >= 0)) return ""
    return "node:" + String(id)
  }

  // A link tracker reports its groups as a list; its length is the answer.
  // Guarded so an absent list reads as zero instead of throwing inside a
  // binding.
  function countOf(list): int {
    if (list === null || list === undefined) return 0
    const n = list.length
    return typeof n === "number" && n >= 0 ? Math.round(n) : 0
  }

  // Create the shared link tracker for a node if it does not exist yet and
  // take the first count, so an observer that binds on the same turn
  // already reads a real answer rather than a default.
  //
  // The entry is registered BEFORE the seed is taken, so an entry exists for
  // every signal from the moment the tracker does, and the seed is the
  // tracker's own `linkGroups` rather than a hardcoded zero. That order is the
  // whole mechanism: `PwNodeLinkTracker` resolves its groups as it is built, so
  // a tracker made for a node whose links already exist raises
  // `linkGroupsChanged` from inside `createObject`, and `_republish` looks the
  // key up before there is an entry under it. A zero seeded here is then the
  // last word on the subject until the topology itself moves, so every observer
  // of a device the graph was carrying streams for reads "no links" in silence.
  //
  // Seeding the ENTRY rather than the handles is what keeps _republish's cheap
  // test honest afterwards: it compares the tracker's view against this one, so
  // the next real move is still published and a repeated report of this same
  // view is not.
  function _ensureEntry(node, key) {
    const existing = root._entries[key]
    if (existing !== undefined) return existing
    const tracker = linkComp.createObject(root, { linkKey: key, linkNode: node })
    const entry = {
      key: key,
      node: node,
      tracker: tracker,
      linkCount: 0,
      links: [],
      revision: 0,
      handles: []
    }
    root._store(key, entry)
    // No observer is counted on a fresh entry yet - observe() and _move() both
    // publish their handle into it afterwards - so the seed is stored rather
    // than published: there is nobody to hand it to, and the entry is the only
    // thing that has to carry it.
    const seeded = root._linkView(entry)
    root._store(key, Object.assign({}, entry, {
      linkCount: seeded.count,
      links: seeded.links
    }))
    return root._entries[key]
  }

  // Create the ONE object tracker for the node set on the first
  // observation, and follow the node set for as long as it is held. It is
  // the only place the node set is subscribed to, so the count of
  // subscriptions is a property of this file and not of how many outputs
  // the shell has.
  function _ensureObjectTracker() {
    if (root._objectTracker !== null) return root._objectTracker
    const tracker = objectComp.createObject(root, { trackNodes: root.nodes })
    root._objectTracker = tracker
    return tracker
  }

  // Register an observation of the node set and, when `node` names one, of
  // that node's link groups. Returns the handle the count is keyed on, or
  // null when the arguments do not answer the contract. Every call is its
  // own observation: the owner string is the consumer's name for
  // diagnostics, the handle is the identity the count is keyed on.
  function observe(owner, node) {
    if (typeof owner !== "string" || owner === "") return null
    const key = root.identity(node)
    if (key === "") return null
    if (root._ensureEntry(node, key) === undefined) return null
    let handle = null
    try {
      handle = handleComp.createObject(null, {
        trackOwner: owner,
        linkNode: node
      })
    } catch (ignored) {
      return null
    }
    if (handle === null) return null
    root._ensureObjectTracker()
    // Re-read: building the entry can already have produced an answer, and
    // publishing from the entry captured before that would put its older
    // count back.
    const entry = root._entries[key]
    if (entry === undefined) return null
    root._handles = root._handles.concat([handle])
    root._publish(key, Object.assign({}, entry, {
      handles: entry.handles.indexOf(handle) >= 0
        ? entry.handles
        : entry.handles.concat([handle])
    }))
    return handle
  }

  // Register an observation of the node set alone. Same contract as
  // observe() for the owner, and the same handle; what it does not do is
  // name a node, so it creates no entry and no link tracker. This is for
  // the caller that reads the set and applies its own filter to it - the
  // device lists and stream rows it shows are its policy, not the
  // tracker's, and it has nothing to follow because it follows nothing.
  function observeSet(owner) {
    if (typeof owner !== "string" || owner === "") return null
    let handle = null
    try {
      handle = handleComp.createObject(null, {
        trackOwner: owner
      })
    } catch (ignored) {
      return null
    }
    if (handle === null) return null
    // The set is live for as long as ANY observation of it is, of either
    // kind, so a node-set-only observation subscribes to the set and never
    // takes it away again on its own.
    root._ensureObjectTracker()
    root._setHandles = root._setHandles.concat([handle])
    return handle
  }

  // Move an observation onto the node its handle currently names, which is
  // how a device switch is followed: the old entry loses the handle, the
  // new one gains it, and the node set observation is untouched because it
  // was never tied to a device.
  //
  // A handle that is not counted anywhere is left alone: observe() counts
  // the handle it just built, and a change landing on a handle before that
  // would register an entry nothing can release.
  function _move(handle) {
    if (handle === null || handle === undefined) return
    if (root._handles.indexOf(handle) < 0) return
    const from = root._entryOf(handle)
    if (from !== undefined) {
      const remaining = from.handles.filter(h => h !== handle)
      if (remaining.length === from.handles.length) return
      if (remaining.length > 0) {
        root._publish(from.key, Object.assign({}, from, { handles: remaining }))
      } else {
        root._dropEntry(from.key)
      }
    }
    const key = root.identity(handle.linkNode)
    if (key === "") {
      // The backend withdrew the node. The entry is gone, so the handle must
      // stop reporting what it was reading - otherwise a consumer keeps a
      // stale "1 link" for a device that no longer exists, and anything
      // derived from it (the mic-in-use indicator, the device row's stream
      // list) stays lit or stays populated after the device is gone. A handle
      // with nowhere to follow reports nothing.
      handle.trackState = {
        linkCount: 0,
        links: [],
        revision: handle.trackState.revision + 1
      }
      return
    }
    if (root._ensureEntry(handle.linkNode, key) === undefined) {
      // Same for a node that cannot be keyed: the observation exists but has
      // no entry, so there is nothing to report.
      handle.trackState = {
        linkCount: 0,
        links: [],
        revision: handle.trackState.revision + 1
      }
      return
    }
    // Re-read for the same reason observe() does: the entry creation above
    // can already have answered.
    const entry = root._entries[key]
    if (entry === undefined) return
    root._publish(key, Object.assign({}, entry, {
      handles: entry.handles.filter(h => h !== handle).concat([handle])
    }))
  }

  // Drop one observation, of either kind. Answers whether an observation
  // was actually dropped, so a teardown can assert it: an unknown handle, a
  // handle released twice and a non-handle all answer false. The last
  // observer leaving - of either kind, and in any order - destroys the
  // object tracker and every link tracker, so a feature closed everywhere
  // leaves no PipeWire subscription behind.
  function release(handle) {
    if (handle === null || handle === undefined) return false
    if (!root._drop(handle)) {
      // Releasing twice, releasing a foreign handle, or releasing something
      // that was never an observation. All three are caller bugs and all three
      // are indistinguishable from success to a caller that ignores the answer.
      return false
    }
    // One teardown site for the node set, so the object tracker cannot be
    // released twice or not at all: it goes when the last observation of
    // EITHER kind goes, because a set-only observation subscribes to the
    // set just as a node observation does.
    if (root._handles.length === 0 && root._setHandles.length === 0
      && root._objectTracker !== null) {
      root._objectTracker.destroy()
      root._objectTracker = null
    }
    return true
  }

  // Forget one handle, wherever it is counted. A set-only handle is counted
  // in the set and nowhere else, so it is looked for there first; a node
  // handle is counted in its entry, and the last one out gives that entry's
  // link tracker back. Returns whether anything was dropped, so release()
  // cannot release the object tracker for a handle it did not count.
  function _drop(handle) {
    const remainingSets = root._setHandles.filter(h => h !== handle)
    if (remainingSets.length < root._setHandles.length) {
      root._setHandles = remainingSets
      return true
    }
    const entry = root._entryOf(handle)
    if (entry === undefined) return false
    const remaining = root._handles.filter(h => h !== handle)
    if (remaining.length === root._handles.length) return false
    root._handles = remaining
    // The entry's own count decides whether it survives, not the global
    // one: with observers on two nodes, the last observer of the first one
    // must still give that node's link tracker back while the second node
    // is being observed.
    const held = entry.handles.filter(h => h !== handle)
    if (held.length > 0) {
      root._publish(entry.key, Object.assign({}, entry, { handles: held }))
      return true
    }
    root._dropEntry(entry.key)
    return true
  }

  // The entry a handle is currently counted in, or undefined when it is
  // counted in none of them.
  function _entryOf(handle) {
    for (const key in root._entries) {
      const entry = root._entries[key]
      if (entry === undefined) continue
      if (entry.handles.indexOf(handle) >= 0) return entry
    }
    return undefined
  }

  // Remove an entry and destroy the link tracker it held: the last observer
  // of a node is what releases that node's tracker.
  function _dropEntry(key) {
    const entry = root._entries[key]
    if (entry !== undefined && entry.tracker !== null && entry.tracker !== undefined) {
      entry.tracker.destroy()
    }
    const next = Object.assign({}, root._entries)
    delete next[key]
    root._entries = next
    root.rev++
  }

  // What is actually held: the object tracker's existence, the live
  // observation count (of both kinds, and the node-set-only ones on their
  // own), and per node the link tracker's existence, its observer count and
  // the current count. This is what "one tracker set for many observers" is
  // checked against.
  function diagnostics() {
    const out = {
      objectTrackers: root._objectTracker !== null && root._objectTracker !== undefined ? 1 : 0,
      observers: root._handles.length + root._setHandles.length,
      setObservers: root._setHandles.length,
      nodeCount: root.countOf(root.nodes),
      links: {}
    }
    for (const key in root._entries) {
      const entry = root._entries[key]
      if (entry === undefined) continue
      out.links[key] = {
        trackers: entry.tracker !== null && entry.tracker !== undefined ? 1 : 0,
        observers: entry.handles.length,
        linkCount: entry.linkCount
      }
    }
    return out
  }

  // Publish an entry: hand every observer the new topology as a fresh state
  // object, then swap the map so a reader that captured the old map
  // re-reads. The fresh object is what re-evaluates the handle's read-only
  // views without exposing them to an external write.
  function _publish(key, entry) {
    const handles = entry.handles
    const links = entry.links
    for (let i = 0; i < handles.length; i++) {
      const handle = handles[i]
      if (handle === null || handle === undefined) continue
      handle.trackState = {
        linkCount: entry.linkCount,
        links: links,
        revision: entry.revision
      }
    }
    const next = Object.assign({}, root._entries)
    next[key] = entry
    root._entries = next
  }

  function _store(key, entry) {
    const next = Object.assign({}, root._entries)
    next[key] = entry
    root._entries = next
  }

  // --- graph observation ------------------------------------------------
  //
  // This file has no per-object graph event handler, and that is a fact about
  // the backend rather than an omission. Read out of
  // /usr/lib/qt6/qml/Quickshell/Services/Pipewire/quickshell-service-pipewire.qmltypes
  // the `Pipewire` type exports NO signals at all: `nodeAdded`, `nodeRemoved`,
  // `linkAdded` and `linkRemoved` exist there as C++ METHODS, which are
  // Quickshell's own PipeWire callbacks exposed as invokable and are not
  // emittable. A `Connections { target: Pipewire; function "onNodeAdded"() }`
  // declares a handler for a signal called `nodeAdded`, that signal does not
  // exist, and Qt says so at runtime:
  //
  //   WARN scene: QML Connections at @common/audio/AudioNodes.qml: Detected
  //   function "onNodeAdded" in Connections element. This is probably intended
  //   to be a signal handler but no signal of the target matches the name.
  //
  // What IS observable is the model. `Pipewire.nodes` and `Pipewire.links` are
  // `UntypedObjectModel`s, and those emit `objectInsertedPost(object, index)`
  // and `objectRemovedPost(object, index)`. Nothing subscribes to those here
  // either, and nothing needs to: every graph question this file answers comes
  // out of a tracker's own counts, so a node's arrival and departure only have
  // to reach the ONE object tracker, which the `onNodesChanged` handler here
  // does.
  //
  // The whole-set `onNodesChanged` is the only subscriber, and it cannot say
  // WHICH node moved - it fires on every set replacement. That is enough here
  // because a caller's answer is a re-evaluation of a projection over the set,
  // not an event with an argument.
  //
  // Link count, read straight off the service. `Pipewire.links` is an object
  // model, so `.values` is the list - the same read PipeWireState publishes as
  // `links`, duplicated rather than imported because `common/` files do not
  // reach into `services/`. PwLink.source, .target and .id are documented as
  // available without binding, so this needs no tracker of its own; PwLink.state
  // is the member that would, and nothing here reads it.
  readonly property var linkValues: Pipewire.links ? Pipewire.links.values : []
  readonly property int linkCount: root.countOf(root.linkValues)

  onNodesChanged: {
    if (root._objectTracker !== null && root._objectTracker !== undefined) {
      root._objectTracker.objects = root.nodes
    }
  }

  // The single object tracker. Its `objects` is set at creation and re-set
  // from the singleton's own change handler, which is the only place the
  // node set is subscribed to.
  Component {
    id: objectComp

    PwObjectTracker {
      property var trackNodes: []

      objects: trackNodes
    }
  }

  // The single link tracker per observed node, created by _ensureEntry and
  // destroyed with the last observer of that node.
  Component {
    id: linkComp

    PwNodeLinkTracker {
      property string linkKey: ""
      property var linkNode: null

      node: linkNode
      onLinkGroupsChanged: root._republish(linkKey)
    }
  }

  // One observation. The read-only views are derived from a state
  // object the tracker replaces, so a binding on `linkCount` or on `links`
  // re-evaluates on every change and no consumer can write either. `linkNode`
  // is writable on purpose: it is how a caller follows a device switch. A
  // handle that named no node keeps it null, and a change landing on a
  // handle nobody is counting is ignored by _move(), so a caller that
  // writes here after its own release cannot register an entry or build a
  // tracker nothing will release.
  //
  // The handle is created with a null parent. Parented to the singleton it
  // would outlive its own release - a feature that opened and closed its
  // bar a hundred times would leave a hundred observation objects behind,
  // since nothing but the entry's list ever referenced them.
  Component {
    id: handleComp

    QtObject {
      id: observation

      property string trackOwner: ""
      property var linkNode: null
      property var trackState: ({ linkCount: 0, links: [], revision: 0 })

      readonly property string owner: observation.trackOwner
      readonly property int linkCount: observation.trackState.linkCount
      // The link groups themselves, `{ source, target }` per pair, so a
      // caller can say WHAT is attached to a node rather than only how many
      // things are. An empty list is a real answer for a node nothing is
      // linked to and for a handle whose node the backend withdrew.
      readonly property var links: observation.trackState.links
      readonly property int revision: observation.trackState.revision

      onLinkNodeChanged: root._move(observation)
    }
  }

  // Volume-tier helper: tiered level glyph for a 0..1 fraction, resolved
  // through the shared common/theme/DeviceIcons.js table so audio views
  // never hand-roll the volume thirds.
  function volumeTierIcon(volume, muted) {
    return DeviceIcons.volumeIconFor(volume, muted)
  }
}
