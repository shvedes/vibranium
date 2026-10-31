pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import Quickshell.Io
import qs.common
import "../../common/text/UnitIpc.js" as UnitIpc
import "PrintersLib.js" as Model

// CUPS queue service. Reads printers + not-completed jobs over IPP with
// ipptool templates colocated in ipptool/, and watches org.cups.cupsd.Notifier
// on the system bus for the events that say to read again. All user-scoped
// operations pass requesting-user-name; printer-level admin ops
// (pause/accept/set-default) are deliberately not attempted - unauthenticated
// IPP rejects them.
//
// Two transports, and they are not the same kind of thing:
//
//   IPP is the only request/reply channel. Every read and every action is a
//   `timeout 10 ipptool -tv` child, so a call here is a fork and the reply is
//   the child's exit code plus a report on stdout. There is no Quickshell
//   CUPS service and no busctl/gdbus call anywhere in this file.
//
//   D-Bus is events only, one direction. `dbus-monitor` subscribes to
//   org.cups.cupsd.Notifier and nothing else; the shell never makes a D-Bus
//   call, so a signal is never answered here.
//
// Measured on this box (cups 2:2.4.19-1): cupsd claims no well-known bus name
// (it is :1.12 and `gdbus introspect --dest org.cups.cupsd` answers
// ServiceUnknown), and the Notifier signal arrives from a throwaway
// connection - a unique name already gone from `busctl --system list` by the
// time anyone looks - so the sender is not even a stable identity for cupsd.
// The path (`/org/cups/cupsd/Notifier`), the interface and the member are the
// stable parts, and those are what a signal is matched on.
Singleton {
  id: root

  readonly property string tag: "printers"

  readonly property string _notifierInterface: "org.cups.cupsd.Notifier"
  // The match rule the monitor subscribes with. Plain match rules need no
  // privilege (BecomeMonitor does).
  readonly property string _notifierMatch: "type='signal',interface='org.cups.cupsd.Notifier'"

  // idle -> loading -> ready | error
  property string state: "idle"
  // Parsed printer rows (Model.parseReport output).
  property var printers: []
  // Parsed job rows (which-jobs all: in-flight plus history), active
  // first, then newest creation first. Each row gains a `printer` key
  // derived from the job-printer-uri tail.
  property var jobs: []
  // User default printer (lpstat -d); "" when none.
  property string defaultPrinter: ""
  // Refresh-level failure ("cupsd unreachable"); island renders it.
  property string errorText: ""
  // Last failed job action, as the IPP status-code token.
  property string actionError: ""
  // Local display aliases: queueName -> label (ShellState section
  // "printers", key "aliases"). Pure display; queue names stay canonical.
  property var aliases: ({})

  // Jobs as shown (server rows minus locally cleared history): every
  // indicator below - bar icon, tooltip count, green check - reads this,
  // so clearing a failed entry clears the red icon along with it.
  readonly property var shownJobs: Model.filterDismissed(root.jobs, root.dismissed)
  readonly property bool hasActiveJobs: Model.activeJobs(root.shownJobs).length > 0
  readonly property bool vmUnavailable: Quickshell.env("CHASSIS_TYPE") === "vm"
  // Any job actually printing right now (drives the bar icon flash).
  readonly property bool anyPrinting: Model.anyPrinting(root.shownJobs)
  // Any failed job (canceled/aborted) or stopped printer.
  readonly property bool anyFailed: root.shownJobs.length > 0
    ? Model.failedJobs(root.shownJobs)
    : root.printers.some(p => Model.printerIsDown(p))
  // At least one finished job still listed since the queue last cleared
  // (drives the green check per the user's spec). An empty list always
  // reads as plain idle, never done.
  property bool _recentlyDone: false
  readonly property bool allDone: root.shownJobs.length > 0 && root.printers.length > 0
    && !root.anyFailed && !root.hasActiveJobs && root._recentlyDone
  // User-set display aliases survive shell restarts via ShellState.
  readonly property var _aliasState: ShellState.section("printers")
  on_AliasStateChanged: root.aliases = Model.aliasesFrom(root._aliasState)

  // requesting-user-name for every IPP op; must be identical across
  // create/list/renew/cancel so subscriptions stay owned by us.
  function _userName(): string {
    const u = Quickshell.env("USER")
    return u !== "" ? u : "vibranium"
  }

  // --- refresh ---

  property bool _refreshing: false
  property bool _ippFailed: false
  property int _pendingReads: 0

  // CUPS liveness: "unknown" until the first check lands, then "ok",
  // "inactive" (unit present but neither service nor socket runs) or
  // "missing" (no cups unit at all - package not installed). The island
  // renders the warning block off this; "unknown" behaves like "ok" so
  // a slow first check never flashes the warning on a healthy box.
  property string cupsHealth: "unknown"

  function refresh() {
    if (root.vmUnavailable) return
    // Single-flight: a second ask is dropped rather than queued.
    if (root._refreshing) return
    root._refreshing = true
    root._ippFailed = false
    root._pendingReads = 3
    root.errorText = ""
    root.state = "loading"
    // Pre-refresh snapshot anchors the completion toast diff and the job
    // lines; `_prevPrinterStates` anchors the printer-state lines for the same
    // reason, and `_prevPrinterEnums` the untranslated token behind each of
    // those labels. All three are answered from the NEXT refresh, because this
    // service polls: nothing announces a state change, so the previous read is
    // the only record of what it was.
    root._prevJobs = root.jobs
    root._prevPrinterStates = Model.printerStates(root.printers)
    root._prevPrinterEnums = root._enums(root.printers, "printer-name", "printer-state")
    root.runIpp("printers.test", { user: root._userName() }, "ipp://localhost/", root._applyPrinters)
    root.runIpp("jobs.test", { user: root._userName() }, "ipp://localhost/", root._applyJobs)
    _defaultProc.running = true
    // Liveness alongside the reads (never blocks them): our own IPP
    // traffic socket-activates cupsd when cups.socket listens, so a
    // listening socket counts as healthy too - not just a running
    // service. Re-runs every refresh so installing/starting CUPS
    // mid-session clears the island warning on its own.
    if (!_healthProc.running) _healthProc.running = true
  }

  // `systemctl is-active` prints one state per unit ("active",
  // "inactive", "unknown", ...) and exits nonzero unless all are
  // active - so the lines parse regardless of the exit code. No lines
  // at all means the check itself could not run (no systemd); health
  // stays "unknown" and nothing changes.
  //
  // The exit code means nothing for THIS probe: three units active exits 0
  // and two-of-three exits 3, which is the same figure as "the check could
  // not run". So the unit lines are the verdict and the code is ignored.
  Process {
    id: _healthProc

    command: ["systemctl", "is-active", "cups.service", "cups.socket"]
    stdout: StdioCollector {
      id: _healthOut

      waitForEnd: true
    }
    onExited: {
      const lines = String(_healthOut.text || "").split("\n")
        .map(s => s.trim()).filter(s => s !== "")
      if (lines.length === 0) return
      if (lines.indexOf("active") !== -1) root.cupsHealth = "ok"
      else if (lines.indexOf("unknown") !== -1) root.cupsHealth = "missing"
      else root.cupsHealth = "inactive"
    }
  }

  function _readDone() {
    root._pendingReads--
    if (root._pendingReads > 0) return
    root._refreshing = false
    root.state = root._ippFailed ? "error" : "ready"
    root._diffToast()
    root._ensureSubscriptions()
  }

  function _applyPrinters(code, text) {
    // Zero printers is a valid answer: cupsd replies client-error-not-found
    // ("No destinations added") once the last queue is deleted, which
    // ipptool reports as FAIL - so rows parse on exit 0 OR on that status.
    // Treating it as a failure kept a deleted printer's ghost row alive
    // (and every action on it silently no-oped).
    const rows = Model.parseReport(text, "printer-name")
      .filter(p => String(p["printer-name"] ?? "") !== "")
    const st = Model.statusCode(text)
    if (code !== 0 && st !== "client-error-not-found") {
      root._ippFailed = true
      root.errorText = "cupsd unreachable"
    } else {
      root.printers = rows
      root._logPrinterStates()
    }
    root._readDone()
  }

  function _applyJobs(code, text) {
    const rows = Model.parseReport(text, "job-id")
      .filter(j => String(j["job-id"] ?? "") !== "")
    for (let i = 0; i < rows.length; i++) {
      const uri = String(rows[i]["job-printer-uri"] || "")
      rows[i].printer = uri.substring(uri.lastIndexOf("/") + 1)
    }
    rows.sort((a, b) => {
      const aa = Model.isActiveJobState(a["job-state"]) ? 0 : 1
      const bb = Model.isActiveJobState(b["job-state"]) ? 0 : 1
      if (aa !== bb) return aa - bb
      return Number(b["time-at-creation"] || 0) - Number(a["time-at-creation"] || 0)
    })
    root.jobs = rows
    root._logQueuedJobs()
    root._pruneDismissed()
    // Green check state per the user spec: it lights when jobs finish and
    // holds until new work arrives (a fresh in-flight entry clears it).
    // History rows (completed/canceled) must not clear it on their own.
    if (Model.activeJobs(rows).length > 0) root._recentlyDone = false
    if (code !== 0) {
      root._ippFailed = true
      if (root.errorText === "") root.errorText = "cupsd unreachable"
    }
    root._readDone()
  }

  function _applyDefault(text) {
    const m = /system default destination: (.+)/.exec(String(text || ""))
    root.defaultPrinter = m ? m[1].trim() : ""
    root._readDone()
  }

  // --- completion toasts ---
  // The Notifier event body is not parsed; the refresh diff is the truth.
  // Only a refresh that saw a JobCompleted header diffs. A previously
  // in-flight job that now reads completed (or vanished, when cupsd keeps no
  // history) toasts and lights the green check - cancel is not a completion
  // and never toasts.

  property var _prevJobs: []
  property var _prevPrinterStates: ({})
  // The untranslated printer-state per queue, anchored exactly like
  // `_prevPrinterStates` and snapshotted from the same read. It answers the
  // question the label map cannot once the read is over, which is why it is a
  // snapshot and not a lookup into `printers`: the "from" end of a transition
  // is by definition a state this service no longer holds anywhere else.
  property var _prevPrinterEnums: ({})
  property bool _completedSeen: false

  // --- what the queue did, as a diff against the previous read ---------------
  //
  // The diffs themselves are `PrintersLib` functions and are unit-tested there.
  // That split is the point: a transition computed against the wrong previous
  // read is a true sentence about a false event, and only a pure function over
  // two reads can be pinned. Here they are only emitted.
  //
  // Everything reported is generic by request - a queue name, a job id, a state.
  // NOT the job title: that is a document name the user chose, it is the one
  // field here that says what somebody was working on, and the toast is where it
  // belongs.

  // _enums(rows, anchorAttr, field) -> id -> that one attribute, untranslated.
  //
  // The keys are the same anchors the two diff functions key their maps by, on
  // purpose: a projection keyed differently from the diff it sits beside would
  // pair an INFO line with the raw value of a DIFFERENT queue, which is worse
  // than printing nothing. `ipptool -tv` renders these enums symbolically, so
  // the value is usually a word and not a digit - which is what makes it worth
  // keeping, because a label the table has no entry for can only be explained
  // by the token it failed on.
  //
  // Deliberately a projection here rather than another `PrintersLib` export.
  // That library exists to hold the parts of the diff that can be wrong in a way
  // nobody notices, and this reads nothing and decides nothing: dropping it
  // would cost a diagnostic and no correctness at all, while adding it would
  // widen the pinned surface for no unit-testable gain.
  function _enums(rows, anchorAttr, field) {
    const out = {}
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i]
      if (!row || typeof row !== "object") continue
      const id = String(row[anchorAttr] ?? "")
      if (id === "") continue
      out[id] = String(row[field] ?? "")
    }
    return out
  }

  // _token(value) -> the untranslated state as it will be printed, bounded.
  //
  // One sentinel for every end of every transition, because the three ways an
  // end can be unreadable are three different sentences: `?` is an attribute
  // the report never carried, "gone" is a queue that left and "absent" is a job
  // cupsd dropped. Rendering the missing attribute as a blank instead would
  // make it indistinguishable from a state the label table had no word for,
  // which is the exact confusion these lines exist to resolve.
  function _token(value) {
    const v = String(value ?? "")
    return v === "" ? "?" : Log.summarize(v)
  }

  // Printer state as a TRANSITION, so "went offline" is the fact rather than
  // "is offline", which a reader would otherwise have to diff by hand. Both ends
  // are CUPS printer-state labels, so the vocabulary is CUPS's and not ours.
  //
  // A printer that JOINS is not reported: it has no previous state, so there is
  // no transition to state. A printer that LEAVES is, with `to` null.
  function _logPrinterStates() {
    const next = Model.printerStates(root.printers)
    const moves = Model.printerStateTransitions(root._prevPrinterStates, next)
    // One gate for the whole read rather than one per transition: the projection
    // is built once either way, so a gate inside the loop would ask the same
    // question N times and still pay for the map. A read that moved nothing
    // builds nothing at all, which is the common case - this service polls, and
    // most polls find exactly what the last one found.
    const d = Log.at()
    const tokens = moves.length > 0 && d.allows("debug")
    const enums = tokens
      ? root._enums(root.printers, "printer-name", "printer-state") : {}
    for (let i = 0; i < moves.length; i++) {
      const m = moves[i]
      Log.info("printer " + m.printer + ": " + m.from + " > "
        + (m.to === null ? "gone" : m.to))
      if (!tokens) continue
      // The tokens both labels above were looked up from. A transition reported
      // as "Idle > Unknown" is otherwise unanswerable from the log: the label
      // says the table missed, and only the server's own token says what it
      // said instead. Bounded because these are attribute values from outside
      // the process, not one of our own strings.
      d.debug("printer " + m.printer + " states: "
        + _token(root._prevPrinterEnums[m.printer])
        + " > " + (m.to === null ? "gone" : _token(enums[m.printer])))
    }
    // The poll cadence is invisible in every other line here: this is the only
    // place that knows how big the read the diff was taken against was, which
    // is what tells a reader whether a missing transition was a change or a
    // gap between two polls.
    Log.debug("read: " + root.printers.length + " queues, "
      + root._prevPrinterStates.length + " before, " + moves.length + " moved")
    root._prevPrinterStates = next
  }

  // A job id that was not in the previous read is new work. The first read
  // yields nothing, for the same reason the printer diff does: it is CUPS's
  // history, not something this shell watched being queued.
  function _logQueuedJobs() {
    const fresh = Model.queuedJobs(root._prevJobs, root.jobs)
    // One gate for the read, for the same reason the printer diff takes it: the
    // whole job list is walked to build this map, and a poll that queued nothing
    // is the case that must not pay for it.
    const d = Log.at()
    const tokens = fresh.length > 0 && d.allows("debug")
    const enums = tokens ? root._enums(root.jobs, "job-id", "job-state") : {}
    for (let i = 0; i < fresh.length; i++) {
      Log.info("queued job " + fresh[i].id + " on " + (fresh[i].printer || "?")
        + ", active " + fresh[i].active)
      if (!tokens) continue
      // The state the job arrived in, which is the one member of the new job's
      // row the INFO line does not carry and the one the island's spinner keys
      // off: pending and processing are both "in flight" for the active count
      // and are not the same thing on screen, so a spinner that never starts
      // next to "active 1" is explained here and nowhere else. The title is
      // still absent, and stays absent.
      d.debug("queued job " + fresh[i].id + " arrived in state "
        + _token(enums[fresh[i].id]))
    }
    Log.debug("job read: " + root.jobs.length + " listed, " + fresh.length + " new")
  }

  function _diffToast() {
    if (!root._completedSeen) return
    root._completedSeen = false
    const prev = root._prevJobs
    if (prev.length === 0) return
    // At least one job crossed to completed: light the green check
    // (per the user's spec it holds until new work arrives again).
    let finished = false
    for (let i = 0; i < prev.length; i++) {
      const old = prev[i]
      if (!Model.isActiveJobState(old["job-state"])) continue
      const id = String(old["job-id"])
      let cur = null
      for (let j = 0; j < root.jobs.length; j++) {
        if (String(root.jobs[j]["job-id"]) === id) {
          cur = root.jobs[j]
          break
        }
      }
      const st = cur ? Model.jobStateNum(cur["job-state"]) : -1
      if (st === 9 || cur === null) {
        finished = true
        // In the toast branch rather than beside it, so the line and the toast
        // can never disagree about which jobs finished: this is the only place
        // in the service that decides that.
        //
        // `cur === null` means the job left the queue entirely - CUPS drops
        // finished jobs from its history - which is a completion too, and one
        // no state field describes.
        Log.info("completed job " + id + " on " + String(old.printer || "?")
          + ", " + (cur === null ? "left queue" : Model.jobStateLabel(cur["job-state"])))
        // Both states of the crossing, because the destination alone cannot
        // distinguish the two things that finish a job. A job that ran
        // 5 > 9 printed normally; one that went 3 > absent between two polls
        // never occupied the printer as far as this shell could see, which is
        // the difference between a working queue and one that swallowed a job
        // whole. The absent end is spelled rather than left blank because a
        // blank and a state the table had no word for would read the same.
        const d = Log.at()
        if (d.allows("debug")) {
          d.debug("completed job " + id + " states: "
            + _token(old["job-state"])
            + " > " + (cur === null ? "absent" : _token(cur["job-state"])))
        }
        root._toast("Print job finished",
          String(Model.jobTitle(old) || "Job") + " on " + String(old.printer || ""))
      }
    }
    if (finished) root._recentlyDone = true
  }

  function _toast(summary, body) {
    _notifyProc.command = ["notify-send", "-a", "Vibranium", "-t", "8000", summary, body]
    _notifyProc.running = true
  }

  // --- IPP process layer ---

  // One dynamic process per op: timeout + ipptool -tv + -d defs + uri +
  // template. onDone(exitCode, stdoutText); the process destroys itself.
  //
  // Every call this service makes goes through here. A call is a fork and the
  // reply is the child's exit code plus a report on stdout: an exited ipptool
  // with exit 0 is a reply, and a Process that has not exited has done nothing
  // at all.
  //
  // The only deadline is coreutils `timeout 10` on the argv. There is no
  // in-process timer, so a call that never answers arrives as exit 124 after
  // ten seconds and nothing else.
  function runIpp(testFile, defs, uri, onDone) {
    if (root.vmUnavailable) return
    const argv = ["timeout", "10", "ipptool", "-tv"]
    for (const key in defs) argv.push("-d", key + "=" + defs[key])
    argv.push(uri, Qt.resolvedUrl("ipptool/" + testFile).toString().replace(/^file:\/\//, ""))
    const proc = _ippComp.createObject(root, { command: argv })
    if (!proc) {
      // The shell failing to build a Process at all. onDone(1, "") answers the
      // caller rather than leaving the read pending forever.
      if (onDone) onDone(1, "")
      return
    }
    proc.onDone = onDone
    proc.running = true
  }

  Component {
    id: _ippComp

    Process {
      id: proc

      property var onDone: null

      stdout: StdioCollector {
        id: out

        waitForEnd: true
      }
      onExited: (code) => {
        if (proc.onDone) proc.onDone(code, out.text)
        proc.destroy()
      }
    }
  }

  // lpstat -d readback (user default printer).
  Process {
    id: _defaultProc

    command: ["timeout", "10", "lpstat", "-d"]

    stdout: StdioCollector {
      id: defaultOut

      waitForEnd: true
    }
    onExited: root._applyDefault(defaultOut.text)
  }

  // notify-send for the completion toast. Fire and forget: nothing here reads
  // its exit, and a failing toast costs the user one notification.
  Process {
    id: _notifyProc

    stdout: StdioCollector {}
  }

  // --- Notifier watcher ---
  // dbus-monitor with an interface match rule: plain match rules need no
  // privilege (BecomeMonitor does). cupsd claims no well-known bus name,
  // so gdbus monitor --dest cannot resolve it. The eavesdrop-fallback
  // banner and the NameAcquired block carry no "member=", so the first
  // guard skips them; event header lines carry member= plus the
  // interface.

  property int _monitorFails: 0

  function _spawnMonitor() {
    _monitorProc.running = true
  }

  Process {
    id: _monitorProc

    command: ["dbus-monitor", "--system", root._notifierMatch]
    stdout: SplitParser {
      onRead: data => root._onMonitorLine(data)
    }
    onExited: {
      // Bus restart or a killed monitor would silently freeze the
      // queue view; respawn with backoff. Fast-fail (missing binary,
      // no system bus) backs off to a minute instead of spinning.
      root._monitorFails++
      const delay = Math.min(60000, 1000 * Math.pow(4, root._monitorFails - 1))
      _monitorRespawn.interval = delay
      _monitorRespawn.restart()
    }
  }

  // Monitor respawn seed, named: reassigned from the backoff on every
  // failure, so the seed only covers the first spawn.
  readonly property int monitorRespawnSeedMs: 1000
  Timer {
    id: _monitorRespawn

    interval: root.monitorRespawnSeedMs
    onTriggered: {
      if (!_monitorProc.running) root._spawnMonitor()
      // Subscriptions die with a cupsd restart; re-discover after the
      // monitor is back too.
      root._ensureSubscriptions()
    }
  }

  // dbus-monitor prints one line per D-Bus message, then one line per
  // argument. A header line begins with the message kind; anything else is an
  // argument of the message above it. The header's trailing fields are
  // space-separated `key=value` pairs terminated with `;` - the measured form
  // is `path=/org/cups/cupsd/Notifier; interface=org.cups.cupsd.Notifier;
  // member=PrinterStateChanged` - so the semicolon is part of the value the
  // naive split returns, and an interface read without stripping it compares
  // unequal to the interface this file asked for. Matching `member=` as a
  // substring is worse: `member=JobState` would match `member=JobStateChanged`.
  //
  // Only the header is read. The body says what changed, and the next IPP read
  // says it authoritatively, so an argument line carries nothing this service
  // acts on.
  function _onMonitorLine(line) {
    const text = String(line || "")
    if (!/^(signal|method_call|method_return|error)\s/.test(text)) return
    if (root._dbusField(text, "interface") !== root._notifierInterface) return
    const member = root._dbusField(text, "member")
    if (member === "") return
    // Reset here rather than on any other path: the backoff counter is about
    // the monitor's own health, and a monitor that is attaching and receiving
    // is healthy whatever it carries.
    root._monitorFails = 0
    if (member === "JobCompleted") root._completedSeen = true
    // Restarted on the header, not after the body: the refresh does not care
    // what the signal says, and waiting for the last argument would put a
    // queue that never finishes printing behind the coalesce window.
    _coalesceTimer.restart()
  }

  // Fixed-key field read without a per-line RegExp: the value is the
  // whitespace-delimited run after `key=`, which must start the line or
  // follow whitespace so `member=` never matches inside `othermember=`.
  function _dbusField(header, key) {
    const text = String(header || "")
    const needle = key + "="
    let at = text.indexOf(needle)
    while (at > 0) {
      const prev = text.charAt(at - 1)
      if (prev === " " || prev === "\t") break
      at = text.indexOf(needle, at + 1)
    }
    if (at < 0) return ""
    let stop = at + needle.length
    while (stop < text.length && text.charAt(stop) !== " " && text.charAt(stop) !== "\t") stop++
    let value = text.substring(at + needle.length, stop)
    // Every field but the last carries its own `;` terminator; without this
    // the interface never equals the interface and no signal is ever ours.
    if (value.charAt(value.length - 1) === ";") value = value.substring(0, value.length - 1)
    return value
  }

  // One event burst (a submit fires JobCreated + JobState + printer
  // events) coalesces into exactly one refresh.
  // Coalesce window, named: one refresh per burst of bus events.
  readonly property int coalesceWindowMs: 250
  Timer {
    id: _coalesceTimer

    interval: root.coalesceWindowMs
    onTriggered: root.refresh()
  }

  // Safety poll while jobs exist: a monitor gap between respawns must
  // not freeze the queue view for longer than a minute. Named cadence.
  readonly property int safetyPollMs: 60000
  Timer {
    interval: root.safetyPollMs
    running: root.hasActiveJobs
    repeat: true
    onTriggered: root.refresh()
  }

  // --- subscriptions ---
  // One dbus:// subscription per printer, leased 24 h, marked with the
  // VB01- user-data prefix. On startup (and after every monitor respawn)
  // Get-Subscriptions re-discovers ours: stale VB01- subs from a crashed
  // shell are cancelled, a missing sub is created. Subs are renewed every
  // 12 h - half the lease, so one missed renewal never drops them.

  property var _subs: ({})       // printerName -> subId
  property var _subWork: []      // printer names still to check

  function _ensureSubscriptions() {
    if (root.vmUnavailable) return
    const live = {}
    for (let i = 0; i < root.printers.length; i++) {
      const n = String(root.printers[i]["printer-name"] || "")
      if (n !== "") live[n] = true
    }
    // Queue vanished (deleted while we ran): drop its subscription id so
    // the next refresh re-creates subscriptions only for real printers.
    let changed = false
    const next = {}
    for (const name in root._subs) {
      if (live[name]) next[name] = root._subs[name]
      else changed = true
    }
    if (changed) root._subs = next
    root._subWork = Object.keys(live)
    root._subNext()
  }

  function _subNext() {
    if (root._subWork.length === 0) return
    const name = root._subWork.shift()
    const puri = "ipp://localhost/printers/" + name
    root.runIpp("sub-list.test", { user: root._userName(), puri: puri }, puri,
      (code, text) => root._applySubList(code, text, name))
  }

  function _applySubList(code, text, name) {
    // Empty sub list is a normal answer: cupsd replies client-error-not-found
    // ("No subscriptions found"), which ipptool reports as FAIL - so the
    // rows parse on exit 0 OR on that specific status.
    const st = Model.statusCode(text)
    if (code === 0 || st === "client-error-not-found") {
      const rows = Model.parseReport(text, "notify-subscription-id")
        .filter(s => String(s["notify-subscription-id"] ?? "") !== "")
      let mine = null
      const puri = "ipp://localhost/printers/" + name
      for (let i = 0; i < rows.length; i++) {
        const id = String(rows[i]["notify-subscription-id"] || "")
        const ud = String(rows[i]["notify-user-data"] || "")
        if (ud.indexOf("VB01-") !== 0) continue
        if (String(root._subs[name]) === id) {
          mine = id
        } else {
          // Stale sub from a crashed shell (id not in our registry).
          root.runIpp("sub-cancel.test", { user: root._userName(), puri: puri, subid: id }, puri, null)
        }
      }
      if (mine === null) {
        root.runIpp("sub-create.test", { user: root._userName(), puri: puri }, puri,
          (ccode, ctext) => root._applySubCreate(ccode, ctext, name))
      }
    }
    root._subNext()
  }

  function _applySubCreate(code, text, name) {
    if (code !== 0) return
    const rows = Model.parseReport(text, "notify-subscription-id")
    if (rows.length === 0) return
    const next = Object.assign({}, root._subs)
    next[name] = String(rows[0]["notify-subscription-id"] || "")
    root._subs = next
  }

  // Subscription lease renewal, named: 12h against a 24h lease.
  readonly property int leaseRenewMs: 43200000
  Timer {
    id: _renewTimer

    interval: root.leaseRenewMs
    running: root.state === "ready" && root.printers.length > 0
    repeat: true
    onTriggered: {
      for (const name in root._subs) {
        const puri = "ipp://localhost/printers/" + name
        root.runIpp("sub-renew.test",
          { user: root._userName(), puri: puri, subid: String(root._subs[name]) }, puri, null)
      }
    }
  }

  // --- actions ---

  function _jobAction(testFile, printerName, jobId) {
    const puri = "ipp://localhost/printers/" + printerName
    root.runIpp(testFile, { user: root._userName(), puri: puri, jobid: String(jobId) }, puri,
      (code, text) => {
        const st = Model.statusCode(text)
        // Clear at the start of every action, set on failure: the action's own
        // follow-up refresh must not wipe a fresh error. A job that already
        // vanished (completed and purged between listing and clicking) is the
        // desired end state, not an error; anything else that failed keeps the
        // IPP status token on screen.
        root.actionError = (code !== 0 && st !== "client-error-not-found")
          ? (st || "ipptool failed") : ""
        _coalesceTimer.restart()
      })
  }

  function holdJob(printerName, jobId) {
    root._jobAction("hold.test", printerName, jobId)
  }

  function releaseJob(printerName, jobId) {
    root._jobAction("release.test", printerName, jobId)
  }

  function cancelJob(printerName, jobId) {
    root._jobAction("cancel-job.test", printerName, jobId)
  }

  // Locally cleared history entries: CUPS has no unprivileged per-job
  // history delete (Cancel-Job rejects terminal jobs with
  // client-error-not-possible, and Purge-Jobs would also kill in-flight
  // prints while needing admin), so finished entries the user clears
  // are hidden here instead. job-id -> true, persisted in the section
  // like aliases, pruned against server truth on every refresh.
  property var dismissed: ({})

  function _loadDismissed() {
    const s = root._aliasState && typeof root._aliasState === "object"
      ? root._aliasState.dismissed : undefined
    root.dismissed = (s && typeof s === "object") ? s : {}
  }

  function _saveDismissed() {
    ShellState.updateSection("printers", { dismissed: root.dismissed })
  }

  function _pruneDismissed() {
    const live = {}
    for (let i = 0; i < root.jobs.length; i++)
      live[String(root.jobs[i]["job-id"])] = true
    const next = {}
    let changed = false
    for (const id in root.dismissed) {
      if (live[id]) next[id] = true
      else changed = true
    }
    if (changed) {
      root.dismissed = next
      root._saveDismissed()
    }
  }

  // Clear one finished entry. Active jobs always go through the server
  // cancel above - server truth for in-flight work is never hidden.
  function dismissJob(jobId) {
    const id = String(jobId ?? "")
    if (id === "") return
    const row = root.jobs.find(j => String(j["job-id"]) === id)
    // A dismiss on a job that is not in the list, or on one still in the
    // queue, is refused: the click does nothing.
    if (!row) return
    if (Model.isActiveJobState(row["job-state"])) return
    const next = Object.assign({}, root.dismissed)
    next[id] = true
    root.dismissed = next
    root._saveDismissed()
    root._maybeAllDone(next)
  }

  // Clear every finished entry at once (the JOBS header button).
  function dismissFinished() {
    const next = Object.assign({}, root.dismissed)
    for (let i = 0; i < root.jobs.length; i++) {
      const j = root.jobs[i]
      if (Model.isActiveJobState(j["job-state"])) continue
      next[String(j["job-id"])] = true
    }
    root.dismissed = next
    root._saveDismissed()
    root._maybeAllDone(next)
  }

  // A clear that leaves the visible queue with no active and no failed
  // work lights the green check: what remains is all completed.
  // Computed off the passed map (not the bindings - those settle after
  // this call returns).
  function _maybeAllDone(next) {
    const shown = Model.filterDismissed(root.jobs, next)
    const active = Model.activeJobs(shown).length > 0
    const failed = shown.length > 0
      ? Model.failedJobs(shown)
      : root.printers.some(p => Model.printerIsDown(p))
    if (!active && !failed) root._recentlyDone = true
  }

  // --- external tool layer ---
  //
  // Every tool call below is fire-and-forget: Exec owns the child and destroys
  // it on exit, no callback reads state back, so nothing here is gated.
  //
  // "Connect" in user space: set the user default printer.
  function connectPrinter(name) {
    Exec.run(["lpoptions", "-d", name])
    _coalesceTimer.restart()
  }

  // Inline rename: local alias only (CUPS has no queue rename; the
  // canonical lpadmin -R name never changes). Empty string clears it;
  // an empty queue name is rejected (guards a race where the row
  // vanished between the click and the commit).
  function setPrinterAlias(name, label) {
    const qname = String(name ?? "").trim()
    if (qname === "") return false
    const clean = String(label ?? "").trim()
    const cur = Object.assign({}, root.aliases)
    if (clean === "") delete cur[qname]
    else cur[qname] = clean
    root.aliases = cur
    ShellState.updateSection("printers", { aliases: cur })
    return true
  }

  // Remove a printer queue (lpadmin -x; works unprivileged - verified).
  function removePrinter(name) {
    Exec.run(["lpadmin", "-x", name])
    _coalesceTimer.restart()
  }

  // Print settings: the system-config-printer main window with no name,
  // that printer's own options page (CUPS web UI) with one.
  // system-config-printer's CLI cannot deep-link a printer's properties
  // (only --show-jobs for the queue window), so the per-printer target
  // is http://localhost:631/printers/<name> - the page carrying that
  // queue's defaults, jobs and administration.
  function openPrinterConfig(name) {
    if (name === "") {
      Exec.run(["system-config-printer"])
      return
    }
    Exec.run(["xdg-open", "http://localhost:631/printers/" + encodeURIComponent(String(name))])
  }

  // Test page: armed then confirmed within 3 s (two presses), then a
  // fresh arm is required. Arm state clears on queue change/close.
  property string _testArm: ""
  // Read-only view for the island's armed-color binding.
  readonly property alias testArm: root._testArm
  function armTestPage(name): bool {
    if (root._testArm === name) return false
    root._testArm = name
    _testArmTimer.restart()
    return true
  }

  // Test-page source. Lives here (not inline) so the Paths.cupsTestPage
  // migration lands on one binding: today Paths has no such member, so
  // the default preserves the CUPS-shipped path byte for byte.
  readonly property string testPageFile: "/usr/share/cups/data/default-testpage.pdf"
  // Test-arm hold, named: 3s.
  readonly property int testArmMs: 3000
  function printTestPage(name) {
    root._testArm = ""
    _testArmTimer.stop()
    Exec.run(["lp", "-d", name, root.testPageFile])
    _coalesceTimer.restart()
  }

  Timer {
    id: _testArmTimer

    interval: root.testArmMs
    onTriggered: root._testArm = ""
  }

  // --- IPC ---

  IpcHandler {
    target: "printers"

    function help(command: string): string {
      return UnitIpc.help("printers", "Printers", "CUPS queues", [
        { name: "refresh", help: "re-read printers and jobs" },
        { name: "connect", help: "set the user default printer: connect <name>" },
        { name: "hold", help: "hold a job: hold <printer> <jobid>" },
        { name: "release", help: "release a job: release <printer> <jobid>" },
        { name: "cancel", help: "cancel a job: cancel <printer> <jobid>" },
        { name: "dismiss", help: "clear a finished entry: dismiss <jobid>" },
        { name: "clear", help: "clear all finished entries" },
        { name: "rename", help: "set a local display alias: rename <name> <label>" },
        { name: "remove", help: "delete a printer queue: remove <name>" },
        { name: "config", help: "open print settings: config [name]" }
      ], command)
    }

    function status(): string {
      return JSON.stringify({
        unit: "printers",
        state: root.state,
        printers: root.printers.length,
        jobs: root.jobs.length,
        defaultPrinter: root.defaultPrinter
      })
    }

    function ping(): string { return "pong" }

    function refresh(): string {
      root.refresh()
      return "ok"
    }

    function connect(name: string): string {
      root.connectPrinter(name)
      return "ok"
    }

    function hold(printer: string, jobid: string): string {
      root.holdJob(printer, jobid)
      return "ok"
    }

    function release(printer: string, jobid: string): string {
      root.releaseJob(printer, jobid)
      return "ok"
    }

    function cancel(printer: string, jobid: string): string {
      root.cancelJob(printer, jobid)
      return "ok"
    }

    function dismiss(jobid: string): string {
      root.dismissJob(jobid)
      return "ok"
    }

    function clear(): string {
      root.dismissFinished()
      return "ok"
    }

    function rename(name: string, label: string): string {
      root.setPrinterAlias(name, label)
      return "ok"
    }

    function remove(name: string): string {
      root.removePrinter(name)
      return "ok"
    }

    function config(name: string): string {
      root.openPrinterConfig(name)
      return "ok"
    }
  }

  // --- boot lifecycle ---

  Component.onCompleted: {
    // A guest has no CUPS to talk to: the unit registers nothing and answers
    // no IPC verb.
    if (root.vmUnavailable) return
    // The section-change handler only fires on writes; load the initial
    // aliases (persisted from a previous session) here.
    root.aliases = Model.aliasesFrom(root._aliasState)
    root._loadDismissed()
    Registry.offer("printers", {
      title: "Printers",
      description: "CUPS queues",
      verbNames: ["refresh", "connect", "hold", "release", "cancel", "dismiss", "clear", "rename", "remove", "config", "status", "help", "ping"]
    })
    Registry.register(root.tag, root)
    root.refresh()
    root._spawnMonitor()
  }
}
