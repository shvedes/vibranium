.pragma library

// Pure derivations for the graph tab: what a port line is, which two ports may
// be connected to each other, what argv a connect or a disconnect is, how the
// graph's own link objects group into one line per node pair, the bezier a line
// is drawn along, and the left-to-right layout the cards are placed by.
//
// No Qt imports and no host object, for the same reason MixerModel.js has none:
// every function here is driven by plain values, so the parsers, the pairing, the
// argv builders, the curve and the layout can be unit-driven outside a live graph.
// Defensive for the same reason too - these run inside QML bindings, where a
// throw is a warning on stderr and an undefined result on screen.
//
// The one thing that cannot be read from QML and has to be parsed out of
// `pw-link` is here: a node's PORTS (Quickshell 0.3.1's `PwNode` publishes no
// `ports` property at all). A link's identity comes from `PwLink.id`, which is
// the global id `pw-link -d` takes.

// --- ports -------------------------------------------------------------
//
// `pw-link -o` and `pw-link -i` print one port per line as
// `node.name:port.name`, with a trailing ` (capture)` or ` (playback)` on the
// ports that are not the ordinary audio direction. Measured on this machine:
//
//   alsa_output.pci-0000_2f_00.4.analog-stereo:playback_FL
//   eq_input:monitor_FL
//   opencode:output_FR
//   Midi-Bridge:Midi Through: Port-0 (capture)
//
// The MIDI line is the reason the split is on the FIRST colon and not the last:
// the node is `Midi-Bridge` and the port is `Midi Through: Port-0`, so the port
// name may itself carry colons. The graph tab never draws that node - a MIDI
// bridge is not an audio node and the classifier drops it - but a parser that
// mis-splits it would be a parser that guesses.

var PORT_ANNOTATION_RE = /\s+\((capture|playback)\)$/

// The trailing direction annotation, or "" for the plain form. Stripped before
// the colon split so an annotation can never end up inside a port name.
function stripAnnotation(line) {
  return String(line).replace(PORT_ANNOTATION_RE, "").trim()
}

// One `node:port` line as `{ node, port }`, or null when the line cannot be
// one: no colon, or an empty half. Null rather than a partial record, because a
// record with no port name would be offered to `pw-link` as an argument.
function splitPortLine(line) {
  const raw = stripAnnotation(line)
  const cut = raw.indexOf(":")
  if (cut <= 0) return null
  const node = raw.substring(0, cut).trim()
  const port = raw.substring(cut + 1).trim()
  if (node === "" || port === "") return null
  return { node: node, port: port }
}

// `pw-link -o` / `pw-link -i` -> `[{ node, port }]`. Blank lines, CRLF endings
// and lines that are not ports are all skipped rather than turned into a
// partial record.
function parsePorts(input) {
  const out = []
  if (typeof input !== "string" || input === "") return out
  const lines = input.split("\n")
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/\r$/, "").trim()
    if (line === "") continue
    const entry = splitPortLine(line)
    if (entry !== null) out.push(entry)
  }
  return out
}

// The `node:port` spelling `pw-link` takes as an argument, or "" when the
// record cannot produce one.
function portPath(entry) {
  if (entry === null || entry === undefined || typeof entry !== "object") return ""
  const node = typeof entry.node === "string" ? entry.node.trim() : ""
  const port = typeof entry.port === "string" ? entry.port.trim() : ""
  if (node === "" || port === "") return ""
  return node + ":" + port
}

// One direction's port list, as `node.name -> [ port, ... ]`. A map rather
// than a filter over the whole list per card, because the tab asks this
// question once per node per rebuild and the lists are short but not free.
function portsByNode(ports) {
  const out = ({})
  if (!Array.isArray(ports)) return out
  for (let i = 0; i < ports.length; i++) {
    const entry = splitRecord(ports[i])
    if (entry === null) continue
    const held = out[entry.node]
    if (held === undefined) out[entry.node] = [entry.port]
    else held.push(entry.port)
  }
  return out
}

// Re-read one stored port entry, accepting either a record or a bare string so
// a caller holding just names does not have to wrap them first.
function splitRecord(entry) {
  if (typeof entry === "string") return splitPortLine(entry)
  if (entry === null || entry === undefined || typeof entry !== "object") return null
  const node = typeof entry.node === "string" ? entry.node.trim() : ""
  const port = typeof entry.port === "string" ? entry.port.trim() : ""
  if (node === "" || port === "") return null
  return { node: node, port: port }
}

// One node's ports as `{ node, port }` records, which is what pairPorts
// consumes: a refusal has to name the whole `node:port`, so a bare port name is
// not enough to describe one.
function recordsOf(map, nodeName) {
  const held = portsOf(map, nodeName)
  const out = []
  const node = text(nodeName)
  for (let i = 0; i < held.length; i++) {
    const entry = splitPortLine(node + ":" + held[i])
    if (entry !== null) out.push(entry)
  }
  return out
}

// One node's port names in one direction, or [] when the node has none. The
// answer the connect form shows and the refusal path tests.
function portsOf(map, nodeName) {
  if (map === null || map === undefined || typeof map !== "object") return []
  const key = typeof nodeName === "string" ? nodeName : ""
  if (key === "") return []
  const held = map[key]
  return Array.isArray(held) ? held : []
}

// --- channel pairing ---------------------------------------------------
//
// `output_FL` to `playback_FL` and `output_FR` to `playback_FR`: every real
// link on this machine is that pairing, and the alternative - connect every
// port to every port - is both wrong and destructive, because it would wire a
// left channel into a right one and put several streams into one input.

var CHANNEL_KEY_RE = /_([A-Za-z0-9]{1,4})$/

