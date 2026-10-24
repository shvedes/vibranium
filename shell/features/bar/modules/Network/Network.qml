pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Networking
import Quickshell.Io
import qs.common
import qs.features.bar
import qs.services as Core
import "Model.js" as Model
import "../../../../common/capture/ShotLib.js" as ShotLib

// Network module: shows the link state with a single wifi glyph.
// Connected via wifi -> wifi-3 in the default foreground color; wired ->
// the ethernet icon; no network at all -> wifi-3 in red. Hovering shows a
// tooltip with the connection (the SSID, under the same glyph, or "Using
// ethernet connection"); clicking opens the island with live transfer
// metrics and the known + available networks.
BarModule {
  id: root

  // Icon geometry comes from the bar tokens (fixed slot / optical canvas).
  // The pill is one slot wide at rest - so the hover and click target stays
  // constant across glyphs - and grows only for the access-point-name flash.
  readonly property real slotWidth: root.iconSlot

  // --- live network state (Quickshell.Networking, NetworkManager backend) ---

  readonly property var devices: Networking.devices ? Networking.devices.values : []
  readonly property var wifiDevice: {
    for (const d of root.devices) if (d.type === DeviceType.Wifi) return d
    return null
  }
  // The connected wifi network, or any connected network (wired counts).
  readonly property var connectedNetwork: {
    for (const d of root.devices) {
      const nets = d.networks ? d.networks.values : []
      for (const n of nets) if (n.connected) return n
    }
    return null
  }
  readonly property var connectedWifi: root.connectedNetwork
    && root.connectedNetwork.device === root.wifiDevice ? root.connectedNetwork : null

  readonly property string ssid: root.connectedWifi ? root.connectedWifi.name : ""
  // Link changes are user-meaningful events: wifi roam, cable plug,
  // captive drop. Backend lists rebuild with fresh object wrappers
  // while settling, so gate on the stable link key, not identity.
  //
  // Empty means "not read yet", and it is load-bearing: this module is
  // constructed before NetworkManager has settled, so the first reading is
  // almost always `off`. Seeding that from a placeholder reported a
  // transition that never happened - the shell announcing the network
  // dropped, seconds before it came up.
  property string _lastLinkKey: ""

  // One definition of "what the link is", read by both the seed and the
  // change handler. They have to agree: if the seed computed the key
  // differently from the handler, the first real change would compare against
  // a string the handler never produces and either be dropped or invented.
  function _linkKey(): string {
    return root.connectedWifi ? "wifi:" + root.ssid
      : (root.connectedNetwork ? "wired" : "off")
  }

  // Seeded at CONSTRUCTION, not lazily on the first firing. A lazy seed is
  // wrong whenever the first firing is also the first real change - the seed
  // swallows the transition that actually happened, so a link coming up at
  // startup reported nothing and only its later loss was seen. Taking the
  // reading when the module appears means every later change is real.
  Component.onCompleted: root._lastLinkKey = root._linkKey()

  onConnectedNetworkChanged: {
    const key = root._linkKey()
    if (key === root._lastLinkKey) return
    const was = root._lastLinkKey
    root._lastLinkKey = key
    // Defensive, and it should be unreachable: the seed is taken above, so
    // a change from "not read yet" has no before to report.
    if (was === "") return
    // The key is already the right shape for this: it names the link on BOTH
    // sides, so a wifi roam, a cable plug and a captive-portal drop are all one
    // form, and a switch from wifi to ethernet reads as what it is instead of
    // losing the drop. `summarize` bounds the SSID, the one unbounded string
    // here - it is already shown in this module's tooltip, so bounding it loses
    // nothing a reader could not see, and an SSID is network-supplied enough
    // that it must not be able to fill a journal line.
    Log.info("link " + Log.summarize(was) + " > " + Log.summarize(key))
    // The equality test above is the load-bearing line in this module: backend
    // lists rebuild with fresh wrappers while settling, so a change that reaches
    // here has a different KEY, not merely a different object. This says so at
    // the moment it is true, which is what makes a missing line meaningful.
    Log.debug("link key changed: " + Log.summarize(was) + " -> " + Log.summarize(key))
    // The access-point-name flash, armed by the same transition the two lines
    // above report. The shared window refuses to open until it has settled,
    // which is what keeps a boot quiet: NetworkManager reports the whole graph
    // while it settles, so the first change this handler sees - the link going
    // from "not read yet" to up - is the graph arriving rather than a
    // connection anybody made. Fullscreen-deferred (see _flashPending):
    // parks while fullscreen is up and replays on exit, so nothing ever
    // expands over fullscreen content.
    root._fireLinkFlash()
  }

  // Icon + color. Connected wifi: wifi-3 in foreground, wired:
  // ethernet, wifi off with no link: wifi-off with its crossing line red
  // and the body dimmed (the bluetooth-off treatment), no network:
  // wifi-3 in red. The bar icon always shows the full glyph - signal
  // tiers only matter in the island's rows, where the actual networks
  // are listed. A wired link wins over a disabled radio: the cable is
  // the link that is up, so ethernet paints even while wifi is off.
  readonly property bool wifiOff: root.wifiDevice !== null && !Networking.wifiEnabled
  readonly property string iconName: root.connectedNetwork
    ? (root.connectedWifi ? "wifi-3" : "ethernet") : (root.wifiOff ? "wifi-off" : "wifi-3")
  readonly property string iconColor: {
    if (root.connectedNetwork) {
      if (root.linkNote === "metered") return "yellow"
      return "foreground_0"
    }
    return root.wifiOff ? "foreground_1" : "red"
  }
  // Second tone for the glyph's indicator elements. Only the wifi-off
  // crossing line takes red, mirroring bluetooth-off's dimmed body with
  // a red fault mark. Ethernet carries no indicator, and the plain
  // disconnected glyph carries no accent at all.
  readonly property string iconAccent: (!root.connectedNetwork && root.wifiOff) ? "red" : ""

  // Connectivity verdict, shared with the island: "portal", "offline",
  // "metered", "configuring" or "".
  readonly property string linkNote: Core.Connectivity ? Core.Connectivity.linkNote : ""
  readonly property bool _connectingWifi: root.connectedWifi !== null
    && root.connectedWifi.state === ConnectionState.Connecting

  // --- tooltip throughput, sampled only while the tooltip is shown ---
  property bool hasStats: false
  property real downloadRate: 0
  property real uploadRate: 0
  property real totalRxBytes: 0
  property real totalTxBytes: 0
  property var prevThroughput: null
  property string statsIface: ""

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
  function counterSample() {
    let out = "iface\t" + root.statsIface + "\n"
    const rx = root.readCounter(statsRx, "rx_bytes")
    if (rx !== "") out += "rx_bytes\t" + rx + "\n"
    const tx = root.readCounter(statsTx, "tx_bytes")
    if (tx !== "") out += "tx_bytes\t" + tx + "\n"
    return out
  }
  function noteRoute(out) {
    const m = /\bdev\s+(\S+)/.exec(String(out || ""))
    const next = m === null ? "" : m[1]
    if (next === root.statsIface) return
    root.statsIface = next
    if (next === "") {
      root.updateStats("")
      return
    }
    root.updateStats(root.counterSample())
  }

  FileView { id: statsRx; blockLoading: true; printErrors: false }
  FileView { id: statsTx; blockLoading: true; printErrors: false }

  Process {
    id: routeProc

    command: ["ip", "route", "get", "1.1.1.1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.noteRoute(text)
    }
    stderr: StdioCollector {}
  }

  Timer {
    id: statsPoll

    interval: 500
    repeat: true
    running: root.hovered
    onTriggered: {
      if (!routeProc.running) routeProc.running = true
      if (root.statsIface !== "") root.updateStats(root.counterSample())
    }
  }

  onHoveredChanged: {
    if (root.hovered) {
      root.prevThroughput = null
      root.statsIface = ""
      root.hasStats = false
      root.downloadRate = 0
      root.uploadRate = 0
      root.totalRxBytes = 0
      root.totalTxBytes = 0
      Qt.callLater(() => {
        if (!root.hovered) return
        if (!routeProc.running) routeProc.running = true
      })
    } else {
      if (routeProc.running) routeProc.running = false
    }
  }

  Component.onDestruction: {
    statsPoll.stop()
    if (routeProc.running) routeProc.running = false
  }

  // Map the link verdict to the word + color the island uses for the
  // connected row.
  readonly property string _statusWord: {
    if (!root.connectedWifi) return ""
    if (root._connectingWifi) return "connecting"
    const note = root.linkNote
    if (note === "offline") return "no internet"
    if (note === "metered") return "metered"
    if (note === "portal") return "login required"
    if (note === "configuring") return "configuring..."
    return ""
  }
  readonly property string _statusColor: {
    const w = root._statusWord
    if (w === "no internet") return Ui.solid("red")
    if (w === "metered" || w === "login required") return Ui.solid("yellow")
    if (w === "configuring...") return Ui.tint("foreground_1", 0.5)
    if (w === "connecting") return Ui.tint("foreground_1", 0.6)
    return ""
  }
  readonly property string _apText: {
    if (root.connectedWifi) {
      const safe = Model.escapeHtml(root.ssid)
      if (root._statusWord !== "") {
        return safe + ' (<font color="' + root._statusColor + '">' + root._statusWord + '</font>)'
      }
      return safe
    }
    if (root.connectedNetwork) return "Using ethernet connection"
    if (root.wifiOff) return "Wi-Fi off"
    return "No network"
  }

  // Tooltip rows: the AP (with its state in parentheses), then download/
  // upload speeds and totals on one line each.
  readonly property string tooltipText: root._apText
  readonly property var tipLines: {
    let lines = []
    lines.push({
      icon: root.iconName,
      iconColor: root.iconColor,
      dimTiers: root.connectedWifi ? Model.strengthDimTiers(root.connectedWifi.signalStrength) : 0,
      text: root._apText,
      markup: root.connectedWifi && root._statusWord !== ""
    })
    if (root.connectedNetwork) {
      const dlSpeed = root.hasStats ? Model.formatRate(root.downloadRate) : "--"
      const ulSpeed = root.hasStats ? Model.formatRate(root.uploadRate) : "--"
      const dlTotal = root.totalRxBytes > 0 ? Model.formatBytes(root.totalRxBytes) : (root.hasStats ? Model.formatBytes(root.totalRxBytes) : "--")
      const ulTotal = root.totalTxBytes > 0 ? Model.formatBytes(root.totalTxBytes) : (root.hasStats ? Model.formatBytes(root.totalTxBytes) : "--")
      lines.push({
        icon: "download",
        iconColor: "blue",
        text: dlSpeed,
        icon2: "upload",
        iconColor2: "green",
        text2: ulSpeed,
        metrics: true
      })
      lines.push({
        icon: "download",
        iconColor: "blue",
        iconOpacity: 0.7,
        text: dlTotal,
        icon2: "upload",
        iconColor2: "green",
        iconOpacity2: 0.7,
        text2: ulTotal,
        metrics: true
      })
    }
    return lines
  }

  // The access-point-name flash is builtin, with no setting behind it: the
  // window is the shared one (common/ui/FlashReveal.qml) and the reveal is
  // the same shape the Now Playing track name uses - a real animated 0..1
  // gating a label inside the pill, plus the glyph going green for it. The
  // slide carries the name gate, so a cable, which has no name, reveals
  // nothing, and an SSID that has already gone collapses the pill with it.
  FlashReveal {
    id: nameFlash
  }
  // Fullscreen defer: a link that comes up while a fullscreen window owns
  // this screen must not flash under it - the pill would expand over the
  // fullscreen content. The event is parked in _flashPending and replayed
  // when the fullscreen ends, so the announcement lands when the bar is
  // visible again. An in-flight flash cut off by entering fullscreen is
  // parked the same way. The reveal itself never reads fullscreen: while
  // fullscreen is up nothing pulses and nothing shows. Only a named
  // (wifi) link parks - a cable has nothing to show.
  readonly property bool _fsActive: root.barScreen ? FullscreenProbe.screenActive(root.barScreen.name) : FullscreenProbe.anyActive
  property bool _flashPending: false
  function _fireLinkFlash() {
    if (root.ssid === "") return
    if (root._fsActive) {
      root._flashPending = true
      return
    }
    nameFlash.pulse()
  }
  on_FsActiveChanged: {
    if (root._fsActive) {
      // Entering fullscreen with a flash up: park it and take it off
      // screen instead of letting it run under the fullscreen window.
      if (nameFlash.active) {
        if (root.ssid !== "") root._flashPending = true
        nameFlash.clear()
      }
      return
    }
    if (root._flashPending) {
      root._flashPending = false
      if (root.ssid !== "") nameFlash.pulse()
    }
  }
  // Whether the reveal is up, read by both the slide and the colour rather
  // than each reading the window on its own: one event - the reveal timer's
  // expiry - flips both, so the pill's collapse and the colour's fade start
  // together and land together. Reading the animated slide instead would flip
  // the colour a whole glide later, when the slide has already reached zero,
  // and the glyph would stay green after the name was gone.
  readonly property bool revealed: nameFlash.active && root.ssid !== ""
  // The island's own reveal: the same slide, held for the island's lifespan
  // while a wifi link stays connected. No window, no colour, no blink - the
  // island opening is the timer. A cable has no name, so it reveals nothing.
  readonly property bool islandOpen: !!(root.barWindow && root.barWindow.islandHost && root.barWindow.islandHost.isOpenFor(root))
  readonly property bool islandReveal: root.islandOpen && root.ssid !== ""
  // The flash's green-normal blink: the colour alternates between green and
  // the resting tone at the blink cadence, independent of the global motion
  // setting.
  property bool flashTick: false
  Timer {
    id: blinkTimer

    interval: Ui.blinkMs
    running: root.revealed
    repeat: true
    onTriggered: root.flashTick = !root.flashTick
  }
  onRevealedChanged: {
    if (root.revealed) root.flashTick = true
    else root.flashTick = false
  }
  readonly property bool greenPhase: root.revealed && root.flashTick
  property real nameSlide: (root.revealed || root.islandReveal) ? 1 : 0
  Behavior on nameSlide {
    Glide { duration: Ui.slowMs }
  }
  // The glyph's colour is tweened rather than swapped: Icon takes a literal
  // "#rrggbb" for colorKey (Icons.url), so both endpoints are real colours
  // and the green-in and the green-out are fades rather than snaps. The way
  // in matches the pill's glide so the two arrive together; the way home
  // lasts a blink so it lands softly. A Behaviour carries one duration, so
  // it is read per travel. The resting endpoint resolves exactly as Icon
  // resolves a palette key, so neither end of the fade has a seam.
  readonly property int colorMs: root.revealed ? Ui.slowMs : Ui.blinkMs
  property color glyphColor: root.greenPhase ? Ui.solid("green") : Ui.solid(root.iconColor)
  Behavior on glyphColor {
    ColorAnim { duration: root.colorMs; easing.type: root.revealed ? Easing.OutCubic : Easing.InOutQuad }
  }

  // Dynamic pill (the NowPlaying convention): a `nameSlide` real animates
  // 0..1 and the width rounds to whole pixels every frame, so neighbours
  // never sit at a fractional x while the pill grows. `clip` keeps the
  // collapsing label inside the module.
  clip: true
  implicitWidth: Math.round(root.nameSlide > 0 ? pill.width : root.slotWidth)

  // Icon + name pill (the NowPlaying pill convention): one icon slot at
  // rest, so the glyph keeps its centred optical canvas, with the name's
  // reserve riding on top while `nameSlide` runs. The slot's own inset all
  // lands on the trailing text edge.
  Item {
    id: pill

    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: root.slotWidth + root.nameSlide * (Math.min(labelText.implicitWidth, 240) + 4 + Bar.slotInset)
    height: root.height

    // The glyph flashes green-normal for the reveal: the reveal names the
    // access point that just came up, so the icon joins the announcement.
    // The colour itself is the signal, so the wrapper holds full opacity -
    // the island reveal slides the name with no colour at all.
    //
    // The wrapper is one slot wide rather than filled from the pill: it is
    // then the item the label anchors to, because an anchor may only name a
    // parent or a sibling and the Icon is a child. Filling it would put
    // glyph.right at the pill's trailing edge and strand the text there.
    Item {
      id: glyph

      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: root.slotWidth
      height: parent.height

      Icon {
        // Centered in the slot when the name is hidden; docked left ahead of
        // the label otherwise (assigned at runtime so the analyzer never sees
        // an illegal left+horizontalCenter combination).
        anchors.left: root.nameSlide > 0 ? parent.left : undefined
        anchors.horizontalCenter: root.nameSlide > 0 ? undefined : parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        name: root.iconName
        colorKey: String(root.glyphColor)
        // Wifi-off only: its crossing line (class="indicator") paints red
        // while the body stays dimmed, the bluetooth-off treatment.
        accentKey: root.iconAccent
      }
    }

    Title {
      id: labelText

      anchors.left: glyph.right
      anchors.leftMargin: 4
      anchors.verticalCenter: parent.verticalCenter
      visible: root.nameSlide > 0
      level: 3
      width: Math.min(implicitWidth, 240)
      font.pixelSize: Math.round(Ui.fontM * 0.95 * root.textScale)
      text: root.ssid
      elide: Text.ElideRight
    }
  }

  fillButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
  onClicked: mouse => {
    if (mouse.button === Qt.MiddleButton) {
      // Declarative override first (shell.statusbar.networkMiddleClick),
      // falling back to the builtin wifi on/off toggle.
      if (root.clickCommand("middleClick")) return
      Networking.wifiEnabled = !Networking.wifiEnabled
      return
    }
    if (mouse.button === Qt.RightButton) {
      // Declarative via settings.jsonc: shell.statusbar.networkRightClick
      // Default is vb-launch-networkmanager; empty disables.
      root.clickCommand("rightClick", "vb-launch-networkmanager")
      return
    }
    root.openIsland()
  }

  // One shared tooltip bubble: the SSID on wifi, "Using ethernet
  // connection" on a wired link, "Wi-Fi off" when the radio is disabled,
  // or a "No network" hint when there is no connection (the tooltip
  // shows in all states).
  ToolTipBind {
    active: root.hovered
    text: root.tooltipText
    lines: root.tipLines
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
    maxWidth: 0
  }

  Component {
    id: islandComp

    NetworkIsland {
      onQrRequested: ssid => qrOverlay.open(ssid)
    }
  }

  // The island this module opens, declared on the base so openIsland()
  // below is the single call every click handler makes.
  islandComponent: islandComp

  // A disconnected ShellScreen is dangling and does not reconnect, so the
  // overlay's screen is resolved out of the CURRENT set on every
  // evaluation instead of being held as an object: a wrapper rebuild for a
  // still-connected output rebinds the card, and the same order the
  // screenshot surfaces use decides the match - object identity, then
  // serial, then name plus size (ShotLib.matchScreen). Every read passes
  // Ui.validScreens, so the binding re-evaluates on the set change itself.
  // One screen-set change, one re-resolution. No match is a genuine
  // disconnect, and a card mapped to a dead output keeps the SSID on a
  // surface nobody can reach with both helper children still running, so
  // the overlay closes: close() retires both generations and drops the
  // secret, the same terminal the user's own dismissal takes.
  function _reconcileQrScreen() {
    if (!qrOverlay.opened) return
    if (ShotLib.matchScreen(root.barScreen, Ui.validScreens) === null) qrOverlay.close()
  }

  Connections {
    target: Ui

    function onValidScreensChanged() {
      root._reconcileQrScreen()
    }
  }

  // Fullscreen Wi-Fi QR share, owned here (sibling to the island, like the
  // color picker's overlay): the island's QR button requests it.
  NetworkQrOverlay {
    id: qrOverlay

    targetScreen: ShotLib.matchScreen(root.barScreen, Ui.validScreens)
  }

  // A hidden bar must not leave its network island floating on screen
  // (the host itself closes centrally; the QR overlay is separate).
  Connections {
    target: Bar

    function onEnabledChanged() {
      if (!Bar.enabled) qrOverlay.close()
    }
  }
}
