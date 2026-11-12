pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type
import QtQuick
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.Pipewire
import qs.common
import qs.services as Core
import qs.features.bar
import "Model.js" as Model
import "../../../../common/text/Format.js" as Format
import "../../../../common/math/Range.js" as Range
import "../../../../common/audio/LevelBand.js" as LevelBand

// Volume island: output and input sliders plus per-application mixers.
// Mirrors the Network/Bluetooth islands: Card chrome from the shared
// host, Title
// levels for typography, Display for metrics. Sliders are custom (no
// library Slider exists) but use the same track/thumb language as
// ProgressBar.
Item {
  id: root

  property int islandContentWidth: 360
  // The card's padded body holds the content: add the outer padding to
  // the content's implicit height so nothing clips. Read off the live
  // body while the host shows this island; the host freezes the last
  // live footprint for the closed window.
  property int islandContentHeight: Math.ceil(body.implicitHeight) + 2 * Ui.outerPad
  // The inline device selectors ease their own height on the shared expand
  // curve; the host steps its window-height Behavior aside so the window
  // tracks them frame by frame (one easing).
  property bool islandSelfAnimating: true
  property var islandHost: null
  // Global animation gate (MotionPolicy): the expand Behaviors below bind
  // through here so an undefined lookup never disables them silently.
  readonly property bool animationsEnabled: MotionPolicy.enabled

  readonly property real rowPad: 6
  // Vertical scrollbar gutter: the bar (3px + 1px margin) overlays the
  // viewport's right edge (ArchUpdates/Battery pattern), so app rows end
  // at rowPad and never run underneath it. The list itself always spans
  // the full width - the scrollbar belongs to the list, drawn inside it.
  // Section readout reserve: every value the readout shows ("0%".."100%",
  // "Muted") fits the width of "Muted", so reserving that keeps the title
  // and inline meter from reflowing when the text changes.
  readonly property real pctW: Math.ceil(pctMetrics.advanceWidth) + 4

  TextMetrics {
    id: pctMetrics

    font.family: Ui.fontFamily
    font.pixelSize: Ui.fontXs
    font.bold: true
    text: "Muted"
  }

  // --- pipewire ---
  //
  // The island is lent to a per-bar-window host, so it is constructed once
  // per output - and PipeWire state is process-global, so N copies of one
  // subscription is N times the work for one device. The island therefore
  // reads state, it does not subscribe to it:
  //
  //   sink/source  the Audio service owns the single PwObjectTracker pair
  //                for the default sink and source (and with them the
  //                step/max policy this island already read), so the live
  //                devices and their subscriptions are read from there -
  //                one pair, one place, unchanged values.
  //   nodes        the neutral AudioNodes tracker owns the one
  //                PwObjectTracker over the backend's node set, and the
  //                three projections below run this island's own filters
  //                over the list it publishes.
  //
  // Five views are needed over the device set: the sink, the source, both
  // candidate lists and the stream list. Two of them are the default devices,
  // owned by the service that has them; the other three are subsets of the
  // node set, so the one tracker over the set covers them and a stream
  // appearing is one re-pointing rather than three per output.
  //
  // Which nodes are a playback device, a capture device, a stream or a
  // mixer row, what a name exclusion means, and what the island does on a
  // switch all stay here: the tracker names no device, no stream class and
  // no output, and it holds nothing this island writes to.
  readonly property var sink: Core.Audio.sink
  readonly property var source: Core.Audio.source
  readonly property var nodes: AudioNodes.nodes

  // The three projections, as functions over a node list rather than inline
  // bindings: the policy is the island's either way, and a function can be
  // run against a synthetic list outside a window - which is the only way a
  // per-output view's projection is checkable at all.
  function sinkCandidates(list) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var n = list[i]
      if (!n || n.isStream || !n.isSink) continue
      if (!n.audio) continue
      if (String(n.name || "").indexOf(".monitor") !== -1) continue
      out.push(n)
    }
    return out
  }

  function sourceCandidates(list) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var n = list[i]
      if (!n || n.isStream || n.isSink) continue
      if (!n.audio) continue
      if (String(n.name || "").indexOf(".monitor") !== -1) continue
      if (String(n.name || "") === "quickshell") continue
      out.push(n)
    }
    return out
  }

  // Rows are the raw PulseAudio nodes, filtered to playback streams. No
  // rowIdentity on the stream list below, because nothing on a node is a
  // safe key: `name` is what the filters below match on and two applications
  // are free to share one, and the node's own id is not carried onto the
  // row. A contested key is worse than an index key - List refuses it for
  // learning AND prunes it - so the index default stands until the stream
  // list projects an id per row. The filter itself lives in the shared
  // Model (one source for this section and the bar tooltip's app count).
  function streamCandidates(list) {
    return Model.playbackStreams(list)
  }

  readonly property var candidateSinks: root.sinkCandidates(root.nodes)
  readonly property var candidateSources: root.sourceCandidates(root.nodes)
  readonly property var audioStreams: root.streamCandidates(root.nodes)

  property var displayStreams: []
  // Empty (no apps playing): the section shows three dimmed skeleton rows
  // with a centered note instead of live rows. Never overlays a populated
  // list: the moment a stream snapshot lands, displayStreams is non-empty
  // and the live rows take over.
  readonly property bool _appsEmpty: root.displayStreams.length === 0
  // The device dropdowns are overlays anchored to their trigger chips (no
  // in-flow slot under them). Exactly one list may be unfolded at a time;
  // this names which, or "" when both are closed.
  property string popOpen: ""

  function refreshDisplay() {
    // The content only exists while the host shows it, so any refresh
    // is open-gated by lifetime.
    root.displayStreams = Model.listSnapshot(root.audioStreams)
  }

  Timer {
    id: refreshTimer
    interval: 75
    repeat: false
    onTriggered: root.refreshDisplay()
  }

  onAudioStreamsChanged: refreshTimer.restart()

  // Snapshot on every show: the content is incubated fresh, so creation
  // is open. Teardown stops the pending refresh and gives up the node-set
  // observation; the next show re-snapshots anyway.
  //
  // The one observation this island holds is the node set, and it names no
  // node: the island filters the set but follows no device, so it takes no
  // link tracker at all. Created with the first island open anywhere and
  // released with the last, whatever the output count - a device switch
  // moves the backend's own default, and the island reads the new device
  // from the audio service, so there is nothing here to re-point.
  property var _nodeSet: null

  // One completion handler. Component.onCompleted is an attached property, so
  // a second one in the same object is not a second hook - it is "Property
  // value set multiple times", and the file does not load at all. The peak
  // holds are taken here rather than in a handler of their own for that
  // reason.
  Component.onCompleted: {
    root._nodeSet = AudioNodes.observeSet("bar/volumeIsland")
    root._reacquirePeaks()
    Qt.callLater(root.refreshDisplay)
  }
  // Every subscription this view holds is dropped here, in one place: the
  // node-set observation and the two peak holds. A second destruction handler
  // elsewhere in the object is the same teardown split in two, and the first
  // one to be missed is the one that leaks.
  Component.onDestruction: {
    refreshTimer.stop()
    if (root._nodeSet !== null) {
      AudioNodes.release(root._nodeSet)
      root._nodeSet = null
    }
    root._releasePeaks()
  }

  // Live levels for the two inline meters, held from the one owner rather
  // than declared here. A monitor declared per view and gated on
  // `enabled: !!root.source` - a constant, not a demand signal - puts two
  // more monitors on the same two global nodes for every output with the
  // island open. The owner keeps one monitor per node for the whole shell
  // and hands out holds, so N outputs cost the same two objects and a
  // closed island costs none.
  //
  // A hold is a handle object, so the meter binds to its own hold: two
  // consumers of one node cannot be read as each other, and a released hold
  // stops resolving rather than keeping a reading whose monitor is gone.
  property var inputPeak: null
  property var outputPeak: null
  // Re-point guard. Both change handlers below run the same re-point, and
  // taking a hold binds its node, which can settle a device's ready state and
  // move the other one - so the second handler can arrive while the first is
  // still on the stack. A nested re-point would mint its own pair, have it
  // overwritten by the outer call's assignment, and leave that pair held by
  // the owner with no reference left here to release it: the monitor stays
  // bound, its peak-detect node stays in the graph, and the privacy
  // indicator stays lit after the island is gone. One re-point at a time,
  // and a re-point asked for mid-flight is served by a re-run once the
  // current one has landed.
  property bool _repointing: false
  property bool _repointQueued: false

  function _reacquirePeaks() {
    if (root._repointing) {
      root._repointQueued = true
      return
    }
    root._repointing = true
    // Loop rather than recurse: a re-point asked for from inside this one
    // only clears on the next pass, and the pass reads whatever the devices
    // name at that point, so the last pass is the one that settles.
    do {
      root._repointQueued = false
      root._releasePeaks()
      if (root.source !== null && root.source !== undefined) {
        root.inputPeak = Core.PipeWireState.acquirePeaks("bar/volumeIsland/input", root.source)
      }
      if (root.sink !== null && root.sink !== undefined) {
        root.outputPeak = Core.PipeWireState.acquirePeaks("bar/volumeIsland/output", root.sink)
      }
    } while (root._repointQueued)
    root._repointing = false
  }

  function _releasePeaks() {
    if (root.inputPeak !== null) Core.PipeWireState.releasePeaks(root.inputPeak)
    if (root.outputPeak !== null) Core.PipeWireState.releasePeaks(root.outputPeak)
    root.inputPeak = null
    root.outputPeak = null
  }

  // A peak is 0 while no hold is live, which is what a handle reports when
  // its monitor is not enabled. Reading through the handle keeps the
  // "reported only while fresh" rule in one place - the owner.
  readonly property real inputLevel: root.inputPeak !== null && root.inputPeak.active
    ? root.inputPeak.peak : 0
  readonly property real outputLevel: root.outputPeak !== null && root.outputPeak.active
    ? root.outputPeak.peak : 0

  onSourceChanged: root._reacquirePeaks()
  onSinkChanged: root._reacquirePeaks()
  // The holds are released by the single destruction handler above, so a
  // closed island takes the owner's monitors back to idle rather than leaving
  // them bound to a view that is gone.

  readonly property real outputVolume: root.sink && root.sink.audio ? root.sink.audio.volume : 0
  readonly property bool outputMuted: root.sink && root.sink.audio ? root.sink.audio.muted : false
  readonly property real inputVolume: root.source && root.source.audio ? root.source.audio.volume : 0
  readonly property bool inputMuted: root.source && root.source.audio ? root.source.audio.muted : false
  // Nothing audible on the output: an explicit mute or a level at zero.
  readonly property bool outputSilent: root.sink && root.sink.audio
    ? Core.Audio.silentFor(root.outputVolume, root.outputMuted) : false

  // Shared step/max come from the Audio core singleton; sliders still
  // write node values directly for 1:1 drag latency.
  readonly property real volumeStep: Core.Audio.step
  readonly property real maxVolume: Core.Audio.maxVolume
  readonly property real maxSourceVolume: Core.Audio.maxSourceVolume
  readonly property real streamMax: 1.5

  function setOutputVolume(v) {
    if (!root.sink || !root.sink.audio) return
    root.sink.audio.volume = Range.clamp(v, 0, root.maxVolume)
    if (v > 0 && root.sink.audio.muted) root.sink.audio.muted = false
  }

  function setInputVolume(v) {
    if (!root.source || !root.source.audio) return
    root.source.audio.volume = Range.clamp(v, 0, root.maxSourceVolume)
    if (v > 0 && root.source.audio.muted) root.source.audio.muted = false
  }

  // The device switch, unchanged: the backend's own preferred-device write
  // is the one thing this island is the owner of, and it is where a switch
  // from any output's island has to land. It touches the backend and
  // nothing this island holds - in particular not its node-set
  // observation - so a switch issued as the last island is being torn down
  // reaches the same place a switch from a first one does, and cannot write
  // to a tracker that is going with it. The new default arrives back
  // through Core.Audio on the next change, and the trackers that follow it
  // are the audio service's one pair.
  function setDefaultSink(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSink = node
    root.popOpen = ""
  }

  function setDefaultSource(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSource = node
    root.popOpen = ""
  }

  function sinkLabel(node) { return Model.nodeLabel(node) }
  function streamLabel(node) { return Model.streamLabel(node) }

  // Percentage readout color. Two bands, not one, because the two scales
  // end at different places: a boosted output/mic track runs to 200%, an
  // app row caps at 150%. So the device scale holds yellow all the way to
  // 150% and only turns red past it, while an app row is already 20% past
  // its own ceiling at 126% and says so there.
  //
  // Every band reads the same rounded percentage the text prints, so the
  // color and the digits cannot disagree, and a muted row keeps the muted
  // foreground - it prints no percentage at all, so a severity color
  // would be rating a level it is not showing.
  function pctColor(volume, muted, redFrom) {
    if (muted) return Ui.tint("foreground_1", 0.6)
    const band = LevelBand.band(volume, 101, redFrom)
    if (band === "red") return Ui.solid("red")
    if (band === "yellow") return Ui.solid("yellow")
    return Ui.tint("foreground_1", 0.6)
  }

  // Output and input readouts: red only once the level is past what even
  // a boosted device track can show as "headroom" (150% of 200%).
  function devicePctColor(volume, muted) { return root.pctColor(volume, muted, 151) }

  // App rows: red at 126%, a quarter of the way past their own 150% cap.
  function streamPctColor(volume, muted) { return root.pctColor(volume, muted, 126) }

  // The same two-step app lookup the mixer's rows use, so a stream that
  // the shipped set cannot serve still gets its theme icon (and the answer
  // is memoized by identity instead of re-walking the theme per row build).
  function streamIconSource(node) {
    var name = Model.appIconName(node)
    var resolved = AppIcons.url(name, "audio-x-generic")
    if (resolved !== "") return resolved
    return Icons.url("file-music", "foreground_1")
  }

  // 200% boost toggle: the frame turns red with a red-tinted
  // background while boosting; the volume-max glyph is always red.
  // Instantiated before each section title (output + input), each
  // bound to its own cap option.
  component BoostToggle: Rectangle {
    id: toggle

    required property string optionKey
    readonly property bool boosting: Settings.value(toggle.optionKey) === true
    readonly property bool hov: toggleHover.hovered
    readonly property bool press: toggleTap.pressed
    width: 26
    height: 22
    // Corners follow the compositor's rounding, like every other framed
    // control in the shell (the mixer's twin of this toggle already does).
    radius: RoundingPolicy.radius
    anchors.verticalCenter: parent.verticalCenter
    color: toggle.boosting
      ? (toggle.press ? Ui.tint("red", 0.3)
        : toggle.hov ? Ui.tint("red", 0.18) : Ui.tint("red", 0.08))
      : (toggle.press ? Ui.tint("foreground_1", 0.2)
        : toggle.hov ? Ui.tint("foreground_1", 0.12) : Ui.tint("foreground_1", 0.05))
    border.width: 1
    border.color: toggle.boosting
      ? (toggle.hov ? Ui.solid("red") : Ui.tint("red", 0.55))
      : (toggle.hov ? Ui.tint("foreground_1", 0.5) : Ui.tint("foreground_1", 0.25))

    Behavior on color {
      ColorAnim {}
    }
    Behavior on border.color {
      ColorAnim {}
    }

    Icon {
      anchors.centerIn: parent
      name: "volume-max"
      colorKey: "red"
      size: 14
    }

    HoverHandler {
      id: toggleHover

      cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
      id: toggleTap

      onTapped: {
        Settings.toggleOption(toggle.optionKey)
      }
    }

  }

  // --- reusable slider - sharp progress-bar style, no thumb ---
  // Seek-lane rule: clicks glide to the point, sustained drags snap
  // (past 6px the lane belongs to the finger) and commit on release.
  component VSlider: Rectangle {
    id: slider
    required property real value
    required property real maximum
    property bool muted: false
    property bool dragging: false
    property real pressX: 0
    signal moved(real v)

    implicitHeight: 6
    height: 6
    radius: RoundingPolicy.radius
    color: Ui.solid("background_2")
    clip: true

    Rectangle {
      id: fill
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * (slider.muted ? 0 : Range.clamp01(slider.value / slider.maximum))
      radius: RoundingPolicy.radius
      color: Ui.solid("accent")
      Behavior on width { enabled: !slider.dragging && MotionPolicy.enabled; Glide { duration: Ui.normalMs } }
    }

    // 100% mark. A track that runs past unity has to say where unity
    // sits: the midpoint of a boosted output/mic track, two thirds across
    // an app row's fixed 150%. The gate is the track itself, not the
    // boost option - a 1.0 maximum has nothing beyond 100% to mark, so
    // the line appears exactly where that slider's own cap sits above
    // unity (output/mic under their boost toggles, app rows always).
    //
    // 3px, not a hairline: this is the one mark on a 6px track that has
    // to be found at a glance rather than read, and a 1px stroke on a
    // track this thin is a rounding artifact at fractional widths - it
    // lands on a half pixel and antialiases into near-invisibility
    // exactly when the user is looking for it.
    Rectangle {
      visible: slider.maximum > 1
      width: 3
      height: parent.height
      // Half-width offset so the mark straddles the exact unity point
      // instead of sitting entirely to its right.
      x: parent.width / slider.maximum - width / 2
      color: Ui.solid("red")
    }

    MouseArea {
      anchors.fill: parent
      anchors.topMargin: -6
      anchors.bottomMargin: -6
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton

      function update(x) {
        var r = Range.clamp01(x / width)
        var v = r * slider.maximum
        slider.moved(v)
      }

      onPressed: mouse => {
        slider.pressX = mouse.x
      }
      onPositionChanged: mouse => {
        if (!pressed) return
        if (Math.abs(mouse.x - slider.pressX) > 6) {
          slider.dragging = true
          update(mouse.x)
        }
      }
      onReleased: mouse => {
        update(mouse.x)
        slider.dragging = false
      }
      // Same release rule as the seek lane: an interrupted drag must
      // never stick `dragging` on, or the fill glide stays dead.
      onCanceled: slider.dragging = false
    }

    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: event => {
        var st = root.volumeStep
        var d = event.angleDelta.y > 0 ? st : (event.angleDelta.y < 0 ? -st : 0)
        if (d !== 0) {
          var nx = Range.clamp(slider.value + d, 0, slider.maximum)
          slider.moved(nx)
        }
      }
    }

  }

  // In-place device selector: a chip naming the active device that opens
  // into the device list itself - the chip's own name becomes the list's
  // first row, so the active device is never drawn twice. The island window
  // grows to fit and no separate dropdown window is drawn. Height eases
  // open/closed on the shared Glide curve (clipped reveal + fade) and the
  // island's height tracks it 1:1.
  component DeviceSelector: Item {
    id: sel

    // Which single list is unfolded ("sink" / "source"), "" = closed.
    property string deviceListOpen: ""
    property string popKey: ""
    property bool expanded: sel.deviceListOpen === sel.popKey
    property var candidates: []
    property var active: null
    property string fallbackLabel: ""

    readonly property bool interactive: sel.candidates.length > 1
    // Option rows: a dropdown list, not a menu - deliberately slimmer than
    // Ui.rowMinH (34), which is for full-width list rows.
    readonly property int rowH: 26
    // Inset from the open plate's edge to the rows inside it, every side
    // alike, so a chosen row's fill never runs into the outline.
    readonly property int pad: Ui.s
    // The rows to draw: the active device first, then the rest in candidate
    // order. Opening swaps the chip for this list, and the chip's name is
    // the row it becomes - repeating it above the list is the duplicate the
    // swap exists to remove.
    readonly property var rows: {
      const a = sel.active
      const list = sel.candidates
      if (!a) return list
      const out = []
      const rest = []
      for (let i = 0; i < list.length; i++) {
        const n = list[i]
        if (n && n.id === a.id) out.push(n)
        else rest.push(n)
      }
      for (let j = 0; j < rest.length; j++) out.push(rest[j])
      return out
    }

    anchors.left: parent.left
    anchors.right: parent.right
    // Both states are the same box around one 26px row: the trigger's row
    // when collapsed, the option rows when open. Opening therefore adds rows
    // below the name instead of moving it. The window height follows this 1:1
    // via the island's islandSelfAnimating mode.
    height: sel.expanded ? list.height : 2 * sel.pad + sel.rowH

    Behavior on height {
      enabled: root.animationsEnabled
      Glide { duration: Ui.expandMs; easing.type: Easing.OutCubic }
    }

    clip: true

    // The open selector is ONE surface: the chip and its options share this
    // plate, so an unfolded control reads as a single box instead of a label
    // with a list parked under it. One step above the card it opens over,
    // with the same 1px inset hairline the menus draw around a focused entry.
    Rectangle {
      id: selPlate

      anchors.fill: parent
      radius: RoundingPolicy.radius
      color: Ui.solid("background_1")
      border.width: 1
      border.color: Ui.solid("background_3")
      opacity: sel.expanded ? 1 : 0
      visible: sel.expanded || selPlate.opacity > 0

      Behavior on opacity {
        enabled: root.animationsEnabled
        Glide { duration: Ui.expandMs; easing.type: Easing.OutCubic }
      }
    }

    // Chip: active device name + caret, inset by the spacing token on both
    // sides so the hover band breathes around the label instead of touching
    // its edges. A single candidate is still shown (it names the device)
    // but is not clickable - nothing to choose.
    // The trigger is the list's first row in everything that can be seen:
    // the same height, the same inset from the plate's edge, the same text
    // position. So opening cannot move the name - it fades this copy out
    // while the row's copy, with its fill, fades in underneath it.
    Item {
      id: chip
      x: sel.pad
      y: sel.pad
      width: parent.width - 2 * sel.pad
      height: sel.rowH
      opacity: sel.expanded ? 0 : 1
      visible: !sel.expanded || chip.opacity > 0

      Behavior on opacity {
        enabled: root.animationsEnabled
        Glide { duration: Ui.expandMs; easing.type: Easing.OutCubic }
      }

      Rectangle {
        anchors.fill: parent
        radius: RoundingPolicy.radius
        color: selMouse.containsMouse && sel.interactive ? Ui.tint("foreground_1", 0.06) : "transparent"
      }

      Row {
        id: selRow
        anchors.left: parent.left
        anchors.leftMargin: Ui.s
        anchors.right: selCaret.left
        anchors.rightMargin: Ui.s
        anchors.verticalCenter: parent.verticalCenter
        spacing: Ui.s

        Title {
          level: 5
          width: parent.width
          text: sel.active ? Model.nodeLabel(sel.active) : sel.fallbackLabel
          elide: Text.ElideRight
          color: sel.interactive ? Ui.solid("foreground_1") : Ui.tint("foreground_1", 0.6)
        }
      }

      // Caret: the menu's round-capped chevron - accent while the list is
      // open, dimmed foreground otherwise (the expandable affordance).
      Item {
        id: selCaret
        anchors.right: parent.right
        anchors.rightMargin: Ui.s
        anchors.verticalCenter: parent.verticalCenter
        width: sel.interactive ? 16 : 0
        height: 16
        visible: sel.interactive

        Chevron {
          anchors.centerIn: parent
          direction: sel.expanded ? "up" : "down"
          color: sel.expanded ? Ui.solid("accent") : Ui.tint("foreground_1", 0.5)
        }
      }

      MouseArea {
        id: selMouse
        anchors.fill: parent
        hoverEnabled: true
        // While open this copy is only fading out, and the row underneath it
        // owns the pointer: a live trigger would swallow the click meant for
        // the first option.
        enabled: !sel.expanded
        // Soft gate: a single-candidate selector is a refusal, not an
        // invisible surface, so the area stays in hover delivery and the
        // click guards itself.
        cursorShape: sel.interactive ? Qt.PointingHandCursor : Qt.ForbiddenCursor
        onClicked: if (sel.interactive) root.popOpen = sel.expanded ? "" : sel.popKey
      }
    }

    // The device list - the plate's only content while open, since the chip
    // that used to sit above it has become its first row. The selector grows
    // and the sections below follow.
    Rectangle {
      id: list
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      // The rows plus the plate's inset on both edges: this block is what
      // the padding above is measured around.
      implicitHeight: selCol.implicitHeight + 2 * sel.pad
      height: implicitHeight
      color: "transparent"
      opacity: sel.expanded ? 1 : 0
      visible: sel.expanded || list.opacity > 0

      Behavior on opacity {
        enabled: root.animationsEnabled
        Glide { duration: Ui.expandMs; easing.type: Easing.OutCubic }
      }

      Column {
        id: selCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: sel.pad
        anchors.rightMargin: sel.pad
        anchors.topMargin: sel.pad
        // A hair of air between rows, so two adjacent fills never read as
        // one tall row.
        spacing: 3

        Repeater {
          model: sel.rows

          delegate: Rectangle {
            id: opt

            required property var modelData
            readonly property bool isActive: opt.modelData.id === sel.active?.id

            width: selCol.width
            height: sel.rowH
            radius: RoundingPolicy.radius
            // The chosen device is the row the trigger became, so it is the
            // one row that sits a step above the plate: with the plate
            // painted background_1, an active row that filled nothing would
            // read as a hole in the surface rather than as the chosen one.
            // Hover tints the rest of the rows the same.
            color: opt.isActive ? Ui.tint("background_2", 0.7)
              : (optMouse.containsMouse ? Ui.tint("foreground_1", 0.06) : "transparent")
            // The chosen row wears the same 1px hairline as the plate it sits
            // on and as a focused entry in the menus: an inset border, so the
            // row gains an edge and no size.
            border.width: opt.isActive ? 1 : 0
            border.color: Ui.solid("background_3")

            Row {
              anchors.fill: parent
              anchors.leftMargin: Ui.s
              anchors.rightMargin: Ui.s
              spacing: Ui.s

              // No leading gutter: the row's text starts where the trigger's
              // text starts, so the name does not slide sideways when the chip
              // becomes this row. A dot column also charged every other row
              // its width, and the chosen device is already carried by the
              // fill, the weight and the brightness.
              Title {
                level: 3
                width: parent.width
                anchors.verticalCenter: parent.verticalCenter
                text: Model.nodeLabel(opt.modelData)
                elide: Text.ElideRight
                color: opt.isActive ? Ui.solid("foreground_0") : Ui.solid("foreground_1")
                font.bold: opt.isActive
              }
            }

            MouseArea {
              id: optMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: sel.pick(opt.modelData)
            }
          }
        }
      }
    }

    function pick(node) {
      if (sel.popKey === "sink") root.setDefaultSink(node)
      else root.setDefaultSource(node)
    }
  }

  // Skeleton entry: a static mock of one app row - icon mark, caption,
  // media-name line, the right-hand volume mock (mute-icon slot + pct
  // readout every real entry carries) and the 6px slider line. Painted
  // at the skeleton wash strength (specs 07/08: the no-apps state IS
  // the skeleton, static, no shimmer). Chrome matches the ArchUpdates
  // skeleton: tint @0.14, 0.55 shared opacity, 2px corners.
  component SkeletonEntry: Column {
    id: skel

    property real labelW: 120

    opacity: 0.55
    spacing: Ui.s / 2

    Row {
      width: parent.width
      spacing: Ui.s / 2

      // Icon placeholder: a little rounded rectangle filling the real
      // entry's 20x20 icon slot (no repeated glyph).
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 20
        height: 20
        radius: RoundingPolicy.radius
        color: Ui.tint("foreground_1", 0.14)
      }

      Column {
        // Same width the real label column gets: everything left after
        // icon, volume mock and pct readout reserve their slots.
        width: parent.width - 20 - 32 - 24 - 3 * parent.spacing - Ui.s / 2
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3

        SkeletonBar { width: Math.min(skel.labelW, parent.width) }

        SkeletonBar {
          width: Math.min(Math.round(skel.labelW * 0.55), parent.width)
          height: 6
        }
      }

      // Right-hand volume mock: the mute-icon slot (16x16, as the real
      // row's icon paints inside its 24px hit area)...
      Item {
        width: 24
        height: 24
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
          anchors.centerIn: parent
          width: 16
          height: 16
          radius: RoundingPolicy.radius
          color: Ui.tint("foreground_1", 0.14)
        }
      }

      // ...and the pct readout reserve (fits "Muted", 32 wide).
      SkeletonBar {
        anchors.verticalCenter: parent.verticalCenter
        width: 32
      }
    }

    SkeletonBar {
      width: parent.width
      height: 6
    }
  }

  // --- content lent to the shared host ---
  // Incubated on show, destroyed after the close fade. The card sizes
  // from body.implicitHeight through islandContentHeight above.
  Column {
    id: body
    width: parent.width
    spacing: Ui.m

    // Island header: the card's own name, so "Audio" is the title and
    // Output/Input/Applications are the sections under it. The glyph
    // leads, the way every other island header leads (network, bluetooth,
    // arch updates, printers, privacy) - a small foreground_1 mark at
    // 70% before the title.
    Row {
      width: parent.width
      spacing: Ui.s

      Icon {
        anchors.verticalCenter: parent.verticalCenter
        name: "volume-max"
        colorKey: "foreground_1"
        size: 14
        opacity: 0.7
      }

      Title {
        level: 1
        anchors.verticalCenter: parent.verticalCenter
        text: "Audio"
      }
    }

    // Output
    Column {
      width: parent.width
      spacing: Ui.s

      Row {
        width: parent.width
        spacing: Ui.m
        // Boost leads: the meter + readout pair stays adjacent and
        // the title never elides.
        BoostToggle {
          id: outBoost

          anchors.verticalCenter: parent.verticalCenter
          optionKey: "shell.volume.allowAboveHundred"
        }

        Title {
          id: outputTitle
          level: 1
          text: "Output"
        }
        // Inline live meter: the output level next to the title, the same
        // 4px bar the Input section carries. Takes whatever the boost, the
        // title and the reserved readout leave over.
        LiveMeter {
          id: outputMeter

          width: parent.width - outBoost.width - outputTitle.width - root.pctW - 3 * parent.spacing
          anchors.verticalCenter: parent.verticalCenter
          // Peak taps pre-volume signal: scale by the sink level so
          // the meter reads what is actually heard (20% volume never
          // paints full-scale).
          peak: root.outputLevel * root.outputVolume
          muted: root.outputMuted
        }
        Title {
          id: outputPct
          level: 4
          width: root.pctW
          horizontalAlignment: Text.AlignRight
          text: root.outputMuted ? "Muted" : Format.percent(root.outputVolume)
          color: root.devicePctColor(root.outputVolume, root.outputMuted)
          font.bold: true
        }
      }

      Row {
        width: parent.width
        spacing: Ui.s

        Icon {
          id: outputIcon
          anchors.verticalCenter: parent.verticalCenter
          name: {
            if (!root.sink || !root.sink.audio) return "volume-off"
            return Core.Audio.volumeIconFor(root.outputVolume, root.outputMuted)
          }
          colorKey: (!root.sink || !root.sink.audio) ? "red" : "foreground_1"
          // Silent (muted or at zero): only the X goes red, the speaker
          // keeps the foreground (the X paths carry class="indicator" -
          // see Icon/Icons).
          accentKey: root.outputSilent ? "red" : ""
          dimTiers: Core.Audio.volumeDimTiersFor(root.outputVolume, root.outputMuted)
          size: 18
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (root.sink && root.sink.audio) root.sink.audio.muted = !root.sink.audio.muted
            }
          }
        }

        Item {
          width: parent.width - outputIcon.width - parent.spacing
          height: outputSlider.implicitHeight
          anchors.verticalCenter: parent.verticalCenter
          VSlider {
            id: outputSlider
            anchors.fill: parent
            value: root.outputVolume
            maximum: root.maxVolume
            muted: root.outputMuted
            onMoved: v => root.setOutputVolume(v)
          }
        }
      }

      // Output device selector - in-place chip with an overlay dropdown.
      DeviceSelector {
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root.sink
        deviceListOpen: root.popOpen
        popKey: "sink"
        candidates: root.candidateSinks
        active: root.sink
        fallbackLabel: "No output device"
      }
    }

    // Input
    Column {
      width: parent.width
      spacing: Ui.s
      visible: !!root.source

      Row {
        width: parent.width
        spacing: Ui.m
        // Boost leads, mirroring the Output row.
        BoostToggle {
          id: micBoost

          anchors.verticalCenter: parent.verticalCenter
          optionKey: "shell.volume.micAllowAboveHundred"
        }

        // Natural width - the title never elides.
        Title {
          id: inputTitle
          level: 1
          text: "Input"
        }
        // Inline live meter: the input level next to the title, the same
        // 4px bar and the same data the Output section carries.
        LiveMeter {
          id: inputMeter

          width: parent.width - micBoost.width - inputTitle.width - root.pctW - 3 * parent.spacing
          anchors.verticalCenter: parent.verticalCenter
          peak: root.inputLevel * root.inputVolume
          muted: root.inputMuted
        }
        Title {
          id: inputPct
          level: 4
          width: root.pctW
          horizontalAlignment: Text.AlignRight
          text: root.inputMuted ? "Muted" : Format.percent(root.inputVolume)
          color: root.devicePctColor(root.inputVolume, root.inputMuted)
          font.bold: true
        }
      }

      Row {
        width: parent.width
        spacing: Ui.s
        Icon {
          id: inputIcon
          anchors.verticalCenter: parent.verticalCenter
          name: root.inputMuted ? "mic-off" : "mic-on"
          colorKey: "foreground_1"
          // Muted: only the slash goes red, the mic keeps the foreground
          // (the slash carries class="indicator" - see Icon/Icons).
          accentKey: root.inputMuted ? "red" : ""
          size: 18
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (root.source && root.source.audio) root.source.audio.muted = !root.source.audio.muted
            }
          }
        }
        Item {
          width: parent.width - inputIcon.width - parent.spacing
          height: inputSlider.implicitHeight
          anchors.verticalCenter: parent.verticalCenter
          VSlider {
            id: inputSlider
            anchors.fill: parent
            value: root.inputVolume
            maximum: root.maxSourceVolume
            muted: root.inputMuted
            onMoved: v => root.setInputVolume(v)
          }
        }
      }

      // Input device selector - in-place chip with an overlay dropdown.
      DeviceSelector {
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root.source
        deviceListOpen: root.popOpen
        popKey: "source"
        candidates: root.candidateSources
        active: root.source
        fallbackLabel: "No input device"
      }
    }

    // Applications header. Title row mirrors the network island's
    // section headers: small foreground_1 glyph at 70% before the caps
    // title.
    Item {
      width: parent.width
      height: 26

      SectionLabel {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        icon: "grid"
        text: "APPLICATIONS"
      }
      Title {
        level: 4
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.displayStreams.length + (root.displayStreams.length === 1 ? " app" : " apps")
        visible: root.displayStreams.length > 0
      }
    }

    Item {
      width: parent.width
      height: liveCol.implicitHeight
      visible: !root._appsEmpty

      Column {
        id: liveCol

        width: parent.width
        spacing: Ui.m

        List {
          id: appList
          // Plain stream rows with no selection concept: the shared
          // highlight bar would sit on the first app forever.
          selectionHighlight: false
          width: parent.width
          height: Math.min(appList.contentHeight, 180)
          stableModel: root.displayStreams
          spacing: Ui.s
          interactive: appList.contentHeight > appList.height
          delegate: streamDelegate
        }

        // Filler skeleton rows under the live ones, up to the three-row
        // window shared with the empty state: discoveries land on rows
        // that are already laid out instead of collapsing the section.
        // Static by design (the empty overlay owns the note) and toned
        // like it, so a list filling up reads as one block.
        Column {
          width: parent.width - root.rowPad
          spacing: Ui.m
          opacity: 0.8
          visible: root.displayStreams.length < 3

          Repeater {
            model: Math.max(0, 3 - root.displayStreams.length)

            delegate: SkeletonEntry {
              width: parent.width
              labelW: [120, 96, 108][index % 3]
            }
          }
        }
      }

      // Overlaid inside the viewport edge (ArchUpdates/Battery pattern):
      // app rows already end at rowPad, so nothing runs underneath.
      ScrollBar {
        flickable: appList
        anchors.right: parent.right
        anchors.rightMargin: 1
        anchors.top: appList.top
        anchors.topMargin: 8
        anchors.bottom: appList.bottom
        anchors.bottomMargin: 8
        thickness: 3
        radius: RoundingPolicy.radius
      }
    }

    // Empty state: three skeleton rows (specs 07/08 - static, no shimmer)
    // dimmed as a section, with the note centered over them. The section
    // keeps its populated footprint while reading as idle.
    Item {
      width: parent.width
      height: emptyCol.implicitHeight
      visible: root._appsEmpty

      Column {
        id: emptyCol

        width: parent.width
        spacing: Ui.m
        opacity: 0.8

        SkeletonEntry {
          width: parent.width
          labelW: 120
        }

        SkeletonEntry {
          width: parent.width
          labelW: 96
        }

        SkeletonEntry {
          width: parent.width
          labelW: 108
        }
      }

      // Overlay presence, 1.2x: the idle section reads at a glance, so
      // the glyph and the note render one step above their resting sizes
      // (explicit sizes, not a transform scale, so the text stays crisp).
      Column {
        anchors.centerIn: parent
        spacing: Ui.s

        Icon {
          anchors.horizontalCenter: parent.horizontalCenter
          name: "list"
          colorKey: "foreground_1"
          size: Math.round(32 * 1.2)
          opacity: 0.7
        }

        Title {
          anchors.horizontalCenter: parent.horizontalCenter
          level: 5
          font.pixelSize: Math.round(Ui.fontS * 1.2)
          text: "No apps playing audio"
          color: Ui.tint("foreground_1", 0.6)
        }
      }
    }
  }

  Component {
    id: streamDelegate
    Item {
      id: row
      required property var modelData
      required property int index
      width: ListView.view ? ListView.view.width : 240
      height: col.implicitHeight

      readonly property var node: row.modelData
      readonly property real vol: row.node && row.node.audio ? row.node.audio.volume : 0
      readonly property bool muted: row.node && row.node.audio ? row.node.audio.muted : false
      // Nothing audible: the explicit mute or a level at zero. The glyph
      // reads this; the title and the "Muted" readout keep `muted`.
      readonly property bool silent: Core.Audio.silentFor(row.vol, row.muted)

      Column {
        id: col
        // End at rowPad: the overlaid scrollbar needs its 4px in the
        // viewport edge, so the readout and slider never run under it.
        width: parent.width - root.rowPad
        spacing: Ui.s / 2

        Row {
          width: parent.width
          spacing: Ui.s / 2

          IconImage {
            id: appIcon
            width: 20
            height: 20
            source: root.streamIconSource(row.node)
            asynchronous: true
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - appIcon.width - 32 - 24 - 3 * parent.spacing - Ui.s / 2
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Title {
              level: 3
              width: parent.width
              text: root.streamLabel(row.node)
              elide: Text.ElideRight
              color: row.muted ? Ui.tint("foreground_1", 0.5) : Ui.solid("foreground_0")
            }
            Title {
              level: 4
              width: parent.width
              text: Model.nodeProps(row.node)["media.name"] || ""
              elide: Text.ElideRight
              visible: text !== ""
            }
          }

          Item {
            width: 24
            height: 24
            anchors.verticalCenter: parent.verticalCenter
            Icon {
              id: muteIcon
              anchors.centerIn: parent
              name: Core.Audio.volumeIconFor(row.vol, row.muted)
              colorKey: row.silent ? "red" : "foreground_1"
              dimTiers: Core.Audio.volumeDimTiersFor(row.vol, row.muted)
              size: 16
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (row.node && row.node.audio) {
                  row.node.audio.muted = !row.muted
                }
              }
            }
          }

          Title {
            id: pctText
            level: 4
            text: row.muted ? "Muted" : Format.percent(row.vol)
            color: root.streamPctColor(row.vol, row.muted)
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
            width: 32
            horizontalAlignment: Text.AlignLeft
          }
        }

        VSlider {
          width: parent.width
          value: row.vol
          maximum: root.streamMax
          muted: row.muted
          onMoved: v => {
            if (row.node && row.node.audio) {
              row.node.audio.volume = Range.clamp(v, 0, root.streamMax)
              if (v > 0 && row.node.audio.muted) row.node.audio.muted = false
            }
          }
        }
      }
    }
  }
}