// The channel token a port name ends in, lowercased, or "" when it ends in
// none. Four characters is the ceiling the names PipeWire actually carries need
// (`output_FL`, `playback_FR`, `capture_MONO`, `capture_AUX1`) and it keeps a
// longer underscore tail from being read as a channel name.
function channelKey(port) {
  const found = CHANNEL_KEY_RE.exec(text(port))
  return found === null ? "" : found[1].toLowerCase()
}

// --- text --------------------------------------------------------------

function text(value) {
  if (typeof value !== "string") return ""
  return value.trim()
}

function nodeKeyOf(node) {
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

// The link id as a number, or -1. `PwLink.id` is a uint and `pw-link -l -I`
// prints one as text, and both have to reach `pw-link -d` as the same number.
function linkIdNumber(value) {
  if (typeof value === "number") {
    if (!isFinite(value) || value < 0) return -1
    return Math.round(value)
  }
  const raw = text(value)
  if (!/^[0-9]+$/.test(raw)) return -1
  const n = parseInt(raw, 10)
  return isFinite(n) ? n : -1
}

// --- pairing -----------------------------------------------------------

// The port pairs a connect between two nodes would make, and the pairs it
// would not.
//
// The rule is the channel suffix and nothing else: an output port whose name
// ends in `_KEY` is paired with the input ports of the target that end in the
// same `_KEY`, one link each. A port with no channel token is paired ONLY when
// both nodes carry exactly one port in the direction being connected AND
// neither of those ports has a channel token either - the unambiguous
// one-to-one case, which is what a `Port-0` on both sides is. A suffix on one
// side alone is not a match: `Port-0` into `playback_FL` would be pairing a port
// that says nothing about its channel with a port that says it is the left one,
// which is exactly the guess this function exists to refuse.
//
// The refusals are returned rather than dropped, because "this pair was not
// made" is a fact the user has to be shown before anything is written, and
// because a connect that quietly made half its pairs is a worse outcome than
// one that made none.
//
// Every pairing is one `pw-link` child: a stereo connection is two port pairs
// and therefore two argv, run one after another rather than in parallel.
function pairPorts(outputs, inputs) {
  const outs = toRecords(outputs)
  const ins = toRecords(inputs)
  const pairs = []
  const refused = []
  const usedIn = ({})
  const solo = outs.length === 1 && ins.length === 1
    && channelKey(outs[0].port) === "" && channelKey(ins[0].port) === ""

  for (let i = 0; i < outs.length; i++) {
    const key = channelKey(outs[i].port)
    if (key === "") {
      if (solo) {
        pairs.push({ output: outs[i], input: ins[0] })
        usedIn[0] = true
        continue
      }
      const only = ins.length === 1 ? channelKey(ins[0].port) : ""
      refused.push({
        output: outs[i],
        input: null,
        reason: only !== ""
          ? "no channel suffix, and the one input port is named _"
            + only.toUpperCase()
          : "no channel suffix, and no unnumbered input port to pair it with"
      })
      continue
    }
    let matched = 0
    for (let j = 0; j < ins.length; j++) {
      if (usedIn[j] === true) continue
      if (channelKey(ins[j].port) !== key) continue
      pairs.push({ output: outs[i], input: ins[j] })
      usedIn[j] = true
      matched++
    }
    if (matched === 0) {
      refused.push({
        output: outs[i],
        input: null,
        reason: "no input port ending in _" + key.toUpperCase()
      })
    }
  }

  for (let j = 0; j < ins.length; j++) {
    if (usedIn[j] === true) continue
    const key = channelKey(ins[j].port)
    refused.push({
      output: null,
      input: ins[j],
      reason: key === ""
        ? "no unnumbered output port to pair it with"
        : "no output port ending in _" + key.toUpperCase()
    })
  }

  return { pairs: pairs, refused: refused }
}

function toRecords(list) {
  const out = []
  if (!Array.isArray(list)) return out
  for (let i = 0; i < list.length; i++) {
    const entry = splitRecord(list[i])
    if (entry !== null) out.push(entry)
  }
  return out
}

// One refusal as a line of text, naming the port that has no counterpart. "" is
// impossible for a refusal: one of the two sides is always present.
function refusalText(entry) {
  if (entry === null || entry === undefined) return ""
  const out = portPath(entry.output)
  const inp = portPath(entry.input)
  const which = out !== "" ? out : inp
  return which + ": " + String(entry.reason || "no counterpart")
}

// --- argv --------------------------------------------------------------
//
// The two argv this tab composes by hand, as lists. Never a shell string, and
// never a flag-looking element: a node name is client-supplied text, so an
// element starting with `-` is refused rather than passed on for `pw-link` to
// read as an option of its own.

function safeArg(value) {
  const raw = text(value)
  if (raw === "") return false
  if (raw.charAt(0) === "-") return false
  return raw.indexOf("\u0000") < 0 && raw.indexOf("\n") < 0
}

function connectArgv(output, input) {
  const o = text(output)
  const i = text(input)
  if (!safeArg(o) || !safeArg(i)) return []
  return ["pw-link", o, i]
}

function disconnectArgv(linkId) {
  const n = linkIdNumber(linkId)
  if (n < 0) return []
  return ["pw-link", "-d", String(n)]
}

// Every connect step for a set of port pairs, as `{ argv, text, fail }` steps
// in the order the pairs were made. The order is the pairing's own order
// because that is the order the panel shows them in, so the list the user read
// and the list the children run are the same list.
function connectSteps(pairs) {
  const out = []
  if (!Array.isArray(pairs)) return out
  for (let i = 0; i < pairs.length; i++) {
    const argv = connectArgv(portPath(pairs[i].output), portPath(pairs[i].input))
    if (argv.length === 0) continue
    out.push({
      argv: argv,
      text: argv.join(" "),
      fail: "pw-link refused " + argv[1] + " " + argv[2]
    })
  }
  return out
}

// Every disconnect step for a set of link ids. One child per id: a stereo
// connection is two link objects, and cutting only one of them would leave a
// channel open on a pair the user believes is gone.
function disconnectSteps(ids) {
  const out = []
  if (!Array.isArray(ids)) return out
  for (let i = 0; i < ids.length; i++) {
    const argv = disconnectArgv(ids[i])
    if (argv.length === 0) continue
    out.push({
      argv: argv,
      text: argv.join(" "),
      fail: "pw-link refused to remove link " + argv[2]
    })
  }
  return out
}

// --- the graph's own links --------------------------------------------

// The graph's link list as one entry per NODE PAIR:
// `{ key, sourceKey, targetKey, ids }`.
//
// One line per pair rather than one per link object, because PipeWire carries
// a separate link per port pair: a stereo connection is two `PwLink` objects
// and one line on this canvas, and drawing both would be two coincident curves
// over one another. The ids all travel with the pair, which is what makes
// removing it honest - the whole pair goes, and a single channel left behind
// would not be what the user was shown.
//
// `keyOf` is the caller's own node-key function (MixerModel.nodeKey), passed in
// rather than imported: this library stays free of the mixer's vocabulary, and
// the join key is the mixer's business. It falls back to a local id read so the
// function is drivable on its own.
function groupLinks(links, current, keyOf) {
  const key = typeof keyOf === "function" ? keyOf : nodeKeyOf
  const out = []
  const total = countOf(links)
  for (let i = 0; i < total; i++) {
    let link = null
    try {
      link = links[i]
    } catch (ignored) {
      link = null
    }
    if (link === null || link === undefined) continue
    const id = linkIdNumber(linkId(link))
    if (id < 0) continue
    const source = link.source
    const target = link.target
    if (source === null || source === undefined) continue
    if (target === null || target === undefined) continue
    const sourceKey = key(source)
    const targetKey = key(target)
    if (sourceKey === "" || targetKey === "") continue
    const pairKey = sourceKey + ":" + targetKey
    let group = null
    for (let j = 0; j < out.length; j++) {
      if (out[j].key === pairKey) {
        group = out[j]
        break
      }
    }
    if (group === null) {
      group = { key: pairKey, sourceKey: sourceKey, targetKey: targetKey, ids: [] }
      out.push(group)
    }
    if (group.ids.indexOf(id) < 0) group.ids.push(id)
  }
  for (let i = 0; i < out.length; i++) out[i].ids.sort(ascending)
  return sameGroups(current, out) ? current : out
}

function linkId(link) {
  if (link === null || link === undefined) return -1
  try {
    return link.id
  } catch (ignored) {
    return -1
  }
}

function ascending(a, b) {
  return a - b
}

function countOf(list) {
  if (list === null || list === undefined) return 0
  const n = list.length
  return typeof n === "number" && n >= 0 ? Math.round(n) : 0
}

// Element-wise equality over the grouped links, as a SET BY KEY: the graph
// makes no promise about the order of its link list, and a stereo pair's two
// ids can arrive in either order. An entry whose key and ids are unchanged is
// the INCUMBENT object, which is what keeps a curve that did not move from
// being rebuilt on every graph tick.
//
// The comparison walks `next` and looks each key up in `current` rather than
// comparing index against index, because a graph that re-emits its link list
// with the pairs in another order has not changed anything and every
// index-wise comparison would call that a change. Both id lists are sorted
// before they get here, so the ids of one pair compare in one order only. The
// walk is quadratic in the number of PAIRS, which is a handful - the graph
// carries six links in three pairs here - and it buys back a curve list that
// survives a reorder.
function sameGroups(current, next) {
  if (current === next) return true
  if (!Array.isArray(current) || !Array.isArray(next)) return false
  if (current.length !== next.length) return false
  for (let i = 0; i < next.length; i++) {
    const want = next[i]
    if (want === undefined || want === null) return false
    let held = null
    for (let j = 0; j < current.length; j++) {
      if (current[j] !== undefined && current[j] !== null
        && current[j].key === want.key) {
        held = current[j]
        break
      }
    }
    if (held === null) return false
    const a = held.ids
    const b = want.ids
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false
    for (let k = 0; k < b.length; k++) {
      if (a[k] !== b[k]) return false
    }
  }
  return true
}

// Which mark of a card edge a link group is drawn from, as `[{ from, to }]`
// aligned with `groups`: the slot the group takes among the lines on its
// SOURCE's right edge, and among the lines on its TARGET's left edge. -1 for a
// group with no usable identity.
//
// A slot and NOT the group's place in `ids`, because `ids` are the graph's own
// GLOBAL link ids, sorted ascending, and no channel suffix travels with them.
// Measured on this machine's graph: the `spotify -> eq_input` group carries
// `[126, 128]`, which `pw-link -l -I` names `output_FR -> playback_FR` and
// `output_FL -> playback_FL`, while that card's input handles run
// `playback_FL`, `playback_FR` in enumeration order - so an ids-indexed mark
// would put the right channel's line on the left channel's mark. Two of this
// graph's groups agree with the ids order, because their ids were created in
// channel order, which is the kind of agreement that is not a rule; and
// `Firefox -> eq_input` carries FOUR ids `[94, 136, 152, 158]` against a
// two-port edge, so ids-indexing would run off the end of that fan.
//
// So the slot is the group's RANK among the groups sharing that edge, ordered by
// the node at their OTHER end. That is a total order over values this function
// can read, it does not depend on the order the graph published its links in,
// and it is stable while the topology stands: a republish that only reorders the
// link list moves no line off the mark it is on. Driven over this graph's own
// twelve links permuted into six orders, every group's two slots are the same in
// all six.
function edgeSlots(groups) {
  const rows = arrayOf(groups)
  // The two edges as `<peer>|<group key>`, so a group's rank on an edge is a
  // lookup in one small list rather than a sort over every pair.
  const outs = ({})
  const ins = ({})
  const out = []
  for (let i = 0; i < rows.length; i++) {
    const group = rows[i]
    if (group === null || group === undefined) {
      out.push({ from: -1, to: -1 })
      continue
    }
    const key = text(group.key)
    if (key === "") {
      out.push({ from: -1, to: -1 })
      continue
    }
    pushOut(outs, text(group.sourceKey), text(group.targetKey) + "|" + key)
    pushOut(ins, text(group.targetKey), text(group.sourceKey) + "|" + key)
    out.push({ from: -1, to: -1 })
  }
  for (const node in outs) outs[node].sort(compareKeys)
  for (const node in ins) ins[node].sort(compareKeys)
  for (let i = 0; i < rows.length; i++) {
    const group = rows[i]
    const held = out[i]
    if (group === null || group === undefined) continue
    const key = text(group.key)
    held.from = listOut(outs, text(group.sourceKey)).indexOf(
      text(group.targetKey) + "|" + key)
    held.to = listOut(ins, text(group.targetKey)).indexOf(
      text(group.sourceKey) + "|" + key)
  }
  return out
}

// --- geometry ----------------------------------------------------------
//
// One definition of the curve a link is drawn along, so the paint and the click
// hit test cannot disagree about where the line is. A cubic with horizontal
// control points: the ends leave and arrive horizontally, which is what keeps a
// pair of cards legible when the control point has to overshoot to reach
// backwards.

// The control points of the curve between two endpoints, as
// `{ x1, y1, x2, y2, x3, y3, x4, y4 }`. `x2`/`y2` is the first control point
// and `x3`/`y3` the second, matching how a `ShapePath` consumes them. The
// ARGUMENTS are the two endpoints and the fourth and fifth of the returned eight
// are the far one, so the far end is `x2`/`y2` as an argument and `x4`/`y4` in
// the result - spelled the same in both places because the ShapePath binding and
// the pick test both index this shape positionally.
//
// The lead is HALF THE HORIZONTAL SPAN, signed TOWARD the other endpoint, and
// that is the whole of the shape. The horizontal span is the only measurement
// here because it is the only measurement a node-editor line can spend: the ends
// are on opposite edges of two cards, so a horizontal lead is what leaves and
// arrives along the edges rather than across them.
//
// Two things follow from "half the span, signed". Both control points stay
// inside the span, so the curve cannot pass the endpoint it faces - the overshoot
// and the kink at the end of a line are the same defect, since a control point
// beyond the endpoint makes the curve leave, cross itself and arrive from the
// wrong side. And with nothing spent on a pair that has no horizontal span, a
// line between two vertically-adjacent cards is the straight vertical run the
// geometry says it is, rather than a short horizontal stub at each end with the
// whole drop crammed into the middle.
function curveBetween(x1, y1, x2, y2) {
  const lead = Math.abs(x2 - x1) * 0.5
  const towards = x2 >= x1 ? 1 : -1
  return {
    x1: x1,
    y1: y1,
    x2: x1 + towards * lead,
    y2: y1,
    x3: x2 - towards * lead,
    y3: y2,
    x4: x2,
    y4: y2
  }
}

// How many samples a hit test takes, from the curve's own arc length.
//
// The distance reported is the distance to the nearest SAMPLE, so the error is
// half a step - and a fixed 24 is fine between two adjacent cards and far too
// coarse between the far ends of a canvas, where a point plainly on the line
// reports a distance larger than the pick radius and the line cannot be clicked.
// The step is four world units along the control POLYGON, whose length bounds the
// arc and needs no arc-length pass to know, so the error stays well under the
// eight-unit pick radius at any size the canvas reaches. Measured over the three
// shapes that matter: 2.7 units on a line between neighbouring cards, 2.8 on a
// four-layer band, 4.1 on a curve stretched to the far corner of a world a
// dragged card can reach - and 126 on that last one at the fixed 24.
//
// A click-time cost over a handful of curves, so the ceiling costs nothing worth
// naming: it bounds the work, and only a line far longer than any layout produces
// reaches it.
function curveSamples(curve) {
  const poly = polyLength(curve)
  if (!isFinite(poly) || poly <= 0) return 24
  return Math.min(1024, Math.max(24, Math.ceil(poly / 4)))
}

// The length of a curve's control POLYGON: the three straight legs of the hull,
// which bound the arc and need no arc-length pass to know. Stated once because
// three functions reason about a curve's size and a second copy of the sum is a
// second thing that can disagree with the first about how long a line is.
function polyLength(curve) {
  return Math.abs(curve.x2 - curve.x1) + Math.abs(curve.y2 - curve.y1)
    + Math.abs(curve.x3 - curve.x2) + Math.abs(curve.y3 - curve.y2)
    + Math.abs(curve.x4 - curve.x3) + Math.abs(curve.y4 - curve.y3)
}

// --- dashes -------------------------------------------------------------
//
// A dash is GEOMETRY here, and both of the alternatives were measured first
// rather than argued about.
//
//   `strokeStyle: DashLine` + `dashPattern` exists on this Qt (6.11.2) and does
//   render. But the pattern is expressed in STROKE WIDTHS: painting
//   `dashPattern: [4, 3]` at five widths and reading the runs off the pixels
//   gives dash 4, 6, 10, 20, 40 - that is, `4 x strokeWidth` every time. So a
//   world-unit dash would have to be written as `dashWorld / strokeWidth`, and
//   `strokeWidth` is the one number this canvas already spends on a DIFFERENT
//   question: 2.5 unpicked, 3.5 picked. The dash would then depend on the
//   selection state, which is backwards - picking a line must not redraw its own
//   pattern.
//
//   Several `ShapePath`s in one `Shape` is the other way to carry several runs,
//   and it does not work: a `Repeater` of `ShapePath` inside a `Shape` reports
//   `count` and builds NOTHING (`rep.children` empty, `rep.itemAt(0)` null, and
//   not one lit pixel), because `ShapePath` is not an `Item` and a `Shape` does
//   not take one as a visual child. A line painted that way is invisible and
//   every check on it passes.
//
// What works is what this does: the runs are geometry, and the geometry is
// carried as a PATH STRING on a single `PathSvg` element. One element per line,
// so a solid line and a dashed one differ only in what the string says, and the
// delegate keeps one mechanism.
//
// The dash pieces are exact sub-curves rather than sampled points, by
// de Casteljau: a cubic restricted to a parameter range IS a cubic, with its own
// control points. So every painted mark lies exactly on the curve `curveDistance`
// measures, and "what is painted" and "what is clickable" cannot drift apart -
// which is the property the whole arrangement rests on.

// One cubic split in two at `t`, as `[ left, right ]`.
//
// The three levels of interpolation are the whole of de Casteljau and the reason
// the halves are EXACT: the point at `t` is computed the same way three times,
// once on each hull, and the same number falls out of all three.
function splitCurve(curve, t) {
  const at = t < 0 ? 0 : (t > 1 ? 1 : t)
  const p01x = curve.x1 + (curve.x2 - curve.x1) * at
  const p01y = curve.y1 + (curve.y2 - curve.y1) * at
  const p12x = curve.x2 + (curve.x3 - curve.x2) * at
  const p12y = curve.y2 + (curve.y3 - curve.y2) * at
  const p23x = curve.x3 + (curve.x4 - curve.x3) * at
  const p23y = curve.y3 + (curve.y4 - curve.y3) * at
  const p012x = p01x + (p12x - p01x) * at
  const p012y = p01y + (p12y - p01y) * at
  const p123x = p12x + (p23x - p12x) * at
  const p123y = p12y + (p23y - p12y) * at
  const midx = p012x + (p123x - p012x) * at
  const midy = p012y + (p123y - p012y) * at
  return [
    { x1: curve.x1, y1: curve.y1, x2: p01x, y2: p01y, x3: p012x, y3: p012y, x4: midx, y4: midy },
    { x1: midx, y1: midy, x2: p123x, y2: p123y, x3: p23x, y3: p23y, x4: curve.x4, y4: curve.y4 }
  ]
}

// The piece of a curve between two parameters, in the same eight-number shape
// `curveBetween` returns - so a dash is the same kind of object the whole curve
// is, and no second drawing vocabulary exists.
//
// Split at the NEAR end first, then again inside what is left, because a
// parameter is only ever relative to the piece it is read on: after the split at
// `t0` the remainder is the curve as parameterised over `[t0, 1]`, so the
// original `t1` sits at `(t1 - t0) / (1 - t0)` of THAT, not at `t1`. Reading it
// as `t1` is the one mistake available here and it is silent - the pieces still
// tile the curve, they are just the wrong pieces of it.
function subCurve(curve, t0, t1) {
  if (!(t1 > t0)) return null
  if (t0 <= 0) return splitCurve(curve, t1)[0]
  if (t1 >= 1) return splitCurve(curve, t0)[1]
  const rest = splitCurve(curve, t0)[1]
  // On `rest`, the original curve's t1 sits at (t1 - t0) / (1 - t0), and
  // (t0, t1) is what lies LEFT of it.
  return splitCurve(rest, (t1 - t0) / (1 - t0))[0]
}

// The parameter at an ARC LENGTH along a sampled curve, by interpolating
// linearly inside the step that brackets it.
//
// `cum` is the cumulative chord length at each sample, so the bracket is found
// by binary search and the answer is read off the one step it falls in. Linear
// rather than exact because a chord under-measures its own arc and the error is
// what the step size is chosen to bound; `dashRuns` steps finer than the dash.
function paramAtLength(cum, steps, length) {
  if (!(length > 0)) return 0
  const total = cum[steps]
  if (!(length < total)) return 1
  let lo = 0
  let hi = steps
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1
    if (cum[mid] <= length) lo = mid
    else hi = mid
  }
  const span = cum[hi] - cum[lo]
  const frac = span > 0 ? (length - cum[lo]) / span : 0
  return Math.min(1, (lo + frac) / steps)
}

