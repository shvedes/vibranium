.pragma library

.import "../../../common/theme/DeviceIcons.js" as DeviceIcons

// Pure derivations for the audio mixer: what a node IS, what it is CALLED,
// what a level prints as, and the `pactl list` parser that turns Pulse
// indices into PipeWire node ids.
//
// No Qt imports and no host object: every function here is driven by plain
// values, which is what makes the classifier and the parser unit-drivable
// outside a live graph. Everything is defensive because these run inside QML
// bindings, where a throw is a warning on stderr and an undefined result on
// screen - so a shape nobody expected has to answer "unknown", never fault.

// --- node shape ---------------------------------------------------------

// One text field, trimmed, with a non-string answer as "absent". A PipeWire
// string property is a string and a deleted QObject reads as undefined, and
// both have to fall through to the next candidate rather than print
// "undefined".
function text(value) {
  if (typeof value !== "string") return ""
  return value.trim()
}

// The node's own property map, or an empty one. Deliberately not gated on
// `ready`: a pre-ready node publishes a possibly incomplete map, which is the
// right answer for a label (the next candidate covers the gap) where a
// half-read volume would not be.
function props(node) {
  if (node === null || node === undefined) return ({})
  try {
    const p = node.properties
    if (p !== null && typeof p === "object") return p
  } catch (ignored) {
    return ({})
  }
  return ({})
}

// The decimal PipeWire node id, as the string every lookup here is keyed by.
// This is the join key between the graph and `pactl`: `pactl` addresses
// objects by its OWN index, and every object it prints carries
// `object.id = "<pipewire node id>"`, so a node and its Pulse index meet
// here. "" for a node without a usable id, because an unkeyable node cannot
// be looked up and a guessed key would move the wrong stream.
function nodeKey(node) {
  if (node === null || node === undefined) return ""
  let id = null
  try {
    id = node.id
  } catch (ignored) {
    return ""
  }
  if (typeof id === "string") {
    return /^\d+$/.test(id.trim()) ? id.trim() : ""
  }
  if (typeof id !== "number" || !isFinite(id) || id < 0) return ""
  return String(Math.round(id))
}

function propText(node, key) {
  const p = props(node)
  if (!Object.prototype.hasOwnProperty.call(p, key)) return ""
  return text(p[key])
}

// The node's own name, or "". Guarded like every other read here, because a
// filter that tests `node.name` must answer "no name" rather than take the
// binding down with it when the accessor faults.
function nodeName(node) {
  if (node === null || node === undefined) return ""
  try {
    return text(node.name)
  } catch (ignored) {
    return ""
  }
}

// An id or a count carried as a property, as its decimal text. The PipeWire
// property map publishes these as strings; a synthetic node in a unit drive
// carries the number itself, and both have to reach the same key.
function propId(node, key) {
  const raw = props(node)[key]
  if (typeof raw === "number" && isFinite(raw) && raw >= 0) return String(Math.round(raw))
  return propText(node, key)
}

// --- classification -----------------------------------------------------

// What a node is, from the two booleans the API documents and nothing else.
// `type` is a `PwNodeType` flags value, and a flag word read as a string and
// substring-matched is how a wrong row happens, so it is not read at all.
//
//   isSink  isStream  kind
//   true    false      output device
//   false   false      input device
//   false   true       capture stream
//   true    true       playback stream
//   -       -          null
//
// null is a real answer and not a failure: anything the four rows cannot
// place is dropped rather than guessed into a row that would then write a
// volume onto the wrong node.
function classify(node) {
  if (node === null || node === undefined) return null
  let sink = null
  let stream = null
  try {
    sink = node.isSink
    stream = node.isStream
  } catch (ignored) {
    return null
  }
  if (typeof sink !== "boolean" || typeof stream !== "boolean") return null
  if (sink === true) return stream === true ? "playbackStream" : "outputDevice"
  return stream === true ? "captureStream" : "inputDevice"
}

// The two kinds the tabs are split by, and the two a device row can host.
function isStreamKind(kind) {
  return kind === "playbackStream" || kind === "captureStream"
}

// The palette KEY one kind is drawn in, and the only place that pairing is
// written down.
//
//   playbackStream  green        what plays
//   captureStream   red          what captures, the recording colour
//   outputDevice    blue         one end of the hardware
//   inputDevice     yellow       the other end
//   anything else   foreground_1 no claim
//
// A card wears this key on its stripe and its glyph, and a line wears the key
// of the kind of the card it LEAVES. The line continues the identity of the
// card it starts at, the same way its endpoint continues the mark it meets, so
// the canvas speaks one colour system rather than three: a user tracing a line
// back learns what class of thing feeds it without reading a word of it.
//
// Four fixed hues and never `accent`: `accent` is the user's own choice and on
// more than one palette here it resolves to the same colour as `blue`, which
// would hand two kinds one hue - and a hue that cannot be told apart is a hue
// carrying nothing.
//
// A kind this table does not know wears the foreground's grey. That is not a
// fallback for a bug: it is the honest answer for a node that is none of the
// four, and grey is a colour that claims no membership.
function kindColorKey(kind) {
  if (kind === "playbackStream") return "green"
  if (kind === "captureStream") return "red"
  if (kind === "outputDevice") return "blue"
  if (kind === "inputDevice") return "yellow"
  return "foreground_1"
}

// Whether a drawn link is the mixer's OWN "hear my voice" route, from the kinds
// of the two cards it joins - and the direction is the whole of it.
//
// A monitor leg joins an input device to an output device, and BOTH orders are
// a monitor, because PipeWire expresses the same route two ways and the mixer
// only ever writes one of them:
//
//   inputDevice  ->  outputDevice   what the mixer writes:
//                                    `pw-link <device:capture_FL>
//                                    <sink:playback_FL>`, the mic's own capture
//                                    into the speakers. This is the wiremix
//                                    behaviour and the only one that works for
//                                    a capture-only device.
//   outputDevice ->  inputDevice    the older shape,
//                                    `pw-link <sink:monitor_FL>
//                                    <device:playback_FL>`. The mixer does not
//                                    write this, because a microphone has no
//                                    playback ports to receive it - but a user
//                                    can draw it by hand, and this tab's job is
//                                    to show the graph's shape.
//
// Both ends are named rather than one, because the one-sided readings all exist
// and all are wrong in a way that is invisible on screen:
//
//   target is any device   dashes every hardware leg, including a filter
//                          chain's own `eq_input -> eq_output`, whose two ends
//                          are both output devices and which is an ordinary
//                          link the user may well have drawn
//   source is any device   dashes every line that leaves hardware, which on
//                          this machine is most of them
//   inputDevice -> captureStream   that is the microphone being RECORDED, which
//                          is the other thing an input device is for
//   playbackStream -> outputDevice that is every ordinary stream, and the graph
//                          is mostly made of them
//
// The pair is also narrow enough to be empty on a graph with no monitor on, and
// that is correct: with nothing monitored the mixer owns no leg and draws none.
// Nothing here can turn a dashed line on, only recognise one the controller
// already wrote.
function isMonitorLeg(sourceKind, targetKind) {
  if (sourceKind === "inputDevice") return targetKind === "outputDevice"
  if (sourceKind === "outputDevice") return targetKind === "inputDevice"
  return false
}

// A source monitor is a Source whose name ends in `.monitor`: PipeWire makes
// one node object per monitor, named after the device it watches.
function isMonitorName(name) {
  return text(name).slice(-8) === ".monitor"
}

// --- the shell's own taps ---------------------------------------------
//
// Opening the mixer puts three nodes named "quickshell" into the graph, every
// one of them `media.class = "Stream/Input/Audio"`, and their count
// oscillates 2 -> 3 -> 0. They are the capture streams behind this shell's own
// PwNodePeakMonitor holds. They classify as capture streams, so the Apps tab
// listed them, every one of those rows took a peak handle of its own, and a
// handle creates another tap: the app fed its own loop and the tab flickered.
//
// This predicate is where the loop is broken, AT THE SOURCE. A tap that is
// never listed is never given a handle, so no second tap is created and
// nothing is left to oscillate. A longer debounce would not break the loop; it
// would only slow it down while still drawing rows for the shell itself.

