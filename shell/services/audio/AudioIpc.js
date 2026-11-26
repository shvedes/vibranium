.pragma library

// Typed projections for the `audio` gateway commands. Pure data in, plain
// records out: no QML references, no PipeWire ids, no property dumps. The
// caller supplies opaque refs minted from QML object identity, so nothing
// here can leak raw graph state.
.import "../../common/audio/AudioNodeKind.js" as Kind

// Direction names published by `audio sink list`, `audio source list` and `audio apps`.
function deviceDirection(kind) {
  if (kind === "outputDevice") return "output"
  if (kind === "inputDevice") return "input"
  return ""
}

function appDirection(kind) {
  if (kind === "playbackStream") return "playback"
  if (kind === "captureStream") return "capture"
  return ""
}

// One device row. `effective` and `configured` are booleans computed by the
// owner from its live default nodes; the two flags distinguish an effective
// default from the policy default after a plug/unplug.
function deviceRow(node, ref, kind, effective, configured) {
  if (node === null || node === undefined || ref === "" || ref === null) return null
  return {
    id: ref,
    name: Kind.label(node),
    direction: deviceDirection(kind),
    virtual: Kind.virtual(node) === true,
    monitor: Kind.monitor(node) === true,
    default: effective === true,
    configuredDefault: configured === true,
    percent: Kind.percent(Kind.nodeVolume(node)),
    muted: Kind.nodeMuted(node) === true
  }
}

// One application row. Only application streams reach this projection; the
// `app` field is null when the stream publishes no application.name.
function appRow(node, ref, kind) {
  if (node === null || node === undefined || ref === "" || ref === null) return null
  const d = appDirection(kind)
  if (d === "") return null
  return {
    id: ref,
    name: Kind.label(node),
    app: Kind.appNameOrNull(node),
    direction: d,
    percent: Kind.percent(Kind.nodeVolume(node)),
    muted: Kind.nodeMuted(node) === true
  }
}

// Stable order: by published name, then by opaque ref. Sorting by the ref
// alone would reorder rows on every incarnation; sorting by name alone would
// leave ties in graph order, which is not stable across ticks.
function sortRows(rows) {
  const out = rows.slice()
  out.sort(function (a, b) {
    const n = String(a.name).localeCompare(String(b.name))
    if (n !== 0) return n
    return String(a.id).localeCompare(String(b.id))
  })
  return out
}

// An explicit step is an integer 1..200 percentage points. The owner passes
// its configured fraction when the keyword was absent. null means a bad or
// non-positive step, before any write occurs.
function stepFraction(stepArg, baseStep) {
  if (stepArg === undefined || stepArg === null) {
    const b = Number(baseStep)
    return isFinite(b) && b > 0 ? b : null
  }
  const n = Number(stepArg)
  if (!isFinite(n) || n % 1 !== 0 || n < 1 || n > 200) return null
  return n / 100
}

// A level after a device write, read back from the live object rather than
// from the requested value: a backend that clamps or refuses must be
// reported honestly.
function levelOf(node) {
  if (node === null || node === undefined) return null
  const audio = node.audio
  if (!audio) return null
  return { percent: Kind.percent(audio.volume), muted: audio.muted === true }
}

// The audio status projection adds script-friendly integer percentages to
// the existing fractional fields; it never replaces them.
function statusFields(sinkVolume, sinkMuted, sourceVolume, sourceMuted,
  step, maxVolume, maxSourceVolume, visualFeedback, loopbackEnabled,
  loopbackError, graphReady, sinkRef, sourceRef) {
  return {
    sinkVolume: sinkVolume,
    sinkMuted: sinkMuted,
    sinkPercent: Kind.percent(sinkVolume),
    sourceVolume: sourceVolume,
    sourceMuted: sourceMuted,
    sourcePercent: Kind.percent(sourceVolume),
    step: step,
    maxVolume: maxVolume,
    maxSourceVolume: maxSourceVolume,
    visualFeedback: visualFeedback,
    loopbackEnabled: loopbackEnabled,
    loopbackError: loopbackError,
    graphReady: graphReady === true,
    sink: sinkRef === "" ? null : sinkRef,
    source: sourceRef === "" ? null : sourceRef
  }
}
