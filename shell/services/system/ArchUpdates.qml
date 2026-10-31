pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import Quickshell.Io
import qs.common
import "../../common/text/UnitIpc.js" as UnitIpc
import "../../common/text/StringUtils.js" as SU
import "ArchUpdatesLib.js" as ArchUpdatesLib

// Arch updates service. Singleton that fetches official Arch repository
// updates via checkupdates (fakeroot pacman -Sy into a temp db, safe) and
// AUR updates via yay -Qua in parallel, each wrapped in a `timeout` so a
// dead mirror or an unreachable AUR RPC can never hang the shell. Parses
// in JS without AWK, refreshes every 30 minutes with a single-flight guard,
// and exposes IPC refresh/update.
//
// The two fetches run side by side and merge on completion. A failed AUR
// check is tolerated (official updates still show, with a note); a failed
// official check flips the whole state to error.
//
// Notification surface: when a refresh lands on a heavy backlog (more than
// notifyThreshold pending updates) and the persistent suppression window
// has expired, a freedesktop notification goes out under the app name
// "Vibranium" with two actions: "Ignore"
// (silence for three real days) and "Update Now" (opens the full-system
// updater in a terminal). Closing or timing out without pressing a button
// silences it for 24 hours. The window lives as a unix timestamp
// ("nextNotify" in the "archUpdates" section of $VIBRANIUM_CACHE/shell.json
// via ShellCache), so restarts compare against the same value and an ignored
// notification never re-shows early. The notification itself stays up for
// 5 minutes; a one-shot timer re-checks exactly when the window expires
// instead of waiting for the 30-minute refresh cadence.
Singleton {
  id: root

  readonly property string tag: "archUpdates"

  // Pending-update count a refresh must exceed before the update-available
  // notification fires. At or below it a refresh stays silent and writes
  // no suppression window; mirrors the island's heavy-queue bar.
  readonly property int notifyThreshold: 125

  // In-memory result contract: idle -> loading -> ready|error.
  // packages.length === 0 is valid only for ready (up to date).
  property string state: "idle"
  property var packages: []
  property string errorText: ""
  property double updatedAt: 0
  property bool refreshQueued: false

  readonly property bool updating: updateProc.running

  // Wall-clock second (unix) the current notification was sent; anchors
  // the three-day "Ignore" window.
  property double _sentAt: 0

  // Per-source results collected while both processes run; merged in
  // _finishRefresh once both have exited.
  property bool _officialDone: false
  property bool _aurDone: false
  property var _officialPkgs: []
  property var _aurPkgs: []
  property string _officialErr: ""
  property string _aurErr: ""

  // Who asked, recorded in two slots because the question "was this the user or
  // the clock" has to be answered about the cycle that REPORTED, not about the
  // ask that most recently arrived. `_why` belongs to the cycle now running and
  // is what the result line is filed under; `_whyNext` is an ask that arrived
  // mid-run and will start the follow-up cycle. One slot cannot do both: an ask
  // that lands while the children are already out would relabel counts that
  // were fetched before it happened, and nothing in the log would show it.
  property string _why: ""
  property string _whyNext: ""

  function refresh(why) {
    // Anything that does not name itself came from outside this file - the bar
    // module's middle-click, the island's refresh button, the IPC verb - and
    // all three are a person asking, which is the only distinction that needs
    // making. Tested with `typeof` rather than against `undefined`, because the
    // IPC verb already passes `true`: an `undefined` test would let the boolean
    // through and the log would read `asked for by true`.
    root._whyNext = (typeof why === "string" && why !== "") ? why : "caller"
    if (refreshProc.running || aurProc.running) {
      refreshQueued = true
      return
    }
    root.state = "loading"
    root.errorText = ""
    root._officialDone = false
    root._aurDone = false
    root._officialPkgs = []
    root._aurPkgs = []
    root._officialErr = ""
    root._aurErr = ""
    root._startFetches()
  }

  function _startFetches() {
    // The pending ask becomes this cycle's ask here, at the one place a cycle
    // begins - never in `refresh` above, which also runs for an ask that is
    // only queued.
    root._why = root._whyNext
    refreshProc.running = true
    aurProc.running = true
  }

  // Update flow. `aur` selects the AUR updater, `pkgNames` restricts the
  // update to the given packages (empty = update everything of that type).
  // Both triggers run through the updateProc bash hold-wrapper so
  // `updating` covers the real terminal lifetime; inner args are
  // shell-quoted, never interpolated raw.
  // A value that crossed a QML signal boundary arrives as an array-like
  // object rather than a native Array, so Array.isArray alone would drop
  // every selected name and silently turn a partial update into a full one.
  // Normalise once here so every caller (UI, IPC, notification) is covered.
  function _asNames(pkgNames) {
    if (Array.isArray(pkgNames)) return pkgNames
    if (typeof pkgNames === "string") {
      try { pkgNames = JSON.parse(pkgNames) } catch (e) { return [] }
    }
    const out = []
    if (pkgNames && typeof pkgNames.length === "number") {
      for (let i = 0; i < pkgNames.length; i++) out.push(pkgNames[i])
    }
    return out
  }

  function triggerUpdate(aur, pkgNames) {
    if (updateProc.running) return
    const names = root._asNames(pkgNames)
    let inner = "vb-launch-tui -- vb-pkg-update"
    if (aur) inner += " --aur"
    inner += " " + root._quotedNames(names)
    root._launchUpdate(inner)
  }

  // Official + AUR in one pass: vb-pkg-update --both runs yay over repos
  // and AUR together, so a full-system update needs a single sync cycle.
  function triggerUpdateBoth(pkgNames) {
    if (updateProc.running) return
    const names = root._asNames(pkgNames)
    const inner = "vb-launch-tui -- vb-pkg-update --both " + root._quotedNames(names)
    root._launchUpdate(inner)
  }

  // Single-quote shell escape for package names passed to the wrapper.
  function _quotedNames(pkgNames) {
    const names = root._asNames(pkgNames)
    const out = []
    for (let i = 0; i < names.length; i++) {
      out.push(SU.shellQuote(names[i]))
    }
    return out.join(" ")
  }

  // Wrap the inner launch in a hold loop: vb-launch-tui daemonizes
  // (setsid -f into its own session) and exits in ms, so without the hold
  // `updating` would clear before the terminal even draws - and the
  // daemonized updater's PID is unknowable from here (no pidfile, no
  // foreground flag), so process-id tracking cannot name it. The loop
  // matches the updater's exact executable name instead: pidof answers
  // PIDs, never command text, so the command-text self-match class of
  // bug (the bracket workaround, the grep self-match stuck-forever
  // variant) is unrepresentable here rather than worked around.
  function _launchUpdate(inner) {
    updateProc.command = ["bash", "-c",
      inner + "; while pidof vb-pkg-update >/dev/null; do sleep 1; done"]
    updateProc.running = true
  }

  // True when the persistent suppression window has expired (or was never
  // set): the shared shell cache carries nextNotify as a unix timestamp,
  // so a restart compares against the exact value the previous session
  // wrote and an ignored notification never re-shows early.
  function _notifyAllowed() {
    return Date.now() / 1000 >= ShellCache.number("archUpdates", "nextNotify", 0)
  }

  // Arm a one-shot refresh for the exact moment the suppression window
  // expires, so the re-show lands on the minute instead of riding the
  // 30-minute refresh cadence. A drained batch or a newer send simply
  // leaves the stale one-shot to fire harmlessly (a refresh that finds
  // nothing to say).
  function _scheduleNotifyCheck() {
    const remaining = Math.round((ShellCache.number("archUpdates", "nextNotify", 0) - Date.now() / 1000) * 1000)
    if (remaining <= 0) return
    notifyWindowTimer.interval = remaining
    notifyWindowTimer.restart()
  }

  // Push the update-available notification with two action buttons. -A
  // implies --wait, so the process lives until the notification closes and
  // prints the chosen action's name to stdout: "update" runs the full
  // updater (official + AUR, one sync cycle, in its own terminal),
  // "ignore" re-arms the window for three real days. -t 300000 keeps the
  // bubble up for 5 minutes (the daemon honors the sender's timeout).
  function _notifyUpdates() {
    if (notifyProc.running) return
    const now = Date.now() / 1000
    root._sentAt = now
    // Silence window for the "closed without a button" outcome, written
    // at send time so a crash or restart mid-wait still counts as
    // ignored; the "ignore" action overwrites it with the 3-day window.
    ShellCache.updateSection("archUpdates", { nextNotify: now + 24 * 3600 })
    const n = root.packages.length
    const body = n === 1 ? "1 package has an update pending"
      : n + " packages have updates pending"
    notifyProc.command = [
      "notify-send",
      "-a", "Vibranium",
      "-t", "300000",
      "-A", "ignore=Ignore",
      "-A", "update=Update Now",
      "Arch updates available",
      body
    ]
    notifyProc.running = true
  }

  // Parse `pkgname oldver -> newver` lines (checkupdates and yay -Qua use
  // the same shape; the bare 4-field pacman -Qu form is handled too).
  // Canonicalized in ArchUpdatesLib.js (pinned format, unit-tested).
  function _parse(text, source): var {
    return ArchUpdatesLib.parseUpdates(text, source)
  }

  // Merge once both fetches have exited and decide the final state.
  // Official failure is fatal (the check is unreliable); AUR failure is
  // tolerated and surfaces as a note on the ready list.
  function _finishRefresh() {
    if (!root._officialDone || !root._aurDone) return
    // One line per completed query, and it is the RESULT rather than the
    // start: "a check began" says nothing that `state` does not already say,
    // whereas the counts are the answer to the question the check was asking,
    // and they are only knowable once both children have landed - which is
    // exactly where this function first runs to completion.
    //
    // The two sources are counted separately because they fail separately: the
    // AUR is a third-party RPC behind a 30s timeout, so "official 4, aur 0" is
    // a real and common outcome that a single total would hide.
    Log.info("queried updates, official "
      + (root._officialErr !== "" ? "failed" : String(root._officialPkgs.length))
      + ", aur " + (root._aurErr !== "" ? "failed" : String(root._aurPkgs.length)))
    // Who asked for the two children whose counts the line above reports. Both
    // sources, both exit codes and both counts are identical whether a person
    // clicked or the 30-minute cadence fired, so this is the only line that can
    // tell a user action from the periodic poll - and "why did the shell just
    // reach for the network" is the question behind every stale count anyone
    // asks about. A closed set: the two timers, the updater's exit and boot
    // name themselves, everything else is one bucket, because the three outside
    // callers are indistinguishable here and all three are a person asking.
    Log.debug("queried updates: asked for by " + root._why)
    if (root._officialErr !== "") {
      root.state = "error"
      root.errorText = root._officialErr
      root.packages = []
    } else {
      root.state = "ready"
      root.packages = root._officialPkgs.concat(root._aurPkgs)
      root.errorText = root._aurErr !== ""
        ? "AUR check failed (" + root._aurErr + ")" : ""
    }
    root.updatedAt = Date.now() / 1000
    // A refresh at or below the threshold is a notification no-op: no
    // suppression window is written and the expiry one-shot is not armed.
    if (root.packages.length > root.notifyThreshold) {
      if (root._notifyAllowed()) root._notifyUpdates()
      else root._scheduleNotifyCheck()
    }
    if (root.refreshQueued) {
      root.refreshQueued = false
      root.state = "loading"
      root.errorText = ""
      root._startFetches()
    }
  }

  // Refresh cadence, named: 30 minutes, single-flight guarded.
  readonly property int refreshMs: 30 * 60 * 1000
  Timer {
    id: refreshTimer

    interval: root.refreshMs
    repeat: true
    running: true
    onTriggered: root.refresh("timer")
  }

  // One-shot armed while a suppression window is pending; fires exactly
  // when the window expires so the re-show is on time (see
  // _scheduleNotifyCheck). Parked at rest: running:false is explicit so
  // the seed interval below can never fire unarmed (it is always
  // reassigned before restart).
  readonly property int notifySeedMs: 1
  Timer {
    id: notifyWindowTimer

    interval: root.notifySeedMs
    repeat: false
    running: false
    onTriggered: root.refresh("notify window")
  }

  // Official repos. `timeout` guards against a dead mirror hanging the
  // check forever; checkupdates itself fails fast on unreadable mirrors,
  // but a black-holed connection needs the kill switch.
  Process {
    id: refreshProc

    command: ["timeout", "60", "checkupdates"]
    stdout: StdioCollector { id: refreshOut }
    stderr: StdioCollector { id: refreshErr }
    onExited: (code, status) => {
      const outText = String(refreshOut.text || "")
      const errText = String(refreshErr.text || "")
      const trimmed = outText.trim()
      if ((code !== 0 && code !== 2) && trimmed === "") {
        root._officialErr = errText !== "" ? errText.trim().substring(0, 512) : "exit " + code
      } else {
        root._officialPkgs = root._parse(outText, "official")
      }
      // Code 2 from checkupdates means "up to date", not failure, and both
      // children are wrapped in `timeout` - so an exit code is the only way to
      // tell a mirror that was slow from a mirror that was broken. Named rather
      // than left as a bare 124 because that number belongs to coreutils, not to
      // this file, and it is the whole difference between a mirror that ran out
      // of clock and one that answered with an error.
      Log.debug("official check: code " + code
        + (code === 124 ? " (timeout fired)" : "")
        + ", " + root._officialPkgs.length + " parsed")
      root._officialDone = true
      root._finishRefresh()
    }
  }

  // AUR. yay -Qua queries the AUR RPC; when the AUR is down or slow the
  // timeout kills it so the module keeps working on official data alone.
  // Same 124 convention as the official child above, and for the same reason:
  // an unreachable RPC and a slow one are different problems.
  Process {
    id: aurProc

    command: ["timeout", "30", "yay", "-Qua"]
    stdout: StdioCollector { id: aurOut }
    stderr: StdioCollector { id: aurErr }
    onExited: (code, status) => {
      const outText = String(aurOut.text || "")
      const errText = String(aurErr.text || "")
      const trimmed = outText.trim()
      if ((code !== 0 && code !== 2) && trimmed === "") {
        root._aurErr = errText !== "" ? errText.trim().substring(0, 256) : "exit " + code
      } else {
        root._aurPkgs = root._parse(outText, "aur")
      }
      Log.debug("aur check: code " + code
        + (code === 124 ? " (timeout fired)" : "")
        + ", " + root._aurPkgs.length + " parsed")
      root._aurDone = true
      root._finishRefresh()
    }
  }

  // Update-available notification action resolver (see _notifyUpdates).
  Process {
    id: notifyProc

    stdout: StdioCollector { id: notifyOut }
    onExited: {
      const action = String(notifyOut.text || "").trim()
      if (action === "update") {
        // Acted on: keep the send-time window as-is. Leftovers from a
        // partial update stay quiet for the rest of the day, while a
        // genuinely fresh batch after the window passes notifies again.
        root.triggerUpdateBoth([])
      } else if (action === "ignore") {
        // Button-ignored: three real days from the moment it was shown.
        // The one-shot is re-armed here immediately so the re-show lands
        // exactly on the 3-day mark, not on the next 30-minute refresh.
        ShellCache.updateSection("archUpdates", { nextNotify: root._sentAt + 3 * 24 * 3600 })
        root._scheduleNotifyCheck()
      }
      // Empty output: closed or timed out without a button - the 24-hour
      // window written at send time already covers it.
    }
  }

  Process {
    id: updateProc

    // Default command (both triggers overwrite it via _launchUpdate):
    // launch, then hold while the vb-pkg-update terminal lives (exact-name
    // pidof match, never command text). Non-zero exit surfaces as
    // errorText instead of a silent refresh.
    command: ["bash", "-c",
      "vb-launch-tui -- vb-pkg-update; while pidof vb-pkg-update >/dev/null; do sleep 1; done"]
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: (code, status) => {
      if (code !== 0) root.errorText = "Update launch failed (exit " + code + ")"
      // Follow-up read of the new list, not a check the user asked for:
      // the user asked for the update, and this refresh is the tail of
      // that action.
      root.refresh("update exit")
    }
  }

  // First refresh deferred past the boot window: checkupdates plus the
  // AUR helper are the heaviest forks in the tree, and firing them from
  // onCompleted contends with first paint. Skipped when something else
  // already refreshed (island open, IPC verb): state leaves "idle" on
  // the first refresh of any kind.
  Timer {
    id: bootRefresh

    interval: 90000
    repeat: false
    running: true
    onTriggered: {
      if (root.state === "idle") root.refresh("boot")
    }
  }

  Component.onCompleted: {
    Registry.offer("archUpdates", {
      title: "Arch updates",
      description: "system update polling + apply",
      verbNames: [
        "refresh",
        "update",
        "status",
        "help",
        "ping",
      ]
    })
  }

  IpcHandler {
    target: "arch-updates"
    function help(command: string): string {
      return UnitIpc.help("arch-updates", "Arch updates", "system update polling + apply", [
        { name: "refresh", help: "re-poll available updates" },
        { name: "update", help: "run the system update" },
      ], command)
    }
    function ping(): string { return "pong" }

    function refresh(): string {
      root.refresh(true)
      return "ok"
    }

    function update(aur: string, json: string): string {
      let names = []
      if (json !== "") {
        try {
          names = JSON.parse(json)
        } catch (e) {
          names = []
        }
      }
      root.triggerUpdate(aur === "aur", names)
      return "ok"
    }

    function status(): string {
      return JSON.stringify({ state: root.state, count: root.packages.length, updatedAt: root.updatedAt, error: root.errorText })
    }
  }
}