// One curve as the runs of ink a dash pattern puts on it, as eight-number curve
// pieces in the order they are drawn.
//
// `[curve]` when there is no pattern, and that is the whole reason a plain link
// and a dashed one are the same shape on screen: a solid line is a run of one.
// The delegate has one mechanism and no branch on which kind of line it is
// drawing, so a solid line cannot accidentally acquire the machinery of the
// dashed one.
//
// Length is measured along the ARC, not along `t`, because a cubic's parameter
// is not its arc length: the ends of these curves run nearly horizontally and the
// middle drops steeply, so dashes placed at even steps of `t` would be long
// where the line is flat and short where it falls. Sampling one step per eighth
// of a dash bounds the boundary error at about a sixteenth of a dash.
function dashRuns(curve, dash, gap) {
  const on = Number(dash)
  const off = Number(gap)
  if (!isFinite(on) || !isFinite(off) || !(on > 0) || !(off > 0)) return [curve]
  const poly = polyLength(curve)
  if (!isFinite(poly) || poly <= 0) return [curve]
  // One step per eighth of a dash, floored at a world unit and a 64-step walk,
  // and bounded above: the walk is build-time work on a graph change over a
  // handful of lines, and a step finer than a world unit buys an error no eye
  // resolves on a two-unit stroke.
  const perStep = Math.max(1, on / 8)
  const steps = Math.min(4096, Math.max(64, Math.ceil(poly / perStep)))
  const cum = new Array(steps + 1)
  cum[0] = 0
  let px = curve.x1
  let py = curve.y1
  for (let i = 1; i <= steps; i++) {
    const t = i / steps
    const u = 1 - t
    const bx = u * u * u * curve.x1 + 3 * u * u * t * curve.x2
      + 3 * u * t * t * curve.x3 + t * t * t * curve.x4
    const by = u * u * u * curve.y1 + 3 * u * u * t * curve.y2
      + 3 * u * t * t * curve.y3 + t * t * t * curve.y4
    const dx = bx - px
    const dy = by - py
    cum[i] = cum[i - 1] + Math.sqrt(dx * dx + dy * dy)
    px = bx
    py = by
  }
  const total = cum[steps]
  if (!(total > 0)) return [curve]
  const period = on + off
  const out = []
  let at = 0
  while (at < total) {
    const end = Math.min(at + on, total)
    const piece = subCurve(curve, paramAtLength(cum, steps, at), paramAtLength(cum, steps, end))
    if (piece !== null) out.push(piece)
    at += period
  }
  // A curve shorter than one dash is one dash, not zero: the alternative is a
  // monitor leg that paints nothing at all, which is worse than a solid line
  // that fails to look dashed.
  return out.length === 0 ? [curve] : out
}

