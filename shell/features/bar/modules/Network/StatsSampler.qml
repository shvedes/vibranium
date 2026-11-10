// Shared link-throughput sampler for the Network module and its island.
//
// Both surfaces read the same two things off the active route: the interface
// the kernel would use for 1.1.1.1, resolved by `ip` on its own argv, and the
// two /sys byte counters of that interface. What differs between them is the
// cadence they ask at, not the reading, so the reading lives here once.
//
// A generated sysfs counter holds content from the moment it exists and raises
// no filesystem event when that content moves, so a watcher on it can never
// fire - the value comes from a read, and `blockLoading` keeps that read on the
// calling turn instead of deferring it behind a job.
import QtQuick
import Quickshell.Io
import "Model.js" as Model

Item {
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

  // Ask for one route read. The reply lands in noteRoute; a consumer decides
  // how often it asks, this only refuses to stack two reads.
  function requestRoute() {
    if (!routeProc.running) routeProc.running = true
  }

  // Drop the route child. Called when the surface that owns the sampler goes
  // away: a reply landing after close would find state nobody is reading.
  function stop() {
    if (routeProc.running) routeProc.running = false
  }

  // The zero reading a fresh hover starts from, so the graph never opens on
  // the previous hover's rates. A cleared interface is the "route unknown"
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
    // waiting for the next tick would hold the metrics empty for another 0.5s
    // after a surface opens. A changed interface re-seeds the throughput
    // baseline anyway, so the back-to-back pair cannot manufacture a rate out
    // of a short interval.
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
