// Probe: the ArchUpdates island's package table - the handover from the
// blank placeholder to the live rows.
//
// The claim under test: the table's two pictures are ONE picture, so the
// handover between them dissolves instead of switching in a single frame.
// Every package row carries the placeholder bar it stands for, and the two
// trade places as the table stops being a placeholder.
//
// What the probe reads is the row's own painted opacity over time: a cut
// shows nothing in between, a dissolve shows the values in between. The
// rows are read the way a reader of the screen would read them - the name
// is found by its text inside the island's tree, and the placeholder bar is
// the sibling that sits under it in the same cell - so nothing here depends
// on a child index or on the island's own bookkeeping.
//
// The motion policy decides whether the shell moves at all, so the probe
// waits for that policy to settle before it measures (it is seeded from the
// settings catalog and then replaced by the live compositor value, and a
// measurement taken across that swap would describe nothing), and the
// driver asserts the RELATION: the handover is in flight exactly when the
// policy allows motion. On a host with the compositor's animations off the
// handover is a cut, and that is the policy doing its job.
//
// The flow is the real one: a fetch is in flight and the table holds the
// previous package, then the fetch lands and the new package arrives. The
// reverse turn is driven too - a second fetch starts while the rows are up -
// because the placeholder and the rows are one picture, so both directions
// have to dissolve.
//
// Everything is driven from the phase counter, one step per turn, so the
// placeholder is read after the bindings have settled and the handover is
// read while it is in flight.

import QtQuick
import qs.common
import qs.features.bar.modules.ArchUpdates