var SHELL_OWN_NAME = "quickshell"
var CAPTURE_CLASS = "Stream/Input/Audio"

// Whether a node name is the shell's own. PipeWire names a monitor capture
// stream after the process that opened it, so this is a fact about the NAME,
// which is exactly why the name alone is never the test: it identifies the
// shell as the owner of the stream and says nothing about what the stream is
// for. A suffix is the same owner (a per-instance tag) and never a third-party
// application, because no desktop application publishes this name.
function isShellOwnName(name) {
  const n = text(name).toLowerCase()
  if (n === "") return false
  if (n === SHELL_OWN_NAME) return true
  return n.indexOf(SHELL_OWN_NAME + ".") === 0
    || n.indexOf(SHELL_OWN_NAME + "-") === 0
    || n.indexOf(SHELL_OWN_NAME + "_") === 0
}

// Is this node one of the shell's own peak taps? A pure function of the
// node's properties, so it is unit-drivable with no graph behind it.
//
// Two of them together, never the name on its own:
//
//   no application.name  the shell's peak taps belong to no application, so a
//                        node the graph cannot attribute to any application
//                        and which the shell has named after itself is the
//                        shell's own, whatever its class says.
//   Stream/Input/Audio   the peak-detect signature. A monitor capture stream
//                        always publishes this class, and a node named after
//                        the shell carrying it is the tap even though it does
//                        publish an application label of its own ("Quickshell
//                        Peak Detect") - that label is the shell's own label
//                        and is not evidence of an application behind the node.
//
// The class is deliberately not the whole test: an application's own capture
// stream is `Stream/Input/Audio` too, and it is kept.
function isShellTap(node) {
  if (!isShellOwnName(nodeName(node))) return false
  if (propText(node, "application.name") === "") return true
  return propText(node, "media.class") === CAPTURE_CLASS
}

// Is this node a stream a user can act on? The positive form the row lists
// ask, and the exact opposite of isShellTap: a stream carrying an
// `application.name`, or whose node name is not the shell's own, is one
// whatever its media class says.
function isApplicationStream(node) {
  return !isShellTap(node)
}

// --- list identity ----------------------------------------------------
//
// The next list, or the CURRENT one when the two hold the same nodes in the
// same order.
//
// A published list is a Repeater's model, so a fresh array identity rebuilds
// every row even when every member is unchanged - and the graph republishes
// its whole node set on any node arriving or leaving, which on this machine
// includes the shell's own peak taps coming and going. Returning the
// incumbent makes "nothing moved" cost no rows at all, which is what stops a
// row from tearing its peak hold down and taking it again every tick.
function stableList(current, next) {
  if (!Array.isArray(current) || !Array.isArray(next)) return next
  if (current.length !== next.length) return next
  for (let i = 0; i < next.length; i++) {
    if (current[i] === next[i]) continue
    // The graph republishes its set wholesale, so an unchanged node can
    // arrive behind a fresh wrapper. The PipeWire id is the identity the
    // shell keys its own observations on (AudioNodes.identity), so it is what
    // "the same node" means here. A member with no usable id counts as a
    // change rather than as equal to another one: two unkeyable nodes are not
    // known to be the same node.
    const key = nodeKey(current[i])
    if (key !== "" && key === nodeKey(next[i])) continue
    return next
  }
  return current
}

// --- labels ------------------------------------------------------------

// What a row is called: nickname, then the hardware description, then the
// media name, then the node's own name, and "" when none of them is usable.
//
// `node.name` is client-supplied and last on purpose - it is what an
// application chose to call its own stream, and it is also the string a
// filter chain publishes ("eq_output"), which is why nothing above it falls
// back DOWN to it. The numeric PipeWire id is never a label: it is graph
// state, not a name.
function label(node) {
  if (node === null || node === undefined) return ""
  let nick = ""
  let desc = ""
  try {
    nick = text(node.nickname)
    desc = text(node.description)
  } catch (ignored) {
    return ""
  }
  if (nick !== "") return nick
  if (desc !== "") return desc
  const media = propText(node, "media.name")
  if (media !== "") return media
  return text(node.name)
}

// The application a stream belongs to, and the secondary line under it: what
// is playing, as opposed to who is playing it. Same fallback order as
// label(), restricted to the stream-shaped keys first.
function appName(node) {
  const app = propText(node, "application.name")
  if (app !== "") return app
  const media = propText(node, "media.name")
  if (media !== "") return media
  return label(node)
}

function mediaName(node) {
  const media = propText(node, "media.name")
  if (media !== "") return media
  const title = propText(node, "media.title")
  if (title !== "") return title
  return ""
}

// A themed icon name, or "" when the node names none. Ordered client data ->
// device data -> graph class -> node name:
//
//   application.icon_name  the application chose this for itself
//   device.icon_name       the driver chose this for the device
//   media.class            the graph's own answer, and the only one that is
//                          correct for a node with no application behind it
//   node.name              last, because it is the least descriptive of the
//                          four and is sometimes a filter's own name
//
// The result is a NAME, not a path: the caller resolves it through the shell
// icon set and then through Quickshell.iconPath's explicit fallback, so a
// miss degrades to the generic audio glyph rather than to a broken image.
function iconName(node) {
  if (node === null || node === undefined) return ""
  const candidates = [
    propText(node, "application.icon_name"),
    propText(node, "application.icon-name"),
    propText(node, "device.icon_name"),
    propText(node, "device.icon-name")
  ]
  for (let i = 0; i < candidates.length; i++) {
    if (candidates[i] !== "") return candidates[i]
  }
  const cls = propText(node, "media.class")
  if (cls !== "") {
    const byClass = iconForMediaClass(cls)
    if (byClass !== "") return byClass
  }
  if (propText(node, "device.class") !== "" && text(node.description) === "") {
    // A device with no media class and nothing but a driver description: the
    // generic device glyph reads better than an absent one.
    return "headphones"
  }
  const own = text(node.name)
  if (own === "" || isMonitorName(own)) return ""
  // Strip the direction suffix and keep the leading segment, which is the
  // application's own token: "firefox.monitor" -> "firefox",
  // "Chromium Web Content" -> "chromium".
  const head = own.split(".")[0].trim().toLowerCase()
  return head === "" ? "" : head
}

// The graph's own class names mapped onto the shipped icon set,
// canonicalized in common/theme/DeviceIcons.js. A class nobody matches
// returns "", so the caller falls through to the node's own name rather
// than to a wrong glyph.
function iconForMediaClass(cls) {
  return DeviceIcons.iconForMediaClass(cls)
}

// The icon name an APPLICATION chose for its own stream, canonicalized
// in common/theme/DeviceIcons.js so a stream looks the same in the
// island and in the mixer. Deliberately no `node.name` fallback (see
// DeviceIcons); "" is the honest answer here, and iconName() turns it
// into the generic glyph.
function appIconName(node) {
  if (node === null || node === undefined) return ""
  return DeviceIcons.appIconNameFromProps(function(key) { return propText(node, key) })
}

// --- levels ------------------------------------------------------------

// A row's readout. A muted row prints "Muted" and no percentage, because a
// percentage beside a mute would be rating a level that is not being heard.
function volumeText(volume, muted) {
  if (muted === true) return "Muted"
  return percentText(volume)
}

// The percentage half of volumeText, shared so the digits a row prints and
// the digits a caller parses cannot disagree.
function percentText(volume) {
  const v = Number(volume)
  if (typeof volume !== "number" && typeof volume !== "string") return ""
  if (!isFinite(v)) return ""
  return String(Math.round(v * 100)) + "%"
}

// "42%" / "42" -> 42; anything else -> null. The inverse of percentText, for
// the one place a level is read back out of text rather than off the node.
// --- link projection ---------------------------------------------------