// The runs as ONE SVG path string, each run a `M` and a `C`.
//
// This is the drawing half of `dashRuns`, kept beside it so the two cannot
// disagree about where a dash starts: the string is not a second description of
// the pattern, it is the same sub-curves written as path commands.
//
// `originX` / `originY` are subtracted, and they are the caller'S numbers
// because only the caller knows which space the element is drawn in: the canvas
// draws in world units, while a `PathSvg` is drawn in the SHAPE's coordinates,
// which are the curve's box with its corner at the origin. Passing the corner in
// is what keeps this library free of the viewport.
//
// Two decimals: a hundredth of a world unit on a canvas whose thinnest feature is
// a two-and-a-half-unit stroke, so two orders of magnitude below the antialiasing
// the result is painted through, and short enough to be worth building at all.
function dashPath(runs, originX, originY) {
  let out = ""
  for (let i = 0; i < runs.length; i++) {
    const r = runs[i]
    if (i > 0) out += " "
    out += "M " + dashPoint(r.x1 - originX) + " " + dashPoint(r.y1 - originY)
      + " C " + dashPoint(r.x2 - originX) + " " + dashPoint(r.y2 - originY)
      + " " + dashPoint(r.x3 - originX) + " " + dashPoint(r.y3 - originY)
      + " " + dashPoint(r.x4 - originX) + " " + dashPoint(r.y4 - originY)
  }
  return out
}

