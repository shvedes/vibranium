pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Bluetooth
import qs.common
import qs.features.bar
import "Model.js" as Model

// Bluetooth module: shows the adapter state with the shipped bluetooth
// icons. Connected device - the connected glyph in the default foreground
// color; adapter on - the plain bluetooth glyph; adapter off - the off
// glyph, dimmed body with its crossing line red (class="indicator" in the
// asset, the treatment the muted mic and muted speaker have); no adapter at
// all - the plain glyph but red. Hovering shows a tooltip with the
// connection state; clicking opens the island with the device list.
BarModule {
  id: root

  // Icon geometry comes from the bar tokens (fixed slot / optical canvas).
  // The pill is one slot wide at rest - so the hover and click target stays
  // constant across glyphs - and grows only for the device-name flash.
  readonly property real slotWidth: root.iconSlot

  // --- live bluetooth state (Quickshell.Bluetooth, BlueZ backend) ---

  readonly property var adapter: Bluetooth.defaultAdapter
  readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property var connectedDevice: {
    for (const d of root.devices) if (d.connected) return d
    return null
  }

  // Icon + color. Connecting or connected: connected glyph in foreground
  // (the side ticks blink only while connecting). Searching: searching
  // glyph, blinking antennas. Adapter off: off glyph, its crossing line red
  // and the body dimmed. No adapter: plain glyph, red.
  readonly property string iconName: (root.connecting || root.connectedDevice) ? "bluetooth-connected"
    : root.searching ? "bluetooth-searching"
    : (root.adapter ? (root.adapter.enabled ? "bluetooth" : "bluetooth-off") : "bluetooth")
  readonly property string iconColor: (root.connecting || root.connectedDevice) ? "foreground_0"
    : root.searching ? "foreground_0"
    : (root.adapter ? (root.adapter.enabled ? "foreground_0" : "foreground_1") : "red")
  // Second tone for the glyph's indicator elements (class="indicator"). The
  // connecting and searching ticks take the regular foreground - user
  // decision: the blink swap solid -> 50% transparent is the animation signal,
  // no extra hue. An adapter that is off takes red for its crossing line only
  // (bluetooth-off), which is the treatment the muted mic and the muted
  // speaker already have: the body reads dimmed, the mark reads as the fault.
  // A missing adapter carries no accent at all, so iconColor paints the whole
  // glyph red there.
  readonly property string iconAccent: (root.connecting || (root.searching && !root.connectedDevice))
    ? "foreground_0"
    : ((root.adapter !== null && !root.adapter.enabled) ? "red" : "")

  // In-flight connect attempt to a known device: BlueZ reports the device
  // state as Connecting. Drives the blinking side ticks of the connected
  // glyph. The binding re-evaluates on the device's stateChanged, so the
  // blink clears the moment the device reaches Connected/Disconnected -
  // it never runs on an already-connected device.
  readonly property bool connecting: root.devices.some(d =>
    d.state === BluetoothDeviceState.Connecting)

  // Discovery or a fresh pairing hand-shake: the not-yet-known phase,
  // served by the searching glyph with its blinking antennas.
  readonly property bool searching: root.adapter !== null
    && (root.adapter.discovering
        || root.devices.some(d => d.pairing))

  readonly property string deviceName: root.connectedDevice ? Model.deviceLabel(root.connectedDevice) : ""

  // The row's glyph already says the link is up and what sits on it, so the
  // connected case carries nothing but the device's own name.
  readonly property string tooltipText: root.connectedDevice
    ? root.deviceName
    : (root.adapter ? (root.adapter.enabled ? "Bluetooth on" : "Bluetooth off") : "No adapter")

  // Tooltip rows ({icon, text}, the weather/printers convention): the
  // connected device's own class glyph - headset, headphones, speaker,
  // keyboard, mice, gamepad, monitor - so the bubble reads what sits on the
  // link rather than the link itself. The adapter-state badge is the
  // fallback, both when nothing is connected and when the reported class
  // has no shipped glyph.
  readonly property var tipLines: [{
    icon: Model.deviceIconName(Model.deviceRow(root.connectedDevice)) || root.iconName,
    text: root.tooltipText
  }]

  // The device-name flash is builtin, with no setting behind it: the window
  // is the shared one (common/ui/FlashReveal.qml) and the reveal is the same
  // shape the Now Playing track name uses - a real animated 0..1 gating a
  // label inside the pill, plus the glyph going green for it. The slide
  // carries the name gate, so a device that dropped out of range mid-window
  // collapses the pill with it instead of holding a label nothing is
  // connected to.
  FlashReveal {
    id: nameFlash
  }
  // Fullscreen defer: a device that connects while a fullscreen window owns
  // this screen must not flash under it - the pill would expand over the
  // fullscreen content. The event is parked in _flashPending and replayed
  // when the fullscreen ends, so the announcement lands when the bar is
  // visible again. An in-flight flash cut off by entering fullscreen is
  // parked the same way. The reveal itself never reads fullscreen: while
  // fullscreen is up nothing pulses and nothing shows.
  readonly property bool _fsActive: root.barScreen ? FullscreenProbe.screenActive(root.barScreen.name) : FullscreenProbe.anyActive
  property bool _flashPending: false
  function _fireConnectFlash() {
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
        if (root.deviceName !== "") root._flashPending = true
        nameFlash.clear()
      }
      return
    }
    if (root._flashPending) {
      root._flashPending = false
      if (root.deviceName !== "") nameFlash.pulse()
    }
  }
  // Whether the reveal is up, read by both the slide and the colour rather
  // than each reading the window on its own: one event - the reveal timer's
  // expiry - flips both, so the pill's collapse and the colour's fade start
  // together and land together. Reading the animated slide instead would flip
  // the colour a whole glide later, when the slide has already reached zero,
  // and the glyph would stay green after the name was gone.
  readonly property bool revealed: nameFlash.active && root.deviceName !== ""
  // The island's own reveal: the same slide, held for the island's lifespan
  // while a device stays connected. No window, no colour, no blink - the
  // island opening is the timer.
  readonly property bool islandOpen: !!(root.barWindow && root.barWindow.islandHost && root.barWindow.islandHost.isOpenFor(root))
  readonly property bool islandReveal: root.islandOpen && root.deviceName !== ""
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

  // --- connection transitions ---
  //
  // The icon already derives from `connected`, but a binding has no hook: a
  // headset connecting woke nothing up, so there was no point at which this
  // module could report it. This watches the FACT, not the request - BlueZ
  // refuses connects, devices drop out of range on their own, and a profile
  // re-connect is routine. "The user clicked connect" and "a device is
  // connected" are different facts and only the second is worth a line.
  //
  // Keyed on `address` - the MAC - deliberately. Not the wrapper, which BlueZ
  // replaces while a connection settles, and not `dbusPath`, which is an opaque
  // object path meaning nothing outside this process. The address is the one
  // identifier that is stable across a reconnect and unique per device.
  //
  // Seeding is PER DEVICE, not per pass, and that is the load-bearing choice
  // here: the adapter reports its device list in pieces while the shell comes
  // up, so a pass that shows a device connected may be the first to have heard
  // of it at all - which is also why the bar building several copies of this
  // module before it settles changes nothing. A device first seen UP was
  // already on when the bar appeared, and reporting it would put a connection
  // in the journal that nobody made and flash a name for it. Only a device
  // observed DOWN and then UP is a connection.
  property var _up: ({})
  property var _watched: ({})

  // Imperative connect rather than an Instantiator per device: this tree uses
  // `.connect()` from JS elsewhere (Polkit, Menu, CursorPicker), and BlueZ
  // device wrappers live for the session, so the set of live handlers is
  // bounded by the number of devices the adapter has ever reported - per
  // module instance, which is what the teardown below restores.
  //
  // The wrapper outlives the module that watched it, and that is the whole
  // difficulty: the bar builds this module several times while it settles,
  // every copy watches the same session-long wrappers, and a wrapper keeps
  // notifying a copy that is already gone - which dereferences a destroyed
  // context and reports a TypeError rather than a transition. So the handlers
  // are dropped on the way out AND carry a null guard while they are live: the
  // disconnect covers a copy being torn down, the guard covers a notification
  // already in flight when it was.
  property var _handles: ([])

  function _watchDevices() {
    for (let i = 0; i < root.devices.length; i++) {
      const d = root.devices[i]
      const key = String(d.address || "")
      if (key === "" || root._watched[key] === true) continue
      root._watched[key] = true
      const onConnectedChanged = () => {
        if (root !== null) root._syncConnections()
      }
      try {
        d.connectedChanged.connect(onConnectedChanged)
        root._handles.push([d, onConnectedChanged])
      } catch (e) { /* unwatchable here; the next pass reports it if it connects */ }
    }
    root._syncConnections()
  }

  Component.onDestruction: {
    for (let i = 0; i < root._handles.length; i++) {
      const handle = root._handles[i]
      try { handle[0].connectedChanged.disconnect(handle[1]) } catch (e) { /* the wrapper went first */ }
    }
    root._handles = []
  }

  function _syncConnections() {
    const seen = ({})
    let live = 0
    for (let i = 0; i < root.devices.length; i++) {
      const d = root.devices[i]
      const key = String(d.address || "")
      if (key === "") continue
      let up = false
      try { up = d.connected === true } catch (e) { up = false }
      seen[key] = up
      if (!up) continue
      live++
      // Only a device this shell observed DOWN is a connection. One first
      // seen UP was already on when the bar appeared, or the graph is still
      // being assembled, and neither is a connection anybody made.
      if (root._up[key] !== false) continue
      Log.info("connected " + key + ", of " + live)
      Log.debug("device " + key + " joined the connected set")
      // Fullscreen-deferred (see _flashPending): parks while fullscreen
      // is up, pulses at once otherwise. The settle gate inside pulse()
      // still decides boot quietness.
      root._fireConnectFlash()
    }
    for (const key in root._up) {
      if (root._up[key] !== true || seen[key] === true) continue
      // A device that left the graph while connected is still a disconnection:
      // an unplugged or out-of-range headset is exactly the case a reader wants,
      // and it never produces a false-to-false flip.
      Log.info("disconnected " + key + ", of " + live)
    }
    // Written through rather than replaced by `seen`, so a device that left the
    // graph keeps its last state: one that comes back connected is a
    // connection this shell watched, not a late appearance.
    for (const key in seen) root._up[key] = seen[key]
  }

  onDevicesChanged: root._watchDevices()
  Component.onCompleted: root._watchDevices()

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
    // device that just came up, so the icon joins the announcement. The
    // colour itself is the signal, so the wrapper holds full opacity - the
    // island reveal slides the name with no colour at all.
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

      CrossfadeIcon {
        // Centered in the slot when the name is hidden; docked left ahead of
        // the label otherwise (assigned at runtime so the analyzer never sees
        // an illegal left+horizontalCenter combination).
        anchors.left: root.nameSlide > 0 ? parent.left : undefined
        anchors.horizontalCenter: root.nameSlide > 0 ? undefined : parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        name: root.iconName
        colorKey: String(root.glyphColor)
        accentKey: root.iconAccent
        indicatorActive: root.connecting || (root.searching && !root.connectedDevice)
        // default slot/canvas tokens
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
      text: root.deviceName
      elide: Text.ElideRight
    }
  }

  fillButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
  onClicked: mouse => {
    if (mouse.button === Qt.MiddleButton) {
      // Declarative override first (shell.statusbar.bluetoothMiddleClick),
      // falling back to the builtin adapter on/off toggle.
      if (root.clickCommand("middleClick")) return
      if (root.adapter) root.adapter.enabled = !root.adapter.enabled
      return
    }
    if (mouse.button === Qt.RightButton) {
      root.clickCommand("rightClick")
      return
    }
    root.openIsland()
  }

  // One shared tooltip bubble: the connection state, or a hint when the
  // adapter is off/missing (the tooltip shows in both states).
  ToolTipBind {
    active: root.hovered
    text: root.tooltipText
    lines: root.tipLines
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }

  Component {
    id: islandComp

    BluetoothIsland {}
  }

  // The island this module opens, declared on the base so openIsland()
  // below is the single call every click handler makes.
  islandComponent: islandComp
}
