pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import QtQuick.Layouts
import Quickshell.Widgets
import qs.common
import qs.services as Core
import "MixerModel.js" as Model

// One stream row: the application's own desktop icon, its name, what it is
// playing, the level with its meter stacked under the fader as one control,
// the shell's own level affordances, the picker that routes it to another
// device, and - on a surround capture stream - the per-channel levels that
// stream actually has.
//
// The picker is the shell's ONE dropdown: the window holds the open key, the
// entries and the highlight, and this row only says which trigger it is, what
// its candidates are, and where its chip is. That is why no row can be open
// while another is, and why the list is an overlay in the window rather than an
// in-flow block under the chip - an in-flow list made the row taller while it
// was open and reserved a fixed-width column the name then had to fit inside.
//
// The stream's own volume and mute are native reads and writes, exactly like a
// device's. Routing is the one thing this app cannot do natively:
// Quickshell 0.3.1's `Quickshell.Services.Pipewire` exposes no link creation,
// so a move is a `pactl move-sink-input` (playback) or `pactl
// move-source-output` (capture) child whose two numbers are PULSE indices
// rather than PipeWire ids. This row never builds that argv: it says which
// device the user picked and the controller owns the map and the child.
//
// The picker is disabled - with a stated reason - in two distinct cases, and
// they are not the same failure: a graph with no device on the right side
// (nothing to move it TO) and a stream the routing map cannot address (no
// index to move it FROM, which is what a filter leg or an unregistered virtual
// stream looks like). Offering a target for the second case would put a
// `pactl` verb on a node it cannot name. A third case refuses for a moment
// rather than for a reason: the map is still being read, so there is no index
// to move from yet, and the chip says so instead of claiming one is missing.
Item {
  id: row

  required property var node
  // true for a capture stream, false for a playback one: it selects both the
  // device side the picker offers and the `pactl` verb the move uses.
  property bool capture: false
  // The devices this stream may be routed to, already filtered to the side
  // that matches `capture`.
  property var candidates: []
  // The device it plays through or records into now, as a node, or null when
  // the graph links it to nothing. A node rather than a label so the picker's
  // "you are here" dot is keyed on the device and not on a string that two
  // devices can share.
  property var target: null
  // The controller's routing map. Empty here on purpose: the picker is
  // disabled when it cannot address this stream, so a row that has no map is
  // a row that refuses rather than one that guesses.
  property var pulse: ({})
  // The controller, for the per-channel write below. Null disables the channel
  // block outright rather than rendering controls with nothing behind them.
  property var controller: null
  // The window's holder, which owns the ONE dropdown state. A row does not own
  // a flag of its own: a row-owned flag cannot see the other rows, so two
  // lists could be open at once and a click on a third trigger had nothing to
  // say about either of them. Null on a nested row, which offers no list.
  property var mixerWindow: null
  // A row nested under a device: the device above it IS the target, so the
  // picker would repeat a choice the parent already made.
  property bool nested: false

  signal routeRequested(var node, var device, bool capture)

  // This row's trigger key. The holder compares it against the key that is open
  // and against the entry a commit carries, so "which list is open" and "which
  // row committed" are both answerable from one string.
  readonly property string popKey: "stream/" + row.nodeKey
  readonly property bool open: row.mixerWindow !== null
    && row.mixerWindow.isPopOpen(row.popKey)

  readonly property var audio: row.node !== null && row.node !== undefined
    && row.node.audio !== undefined ? row.node.audio : null
  readonly property real volume: row.audio !== null ? Number(row.audio.volume) : 0
  readonly property bool muted: row.audio !== null ? row.audio.muted === true : false
  readonly property string nodeKey: Model.nodeKey(row.node)
  readonly property string targetKey: Model.nodeKey(row.target)

  // The routing map's answer for this stream: the Pulse index of its
  // sink-input (playback) or source-output (capture). -1 means the map cannot
  // address this node, which is the case the picker reports rather than hides.
  readonly property int pulseStream: Model.pulseIndex(
    row.capture ? row.pulse.sourceOutputs : row.pulse.sinkInputs, row.nodeKey)

  // Whether the routing map has been asked about yet. This is what separates
  // "nobody has looked yet" from "the map came back and named no device for this
  // stream", and the two print differently because they are different facts: the
  // first is the shell a moment from an answer, the second is an answer.
  //
  // Read off the controller's own stamp rather than off the shape of `pulse`,
  // because the two states have the same shape: an unresolved map and a daemon
  // that answered with nothing are both the five empty buckets.
  readonly property bool routed: Model.routingSettled(row.controller)

  // Why the picker cannot be used, "" when it can.
  //
  // A stream the map has not answered for is not a stream the map cannot address,
  // and both cases reduce to the same `pulseStream < 0`. Only the second is a
  // reason to refuse: the unresolved one says the shell is still reading, and
  // says it as a state rather than as a fault, because on a fresh open every row
  // would otherwise open with a claim about itself that is not yet true.
  readonly property string blockedReason: row.nested ? ""
    : (row.candidates.length === 0 ? "no device to route to"
      : (!row.routed ? "reading the routing map"
        : (row.pulseStream < 0 ? "no Pulse index for this stream" : "")))

  // Whether the chip is a control at all. A nested row has the device above it,
  // so it offers no device list of its own and its chip has nothing to open -
  // which is why the chip is laid out but not drawn rather than drawn and dead.
  // The slot keeps its width so a nested row's level icon and percentage sit
  // under the parent device's.
  readonly property bool pickable: !row.nested && row.blockedReason === ""

  // The stream cap, the same 1.5 the bar's island uses for its own app rows: a
  // stream is allowed headroom even when the device is not. Not a local
  // constant because it is the number the island draws its rows against, and a
  // mixer slider ending at 100% while the island's ends at 150% would be two
  // answers to one question.
  readonly property real maximum: 1.5

  // The candidate list in the popover's own entry shape, built once per
  // candidate change rather than once per gesture. The chip's label, the
  // keyboard's step, the accessible actions and the open list all read this one
  // array: a handler that rebuilt it per keypress would allocate on every step,
  // and a popover whose model followed the pointer is a popover that rebuilds
  // its delegates while you are reading them.
  //
  // `key` names the CANDIDATE - here the device - and not the trigger: the one
  // commit path tells rows apart by the trigger key they carry, and a candidate
  // that carried one too would be answering a question nobody asked of it.
  property var entries: []

  function _buildEntries() {
    const list = row.candidates
    const out = []
    for (let i = 0; i < list.length; i++) {
      const node = list[i]
      const key = Model.nodeKey(node)
      out.push({
        key: key,
        text: Model.label(node),
        enabled: true,
        active: key !== "" && key === row.targetKey,
        index: i,
        value: node
      })
    }
    return out
  }

  function _rebuild() {
    row.entries = row._buildEntries()
    // The window draws the open list out of its own copy of these, so a rebuild
    // has to hand the new ones over while the list is up: a commit that lands
    // with the list still open - which is what Enter does - would otherwise
    // leave the entry that is now the target printing the old value's mark.
    // Null on a nested row, which owns no list.
    if (row.mixerWindow === null) return
    row.mixerWindow.refreshPop(row.popKey, row.entries)
  }

  onCandidatesChanged: row._rebuild()
  onTargetKeyChanged: row._rebuild()

  // A peak monitor is bound only once the node's own channel map is known.
  // Quickshell matches its capture stream's channels against the node's and
  // refuses - through a backend error, once per process callback - when they do
  // not line up, and a stream whose channels are still `PwAudioChannel.Unknown`
  // is exactly that case. Until they arrive the meter draws the dead track it
  // draws for a null handle, which is the same degradation PipeWireState
  // already answers with for a node it will not monitor.
  property var peak: null
  // The node the hold was taken on, recorded beside the handle so a delegate
  // that is handed a DIFFERENT node can give the old hold back first. See
  // DeviceRow._syncPeak(), which is the same mechanism and the same reason.
  property var _peakNode: null

  // Fixed slot widths, published as properties so the header is arithmetic a
  // layout can read rather than a chain of `children[n]` lookups - a delegate
  // that reads `children[n]` breaks the moment a sibling is added. Nothing here
  // is a sum against the row's own width: the row is a partition of it, written
  // once below.
  readonly property int iconW: 20
  readonly property int levelW: 16
  readonly property int pctW: 44
  // What the level column is given: the usable row width less a fixed
  // allowance. The fixed slots, the gaps between them, the name's reserve and the
  // chip's share go into the allowance and what is left is the fader and the meter
  // under it. Preferred and minimum are the SAME number, so the layout has no slack
  // to hand this column and none to take away from it, and that is the whole of
  // the rule: `RowLayout` divides slack in proportion to (preferred - minimum),
  // and a slot allowed to differ between the two is a slot whose width depends on
  // what the rest of the row asks for.
  //
  // Both texts are shares rather than fillers here, and the reason is the order
  // they appear in: the name sits in FRONT of the fader, so the name's width IS
  // the fader's x. A filler there is a label that grows and pushes the fader
  // along, which is what made two meters in one list disagree. The names that
  // need more room than their share elide inside it, and the one slot with a
  // minimum below its preferred is the name - so a row too narrow for all three
  // shares squeezes the name rather than running past the window's edge.
  readonly property int textReserve: 240
  // The chip's share. Its own text capped at it, so a device name prints in full
  // up to this width and elides past it, and the row's fader never moves either
  // way. Measured on this machine's two sinks: an 18-character name measured a
  // 131px label, which is inside the 170px of text this leaves.
  readonly property int pickerShare: 200
  // The fader's length is `VolumeSlider.implicitWidth` and nothing else - a
  // hardcoded 200 that this row reads rather than restates, so a device row, a
  // stream row and a per-channel row cannot drift apart. What is left of the row
  // goes to the name column, which is the `Layout.fillWidth` slot.

  // The chip's chrome: the caret, the two insets around it and the border, so
  // the label's own width is the chip's width less this.
  readonly property int pickerChrome: 2 * Ui.s + 12 + 2

  // The channel block, and the policy that decides whether a stream has one.
  //
  // `PwNodeAudio.volumes` is writable per channel, so a capture source with
  // more than a stereo pair has genuinely per-channel levels and drawing them
  // is the difference between a mixer and a volume button. A two-channel
  // stream does not: one fader is the whole of it, and a second row of
  // near-identical faders is noise rather than control. `known: false` draws
  // nothing at all, because a channel the API has not settled is not a channel
  // this app can name.
  readonly property var channels: row.controller !== null && row.channeled
    ? row.controller.channelInfo(row.node) : null
  readonly property bool channeled: row.capture && row.controller !== null
  readonly property bool channelRows: row.channels !== null
    && row.channels.known === true && row.channels.channelCount > 2

  // The shell's own level icon, and the tiers that dim its waves by level.
  // Both come from the audio service rather than from a switch here, so a row
  // in this window and a row in the bar's island colour by the same rule.
  readonly property string levelIconName: row.audio === null
    ? "volume-off" : Core.Audio.volumeIconFor(row.volume, row.muted)
  readonly property int levelIconTiers: row.audio === null ? 0
    : Core.Audio.volumeDimTiersFor(row.volume, row.muted)

  // The readout: `Muted` and no percentage, because a percentage beside a mute
  // would be rating a level that is not being heard. Two bands, matching the
  // island's app rows: a stream caps at 150%, so 126% is already a quarter of
  // the way past its own ceiling. The bands read the same rounded percentage
  // the text prints, so the colour and the digits cannot disagree.
  readonly property string pctText: row.muted ? "Muted" : Model.volumeText(row.volume, false)
  readonly property color pctColor: row.muted ? Ui.tint("foreground_1", 0.6)
    : (Math.round(row.volume * 100) >= 126 ? Ui.solid("red")
      : (Math.round(row.volume * 100) >= 101 ? Ui.solid("yellow")
        : Ui.tint("foreground_1", 0.6)))

  implicitHeight: col.implicitHeight
  height: col.implicitHeight

  function setVolume(v) {
    if (row.audio === null) return
    row.audio.volume = Math.max(0, Math.min(row.maximum, v))
    // Unmute only from a deliberate drag: a change-handler unmute would fire
    // on the graph side too and silently start a stream the user had muted.
    if (v > 0 && row.audio.muted) row.audio.muted = false
  }

  function toggleMute() {
    if (row.audio === null) return
    row.audio.muted = !row.audio.muted
  }

  function setChannelVolume(channel, v) {
    if (row.controller === null) return
    row.controller.setChannelVolume(row.node, channel, v)
  }

  // The one place a device is routed. The list is not closed here: the
  // holder closed it before this signal was raised, and a close this row
  // performed would be a second piece of state that could disagree with the
  // one list that is actually open.
  function routeTo(device) {
    if (row.blockedReason !== "") return
    row.routeRequested(row.node, device, row.capture)
  }

  // --- the selector ---
  //
  // Three verbs, and none of them writes: each one hands the window's holder
  // the entries this row already holds and the chip to anchor to, and the
  // holder decides what opens, what is highlighted and what commits. That is
  // what makes "one list at a time" a property of the window rather than a
  // promise each row makes about itself.
  function togglePicker() {
    if (!row.pickable) return
    row.mixerWindow.togglePop(row.popKey, row.entries, pickerChip)
  }

  function openPicker() {
    if (!row.pickable) return
    row.mixerWindow.openPop(row.popKey, row.entries, pickerChip)
  }

  function stepPicker(delta) {
    if (!row.pickable) return
    row.mixerWindow.stepOpen(delta)
  }

  // A screen reader's increase and decrease: the same open-then-step the arrow
  // keys do, and the only way the selection moves with no pointer on an entry.
  // The chip claims no wheel, so this is the whole of "route this somewhere
  // else" for anyone not driving a mouse over the list.
  function nudgePicker(delta) {
    if (!row.pickable) return
    if (!row.open) row.openPicker()
    row.stepPicker(delta)
  }

  // The one commit, wherever it came from: a click in the list, Enter or
  // Space. The key check is this row's own trigger, so a commit raised for
  // another row's list is not acted on here.
  Connections {
    target: row.mixerWindow

    // The key is checked, not the entry: it names the trigger the holder raised
    // this for, and a commit raised for another row's list is not acted on here.
    function onPopCommit(key, entry) {
      if (key !== row.popKey) return
      if (entry === null || entry === undefined) return
      row.routeTo(entry.value)
    }
  }

  Component.onCompleted: {
    row._rebuild()
    row._syncPeak()
  }
  Component.onDestruction: row._releasePeak()

  // Two ways the hold can become stale, and both are answered by the same pair:
  // the node itself changing under a delegate that is reused, and the node's
  // own channel map arriving after the first attempt.
  onNodeChanged: row._syncPeak()

  Connections {
    target: row.audio
    function onChannelsChanged() { row._syncPeak() }
  }

  // The hold, moved onto whatever node this row is showing now. A hold latched
  // at construction would meter the stream that left and refuse to take one for
  // the stream that arrived, because the old handle is not null. The channel
  // map is read off `row.node` rather than off the `audio` binding, because this
  // runs from `onNodeChanged` and a change handler can land before the dependent
  // binding has re-evaluated.
  function _syncPeak() {
    if (row._peakNode !== row.node) row._releasePeak()
    if (row.peak !== null) return
    const node = row.node
    if (node === null || node === undefined || node.audio === null
      || node.audio === undefined) return
    if (!Model.channelsKnown(node.audio.channels)) return
    const handle = Core.PipeWireState.acquirePeaks("audioMixer/stream", node)
    if (handle === null) return
    row.peak = handle
    row._peakNode = node
  }

  function _releasePeak() {
    row._peakNode = null
    if (row.peak === null) return
    Core.PipeWireState.releasePeaks(row.peak)
    row.peak = null
  }

  Column {
    id: col

    width: parent.width
    spacing: Ui.s / 2

    // One layout, and the text column is the only child that fills. Sizing
    // the label by subtracting five fixed slots from `header.width`
    // and the slider by reading the label's width back would make the row's
    // contents a sum against the parent, and every slot added since would
    // grow the bar past the window edge. `Layout.fillWidth` hands the
    // remainder to the
    // labels and `Layout.minimumWidth` says what each shrinkable slot needs, so
    // the layout - not an expression - decides where the row ends.
    RowLayout {
      id: header

      width: parent.width
      spacing: Ui.s

      // The application's own desktop icon, from the icon name the application
      // published for itself. `AppIcons.url` is the two-step lookup the shell
      // uses for every window identity: the shipped themed set first, then the
      // platform icon theme with an explicit fallback. The name deliberately
      // does NOT fall back to `node.name` - a filter chain's own name resolves
      // to nothing and the shell renders a miss as a purple checker - so a node
      // that named no icon gets the generic glyph instead.
      IconImage {
        id: appIcon

        Layout.preferredWidth: row.iconW
        Layout.preferredHeight: row.iconW
        Layout.alignment: Qt.AlignVCenter
        source: row.iconSource
        asynchronous: true
      }

      Column {
        id: labelCol

        // The name column is where a wider window now goes: the fader's length
        // is fixed, so the slack has to land somewhere, and a long application
        // or media name is the thing that can actually use it. `minimumWidth`
        // is what the column shrinks to before it starts truncating harder.
        Layout.preferredWidth: row.textReserve
        Layout.minimumWidth: 60
        Layout.fillWidth: true
        spacing: 1

        Title {
          level: 3
          width: parent.width
          text: Model.appName(row.node)
          elide: Text.ElideRight
          color: row.muted ? Ui.tint("foreground_1", 0.5) : Ui.solid("foreground_0")
        }

        Title {
          level: 4
          width: parent.width
          text: Model.mediaName(row.node)
          elide: Text.ElideRight
          visible: text !== ""
        }
      }

      // The level and the fader as ONE column: the meter is the track's own length,
      // directly under it, the shape the bar's app rows use. Side by side they
      // read as two unrelated bars - a 34px meter against a 150px track, with
      // their baselines matching by accident - and a meter you cannot line up
      // with the value it belongs to is a decoration.
      //
      // ONE meter, fed by the row's own peak hold: the handle is passed in
      // rather than acquired here, so this row still holds exactly one
      // subscription whatever draws it, and the stacked meter costs no second
      // one.
      Item {
        id: levelStack

        // The same number twice, on purpose: a layout slot that may differ
        // between its minimum and its preferred is a slot the layout may resize,
        // and this one is not allowed to be resized by anything a label says.
        // The number is the slider's own hardcoded length, read off the slider
        // so there is one fader length in the app rather than one per row.
        Layout.preferredWidth: track.implicitWidth
        Layout.minimumWidth: track.implicitWidth
        Layout.preferredHeight: levelCol.implicitHeight
        Layout.alignment: Qt.AlignVCenter

        Column {
          id: levelCol

          width: parent.width
          // The island's own gap between an app row and its slider.
          spacing: Ui.s / 2

          VolumeSlider {
            id: track

            width: parent.width
            maximum: row.maximum
            value: row.volume
            muted: row.muted
            interactive: row.audio !== null
            onMoved: function(v) { row.setVolume(v) }
          }

          // The meter is the TRACK's width, read off the track rather than off
          // the column: "exactly as wide as the fader above it" is then one
          // statement in one place, and a meter that draws itself at its own
          // default width cannot drift from it.
          LiveMeter {
            width: track.width
            height: 4
            peakHandle: row.peak
            // Peak taps are pre-volume, so the meter is scaled by the row's own
            // volume: a 20% stream must never paint full scale.
            gain: row.volume
            muted: row.muted
          }
        }
      }

      // The mute affordance, and the island's: the glyph carries the level, the
      // tiered paths carry the colour of it, and the click is the toggle. One
      // control rather than a glyph plus a switch side by side, because a row
      // with two mute buttons has no mute button.
      Item {
        id: levelToggle

        Layout.preferredWidth: row.levelW
        Layout.preferredHeight: row.levelW
        Layout.alignment: Qt.AlignVCenter

        Icon {
          anchors.centerIn: parent
          name: row.levelIconName
          colorKey: row.muted ? "red" : "foreground_1"
          accentKey: row.muted ? "red" : ""
          dimTiers: row.levelIconTiers
          size: row.levelW
        }

        MouseArea {
          anchors.fill: parent
          enabled: row.audio !== null
          cursorShape: Qt.PointingHandCursor
          onClicked: row.toggleMute()
        }

        Accessible.role: Accessible.CheckBox
        Accessible.name: "Mute"
        Accessible.checked: row.muted
      }

      Title {
        id: pctText

        Layout.preferredWidth: row.pctW
        Layout.alignment: Qt.AlignVCenter
        horizontalAlignment: Text.AlignRight
        text: row.pctText
        color: row.pctColor
        font.bold: true
      }

      // The routing picker: a selector with a value, not an action, so it is a
      // chip and not a DropdownButton. Hand-built rather than `Chip` because
      // `Chip` centres its label in the whole pill: a long device name would run
      // under the caret and past the chip's own edge, which names like
      // "Starship/Matisse HD Audio Controller Analog Stereo" make certain
      // rather than possible.
      //
      // Its slot is `pickerShare`, and its preferred width is its own text capped
      // at that share: the chip is the last thing in the row, so letting it take
      // the space the fader is not using gives a device name room to print
      // without letting the name decide where the fader is. A label wider than
      // the share elides, which is a name the user cannot read rather than a
      // meter that moves under them.
      Rectangle {
        id: pickerChip

        Layout.minimumWidth: row.pickerShare
        Layout.preferredWidth: Math.min(pickerLabel.implicitWidth + row.pickerChrome,
          row.pickerShare)
        Layout.preferredHeight: 24
        Layout.alignment: Qt.AlignVCenter
        radius: RoundingPolicy.radius
        clip: true
        // Drawn only where it is a control: a nested row's chip is the
        // parent's choice restated, so it holds the slot and paints nothing.
        opacity: row.nested ? 0 : (row.blockedReason === "" ? 1 : Ui.disabledOpacity)
        color: pickerMouse.containsMouse && row.pickable
          ? Ui.tint("foreground_1", 0.06) : "transparent"
        border.width: 1
        border.color: row.pickable
          ? Ui.tint(row.open ? "accent" : "background_3", 0.45)
          : Ui.tint("background_3", 0.7)

        Behavior on color { ColorAnim {} }
        Behavior on border.color { ColorAnim {} }

        Title {
          id: pickerLabel

          anchors.left: parent.left
          anchors.leftMargin: Ui.s
          anchors.right: caret.left
          anchors.rightMargin: Ui.s / 2
          anchors.verticalCenter: parent.verticalCenter
          level: 5
          text: row.pickerText
          elide: Text.ElideRight
          color: row.open ? Theme.color("accent") : Ui.solid("foreground_1")
        }

        Item {
          id: caret

          anchors.right: parent.right
          anchors.rightMargin: Ui.s / 2
          anchors.verticalCenter: parent.verticalCenter
          width: 12
          height: 12
          visible: row.pickable

          Chevron {
            anchors.centerIn: parent
            // The caret names the direction the list will open, which is the
            // browser's own tell: down when there is room below it, up when the
            // list has to flip.
            direction: row.open ? "up" : "down"
            color: row.open ? Theme.color("accent") : Ui.tint("foreground_1", 0.5)
          }
        }

        MouseArea {
          id: pickerMouse

          anchors.fill: parent
          enabled: row.pickable
          hoverEnabled: row.pickable
          cursorShape: row.pickable ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: row.togglePicker()
        }

        // Keyboard on the closed chip: Up/Down open the list and step the
        // highlight, Enter and Space open it. Escape is deliberately NOT
        // accepted here, so it falls through to the window's own handler and
        // still closes the mixer.
        //
        // There is NO WheelHandler on the chip. A wheel over it is not a claim
        // on the gesture, it is a scroll of the body the chip is a child of,
        // and an item that catches a wheel to walk its candidates is a control
        // that moves a stream per notch of a fling.
        activeFocusOnTab: row.pickable
        Keys.onPressed: function(event) {
          if (!row.pickable) return
          const down = event.key === Qt.Key_Down
          const up = event.key === Qt.Key_Up
          if (!down && !up && event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter
            && event.key !== Qt.Key_Space) return
          event.accepted = true
          row.openPicker()
          if (down || up) row.stepPicker(down ? 1 : -1)
        }

        Accessible.role: Accessible.ComboBox
        Accessible.name: "Route to device"
        // The reason rides the accessible description as well as the
        // status line, so it is not only a sighted user's problem.
        Accessible.description: row.blockedReason
        // The same open-then-step the arrow keys run, so the control is
        // complete for a screen reader as well as for a keyboard.
        Accessible.onIncreaseAction: row.nudgePicker(1)
        Accessible.onDecreaseAction: row.nudgePicker(-1)
        // A nested row's chip is not a control, so it is not offered to
        // assistive tech as one either.
        Accessible.ignored: row.nested
      }
    }

    // The reason, on the row itself rather than only in a tooltip: a disabled
    // control with no explanation reads as a broken mixer.
    Title {
      level: 5
      width: col.width
      x: row.iconW + Ui.s
      visible: !row.nested && row.blockedReason !== ""
      text: row.blockedReason
    }

    // --- per-channel levels ---
    //
    // Gated on the whole `channelRows` verdict rather than merely hidden, so a
    // stereo capture stream builds no channel rows at all and a node whose
    // channel map has not settled builds none either.
    Repeater {
      model: row.channelRows ? row.channels.names : []

      delegate: ColumnLayout {
        id: channelRow

        required property var modelData
        required property int index

        Layout.fillWidth: true
        spacing: 2

        Title {
          level: 4
          Layout.fillWidth: true
          text: Model.channelLabel(channelRow.modelData)
          elide: Text.ElideRight
        }

        VolumeSlider {
          Layout.fillWidth: true
          maximum: row.maximum
          value: channelRow.index < row.channels.volumes.length
            ? Number(row.channels.volumes[channelRow.index]) : 0
          muted: row.muted
          onMoved: function(v) { row.setChannelVolume(channelRow.index, v) }
        }
      }
    }

    // The device list is NOT here. It is an overlay in the window's own tree,
    // anchored to this chip and clipped to the window, so this row reserves no
    // slot for it: an in-flow list made the whole row taller while it was open,
    // which is what pushed the option rows off the bottom of a scrolled body
    // and what a fixed-width chip beside them made unreadable.
  }

  // What the chip says, and the three states it has to keep apart.
  //
  //   the device   what this stream plays into or records into, named off the
  //                device node rather than assembled from the stream's own
  //                properties.
  //   no target    the map came back and carries no device for this stream: a
  //                filter leg, or a node the daemon holds no Pulse object for.
  //                A fact about the stream, not a prompt.
  //   reading map  nothing has looked yet. Deliberately not a request:
  //                "choose device" is an instruction to act on something the
  //                shell had not looked up, and the row it names is about to
  //                print a device of its own.
  //
  // The device wins over the map's state, because the two sources are not equally
  // fresh: the link topology can answer while the map is still in flight, and a
  // row that can name its device should name it.
  readonly property string deviceLabel: Model.label(row.target)
  readonly property string pickerText: row.deviceLabel !== "" ? row.deviceLabel
    : (row.routed ? "no target" : "reading map")

  // The icon URL for this stream. `AppIcons.url` memoises, so a mixer that is
  // open for a day asks the theme once per distinct application rather than
  // per row per repaint; the empty name is answered with the shell's own
  // generic glyph, which recolours with the palette where a theme icon cannot.
  readonly property string iconSource: {
    const name = Model.appIconName(row.node)
    if (name === "") return Icons.url("music", "foreground_1")
    return AppIcons.url(name, "audio-x-generic")
  }
}