function dashPoint(value) {
  if (!isFinite(value)) return "0"
  return String(Math.round(value * 100) / 100)
}

// How far a point is from a curve, sampled at `curveSamples` points. A
// click-time hit test and nothing else: sampling a cubic is not a shape's job,
// and this runs once per click rather than per frame.
function curveDistance(px, py, curve) {
  if (curve === null || curve === undefined) return Infinity
  const steps = curveSamples(curve)
  let best = Infinity
  for (let i = 0; i <= steps; i++) {
    const t = i / steps
    const u = 1 - t
    const bx = u * u * u * curve.x1 + 3 * u * u * t * curve.x2
      + 3 * u * t * t * curve.x3 + t * t * t * curve.x4
    const by = u * u * u * curve.y1 + 3 * u * u * t * curve.y2
      + 3 * u * t * t * curve.y3 + t * t * t * curve.y4
    const dx = bx - px
    const dy = by - py
    const d = dx * dx + dy * dy
    if (d < best) best = d
  }
  return Math.sqrt(best)
}

// --- card identity -----------------------------------------------------
//
// The same discipline as `MixerModel.stableList`, extended to what a card is:
// a published array is a Repeater's model, so a fresh identity rebuilds every
// delegate even when every member is unchanged, and a delegate that rebuilds
// tears down its peak hold and takes it again. The node that stayed must keep
// its own object here, and the card that did not move must keep its slot.
//
// The comparison is by node KEY rather than by object identity, because the
// graph republishes its whole node set on any node arriving or leaving, so the
// same node arrives behind a fresh wrapper.

