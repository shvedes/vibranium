// Shared link-throughput sampler for the Network module and its island.
//
// ONE owner, not one per surface. The sampler used to be instantiated by the
// bar module and again by the island's content, each with its own tick, its
// own `ip route` child and its own pair of sysfs readers - so a hovered
// tooltip beside an open island polled the same route twice a second and kept
// two copies of a reading that is a property of the link, not of the surface.
//
// A singleton with a subscriber count is the ownership that matches the fact:
//
//   acquire()  a surface starts reading (tooltip hover, island open)
//   release()  it stops; the last one to leave stops the tick and drops the
//              route child, so nothing polls while no surface is watching
//
// The first subscriber resets the reading (a fresh hover must not open on the
// previous session's rates) and asks for a route immediately; later
// subscribers share what is already there instead of zeroing it under the
// surface that is watching.
//
// A generated sysfs counter holds content from the moment it exists and raises
// no filesystem event when that content moves, so a watcher on it can never
// fire - the value comes from a read, and `blockLoading` keeps that read on the
// calling turn instead of deferring it behind a job. The route is a fork, so it
// is refreshed on a slower cadence than the counters: once a second while a
// surface is open, which still catches an interface change well inside the
// window a user would notice.
pragma Singleton

import QtQml
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Singleton {
  id: sampler

  // The interface the last route reply named, or "" while there is no active
  // route. Counters are only read while this names one.
  property string iface: ""
  property bool hasStats: false
  property real downloadRate: 0
  property real uploadRate: 0
  property real totalRxBytes: 0
  property real totalTxBytes: 0
  property var prevThroughput: null

  // Surfaces currently reading. The tick runs exactly while this is non-zero.
  property int _subscribers: 0
  readonly property bool active: sampler._subscribers > 0

  // A speed test saturates the link on purpose; a competing `ip route` every
  // second is contention the measurement never needed. The island owns that
  // state, so it sets this while its test runs. The counters keep being read -
  // they cost no fork, and the graph is what shows the test's own throughput.
  property bool routePaused: false

  // A surface starts reading. The first one gets a zeroed reading and an
  // immediate route; a later one inherits the live one.
  function acquire() {
    sampler._subscribers++
    if (sampler._subscribers !== 1) return
    sampler.reset()
    sampler._routeTick = 0
    sampler.requestRoute()
  }

  // A surface stops reading. The last one out stops the child and the tick, so
  // no process is left sampling a link nobody is looking at.
  function release() {
    if (sampler._subscribers === 0) return
    sampler._subscribers--
    if (sampler._subscribers > 0) return
    sampler.reset()
    sampler.routePaused = false
    if (routeProc.running) routeProc.running = false
  }

  // The zero reading a fresh acquisition starts from, so the graph never opens
  // on the previous session's rates. A cleared interface is the "route unknown"
  // state noteRoute resolves next.
  function reset() {
    sampler.prevThroughput = null
    sampler.iface = ""
    sampler.hasStats = false
    sampler.downloadRate = 0
    sampler.uploadRate = 0
    sampler.totalRxBytes = 0
    sampler.totalTxBytes = 0
  }

  // Ask for one route read. The reply lands in noteRoute; a consumer decides
  // how often it asks, this only refuses to stack two reads.
  function requestRoute() {
    if (sampler.routePaused) return
    if (!routeProc.running) routeProc.running = true
  }

  // One stats tick: hand the raw sample plus the previous one to the library
  // and land the derived metrics. The parse, the throughput delta, the
  // link-drop reset and the cumulative counters are Model.deriveStats; the
  // clock stays here so the rate is reproducible in a test.
  function updateStats(raw) {
    const d = Model.deriveStats({
      prevThroughput: sampler.prevThroughput,
      totalRxBytes: sampler.totalRxBytes,
      totalTxBytes: sampler.totalTxBytes
    }, raw, Date.now() / 1000)
    sampler.hasStats = d.hasStats
    sampler.downloadRate = d.downloadRate
    sampler.uploadRate = d.uploadRate
    sampler.totalRxBytes = d.totalRxBytes
    sampler.totalTxBytes = d.totalTxBytes
    sampler.prevThroughput = d.prevThroughput
  }

  // The same key<TAB>value shape the library reads, built from the two files.
  // A counter this tick could not read is left out rather than reported as a
  // zero: an omitted key means nobody read it and the library carries the last
  // figure, while a zero would read as a link that moved nothing.
  function counterSample() {
    let out = "iface\t" + sampler.iface + "\n"
    const rx = sampler.readCounter(statsRx, "rx_bytes")
    if (rx !== "") out += "rx_bytes\t" + rx + "\n"
    const tx = sampler.readCounter(statsTx, "tx_bytes")
    if (tx !== "") out += "tx_bytes\t" + tx + "\n"
    return out
  }

  // The route reply, reduced to an interface. A reply with no `dev` and an
  // `ip` that could not start at all are the same answer - no active route -
  // and the library already reads that as the link being down.
  function noteRoute(out) {
    const next = Model.routeIface(out)
    if (next === sampler.iface) return
    sampler.iface = next
    if (next === "") {
      // A route that went away has to reach the surface as a link-down reading
      // rather than as a graph frozen on the interface it last saw.
      sampler.updateStats("")
      return
    }
    // A route that appeared is the one transition worth sampling at once:
    // waiting for the next tick would hold the metrics empty for another 0.5s.
    // A changed interface re-seeds the throughput baseline anyway, so the
    // back-to-back pair cannot manufacture a rate out of a short interval.
    sampler.updateStats(sampler.counterSample())
  }

  // One counter, as the digits it holds, or "" when the read did not complete.
  // The interface name comes from the kernel and cannot contain a separator,
  // and nothing is handed to a shell here, so an odd name fails the read
  // instead of reaching a command line.
  function readCounter(view, name) {
    view.path = ""
    view.path = "/sys/class/net/" + sampler.iface + "/statistics/" + name
    try {
      if (!view.waitForJob()) return ""
      return String(view.text()).trim()
    } catch (e) {
      return ""
    }
  }

  // The one sampling tick. Counters every 500ms; the route fork once a second.
  property int _routeTick: 0
  readonly property int _routeEveryTicks: 2

  Timer {
    interval: 500
    repeat: true
    running: sampler.active
    onTriggered: {
      sampler._routeTick++
      if (sampler._routeTick % sampler._routeEveryTicks === 0) sampler.requestRoute()
      if (sampler.iface !== "") sampler.updateStats(sampler.counterSample())
    }
  }

  // The interface the kernel would route 1.1.1.1 through. Resolved by `ip` on
  // its own argv: the interface is the word after the first `dev` in a reply
  // like "1.1.1.1 dev wlan0 src 10.0.0.5 uid 1000", so no shell, no pipeline
  // and no `cat` stands between the tick and the number.
  Process {
    id: routeProc

    command: ["ip", "route", "get", "1.1.1.1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: sampler.noteRoute(text)
    }
    // `ip` reports a failed lookup on stderr and says nothing on stdout, and
    // nothing on stdout is the answer this sampler wants; the collector keeps
    // that text out of the shell's own log.
    stderr: StdioCollector {}
  }

  // The two byte counters, read straight off the tick.
  FileView { id: statsRx; blockLoading: true; printErrors: false }
  FileView { id: statsTx; blockLoading: true; printErrors: false }
}