// One link endpoint pair, or "" when either end is unusable. A link group's
// endpoints are node objects, so the pair is stored as the objects
// themselves: a consumer that wants a level reads it off the endpoint
// directly and never has to look the node up again.
function linkPair(source, target) {
  if (source === null || source === undefined) return null
  if (target === null || target === undefined) return null
  return { source: source, target: target }
}

// The streams attached to one device, read from an AudioNodes handle's
// `links`, as the stream NODES rather than as their ids: a device row draws
// each of them as a full row, and a row needs the node to read a level off.
// `deviceKey` is the decimal node id from nodeKey().
//
// A link is directional, and a device is at the receiving end of it either
// way (a stream's audio travels INTO a sink, a microphone's INTO a source),
// so both ends are checked rather than assuming an orientation. Only the far
// end that is itself a stream is returned: a device-to-device pair is
// topology, not a mixer row.
function attachedStreams(links, deviceKey) {
  const key = typeof deviceKey === "string" ? deviceKey : ""
  if (key === "" || !Array.isArray(links) || links.length === 0) return []
  const out = []
  for (let i = 0; i < links.length; i++) {
    const peer = peerStreamNode(links[i], key)
    if (peer === null) continue
    const peerKey = nodeKey(peer)
    let seen = false
    for (let j = 0; j < out.length; j++) {
      if (nodeKey(out[j]) === peerKey) {
        seen = true
        break
      }
    }
    if (!seen) out.push(peer)
  }
  return out
}

// The far end of one link, when this device is one of its ends and the other
// is a stream. null for every other case.
function peerStreamNode(link, deviceKey) {
  if (link === null || link === undefined) return null
  const source = link.source
  const target = link.target
  if (nodeKey(source) === deviceKey) return streamNode(target)
  if (nodeKey(target) === deviceKey) return streamNode(source)
  return null
}

function streamNode(node) {
  if (node === null || node === undefined) return null
  let stream = null
  try {
    stream = node.isStream
  } catch (ignored) {
    return null
  }
  return stream === true ? node : null
}

// One `source -> target` pair's identity, by node id rather than by object
// identity: the graph republishes its link list, so the same pair can arrive
// behind a fresh wrapper, and two reports of one pair have to compare equal.
function pairKey(pair) {
  if (pair === null || pair === undefined) return ""
  return nodeKey(pair.source) + ":" + nodeKey(pair.target)
}

// Element-wise equality over a pair list, as a SET rather than in order: the
// graph does not promise an order for its links, so two reports carrying the
// same attachments in a different order are the same topology and must not
// count as a change.
function samePairs(a, b) {
  if (a === b) return true
  if (!Array.isArray(a) || !Array.isArray(b)) return false
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) {
    const key = pairKey(a[i])
    let found = false
    for (let j = 0; j < b.length; j++) {
      if (pairKey(b[j]) === key) {
        found = true
        break
      }
    }
    if (!found) return false
  }
  return true
}

// The graph's own link list, projected onto one entry per device: the
// `{ source, target }` pairs that touch that device, under `{ links: [...] }`,
// keyed by device node id - the shape `attachedStreams` and `streamTargets`
// already read, so a device row and a stream row are answered off one
// projection.
//
// Read off the whole-graph list rather than off one link tracker per device,
// and the reason is structural rather than a preference. A per-device tracker
// is a subscription on process-global state: one per device is N subscriptions
// to answer a question the graph has already answered once. `PwLink.source` and
// `.target` are documented as readable without binding - only `PwLink.state`
// needs a tracker, and nothing here reads it - so the whole-graph list is right
// on the first read, with no tracker to create, no window before the first
// notification lands, and nothing to release when a device leaves.
//
// (This was also, for a while, the only way to get a correct answer at all:
// `AudioNodes` seeded a new tracker's entry with an empty topology, because the
// tracker's first `linkGroupsChanged` fires before the entry that will hold it
// is registered. That is fixed in `common/audio/AudioNodes.qml`. The decision
// here stands without it.)
//
// `links` is the service's list, which QML exposes as an indexable sequence
// rather than as a JS array, so its length is read and its elements walked
// rather than `Array.isArray` being demanded of it.
function deviceLinks(links, devices, current) {
  const out = ({})
  if (devices === null || devices === undefined || !Array.isArray(devices)) return out
  const held = current === null || current === undefined ? ({}) : current
  let keys = 0
  let changed = false
  for (let i = 0; i < devices.length; i++) {
    const key = nodeKey(devices[i])
    if (key === "") continue
    keys++
    const pairs = deviceLinkPairs(links, key)
    const entry = held[key]
    if (entry !== undefined && entry !== null && samePairs(entry.links, pairs)) {
      out[key] = entry
      continue
    }
    out[key] = { links: pairs }
    changed = true
  }
  if (changed) return out
  let heldKeys = 0
  for (const key in held) heldKeys++
  return heldKeys === keys ? held : out
}

// The pairs one device is an end of. PipeWire carries a separate link per port
// pair, so two audio ports between the same two nodes are two links and one
// attachment: deduplicating to one pair per `source -> target` is what a
// node's own link tracker reports, and what keeps a two-channel stream from
// being drawn twice.
function deviceLinkPairs(links, deviceKey) {
  const out = []
  if (deviceKey === "" || links === null || links === undefined) return out
  const raw = links.length
  const n = typeof raw === "number" && raw >= 0 ? Math.round(raw) : 0
  const seen = ({})
  for (let i = 0; i < n; i++) {
    const link = links[i]
    if (link === null || link === undefined) continue
    const source = link.source
    const target = link.target
    if (source === undefined || target === undefined) continue
    if (source === null || target === null) continue
    const sourceKey = nodeKey(source)
    const targetKey = nodeKey(target)
    if (sourceKey !== deviceKey && targetKey !== deviceKey) continue
    const key = sourceKey + ":" + targetKey
    if (seen[key] === true) continue
    seen[key] = true
    const pair = linkPair(source, target)
    if (pair !== null) out.push(pair)
  }
  return out
}

// stream node id -> device node id, from the projected device link map. A
// stream's current target is read from the graph's own link topology rather
// than from a second `pactl list`: the topology is already projected above,
// and a stream that is not linked anywhere (a filter leg, a stream the user
// has just moved) is simply absent, which is what "no target" looks like.
//
// Two readings of one stream are one answer: the map is walked per device, so
// a stream linked to two devices would be claimed by whichever came second.
// That does not happen on a graph where each stream has one target, and the
// alternative - a list per stream - is a second structure for a case the
// daemon does not produce.
function streamTargets(devices) {
  const out = ({})
  if (devices === null || devices === undefined || typeof devices !== "object") return out
  for (const deviceKey in devices) {
    const entry = devices[deviceKey]
    if (entry === null || entry === undefined) continue
    const streams = attachedStreams(entry.links, deviceKey)
    for (let i = 0; i < streams.length; i++) {
      const key = nodeKey(streams[i])
      if (key !== "") out[key] = deviceKey
    }
  }
  return out
}

// Whether a node's own audio channel map is fully known.
//
// Quickshell's peak monitor matches its capture stream's channels against the
// node's and refuses - through `qCCritical(logPeak)`, once per process
// callback - when they do not line up. A node whose channels are still
// `PwAudioChannel.Unknown` is exactly that case, so binding a monitor to it
// buys a permanent stream of backend errors and no peak.
//
// The test is against the value 0 rather than against the enum's name because a
// `.pragma library` has no Qt imports and cannot name `PwAudioChannel`; 0 is
// that enum's first value and the only one the API lists before the real
// channels, and a channel the shell cannot name is not one it should trust.
function channelsKnown(channels) {
  if (channels === null || channels === undefined) return false
  const n = channels.length
  if (typeof n !== "number" || n <= 0) return false
  for (let i = 0; i < n; i++) {
    if (Number(channels[i]) === 0) return false
  }
  return true
}

// --- the pulse map -----------------------------------------------------

// `pactl list` block header: "Sink #67", "Sink Input #68", "Module #1". The
// kind is upper-initial and may carry a space ("Sink Input", "Source Output",
// "Sink Input"), the index is decimal, and nothing else is on the line.
var HEADER_RE = /^([A-Z][A-Za-z ]*?) #([0-9]+)$/