function syncCards(current, next, keyOf) {
  const key = typeof keyOf === "function" ? keyOf : nodeKeyOf
  if (!Array.isArray(current) || !Array.isArray(next)) return next
  if (current.length !== next.length) return next
  for (let i = 0; i < next.length; i++) {
    const held = current[i]
    if (held === undefined || held === null) return next
    if (held.key !== next[i].key) return next
    if (key(held.node) !== key(next[i].node)) return next
  }
  return current
}

// --- the layered layout -------------------------------------------------
//
// Two functions, and between them the whole default placement: `layerPlan` says
// which COLUMN each node is in and which place down that column it takes, and
// `layerSlots` turns those into world coordinates. Pure, so the placement can be
// driven and checked without a canvas.
//
// A COLUMN IS A DEPTH IN THE CHAIN, not a kind. A node's layer is the length of
// the longest chain of links that ends at it, counted from a node nothing feeds:
// a source is 0, and every node is one more than the deepest thing that feeds it.
// That single rule is what puts a capture stream or an input device leftmost,
// leaves the filters in the middle, puts playback streams after them and a
// device last, and it puts a node strictly to the right of everything that feeds
// it without any per-kind case to keep in step - a filter chain of any length
// lays itself out.
//
// The kind decides NOTHING about the layer. It is the wrong signal: the graph's
// own `Stream/Output/Audio` stream output of a filter chain classifies as a
// playback stream and the chain's `Audio/Sink` input classifies as an output
// DEVICE, because that is the whole of what `isSink` plus `isStream` can tell -
// so a kind-keyed floor would seat a filter at the device end and then push its
// own chain right of the speakers, which is the layout the user has to undo by
// dragging. The kind decides the one question a chain cannot answer: which SIDE a
// node with no links at all goes on.
//
// Determinism is a property of the INPUT, not of the call: the layer of a node
// is a `max` over its predecessors and the place down a column is the node's rank
// in KEY order, so the plan does not depend on the order the graph published its
// nodes in and two rebuilds of the same node set put every card in exactly the
// same place. Nothing here is seeded from a counter or sampled, so there is
// nothing left to drift.