Item {
  id: root
  width: 640
  height: 480

  property int phase: 0
  property int threw: 0

  // The motion policy's own state, watched until it stops moving.
  property bool policyKnown: false
  property bool policyLast: false
  property int policyStreak: 0

  // The sampled opacities, in order: the row's name, the placeholder bar
  // beside it, and the mix that both of them follow.
  property var names: []
  property var bars: []
  property var mixes: []
  property var backNames: []
  property var backBars: []
  property var backMixes: []
  // How many samples broke the relation between the mix and the paint.
  property int mismatch: 0
  property int backMismatch: 0
  // How many samples found no row at all (the handover destroys the old
  // delegate before the new one is built).
  property int missing: 0
  property int backMissing: 0

  // The package the table holds while the fetch is in flight, and the one
  // that arrives with it. A real package: a name and a candidate version.
  property var stalePkg: ({ name: "stale-pkg", candidate: "1.0-1" })
  property var freshPkg: ({ name: "vim", candidate: "9.0-1" })

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  // safe() keeps one failed read from taking the whole run down: the key that
  // failed is simply never printed, which the driver reports as "the probe
  // never printed key X" rather than as a wrong number.
  function safe(key, fn) {
    try {
      kv(key, fn())
    } catch (e) {
      threw++
      kv(key + ".threw", "" + (e && e.message ? e.message : e))
    }
  }

  // The island under test. The module hands it the packages and the state;
  // the probe does the same.
  ArchUpdatesIsland {
    id: island
    width: 640
    height: 480
  }

  // ---- reading the screen ------------------------------------------------

  // The painted text with this text, anywhere under the island.
  function findText(node, text) {
    if (!node) return null
    if (node.text !== undefined && node.text === text) return node
    const kids = node.children || []
    for (let i = 0; i < kids.length; i++) {
      const hit = findText(kids[i], text)
      if (hit) return hit
    }
    return null
  }

  // The row's name, whichever package it is holding: the handover swaps the
  // package behind the probe's back, and the row is what is being watched.
  function findName(node) {
    const stale = findText(node, "stale-pkg")
    if (stale) return stale
    return findText(node, "vim")
  }

  // The name's own opacity: 1 is fully drawn, 0 is not drawn at all.
  function nameOpacity() {
    const t = findName(island)
    if (!t) return -1
    return t.opacity
  }

  // The placeholder bar under that name. The bar and the name share one
  // cell, and the bar's wrapper is the sibling that is not the name.
  function barOpacity() {
    const t = findName(island)
    if (!t) return -1
    const cell = t.parent
    if (!cell) return -1
    const kids = cell.children || []
    for (let i = 0; i < kids.length; i++) {
      if (kids[i] !== t) return kids[i].opacity
    }
    return -1
  }

  // ---- the arithmetic the driver reads ------------------------------------

  // How many of the samples are strictly between "not drawn" and "drawn" -
  // the values only a dissolve in flight can produce.
  function countBetween(values, lo, hi) {
    let n = 0
    for (let i = 0; i < values.length; i++) {
      if (values[i] > lo && values[i] < hi) n++
    }
    return n
  }

  function joined(values) {
    const out = []
    for (let i = 0; i < values.length; i++) out.push(Number(values[i]).toFixed(3))
    return out.join(",")
  }

  // The mix the row's paint must follow: the name is the mix's complement
  // and the bar is the mix itself.
  function checkSample(names, bars, mixes, mix) {
    if (names < 0 || bars < 0) return "missing"
    if (Math.abs(names - (1 - mix)) > 0.002) return "name"
    if (Math.abs(bars - mix) > 0.002) return "bar"
    return ""
  }

  // ---- steps -------------------------------------------------------------

  // The motion policy is seeded from the settings catalog and then replaced
  // by the live compositor value. Wait until it has stopped moving, and
  // never measure across the swap: a handover read while the policy is
  // changing describes the swap, not the handover.
  function settle() {
    const p = MotionPolicy.enabled
    if (!root.policyKnown || p !== root.policyLast) {
      root.policyKnown = true
      root.policyLast = p
      root.policyStreak = 0
      return
    }
    root.policyStreak++
  }

  // A fetch is in flight: the table stands blank under the wash, holding
  // the package it had before.
  function enterSkeleton() {
    island.islandState = "loading"
    island.packages = [root.stalePkg]
  }

  // One turn later, the placeholder has settled.
  function readPlaceholder() {
    safe("ph.nameOpacity", function () { return root.nameOpacity() })
    safe("ph.barOpacity", function () { return root.barOpacity() })
    safe("ph.mix", function () { return island._skeletonMix })
  }

  // The fetch lands: the state goes ready and the new package arrives, in
  // the same turn, which is how the service hands them over.
  function enterLive() {
    island.islandState = "ready"
    island.packages = [root.freshPkg]
  }

  // The row's opacity, sampled while the handover is in flight.
  function sampleLive() {
    const mix = island._skeletonMix
    const n = root.nameOpacity()
    const b = root.barOpacity()
    root.names.push(n)
    root.bars.push(b)
    root.mixes.push(mix)
    const bad = root.checkSample(n, b, mix)
    if (bad === "missing") root.missing++
    else if (bad !== "") root.mismatch++
  }

  function readLive() {
    safe("live.nameOpacity", function () { return root.nameOpacity() })
    safe("live.barOpacity", function () { return root.barOpacity() })
    safe("live.names", function () { return root.joined(root.names) })
    safe("live.bars", function () { return root.joined(root.bars) })
    safe("live.mixes", function () { return root.joined(root.mixes) })
    safe("live.midCount", function () { return root.countBetween(root.mixes, 0.02, 0.98) })
    safe("live.nameMidCount", function () { return root.countBetween(root.names, 0.02, 0.98) })
    safe("live.barMidCount", function () { return root.countBetween(root.bars, 0.02, 0.98) })
    kv("live.mismatch", root.mismatch)
    kv("live.missing", root.missing)
    kv("live.sampleCount", root.names.length)
    safe("live.first", function () { return root.names.length ? root.names[0] : -1 })
    safe("live.last", function () { return root.names.length ? root.names[root.names.length - 1] : -1 })
  }

  // A second fetch starts while the rows are up: the table dissolves back
  // into its placeholder.
  function enterSkeletonAgain() {
    island.islandState = "loading"
  }

  function sampleBack() {
    const mix = island._skeletonMix
    const n = root.nameOpacity()
    const b = root.barOpacity()
    root.backNames.push(n)
    root.backBars.push(b)
    root.backMixes.push(mix)
    const bad = root.checkSample(n, b, mix)
    if (bad === "missing") root.backMissing++
    else if (bad !== "") root.backMismatch++
  }

  function finish() {
    safe("back.names", function () { return root.joined(root.backNames) })
    safe("back.bars", function () { return root.joined(root.backBars) })
    safe("back.midCount", function () { return root.countBetween(root.backMixes, 0.02, 0.98) })
    safe("back.nameMidCount", function () { return root.countBetween(root.backNames, 0.02, 0.98) })
    safe("back.barMidCount", function () { return root.countBetween(root.backBars, 0.02, 0.98) })
    kv("back.mismatch", root.backMismatch)
    kv("back.missing", root.backMissing)
    kv("back.sampleCount", root.backNames.length)
    safe("back.last", function () { return root.backNames.length ? root.backNames[root.backNames.length - 1] : -1 })
    safe("back.barLast", function () { return root.backBars.length ? root.backBars[root.backBars.length - 1] : -1 })
    kv("probe.threw", root.threw)
    console.log("##DONE##")
  }

  Timer {
    id: pump
    interval: 8
    repeat: true
    running: true
    onTriggered: {
      root.phase++
      // The settle window: the policy has to have held its value for half
      // a second, and the process has to have been up for at least a
      // second, so the compositor's own value has had its chance to land.
      if (root.phase < 130) {
        root.settle()
        return
      }
      if (root.phase === 130) {
        kv("policy.start", MotionPolicy.enabled)
        root.enterSkeleton()
        return
      }
      if (root.phase === 131) {
        root.readPlaceholder()
        return
      }
      if (root.phase === 132) {
        root.enterLive()
        return
      }
      if (root.phase > 132 && root.phase <= 175) {
        root.sampleLive()
        return
      }
      if (root.phase === 176) {
        root.readLive()
        root.enterSkeletonAgain()
        return
      }
      if (root.phase > 176 && root.phase <= 220) {
        root.sampleBack()
        return
      }
      if (root.phase === 221) {
        kv("policy.end", MotionPolicy.enabled)
        root.finish()
      }
    }
  }

  Component.onCompleted: {
    kv("probe.error", "none")
  }
}
