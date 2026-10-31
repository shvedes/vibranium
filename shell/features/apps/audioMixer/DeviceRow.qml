pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import QtQuick.Layouts
import qs.common
import qs.services as Core
import "MixerModel.js" as Model

// One device row, in two modes against one header:
//
//   live           a disclosure, the device icon, its label, the level with its
//                  meter stacked under the fader as one control, the shell's
//                  level affordances, the boost toggle, the monitor on an
//                  input row, "set default", and the expandable list of linked
//                  streams.
//   configuration  the same disclosure, icon and label, then the card's PROFILE
//                  picker and the device's per-channel levels.
//
// One row for both because they are one device: the two tabs are two views of
// the same node, and a second component for the second view would be two
// places to learn the same label, the same icon and the same disclosure.
//
// The profile picker is the shell's ONE dropdown: the window holds the open
// key, the entries and the highlight, and this row says only which trigger it
// is, what the card offers, and where its chip is. That is what keeps two
// lists from being open at once, and it is why the list is an overlay in the
// window sized to its own content rather than an in-flow block under the chip.
//
// Everything on the live half is read live off the node rather than
// snapshotted: `node.audio.volume` and `node.audio.muted` are the device's own
// state, and the graph changes them from the hardware side too - a headset's
// own volume ring moves the value and a mixer that cached it would show the
// old level until something else touched the row. They are valid reads because
// the controller holds the one `AudioNodes.observeSet` over the whole node set;
// without it every value here reads 0 and nothing is raised.
//
// "Set default" is the one write this app does not own end to end: the
// default device is PipeWire's own preference and PipeWireState is its
// documented entry point. Whether this row IS the default is read from the
// same state owner's published devices, so a default the daemon changed by
// itself - an unplugged device, a profile switch - is reflected here without
// this file writing anything.
Item {
  id: row

  required property var node
  // The AudioNodes handle for this device, or null. Read for its link
  // projection; the row neither takes nor releases it, because the controller
  // owns one handle per device for as long as the device is in the set.
  property var linkHandle: null
  property bool expanded: false
  // The controller, for the configuration half only. Null leaves that half
  // reporting what it cannot do rather than drawing controls with nothing
  // behind them.
  property var controller: null
  // The window's holder, which owns the ONE dropdown state. A row does not own
  // a flag of its own: a row-owned flag cannot see the other rows, so two
  // lists could be open at once and a click on a third trigger had nothing to
  // say about either of them. Null on a live-mode row, which opens no list.
  property var mixerWindow: null
  // The Configuration tab's view of this device: the card profile and the
  // per-channel levels, instead of the volume half.
  property bool configuration: false

  signal toggleExpanded()

  // This row's trigger key, unique per device and distinct from any stream
  // row's: the holder compares it against the key that is open and against the
  // entry a commit carries, so both "which list is open" and "which row
  // committed" are answerable from one string.
  readonly property string popKey: "profile/" + row.nodeKey
  readonly property bool open: row.mixerWindow !== null
    && row.mixerWindow.isPopOpen(row.popKey)

  readonly property var audio: row.node !== null && row.node !== undefined
    && row.node.audio !== undefined ? row.node.audio : null
  readonly property real volume: row.audio !== null ? Number(row.audio.volume) : 0
  readonly property bool muted: row.audio !== null ? row.audio.muted === true : false
  readonly property string nodeKey: Model.nodeKey(row.node)

  // Two defaults (a sink and a source) and two writes, so the row asks the
  // state owner which side it is on rather than inferring it from the icon.
  readonly property bool input: Model.classify(row.node) === "inputDevice"
  readonly property bool isDefault: row.input
    ? Model.nodeKey(Core.PipeWireState.source) === row.nodeKey
    : Model.nodeKey(Core.PipeWireState.sink) === row.nodeKey

  // The cap the slider range matches, read from the same place the bar's
  // volume island reads it: a boosted device offers the same range in the
  // mixer and in the bar, and neither invents its own 200%.
  readonly property real maximum: row.input ? Core.Audio.maxSourceVolume : Core.Audio.maxVolume

  // --- the monitor ---
  //
  // "Hear my voice" on an input device: this device's audio routed to the output
  // so the user can hear the microphone. The route belongs to the controller and
  // the row only says which device is asking, because the route has to OUTLIVE
  // this row - the device list is rebuilt whole whenever any node arrives, so a
  // row-owned flag would be recreated as "off" on every rebuild and would take
  // the user's route with it.
  //
  // Drawn on an input row in the live half only, beside the boost. Not in the
  // configuration half: that mode is the card's profile and the per-channel
  // levels, and a route is not a property of a card.
  readonly property bool monitorable: row.input && !row.configuration
    && row.controller !== null
  readonly property bool monitoring: row.monitorable
    && row.controller.monitorOn(row.nodeKey)

  // The refusal, and the two things that have to travel with it. `monitorNote`
  // is the controller's and is about whichever device last asked, so it is read
  // only when `monitorNoteKey` is THIS row's key - four microphones and one
  // refusal is one line on one row, not the same complaint under four
  // controls. `monitorBlock` is which of the two refusals it is, and without it
  // "this microphone exposes no capture ports" reads exactly like "the shell
  // was busy" - one is the hardware, the other is worth trying again.
  readonly property string monitorNote: row.controller === null
    ? "" : String(row.controller.monitorNote || "")
  readonly property string monitorBlock: row.controller === null
    ? "" : String(row.controller.monitorBlocked || "")
  readonly property bool noteMine: row.monitorNote !== ""
    && String(row.controller.monitorNoteKey || "") === row.nodeKey

  // What the row PAINTS, and it is the same one-line treatment the refused
  // profile write already has under the header: a `Title` at level 5 beside the
  // icon, where the click was, rather than a bubble that only exists while the
  // pointer is resting on a control. A control that cannot act has to say so
  // where the user is already looking, with no gesture of their own required -
  // a screen-reader string and nothing painted is why a tapped toggle that
  // decided it could not do it read as a dead button.
  //
  // The two lead-ins, and the distinction is the whole point: a fact about the
  // graph is not a failure of the click, and printing "monitor not started"
  // over a device that has no capture port would tell the user to do something
  // that cannot help them.
  readonly property string monitorNoteText: {
    if (!row.noteMine) return ""
    if (row.monitorBlock === Model.MONITOR_UNAVAILABLE) {
      return "cannot be monitored: " + row.monitorNote
    }
    return "monitor not started: " + row.monitorNote
  }

  // The whole sentence, for the bubble on the control and for
  // `Accessible.description`, in the profile chip's own split: the short line is
  // what is painted, and this is what says which of the two it is in words.
  readonly property string monitorTip: {
    if (!row.noteMine) return ""
    if (row.monitorBlock === Model.MONITOR_UNAVAILABLE) {
      return "This input cannot be heard on the output: " + row.monitorNote + "."
    }
    return "The monitor did not start: " + row.monitorNote + "."
  }

  // A refusal taken down while the pointer is resting on the toggle: the bubble
  // is still describing a click the user has already moved past, and a pointer
  // that has not moved would leave it there indefinitely. The same handoff the
  // profile chip makes when its own state turns ready.
  onNoteMineChanged: {
    if (!row.noteMine && row.mixerWindow !== null) {
      row.mixerWindow.hideTip(monitorToggle)
    }
  }

  // The sink the live route points at, which is the one published when the route
  // was made rather than the one the resolver would pick now - what the toggle
  // describes is what it is doing, not what the graph would choose next.
  readonly property string monitorSink: row.controller === null
    ? "" : String(row.controller.monitorSinkName || "")

  // The tab this row is drawn under, read off the window rather than handed in:
  // the rule the monitor's lifetime follows is "while the control is on screen",
  // and the window is the only thing that knows which tab that is. Null on a
  // row built without a window, which is the live-mode output row the Devices
  // tab passes none to - and an output row offers no monitor either way.
  readonly property string tab: row.mixerWindow === null
    ? "" : String(row.mixerWindow.tab || "")

  function toggleMonitor() {
    if (row.controller === null) return
    row.controller.toggleMonitor(row.node)
  }

  // Hand the route back. The row never writes a link itself: the argv, the
  // queue and the three teardown paths are the controller's, and a row with its
  // own would be a second set of rules for a write to the user's audio.
  function releaseMonitor() {
    if (row.controller === null) return
    row.controller.clearMonitor()
  }

  // A tab change retires the route, because the control that offers it is no
  // longer on screen. Nothing else about this row's destruction may: the list is
  // rebuilt behind fresh wrappers whenever a node arrives, and a teardown on that
  // would silence the microphone every few seconds on a busy graph.
  onTabChanged: {
    if (row.monitoring && row.tab !== "devices") row.releaseMonitor()
  }

  // The boost setting this row's side of the graph is governed by. Two keys,
  // one per side, the same two the bar's volume island toggles: boost is shell
  // policy rather than a property of one device, so every device row on this
  // side shows the same state and every one of them writes the same key.
  readonly property string boostOption: row.input
    ? "shell.volume.micAllowAboveHundred" : "shell.volume.allowAboveHundred"

  // The streams the graph routes through this device, in its own order. The
  // projection is the authority rather than a second `pactl list`: it is the
  // graph's own link list projected once for the whole device set, and it
  // answers "what is routed through here" in the same tick the answer changes.
  readonly property var attached: Model.attachedStreams(
    row.linkHandle === null || row.linkHandle === undefined
      ? [] : row.linkHandle.links, row.nodeKey)

  // The disclosure's two sentences: a definition of the list, and the state of
  // it when the list is empty. "Currently routed through" is what the
  // projection answers and all it answers - the links the graph holds on this
  // device now, not streams the user once associated with it and not every
  // stream that exists somewhere in the graph.
  //
  // The empty half names what empty means FOR THIS DEVICE, which is all the row
  // knows to say: the side, and the fact that nothing is routed through it. A
  // microphone with no stream routed through it is the ordinary state of a
  // machine nothing is recording from, so the sentence is the state and not a
  // warning.
  readonly property string linkedCaption: row.input
    ? "Streams currently routed through this input"
    : "Streams currently routed through this output"
  readonly property string linkedEmpty: row.input
    ? "No stream is routed through this input"
    : "No stream is routed through this output"

  // --- the configuration half ---
  //
  // `deviceProfiles` is the card's own answer: the profile list is CARD data
  // (`pactl list cards`), and a node reaches its card through the properties on
  // the node rather than through index order. `readable: false` is not an empty
  // picker, it is the absence of one - an index of 0 against a list nobody has
  // read is not the disable profile - so the chip is disabled, and a control
  // that cannot act has to say which of the three states it is in: see
  // `profileBlockedLabel` and `profileBlockedTip`.
  readonly property var profiles: row.configuration && row.controller !== null
    ? row.controller.deviceProfiles(row.node) : null
  readonly property bool profilesReadable: row.profiles !== null
    && row.profiles.readable === true
  readonly property var profileList: row.profilesReadable ? row.profiles.profiles : []

  // Which of the three states the picker is in, as one word: it has a list,
  // the device has no card to have a list from, or the list has not been read.
  // The model classifies rather than the row because the two reasons arrive as
  // the same `readable: false` and only the read's own reason string separates
  // them; the words themselves are this row's, beside the rest of its text.
  readonly property string profileState: Model.profileReadState(row.profiles)

  // Where the card currently sits, as an index into its OWN list, or -1 when
  // the active profile is not one the list carries. -1 rather than a guess: a
  // dot on an index the daemon did not name would mark a mode the card is not
  // in.
  readonly property int currentProfile: row._indexOfCurrent()

  function _indexOfCurrent() {
    if (row.profiles === null || row.profilesReadable !== true) return -1
    const cur = String(row.profiles.current === undefined ? "" : row.profiles.current)
    if (cur === "") return -1
    const list = row.profiles.profiles
    for (let i = 0; i < list.length; i++) {
      if (list[i].name === cur) return i
    }
    return -1
  }

  // The one failure line, and it is a refused WRITE and nothing else: the
  // controller's error belongs to the row that asked for it, and `profileError`
  // is one property on the controller rather than one per device, so printing
  // it on every configuration row would repeat the same complaint beside four
  // devices when one of them refused a profile - which reads as four broken
  // devices instead of one refused click.
  //
  // What a device has NO profiles for is not on this line at all, and neither
  // is a read that has not landed. Both are the chip's own state: the virtual
  // sink the equalizer's input presents is the case that made the point - it has
  // no ALSA card behind it, so the read answers `readable: false` with "no card
  // on this device", and that string belongs on the chip rather than under it,
  // where it would stand as a paragraph in the middle of the window for a
  // device that is working exactly as it should. It is also in-progress state
  // rather than a fault - the same
  // read answers "not read yet" while a refresh is in flight - so a line that
  // carried it would flash rather than persist, which is what a line in this
  // window must never do. The chip says both, on the chip, where it is the
  // control's own business.
  readonly property string profileNote: {
    const err = row.controller === null ? "" : String(row.controller.profileError || "")
    if (err !== "" && row._attempted >= 0) return "profile not changed: " + err
    return ""
  }

  // What the chip says when it has no list to open: the reason, in the two or
  // three words that fit beside the caret, and the whole sentence for the hover
  // and for a screen reader.
  //
  // "no card" and "not read yet" are deliberately different words. They were
  // both drawn as one dimmed chip with no words at all, which left a device
  // with no ALSA card behind it looking exactly like a card list that had not
  // been read - the first is what a graph full of filters is made of and the
  // second is a fault, and a user cannot tell which one they are looking at
  // from a control that says nothing.
  readonly property string profileBlockedLabel: row._blockedLabel()
  readonly property string profileBlockedTip: row._blockedTip()

  // Both are empty for a working chip rather than a fallback sentence: a reason
  // belongs to a control that has one, and a property that reported a "reason"
  // nobody asked about would be read by the next caller as one.
  function _blockedLabel() {
    if (row.profileState === "ready") return ""
    if (row.profiles === null || row.profiles === undefined) return "not read yet"
    if (row.profileState === "no-card") return "no card"
    return String(row.profiles.error) === Model.PROFILE_UNREAD
      ? "not read yet" : "read failed"
  }

  function _blockedTip() {
    if (row.profileState === "ready") return ""
    if (row.profiles === null || row.profiles === undefined) {
      return "Nothing has read this device's card, so there are no profiles to pick."
    }
    if (row.profileState === "no-card") {
      // A virtual node is a node the graph made: no ALSA card sits behind it,
      // so the daemon publishes no profiles for it. That is a fact about the
      // graph rather than a fault, and on a machine whose default sink is an
      // equalizer tap it is the ordinary case rather than the exceptional one.
      if (Model.isVirtualNode(row.node)) {
        return "A virtual node in the audio graph. It has no card of its own,"
          + " so it has no profiles to pick."
      }
      return "No card on this device, so there are no profiles to pick."
    }
    if (String(row.profiles.error) === Model.PROFILE_UNREAD) {
      return "The card profile list has not been read yet."
    }
    return "Reading the card profile list failed: " + String(row.profiles.error)
  }

  // A read that lands while the pointer rests on a chip turns that chip from a
  // reason into a selector, and the bubble it is still serving is now about
  // nothing. The hover itself has not changed, so nothing else would take it
  // down.
  onProfileStateChanged: {
    if (row.profileState === "ready" && row.mixerWindow !== null) {
      row.mixerWindow.hideTip(profileChip)
    }
  }

  // The profile index this row last asked for, or -1 for never. The only thing
  // that decides whether the controller's write error belongs on this row.
  property int _attempted: -1

  // The profile list in the popover's own entry shape, built once per list
  // change rather than once per gesture: the chip's label, the keyboard's step,
  // the accessible actions and the open list all read this one array, so a
  // handler that rebuilt it per keypress would allocate on every step.
  property var entries: []

  // The channel map. `known: false` means the API has not settled which channels
  // this node has, and a channel row drawn from an unsettled map is wrong
  // rather than approximate - so it draws nothing at all.
  readonly property var channels: row.configuration && row.controller !== null
    ? row.controller.channelInfo(row.node) : null
  readonly property bool channelRows: row.channels !== null
    && row.channels.known === true && row.channels.channelCount > 0

  function applyProfile(index) {
    if (row.controller === null) return
    row._attempted = index
    // The list is not closed here: the holder closed it before raising the
    // commit, and a close this row performed would be a second copy of state
    // that could disagree with the one list that is actually open.
    row.controller.setDeviceProfile(row.node, index)
  }

  function _buildEntries() {
    const list = row.profileList
    const out = []
    for (let i = 0; i < list.length; i++) {
      out.push({
        key: row.popKey + "/" + String(list[i].name),
        text: row.profileText(list[i]),
        enabled: list[i].available === true,
        active: i === row.currentProfile,
        index: list[i].index,
        value: list[i]
      })
    }
    return out
  }

  function _rebuild() {
    row.entries = row._buildEntries()
    // The window draws the open list out of its own copy of these, so a rebuild
    // has to hand the new ones over while the list is up: a commit that lands
    // with the list still open - which is what Enter does - would otherwise
    // leave the entry that is now the active profile printing the old one's mark.
    if (row.mixerWindow === null) return
    row.mixerWindow.refreshPop(row.popKey, row.entries)
  }

  onProfileListChanged: row._rebuild()
  onCurrentProfileChanged: row._rebuild()

  // The selector, four verbs and no writes: each hands the window's holder this
  // row's entries and its chip, and the holder decides what opens, what is
  // highlighted and what commits. That is what makes "one list at a time" a
  // property of the window rather than a promise each row makes about itself.
  function togglePicker() {
    if (!row.profilesReadable || row.mixerWindow === null) return
    row.mixerWindow.togglePop(row.popKey, row.entries, profileChip)
  }

  function openPicker() {
    if (!row.profilesReadable || row.mixerWindow === null) return
    row.mixerWindow.openPop(row.popKey, row.entries, profileChip)
  }

  function stepPicker(delta) {
    if (!row.profilesReadable || row.mixerWindow === null) return
    row.mixerWindow.stepOpen(delta)
  }

  // A screen reader's increase and decrease: the same open-then-step the arrow
  // keys do, and the only way the selection moves with no pointer on an entry.
  // The chip claims no wheel, so this is the whole of "change this value" for
  // anyone not driving a mouse over the list.
  function nudgePicker(delta) {
    if (!row.profilesReadable || row.mixerWindow === null) return
    if (!row.open) row.openPicker()
    row.stepPicker(delta)
  }

  // The one commit, wherever it came from: a click in the list, Enter, Space,
  // or the wheel settling. The key check is this row's own trigger, so a commit
  // raised for another row's list is not acted on here.
  Connections {
    target: row.mixerWindow

    // The key is checked, not the entry: it names the trigger the holder raised
    // this for, and a commit raised for another row's list is not acted on here.
    function onPopCommit(key, entry) {
      if (key !== row.popKey) return
      if (entry === null || entry === undefined) return
      row.applyProfile(entry.index)
    }
  }

  function setChannelVolume(channel, v) {
    if (row.controller === null) return
    row.controller.setChannelVolume(row.node, channel, v)
  }

  // What one profile entry prints. The description first, because that is what
  // the daemon calls the mode, then the availability, then the sink/source
  // counts the parser published - which is the whole reason the list is read
  // rather than guessed. The counts are left off the disable profile: 0 sinks
  // and 0 sources is what "disables the device" means, and the description
  // already says it.
  function profileText(entry) {
    if (entry === null || entry === undefined) return ""
    let out = String(entry.description !== "" ? entry.description : entry.name)
    if (entry.available !== true) out += " (unavailable)"
    if (Number(entry.sinks) > 0 || Number(entry.sources) > 0) {
      out += " - " + entry.sinks + " sink" + (entry.sinks === 1 ? "" : "s")
        + ", " + entry.sources + " source" + (entry.sources === 1 ? "" : "s")
    }
    return out
  }

  // The peak handle, taken by the row and given back by it. The shell's
  // monitor owner is refcounted per node, so a hold per meter row is what
  // makes "one monitor per node, any number of meters" true here.
  //
  // The hold waits on the node's channel map, and is re-taken when it lands:
  // Quickshell's peak monitor matches its capture stream's channels against the
  // node's and refuses - through a backend error, once per process callback -
  // when they do not line up, and a node whose channels are still
  // `PwAudioChannel.Unknown` is exactly that case. Until they arrive the meter
  // draws the dead track it draws for a null handle.
  property var peak: null
  // The node the hold was taken on. Recorded beside the handle rather than read
  // back off it, because a delegate that is handed a DIFFERENT node has to give
  // the old hold back before it can take one, and a handle carries no
  // recollection of what it was taken on.
  property var _peakNode: null

  implicitHeight: col.implicitHeight
  height: col.implicitHeight

  function setVolume(v) {
    if (row.audio === null) return
    row.audio.volume = Math.max(0, Math.min(row.maximum, v))
    // Unmute only from a deliberate drag. A change-handler unmute would fire
    // on the hardware side too, so a muted headset whose own volume ring the
    // user then turned would silently start playing.
    if (v > 0 && row.audio.muted) row.audio.muted = false
  }

  function toggleMute() {
    if (row.audio === null) return
    row.audio.muted = !row.audio.muted
  }

  function setDefault() {
    if (row.node === null || row.node === undefined) return
    if (row.input) Core.PipeWireState.setDefaultSource(row.node)
    else Core.PipeWireState.setDefaultSink(row.node)
  }

  Component.onCompleted: {
    row._rebuild()
    row._syncPeak()
  }

  // Three things go, and they are not the same kind of thing. The peak hold is
  // this row's own subscription and must not outlive it. The bubble this row
  // served is anchored to a chip inside it, so it goes before the chip rather
  // than after. The monitor route is NOT the row's: it belongs to the
  // controller and is dropped only when this row stops being the control that
  // offers it, which is a tab move - read off the WINDOW rather than off
  // `row.tab`, because a tab change that empties this row's model can destroy
  // the row before its own binding to the window's tab has caught up, and the
  // read that cannot be missed is the one that does not go through this row at
  // all.
  Component.onDestruction: {
    row._releasePeak()
    // Both bubbles this row serves, and the bubble goes before the control it
    // is anchored to: the monitor's anchor is the toggle above, which is a
    // child of this row's header.
    if (row.mixerWindow !== null) row.mixerWindow.hideTip(profileChip)
    if (row.mixerWindow !== null) row.mixerWindow.hideTip(monitorToggle)
    if (row.mixerWindow !== null && String(row.mixerWindow.tab) === "devices") return
    if (row.monitoring) row.releaseMonitor()
  }

  // Two ways the hold can become stale, and both are answered by the same pair:
  // the node itself changing under a delegate that is reused, and the node's
  // own channel map arriving after the first attempt.
  onNodeChanged: row._syncPeak()

  Connections {
    target: row.audio
    function onChannelsChanged() { row._syncPeak() }
  }

  // The hold, moved onto whatever node this row is showing now. `Repeater` does
  // not key its delegates, so a set that keeps its length but changes its
  // members re-points an existing row at a different node: a hold latched at
  // construction would then meter the node that left and refuse to take one for
  // the node that arrived, because the old handle is not null. Giving the old
  // hold back first is also what stops a rebound row from pinning a monitor on
  // a device it no longer draws.
  //
  // The channel map is read off `row.node` rather than off the `audio` binding,
  // because this runs from `onNodeChanged` and a change handler can land before
  // the dependent binding has re-evaluated. Reading the property chain here
  // makes the answer a function of the node alone and not of handler order.
  function _syncPeak() {
    if (row._peakNode !== row.node) row._releasePeak()
    if (row.peak !== null) return
    const node = row.node
    if (node === null || node === undefined || node.audio === null
      || node.audio === undefined) return
    if (!Model.channelsKnown(node.audio.channels)) return
    const handle = Core.PipeWireState.acquirePeaks("audioMixer/device", node)
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

  // Fixed slot widths, published so the layout can read them. Nothing here is a
  // sum against the row's own width, which is what made the bar run past the
  // window edge; the row is a partition of its width, written once below.
  readonly property int caretW: 16
  readonly property int boostW: 26
  readonly property int monitorW: 26
  readonly property int iconW: 18
  readonly property int levelW: 16
  readonly property int pctW: 44
  readonly property int defaultW: 84
  // What the level column is given: the usable row width less a fixed
  // allowance. Preferred and minimum are the SAME number, so the layout has no
  // slack to hand this column and none to take away from it - `RowLayout`
  // divides slack in proportion to (preferred - minimum), and a slot allowed to
  // differ between the two is a slot whose width depends on what the rest of the
  // row asks for, which is what moved a fader and the meter under it whenever a
  // device name changed length.
  //
  // The allowance is every fixed slot, the gaps between them (eight children in
  // this mode, seven gaps, and a ninth beside the boost on an input row, which
  // is where the monitor sits) and a reserve for the name. No chip allowance:
  // the profile chip belongs to the other mode, which draws no fader and no meter.
  //
  // The name keeps `Layout.fillWidth` here, and it measures the same on every
  // device row all the same. The fader beside it is `VolumeSlider.implicitWidth`
  // - the same hardcoded length the stream row reads - so a wider window buys a
  // longer device name rather than a longer bar.
  readonly property int textReserve: 240

  // The profile chip has no fixed width either: `profileMinW` is the floor it
  // may shrink to before its own label elides, and `profileChrome` is the label
  // plus the caret and the insets, so the chip's preferred width is its own
  // text. A profile description is arbitrary length - "Analog Stereo Output
  // (2 sinks, 0 sources)" is a fifth wider than "Off (disables the device)" -
  // so a constant column truncated the modes that need reading most. Measured
  // on a live 760px configuration row against a four-profile card: a 288px
  // chip, where the 220px column elided it.
  //
  // No `Layout.fillWidth` here either: a filler claims slack in proportion to
  // (preferred - minimum), and this chip's preferred width IS its own text, so it
  // has almost no spread to claim and would take the row's width instead of its
  // own. Nothing here decides the level column's width either - this chip is in
  // the configuration mode, which draws no fader and no meter at all.
  readonly property int profileMinW: 160
  readonly property int profileChrome: 2 * Ui.s + 12 + 2

  // The bar volume island's 200% boost toggle, lifted rather than reinvented.
  // The frame turns red while boosting and the volume-max glyph is always red,
  // which is the whole of its message: it is one bit of shell policy with a
  // visible consequence, and it lives next to the slider that bit widens.
  component BoostToggle: Rectangle {
    id: toggle

    required property string optionKey
    readonly property bool boosting: Settings.value(toggle.optionKey) === true
    readonly property bool hov: toggleHover.hovered
    readonly property bool press: toggleTap.pressed

    width: row.boostW
    height: 22
    radius: RoundingPolicy.radius
    color: toggle.boosting
      ? (toggle.press ? Ui.tint("red", 0.3)
        : toggle.hov ? Ui.tint("red", 0.18) : Ui.tint("red", 0.08))
      : (toggle.press ? Ui.tint("foreground_1", 0.2)
        : toggle.hov ? Ui.tint("foreground_1", 0.12) : Ui.tint("foreground_1", 0.05))
    border.width: 1
    border.color: toggle.boosting
      ? (toggle.hov ? Ui.solid("red") : Ui.tint("red", 0.55))
      : (toggle.hov ? Ui.tint("foreground_1", 0.5) : Ui.tint("foreground_1", 0.25))

    Behavior on color { ColorAnim {} }
    Behavior on border.color { ColorAnim {} }

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

      onTapped: Settings.toggleOption(toggle.optionKey)
    }

    Accessible.role: Accessible.CheckBox
    Accessible.name: "Allow above 100%"
    Accessible.checked: toggle.boosting
  }

  // The monitor, on an input row, beside the boost. Same frame and same pressed
  // and hover ramp as the boost beside it - two controls side by side that do
  // not agree about how they look are two controls the eye has to learn - with
  // the accent instead of red, because this one is a route rather than a policy
  // bit about how far the slider may travel.
  //
  // The glyph is `link`, the shell's own glyph for a link leg (it is what
  // MixerModel.iconForMediaClass hands a `Sink/Input/Audio` or
  // `Source/Output/Audio` node), because the action IS a graph link and not a
  // level. A speaker glyph here would sit next to this row's own speaker glyph
  // and read as a second control over the same question.
  component MonitorToggle: Rectangle {
    id: monitor

    // Read from the controller, never latched here: the route outlives this row,
    // so a row's own copy of it is a second answer that a rebuilt row gets wrong.
    readonly property bool active: row.monitoring
    readonly property bool usable: row.controller !== null
      && row.controller.portsReady === true
    readonly property bool hov: monitorHover.hovered
    readonly property bool press: monitorTap.pressed

    width: row.monitorW
    height: 22
    radius: RoundingPolicy.radius
    // Dimmed rather than absent while the ports are not read, and at FULL
    // strength while the device merely cannot be monitored: dimming on the
    // refusal would take away the only thing that can say why, and this control
    // is not removed when it cannot act, it explains itself. "Ports not read" is
    // in-progress state; "this device has no capture ports" is a verdict.
    opacity: monitor.usable ? 1 : Ui.disabledOpacity
    color: monitor.active
      ? (monitor.press ? Ui.tint("accent", 0.3)
        : monitor.hov ? Ui.tint("accent", 0.18) : Ui.tint("accent", 0.08))
      : (monitor.press ? Ui.tint("foreground_1", 0.2)
        : monitor.hov ? Ui.tint("foreground_1", 0.12) : Ui.tint("foreground_1", 0.05))
    border.width: 1
    border.color: monitor.active
      ? (monitor.hov ? Ui.solid("accent") : Ui.tint("accent", 0.55))
      : (monitor.hov ? Ui.tint("foreground_1", 0.5) : Ui.tint("foreground_1", 0.25))

    Behavior on color { ColorAnim {} }
    Behavior on border.color { ColorAnim {} }

    Icon {
      anchors.centerIn: parent
      name: "link"
      colorKey: monitor.active ? "accent" : "foreground_1"
      size: 14
    }

    HoverHandler {
      id: monitorHover

      // Enabled for the whole monitorable row rather than only while the ports
      // are read, because the ports being unread is one of the refusals this
      // control has to explain. `cursorShape` is the part that is conditional:
      // the pointer says "this does nothing" whenever the toggle is inert, and
      // the frame still brightens under the pointer because the reason is why
      // the user is there.
      enabled: row.monitorable
      cursorShape: monitor.usable ? Qt.PointingHandCursor : Qt.ArrowCursor

      onHoveredChanged: {
        if (row.mixerWindow === null) return
        if (hovered) row.mixerWindow.showTip(monitor, row.monitorTip)
        else row.mixerWindow.hideTip(monitor)
      }
    }

    TapHandler {
      id: monitorTap

      enabled: monitor.usable
      onTapped: row.toggleMonitor()
    }

    Accessible.role: Accessible.CheckBox
    Accessible.name: "Hear this input on the output"
    Accessible.checked: monitor.active
    // The whole sentence, the same one the row paints above and the bubble
    // serves on hover - kept, and not as a substitute for either. A screen
    // reader is told the reason for a control that cannot act whichever way it
    // asks; the painted line is what reaches everyone else, and this string is
    // what reaches the readers of both.
    Accessible.description: row.noteMine ? row.monitorTip
      : (row.monitoring ? "routes to " + row.monitorSink : "")
  }

  Column {
    id: col

    width: parent.width
    spacing: Ui.s / 2

    // One layout for both modes, with the label column the only child that
    // fills. The half that does not apply to the current mode is not hidden but
    // absent, so a configuration row cannot draw a volume control the mode does
    // not answer for.
    RowLayout {
      id: header

      width: parent.width
      spacing: Ui.s

      // The disclosure, leading the row the way it leads a tree: a device
      // with nothing linked to it still shows the control, greyed by the
      // caret's own colour rather than by hiding it, so the row's shape does
      // not change when a stream starts and stops.
      Item {
        id: caret

        Layout.preferredWidth: row.caretW
        Layout.preferredHeight: 16
        Layout.alignment: Qt.AlignVCenter

        Chevron {
          anchors.centerIn: parent
          direction: row.expanded ? "up" : "down"
          color: row.attached.length === 0
            ? Ui.tint("foreground_1", 0.25) : Ui.tint("foreground_1", 0.6)
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: row.toggleExpanded()
        }

        Accessible.role: Accessible.Button
        Accessible.name: row.expanded
          ? "Hide streams routed through this device"
          : "Show streams routed through this device"
      }

      BoostToggle {
        Layout.alignment: Qt.AlignVCenter
        optionKey: row.boostOption
        visible: !row.configuration
      }

      // Beside the boost, and only where the row can offer it: the slot is
      // collapsed on an output row and in the configuration half rather than
      // drawn dead, which is the mode switch's own discipline - a RowLayout
      // here ignores an invisible child, verified on this Qt.
      MonitorToggle {
        id: monitorToggle

        Layout.alignment: Qt.AlignVCenter
        visible: row.monitorable
      }

      Icon {
        id: devIcon

        Layout.preferredWidth: row.iconW
        Layout.preferredHeight: row.iconW
        Layout.alignment: Qt.AlignVCenter
        name: row.input ? (row.muted ? "mic-off" : "mic-on") : "speaker"
        colorKey: row.input || !row.muted ? "foreground_1" : "red"
        // Muted output: only the X goes red, the speaker keeps the
        // foreground - the X paths carry class="indicator".
        accentKey: !row.input && row.muted ? "red" : ""
        size: row.iconW

        // Not clickable, and that is the consolidation: this glyph answers
        // "which kind of device is this", and the level glyph below answers
        // "how loud, and is it muted". A row whose two glyphs both toggle the
        // mute has two answers to one question.
      }

      Column {
        id: labelCol

        Layout.fillWidth: true
        Layout.minimumWidth: 60
        spacing: 1

        Title {
          level: 3
          width: parent.width
          text: Model.label(row.node)
          elide: Text.ElideRight
          color: row.muted ? Ui.tint("foreground_1", 0.5) : Ui.solid("foreground_0")
        }

        Title {
          level: 4
          width: parent.width
          visible: row.isDefault && !row.configuration
          text: "default"
          elide: Text.ElideRight
        }
      }

      // The live half: the level with its meter stacked under the fader as one
      // control, the shell's level affordances, and the verb.
      Item {
        id: levelStack

        // The same number twice, on purpose: a layout slot that may differ
        // between its minimum and its preferred is a slot the layout may resize.
        Layout.preferredWidth: track.implicitWidth
        Layout.minimumWidth: track.implicitWidth
        Layout.preferredHeight: levelCol.implicitHeight
        Layout.alignment: Qt.AlignVCenter
        visible: !row.configuration

        Column {
          id: levelCol

          width: parent.width
          // The island's own gap between a row and its slider.
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
          // statement in one place.
          LiveMeter {
            width: track.width
            height: 4
            // The row's own peak hold, handed in rather than acquired here: one
            // subscription per node whatever draws it, and a stacked meter costs
            // no second one.
            peakHandle: row.peak
            // Peak taps are pre-volume, so the meter is scaled by the row's own
            // volume: a 20% device must never paint full scale.
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
        visible: !row.configuration

        Icon {
          anchors.centerIn: parent
          name: row.audio === null ? "volume-off"
            : Core.Audio.volumeIconFor(row.volume, row.muted)
          colorKey: row.muted ? "red" : "foreground_1"
          accentKey: row.muted ? "red" : ""
          dimTiers: row.audio === null ? 0
            : Core.Audio.volumeDimTiersFor(row.volume, row.muted)
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

      // The readout: `Muted` and no percentage, because a percentage beside a
      // mute would be rating a level that is not being heard. The bands are the
      // island's: yellow from 101% up, red only past 150%, which is three
      // quarters of what even a boosted device track shows as headroom. The
      // bands read the same rounded percentage the text prints, so the colour
      // and the digits cannot disagree.
      Title {
        Layout.preferredWidth: row.pctW
        Layout.alignment: Qt.AlignVCenter
        visible: !row.configuration
        horizontalAlignment: Text.AlignRight
        text: row.muted ? "Muted" : Model.volumeText(row.volume, false)
        color: {
          if (row.muted) return Ui.tint("foreground_1", 0.6)
          const pct = Math.round(row.volume * 100)
          if (pct >= 151) return Ui.solid("red")
          if (pct >= 101) return Ui.solid("yellow")
          return Ui.tint("foreground_1", 0.6)
        }
        font.bold: true
      }

      // The set-default verb, as a DropdownButton rather than a bare icon:
      // it is a one-shot action on a row, and the shell's own control for a
      // row action of that kind is this one.
      DropdownButton {
        Layout.preferredWidth: row.defaultW
        Layout.alignment: Qt.AlignVCenter
        visible: !row.configuration
        text: row.isDefault ? "DEFAULT" : "SET DEFAULT"
        accent: Theme.color("accent")
        enabled: !row.isDefault && row.node !== null
        onClicked: row.setDefault()
      }

      // The profile picker, the configuration mode's one verb. A selector with
      // a value rather than an action, so a chip rather than a DropdownButton,
      // hand-built for the reason StreamRow's picker is: a profile description
      // is arbitrary length and a pill that centres its label would run the
      // text under its own caret.
      //
      // The width is the label's own plus the chrome, and the list it opens is an
      // overlay in the window sized to its own content - so this chip reserves
      // neither a slot for the list nor a fixed column for the description.
      Rectangle {
        id: profileChip

        Layout.minimumWidth: row.profileMinW
        Layout.preferredWidth: profileLabel.implicitWidth + row.profileChrome
        Layout.preferredHeight: 24
        Layout.alignment: Qt.AlignVCenter
        visible: row.configuration
        radius: RoundingPolicy.radius
        clip: true
        opacity: row.profilesReadable ? 1 : Ui.disabledOpacity
        color: profileMouse.containsMouse && row.profilesReadable
          ? Ui.tint("foreground_1", 0.06) : "transparent"
        border.width: 1
        border.color: row.profilesReadable
          ? Ui.tint(row.open ? "accent" : "background_3", 0.45)
          : Ui.tint("background_3", 0.7)

        Behavior on color { ColorAnim {} }
        Behavior on border.color { ColorAnim {} }

        Title {
          id: profileLabel

          anchors.left: parent.left
          anchors.leftMargin: Ui.s
          anchors.right: profileCaret.left
          anchors.rightMargin: Ui.s / 2
          anchors.verticalCenter: parent.verticalCenter
          level: 5
          text: row.profileChipText
          elide: Text.ElideRight
          color: row.open ? Theme.color("accent") : Ui.solid("foreground_1")
        }

        Item {
          id: profileCaret

          anchors.right: parent.right
          anchors.rightMargin: Ui.s / 2
          anchors.verticalCenter: parent.verticalCenter
          width: 12
          height: 12
          visible: row.profilesReadable

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
          id: profileMouse

          anchors.fill: parent
          enabled: row.profilesReadable
          hoverEnabled: row.profilesReadable
          cursorShape: row.profilesReadable ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: row.togglePicker()
        }

        // The reason, on the control that carries it. A HoverHandler rather than
        // `profileMouse`: that area is disabled in both blocked states, and a
        // disabled mouse target is out of the hit-test chain entirely - it
        // reports no `containsMouse`, so a bubble hung off it would appear for
        // exactly the controls that cannot show one. A passive pointer handler
        // sees the same pointer whether or not a MouseArea below it is enabled.
        //
        // Gated on the blocked states rather than drawn for the whole chip: a
        // control that CAN act does not owe an explanation, and the sentence
        // under a working chip is one more line of chrome over the fader row.
        HoverHandler {
          enabled: row.profileState !== "ready" && row.mixerWindow !== null

          onHoveredChanged: {
            if (hovered) row.mixerWindow.showTip(profileChip, row.profileBlockedTip)
            else row.mixerWindow.hideTip(profileChip)
          }
        }

        // Keyboard on the closed chip: Up/Down open the list and step the
        // highlight, Enter and Space open it. Escape is deliberately NOT
        // accepted here, so it falls through to the window's own handler and
        // still closes the mixer.
        //
        // There is NO WheelHandler on the chip. A wheel over it is not a claim
        // on the gesture, it is a scroll of the body the chip is a child of, and
        // an item that catches a wheel to walk its candidates is a control that
        // writes a `wpctl` profile change per notch of a fling.
        activeFocusOnTab: row.profilesReadable
        Keys.onPressed: function(event) {
          if (!row.profilesReadable) return
          const down = event.key === Qt.Key_Down
          const up = event.key === Qt.Key_Up
          if (!down && !up && event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter
            && event.key !== Qt.Key_Space) return
          event.accepted = true
          row.openPicker()
          if (down || up) row.stepPicker(down ? 1 : -1)
        }

        Accessible.role: Accessible.ComboBox
        Accessible.name: "Device profile"
        // The refused write on a working chip, the reason on a dead one: the
        // description is read either way, so this is the one place a screen
        // reader learns why the control does nothing.
        Accessible.description: row.profilesReadable
          ? row.profileNote : row.profileBlockedTip
        // The same open-then-step the arrow keys run, so the control is
        // complete for a screen reader as well as for a keyboard.
        Accessible.onIncreaseAction: row.nudgePicker(1)
        Accessible.onDecreaseAction: row.nudgePicker(-1)
      }
    }

    // The profile list is NOT here. It is an overlay in the window's own tree,
    // anchored to the chip above and clipped to the window, so this row
    // reserves no slot for it: an in-flow list made the whole column taller
    // while it was open and gave a list of twelve modes nowhere to go on a
    // window with three devices in it.

    // The refused write, and only that. It is on the row rather than in
    // the header because it is this device's answer: a `wpctl` the daemon turned
    // down belongs beside the chip that asked for it, and a click that appears
    // to have done nothing needs saying so where the click was.
    Title {
      level: 5
      width: col.width
      x: row.caretW + row.boostW + row.iconW + 3 * Ui.s
      visible: row.configuration && row.profileNote !== ""
      text: row.profileNote
    }

    // The monitor's refusal, in the same place and the same treatment: a `Title`
    // at level 5 on the row, indented past the controls that were clicked, and
    // it stays until the next toggle decides otherwise. Not a bubble and not a
    // tooltip, because the tap that produced it is over by the time anyone could
    // read one - the pointer has to find a 26px control again to see what
    // happened, and a refusal nobody has to look for is the only version of
    // this that a tapped control can deliver.
    //
    // The x is the profile line's plus the monitor slot, because this only ever
    // draws on a monitorable row - an input row in the live half, where that
    // slot is in the layout and the four gaps are the real ones.
    Title {
      level: 5
      width: col.width
      x: row.caretW + row.boostW + row.monitorW + row.iconW + 4 * Ui.s
      visible: row.monitorNoteText !== ""
      text: row.monitorNoteText
    }

    // --- the per-channel levels ---
    //
    // There is NO per-channel mute here, and that is an API limit rather than
    // an omission: `PwNodeAudio` publishes `muted` for the node as a whole and
    // `volumes` for the channels, and nothing else. A switch here would be a
    // control that silently does nothing, which is worse than an absent one.
    Repeater {
      model: row.channelRows ? row.channels.names : []

      delegate: ColumnLayout {
        id: channelRow

        required property var modelData
        required property int index

        Layout.fillWidth: true
        spacing: 2

        Title {
          Layout.fillWidth: true
          level: 4
          // The API's own channel names, formatted for a human: "FrontLeft"
          // reads as "Front Left" and the four LFE spellings all read as "LFE".
          // A channel this build does not describe is numbered rather than
          // named wrong.
          text: Model.channelLabel(channelRow.modelData) !== ""
            ? Model.channelLabel(channelRow.modelData) : "Channel " + (channelRow.index + 1)
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

    // What the list is, named on the row rather than only implied by the caret:
    // a disclosure holding rows of streams with no heading is a list nobody can
    // work out what it is a list OF, which is the whole question the disclosure
    // raises. One line rather than a tooltip, because the answer has to be
    // there when the list is not empty as well.
    Title {
      level: 5
      width: col.width
      x: Ui.m
      font.bold: true
      visible: row.expanded
      text: row.linkedCaption
    }

    // The streams this device is carrying. Gated on `expanded`, not merely
    // hidden: an unfolded-but-invisible list would keep a StreamRow - and
    // therefore a peak monitor - alive for every device on the graph.
    Repeater {
      model: row.expanded ? row.attached : []

      delegate: StreamRow {
        required property var modelData

        x: Ui.m
        width: col.width - Ui.m
        node: modelData
        // Nested: the device this stream plays through IS the row above it, so
        // the picker that row already offers is not repeated here.
        nested: true
      }
    }

    Title {
      level: 5
      width: col.width
      x: Ui.m
      visible: row.expanded && row.attached.length === 0
      text: row.linkedEmpty
    }
  }

  // What the profile chip says: the mode the card is in, or - when there is no
  // list to choose from - the reason there is none. The disable profile is
  // spelled out in the list rather than here - the daemon's own word for it is
  // the single word "Off", which does not tell a user they are about to take the
  // device out of the graph, so the parser expands it and the row prints that.
  //
  // The blocked half names the reason rather than the conclusion: "no
  // profiles" is the conclusion two unrelated causes have in common - a device
  // with no card behind it and a card list that has not been read - so the chip
  // says which of the two a user is looking at - see `profileBlockedLabel`.
  readonly property string profileChipText: !row.profilesReadable
    ? row.profileBlockedLabel
    : (row.currentProfile >= 0 ? row.profileText(row.profileList[row.currentProfile])
      : String(row.profiles.current === undefined ? "" : row.profiles.current))
}