// Which of the five maps a block kind feeds. "" for every kind the mixer
// does not read (Module, Client, Card): those blocks are still walked to the
// next header, because the walk is what keeps one block's fields out of the
// next block's record.
function bucketFor(kind) {
  const k = String(kind)
  if (k === "Sink") return "sinks"
  if (k === "Source") return "sources"
  if (k === "Sink Input") return "sinkInputs"
  if (k === "Source Output") return "sourceOutputs"
  return ""
}

// The five maps, keyed by PipeWire node id, valued by the Pulse index.
function emptyPulseObjects() {
  return {
    sinks: ({}),
    sources: ({}),
    monitors: ({}),
    sinkInputs: ({}),
    sourceOutputs: ({})
  }
}

// `pactl list` -> { sinks, sources, monitors, sinkInputs, sourceOutputs },
// each keyed by the object's `object.id` (the PipeWire node id) and valued
// with the Pulse index from its own header.
//
// Monitors are separated from sources because a monitor shares `object.id`
// with the sink it watches: `Source #1967` and `Sink #1967` are both
// `object.id = "95"`. There is no id left to tell them apart, so the split is
// made on the `.monitor` suffix the graph puts on the monitor's node name -
// which is exactly why monitors are not simply another key of the same map.
//
// Robust by construction: a missing block, a CRLF line ending, a blank line
// and an unrecognised block kind all leave the maps empty rather than
// throwing, because this parses text a daemon produced inside a QML handler.
function parsePulseObjects(input) {
  const out = emptyPulseObjects()
  if (typeof input !== "string" || input === "") return out

  const lines = input.split("\n")
  // One block's record, rebuilt at every header. A block's object.id only
  // arrives in its property tail, so the record is committed at the NEXT
  // header rather than at its own.
  let bucket = ""
  let pulseIndex = -1
  let nodeId = ""
  let headerName = ""
  let propName = ""
  let inProps = false

  function commit() {
    if (bucket !== "" && nodeId !== "" && pulseIndex >= 0) {
      // The `.monitor` suffix on the node name is what separates a monitor
      // from the sink whose object.id it shares, so the name has to come
      // from whichever of the two places this block printed it.
      const name = headerName !== "" ? headerName : propName
      const key = (bucket === "sources" && isMonitorName(name)) ? "monitors" : bucket
      out[key][nodeId] = pulseIndex
    }
    bucket = ""
    pulseIndex = -1
    nodeId = ""
    headerName = ""
    propName = ""
    inProps = false
  }

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/\r$/, "")
    const header = HEADER_RE.exec(line)
    if (header !== null) {
      commit()
      bucket = bucketFor(header[1])
      pulseIndex = parseInt(header[2], 10)
      continue
    }
    // Fields are tab-indented. A continuation line (`Volume:`'s own
    // `balance 0.00` tail) is indented deeper and is not a field.
    if (line.charAt(0) !== "\t") continue
    const body = line.replace(/^\t+/, "")
    if (inProps) {
      // Property entries are `key = "value"` and carry no colon, which is
      // what keeps them out of the field branch below. Only two of them are
      // read: the node name the monitor split needs, and the object id the
      // whole map is keyed by.
      const eq = body.indexOf("=")
      if (eq > 0) {
        const key = body.substring(0, eq).trim()
        const value = unquote(body.substring(eq + 1).trim())
        if (key === "object.id") nodeId = value
        else if (key === "node.name") propName = value
      }
      continue
    }
    if (body === "Properties:") {
      inProps = true
      continue
    }
    const colon = body.indexOf(":")
    if (colon < 0) continue
    // The fields that are NOT properties: a Sink Input has no `Name:` line at
    // all, which is why the property copy of `node.name` exists.
    const field = body.substring(0, colon).trim()
    const value = body.substring(colon + 1).trim()
    if (field === "Name") headerName = value
    else if (field === "object.id") nodeId = unquote(value)
  }
  commit()
  return out
}

function unquote(value) {
  if (value.length < 2) return value
  if (value.charAt(0) !== '"' || value.charAt(value.length - 1) !== '"') return value
  return value.substring(1, value.length - 1)
}

// The Pulse index for one node, or -1 when the map has no entry for it.
// -1 rather than null so the answer composes with the argv builder below
// without a second type check at every call site.
function pulseIndex(map, key) {
  if (map === null || map === undefined || typeof map !== "object") return -1
  const k = typeof key === "string" ? key : ""
  if (k === "") return -1
  const v = map[k]
  if (typeof v !== "number" || !isFinite(v)) return -1
  return v
}

// The one argv this app builds by hand, as a list.
//
// Both numbers are Pulse INDICES, not PipeWire ids: `pactl` numbers its own
// objects independently of the graph's, and the routing map is the only
// translation between the two. There is no shell form anywhere on this path,
// because a node name is client-supplied text and a shell string is where
// client-supplied text goes to be interpreted.
function moveArgv(capture, streamIndex, deviceIndex) {
  if (typeof streamIndex !== "number" || !isFinite(streamIndex)) return []
  if (typeof deviceIndex !== "number" || !isFinite(deviceIndex)) return []
  if (streamIndex < 0 || deviceIndex < 0) return []
  const verb = capture === true ? "move-source-output" : "move-sink-input"
  return ["pactl", verb, String(Math.round(streamIndex)), String(Math.round(deviceIndex))]
}

// --- the stream routes --------------------------------------------------
//
// `pactl list` names the device a stream plays into on the STREAM's own block: a
// Sink Input carries `Sink: <pulse sink index>` and a Source Output carries
// `Source: <pulse source index>`. That is a Pulse index like the header's, so it
// names nothing the shell holds until a device map turns it back into a
// PipeWire node id - the same `object.id` join parsePulseObjects() already
// makes, and for the same reason it is the only reliable one.
//
// A second walk of the same capture rather than a sixth map on the first one:
// the five maps are keyed by DEVICE ids and are keyed that way because
// everything else reads them that way, while this one is keyed by STREAM ids and
// valued with a device's index. One walk cannot hold both without changing the
// shape every other reader of that result depends on.

// Which field of each stream block names its device. Absent for every other
// bucket, which is why the walk below never asks this map about a block kind it
// does not keep.
var ROUTE_FIELD = ({ sinkInputs: "Sink", sourceOutputs: "Source" })

// The pair of maps keyed by STREAM node id and valued with a DEVICE's Pulse
// index. The same shape as emptyPulseObjects() and the opposite key, because the
// two answer opposite halves of one question.
function emptyStreamRoutes() {
  return {
    sinkInputs: ({}),
    sourceOutputs: ({})
  }
}

// `pactl list` -> { sinkInputs, sourceOutputs }, each keyed by the STREAM's
// `object.id` and valued with the DEVICE's Pulse index.
//
// The walk is parsePulseObjects()'s with two differences: only the two stream
// buckets survive, and the index recorded is the block's own `Sink:`/`Source:`
// field rather than its header. A field that is not decimal commits nothing, so
// a daemon that prints something else for it leaves that stream unrouted rather
// than routing it onto an index that means nothing.
function parseStreamRoutes(input) {
  const out = emptyStreamRoutes()
  if (typeof input !== "string" || input === "") return out

  const lines = input.split("\n")
  let bucket = ""
  let deviceIndex = -1
  let nodeId = ""
  let inProps = false

  function commit() {
    if (bucket !== "" && nodeId !== "" && deviceIndex >= 0) out[bucket][nodeId] = deviceIndex
    bucket = ""
    deviceIndex = -1
    nodeId = ""
    inProps = false
  }

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/\r$/, "")
    const header = HEADER_RE.exec(line)
    if (header !== null) {
      commit()
      const kind = bucketFor(header[1])
      bucket = kind === "sinkInputs" || kind === "sourceOutputs" ? kind : ""
      continue
    }
    if (bucket === "") continue
    // Fields are tab-indented, and a continuation line is indented deeper, so a
    // line that does not start with a tab is a block separator rather than
    // anything this walk reads.
    if (line.charAt(0) !== "\t") continue
    const body = line.replace(/^\t+/, "")
    if (inProps) {
      const eq = body.indexOf("=")
      if (eq > 0 && body.substring(0, eq).trim() === "object.id") {
        nodeId = unquote(body.substring(eq + 1).trim())
      }
      continue
    }
    if (body === "Properties:") {
      inProps = true
      continue
    }
    const colon = body.indexOf(":")
    if (colon < 0) continue
    // The field name is matched against the bucket's own word, so a sink's
    // `Sink Source:` line - a different field on a block this walk discards
    // anyway - cannot be read as a sink input's route, and a source output
    // carrying a sink field cannot borrow one.
    if (body.substring(0, colon).trim() !== ROUTE_FIELD[bucket]) continue
    const raw = body.substring(colon + 1).trim()
    if (!/^\d+$/.test(raw)) continue
    deviceIndex = parseInt(raw, 10)
  }
  commit()
  return out
}

