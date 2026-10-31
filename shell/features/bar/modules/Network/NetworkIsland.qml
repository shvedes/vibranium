pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import qs.common
import qs.services as Core
import "Model.js" as Model

// The network island: live link metrics on top (current down/up rates,
// total downloaded/uploaded), then the wifi networks - known ones
// first, then everything else, both by signal strength. Clicking a known network - connected or not - unfolds the shared manage
// dropdown (Share, Connect/Disconnect, Forget, profile toggles); a
// secured unknown one unfolds the shared DropdownSlot with a builtin
// passphrase field; an open one connects straight away.
//
// Metrics come from a lightweight poll (the active route's interface, resolved
// by `ip`, and its /sys byte counters, read directly) - only while the island
// is open. The network list comes from Quickshell.Networking (NetworkManager
// backend), refreshed on the same poll tick after each scan.
//
// SPLIT MAP (one owner each, no behavior change): WifiList (network
// rows: known/other sections, sorting, row subtext, connect dropdowns)
// and Stats (link metrics: down/up rates, totals, speedtest, profile
// toggles, link hardware). Data plumbing feeds both; actions serve both.
Item {
  id: root

  // Table cell text styles, shared by the metrics grid -> via lib Title.
  component MetricLabel: Title {
    level: 4
    color: Ui.tint("foreground_1", 0.6)
  }
  component MetricValue: Title {
    level: 3
    color: Ui.solid("foreground_0")
    // Fixed column width + right alignment: the metrics grid must not
    // reflow when a value string changes width (e.g. "512 B/s" ->
    // "12.4 MB/s"), or every label would shift left/right each poll.
    Layout.preferredWidth: root.metricValueWidth
    horizontalAlignment: Text.AlignRight
  }

  // Widest value that can appear, measured once via a hidden probe so the
  // value column is static regardless of the font in use.
  readonly property real metricValueWidth: Math.round(metricProbe.implicitWidth)

  Title {
    id: metricProbe

    visible: false
    level: 3
    text: "123.4 MB/s"
  }

  property int islandContentWidth: 380
  // The card's padded body holds the content: add the outer padding to the
  // content's implicit height so nothing clips. Read off the live body
  // while the host shows this island; the host freezes the last live
  // footprint for the closed window.
  property int islandContentHeight: Math.ceil(body.implicitHeight) + 2 * Ui.outerPad
  // DropdownSlots and the Wi-Fi list ease their own heights; the host steps
  // its window-height Behavior aside so the window tracks them frame by
  // frame (one easing only).
  property bool islandSelfAnimating: true
  property var islandHost: null

  // Horizontal inset for each network row's content, mirroring the menu
  // entry insets so rows read like menu entries. Compact - keeps the
  // wifi icon's box tight to the edge.
  readonly property real rowPad: 4

  // --- metrics ---
  property bool hasStats: false
  property real downloadRate: 0
  property real uploadRate: 0
  property real totalRxBytes: 0
  property real totalTxBytes: 0
  property var prevThroughput: null

  // --- wifi state ---
  // The derived wifi display model as ONE object: exactly what
  // Model.deriveWifiState returned on the last poll, handed straight back
  // to it on the next one so its change gates compare against what the
  // list is actually showing. Owning it as one object is what makes that true:
  // parallel arrays could disagree, and a gate reading a stale one would
  // recreate every delegate each tick.
  property var derived: ({
    sorted: [],
    known: [],
    other: [],
    display: [],
    changed: false,
    knownChanged: false,
    otherChanged: false,
    grew: false
  })
  // Views onto that one object, not caches of their own. The delegate and
  // binding sites below read them unchanged.
  readonly property var wifiRows: root.derived.sorted
  // Display model for the single list: the sorted rows, connected first.
  // Produced by the same library step, so the poll gate in
  // syncWifiNetworks still owns delegate churn.
  readonly property var displayRows: root.derived.display
  // Slide gate: true only for the sync that grows the known set (a
  // promotion). Signal resort, scans and text changes sync instantly.
  // It gates the list's move/displaced durations, so a sync that only
  // changes row content changes it with no transition. Reset by the next
  // poll, so scan wobble never slides.
  property bool syncAnimated: false
  // Row records behind the display model: one per display row, carrying
  // that row's own fields with its identity lifted onto it as `key`.
  property var _wifiRecords: []
  // Wifi rows as ONE display model. `values` is the model's only write and
  // it refuses nothing, so a sync is a plain reassignment: the model diffs
  // the row set and reuses every surviving delegate in place, where a JS
  // array as the model would reset the view and recreate them all.
  // Skeleton/off paths stay on plain arrays (no animation needed there).
  ScriptModel {
    id: wifiModel

    values: root._wifiRecords
    objectProp: "key"
    // Identity compares a record by reference, which is the semantics the
    // rows are built under; the default Structure compares by content.
    comparisonMode: ObjectComparison.Identity
  }
  // Sync from the derived display rows. The record is the display row
  // itself plus its key, so the delegate reads a row's content straight
  // off the modelData role instead of rescanning displayRows per row per
  // poll.
  function syncWifiModel(next) {
    const want = Array.isArray(next) ? next : []
    const rows = new Array(want.length)
    for (let i = 0; i < want.length; i++) {
      const r = want[i] || {}
      rows[i] = Object.assign({}, r, { key: Model.wifiDisplayKey(r) })
    }
    root._wifiRecords = rows
  }
  // Row source and delegate for the Wi-Fi networks list, written as one
  // ordered pair. The two halves are NOT interchangeable: both models hand
  // the view a `modelData` record and both delegates require only `index`,
  // so a mismatch does not fail loudly - the row delegate against a
  // placeholder row paints a nameless network, and the placeholder
  // delegate flashes over a real one. Each write recreates the delegates,
  // so the half that tolerates a mismatched partner must land first and
  // the constrained half second - that holds in both directions here. Two
  // bindings over the same toggle cannot promise that order: the engine
  // re-evaluates them in property-declaration order, which is the model
  // first.
  function syncOtherList() {
    if (root.otherSkeletonMode) {
      otherList.delegate = otherSkeletonDelegate
      otherList.stableModel = root._otherSkeletonRows
    } else {
      otherList.stableModel = wifiModel
      otherList.delegate = networkDelegate
    }
  }
  // Skeleton for OTHER NETWORKS -> same flashing style as ArchUpdates.
  readonly property var _otherSkeletonRows: {
    const out = []
    for (let i = 0; i < 4; i++) out.push({})
    return out
  }
  readonly property bool _otherSkeleton: root.scanning && root.wifiRows.length === 0
  readonly property bool _wifiOff: !Networking.wifiEnabled
  // Watcher verdict for the connected row ("portal", "configuring",
  // "offline", "metered" or "") and its ink: red for no internet, yellow
  // for portal/metered, the plain dot tone for configuring (setup is not
  // an alarm). Read off the connectivity service so the row and the pile
  // read one verdict, and silent until its first poll lands.
  readonly property string linkNote: Core.Connectivity.linkNote
  readonly property string linkNoteHex: root.linkNote === "offline"
    ? String(Ui.solid("red")) : root.linkNote === "configuring"
    ? String(Ui.tint("foreground_1", 0.5)) : String(Ui.solid("yellow"))
  // Real internet for gating fixtures: the watcher's optimistic answer
  // (full until the first poll proves otherwise), so the section below
  // reads the same verdict the converter plugin and the pile do.
  readonly property bool hasInternet: Core.Connectivity.online
  // The list shows placeholders while a scan is in flight with nothing
  // to show yet (flashing). One state, because the row source and the
  // delegate that can read it have to land together (see syncOtherList).
  readonly property bool otherSkeletonMode: root._otherSkeleton
  onOtherSkeletonModeChanged: root.syncOtherList()
  // A wifi radio exists. The soft-enabled state is deliberately NOT part of
  // this: the header carries the only control that can switch a disabled
  // radio back on, so gating it on `wifiEnabled` hides the toggle together
  // with the radio it controls. A hard-blocked radio keeps the header as
  // well - the shared Toggle renders faded and inert on its own.
  // Metrics and speedtest are transport-agnostic and stay either
  // way; they do not ride this.
  readonly property bool wifiPresent: root.wifiDevice !== null
  // Subtext under the Wi-Fi header: "<interface> · <device>" when NM
  // exposes a device name beyond the control interface (e.g.
  // "wlan0 · Intel Wi-Fi 6"), else the interface alone (e.g. "wlan0").
  // Bluetooth-header style (Title level 4). "No adapter" with no radio.
  readonly property string wifiHeaderSubtext: {
    if (!root.wifiDevice) return "No adapter"
    const d = root.wifiDevice
    const iface = String(d.name || "")
    const candidates = [d.description, d.model, d.product, d.deviceName, d.nickname, d.interfaceName, d.interface]
    let dev = ""
    for (let i = 0; i < candidates.length; i++) {
      const s = String(candidates[i] || "").trim()
      if (s !== "" && s !== iface) {
        dev = s
        break
      }
    }
    if (iface !== "" && dev !== "") return iface + " · " + dev
    if (iface !== "") return iface
    if (dev !== "") return dev
    return "Wi-Fi"
  }
  property string actionSsid: ""
  property string actionKind: "" // "connect" | "disconnect" | "forget"
  // True while a connect attempt runs on secrets typed just now for a
  // network that had no saved profile. A rejected secret must be discarded
  // (see onConnectionFailed): the submit creates the NM profile at
  // activation, so keeping it would autoconnect with the wrong password
  // instead of re-prompting.
  property bool actionFreshSecrets: false
  // The row whose dropdown is open: `passwordSsid` for a secured-unknown
  // network's slide-in passphrase field, `disconnectSsid` for the
  // connected row's disconnect dropdown. At most one open at a time.
  property string passwordSsid: ""
  property string disconnectSsid: ""
  // The half-typed passphrase: the wifi list's delegate is
  // torn down and rebuilt on every 0.5s poll, so the typed value must live
  // HERE, not in the (recreated) field, or each refresh would clear it.
  property string passwordText: ""
  property string failureSsid: ""
  property string failureReason: ""
  property var actionTarget: null

  readonly property bool busy: root.actionKind !== ""

  // Fullscreen QR share is owned by the module (sibling overlay, like the
  // color picker's): a row's action emits this with that row's SSID ("" for
  // the active connection, resolved by self-detect) and Network.qml opens
  // the overlay for it.
  signal qrRequested(string ssid)

  // The connected wifi network. Rows share through their own buttons, so
  // the header carries no QR action - just the title and the radio toggle.
  readonly property var connectedWifi: root.connectedNetwork
    && root.wifiDevice && root.connectedNetwork.device === root.wifiDevice
    ? root.connectedNetwork : null
  // The connected wired network, if any. Wired is the negation of wifi:
  // any connected link whose device is not the wifi radio.
  readonly property var connectedWired: (root.connectedNetwork && (!root.wifiDevice || root.connectedNetwork.device !== root.wifiDevice))
    ? root.connectedNetwork : null
  // Any usable link (wifi or wired). Metrics and speedtest key off this, so
  // neither is gated on the radio being the wifi one.
  readonly property bool hasLink: !!(root.connectedWifi || root.connectedWired)
  // A connect attempt in flight counts as a link for section visibility:
  // while wifi is "connecting" no network reads connected yet, but the
  // sections must stay up rather than hide as if wifi were off. Disconnect
  // and forget clear the action at once (fire-and-forget), so only
  // "connect" can hold this true.
  readonly property bool connectInflight: root.actionKind === "connect"
  // Metrics show when the collector has data AND a link exists, even with the
  // wifi radio off (wired-only setups).
  readonly property bool metricsLive: root.hasStats && (root.hasLink || !root._wifiOff)

  // --- inline speedtest (no dials, no fullscreen) ---
  // Permanent section, any link: grows whenever a wifi or wired link
  // is up. Each run measures download then upload (15s a phase); every
  // meter fills live against a stepped cap (100 Mbps, then 500, 1 Gbps and
  // so on) with the scale labeled at both ends, so the bar always reads as
  // what it is: current throughput over 0..cap.
  property bool speedtestRunning: false
  property string speedtestPhase: "" // "down" | "up" | ""
  property string speedtestDown: ""
  property string speedtestUp: ""
  property real speedtestScaleDown: 100
  property real speedtestScaleUp: 100
  property string speedtestError: ""
  property string speedtestStderr: ""
  property bool speedtestExpectedStop: false
  property bool speedtestPending: false

  // Drop the whole result state: closing the island always lands the next
  // open on a fresh section (no stale figures, no "Run Again").
  function clearSpeedtest() {
    root.speedtestDown = ""
    root.speedtestUp = ""
    root.speedtestScaleDown = Model.initialSpeedScale()
    root.speedtestScaleUp = Model.initialSpeedScale()
    root.speedtestError = ""
    root.speedtestStderr = ""
    root.speedtestPending = false
  }

  function startSpeedtest() {
    if (speedtestProc.running) {
      // A previous run's SIGTERM is still landing; queue the fresh run.
      if (root.speedtestExpectedStop) root.speedtestPending = true
      return
    }
    root.speedtestError = ""
    root.speedtestStderr = ""
    root.speedtestDown = ""
    root.speedtestUp = ""
    root.speedtestScaleDown = Model.initialSpeedScale()
    root.speedtestScaleUp = Model.initialSpeedScale()
    root.speedtestRunning = true
    root.startSpeedtestPhase("down")
  }

  function startSpeedtestPhase(nextPhase) {
    root.speedtestExpectedStop = false
    root.speedtestPhase = nextPhase
    root.speedtestStderr = ""
    speedtestProc.command = ["vb-network-speedtest", nextPhase]
    speedtestProc.running = true
    speedtestTimer.restart()
  }

  function stopSpeedtestPhase() {
    speedtestTimer.stop()
    if (speedtestProc.running) {
      root.speedtestExpectedStop = true
      speedtestProc.running = false
      return
    }
    root.finishSpeedtestPhase()
  }

  function finishSpeedtestPhase() {
    if (root.speedtestPhase === "down") {
      root.startSpeedtestPhase("up")
      return
    }
    root.speedtestPhase = ""
    root.speedtestRunning = false
    root.speedtestExpectedStop = false
  }

  function stopSpeedtest() {
    speedtestTimer.stop()
    root.speedtestPending = false
    // Clear the phase before killing: onExited advances while it reads "down".
    root.speedtestPhase = ""
    root.speedtestRunning = false
    if (speedtestProc.running) {
      root.speedtestExpectedStop = true
      speedtestProc.running = false
    }
    // A manual stop resets the section: stale bars must not survive a cancel.
    root.clearSpeedtest()
  }

  function updateSpeedtestLine(line) {
    const value = parseFloat(line)
    if (!isFinite(value) || value < 0) return
    if (root.speedtestPhase === "down") {
      root.speedtestDown = String(value)
      root.speedtestScaleDown = Model.stepSpeedScale(root.speedtestScaleDown, value)
    } else if (root.speedtestPhase === "up") {
      root.speedtestUp = String(value)
      root.speedtestScaleUp = Model.stepSpeedScale(root.speedtestScaleUp, value)
    }
  }

  // True while the wifi radio is refreshing. When the backend exposes
  // `scanning` (or `isScanning`) that flag is authoritative; when it
  // does not, the shown content + wifi-enabled state implies a refresh
  // (scannerEnabled is set on show and the 500 ms poll syncs the list).
  readonly property bool scanning: {
    if (!root.wifiDevice) return false
    if (!Networking.wifiEnabled) return false
    const d = root.wifiDevice
    if (d.scanning !== undefined) return !!d.scanning
    if (d.isScanning !== undefined) return !!d.isScanning
    return true
  }

  readonly property var failReasons: ({
    NoSecrets: ConnectionFailReason.NoSecrets,
    WifiAuthTimeout: ConnectionFailReason.WifiAuthTimeout,
    WifiNetworkLost: ConnectionFailReason.WifiNetworkLost,
    WifiClientDisconnected: ConnectionFailReason.WifiClientDisconnected,
    WifiClientFailed: ConnectionFailReason.WifiClientFailed
  })

  readonly property var devices: Networking.devices ? Networking.devices.values : []
  readonly property var wifiDevice: {
    for (const d of root.devices) if (d.type === DeviceType.Wifi) return d
    return null
  }
  readonly property var connectedNetwork: {
    for (const d of root.devices) {
      const nets = d.networks ? d.networks.values : []
      for (const n of nets) if (n.connected) return n
    }
    return null
  }

  // --- data plumbing ---

  function networkForSsid(ssid) {
    if (!root.wifiDevice || !root.wifiDevice.networks) return null
    for (const n of root.wifiDevice.networks.values) {
      if (n.name === ssid) return n
    }
    return null
  }

  // The adapter half of a poll tick: walk the backend into plain row
  // snapshots, hand those plus the previous derived model to the library,
  // then land what comes back on the properties and the wifi model. The
  // derivation between the two - sort, section carry, the known/other
  // split, and the change and promotion gates - is Model.deriveWifiState.
  function syncWifiNetworks() {
    const rows = []
    if (root.wifiDevice && root.wifiDevice.networks) {
      for (const n of root.wifiDevice.networks.values) {
        const r = Model.wifiRow(n, WifiSecurityType.Open, WifiSecurityType.Owe)
        if (r) rows.push(r)
      }
    }
    const d = Model.deriveWifiState(root.derived, rows)
    // Assign only on visible change: every model swap recreates delegates,
    // so an unconditional assign would drop a focused passphrase field
    // even outside the frozen-entry guard above.
    if (d.changed || d.knownChanged || d.otherChanged) root.derived = d
    root.syncAnimated = d.grew
    // The third arm is the not-yet-populated one, and it is what separates
    // a model that has never held a row set from a genuinely empty one.
    // `values.length` is the row count; a ScriptModel has no `count`, and
    // `undefined === 0` is false, so reading `count` here would make both
    // states identical and the arm would never fire, with nothing to say so.
    if (d.changed || d.grew || wifiModel.values.length === 0) root.syncWifiModel(d.display)
    root.checkActionCompletion()
    root.retireStaleFailure()
  }

  // The adapter half of a stats tick: hand the script's raw output plus
  // the previous sample to the library and land the derived metrics. The
  // parse, the throughput delta, the link-drop reset and the cumulative
  // counters are Model.deriveStats; the clock stays here so the rate is
  // reproducible in a test.
  function updateStats(raw) {
    const d = Model.deriveStats({
      prevThroughput: root.prevThroughput,
      totalRxBytes: root.totalRxBytes,
      totalTxBytes: root.totalTxBytes
    }, raw, Date.now() / 1000)
    root.hasStats = d.hasStats
    root.downloadRate = d.downloadRate
    root.uploadRate = d.uploadRate
    root.totalRxBytes = d.totalRxBytes
    root.totalTxBytes = d.totalTxBytes
    root.prevThroughput = d.prevThroughput
  }

  // --- actions ---

  function beginAction(kind, ssid) {
    root.failureSsid = ""
    root.failureReason = ""
    root.actionSsid = ssid
    root.actionKind = kind
    root.actionFreshSecrets = false
  }

  function runAction(kind, ssid, fn) {
    const net = root.networkForSsid(ssid)
    if (!net) return
    root.beginAction(kind, ssid)
    root.actionTarget = net
    fn(net)
  }

  // Close whichever dropdown is open (called before opening another).
  function closeDropdowns() {
    root.passwordSsid = ""
    root.disconnectSsid = ""
  }

  // Clicking a row toggles its action dropdown: an already-open dropdown
  // closes again, any other dropdown closes first.
  function connectRow(row) {
    if (root.busy) return
    // Known networks (connected or not): the manage dropdown. The
    // primary button is Disconnect on the active link, Connect on a
    // known-but-disconnected row - manageability before blind
    // auto-activation.
    if (row.known) {
      if (root.disconnectSsid === row.ssid) {
        root.closeDropdowns()
        return
      }
      // The shared DropdownSlot (Share + Connect/Disconnect + Forget
      // buttons, profile toggles) is the manage affordance - not a
      // disconnect-on-left-click or a blind connect.
      root.closeDropdowns()
      root.disconnectSsid = row.ssid
      return
    }
    // Secured and unknown: unfold the shared DropdownSlot passphrase field
    // instead of failing with NoSecrets seconds later.
    if (row.secured && !row.known) {
      if (root.passwordSsid === row.ssid) {
        root.closeDropdowns()
        return
      }
      root.failureSsid = ""
      root.failureReason = ""
      root.closeDropdowns()
      root.passwordSsid = row.ssid
      // Fresh open always starts a blank passphrase.
      root.passwordText = ""
      return
    }
    root.runAction("connect", row.ssid, n => n.connect())
  }

  // Submitting a passphrase for a secured unknown network. No routing:
  // only unknown networks can have the passphrase field open, so the
  // connect action is the only possible outcome; known rows run through
  // the manage dropdown instead.
  function submitPassword(text) {
    const ssid = root.passwordSsid
    if (ssid === "") return
    const net = root.networkForSsid(ssid)
    const wasUnknown = net ? !net.known : true
    root.passwordSsid = ""
    root.passwordText = ""
    root.runAction("connect", ssid, n => n.connectWithPsk(text))
    // Latch only when the action actually started (runAction no-ops when
    // the network vanished from the scan): a rejected fresh secret is
    // discarded on failure so the retry re-prompts.
    root.actionFreshSecrets = root.actionKind === "connect" && wasUnknown
  }
  function disconnectRow(row) {
    root.disconnectSsid = ""
    const net = root.networkForSsid(row.ssid)
    if (net) net.disconnect()
    // Disconnect is dispatched asynchronously and NetworkManager is free
    // to re-activate the saved profile right after it (autoconnect,
    // upstream quickshell issue 802), so a tracked terminal state never
    // reliably arrives and tracking would pin `busy` - all row input -
    // until the island reopens. Fire and forget like Forget: the row
    // updates on the next sync either way, and input stays live.
    root.clearAction()
  }

  function forgetRow(row) {
    root.disconnectSsid = ""
    const net = root.networkForSsid(row.ssid)
    if (net) net.forget()
    // Forget is dispatched asynchronously and Quickshell can drop the AP
    // out of the scan on completion, so a tracked terminal state never
    // reliably arrives. Clear the busy latch immediately rather than block
    // the whole island until the network churns - the row updates on the
    // next sync either way, and input stays live.
    root.clearAction()
  }

  // Reset the whole in-flight action (timeout, failure and success all
  // converge here so no path forgets a field).
  function clearAction() {
    actionTimeout.stop()
    root.actionSsid = ""
    root.actionKind = ""
    root.actionFreshSecrets = false
    root.actionTarget = null
    root.closeDropdowns()
  }

  // A mid-flight action completes once its network reaches the target state:
  // connect->connected, disconnect->disconnected, forget->no longer known.
  // Poll ticks call this after syncing networks. A missing network is also
  // terminal: forget (and churn) can remove the AP from the scan entirely,
  // which would otherwise leave `busy` latched until the island reopens.
  function checkActionCompletion() {
    if (root.actionKind === "" || root.actionSsid === "") return
    const net = root.networkForSsid(root.actionSsid)
    if (!net) {
      root.clearAction()
      return
    }
    let done = false
    if (root.actionKind === "connect") done = net.connected
    else if (root.actionKind === "disconnect") done = !net.connected && !net.stateChanging
    else if (root.actionKind === "forget") done = !net.known && !net.stateChanging
    if (!done) return
    // A connect that lands clears a stale failure for the same network,
    // the poll-path twin of the signal above (missed signals converge
    // here): the password that failed before is the one that just worked.
    if (root.actionKind === "connect" && root.failureSsid === root.actionSsid) {
      root.failureSsid = ""
      root.failureReason = ""
    }
    root.clearAction()
  }

  // A failure whose network is up anyway is stale - success outside any
  // action (an autoconnect landing right after a failure) retires the
  // banner on the next sync. Runs on the poll tick, so it costs no fork.
  function retireStaleFailure() {
    if (root.failureSsid === "") return
    const net = root.networkForSsid(root.failureSsid)
    if (net && net.connected) {
      root.failureSsid = ""
      root.failureReason = ""
    }
  }

  // --- connection profile (autoconnect / IPv4 / IPv6) ---
  // Served straight off the live backend object: Network.nmSettings ends
  // at NMSettings.read()/write() on the NetworkManager backend, so there
  // is no script and no polling here. Unknown networks and non-NM
  // backends expose no profiles - the toggles stay hidden then, never
  // faked. Writes persist for the next activation; ip-method flips are
  // NOT re-applied live (that would bounce the active link), while
  // autoconnect takes effect immediately.
  property string profileSsid: ""
  property var profileSettings: null
  property bool profileAutoconnect: true
  property bool profileIpv4: true
  property bool profileIpv6: true
  property bool profileReady: false

  // First settings profile behind a live network, whatever shape the
  // backend hands the list in (JS list or ObjectModel).
  function firstSettings(net) {
    const l = net ? net.nmSettings : null
    if (!l) return null
    if (typeof l.length === "number") return l.length > 0 ? l[0] : null
    if (typeof l.count === "number" && typeof l.get === "function")
      return l.count > 0 ? l.get(0) : null
    return null
  }

  function fetchProfile(ssid) {
    root.profileSsid = ssid
    root.profileReady = false
    root.profileSettings = null
    if (ssid === "") return
    const st = root.firstSettings(root.networkForSsid(ssid))
    if (!st) return
    root.profileSettings = st
    let map = null
    try {
      map = st.read()
    } catch (e) {
      map = null
    }
    root.applyProfileMap(ssid, map)
  }

  // Land a settings map onto the toggles. The map -> toggle DTO is
  // Model.profileToggles; anything unexpected (empty map, missing sections,
  // wrong shapes) comes back null and fails closed: the section hides.
  function applyProfileMap(ssid, map) {
    if (ssid === "" || root.disconnectSsid !== ssid) return
    const t = Model.profileToggles(map)
    if (!t) {
      root.profileReady = false
      return
    }
    root.profileAutoconnect = t.autoconnect
    root.profileIpv4 = t.ipv4
    root.profileIpv6 = t.ipv6
    root.profileReady = true
  }

  function clearProfile() {
    root.profileSsid = ""
    root.profileReady = false
    root.profileSettings = null
    root.linkBssid = ""
    root.macCopied = false
    macCopyTimer.stop()
  }

  // Toggles are state-externalized (see Toggle): the thumb answers the
  // click at once through the optimistic set below, and the confirming
  // re-read heals it if the backend refused the write (e.g. a system
  // profile needing auth). The re-read - not the settingsChanged signal -
  // is the source of truth, because that signal is not guaranteed to
  // arrive after every write.
  function writeProfile(key, on) {
    const st = root.profileSettings
    if (!st || root.profileSsid === "") return
    // The patch DTO is Model.profilePatch; the write itself is the backend
    // call and stays here. An unowned key yields no patch and writes
    // nothing.
    const patch = Model.profilePatch(key, on)
    if (!patch) return
    if (key === "autoconnect") root.profileAutoconnect = !!on
    else if (key === "ipv4") root.profileIpv4 = !!on
    else if (key === "ipv6") root.profileIpv6 = !!on
    try {
      st.write(patch)
    } catch (e) {
      // Refused (permissions, vanished profile): the confirm pass below
      // re-reads and flips the thumb back.
    }
    profileConfirm.restart()
  }

  // Confirming re-read after a write: lands whatever the backend settled
  // on. Never touches `ready`, so the section cannot blink out mid-click.
  function refreshProfile() {
    const ssid = root.profileSsid
    if (ssid === "" || root.disconnectSsid !== ssid) return
    const st = root.profileSettings
    if (!st) return
    let map = null
    try {
      map = st.read()
    } catch (e) {
      return
    }
    if (!map || typeof map !== "object") return
    root.applyProfileMap(ssid, map)
  }

  // Live re-sync: the backend may announce writes and late loads here, but
  // the payload is never applied raw - it has proven to disagree with the
  // settled state (stale or partial maps flip confirmed toggles back).
  // Instead every announcement schedules a full re-read, which converges
  // on the truth within one confirm beat.
  Connections {
    target: root.profileSettings

    function onSettingsChanged(settings) {
      if (root.profileSsid === "") return
      profileConfirm.restart()
    }
    function onLoaded() {
      if (root.profileSsid !== "") root.fetchProfile(root.profileSsid)
    }
  }

  // Named intervals (no bare numbers on any Timer): confirmation
  // beat, MAC copy hold, action timeout, poll cadence, speedtest slice.
  readonly property int profileConfirmMs: 500
  readonly property int macCopyHoldMs: 3000
  readonly property int actionTimeoutMs: 30000
  readonly property int pollMs: 500
  readonly property int speedtestSliceMs: 15000

  // Confirmation beat after a toggle write (see writeProfile).
  Timer {
    id: profileConfirm

    interval: root.profileConfirmMs
    repeat: false
    onTriggered: root.refreshProfile()
  }

  // --- link hardware (AP MAC) ---
  // The connected access point's BSSID, independent of the profile above
  // (open networks have an address but no settings to flip). Resolved by
  // vb-network-bssid, which self-detects the active wifi link.
  property string linkBssid: ""
  property bool macCopied: false

  function fetchLink() {
    if (linkProc.running) return
    linkProc.command = ["vb-network-bssid"]
    linkProc.running = true
  }

  function copyMac() {
    if (root.macCopied || root.linkBssid === "") return
    Exec.run(["wl-copy", "-n", root.linkBssid])
    root.macCopied = true
    macCopyTimer.restart()
  }

  Process {
    id: linkProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const s = String(text || "").trim()
        root.linkBssid = /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(s) ? s : ""
      }
    }
    stderr: StdioCollector {}
    onExited: function(exitCode) {
      if (exitCode !== 0) root.linkBssid = ""
    }
  }

  Timer {
    id: macCopyTimer

    interval: root.macCopyHoldMs
    repeat: false
    onTriggered: root.macCopied = false
  }

  // The row we acted on reports a failure (wrong PSK, no secrets, lost
  // network...) - surface the reason on that row, where it stands until the
  // network connects or the island reopens: nothing here clears it on a
  // tick, only success or a fresh action does. A rejected fresh secret is
  // discarded first (see actionFreshSecrets): the passphrase submit creates
  // the NM profile at activation time, so without the forget the wrong
  // password stays saved and every retry autoconnects with it instead of
  // re-prompting. The failure banner stays up either way, and the row is
  // unknown again, so opening it re-opens the blank passphrase field.
  // Credential failures also ping an urgent expiring toast - the banner is
  // only visible with the island open.
  Connections {
    target: root.actionTarget

    function onConnectionFailed(reason) {
      const kind = root.actionKind
      const ssid = root.actionSsid
      const net = root.actionTarget
      const fresh = root.actionFreshSecrets
      if (net && Model.shouldDiscardSecrets(kind, fresh, reason, root.failReasons)) {
        try {
          net.forget()
        } catch (e) {
        }
      }
      if (kind === "connect"
        && (reason === root.failReasons.WifiAuthTimeout || reason === root.failReasons.NoSecrets)) {
        Exec.run(Model.authFailureArgv(ssid))
      }
      root.failureSsid = ssid
      root.failureReason = Model.failureReasonText(reason, root.failReasons, fresh)
      root.actionSsid = ""
      root.actionKind = ""
      root.actionFreshSecrets = false
      root.actionTarget = null
    }

    function onConnectedChanged() {
      // Connect clearance: the acted-on network reaching the connected
      // state clears the action at once, ahead of the poll. A stale
      // failure for the same network goes with it - the password that
      // failed before is the one that just worked. Disconnect
      // and forget are fire-and-forget, so the handler cannot misfire
      // on them.
      if (root.actionKind === "connect") {
        if (root.failureSsid !== "" && root.failureSsid === root.actionSsid) {
          root.failureSsid = ""
          root.failureReason = ""
        }
        root.clearAction()
      }
    }
  }

  // NetworkManager's supplicant can take ~25s to reject a saved-but-wrong
  // PSK; the action must outlast it so the timeout lands on the right row.
  Timer {
    id: actionTimeout

    interval: root.actionTimeoutMs
    repeat: false
    onTriggered: {
      if (root.actionKind === "") return
      root.failureSsid = root.actionSsid
      root.failureReason = root.actionKind === "connect" ? "Timed out connecting"
        : (root.actionKind === "disconnect" ? "Timed out disconnecting" : "Timed out forgetting")
      root.actionSsid = ""
      root.actionKind = ""
      root.actionFreshSecrets = false
      root.actionTarget = null
    }
  }
  onActionKindChanged: {
    if (root.actionKind !== "") actionTimeout.restart()
    else actionTimeout.stop()
    // The connecting row sorts to the top (connected first) as soon as the
    // backend reports it, so seat the viewport there with it: a row picked
    // from below the fold would otherwise spin out of view.
    if (root.actionKind === "connect") otherList.seatTo(0, false, "network-connect")
  }

  // Kick a scan + immediate sync on show, then poll stats + networks.
  // The content is incubated fresh, so creation is open and every show
  // starts clean: no preserved dropdowns, passphrases, failures,
  // actions or profile state from the last visit. Teardown stops the
  // speedtest traffic and clears its results, so the next open lands on
  // a fresh section instead of stale figures.
  Component.onCompleted: {
    root.clearAction()
    root.passwordText = ""
    root.failureSsid = ""
    root.failureReason = ""
    root.clearProfile()
    // Fresh watcher reading for the open: the poll runs on its own
    // cadence, and an island opened onto a just-joined network should
    // not quote the verdict from before it.
    Core.Connectivity.refresh()
    if (root.wifiDevice) root.wifiDevice.scannerEnabled = true
    Qt.callLater(root.syncWifiNetworks)
  }
  Component.onDestruction: {
    root.stopSpeedtest()
    root.clearSpeedtest()
    root.stopStats()
  }

  Timer {
    id: poll

    interval: root.pollMs
    repeat: true
    // The content only exists while the host shows it, so an always-on
    // poll is open-gated by lifetime.
    running: true
    onTriggered: {
      // The route fork is the only child this section runs, and it stays off
      // the link while a speed test is saturating it: the measurement is the
      // user's own traffic and a competing child every tick is contention it
      // never needed. The counters below keep being read throughout - they
      // cost no fork, and the graph is what shows the test's own throughput.
      if (!routeProc.running && !root.speedtestRunning) routeProc.running = true
      // Counters only: the interface is whatever the last route reply named,
      // so the sample does not wait on the fork to land.
      if (root.statsIface !== "") root.updateStats(root.counterSample())
      // Freeze the wifi list while a dropdown is open: swapping the model
      // rebuilds the delegates, which steals a half-typed passphrase every
      // tick - and, with the cursor parked on an expanded row's buttons,
      // drops and restores the hover wash each tick so it flickers. Stats
      // keep polling; the list resumes on submit/cancel/close. The
      // completion latch still runs so a vanished AP cannot pin `busy`.
      if (root.passwordSsid === "" && root.disconnectSsid === "") root.syncWifiNetworks()
      else root.checkActionCompletion()
    }
  }

  // The interface the kernel would route 1.1.1.1 through, or "" while there
  // is no active route. Resolved by `ip` on its own argv: the interface is
  // the word after the first `dev` in a reply like "1.1.1.1 dev wlan0 src
  // 10.0.0.5 uid 1000", so no shell, no pipeline and no `cat` stands between
  // the tick and the number - one fork per tick where a script cost six.
  property string statsIface: ""

  Process {
    id: routeProc

    command: ["ip", "route", "get", "1.1.1.1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.noteRoute(text)
    }
    // `ip` reports a failed lookup on stderr and says nothing on stdout, and
    // nothing on stdout is the answer this section wants; the collector keeps
    // that text out of the shell's own log.
    stderr: StdioCollector {}
  }

  // The two byte counters, read straight off the tick. A generated sysfs
  // counter holds content from the moment it exists and raises no filesystem
  // event when that content moves, so a watcher on it can never fire and
  // FilePresence would answer a constant "present" - this section needs the
  // value, and only a read produces it. `blockLoading` keeps the read on the
  // calling turn, so re-pointing `path` is what makes the next tick see a
  // fresh number rather than the one it already cached.
  FileView { id: statsRx; blockLoading: true; printErrors: false }
  FileView { id: statsTx; blockLoading: true; printErrors: false }

  // One counter, as the digits it holds, or "" when the read did not
  // complete. The interface name comes from the kernel and cannot contain a
  // separator, and nothing is handed to a shell here, so an odd name fails
  // the read instead of reaching a command line.
  function readCounter(view, name) {
    view.path = ""
    view.path = "/sys/class/net/" + root.statsIface + "/statistics/" + name
    try {
      if (!view.waitForJob()) return ""
      return String(view.text()).trim()
    } catch (e) {
      return ""
    }
  }

  // The same key<TAB>value shape the section hands the library, built from the
  // two files. A counter this tick could not read is left out rather than
  // reported as a zero: an omitted key means nobody read it and the library
  // carries the last figure, while a zero would read as a link that moved
  // nothing.
  function counterSample() {
    let out = "iface\t" + root.statsIface + "\n"
    const rx = root.readCounter(statsRx, "rx_bytes")
    if (rx !== "") out += "rx_bytes\t" + rx + "\n"
    const tx = root.readCounter(statsTx, "tx_bytes")
    if (tx !== "") out += "tx_bytes\t" + tx + "\n"
    return out
  }

  // The route reply, reduced to an interface. A reply with no `dev` and an
  // `ip` that could not start at all are the same answer - no active route -
  // and the library already reads that as the link being down.
  function noteRoute(out) {
    const m = /\bdev\s+(\S+)/.exec(String(out || ""))
    const next = m === null ? "" : m[1]
    if (next === root.statsIface) return
    root.statsIface = next
    if (next === "") {
      // A route that went away has to reach the section as a link-down
      // reading rather than as a graph frozen on the interface it last saw.
      root.updateStats("")
      return
    }
    // A route that appeared is the one transition worth sampling at once:
    // waiting for the next tick would hold the metrics empty for another
    // 0.5s after the island opens. A changed interface re-seeds the
    // throughput baseline anyway, so the back-to-back pair cannot manufacture
    // a rate out of a short interval.
    root.updateStats(root.counterSample())
  }

  // Dropped with the island, and explicitly: a child of a destroyed content
  // tree has no reason to outlive it, and a route reply landing after close
  // would find state nobody is reading.
  function stopStats() {
    if (routeProc.running) routeProc.running = false
  }

  // One direction of the speed test: vb-network-speedtest streams one
  // Mbps line every 0.5s until killed. The 15s timer bounds each phase (down
  // then up): slow enough to watch the live figure settle, without
  // saturating the link forever.
  Process {
    id: speedtestProc

    stdout: SplitParser {
      onRead: line => root.updateSpeedtestLine(line)
    }
    // Exit and stream-finished have no guaranteed order: when a failed exit
    // beat the collector and published the generic message, replace it with
    // the specific one once it lands.
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.speedtestStderr = String(text || "").trim()
        if (root.speedtestError !== "" && root.speedtestStderr !== "")
          root.speedtestError = root.speedtestStderr
      }
    }
    onExited: function(exitCode) {
      speedtestTimer.stop()
      if (root.speedtestPending) {
        root.speedtestPending = false
        root.speedtestExpectedStop = false
        if (root.hasLink) Qt.callLater(root.startSpeedtest)
        else {
          root.speedtestRunning = false
          root.speedtestPhase = ""
        }
        return
      }
      if (!root.speedtestExpectedStop && exitCode !== 0) {
        root.speedtestError = root.speedtestStderr || "Speed test failed"
        root.speedtestPhase = ""
        root.speedtestRunning = false
        return
      }
      root.speedtestExpectedStop = false
      if (root.speedtestRunning) root.finishSpeedtestPhase()
      else root.speedtestPhase = ""
    }
  }

  Timer {
    id: speedtestTimer

    interval: root.speedtestSliceMs
    repeat: false
    onTriggered: root.stopSpeedtestPhase()
  }

  // --- content lent to the shared host ---
  // Incubated on show, destroyed after the close fade. The card sizes
  // from body.implicitHeight through islandContentHeight above.
    Item {
      anchors.fill: parent

      Column {
        id: body

        width: parent.width
        spacing: Ui.m

    // --- METRICS -> visible with any link, wifi or wired: LAN traffic
    // moves without internet, so only a missing link hides the section.
    // Show and hide glide through the height like the sections below.
    Column {
      visible: root.hasLink || root.connectInflight || height > 0
      width: parent.width
      spacing: Ui.m
      height: (root.hasLink || root.connectInflight) ? implicitHeight : 0
      clip: true

      Behavior on height {
        enabled: MotionPolicy.enabled
        Glide { duration: Ui.resizeMs }
      }

        Row {
          spacing: Ui.s

          Icon {
            anchors.verticalCenter: parent.verticalCenter
            name: "chart"
            colorKey: "foreground_1"
            size: 14
            opacity: 0.7
          }

          Title {
            level: 2
            anchors.verticalCenter: parent.verticalCenter
            text: "METRICS"
          }
        }

        GridLayout {
          id: metricsGrid
          width: parent.width
          columns: 4
          columnSpacing: Ui.xl
          rowSpacing: Ui.s

          MetricLabel { text: "Receiving" }
        Item {
          Layout.preferredWidth: root.metricValueWidth
          Layout.preferredHeight: 8
          MetricValue { visible: root.metricsLive; text: Model.formatRate(root.downloadRate); anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
          Rectangle {
            visible: !root.hasStats && !root._wifiOff
            width: parent.width * 0.7
            height: 8
            radius: RoundingPolicy.radius
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            color: Ui.tint("foreground_1", 0.14)
            opacity: 0.55
            SequentialAnimation on opacity {
              loops: Animation.Infinite
              running: !root.hasStats && !root._wifiOff
              SkeletonPulse { index: 0 }
            }
          }
          MetricValue { visible: !root.metricsLive && (root.hasStats || root._wifiOff); text: "--"; color: Ui.tint("foreground_1", 0.6); anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
        }

        MetricLabel { text: "Sending" }
        Item {
          Layout.preferredWidth: root.metricValueWidth
          Layout.preferredHeight: 8
          MetricValue { visible: root.metricsLive; text: Model.formatRate(root.uploadRate); anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
          Rectangle {
            visible: !root.hasStats && !root._wifiOff
            width: parent.width * 0.7
            height: 8
            radius: RoundingPolicy.radius
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            color: Ui.tint("foreground_1", 0.14)
            opacity: 0.55
            SequentialAnimation on opacity {
              loops: Animation.Infinite
              running: !root.hasStats && !root._wifiOff
              SkeletonPulse { index: 1 }
            }
          }
          MetricValue { visible: !root.metricsLive && (root.hasStats || root._wifiOff); text: "--"; color: Ui.tint("foreground_1", 0.6); anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
        }

        MetricLabel { text: "Downloaded" }
        Item {
          Layout.preferredWidth: root.metricValueWidth
          Layout.preferredHeight: 8
          MetricValue { visible: root.metricsLive; text: Model.formatBytes(root.totalRxBytes); anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
          Rectangle {
            visible: !root.hasStats && !root._wifiOff
            width: parent.width * 0.7
            height: 8
            radius: RoundingPolicy.radius
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            color: Ui.tint("foreground_1", 0.14)
            opacity: 0.55
            SequentialAnimation on opacity {
              loops: Animation.Infinite
              running: !root.hasStats && !root._wifiOff
              SkeletonPulse { index: 2 }
            }
          }
          MetricValue { visible: !root.metricsLive && (root.hasStats || root._wifiOff); text: "--"; color: Ui.tint("foreground_1", 0.6); anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
        }

        MetricLabel { text: "Uploaded" }
        Item {
          Layout.preferredWidth: root.metricValueWidth
          Layout.preferredHeight: 8
          MetricValue { visible: root.metricsLive; text: Model.formatBytes(root.totalTxBytes); anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
          Rectangle {
            visible: !root.hasStats && !root._wifiOff
            width: parent.width * 0.7
            height: 8
            radius: RoundingPolicy.radius
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            color: Ui.tint("foreground_1", 0.14)
            opacity: 0.55
            SequentialAnimation on opacity {
              loops: Animation.Infinite
              running: !root.hasStats && !root._wifiOff
              SkeletonPulse { index: 3 }
            }
          }
          MetricValue { visible: !root.metricsLive && (root.hasStats || root._wifiOff); text: "--"; color: Ui.tint("foreground_1", 0.6); anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
        }
    }
    }
    // End METRICS: the sections below are body siblings. Metrics
    // collapses (and clips) with the link, so anything nested under it
    // hides whenever the link drops.

    // --- SPEED TEST -> visible only with a live link and real internet:
    // measuring against fast.com without a route is a certain failure,
    // so the section stays hidden until a link is up and the watcher
    // reports full. The link half is backend-instant; the watcher half
    // is optimistic until its first poll lands, so the link half is what
    // hides the section the moment wifi drops. Each run
    // measures download then upload (15s
    // a phase via fast.com). Every meter states what it shows: the live
    // figure on its title row, and the bar fills 0..peak with both ends of
    // the scale labeled underneath. No dials, no fullscreen. The section
    // title itself is the toggle: hover crossfades the caps title into
    // the underlined action ("Start test" bright, "Stop test" red) with
    // a pointer cursor; click starts, click while running cancels. Show
    // and hide glide through the height like the networks section above.
    Column {
      visible: (root.hasInternet && root.hasLink) || root.connectInflight || height > 0
      width: parent.width
      spacing: Ui.s
      height: ((root.hasInternet && root.hasLink) || root.connectInflight) ? implicitHeight : 0
      clip: true

      Behavior on height {
        enabled: MotionPolicy.enabled
        Glide { duration: Ui.resizeMs }
      }

      Item {
        width: parent.width
        height: 26
        // Dimmed with the link down - covers the optimistic window before
        // the first poll, when the section still shows without a link.
        opacity: root.hasLink ? 1 : 0.45

        Row {
          id: speedTitleRow

          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Ui.s

          Icon {
            anchors.verticalCenter: parent.verticalCenter
            name: "gauge"
            colorKey: "foreground_1"
            size: 14
            opacity: 0.7
          }

          // Hover crossfade: the caps title swaps for the underlined
          // Start/Stop action, fading one out as the other fades in.
          // Opacity never touches implicit size, so both titles keep
          // their measure and the swap box holds the wider one
          // throughout; its own width eases when the action text flips.
          Item {
            id: speedTitleSwap

            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(capsTitle.implicitWidth, actionTitle.implicitWidth)
            height: Math.max(capsTitle.implicitHeight, actionTitle.implicitHeight)

            Behavior on width {
              enabled: MotionPolicy.enabled
              NumberAnimation { duration: Ui.fastMs }
            }

            Title {
              id: capsTitle

              level: 2
              anchors.verticalCenter: parent.verticalCenter
              text: "SPEED TEST"
              color: Ui.tint("foreground_1", 0.5)
              opacity: (root.hasLink && speedHover.containsMouse) ? 0 : 1

              Behavior on opacity {
                enabled: MotionPolicy.enabled
                NumberAnimation { duration: Ui.fastMs }
              }
            }

            Title {
              id: actionTitle

              level: 2
              anchors.verticalCenter: parent.verticalCenter
              text: root.speedtestRunning ? "Stop test" : "Start test"
              color: root.speedtestRunning ? Ui.solid("red") : Ui.solid("foreground_0")
              font.underline: true
              opacity: (root.hasLink && speedHover.containsMouse) ? 1 : 0

              Behavior on opacity {
                enabled: MotionPolicy.enabled
                NumberAnimation { duration: Ui.fastMs }
              }
              Behavior on color {
                ColorAnim {}
              }
            }
          }
        }

        MouseArea {
          id: speedHover

          x: 0
          anchors.verticalCenter: parent.verticalCenter
          width: speedTitleRow.width
          height: speedTitleRow.height
          enabled: root.hasLink
          hoverEnabled: true
          cursorShape: root.hasLink ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: {
            if (!root.hasLink) return
            if (root.speedtestRunning) root.stopSpeedtest()
            else root.startSpeedtest()
          }
        }
      }

      Column {
        width: parent.width
        spacing: Ui.s

        Column {
          width: parent.width
          spacing: 2

          Item {
            width: parent.width
            height: Math.max(speedDownLabel.implicitHeight, speedDownValue.implicitHeight)

            MetricLabel {
              id: speedDownLabel

              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Download"
            }

            MetricValue {
              id: speedDownValue

              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.speedtestDown !== "" ? root.speedtestDown + " Mbps" : "--"
              color: root.speedtestRunning && root.speedtestPhase === "down"
                ? Ui.solid("accent") : Ui.solid("foreground_0")
            }
          }

          ProgressBar {
            width: parent.width
            value: Math.min(100, (parseFloat(root.speedtestDown) || 0) / root.speedtestScaleDown * 100)
            dimWhenEmpty: false
          }

          Item {
            width: parent.width
            height: scaleDownCap.implicitHeight

            Title {
              level: 4
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "0 Mbps"
            }

            Title {
              id: scaleDownCap

              level: 4
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: Model.speedScaleLabel(root.speedtestScaleDown)
            }
          }
        }

        Column {
          width: parent.width
          spacing: 2

          Item {
            width: parent.width
            height: Math.max(speedUpLabel.implicitHeight, speedUpValue.implicitHeight)

            MetricLabel {
              id: speedUpLabel

              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Upload"
            }

            MetricValue {
              id: speedUpValue

              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.speedtestUp !== "" ? root.speedtestUp + " Mbps" : "--"
              color: root.speedtestRunning && root.speedtestPhase === "up"
                ? Ui.solid("accent") : Ui.solid("foreground_0")
            }
          }

          ProgressBar {
            width: parent.width
            value: Math.min(100, (parseFloat(root.speedtestUp) || 0) / root.speedtestScaleUp * 100)
            dimWhenEmpty: false
          }

          Item {
            width: parent.width
            height: scaleUpCap.implicitHeight

            Title {
              level: 4
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "0 Mbps"
            }

            Title {
              id: scaleUpCap

              level: 4
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: Model.speedScaleLabel(root.speedtestScaleUp)
            }
          }
        }
      }

      Title {
        level: 4
        visible: root.speedtestError !== ""
        width: parent.width
        text: root.speedtestError
        color: Ui.solid("red")
        wrapMode: Text.WordWrap
      }

      Title {
        level: 4
        visible: root.speedtestRunning
        width: parent.width
        text: root.speedtestPhase === "down" ? "Measuring download..." : "Measuring upload..."
      }
    }

    // Wi-Fi section header + list as one thing: regular wifi icon with
    // Title level 1 and the interface subtext (level 4,
    // Bluetooth-header style), radio toggle on the right border. Pinned
    // visible in every radio/link state: with wifi off this header is the
    // only thing left in the island and the only way back on, so nothing
    // may gate it. The network list below spawns directly under it and
    // hides while off.
    Row {
      visible: true
      width: parent.width
      spacing: Ui.m

      Icon {
        id: wifiHeaderIcon

        anchors.verticalCenter: parent.verticalCenter
        name: "wifi-3"
        colorKey: "foreground_0"
        size: 20
        opacity: root._wifiOff ? 0.5 : 1
      }

      Column {
        width: parent.width - wifiHeaderIcon.width - (wifiToggle.visible ? wifiToggle.implicitWidth + 2 * parent.spacing : parent.spacing)
        spacing: 2

        Title {
          level: 1
          width: parent.width
          text: "Wi-Fi"
          elide: Text.ElideRight
        }

        Title {
          level: 4
          width: parent.width
          text: root.wifiHeaderSubtext
          elide: Text.ElideRight
        }
      }

      Toggle {
        id: wifiToggle

        anchors.verticalCenter: parent.verticalCenter
        // No radio, no switch: systems without a wifi adapter (wired-only,
        // VMs) hide the toggle and keep the header as a "No adapter" label.
        visible: root.wifiPresent
        checked: Networking.wifiEnabled
        // Never dimmed, never gated: this is the bar middle-click as a
        // switch, and soft-off must always be undoable from the island.
        // The hardware block cannot be lifted from software anyway, so a
        // faded-but-dead control would only strand the user.
        onToggled: state => {
          Networking.wifiEnabled = state
        }
      }
    }

    // --- Wi-Fi networks -- single list under the header above, connected
    // first always. Visible only while the radio is on: a soft-disabled
    // radio hides the list and the header toggle is what turns it back
    // on. Show and hide glide through the height (visible follows it
    // down) so the window breathes instead of jumping; the positioner
    // skips the section once it lands at 0.
    Item {
      visible: (root.wifiPresent && !root._wifiOff) || height > 0
      width: parent.width
      height: (root.wifiPresent && !root._wifiOff) ? otherColumn.implicitHeight : 0
      clip: true

      Behavior on height {
        enabled: MotionPolicy.enabled
        Glide { duration: Ui.resizeMs }
      }

      Column {
        id: otherColumn
        width: parent.width
        spacing: 0

        Item {
          visible: root.wifiRows.length > 0 || root.otherSkeletonMode
          width: parent.width
          height: otherList.height

          List {
              id: otherList
              // No keyboard cursor here: dropdown-open rows tint themselves
              // in the delegate, and a shared bar would sit on row 0
              // forever.
              selectionHighlight: false
              // Dropdown rows reveal through the shared contract (see
              // networkDelegate): the claim is the row index, the pursuit
              // holds it as the slot grows and eases on every height step.
              pursuitAnimated: true
              width: parent.width - 8
              height: Model.wifiListViewportHeight(otherList.contentHeight)
              // Window breathes with the row count: rows arriving or
              // leaving glide the list (and through it the island)
              // instead of snapping it. Row motion itself stays gated
              // on syncAnimated below; this is only the window following.
              Behavior on height {
                enabled: MotionPolicy.enabled
                Glide { duration: Ui.resizeMs }
              }
              spacing: 2
              interactive: !root.otherSkeletonMode && otherList.contentHeight > otherList.height
              // Source and delegate are written, not bound: syncOtherList
              // owns the pair and the order it has to land in. They start
              // unset and are applied on completion.
              Component.onCompleted: root.syncOtherList()
              clip: true
              // Row motion rides these on a sync the model reads as a move. A
              // single promotion is one row crossing groups, which lands
              // with no transition; a bulk reshuffle shifts several rows
              // and does move them. New scan rows never fly (no add:),
              // and syncAnimated holds the durations at zero for an
              // un-armed sync, so a scan's signal resort changes content in
              // place with no transition either.
              move: Transition { NumberAnimation { property: "y"; duration: MotionPolicy.enabled && root.syncAnimated ? Ui.normalMs : 0; easing.type: Easing.OutCubic } }
              displaced: Transition { NumberAnimation { property: "y"; duration: MotionPolicy.enabled && root.syncAnimated ? Ui.normalMs : 0; easing.type: Easing.OutCubic } }
            }

          ScrollBar {
            flickable: otherList
            anchors.right: parent.right
            anchors.rightMargin: 1
            anchors.top: otherList.top
            anchors.topMargin: 1
            anchors.bottom: otherList.bottom
            anchors.bottomMargin: 1
            thickness: 3
            radius: RoundingPolicy.radius
          }
        }

        // Filler skeleton rows under the live ones, up to the four-row
        // window shared with skeleton mode: static whenever real rows are
        // on screen (the pulse below only runs there), so discoveries swap
        // placeholders for rows in place instead of growing the section.
        // The extra 2px is the junction gap the two lists' own spacings
        // cannot place - without it a filled section lands 2px short of
        // the skeleton block it replaces.
        Item {
          visible: !root.otherSkeletonMode && root.wifiRows.length < 4
          width: parent.width
          height: fillerList.height + (root.wifiRows.length > 0 ? 2 : 0)

          List {
            id: fillerList

            selectionHighlight: false
            width: parent.width
            y: root.wifiRows.length > 0 ? 2 : 0
            height: fillerList.contentHeight
            stableModel: root._otherSkeletonRows.slice(0, Math.max(0, 4 - root.wifiRows.length))
            spacing: 2
            interactive: false
            delegate: otherSkeletonDelegate
            clip: true
          }
        }
      }
    }

  // Shared network row delegate -> used by both per-section Lists.
  Component {
    id: networkDelegate

    Rectangle {
      id: row

      // Wifi case renders from the ScriptModel: it exposes one role,
      // `modelData`, and it holds the whole record - so `modelData` IS the
      // display row here (not a context object to read the payload out
      // of), and the row's fields are read straight off it rather than
      // scanned out of displayRows per row per poll. `key` is the model's
      // identity field, not a role: nothing fills a delegate property for
      // it, so declaring one required would leave every row unbuildable.
      required property var modelData
      required property int index

      width: ListView.view ? ListView.view.width : 240
      // Base line plus whichever dropdown is open; closed slots
      // animate to zero height, so the row tracks the motion 1:1.
      // The shared DropdownSlot's top breathing comes from the
      // consumer's anchor margin (Ui.m), which sits outside the
      // slot's own height -> fold it into the row so the dropdown
      // is fully visible and its buttons keep their Column parent
      // with proper spacing.
      height: baseRow.height + passSlot.height + discSlot.height
        + ((row.isPasswordRow || row.isDisconnectRow) ? Ui.m : 0)
      // Selected (dropdown open) reads like Settings/menus: the
      // whole row -> base line plus its dropdown -> tints with
      // background_2 instantly, not a hover wash. Keeps the
      // dropdown's buttons visibly parented and spaced.
      color: (row.isPasswordRow || row.isDisconnectRow) ? Ui.solid("background_2")
        : (hoverArea.containsMouse ? Ui.tint("foreground_1", 0.06) : "transparent")
      radius: RoundingPolicy.radius

      // The owning shared List, reached through the view attached
      // property. Held as var so the reveal contract is written against
      // the library, not the builtin ListView.
      readonly property var listView: row.ListView.view

      // Hand an opening dropdown to the shared reveal/pursuit contract:
      // revealEnd claims the row and seats it fully into view, and the
      // library pursuit re-aims the shared ease on every height step, so
      // the scroll tracks the dropdown 1:1 instead of waiting it out.
      // Downward only, nothing persists - a later manual scroll or close is
      // never fought, and the pursuit skips while the user is dragging.
      //
      // The claim is established on open only. Height steps are the
      // library's job (it watches the claimed delegate directly), so
      // calling this per step would re-seat instantly and drop the easing.
      // Release on close so a recycled delegate never keeps a claim on a
      // row it no longer shows.
      function revealOpen() {
        const v = row.listView
        if (!v) return
        if (!(row.isPasswordRow || row.isDisconnectRow)) {
          if (v.autoRevealIndex === row.index) v.autoRevealIndex = -1
          return
        }
        v.revealEnd(row.index)
      }
      // The profile toggles live and die with the disconnect dropdown:
      // opening loads the backend state (plus the AP address), closing
      // drops everything.
      function syncProfileOnDropdown() {
        if (row.isDisconnectRow) {
          root.fetchProfile(row.modelData.ssid)
          root.fetchLink()
        } else {
          root.clearProfile()
        }
      }
      // Focus guard for the passphrase field: a fresh open grabs the
      // caret and starts masked (blank text comes from connectRow).
      // Closing the row's dropdown - Escape, submit, row toggle, another
      // row picked - must un-focus the field, or the hidden field keeps
      // the caret: clicking back into this row would land on an already
      // activated field, and while it holds focus the shared passwordText
      // Binding stays disabled, so stale text would never heal.
      // QML allows one handler per signal, so the reveal claim shares this
      // one instead of declaring a second onIsPasswordRowChanged. The
      // field itself only exists while the slot holds it, so the guard
      // reads the live instance and the field's own Component.onCompleted
      // covers the open that constructs it.
      onIsPasswordRowChanged: {
        revealOpen()
        const field = passSlot.nestedItem
        if (row.isPasswordRow) {
          if (field) {
            field.revealed = false
            field.grabFocus()
          }
        } else if (field) {
          field.releaseFocus()
        }
      }
      onIsDisconnectRowChanged: {
        revealOpen()
        syncProfileOnDropdown()
      }
      Component.onCompleted: Qt.callLater(revealOpen)

      readonly property bool connected: !!(row.modelData && row.modelData.connected)
      readonly property bool outOfReach: !!(row.modelData && row.modelData.outOfReach)
      readonly property bool actionOn: !!(row.modelData && root.actionSsid === row.modelData.ssid && root.actionKind !== "")
      readonly property bool connecting: row.actionOn && root.actionKind === "connect"
      readonly property bool failed: !!(row.modelData && root.failureSsid === row.modelData.ssid)
      // In-flight action or failure keeps the status word on the right;
      // otherwise the freed edge shows only the lock when the network is
      // secured. Sharing moved into the connected row's dropdown (first
      // button), so the edge never steals row clicks.
      readonly property bool showStatusText: (row.actionOn && !row.connecting || row.failed) && !root._wifiOff
      readonly property bool lockVisible: !row.showStatusText && !!(row.modelData && row.modelData.secured)
      readonly property bool isPasswordRow: !!(row.modelData && root.passwordSsid === row.modelData.ssid)
      readonly property bool isDisconnectRow: !!(row.modelData && root.disconnectSsid === row.modelData.ssid)
      readonly property string ssid: {
        const s = row.modelData ? String(row.modelData.ssid || "") : ""
        return s === "" ? "(hidden network)" : s
      }

      Item {
        id: baseRow

        width: parent.width
        height: 40

        Item {
          id: iconWrap
          anchors.left: parent.left
          anchors.leftMargin: root.rowPad
          anchors.verticalCenter: parent.verticalCenter
          width: 28
          height: 28
          Icon {
            anchors.fill: parent
            name: "wifi-3"
            colorKey: row.connected && !root._wifiOff ? "accent" : "foreground_1"
            dimTiers: (root._wifiOff || !row.modelData || row.outOfReach) ? 0
              : Model.strengthDimTiers(row.modelData.signal / 100)
            size: 28
            opacity: row.connecting ? 0 : (row.outOfReach ? 0.5 : 1)
            Behavior on opacity { enabled: MotionPolicy.enabled; NumberAnimation { duration: Ui.fastMs } }
          }
          Icon {
            id: connectSpinner
            anchors.centerIn: parent
            name: "update"
            colorKey: "foreground_1"
            size: 20
            opacity: row.connecting ? 0.9 : 0
            visible: opacity > 0.01
            transformOrigin: Item.Center
            Behavior on opacity { enabled: MotionPolicy.enabled; NumberAnimation { duration: Ui.fastMs } }
            RotationAnimation on rotation {
              from: 0
              to: 360
              duration: 1000
              loops: Animation.Infinite
              running: row.connecting
              onRunningChanged: if (!running) connectSpinner.rotation = 0
            }
          }
        }

        Column {
          anchors.left: iconWrap.right
          anchors.leftMargin: Ui.s
          anchors.right: statusText.left
          anchors.rightMargin: Ui.m
          anchors.verticalCenter: parent.verticalCenter
          spacing: 1

          // Primary line: the SSID, with a watcher verdict (if any) riding
          // beside it ("SSID • login required", lowercase, thick dot). The
          // connected state itself is carried by the accent-coloured icon, so
          // no "connected" word is repeated here. One Text keeps the suffix
          // glued to the name through elision - no Row width math to drift
          // apart. Dot renders in subtext, word in its own ink. A remembered
          // network says so in the subtext instead.
          Title {
            level: 3
            width: parent.width
            textFormat: Text.RichText
            text: Model.ssidWithStatus(row.ssid, row.connected && !root._wifiOff, String(Ui.solid("accent")), String(Ui.tint("foreground_1", 0.5)), root.linkNote, root.linkNoteHex)
            color: row.connected ? Ui.solid("foreground_0") : Ui.solid("foreground_1")
            font.bold: row.connected
          }

          Title {
            level: 4
            width: parent.width
            text: root._wifiOff ? "Unavailable" : Model.subtextFor(row.modelData)
          }
        }

        Item {
          id: statusText

          anchors.right: parent.right
          anchors.rightMargin: root.rowPad + 6
          anchors.verticalCenter: parent.verticalCenter
          width: {
            if (row.showStatusText) return statusLabel.implicitWidth
            if (row.lockVisible) return lockIcon.implicitWidth
            return 0
          }
          height: Math.max(statusLabel.implicitHeight, lockIcon.implicitHeight)

          Title {
            id: statusLabel
            level: 4
            visible: row.showStatusText
            anchors.verticalCenter: parent.verticalCenter
            text: row.failed ? root.failureReason
              : (root.actionKind === "connect" ? "Connecting..."
                : root.actionKind === "forget" ? "Forgetting..." : "Disconnecting...")
            color: row.failed ? Ui.solid("red") : Ui.tint("foreground_1", 0.6)
            font.bold: true
          }

          Icon {
            id: lockIcon

            visible: row.lockVisible
            anchors.verticalCenter: parent.verticalCenter
            name: "lock"
            colorKey: "foreground_1"
            size: 14
            opacity: 0.55
          }
        }
      }

      DropdownSlot {
        id: passSlot

        anchors.top: baseRow.bottom
        topGap: Ui.m
        anchors.left: parent.left
        anchors.right: parent.right
        open: row.isPasswordRow

        // Deferred body: the field belongs to the one row that is open, so
        // the slot builds it on open and releases it with the close fade
        // instead of every network row carrying an editor it never shows.
        nestedContent: Component {
          Column {
            x: Ui.m
            width: parent.width - 2 * Ui.m
            spacing: Ui.m

            // No Connect button on purpose: Enter submits the passphrase, so
            // the field alone keeps the dropdown compact.
            InputField {
              id: passField

              width: parent.width
              echoMode: TextInput.Password
              // Eye in the field's right edge unmasks the typed passphrase;
              // it is the only right-edge affordance (no clear button -
              // Ctrl+A + backspace clears).
              revealable: true
              clearable: false
              placeholder: "Password"
              onEdited: text => root.passwordText = text
              onAccepted: text => root.submitPassword(text)
              onEscaped: root.passwordSsid = ""
              Component.onCompleted: {
                if (row.isPasswordRow) passField.grabFocus()
              }
            }
          }
        }

        // The field has no scope of its own while the slot is closed, so
        // the Binding rides the live instance: it feeds root.passwordText
        // into a field that does not hold the caret and lifts as soon as
        // the row is no longer the open one, which is what lets a reopened
        // row start from the pending value instead of the last keystroke.
        Binding {
          target: passSlot.nestedItem
          property: "text"
          value: root.passwordText
          when: row.isPasswordRow && passSlot.nestedItem !== null
            && !passSlot.nestedItem.focused
          restoreMode: Binding.RestoreBinding
        }
      }

      DropdownSlot {
        id: discSlot

        anchors.top: passSlot.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        // Stacked below the password slot: no top gap while it is live,
        // full padding when it is shut.
        topGap: (passSlot.open || passSlot.closing) ? 0 : Ui.m
        open: row.isDisconnectRow

        // Deferred body: four buttons, three profile toggles and the MAC
        // row per network row delegate is the most expensive body in the
        // island, and at most one of those rows is ever open. The slot
        // builds it for that row and releases it with the close fade, so a
        // scanned neighbourhood of 40 SSIDs costs 40 rows, not 40 control
        // sets. Nothing here reads slot geometry back, and the profile
        // state the toggles show is fetched on open (see
        // syncProfileOnDropdown), so the body is self-contained.
        nestedContent: Component {
          Column {
            x: Ui.m
            width: parent.width - 2 * Ui.m
            spacing: Ui.m

            Row {
              id: discBtnRow

              width: parent.width
              spacing: Ui.s
              // Equal split among the visible buttons. Share shows for any
              // saved network: vb-network-qr --ssid reads the profile by
              // SSID, connected or not. The primary button is Disconnect on
              // the active link, Connect on a known-but-disconnected row;
              // both hide with the radio off. Forget always shows - the
              // dropdown only opens for known networks.
              readonly property int shown: (shareBtn.visible ? 1 : 0)
                + (connectDisconnectBtn.visible ? 1 : 0) + (forgetBtn.visible ? 1 : 0)
              readonly property real split: (discBtnRow.width - (discBtnRow.shown - 1) * discBtnRow.spacing) / Math.max(1, discBtnRow.shown)

              DropdownButton {
                id: shareBtn

                width: discBtnRow.split
                text: "Share"
                accent: Ui.solid("foreground_1")
                onClicked: root.qrRequested(row.modelData.ssid)
              }

              DropdownButton {
                id: connectDisconnectBtn
                width: discBtnRow.split
                text: row.connected && !root._wifiOff ? "Disconnect" : "Connect"
                visible: !root._wifiOff
                accent: Ui.solid("accent")
                // Connecting from the dropdown closes it at once: the row
                // carries the "Connecting..." status while runAction tracks
                // the terminal state.
                onClicked: {
                  if (row.connected && !root._wifiOff) {
                    root.disconnectRow(row.modelData)
                    return
                  }
                  root.closeDropdowns()
                  root.runAction("connect", row.modelData.ssid, n => n.connect())
                }
              }

              DropdownButton {
                id: forgetBtn

                width: discBtnRow.split
                text: "Forget"
                accent: Ui.solid("red")
                onClicked: root.forgetRow(row.modelData)
              }
            }

            // Per-line connection options, one toggle per line. Only the
            // backend can provide them: the section stays hidden unless a
            // settings profile resolved and parsed (unknown networks,
            // non-NM backends). Writes persist; ip flips apply on the next
            // activation, autoconnect immediately.
            Column {
              visible: root.profileReady && root.profileSsid === row.modelData.ssid
              width: parent.width
              spacing: Ui.s

              Item {
                width: parent.width
                height: Math.max(autoConnLabel.implicitHeight, autoConnToggle.implicitHeight)

                Title {
                  id: autoConnLabel

                  level: 4
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Auto connect"
                }

                Toggle {
                  id: autoConnToggle

                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                                    checked: root.profileAutoconnect
                  onToggled: state => root.writeProfile("autoconnect", state)
                }
              }

              Item {
                width: parent.width
                height: Math.max(ipv4Label.implicitHeight, ipv4Toggle.implicitHeight)

                Title {
                  id: ipv4Label

                  level: 4
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Enable IPv4"
                }

                Toggle {
                  id: ipv4Toggle

                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                                    checked: root.profileIpv4
                  onToggled: state => root.writeProfile("ipv4", state)
                }
              }

              Item {
                width: parent.width
                height: Math.max(ipv6Label.implicitHeight, ipv6Toggle.implicitHeight)

                Title {
                  id: ipv6Label

                  level: 4
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Enable IPv6"
                }

                Toggle {
                  id: ipv6Toggle

                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                                    checked: root.profileIpv6
                  onToggled: state => root.writeProfile("ipv6", state)
                }
              }
            }

            // Link hardware row: the access point's BSSID with a copy
            // affordance. Shows on its own (no profile needed); copying swaps
            // the label to "copied" for 3s, during which the button is inert.
            // Same neutral chrome as Share - no accent colors.
            Divider {
              visible: root.linkBssid !== ""
              width: parent.width
              color: Ui.tint("background_3", 0.8)
            }

            Item {
              visible: root.linkBssid !== ""
              width: parent.width
              height: Math.max(macLabel.implicitHeight, macCopyBtn.implicitHeight)

              Title {
                id: macLabel

                level: 4
                width: parent.width - macCopyBtn.width - Ui.s
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "MAC Address: " + root.linkBssid
                elide: Text.ElideRight
              }

              DropdownButton {
                id: macCopyBtn

                // Small utility size (matches the speedtest Run button), fixed
                // width so the copy/copied swap never moves the row. Disabled
                // is lib-owned (no hover/press wash, no clicks, faded) - the
                // label swap is the only per-state change here.
                width: 70
                height: 22
                implicitHeight: 22
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.macCopied ? "copied" : "copy"
                accent: Ui.solid("foreground_1")
                enabled: !root.macCopied
                onClicked: {
                  if (!root.macCopied) root.copyMac()
                }
              }
            }
          }
        }
      }

      MouseArea {
        id: hoverArea

        anchors.fill: baseRow
        enabled: !root.busy
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.connectRow(row.modelData)
      }
    }
  }

  // Skeleton for the Wi-Fi list - flashes only while a scan is in
  // flight with nothing to show yet (e.g. wifi just turned on).
  Component {
    id: otherSkeletonDelegate

    Rectangle {
      id: skeletonRow

      required property int index
      width: ListView.view ? ListView.view.width : 240
      height: 40
      color: ((Number(skeletonRow.index) || 0) % 2) === 1 ? Ui.tint("foreground_1", 0.05) : "transparent"

      Row {
        anchors.fill: parent
        anchors.leftMargin: root.rowPad
        anchors.rightMargin: root.rowPad + 6
        spacing: Ui.s

        Rectangle {
          width: 28
          height: 28
          radius: RoundingPolicy.radius
          anchors.verticalCenter: parent.verticalCenter
          color: Ui.tint("foreground_1", 0.13)
          opacity: 0.55

          SequentialAnimation on opacity {
            loops: Animation.Infinite
            running: root._otherSkeleton
            SkeletonPulse { index: skeletonRow.index }
          }
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - 28 - 14 - 2 * Ui.s
          spacing: 4

          Rectangle {
            width: parent.width * (0.48 + ((Number(skeletonRow.index) || 0) % 3) * 0.16)
            height: 8
            radius: RoundingPolicy.radius
            color: Ui.tint("foreground_1", 0.14)
            opacity: 0.55

            SequentialAnimation on opacity {
              loops: Animation.Infinite
              running: root._otherSkeleton
              SkeletonPulse { index: skeletonRow.index }
            }
          }

          Rectangle {
            width: parent.width * 0.72
            height: 6
            radius: RoundingPolicy.radius
            color: Ui.tint("foreground_1", 0.10)
            opacity: 0.55

            SequentialAnimation on opacity {
              loops: Animation.Infinite
              running: root._otherSkeleton
              SkeletonPulse { index: skeletonRow.index; offset: 150 }
            }
          }
        }

        Rectangle {
          width: 14
          height: 14
          radius: RoundingPolicy.radius
          anchors.verticalCenter: parent.verticalCenter
          color: Ui.tint("foreground_1", 0.13)
          opacity: 0.55
          visible: ((Number(skeletonRow.index) || 0) % 2) === 0

          SequentialAnimation on opacity {
            loops: Animation.Infinite
            running: root._otherSkeleton && ((Number(skeletonRow.index) || 0) % 2) === 0
            SkeletonPulse { index: skeletonRow.index; offset: 75 }
          }
        }
      }
    }
  }
}
}
}