// The two kinds that are the START of a chain, and therefore the side an unlinked
// card of that kind belongs on.
var SOURCE_KINDS = ["captureStream", "inputDevice"]

function isSourceKind(kind) {
  return SOURCE_KINDS.indexOf(text(kind)) >= 0
}

// The layer plan for a node set, as `{ columns, byLayer, layers, rows, count }`.
//
// `nodes` is `[{ key, kind }]` and `groups` is `[{ sourceKey, targetKey }]` -
// the canvas's own link groups, which carry one entry per NODE PAIR, so a stereo
// pair contributes one edge rather than two. Plain values, no node objects: the
// canvas knows how a node is classified and this library does not, so the kinds
// travel in.
//
// `columns` is the ordered list of layer indices from left to right, `byLayer` is
// `layer -> [ key ]` in KEY order, `layers` is `key -> layer` and `rows` is the
// depth of the deepest column - the numbers the canvas needs both to place the
// cards and to size the band against.
function layerPlan(nodes, groups) {
  const keys = []
  const kinds = ({})
  const index = ({})
  for (const node of arrayOf(nodes)) {
    if (node === null || node === undefined) continue
    const key = text(node.key)
    if (key === "") continue
    if (Object.prototype.hasOwnProperty.call(index, key)) continue
    index[key] = keys.length
    keys.push(key)
    kinds[key] = text(node.kind)
  }
  const total = keys.length
  // Edges from and to each node, de-duplicated. A group repeated by a republish
  // is one edge: a node that feeds a node twice over two links is one node in
  // the graph, and letting the duplicate in would push the target a layer right
  // for a link count that does not exist.
  const outs = ({})
  const ins = ({})
  const linked = ({})
  for (const group of arrayOf(groups)) {
    if (group === null || group === undefined) continue
    const from = index[text(group.sourceKey)]
    const to = index[text(group.targetKey)]
    if (from === undefined || to === undefined || from === to) continue
    linked[keys[from]] = true
    linked[keys[to]] = true
    // Both directions carry flow, so the same pair de-duplicates twice: the
    // first check is what keeps the edge list free of a republish's repeats and
    // the second is what keeps a pair that arrives with its two ends the wrong way
    // round from being two edges. A self edge is dropped rather than counted: a
    // node cannot feed itself, and counting one would put it a layer right of
    // itself forever.
    if (hasOut(outs, keys[from], keys[to])) continue
    if (hasOut(ins, keys[to], keys[from])) continue
    pushOut(outs, keys[from], keys[to])
    pushOut(ins, keys[to], keys[from])
  }

  // Depth by longest path, over a Kahn walk so a graph with a loop in it
  // terminates: a node's layer is raised only once every node feeding it has
  // been layered, and anything left over - the nodes inside the loop - is
  // layered afterwards in KEY order, which is the one order that does not
  // depend on the order the graph happened to publish its nodes in. A cycle has
  // no left-to-right layering at all: the edge that closes it is drawn
  // backwards, and that is the truth about a loop rather than a layout bug.
  const depth = ({})
  const pending = ({})
  const queue = []
  for (const key of keys) {
    depth[key] = 0
    pending[key] = countOut(ins, key)
    if (pending[key] === 0) queue.push(key)
  }
  const seen = ({})
  const walk = []
  while (queue.length > 0) {
    const key = queue.shift()
    if (seen[key] === true) continue
    seen[key] = true
    walk.push(key)
    for (const next of listOut(outs, key)) {
      depth[next] = Math.max(depth[next], depth[key] + 1)
      pending[next] = pending[next] - 1
      if (pending[next] === 0) queue.push(next)
    }
  }
  const rest = []
  for (const key of keys) {
    if (seen[key] !== true) rest.push(key)
  }
  rest.sort(compareKeys)
  for (const key of rest) {
    let deepest = 0
    for (const from of listOut(ins, key)) {
      if (depth[from] + 1 > deepest) deepest = depth[from] + 1
    }
    depth[key] = deepest
  }

  // The columns, and the two side columns the unlinked cards go on rather than
  // into the band: the one LEFT of the band for a card that is a source by kind
  // (a capture stream, an input device) and the one RIGHT of it for everything
  // else. An unlinked card is beside the band it would have belonged in, so it
  // cannot be mistaken for a stage of the chain and it cannot push a linked
  // card's column along - and the side it lands on says which end of the graph
  // it would have joined.
  //
  // A node whose only link is a monitor leg lands on the side and not in the
  // band, and that is the same rule rather than a special case: a monitor link
  // runs from a sink's monitor ports to a device's playback ports, so the sink
  // end has nothing feeding it and the device end has nothing it feeds, and both
  // are at the ends of a chain that exists only while the monitoring does.
  let widest = -1
  for (const key of keys) {
    if (linked[key] === true && depth[key] > widest) widest = depth[key]
  }
  const layers = ({})
  for (const key of keys) {
    layers[key] = linked[key] !== true
      ? (isSourceKind(kinds[key]) ? -1 : widest + 1) : depth[key]
  }

  const columns = []
  const byLayer = ({})
  for (const key of keys) {
    const layer = layers[key]
    if (byLayer[layer] === undefined) {
      byLayer[layer] = []
      columns.push(layer)
    }
    byLayer[layer].push(key)
  }
  columns.sort(numericAscending)
  let rows = 0
  for (const layer of columns) {
    // Key order within a column, so a card's place down it is its own identity
    // rather than its position in whatever order the graph handed the set over.
    byLayer[layer].sort(compareKeys)
    if (byLayer[layer].length > rows) rows = byLayer[layer].length
  }
  return {
    columns: columns,
    byLayer: byLayer,
    layers: layers,
    rows: rows,
    count: keys.length
  }
}