// stream node id -> device node id, from the routing map alone: the stream's own
// route index becomes a node id by finding the device entry valued with that
// index. This is the source that answers "which device is this stream on"
// without waiting, because it is data the controller already published - a link
// tracker answers only after the daemon has sent it something, and on a fresh
// open that is a beat after the first frame.
//
// A stream the map resolved and named no device for is absent rather than
// wrong, which is the same absence the link topology reports for a filter leg.
function pulseStreamTargets(routes, pulse) {
  const out = ({})
  if (routes === null || routes === undefined || typeof routes !== "object") return out
  if (pulse === null || pulse === undefined || typeof pulse !== "object") return out
  joinRouteMap(out, routes.sinkInputs, pulse.sinks)
  // `sources` and not `monitors`: a monitor shares its sink's `object.id`, so a
  // route onto a monitor would resolve to the sink node instead and name a
  // device the user is not recording into.
  joinRouteMap(out, routes.sourceOutputs, pulse.sources)
  return out
}

// One half of the join: routes keyed by stream id, devices keyed by node id and
// valued with the same kind of index. The device side is walked rather than
// indexed, because it is a handful of entries and the walk keeps this a function
// of two plain maps - there is no reverse index to build here and keep in step
// with the forward one on the next capture.
function joinRouteMap(out, routes, devices) {
  if (routes === null || routes === undefined || typeof routes !== "object") return
  if (devices === null || devices === undefined || typeof devices !== "object") return
  for (const streamKey in routes) {
    const index = routes[streamKey]
    if (typeof index !== "number" || !isFinite(index)) continue
    for (const nodeId in devices) {
      if (devices[nodeId] !== index) continue
      out[streamKey] = nodeId
      break
    }
  }
}

// One map out of two sources of the same fact, the first winning wherever it
// has an answer. The routing map is the resolved one; the link topology covers
// what it does not carry, which is a stream the daemon holds no Pulse object for
// at all - a filter leg, or a node registered only to PipeWire.
function mergeTargets(primary, fallback) {
  const out = ({})
  copyTargets(out, fallback)
  copyTargets(out, primary)
  return out
}

// One map over the other, entry by entry. Applied second so the first source
// wins where both have an answer; a value that is not a node id is dropped rather
// than stored, because an entry a caller cannot look a node up by is a row that
// would print no target and give no reason for it.
function copyTargets(out, source) {
  if (source === null || source === undefined || typeof source !== "object") return
  for (const key in source) {
    const value = source[key]
    if (typeof value === "string" && value !== "") out[key] = value
  }
}

// Whether the routing map has been asked about and its answer is in, which is
// what a caller needs before an absent target may be called a fact.
//
// The controller stamps the capture it accepted and carries the reason a read
// failed. Both are read, because the map's own shape cannot answer this: an
// unresolved map and a daemon that answered with nothing are the same five empty
// buckets, so a caller that looked at the buckets would call the second one a
// first and leave a row claiming it was still waiting.
//
// A failed read counts as answered. No map is coming, so a row that kept saying
// it was reading would be describing work in flight that stopped, and the
// controller's routing error is where that failure says itself.
//
// Guarded because this runs inside a binding, where a read of a controller on
// its way out has to answer the question rather than fault it.
function routingSettled(controller) {
  if (controller === null || controller === undefined) return false
  try {
    if (controller.routingReady === true) return true
    return text(controller.routingError) !== ""
  } catch (ignored) {
    return false
  }
}

// --- channels ----------------------------------------------------------
//
// The PwAudioChannel enum, in order, read out of
// /usr/lib/qt6/qml/Quickshell/Services/Pipewire/quickshell-service-pipewire.qmltypes.
// A `.pragma library` has no Qt imports and cannot name PwAudioChannel - the
// same reason channelsKnown() tests the value 0 rather than the enum's name -
// so the vocabulary is spelled out here and read by index. An index outside it
// is a channel this build does not describe, and names "".
var CHANNEL_NAMES = [
  "Unknown", "NA", "Mono", "FrontCenter", "FrontLeft", "FrontRight",
  "FrontLeftCenter", "FrontRightCenter", "FrontLeftWide", "FrontRightWide",
  "FrontCenterHigh", "FrontLeftHigh", "FrontRightHigh", "LowFrequencyEffects",
  "LowFrequencyEffects2", "LowFrequencyEffectsLeft", "LowFrequencyEffectsRight",
  "SideLeft", "SideRight", "RearCenter", "RearLeft", "RearRight",
  "RearLeftCenter", "RearRightCenter", "TopCenter", "TopFrontCenter",
  "TopFrontLeft", "TopFrontRight", "TopFrontLeftCenter", "TopFrontRightCenter",
  "TopSideLeft", "TopSideRight", "TopRearCenter", "TopRearLeft", "TopRearRight",
  "TopRearLeftCenter", "TopRearRightCenter", "BottomCenter", "BottomLeftCenter",
  "BottomRightCenter", "AuxRangeStart", "AuxRangeEnd", "CustomRangeStart"
]

// One channel enum value as the API's own name, or "" for a value this build
// does not describe. `Unknown` (0) is spelled out rather than hidden: a caller
// asking what a channel is deserves the honest answer, and `known` is where
// the "do not trust this yet" verdict lives.
function channelName(value) {
  if (typeof value !== "number" || !isFinite(value)) return ""
  const i = Math.round(value)
  if (i < 0 || i >= CHANNEL_NAMES.length) return ""
  return CHANNEL_NAMES[i]
}

// A channel's own name as text a row can print: "FrontLeft" reads as
// "Front Left", and the four LFE spellings all read as "LFE", which is what
// every mixer on this machine calls them. An unexpected value prints as
// itself rather than as a mangle of it.
function channelLabel(name) {
  const raw = text(name)
  if (raw === "") return ""
  if (raw === "LowFrequencyEffects" || raw === "LowFrequencyEffects2"
    || raw === "LowFrequencyEffectsLeft" || raw === "LowFrequencyEffectsRight") {
    return "LFE"
  }
  const spaced = raw.replace(/([a-z0-9])([A-Z])/g, "$1 $2").trim()
  return spaced === "" ? raw : spaced
}

// --- the card map ------------------------------------------------------

// The `pactl list cards` block header, "Card #44".
var CARD_HEADER_RE = /^Card #([0-9]+)$/

// One profile line, indented under `Profiles:`:
//
//   off: Off (sinks: 0, sources: 0, priority: 0, available: yes)
//   output:analog-stereo+input:analog-stereo: Analog Stereo Duplex (sinks: 1,
//     sources: 1, priority: 6565, available: yes)
//
// A profile NAME carries its own colons - `output:` and `input:` are part of
// the name - so the name is the token up to the first whitespace rather than
// up to the first colon: no profile name this daemon prints contains a space,
// and a description is free to contain both colons and spaces. The statistics
// then come off the tail, which is the only fixed part of the line, and the
// same tail test is what rejects a port line ("type: Mic, priority: ...")
// that happens to sit at the same indent.
var PROFILE_RE = /^([^\s]+): (.*)$/
var PROFILE_STATS_RE = /\(sinks:\s*(\d+),\s*sources:\s*(\d+)[^)]*\)\s*$/
var PROFILE_AVAIL_RE = /available:\s*([A-Za-z]+)/

