pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import qs.services as Core
import qs.features.bar
import "Model.js" as Model
import "../../../../common/text/Format.js" as Format

// Volume module: single volume icon with the microphone pill folded into
// the same slot. Right-click toggles the shell's audio mixer over IPC
// (shell.statusbar.volumeRightClick, falling back to the same command),
// left-click opens the island with output, input and per-app sliders. The mic
// icon lives in its own pill to the LEFT of the volume icon: when the
// microphone is in use (or always, via shell.statusbar.volumeShowMic) it
// slides out leftward, shifting the left-side bar contents; otherwise it
// slides back under the volume icon. Mic and Vol is a single module, always.
BarModule {
  id: root

  // Each pill has its own MouseArea; the base's fill surface is not used.
  builtinFill: false

  // Icon geometry comes from the bar tokens (fixed slot / optical canvas);
  // each pill is exactly one slot wide so the hover/click target stays
  // constant across glyphs.
  readonly property real slotWidth: root.iconSlot

  // --- mic pill policy ---

  // Mic and Vol is a single module, always: the pill shows on live
  // capture stream, or always via the show-mic option.

  // --- pipewire state ---
  //
  // A BarModule is constructed once per bar window, so anything built here
  // is built once per output - and PipeWire state is process-global, so
  // N copies of one subscription is N times the work for one device. The
  // module therefore reads state, it does not subscribe to it:
  //
  //   sink/source  the Audio service owns the single PwObjectTracker pair
  //                for the default sink and source (and with them the
  //                volume/mute policy this module already reads step and
  //                maxVolume through), so the live nodes and their
  //                subscriptions are read from there - one policy, one
  //                place, unchanged values.
  //   nodes        the neutral AudioNodes tracker owns the one
  //                PwObjectTracker over the backend's node set, and the
  //                per-output filter below runs on the node list it
  //                publishes.
  //   link groups  the same tracker owns the one PwNodeLinkTracker for the
  //                observed device, reached through this output's handle.
  //
  // Which nodes count as a capture stream, and what a link group means for
  // a microphone, stay here: the trackers know neither.
  readonly property var sink: Core.Audio.sink
  readonly property var source: Core.Audio.source
  readonly property var nodes: AudioNodes.nodes
  readonly property var captureStreams: {
    var list = []
    for (var i = 0; i < root.nodes.length; i++) {
      var n = root.nodes[i]
      if (!n || !n.isStream) continue
      if (n.isSink) continue
      if (!n.audio) continue
      if (!Model.isCaptureStream(n) && n.isSink !== false) continue
      list.push(n)
    }
    return list
  }

  // The one shared observation this output holds: the node set, plus the
  // link groups of whatever device is the default source right now. It is
  // an observation, not a subscription - the trackers behind it are the
  // global Audio service's and the neutral AudioNodes', one set each, no
  // matter how many outputs are watching them.
  property var _audioTrack: null

  // Mic-in-use: any capture link on the default source, or any active
  // capture stream at all (covers PipeWire setups where the link tracker
  // is momentarily empty but streams remain).
  readonly property bool micInUse: (root._audioTrack !== null && root._audioTrack.linkCount > 0)
    || root.captureStreams.length > 0
  readonly property bool showMicAlways: Settings.value("shell.statusbar.volumeShowMic") === true
  readonly property bool micVisible: root.showMicAlways || root.micInUse

  readonly property real outputVolume: root.sink && root.sink.audio ? root.sink.audio.volume : 0
  readonly property bool outputMuted: root.sink && root.sink.audio ? root.sink.audio.muted : false
  readonly property real inputVolume: root.source && root.source.audio ? root.source.audio.volume : 0
  readonly property bool inputMuted: root.source && root.source.audio ? root.source.audio.muted : false
  // Nothing audible on the output: an explicit mute or a level at zero.
  // The off glyph's red mark reads this; `outputMuted` still owns the
  // "Muted" readout and the toggle.
  readonly property bool outputSilent: root.sink && root.sink.audio
    ? Core.Audio.silentFor(root.outputVolume, root.outputMuted) : false

  // Output percentage readout (shell.statusbar.volumePercent, default off):
  // the current output's level printed next to the bar icon, the battery
  // module's convention. The pill stays one slot wide while it is off.
  readonly property bool showPercentage: Settings.value("shell.statusbar.volumePercent") === true
    && !!root.sink && !!root.sink.audio

  // Preferred device label for the tooltip.
  readonly property string sinkLabel: Model.nodeLabel(root.sink)

  // Playback app rows for the tooltip count: the shared filter, so this
  // number and the island's own "N apps" counter always agree.
  readonly property var playbackStreams: Model.playbackStreams(root.nodes)

  readonly property string volumeIconName: {
    if (!root.sink || !root.sink.audio) return "volume-off"
    if (root.sink.audio.muted) return "volume-off"
    var devIcon = Model.sinkDeviceIcon(root.sink)
    if (devIcon === "headset") return "headset"
    if (devIcon === "headphones") return "headphones"
    // Level tiers live in the Audio service so the bar, the island and
    // the OSD never drift apart again. volume-max is tiered: the dim
    // count below fades its wave groups to render every level.
    return Core.Audio.volumeIconFor(root.sink.audio.volume, false)
  }

  // Wave groups kept opaque on the tiered volume-max glyph (Audio
  // service policy, same thirds as the name above). Non-tiered glyphs
  // (volume-off, headset, headphones) have no tier classes and ignore it.
  readonly property int volumeDimTiers: root.sink && root.sink.audio && !root.sink.audio.muted
    ? Core.Audio.volumeDimTiersFor(root.sink.audio.volume, false) : 0

  readonly property string volumeIconColor: "foreground_0"
  readonly property string micIconName: root.inputMuted ? "mic-off" : "mic-on"
  readonly property string micIconColor: "foreground_0"

  // Tooltip rows per hovered pill, apps first (what the pill is about),
  // then the device row and the level row: the percentage gets the bar's
  // own tiered volume glyph in front of it and the two can never disagree
  // about what is being driven. The muted mark carries the same red
  // indicator as the module icon (class="indicator" in volume-off). The
  // mic pill keeps one row - its glyph already carries the mute state,
  // with the same red slash as its module icon. The app count mirrors the
  // island section, including its singular and its empty-state copy.
  readonly property var volumeTipLines: {
    if (!root.sink || !root.sink.audio) return [{ icon: "volume-off", text: "No output device" }]
    var apps = root.playbackStreams.length
    var appsText = apps === 0 ? "No apps playing audio"
      : apps + (apps === 1 ? " app" : " apps")
    return [
      { icon: "grid", text: appsText },
      { icon: Model.sinkTooltipIcon(root.sink), text: root.sinkLabel !== "" ? root.sinkLabel : "Output" },
      {
        icon: root.outputSilent ? "volume-off" : "volume-max",
        text: root.outputMuted ? "Muted" : Format.percent(root.outputVolume),
        dimTiers: root.outputSilent ? 0 : root.volumeDimTiers,
        accentKey: root.outputSilent ? "red" : ""
      }
    ]
  }
  readonly property var micTipLines: [{
    icon: root.micIconName,
    text: "Microphone - " + (root.inputMuted ? "Muted" : Format.percent(root.inputVolume)),
    accentKey: root.inputMuted ? "red" : ""
  }]

  // Policy lives in the Audio core singleton; the widget only forwards.
  readonly property real volumeStep: Core.Audio.step
  readonly property real maxVolume: Core.Audio.maxVolume

  function adjustOutput(delta) {
    Core.Audio.adjustSink(delta)
  }

  function adjustInput(delta) {
    Core.Audio.adjustSource(delta)
  }

  // --- default-output name flash ---
  //
  // The same one-shot window the Network and Bluetooth modules use for a new
  // connection name, without their green color blink: here only the name
  // pill moves. The event is PipeWireState's counter, which bumps once per
  // default-output move the shell did not initiate itself - island and mixer
  // picks are recorded at the write and swallowed there - so every output's
  // bar reveals on the same event. The window's settle gate keeps the graph
  // arriving at boot quiet.
  FlashReveal {
    id: sinkFlash
  }

  // A device switch rebuilds the node/link graph: the source can be
  // withdrawn for a moment, and AudioNodes reports a link count of zero for
  // a handle whose node is gone, which takes micInUse with it. The mic pill
  // would slide away and straight back while the name reveals. Hold it for
  // the announcement, but only if it was visible when the change arrived -
  // an idle mic must not pop out on an unrelated output switch.
  property bool _micHold: false
  Timer {
    id: micHoldTimer
    // Covers the reveal window and the graph settling after it.
    interval: sinkFlash.durationMs + 1000
    onTriggered: root._micHold = false
  }

  function _pulseSinkFlash() {
    if (root.micVisible) {
      root._micHold = true
      micHoldTimer.restart()
    }
    sinkFlash.pulse()
  }

  property bool _sinkFlashPending: false
  function _fireSinkFlash() {
    if (root.sinkLabel === "" || root.sinkLabel === "Unknown") return
    if (root.fullscreenActive) {
      root._sinkFlashPending = true
      return
    }
    root._pulseSinkFlash()
  }
  onFullscreenActiveChanged: {
    if (root.fullscreenActive) {
      if (sinkFlash.active) {
        if (root.sinkLabel !== "") root._sinkFlashPending = true
        sinkFlash.clear()
      }
      return
    }
    if (root._sinkFlashPending) {
      root._sinkFlashPending = false
      if (root.sinkLabel !== "") root._pulseSinkFlash()
    }
  }

  property int _lastSinkChangeSeq: -1
  Connections {
    target: Core.PipeWireState
    function onSinkChangeSeqChanged() {
      const seq = Core.PipeWireState.sinkChangeSeq
      if (root._lastSinkChangeSeq < 0) {
        root._lastSinkChangeSeq = seq
        return
      }
      root._lastSinkChangeSeq = seq
      root._fireSinkFlash()
    }
  }

  // Only the name pill moves; the volume glyph keeps its normal color. The
  // slide is the 0..1 form the Behavior needs, so nothing else is involved.
  property real sinkNameSlide: sinkFlash.active
    && root.sinkLabel !== "" && root.sinkLabel !== "Unknown" ? 1 : 0
  Behavior on sinkNameSlide {
    Glide { duration: Ui.slowMs }
  }

  // Volume and mute stay live because the ONE tracker set that keeps the
  // default devices' PipeWire properties observed is the Audio service's
  // (see the state block above), not because this module subscribed to
  // them per output.
  Component.onCompleted: {
    root._audioTrack = AudioNodes.observe("bar/volume", root.source)
    root._lastSinkChangeSeq = Core.PipeWireState.sinkChangeSeq
  }
  // A device switch follows the observation: the handle is re-pointed at
  // the new default source, which moves it onto that node's single shared
  // link tracker.
  onSourceChanged: {
    if (root._audioTrack !== null) root._audioTrack.linkNode = root.source
  }

  implicitWidth: row.implicitWidth

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 0

    // Microphone pill - slides out to the left of the volume icon.
    // Collapsible slot (see CollapsibleSlot.qml): zero width while idle
    // so it leaves no gap.
    CollapsibleSlot {
      id: micBox

      // The pill owns its hover/click areas below, like the module root.
      builtinFill: false
      // Cold-boot settle: at creation the pill starts parked (no slide-in
      // churn before the first layout pass). The hold keeps it parked open
      // while a device switch rebuilds the graph the mic state is read from.
      collapseShown: root.micVisible || root._micHold
      collapseFull: root.slotWidth
      collapseArmed: root.bootSettled

      CrossfadeIcon {
        // Right-anchored so the glyph holds still while the pill grows
        // leftward (left overflow is clipped).
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        name: root.micIconName
        colorKey: root.micIconColor
        // Muted: only the slash goes red (class="indicator" in mic-off).
        accentKey: root.inputMuted ? "red" : ""
        opacity: micBox.fade
        visible: opacity > 0
      }

      MouseArea {
        id: micHover

        anchors.fill: parent
        enabled: micBox.collapseShown
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: mouse => {
          if (mouse.button === Qt.MiddleButton) {
            if (root.clickCommand("micMiddleClick", "")) return
            Core.Audio.toggleSourceMute()
            return
          }
          if (mouse.button === Qt.RightButton) {
            root.clickCommand("micRightClick", "vb-shell app toggle audioMixer")
            return
          }
          Core.Audio.toggleSourceMute()
        }
      }

      WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: event => {
          var st = root.volumeStep
          var d = event.angleDelta.y > 0 ? st : (event.angleDelta.y < 0 ? -st : 0)
          if (d !== 0) root.adjustInput(d)
        }
      }
    }

    // Volume icon box - always visible. Grows by the readout's width when the
    // percentage option is on; the glyph stays at the slot's leading edge so
    // the number reads as an extension of it rather than moving it.
    Item {
      id: volumeBox

      // The slide drives both the number's opacity and the added width, so
      // the row measures the pill frame by frame and reserves exactly the
      // space the text needs. Boot settle keeps a persisted option from
      // sliding in on the first layout pass.
      property real pctSlide: root.showPercentage ? 1 : 0
      Behavior on pctSlide {
        enabled: root.bootSettled
        Glide { duration: Ui.slowMs }
      }
      readonly property int pctWidth: pctText.implicitWidth + 4

      implicitWidth: root.slotWidth + Math.round(pctSlide * pctWidth)
      implicitHeight: Bar.height
      width: implicitWidth
      height: implicitHeight

      CrossfadeIcon {
        // Hold the one-slot box at the leading edge and center the glyph in
        // it: growing the pill must not move the icon or recenter it over the
        // number. Icon's implicit width is the whole slot, so an explicit
        // slot width here reproduces the original centered placement.
        anchors.left: parent.left
        width: root.slotWidth
        anchors.verticalCenter: parent.verticalCenter
        name: root.volumeIconName
        colorKey: root.volumeIconColor
        // Silent (muted or at zero): only the X goes red
        // (class="indicator" in volume-off).
        accentKey: root.outputSilent ? "red" : ""
        dimTiers: root.volumeDimTiers
      }

      Title {
        id: pctText

        anchors.left: parent.left
        anchors.leftMargin: root.slotWidth + 2
        anchors.verticalCenter: parent.verticalCenter
        opacity: volumeBox.pctSlide
        visible: opacity > 0
        level: 3
        font.pixelSize: Bar.pillFontSize
        color: Ui.solid(root.volumeIconColor)
        text: Format.percent(root.outputVolume)
      }

      MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: mouse => {
          if (mouse.button === Qt.MiddleButton) {
            if (root.clickCommand("middleClick")) return
            Core.Audio.toggleSinkMute()
            return
          }
          if (mouse.button === Qt.RightButton) {
            root.clickCommand("rightClick", "vb-shell app toggle audioMixer")
            return
          }
          root.openIsland()
        }
      }

      WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: event => {
          var st = root.volumeStep
          var d = event.angleDelta.y > 0 ? st : (event.angleDelta.y < 0 ? -st : 0)
          if (d !== 0) root.adjustOutput(d)
        }
      }
    }

    // New-output name reveal, docked AFTER the volume icon - never after the
    // mic pill. The animated `sinkNameSlide` grows the width from zero so the
    // label glides out with the pill and back when the window closes; clip
    // keeps it inside while it collapses. Only a named output reveals
    // anything, so an unknown device leaves no gap.
    Item {
      id: sinkNamePill

      width: Math.round(root.sinkNameSlide * (Math.min(sinkNameLabel.implicitWidth, 200) + 4))
      height: volumeBox.height
      clip: true
      visible: root.sinkNameSlide > 0

      Title {
        id: sinkNameLabel

        anchors.left: parent.left
        anchors.leftMargin: 2
        anchors.verticalCenter: parent.verticalCenter
        visible: root.sinkNameSlide > 0
        level: 3
        width: Math.min(implicitWidth, 200)
        font.pixelSize: Bar.pillFontSize
        text: root.sinkLabel
        elide: Text.ElideRight
      }
    }
  }

  // One tooltip per pill: the active one follows whichever surface the
  // cursor rests on (the mic pill's surface is disabled while hidden).
  ToolTipBind {
    active: micHover.containsMouse && !root.islandOpen
    lines: root.micTipLines
    anchor: micBox
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }

  ToolTipBind {
    active: hoverArea.containsMouse && !root.islandOpen
    lines: root.volumeTipLines
    anchor: volumeBox
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }

  // The island is lent to the shared host, anchored to the module
  // (not to micBox/volumeBox - those anchors belong to the tooltips).
  Component {
    id: islandComp

    VolumeIsland {}
  }

  // The island this module opens, declared on the base so openIsland()
  // below is the single call every click handler makes.
  islandComponent: islandComp

  // Cold-boot settle gate for the pill's slide behavior: the shared boot
  // milestone the bar latches once its modules have built (Zone reads the
  // same one), so the first layout pass never animates and this module arms
  // no timer of its own per output.
  readonly property bool bootSettled: DesktopLayoutState.bootEntranceSettled

  // An output going away drops its observation; the last output to go drops
  // the shared trackers with it, so a module closed everywhere leaves no
  // PipeWire subscription behind.
  Component.onDestruction: {
    if (root._audioTrack !== null) {
      AudioNodes.release(root._audioTrack)
      root._audioTrack = null
    }
  }
}