// `key -> { x, y }` for a plan. The canvas's own metrics go in, so this function
// states no size of its own and the spacing numbers live in one place.
function layerSlots(plan, metrics) {
  const out = ({})
  if (plan === null || plan === undefined) return out
  if (!Array.isArray(plan.columns) || plan.columns === null) return out
  const cardW = numberOf(metrics, "cardW", 0)
  const cardH = numberOf(metrics, "cardH", 0)
  const gapX = numberOf(metrics, "gapX", 0)
  const gapY = numberOf(metrics, "gapY", 0)
  const margin = numberOf(metrics, "margin", 0)
  const rowStep = cardH + gapY
  // A layer's own band, plus the side columns, drawn left to right with each
  // card's own width kept off its neighbour - so a wider card widens the band
  // instead of closing the gap between the two layers around it.
  const colStep = cardW + gapX
  const rows = Math.max(1, Math.round(numberOf(plan, "rows", 1)))
  for (const layer of plan.columns) {
    const list = byLayerOf(plan, layer)
    // A column is centred on the band's own vertical middle, so a two-card layer
    // and a four-card layer read as columns of one table rather than as a
    // staircase hanging off the top-left corner.
    const offset = Math.round((rows - list.length) * rowStep / 2)
    for (let i = 0; i < list.length; i++) {
      out[list[i]] = {
        x: margin + (layer + 1) * colStep,
        y: margin + offset + i * rowStep
      }
    }
  }
  return out
}

// The world's own size for a plan: the band's extent plus the margin on each
// side. Derived from the plan rather than counted from the card list, because a
// plan's extent is what the cards actually occupy and a card count says nothing
// about how many columns those cards ended up in - eight cards laid out as a
// chain of four filter stages are four columns wide.
//
// Same metrics object `layerSlots` took, over the same plan, so the bound and the
// places it bounds are one measurement rather than two.
function layerExtent(plan, metrics) {
  const columns = plan === null || plan === undefined ? 0 : countOf(plan.columns)
  const rows = plan === null || plan === undefined ? 0 : Math.round(numberOf(plan, "rows", 0))
  const cardW = numberOf(metrics, "cardW", 0)
  const cardH = numberOf(metrics, "cardH", 0)
  const gapX = numberOf(metrics, "gapX", 0)
  const gapY = numberOf(metrics, "gapY", 0)
  const margin = numberOf(metrics, "margin", 0)
  return {
    w: margin * 2 + Math.max(1, columns) * (cardW + gapX),
    h: margin * 2 + Math.max(1, rows) * (cardH + gapY)
  }
}

// --- the layout's own small helpers --------------------------------------
//
// A node id is a decimal string, so a numeric comparison orders ids the way they
// were created and a string comparison orders them 1, 10, 100, 2. Numeric first
// with a string fallback for anything that is not a number at all, which keeps
// the order total for a synthetic key rather than leaving it to the sort.

function compareKeys(a, b) {
  const na = parseFloat(a)
  const nb = parseFloat(b)
  const both = !isNaN(na) && !isNaN(nb)
  if (both && na !== nb) return na < nb ? -1 : 1
  if (a === b) return 0
  return a < b ? -1 : 1
}

function numericAscending(a, b) {
  return a - b
}

function byLayerOf(plan, layer) {
  if (plan === null || plan === undefined) return []
  if (plan.byLayer === undefined || plan.byLayer === null) return []
  return arrayOf(plan.byLayer[layer])
}

// Edges per node, as a map of small lists. A map rather than an array of lists
// indexed by node position, so the two never have to agree about how a node list
// was numbered.
function pushOut(map, key, value) {
  if (map[key] === undefined) map[key] = []
  map[key].push(value)
}

function listOut(map, key) {
  return map[key] === undefined ? [] : arrayOf(map[key])
}

function countOut(map, key) {
  return listOut(map, key).length
}

function hasOut(map, key, value) {
  return listOut(map, key).indexOf(value) >= 0
}

function arrayOf(list) {
  return Array.isArray(list) ? list : []
}

function numberOf(holder, name, fallback) {
  if (holder === null || holder === undefined || typeof holder !== "object") {
    return fallback
  }
  const raw = holder[name]
  if (typeof raw !== "number" || !isFinite(raw)) return fallback
  return raw
}