// The profile every card carries at index 0, with 0 sinks and 0 sources. It is
// not a mode: it is how a device is DISABLED, which the daemon's own
// description does not say - it prints the single word "Off" - and which is
// what a user reaching for a way to turn a device off is looking for.
var OFF_PROFILE = "off"
var OFF_DESCRIPTION = "Off (disables the device)"

// Key prefixes. The form is what makes a key safe to index by: "analog-stereo"
// is an input profile on one card and an output profile on another, while
// "card:46" names one card and nothing else.
var CARD_KEY_PREFIX = "card:"
var ALSA_KEY_PREFIX = "alsa:"
var PROFILE_KEY_PREFIX = "profile:"
var DEVICE_KEY_PREFIX = "device:"

// A key of the form "<form>:<value>", or "" when the value names nothing.
// Numeric forms are refused unless they are decimal, because a key of
// "card:unknown" would resolve the way a real one does.
function cardKey(prefix, value) {
  const v = text(value)
  if (v === "") return ""
  if (prefix !== PROFILE_KEY_PREFIX && !/^\d+$/.test(v)) return ""
  return prefix + v
}

// The underlying profile names a card profile is built from, as one string:
// `output:analog-stereo` is "analog-stereo", and
// `output:analog-stereo+input:analog-stereo` is "analog-stereo" too because
// the two halves are the same profile. A node's `device.profile.name` is the
// ALSA profile, which is this string on the card side - that is how a node
// finds the card whose profile list is its own.
function baseProfileName(name) {
  const raw = text(name)
  if (raw === "") return ""
  const parts = raw.split("+")
  const out = []
  for (let i = 0; i < parts.length; i++) {
    let part = parts[i].trim()
    if (part.indexOf("output:") === 0) part = part.slice(7)
    else if (part.indexOf("input:") === 0) part = part.slice(6)
    if (part === "" || out.indexOf(part) >= 0) continue
    out.push(part)
  }
  if (out.length === 1) return out[0]
  return out.length === 0 ? "" : out.join("+")
}

// The key that maps a node to its card, or "" when nothing on the node
// identifies one.
//
// This is the join that keeps a profile write from landing on the wrong card.
// `wpctl set-profile` reads the index against the NODE's own card, so a key
// that named a different card would answer with a profile list whose index
// means something else, and the user would set a profile they did not choose.
//
// Measured on this machine's graph, a device node carries:
//
//   device.id             the card's Pulse `object.id`, which is the same join
//                         key parsePulseObjects() uses and the only property
//                         on a node that IS a card identity
//   alsa.card              the ALSA card index, which the card block publishes
//                         as `alsa.card`
//   device.profile.name    the ALSA profile - NOT a card identity: the same
//                         profile name is on more than one card here
//   card.profile.device    the ALSA device number within the card. No card
//                         block publishes a matching key, so this resolves to
//                         nothing rather than to the wrong card; it is last
//                         for that reason.
//
// Index order is never used: `pactl` numbers its own objects independently of
// the graph's, so node N is not card N.
function nodeCardKey(node) {
  if (node === null || node === undefined) return ""
  const keys = [
    cardKey(CARD_KEY_PREFIX, propId(node, "device.id")),
    cardKey(ALSA_KEY_PREFIX, propId(node, "alsa.card")),
    cardKey(PROFILE_KEY_PREFIX, propText(node, "device.profile.name")),
    cardKey(DEVICE_KEY_PREFIX, propId(node, "card.profile.device"))
  ]
  for (let i = 0; i < keys.length; i++) {
    if (keys[i] !== "") return keys[i]
  }
  return ""
}

// One `Profiles:` line, or null for anything that is not one.
function parseProfileLine(body) {
  const head = PROFILE_RE.exec(body)
  if (head === null) return null
  const stats = PROFILE_STATS_RE.exec(head[2])
  if (stats === null) return null
  const name = head[1]
  const avail = PROFILE_AVAIL_RE.exec(head[2])
  const available = avail !== null && avail[1] === "yes"
  const sinks = parseInt(stats[1], 10)
  const sources = parseInt(stats[2], 10)
  let description = head[2].replace(PROFILE_STATS_RE, "").trim()
  // The disable profile says so. The daemon's own word for it is "Off", which
  // is not what a user reaching for a way to turn a device off is looking at,
  // and it is the one profile whose effect is invisible rather than audible.
  // Only the bare word is replaced: a daemon that described it further has
  // said more than this does, and that text is kept.
  if (name === OFF_PROFILE && sinks === 0 && sources === 0
    && description.toLowerCase() === OFF_PROFILE) {
    description = OFF_DESCRIPTION
  }
  return {
    index: 0,
    name: name,
    description: description,
    available: available,
    sinks: sinks,
    sources: sources
  }
}

// The answer `deviceProfiles()` gives when it has none: the same four keys, so
// a caller reads `readable` and never has to test for an absent object.
function noCardProfiles(error) {
  return { current: "", profiles: [], readable: false, error: String(error || "unknown") }
}

function emptyCardProfiles() {
  return { cards: [], byKey: ({}), ambiguous: ({}) }
}

// Index every card under the keys a node can answer with. A key owned by more
// than one card indexes NOTHING and is recorded as ambiguous: "analog-stereo"
// is an input profile on one card and an output profile on another here, and a
// key that resolved to either of them would hand the caller the wrong profile
// list and therefore the wrong index.
function indexCards(out) {
  const owners = ({})
  const claim = (key, card) => {
    if (key === "") return
    const list = owners[key]
    if (list === undefined) owners[key] = [card]
    else if (list.indexOf(card) < 0) list.push(card)
  }
  for (let i = 0; i < out.cards.length; i++) {
    const card = out.cards[i]
    const byId = cardKey(CARD_KEY_PREFIX, card.objectId)
    const byAlsa = cardKey(ALSA_KEY_PREFIX, card.alsa)
    card.key = byId !== "" ? byId : byAlsa
    claim(byId, card)
    claim(byAlsa, card)
    for (let j = 0; j < card.profiles.length; j++) {
      const base = baseProfileName(card.profiles[j].name)
      if (base !== "") claim(PROFILE_KEY_PREFIX + base, card)
    }
  }
  for (const key in owners) {
    const list = owners[key]
    if (list.length === 1) out.byKey[key] = list[0]
    else out.ambiguous[key] = true
  }
}

// `pactl list cards` -> { cards, byKey, ambiguous }.
//
// Each card is `{ index, name, driver, description, active, profiles, key }`,
// where `index` is the Pulse card number, `active` is the card's
// `Active Profile:` and each profile is `{ index, name, description,
// available, sinks, sources }` with `index` being the card-relative ordinal
// `wpctl set-profile` takes. `byKey` is the index nodeCardKey() resolves
// against; `ambiguous` names the keys more than one card owns, which resolve
// to nothing.
//
// Robust the same way parsePulseObjects() is: a missing card, a truncated
// capture, a CRLF line ending and a profile line cut mid-statistics all
// leave what was readable rather than throwing, because this parses text a
// daemon produced inside a QML handler.
function parseCardProfiles(input) {
  const out = emptyCardProfiles()
  if (typeof input !== "string" || input === "") return out

  const lines = input.split("\n")
  let card = null
  let inProps = false
  let inProfiles = false

  function commit() {
    if (card !== null) out.cards.push(card)
    card = null
    inProps = false
    inProfiles = false
  }

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/\r$/, "")
    const header = CARD_HEADER_RE.exec(line)
    if (header !== null) {
      commit()
      card = {
        index: parseInt(header[1], 10),
        name: "",
        driver: "",
        description: "",
        active: "",
        objectId: "",
        alsa: "",
        key: "",
        profiles: []
      }
      continue
    }
    if (card === null) continue
    const indent = line.length - line.replace(/^\t+/, "").length
    const body = line.replace(/^\t+/, "")
    // Indent first, state second, and the order is the whole parse: a card's
    // own fields are at one tab and its nested blocks at two, and
    // `Active Profile:` - the line that CLOSES the profile block - is itself a
    // one-tab field. A state flag consulted before the indent would swallow
    // the line that ends the block it guards, and the card's active profile
    // with it.
    if (indent === 1) {
      if (body === "Properties:") {
        inProps = true
        continue
      }
      if (body === "Profiles:") {
        inProfiles = true
        // The property block is closed rather than left open: it comes first
        // in a card, and a property entry sits at the indent a profile line
        // does.
        inProps = false
        continue
      }
      const colon = body.indexOf(":")
      if (colon < 0) continue
      const field = body.substring(0, colon).trim()
      const value = body.substring(colon + 1).trim()
      if (field === "Name") card.name = value
      else if (field === "Driver") card.driver = value
      else if (field === "Active Profile") {
        card.active = value
        inProfiles = false
        inProps = false
      }
      continue
    }
    if (inProfiles) {
      // Indent and state, not the regex alone: a port line sits at the same
      // indent as a profile line and is separated by the statistics test, and
      // a nested `Properties:` under a port must not be read into the card.
      if (indent === 2) {
        const profile = parseProfileLine(body)
        if (profile !== null) {
          profile.index = card.profiles.length
          card.profiles.push(profile)
        }
      }
      continue
    }
    if (inProps && indent >= 2) {
      const eq = body.indexOf("=")
      if (eq > 0) {
        const key = body.substring(0, eq).trim()
        const value = unquote(body.substring(eq + 1).trim())
        if (key === "object.id") card.objectId = value
        else if (key === "alsa.card") card.alsa = value
        else if (key === "device.description") card.description = value
        else if (key === "device.nick") {
          if (card.description === "") card.description = value
        }
      }
    }
  }
  commit()
  indexCards(out)
  return out
}

// The one argv this app builds for a profile write, as a list. `wpctl` takes a
// PipeWire NODE id and the index within that node's card - no shell form on
// this path, because a node id and an index both arrive from a UI row and a
// shell string is where caller-supplied text goes to be interpreted.
//
// Index 0 is a legal answer and is the profile that disables the device.
function setProfileArgv(nodeId, index) {
  const k = text(nodeId)
  if (!/^\d+$/.test(k)) return []
  if (typeof index !== "number" || !isFinite(index)) return []
  if (index < 0 || Math.round(index) !== index) return []
  return ["wpctl", "set-profile", k, String(Math.round(index))]
}

// --- the profile picker's three states ---
//
// The two reasons `deviceProfiles()` answers `readable: false` are different
// facts about different things, and a control that cannot act has to name which
// one it is:
//
//   PROFILE_NO_CARD  the node names no card, so the daemon has no profile list
//                    to publish. A node the graph created itself - an
//                    equalizer tap, a loopback, a virtual sink - is exactly
//                    this, and on a graph full of filters it is ordinary.
//   PROFILE_UNREAD   the card read has not landed yet.
//
// Anything else in `error` came out of a read that DID finish and did not
// answer, which is a third state again and a fault rather than a fact about
// the graph. The strings live here rather than at their call sites so the
// classification below cannot drift from the answers it reads.
var PROFILE_NO_CARD = "no card on this device"
var PROFILE_UNREAD = "not read yet"

// A node the graph created rather than one on hardware, as `node.virtual`
// publishes it: the string "true" on a filter leg, an equalizer tap, a virtual
// sink. NOT `device.virtual`, which is ALSA's own virtual-device flag and reads
// on a card - asking for that one answers the same thing for every device on
// hardware, which would name every one of them broken.
function isVirtualNode(node) {
  const v = propText(node, "node.virtual").toLowerCase()
  return v === "true" || v === "1" || v === "yes"
}

// Which state a device's profile picker is in, as one word:
//
//   "ready"   a list to choose from
//   "no-card" the node names no card, so there are no profiles to pick
//   "unread"  the card read has not landed, or came back without an answer
//
// A null answer counts as "unread" rather than "ready": a row with no
// controller behind it has no list either, and reporting that as ready would
// draw an empty profile where a state belongs.
function profileReadState(profiles) {
  if (profiles !== null && profiles !== undefined && profiles.readable === true) {
    return "ready"
  }
  if (profiles === null || profiles === undefined) return "unread"
  return text(profiles.error) === PROFILE_NO_CARD ? "no-card" : "unread"
}

// --- the monitor ---------------------------------------------------------
//
// "Hear my voice": the input device's audio routed to the output so the user
// can hear the microphone. It is a graph link, not a route - `pactl` has no
// verb for it - and it is made of two halves this directory already knows how
// to name: the input device's CAPTURE ports (`device:capture_FL`, the only
// direction a source node carries) into the sink's PLAYBACK ports
// (`sink:playback_FL`, what plays into an output), paired by channel suffix
// through the one pairing rule in this directory. captureOutputs() below
// records why that is the only pairing of the two that this machine's graph
// can compose, and why the sink's `monitor_*` ports - the pair that reads
// correctly - are not what this links.
//
// What this section decides with no child in it: WHICH sink, WHICH ports, and
// what the removal writes. It is all pure so it can be driven against real
// node properties off a live graph.

// A PipeWire boolean property, as a boolean. The graph publishes these as the
// strings "true"/"false"; a synthetic node in a unit drive carries the boolean
// itself, and both have to answer the same question.
function trueProp(node, key) {
  const raw = props(node)[key]
  if (typeof raw === "boolean") return raw
  const value = propText(node, key)
  return value === "true" || value === "1" || value === "yes"
}

// The group value a filter chain publishes on its legs. Measured on this
// machine: both ends of the Parametric EQ chain carry
// `filter-chain-3015968-13` on `node.group` and `node.link-group`.
var FILTER_GROUP_PREFIX = "filter-chain-"

function filterGroup(name) {
  return text(name).slice(0, FILTER_GROUP_PREFIX.length) === FILTER_GROUP_PREFIX
}

// Is this node a virtual filter leg rather than a device? Three markers and any
// ONE of them is enough, because they are published independently:
//
//   node.virtual     "true" on both ends of the chain on this machine
//   node.group       the chain id, for the node grouping
//   node.link-group  the same value, for the link grouping
//
// A chain leg written by another tool may carry the group and not the flag, and
// a virtual sink with no group at all is still not hardware. `node.driver` is
// deliberately NOT one of these: it is the positive hardware marker below, and a
// marker that means both things at once would make the two questions
// inseparable.
function isVirtualFilterNode(node) {
  if (trueProp(node, "node.virtual")) return true
  return filterGroup(propText(node, "node.group"))
    || filterGroup(propText(node, "node.link-group"))
}

// Positive evidence of a driver-backed device, from the three properties the
// hardware nodes on this machine carry and a filter leg carries NONE of:
// `device.api` ("alsa"), `card.profile.device` ("5" on the ALSA sink) and
// `node.driver` ("true", which PipeWire sets on a node a driver owns). Absent
// all three and nothing is claimed either way, which is the middle score below
// rather than a verdict.
function isHardwareDevice(node) {
  if (propText(node, "device.api") !== "") return true
  if (propId(node, "card.profile.device") !== "") return true
  return trueProp(node, "node.driver")
}

// 2 hardware, 1 unknown, 0 virtual. A virtual marker outranks every other
// property on the node: a leg that says it is a filter is a filter whatever
// else it publishes.
function sinkScore(node) {
  if (isVirtualFilterNode(node)) return 0
  return isHardwareDevice(node) ? 2 : 1
}

// The sink a monitor should be pointed at, or null when the graph has none.
//
// The rule, and the reason for it: "hear my voice" means hearing it through the
// speakers, and a filter leg is not speakers. On this machine the DEFAULT sink
// is a filter - `eq_input`, `node.virtual = "true"` inside a `filter-chain-*`
// group - and listening to what that node plays is listening to the graph's
// post-EQ stream rather than to the microphone. So:
//
//   1. only output devices are candidates, by classify() and not by media class
//   2. a candidate carrying a virtual/filter marker scores 0 whatever else it
//      publishes
//   3. one with positive hardware evidence scores 2, one with neither marker 1
//   4. the highest score wins, and a TIE goes to the default sink - so a graph
//      whose hardware already is the default answers with the default
//   5. with no candidate at all, the default sink answers if it is itself an
//      output device, and null if it is not
//
// Degradation, stated because it is a choice: when EVERY output is virtual there
// is no hardware to prefer, so the graph's own default answers and the monitor
// still works. Refusing instead would leave a control that cannot act on a graph
// whose only sink is a perfectly working one, for a reason the user can do
// nothing about.
function resolveMonitorSink(defaultSink, devices) {
  const list = Array.isArray(devices) ? devices : []
  const defaultKey = nodeKey(defaultSink)
  let best = null
  let bestScore = -1
  let bestIsDefault = false
  for (let i = 0; i < list.length; i++) {
    const node = list[i]
    if (classify(node) !== "outputDevice") continue
    const key = nodeKey(node)
    const isDefault = defaultKey !== "" && key === defaultKey
    const score = sinkScore(node)
    if (score < bestScore) continue
    // A tie is settled towards the default and never away from it, so two
    // equally good candidates cannot make the answer depend on list order.
    if (score === bestScore && best !== null && bestIsDefault && !isDefault) continue
    best = node
    bestScore = score
    bestIsDefault = isDefault
  }
  if (best !== null) return best
  return classify(defaultSink) === "outputDevice" ? defaultSink : null
}

// One direction's port names for one node, as `{ node, port }` records, keeping
// only the ports under a prefix. Records rather than bare strings because a
// refusal has to name the whole `node:port` (Graph.refusalText does).
function prefixedRecords(portMap, name, prefix) {
  const out = []
  const key = text(name)
  if (key === "") return out
  if (portMap === null || portMap === undefined || typeof portMap !== "object") return out
  const held = portMap[key]
  if (!Array.isArray(held)) return out
  for (let i = 0; i < held.length; i++) {
    const port = text(held[i])
    if (port.length <= prefix.length) continue
    if (port.slice(0, prefix.length) !== prefix) continue
    out.push({ node: key, port: port })
  }
  return out
}

// The input device's PLAYBACK ports: the direction a source node takes audio IN
// on, as opposed to the `capture_*` ports it records from. Measured on this
// machine, the ALSA microphone carries no `playback_*` port at all, and
// `pw-cli info 53` reports `input ports: 0/0` - so on a capture device this
// answers [] and any plan built on it refuses before it writes anything.
//
// On a SINK it is one half of the monitor, because a sink does carry
// `playback_*`: what plays into it. The direction reversal below is the whole of
// why.
function playbackInputs(portMap, name) {
  return prefixedRecords(portMap, name, "playback_")
}

// The input device's CAPTURE ports, read off the OUTPUT map (`pw-link -o`) -
// and that map is where they belong, because they ARE the device's outputs. A
// source node in PipeWire is read-only: audio leaves it through `capture_*` and
// there is no port on it that takes audio in at all. So for a microphone this is
// the only pair of ports a monitor can be built from, and it is half of the
// route the controller writes:
//
//   pw-link <device:capture_FL> <sink:playback_FL>
//
// WHY THE MONITOR IS BUILT THIS WAY ROUND, because the other way round is the
// one a reader restores by reflex. The obvious reading of "hear my voice" is
// `pw-link <sink:monitor_FL> <device:playback_FL>` - the sink's monitor ports,
// which publish what it plays, into the device's playback ports. It is
// unbuildable on this machine, and not for a reason any fix could reach:
// `pw-link -i` prints three lines and none of them belongs to
// `alsa_input.usb-HP__Inc_HyperX_SoloCast_2_C1W5240LHN-00.analog-stereo`, so
// `playbackInputs` answers an empty list for the only microphone here and the
// plan refuses with "has no playback ports to hear it on" on every click, for
// good. That is not a device that cannot be monitored - it is a direction this
// graph does not carry. The capture -> playback pairing needs the DEVICE to
// have outputs (every capture device does) and the SINK to have inputs (every
// sink does), so it composes on this machine and is what wiremix's own Monitor
// writes. Do not restore `monitor_` on the source side: it reads correctly and
// refuses forever.
function captureOutputs(portMap, name) {
  return prefixedRecords(portMap, name, "capture_")
}

// --- the monitor's two kinds of "no" ------------------------------------
//
// A control that cannot act has to name WHICH thing stopped it, because the two
// are different facts about different things and a reader acts on them
// differently:
//
//   MONITOR_UNAVAILABLE  the graph cannot carry this route at all - the device
//                        exposes no capture ports, or the sink exposes no
//                        playback ports. True before the click and true after
//                        it, the user's hardware rather than their click, and
//                        nothing they did will change it.
//   MONITOR_FAILED       something did not happen - the port enumeration has
//                        not landed, `pw-link` refused the write, or the graph
//                        queue was busy. A fault, and the click is worth making
//                        again.
//
// Both arrive at the row as one string, so a control that paints the reason
// and never says which of the two it is leaves "this microphone has no capture
// ports" reading exactly like "the shell was busy". The words live here, beside
// the refusal sites that choose them, for the reason PROFILE_NO_CARD and
// PROFILE_UNREAD live here: a row that spells its own copy of the vocabulary
// drifts from the plan the first time a third case is added.
var MONITOR_UNAVAILABLE = "unavailable"
var MONITOR_FAILED = "failed"

// `pw-link` matches BOTH arguments of `pw-link <out> <in>` and of
// `pw-link -d <out> <in>` as glob patterns - measured on this machine:
// `pw-link -o 'eq_input:monitor_*'` prints both monitor ports and
// `pw-link -o 'eq_input:monitor_?'` prints both, while
// `pw-link -o 'eq_input:monitor_ZZ'` prints none and exits 0. So a port name
// carrying a wildcard can widen to a port this route never named, and the
// teardown's cut would take it with it.
//
// The leading-dash and control-character rules are the same ones Graph.safeArg
// applies to a connect, spelled out here because this library does not import
// the other one and a name that can become an option of pw-link's own is the
// same hazard in either direction.
var MONITOR_GLOB_RE = /[*?]/

function monitorNameSafe(path) {
  const raw = text(path)
  if (raw === "") return false
  if (raw.charAt(0) === "-") return false
  if (raw.indexOf("\u0000") >= 0 || raw.indexOf("\n") >= 0) return false
  return !MONITOR_GLOB_RE.test(raw)
}

// The one argv the monitor's removal composes: `pw-link -d <out> <in>` removes
// the link between those two ports by name.
//
// `pw-link -d` also takes a link id, and an id is what the graph tab cuts with -
// but an id has to be READ first, and a removal that begins with a read is a
// removal with a window in which the controller can be destroyed before the
// answer arrives. The pair needs nothing: it is the pair the plan built, and
// every name in it survived the pattern check above, so the cut is exactly as
// wide as the create.
function monitorDisconnectArgv(output, input) {
  const o = text(output)
  const i = text(input)
  if (!monitorNameSafe(o) || !monitorNameSafe(i)) return []
  return ["pw-link", "-d", o, i]
}

// One removal step per pair, in the pairing's own order, so the list the plan
// published and the list the children run are the same list. A pair whose names
// did not survive the check is dropped rather than guessed at; the plan refuses
// such a pair before it can be created, so the drop is a defence against a
// hand-set state rather than a path anything reaches.
function monitorDisconnectSteps(pairs) {
  const out = []
  if (!Array.isArray(pairs)) return out
  for (let i = 0; i < pairs.length; i++) {
    const pair = pairs[i]
    if (pair === null || pair === undefined) continue
    const argv = monitorDisconnectArgv(pair.source, pair.input)
    if (argv.length === 0) continue
    out.push({
      argv: argv,
      text: argv.join(" "),
      fail: "pw-link refused to unlink " + argv[2] + " " + argv[3]
    })
  }
  return out
}