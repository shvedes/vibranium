pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import "MixerModel.js" as Model

// The mixer window: a regular toplevel.
//
// Every overlay this shell draws (Pass, Menu, ScreenshotPicker) is a
// `WlrLayershell` surface, and a layershell surface is not a window: Hyprland
// files it under `hyprctl layers` and never under `hyprctl clients`, so it has
// no title, no entry in the compositor's window list and nothing a taskbar or a
// window switcher can reach. wiremix and pavucontrol are both ordinary windows
// and this app is the user's replacement for both, so it is one too - which is
// why the window below is a QtQuick `Window`.
//
// Quickshell 0.3.1 has no window type of its own that is not layer-shell.
// `PanelWindow` maps a `wlr_layer_shell_v1` surface whether or not it carries a
// `WlrLayershell` block, which the type description cannot settle: measured with
// the mixer open, this surface was `Layer level 2 (top)`, 900x560, `namespace:
// quickshell`, and absent from `hyprctl clients`. `PopupWindow` is an xdg_popup
// and needs a parent toplevel it would have to be. A QtQuick `Window` is an
// xdg_toplevel, and an xdg_toplevel is what `hyprctl clients` lists.
//
// Five tabs rather than one column, in the order a user arrives with: APPS
// first, because that is what somebody opens a mixer for. Then the DEVICES they
// pick once and forget, the streams RECORDING (the capture half of the same
// kind of row as Apps, split out because a machine that is playing and a
// machine that is recording are two different questions), CONFIGURATION,
// which is the part wiremix and pavucontrol offer and this app could not do:
// card profiles, the disable profile, and per-channel levels; and GRAPH, which
// answers what the other four cannot - not "what is playing" but "what is
// playing through what" - and is the one place this app writes to the link
// topology. The Graph tab's body is a SIBLING of the body Flickable rather than
// a column inside it, because a canvas the user pans and zooms inside a
// Flickable is two scroll owners over one viewport.
//
// The window has no `title` of its own and no Reload and no Close button. The
// compositor names a real window, and it closes through the same `app close`
// path the bar and the settings menu already use - so the one verb is the
// facade's, and there is no button here that can disagree with it about whether
// the mixer is open. The routing map is refreshed on the open, after every
// move, and on a 5s timer that runs only while the window is up, so nothing is
// lost by dropping the button either.
//
// The window is a child of the controller and goes with it, so a closed mixer
// leaves no mapped surface behind.

// The root object is a holder, not the window. Qt builds a `Window` that is
// created inside a QQuickItem as a rendered surface inside that item, not a
// native platform window, so it never reaches the compositor's window list.
// `Loader` is a QQuickItem - `QQuickLoader` derives from
// `QQuickImplicitSizeItem` in QtQuick's own type description - and
// `AudioMixerController.qml` builds this file through
// `Loader { sourceComponent: Component { AudioMixerWindow { ... } } }`. Measured
// on this machine, a `Window` root loaded that way never mapped at all:
// `visible: true` left `visibility` at 0 and `hyprctl clients` stayed empty,
// while the same window held by a non-Item object mapped normally. Declaring
// the window as a property of a plain object is what puts a non-Item between it
// and the Loader, which is the whole job this root object does.
//
// The holder is also where the window's state lives, which is not a
// convenience. qmllint's unqualified-access rule flags every read of a member
// of an enclosing element that is not the component root, so each of the 91
// `win.x` reads this file makes is a warning from the shape alone and none of
// them are about the code. Moving the state up here and reading it as
// `mixer.x` - the root, which the rule exempts - makes the same structure lint
// clean without silencing anything. Every read below the holder is qualified,
// and the reason is written here rather than in a lint pragma.
//
// SPLIT MAP (one owner each, no behavior change): tabs + window chrome
// stay here and MixerSection (the lists this window draws: playback,
// devices, recording, configuration rows + dropdown + status line) owns
// its region below. The Graph tab body is a sibling of the body
// Flickable, not a column inside it.
QtObject {
  id: mixer

  // The controller that built this window. Required rather than defaulted: a
  // mixer window with no controller has no graph to read, and one that
  // silently rendered an empty shell would look like "no devices" instead of
  // "wired to nothing".
  required property var controller

  // --- tab state ---
  property string tab: "apps"
  // Device keys whose stream list is unfolded. A set rather than a single
  // key so folding one row does not have to fold every other one.
  property var expandedDevices: []

  // The tab set, in order, and the one place the order is written: Apps first
  // because it is what the window is opened for. Each tab carries the icon
  // its chip draws ahead of the label - the tab's empty-state glyph, so a tab
  // reads the same with rows and without. Recording is the one deliberate
  // exception: its empty state uses "recording", which is a video camera,
  // while the tab lists audio capture streams and gets the microphone.
  readonly property var tabs: [
    { key: "apps", label: "Apps", icon: "music" },
    { key: "devices", label: "Devices", icon: "speaker" },
    { key: "recording", label: "Recording", icon: "mic-on" },
    { key: "configuration", label: "Configuration", icon: "settings-general" },
    { key: "graph", label: "Graph", icon: "link" }
  ]

  // Left/Right walk the set rather than naming two tabs, so the arrow keys and
  // the chips cannot disagree about what the neighbours are. The keys are
  // projected off the same list the chips are drawn from, so the set has exactly
  // one definition.
  readonly property var tabKeys: mixer._tabKeys()

  function _tabKeys() {
    const keys = []
    for (let i = 0; i < mixer.tabs.length; i++) keys.push(mixer.tabs[i].key)
    return keys
  }

  function stepTab(delta) {
    const keys = mixer.tabKeys
    if (keys.length === 0) return
    let at = keys.indexOf(mixer.tab)
    if (at === -1) at = 0
    mixer.tab = keys[Math.max(0, Math.min(keys.length - 1, at + delta))]
  }

  // --- the output this window opens on ---
  //
  // `Window.screen` is a QtQuick Screen, while the shell's screen registry
  // publishes Quickshell's own screen objects, so the two cannot be assigned
  // across: binding `Ui.primaryScreen` straight into `screen` logs
  // "Unable to assign QuickshellScreenInfo to QQuickScreenInfo" and leaves the
  // window on whichever output Qt picked. `WindowScreen` is the name-matching
  // bridge between the two, shared with the image viewer, and returns null when
  // the names do not meet - which leaves the window on the primary output
  // rather than on none.
  readonly property var _targetScreen: WindowScreen.forScreen(Ui.primaryScreen)

  // --- geometry ---
  //
  // 900x560 is the size at which the four LIST tabs read at a glance: enough
  // width for a caret, a boost toggle, an icon, a two-line label, a meter, a
  // slider, the level affordances and a percentage on one device row, and enough
  // height for a device tab whose stream lists are unfolded. The Graph tab has
  // its own reason to want the room - a canvas is mostly empty and the pan is
  // what fills it - so it shares the size rather than asking for another.
  // Clamped to the screen with the spacing token as the margin, so a small panel
  // gets a smaller mixer rather than one that runs off it.
  readonly property int baseW: 900
  readonly property int baseH: 560
  // The floor is the width of the widest row, not a round number: a device row
  // is nine slots plus a label, and a minimum below that would clip controls
  // rather than shrink them.
  readonly property int minW: 640
  readonly property int minH: 240
  readonly property int margin: Ui.xl
  // The tab chip's height: `Chip`'s own implicit height - its label's line
  // plus the component's fixed 4px padding a side - taken as is. It used to
  // carry half a spacing unit less, which left 2px of padding around a bare
  // label; beside an icon that reads as a cramped strip rather than a tab.
  // Read from the component rather than written as a number so the chip
  // cannot go shorter than the text inside it when the font scale moves: a
  // hardcoded height is a height that clips its own label at some other
  // user's font size, and a tab row whose labels are cut in half is a tab bar
  // nobody can read.
  readonly property int chipNatH: tabBar.children.length > 0
    ? tabBar.children[0].implicitHeight : 0
  readonly property int chipH: chipNatH
  // The air the bar keeps above the chip row: one full spacing unit, so the
  // chips sit inside the bar rather than forming its top edge. The row is
  // ANCHORED at this margin rather than centred in the bar, and that is the
  // load-bearing half: a centred row drops by half of every pixel the bar
  // grows, so the room given to the separator below would be paid for out of
  // the air above the chips.
  readonly property int chipAir: Ui.s
  // The separator's own breathing room, one token either side of the hairline
  // - `sepAir` under the line and `sepAir` above it, the latter coming out of
  // the bar's height below. A margin on the line only exists where there is
  // space behind it, which is why the bar carries it: `+ 1` is the line itself.
  readonly property int sepAir: Ui.s / 2
  // The tab bar's own height, published because the body, the graph canvas and
  // the empty states all start below it and none of them may read the bar's
  // geometry. The chip, the air above it, and the separator with its own air on
  // both sides - the row follows the chip rather than a fixed height the chips
  // then have to be padded to fit, and the bar follows the separator.
  readonly property int tabBarH: mixer.chipAir + mixer.chipH + 2 * mixer.sepAir + 1

  // Whether the compositor has given this window the keyboard. A toplevel is
  // mapped unfocused and whether it gets the keyboard is not a client
  // decision: `requestActivate()` asks for it on the map and this is the
  // answer. Read through the holder because it is a window's property and the
  // handler that needs it belongs to the content item, two levels down.
  readonly property bool active: mixer.win !== null && mixer.win.active === true

  function requestClose() { AudioMixer.close() }

  // --- the lists this window draws ---
  //
  // Read as a projection over what the controller publishes, so a stream that
  // appears or a device that leaves is one re-evaluation rather than a model
  // edit at every call site. `recordingStreams` is the controller's alias of
  // the capture list and is used as such: two arrays for one set of rows would
  // be two things that can drift.
  readonly property var outputDevices: mixer.controller.outputDevices
  readonly property var inputDevices: mixer.controller.inputDevices
  readonly property var playbackStreams: mixer.controller.playbackStreams
  readonly property var recordingStreams: mixer.controller.recordingStreams
  // The Graph tab's two lists, handed over rather than reached for inside the
  // tab: the canvas gets the controller itself, and it reads these through it.
  readonly property var graphNodes: mixer.controller.graphNodes
  readonly property var graphLinks: mixer.controller.graphLinks

  // The device a stream currently plays through or records into, as a node, or
  // null when no device reports a link to it. A filter leg is linked to no
  // device and a stream the user has just moved has not settled yet; both are
  // null rather than a guessed device, which is what the row's chip prints as
  // "choose device".
  function deviceOf(node) {
    const key = mixer.controller.streamTargets[Model.nodeKey(node)]
    if (key === undefined) return null
    const devices = mixer.controller.allDevices
    for (let i = 0; i < devices.length; i++) {
      if (Model.nodeKey(devices[i]) === key) return devices[i]
    }
    return null
  }

  function toggleDevice(key) {
    const at = mixer.expandedDevices.indexOf(key)
    mixer.expandedDevices = at === -1
      ? mixer.expandedDevices.concat([key])
      : mixer.expandedDevices.filter(k => k !== key)
  }

  function isExpanded(key) { return mixer.expandedDevices.indexOf(key) !== -1 }

  // --- the one dropdown ---
  //
  // Which trigger's list is unfolded, "" for none, keyed per row. ONE string
  // on the holder rather than a flag on each row, for the reason the row
  // flags could not hold: a row-owned flag cannot see the other rows, so two
  // lists could be open at once, and a click on a third trigger had nothing to
  // say about either of them. Here, opening a trigger RETIRES the previous
  // one, so "which list is open" is a question with one answer.
  property string popKey: ""
  // The unfolded list, as { key, text, enabled, active, index, value } per
  // entry, built by the row that owns the trigger and rebuilt only when that
  // row's candidates change. It is a model built once per open, never a
  // projection of the last mouse position.
  property var popItems: []
  property Item popAnchorItem: null
  // The highlighted entry: the pointer's or the keyboard's. Hovering an entry
  // names it and a key walks it; the wheel is a scroll and writes nothing here,
  // so this integer only moves for a deliberate act on one entry.
  property int popIndex: -1

  // The one commit path. Both routes here - a click in the list, Enter, Space -
  // land on this signal, so a row's own write is written once and in one place.
  //
  // The trigger key and the entry travel as two arguments because they answer
  // two different questions: the key says WHICH row is being told to act, the
  // entry says what it picked. Carrying one field for both left every row
  // comparing the identity of a picked candidate against the key of the trigger
  // that offered it, which no candidate carries, so every commit was dropped.
  signal popCommit(string key, var entry)

  function isPopOpen(key) { return key !== "" && mixer.popKey === key }

  // --- the reason a control cannot act ---
  //
  // One tooltip for the window, on the same terms as the one dropdown: the
  // trigger and the sentence travel to the holder rather than being drawn by the
  // control, because the control that most needs to say something is the one
  // whose MouseArea is disabled and therefore cannot own a hover of its own.
  property var tipAnchor: null
  property string tipText: ""

  function showTip(item, text) {
    if (item === null || item === undefined || text === "") return
    mixer.tipAnchor = item
    mixer.tipText = text
  }

  // Only the served control may take the bubble down: a row losing its hover
  // must not empty a bubble another row is still pointing at.
  function hideTip(item) {
    if (mixer.tipAnchor !== item) return
    mixer.tipText = ""
    mixer.tipAnchor = null
  }

  // The unconditional clear, for the one path where the served control stops
  // existing without anything else saying so: a tab change. A bubble left
  // anchored to a destroyed item measures against nothing, which is a position
  // warning on every frame the window stays open.
  function clearTip() {
    mixer.tipText = ""
    mixer.tipAnchor = null
  }

  // Where this selector currently points, as an index into its own list, or -1
  // when nothing in it is the current value.
  function activeIndex(list) {
    if (list === null || list === undefined) return -1
    for (let i = 0; i < list.length; i++) {
      if (list[i].active === true) return i
    }
    return -1
  }

  // The entry `delta` steps onto, skipping the ones this selector refuses, or
  // -1 at either end. It stops at the end rather than wrapping: a scroll past
  // the last entry that jumps to the first is a different control's behaviour
  // and reads as a skip rather than a step. Bounded by the list length, so an
  // all-refused list costs one pass and stops.
  function stepIndex(list, at, delta) {
    if (list === null || list === undefined || list.length === 0) return -1
    let i = at
    for (let n = 0; n < list.length; n++) {
      i += delta
      if (i < 0 || i >= list.length) return -1
      if (list[i].enabled === true) return i
    }
    return -1
  }

  function openPop(key, entries, anchor) {
    if (key === "" || entries === null || entries === undefined) return
    mixer.popItems = entries
    mixer.popAnchorItem = anchor
    mixer.popIndex = mixer.activeIndex(entries)
    mixer.popKey = key
  }

  // The single place the dropdown state empties, so a tab change, a focus loss,
  // Escape, a commit and a window close all leave the same nothing behind.
  function closePop() {
    mixer.popKey = ""
    mixer.popItems = []
    mixer.popAnchorItem = null
    mixer.popIndex = -1
  }

  function togglePop(key, entries, anchor) {
    if (mixer.isPopOpen(key)) mixer.closePop()
    else mixer.openPop(key, entries, anchor)
  }

  // The one commit, and a commit always closes: an entry has been chosen, so the
  // list has said what it had to say. Whether a list stayed up was a question
  // only a scrolling walk had to answer - where its own selection was going to
  // be shown - and there is no walk left to answer it.
  function commitPop(key, entry) {
    if (entry === null || entry === undefined) return
    if (entry.enabled !== true) return
    mixer.closePop()
    mixer.popCommit(key, entry)
  }

  // One step of the walk over an OPEN list: the highlight moves and nothing
  // else, so an arrow stops here and Enter is the keyboard's commit.
  function stepOpen(delta) {
    const at = mixer.stepIndex(mixer.popItems, mixer.popIndex, delta)
    if (at < 0) return
    mixer.popIndex = at
  }

  // The pointer's highlight, written through the holder rather than assigned on
  // the popover's own copy of it. An assignment there breaks the binding that
  // carries `popIndex`, and a broken binding is invisible until it matters: after
  // one hover the keyboard would walk the highlight with nothing on screen
  // moving with it, and Enter would commit an entry nobody can see marked.
  function pointOpen(index) { mixer.popIndex = index }

  // The open list is fed from this holder, so a row that rebuilds its entries
  // hands them over while its list is up. Without that a commit landing with the
  // list still open - which is what Enter does, and what a click would if it did
  // not close - would leave the "you are here" mark on the entry just left.
  function refreshPop(key, entries) {
    if (key === "" || entries === null || entries === undefined) return
    if (!mixer.isPopOpen(key)) return
    mixer.popItems = entries
  }

  // Home and End: the same refusal-skipping walk, aimed at one end rather than
  // one step, so an end that is itself refused lands on the entry before it.
  function seatOpen(at) {
    const list = mixer.popItems
    if (list === null || list === undefined || list.length === 0) return
    const step = at < mixer.popIndex ? -1 : 1
    let i = mixer.popIndex
    for (let n = 0; n < list.length; n++) {
      i += step
      if (i < 0 || i >= list.length) return
      if (list[i].enabled === true) {
        mixer.popIndex = i
        return
      }
    }
  }

  // A tab change and a focus loss both retire the open list: the first because
  // the rows that owned it are about to be destroyed, the second because a
  // list nobody can reach is a list nobody can dismiss. The tooltip goes with
  // them on the tab change for the same first reason - its anchor is one of
  // those rows - and on the focus loss because a bubble anchored to a row the
  // pointer has left is a bubble nobody can dismiss.
  onTabChanged: {
    mixer.closePop()
    mixer.clearTip()
  }
  onActiveChanged: {
    if (!mixer.active) mixer.closePop()
  }

  // The keyboard handoff, both edges. The popover is the only thing on screen
  // that answers a key while it is open, so it takes the window's focus on the
  // open; the tab bar takes it back on the close, which is the same handoff the
  // window makes when the compositor grants it focus. `Qt.callLater` because
  // the focus move has to happen after the open's bindings have settled.
  //
  // The hand-back is gated on the window still being the active one: an unmapped
  // window has no keyboard to put focus into, and asking an item inside one
  // that is going away is a request against a tree that is already closing.
  onPopKeyChanged: {
    if (mixer.popKey !== "") {
      Qt.callLater(() => pop.forceActiveFocus())
      return
    }
    if (!mixer.active) return
    Qt.callLater(() => tabBar.forceActiveFocus())
  }

  // --- the one status line ---
  //
  // Two reads, one line: the routing map and the card map are both `pactl`
  // children, and a mixer that is up is running both. Each failure takes away
  // one kind of control - the stream pickers or the profile pickers - and
  // nothing else, so it is a hint on the bar rather than a dialog.
  //
  // A read that is RUNNING says nothing. "Reading profiles" is the shell
  // telling the user it is working, and a line that appears and vanishes in the
  // corner of a window is read as a fault - it flashes on every open, and every
  // refresh after a profile write, and a user watching for a real problem learns
  // to ignore the line that reports them. `configError` is cleared when the read
  // starts and set only when it fails, so silence for the duration of a read is
  // already what this file says; `configBusy` was the only thing printing over
  // it. The routing side reads its error field alone for the same reason, and
  // `routingBusy` has never been a line.
  readonly property string routingNote: {
    const err = String(mixer.controller.routingError || "")
    if (err === "") return ""
    return err === "timeout" ? "routing map timed out" : "routing map unavailable"
  }
  readonly property string configNote: {
    return String(mixer.controller.configError || "") === ""
      ? "" : "profile list unavailable"
  }
  readonly property string statusNote: mixer.routingNote !== ""
    ? mixer.routingNote : mixer.configNote

  // The empty state, per tab: a centred dim glyph over one line of generic
  // text. One component, four copies, because the copy is the only thing that
  // differs and four hand-written blocks would be four chances to forget one.
  component EmptyState: Item {
    id: empty

    property string iconName: "music"
    property string text: ""

    Column {
      width: empty.width - 2 * Ui.xl
      anchors.verticalCenter: parent.verticalCenter
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Ui.m

      Icon {
        anchors.horizontalCenter: parent.horizontalCenter
        name: empty.iconName
        colorKey: "foreground_1"
        // Dimmed rather than tinted: the glyph is the shell's own, so its
        // palette entry is the foreground and the emptiness is expressed with
        // opacity - the same idiom the disabled rows use.
        opacity: 0.22
        size: 32
      }

      Title {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        level: 5
        text: empty.text
        color: Ui.tint("foreground_1", 0.45)
      }
    }
  }

  // The one dropdown list, drawn as an item of THIS window rather than as a
  // surface of its own. See the layer it is declared in for why that matters.
  //
  // One instance, fed by the holder's `popKey`: a second trigger's open
  // replaces the key, so the first list is gone before the second is drawn and
  // there is no state in which two of them are open.
  component SelectorPopover: Rectangle {
    id: pop

    // The entry list, as { key, text, enabled, active, index, value }.
    required property var items

    // The layer this popover is drawn in, and the trigger it hangs off, both
    // handed in rather than read off `parent`: the anchor is a mapToItem into
    // the layer's coordinate space, and `parent` is the one identifier a
    // linted file may not read unqualified.
    property Item host: null
    property Item anchorItem: null
    property int highlight: -1

    signal activated(var entry)
    // Escape: the highlight is dropped and nothing is written.
    signal reverted()
    // An arrow moves the highlight and stops there.
    signal stepped(int delta)
    // Home/End aim the same walk at one end.
    signal seated(int at)
    // The wheel had nothing to scroll here, so it belongs to the page under the
    // window. The popover is not an ancestor of that Flickable - a wheel event
    // only ever walks up the parent chain, never sideways into a sibling - so
    // the gesture is handed on rather than left to propagate into nothing.
    signal paged(real notches)
    // The pointer names an entry, -1 when it has left the list. The holder
    // owns the highlight, so a hover and a key cannot end up on two entries.
    signal pointed(int index)

    // A dropdown row, slimmer than Ui.rowMinH (34) which is for full-width
    // list rows. The bar's device selector draws its options at this height.
    readonly property int rowH: 26
    // The frame's own padding, ONE token on all four sides: `Ui.s / 2`. It used
    // to be two - a `Ui.m` at the sides and half a unit top and bottom - and a
    // box whose sides carry three times the air of its top reads as lopsided
    // rather than as padded. One number is what stops that drifting back into
    // two, and this one is the value the top and bottom already had, so evening
    // the sides in costs the frame no height.
    readonly property int pad: Ui.s / 2
    readonly property int dotW: 10
    // The internal scrollbar's slot, reserved whether or not the list
    // overflows, so the popover does not change width when it starts
    // scrolling: a list that grows sideways under the pointer is a list whose
    // entries move as you read them. It is chrome and not padding: it sits on
    // top of `pad` on the right and keeps the frame's four insets equal.
    readonly property int gutter: 8
    // The border plus that one padding token, on every side. One derived number
    // for all four margins, so the frame's insets are four reads of the same
    // thing rather than four spellings of it.
    readonly property int inset: 1 + pop.pad
    // The window's breathing room, kept on every edge the list can reach. A
    // list clamped flush to the edge it was clamped against reads as part of the
    // window's frame rather than as something drawn over the window, and a
    // trigger near the right margin is the case that shows it. One token, so it
    // is the shell's spacing rather than a number this file invented.
    readonly property real edge: Ui.m
    // The widest a label may be here: the window less its own margin, this
    // popover's chrome and the scrollbar's reserved slot. It is what a very
    // long name elides against, and the window's own floor is 640 wide, so
    // reaching it takes a name longer than any this shell prints. The three
    // spacing units are the entry's own end margin and the two gaps inside it.
    readonly property real maxLabelW: {
      if (pop.host === null) return 0
      const room = pop.host.width - 2 * pop.edge - 2 * (pop.inset + pop.gutter)
        - pop.dotW - 3 * Ui.s
      return Math.max(60, room)
    }

    radius: RoundingPolicy.radius
    // One step off the window's own plate, not two. `background_2` put the list
    // two steps above `background_0`, which made an overlay that is meant to sit
    // ON the window read as a separate panel in front of it - bright enough that
    // the eye went to the list instead of the chip that opened it. `background_1`
    // is +15 per channel on this palette: enough to lift the list off the rows
    // beneath it, little enough that the list belongs to the window. The border
    // is what separates an overlay from its ground, and it is already here.
    color: Ui.solid("background_1")
    border.width: 1
    border.color: Ui.tint("accent", 0.45)
    // The list is the keyboard's while it is open: nothing else on screen
    // answers a key, so this is where the focus has to be for the arrows, the
    // commit and the revert to reach anything.
    focus: true

    // --- geometry ---
    //
    // Width follows the CONTENT, measured by the entry column rather than by a
    // second pass over the same strings: each entry states the width of its own
    // label and a positioner's implicit width is the widest of its children.
    // That is the whole of "sized to its content" - no fixed column, no text
    // measuring pass, and a long device name gets room instead of an ellipsis.
    //
    // `entryW` is that width PLUS one spacing unit at each end, which is the box
    // every entry is laid out in: the background spans the box rather than
    // hugging its own label, so the highlight under the pointer is the same
    // shape on every row instead of a ladder that follows the text.
    readonly property real entryW: listCol.implicitWidth
    readonly property real contentH: listCol.implicitHeight

    // The trigger's top-left in the layer's coordinates, and its height. Those
    // two ARE the anchor: the list hangs off the chip's bottom edge and slides
    // along the chip's left edge, so nothing here needs the chip's width - and
    // not reading it is what keeps a stale measurement out of the geometry.
    //
    // `mapToItem` is a method call rather than a property read, so a binding
    // over it tracks the anchor ITEM and not the anchor's geometry. That is
    // enough here and deliberately so: the body is frozen for as long as a list
    // is open, so the chip cannot move after the popover opens and there is
    // nothing for a binding to re-read. (The four-argument overload, which
    // also reads the anchor's width, picked up a width the layout had not
    // settled yet - which is why the width is not read at all.)
    readonly property point origin: pop.anchorItem === null || pop.host === null
      ? Qt.point(0, 0)
      : pop.anchorItem.mapToItem(pop.host, 0, 0)
    readonly property real anchorH: pop.anchorItem === null
      ? 0 : pop.anchorItem.height

    readonly property real gap: Ui.listTopGap
    // The room each SIDE can actually hold, gap included: not where the list's
    // edge would land but how much of the window is left to put it in. (The
    // first version of this used the edge coordinates, which made the cap and
    // the direction read off the same number in opposite senses - the cap
    // became larger the lower the chip sat, and `openDown` compared the room
    // under the trigger against a cap that was never larger than it, so the
    // flip branch was unreachable. Measured: a trigger at y=804 of an 864px
    // window reported 838 "of room below" with 26px actually below it.)
    readonly property real roomBelow: pop.host === null ? 0
      : Math.max(0, pop.host.height - pop.edge - (pop.origin.y + pop.anchorH + pop.gap))
    readonly property real roomAbove: Math.max(0, pop.origin.y - pop.edge - pop.gap)
    // The taller side is the cap, so the list is never taller than the space a
    // flip could reach and the popover can never grow past the window.
    readonly property real room: Math.max(pop.rowH, Math.max(pop.roomBelow, pop.roomAbove))
    readonly property real listH: Math.min(pop.contentH, pop.room)
    readonly property bool overflows: pop.contentH > pop.listH + 0.5

    // Downward when the room under the trigger holds the whole list, upward
    // when it does not and the room above it does - the browser's own rule,
    // and the one that keeps the list against the chip it belongs to.
    readonly property bool openDown: pop.roomBelow >= pop.listH || pop.roomBelow >= pop.roomAbove

    width: pop.entryW + 2 * pop.inset + pop.gutter + 2
    height: pop.listH + 2 * pop.inset
    // Slid along the trigger's left edge and stopped one spacing token short of
    // the window's right edge, so a list opened from a chip in the right margin
    // opens leftwards rather than hanging outside - and leaves a margin rather
    // than sitting flush against the frame it was clamped to.
    x: pop.host === null ? 0
      : Math.max(0, Math.min(pop.host.width - pop.edge - pop.width, pop.origin.x))
    // The same token on the bottom edge, which is the one an unflipped list runs
    // into on a full window; the top is already clear by the gap plus the edge,
    // because the list hangs from a chip that is always below the tab bar.
    y: pop.host === null ? 0
      : Math.max(0, Math.min(pop.host.height - pop.edge - pop.height, pop.openDown
        ? pop.origin.y + pop.anchorH + pop.gap
        : pop.origin.y - pop.gap - pop.height))

    Flickable {
      id: list

      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.leftMargin: pop.inset
      anchors.rightMargin: pop.inset + pop.gutter
      anchors.topMargin: pop.inset
      anchors.bottomMargin: pop.inset
      contentWidth: listCol.implicitWidth
      contentHeight: listCol.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      clip: true
      // The gesture is taken by the WheelHandler below, which is the only
      // place that knows whether this list has anything to scroll, so the
      // Flickable never takes one itself.
      interactive: false

      Column {
        id: listCol

        Repeater {
          model: pop.items

          // Every entry is drawn and clicked across the SAME width: the widest
          // entry's own content plus a spacing unit at each end. A background
          // sized to its own text is a list whose hover is a ragged ladder and
          // whose click target is as wide as the word under the pointer.
          //
          // The delegate states its own content as its width and the background
          // and the click target read `entryW`, the positioner's own implicit
          // width, which is the widest of those. The width is NOT bound back to
          // `entryW` - a child whose width is the positioner's implicit width is
          // a cycle, and the measured result of writing it was a list with no
          // width at all.
          delegate: Item {
            id: opt

            required property var modelData
            required property int index

            readonly property bool usable: opt.modelData.enabled === true
            readonly property bool marked: opt.index === pop.highlight

            // Own content: the dot, the gap, a spacing unit of margin at each
            // end, and the label capped by what the window can hold. The cap is
            // what a very long name elides against.
            width: pop.dotW + 3 * Ui.s + Math.min(optLabel.implicitWidth, pop.maxLabelW)
            height: pop.rowH
            opacity: opt.usable ? 1 : Ui.disabledOpacity

            Rectangle {
              id: optBg

              width: pop.entryW
              height: parent.height

              color: opt.marked ? Ui.tint("foreground_1", 0.08) : "transparent"

              // No Behavior on color here: the highlight is the pointer's own
              // position report, and a tween on it lags behind a moving cursor
              // so the entry under the pointer never looks fully marked until
              // the pointer stops. The highlight must track the hover exactly.
            }

            Row {
              id: optRow

              anchors.left: parent.left
              anchors.leftMargin: Ui.s
              anchors.verticalCenter: parent.verticalCenter
              spacing: Ui.s

              // The active entry is an accent dot and a bright label; the
              // highlighted entry is the row tint. Two facts and two marks, so
              // a hover can never be mistaken for a selection.
              Title {
                width: pop.dotW
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignLeft
                text: opt.modelData.active === true ? "\u2022" : ""
                color: Theme.color("accent")
              }

              Title {
                id: optLabel

                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, pop.maxLabelW)
                level: 3
                text: opt.modelData.text
                elide: Text.ElideRight
                color: opt.modelData.active === true
                  ? Ui.solid("foreground_0") : Ui.solid("foreground_1")
                font.bold: opt.modelData.active === true
              }
            }

            MouseArea {
              // The whole row band, not the label's own width. The Column
              // stacks these vertically, so one entry's band never overlaps its
              // neighbours' and the wider hit area cannot steal a click from the
              // row below it.
              width: pop.entryW
              height: parent.height
              enabled: opt.usable
              hoverEnabled: true
              cursorShape: opt.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
              // Hover only MOVES the highlight: nothing is written until the
              // pointer clicks it or Enter commits it. A selector that routed
              // on hover would fire a `pactl` move every time the pointer
              // crossed a row.
              onEntered: pop.pointed(opt.index)
              onClicked: pop.activated(opt.modelData)
            }

            Accessible.role: Accessible.MenuItem
            Accessible.name: opt.modelData.text
            Accessible.description: opt.usable ? "" : "this entry is unavailable"
          }
        }
      }
    }

    // Canonical placement: the bar belongs to the list and is drawn inside the
    // popover's own viewport edge, over the reserved gutter.
    ScrollBar {
      flickable: list

      anchors.right: parent.right
      anchors.rightMargin: 3
      anchors.top: parent.top
      anchors.topMargin: pop.inset
      anchors.bottom: parent.bottom
      anchors.bottomMargin: pop.inset
      thickness: 3
      // Not auto-hiding: the popover is a transient surface and a thumb that
      // fades while it is open has to be woken to tell the list scrolls.
      autoHide: false
    }

    // The wheel over the open list, and the one place its two cases are
    // decided. `notches` is the wheel delta measured in rows, positive for a
    // wheel-up, so a discrete wheel reports whole ones and a trackpad reports
    // fractions of one.
    //
    // A list with something to scroll takes the gesture itself. A list that
    // fits has nothing to scroll, and the gesture is then the page's: the
    // selection here is the pointer's and the keyboard's, and a wheel that
    // moved it would turn every scroll of a short list into a `pactl` move the
    // user did not ask for. Nothing here can close the list either - a scroll
    // that is not a choice is not a dismissal.
    //
    // A wheel-up carries a positive delta and scrolls the list up, which is a
    // contentY DECREASE, hence the subtraction: adding it here scrolled the
    // list down under a wheel-up, the touch-style "natural" direction.
    function wheelBy(notches) {
      if (pop.overflows) {
        const maxY = Math.max(0, list.contentHeight - list.height)
        list.contentY = Math.max(0, Math.min(maxY, list.contentY - notches * pop.rowH))
        return
      }
      pop.paged(notches)
    }

    // The wheel, taken here rather than by the Flickable because the gesture
    // has two owners and only the popover knows which one applies. `target`
    // defaults to the popover, which is not a Flickable, so the handler
    // delivers the gesture here and moves nothing by itself.
    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: function(event) {
        const d = event.angleDelta.y
        if (d === 0) return
        pop.wheelBy(d / 120)
      }
    }

    // Leaving the list drops the highlight. A highlight on an entry the
    // pointer is not over is a stale selection, and Enter would then commit an
    // entry the user cannot see marked.
    HoverHandler {
      onHoveredChanged: {
        if (!hovered) pop.pointed(-1)
      }
    }

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
        event.accepted = true
        pop.stepped(event.key === Qt.Key_Down ? 1 : -1)
        return
      }
      if (event.key === Qt.Key_Home || event.key === Qt.Key_End) {
        event.accepted = true
        pop.seated(event.key === Qt.Key_Home ? 0 : pop.items.length - 1)
        return
      }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
        || event.key === Qt.Key_Space) {
        event.accepted = true
        if (pop.highlight >= 0 && pop.highlight < pop.items.length) {
          pop.activated(pop.items[pop.highlight])
        }
        return
      }
      if (event.key === Qt.Key_Escape) {
        // Accepted here so the window's own Escape - which closes the mixer -
        // does not answer a key aimed at the list. The highlight is dropped
        // rather than committed: Escape on a combo box is a cancel, not a choice.
        event.accepted = true
        pop.reverted()
      }
    }

    // The list is the container assistive tech is told about, and the role is
    // `List` rather than `ListView` or `Menu`: `Accessible.ListView` is the QML
    // LIST ATTACHED PROPERTY and shadows the enum member, so naming it here is
    // an incompatible-type error rather than an announcement, and `Menu` is not
    // in the namespace this Qt's type description publishes at all. The
    // entries under it already carry MenuItem, which is what a reader walks.
    Accessible.role: Accessible.List
    Accessible.name: "Selection"
  }

  // The window, held rather than declared as this file's root object. See the
  // note above the root object for why the holder is not decoration.
  property Window win: Window {
    // A `Window` is unmapped until `visible` goes true, so this binding is the
    // whole of the map/unmap lifecycle: it shows the mixer when the facade
    // claims it and hides it when the facade releases the claim.
    visible: AudioMixer.visible
    screen: mixer._targetScreen
    // Not "transparent": this surface IS the window, so its own colour is the
    // ground the rows are drawn on, and a transparent toplevel is a hole with a
    // title bar over it. The window sets no `title`: a real toplevel is named
    // by the compositor, and an app that sets one is asking for a title bar it
    // cannot have.
    color: Ui.solid("background_0")

    // The output's own rectangle, in the desktop coordinates a compositor
    // reports positions in, so an output that does not start at the desktop
    // origin is measured against itself rather than against 0,0. Empty until
    // `screen` resolves, which is what the size fallbacks below are for. It
    // lives on the window rather than on the holder because it reads the
    // window's own `screen`, and the holder's copy of the output is the
    // Quickshell screen, not this one.
    //
    // Three tests and not one: a `Window` has no screen at all until the
    // platform hands it one, and the property reads `undefined` in that window
    // rather than `null`. Testing only for null let the first evaluation throw
    // on `screen.width`, which left `geo` itself undefined and took the width,
    // the height and the position bindings down with it.
    //
    // `virtualX`/`virtualY`, not `x`/`y`: a `QQuickScreenInfo` publishes the
    // output's desktop position under those two names and publishes no `x` or
    // `y` at all, so reading the short ones here measured every output against
    // the desktop origin whatever its real one was.
    readonly property rect geo: {
      const target = screen
      if (target === null || target === undefined || !(target.width > 0)) {
        return Qt.rect(0, 0, 0, 0)
      }
      return Qt.rect(target.virtualX, target.virtualY, target.width, target.height)
    }

    // width/height, not the implicit pair: a `Window` has no implicit content to
    // measure, so an `implicitWidth` here leaves the surface at Qt's own default
    // size and the clamp would size nothing. The screen's width/height are
    // logical pixels, the same unit as the base size.
    width: geo.width <= 0 ? mixer.baseW
      : Math.max(mixer.minW, Math.min(mixer.baseW, geo.width - 2 * mixer.margin))
    height: geo.height <= 0 ? mixer.baseH
      : Math.max(mixer.minH, Math.min(mixer.baseH, geo.height - 2 * mixer.margin))

    // Where the window asks to be: the centre of the output. Unlike the
    // layer-shell placement block, x/y are real settable properties on a
    // `Window`, so this is a stated position rather than a decoration. See the
    // placement note for why the compositor is free to answer with something
    // else.
    x: geo.width <= 0 ? 0 : geo.x + Math.round((geo.width - width) / 2)
    y: geo.height <= 0 ? 0 : geo.y + Math.round((geo.height - height) / 2)

    // Placement, and what the compositor owes it. A toplevel is not a layer
    // surface: it goes into a layout, so the size and the position bound above
    // are requests against a tiling policy rather than instructions. Measured on
    // this machine, a `Window` asking for 500x300 at (100, 80) mapped as a
    // 946x1036 tile at (966, 36), and `flags: Qt.Dialog` did not float it
    // either. A Wayland client cannot ask for a floating surface - the protocol
    // has no request for it - so whether this window floats is a Hyprland
    // windowrule on class `org.quickshell`, which is the compositor's decision
    // to make and not something this file can express. The clamp above is
    // therefore the floor of what the app controls.

    // Keyboard focus is the compositor's to give and this file's to use. A
    // toplevel is mapped unfocused and whether it gets the keyboard is not a
    // client decision: requestActivate() asks for it on the map, `active` is the
    // answer, and the focus handoff below runs off that answer rather than off
    // the surface appearing.
    onVisibleChanged: {
      if (!visible) return
      Qt.callLater(() => requestActivate())
    }
    onActiveChanged: {
      if (!mixer.active) return
      // Focus goes to the tab bar rather than staying on the root item: the tab
      // bar is the only thing on the window that does something with a key, and a
      // focused item nobody can see the focus in is a keyboard that appears dead.
      // Qt.callLater because the compositor grants keyboard focus a beat after the
      // map, and a forceActiveFocus before that is a request recorded against a
      // surface that does not hold focus yet.
      Qt.callLater(() => tabBar.forceActiveFocus())
    }
    // A toplevel is closeable from outside this file - a keybinding, a
    // windowrule, a switcher - and a layer-shell surface never was. Routing the
    // compositor's close back through the facade is what keeps
    // `AudioMixer.visible` from staying true over a window that is gone, and it
    // is the same close the Escape handler and the `app close` IPC verb perform.
    onClosing: function(close) { mixer.requestClose() }

    Item {
      id: root

      anchors.fill: parent
      // The window's content item is this Item, so `focus: true` makes it the
      // holder of the keyboard focus the compositor granted the window, and the
      // Keys handler below the one place that answers a key. The handoff of that
      // focus to the tab bar is on the window's `onActiveChanged`, because that
      // is where the compositor's answer arrives.
      focus: true

      Keys.onEscapePressed: function(event) {
        // Escape closes the window. It is on the root item and not on each
        // section, so there is one place that answers it; a row that owns a key
        // (the sliders own arrows, Home and End) consumes it first. Gated on the
        // window being active: a toplevel the compositor is holding unfocused is
        // one whose keys go somewhere else, and a close wired to a keypress aimed
        // elsewhere is not this window's to answer.
        if (!mixer.active) return
        event.accepted = true
        mixer.requestClose()
      }
    }

    // --- the tab bar ---
    Item {
      id: bar

      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: mixer.tabBarH

      Row {
        id: tabBar

        anchors.left: parent.left
        anchors.leftMargin: Ui.s
        anchors.top: parent.top
        anchors.topMargin: mixer.chipAir
        // Half a spacing unit between the chips, and the bar's own side
        // inset is one unit: the chips already carry Ui.s of padding
        // inside their own boxes, so a full outerPad outside them stacked
        // the two and left the first tab reading detached from the frame.
        // The body keeps its wider inset; pills belong to the frame and
        // may sit slightly outboard of the content titles.
        spacing: Ui.s / 2
        focus: true

        // Left/Right walk the tabs, so the whole window is reachable from the
        // bar alone: no tab control in this tree is a focus scope, which is why
        // the keys are owned one level up.
        Keys.onLeftPressed: function(event) {
          event.accepted = true
          mixer.stepTab(-1)
        }
        Keys.onRightPressed: function(event) {
          event.accepted = true
          mixer.stepTab(1)
        }

        Repeater {
          model: mixer.tabs

          delegate: Chip {
            id: tabChip

            required property var modelData

            text: tabChip.modelData.label
            iconName: tabChip.modelData.icon
            // The icon follows the label's own state color, so the glyph reads
            // as part of the tab rather than as a separate muted mark beside
            // an accent one.
            iconColorKey: tabChip.selected ? "accent" : "foreground_1"
            selected: mixer.tab === tabChip.modelData.key
            // The holder's chip height: `Chip`'s own implicit height, published
            // there because the bar's height is this number plus the margin
            // either side of it and the body starts below the bar - one
            // measurement, three readers.
            height: mixer.chipH
            // One step dimmer than the shell's own chip, in the dimming idiom
            // the rows and the tree use: a foreground tint rather than a second
            // background, so the active chip's accent fill is the only fill on
            // the bar and the inactive three read as the same surface. One
            // value, not a hover ramp - the whole point is that the bar is
            // quiet and the selected tab is the thing on it.
            color: tabChip.selected ? Ui.tint("accent", 0.12) : Ui.tint("foreground_1", 0.05)

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: mixer.tab = tabChip.modelData.key
            }
          }
        }
      }

      // The one status line, anchored from the right so it grows leftward into
      // the bar's slack and never moves the tabs.
      Title {
        id: statusNote

        anchors.right: parent.right
        anchors.rightMargin: Ui.s
        anchors.verticalCenter: parent.verticalCenter
        visible: mixer.statusNote !== ""
        text: mixer.statusNote
        color: Ui.solid("yellow")
        elide: Text.ElideRight
        width: Math.max(0, Math.min(implicitWidth, 240))
      }

      Divider {
        // The hairline between the bar and the body, held a token off the bar's
        // bottom so the space below the line belongs to the line: flush against
        // the frame, it welded the two into one edge and the row above it read
        // as a strip of the body rather than as a bar. The token above it comes
        // out of `tabBarH` instead, which is why the bar carries it.
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: mixer.sepAir
      }
    }

    // --- the tab body ---
    //
    // One Flickable rather than a ListView: a mixer is a bounded list (the
    // device set plus whatever the daemon is publishing), and a plain Column
    // takes variable-height rows - a device row whose stream list is unfolded,
    // a configuration row whose profile list is open - without a row-identity
    // problem. The cost is that every row is live, so every meter row holds a
    // peak handle; PipeWireState's peak bound is the documented answer to that,
    // and a row that cannot get one draws a dead track rather than the mixer
    // refusing to list it.
    // The Graph tab's body, and it is NOT this Flickable.
    //
    // The other four tabs are a bounded list, which is what that Flickable is
    // for. The Graph tab is a canvas the user pans and zooms, and a Flickable
    // nested inside one is two scroll owners over one viewport: Qt decides
    // which of them gets a drag, not this file. So the canvas is a sibling of
    // the body, and this Flickable is collapsed while it is up - collapsed
    // rather than detached, because its four tab columns are gated on their own
    // key and would contribute nothing anyway.
    Flickable {
      id: body

      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: mixer.tabBarH
      anchors.bottom: parent.bottom
      contentWidth: width
      contentHeight: columns.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      visible: mixer.tab !== "graph"
      // Frozen while a popover is open. Its anchor is a rect in the layer's
      // coordinates, and a body that scrolls under an open list moves that
      // rect: the list would hang where the chip used to be, which is the one
      // way an in-window popover reads as an escaping one. The scrollbar keeps
      // working - it writes contentY directly - so a user can still scroll the
      // body out from under a list they did not want.
      interactive: mixer.popKey === ""

      Column {
        id: columns

        x: Ui.outerPad
        y: Ui.m
        width: body.width - 2 * Ui.outerPad - 4
        spacing: Ui.s

        // --- Apps tab ---
        //
        // The tab is gated TWICE and both halves are load-bearing. `visible`
        // collapses the column so an inactive tab contributes no spacing, and the
        // MODELS are emptied so its delegates do not exist: every row holds a
        // peak handle and reads two volume properties, and a mixer that built
        // these four tabs' rows at once would hold four times the handles it draws
        // and read four times the graph. A Repeater over an empty model
        // instantiates nothing.
        Column {
          width: parent.width
          spacing: Ui.s / 2
          visible: mixer.tab === "apps"

          Title {
            level: 2
            text: "PLAYBACK"
          }

          Repeater {
            model: mixer.tab === "apps" ? mixer.playbackStreams : []

            delegate: StreamRow {
              required property var modelData

              // The key is spelled out at each use rather than hoisted into a
              // property on the delegate: a readonly property whose name the
              // base type already uses is a property-override warning, and the
              // expression is short enough not to need the name.
              width: columns.width
              node: modelData
              capture: false
              candidates: mixer.outputDevices
              target: mixer.deviceOf(modelData)
              pulse: mixer.controller.pulse
              controller: mixer.controller
              mixerWindow: mixer
              onRouteRequested: function(n, device, capture) {
                mixer.controller.routeStream(n, device, capture)
              }
            }
          }
        }

        // --- Devices tab ---
        //
        // Unchanged behaviour: two headed lists over the two device sets, each
        // row disclosing the streams the graph says are linked to it.
        Column {
          width: parent.width
          spacing: Ui.s / 2
          visible: mixer.tab === "devices"

          Title {
            level: 2
            text: "OUTPUT DEVICES"
          }

          Repeater {
            model: mixer.tab === "devices" ? mixer.outputDevices : []

            delegate: DeviceRow {
              required property var modelData

              width: columns.width
              node: modelData
              linkHandle: mixer.controller.deviceLinks[Model.nodeKey(modelData)]
              expanded: mixer.isExpanded(Model.nodeKey(modelData))
              controller: mixer.controller
              mixerWindow: mixer
              onToggleExpanded: mixer.toggleDevice(Model.nodeKey(modelData))
            }
          }

          Item {
            width: 1
            height: Ui.s
          }

          Title {
            level: 2
            text: "INPUT DEVICES"
          }

          Repeater {
            model: mixer.tab === "devices" ? mixer.inputDevices : []

            delegate: DeviceRow {
              required property var modelData

              width: columns.width
              node: modelData
              linkHandle: mixer.controller.deviceLinks[Model.nodeKey(modelData)]
              expanded: mixer.isExpanded(Model.nodeKey(modelData))
              controller: mixer.controller
              mixerWindow: mixer
              onToggleExpanded: mixer.toggleDevice(Model.nodeKey(modelData))
            }
          }
        }

        // --- Recording tab ---
        //
        // The capture half of the stream rows, and the tab that keeps the
        // shell's own peak taps out of the list: they are `Stream/Input/Audio`
        // nodes named after this process, and listing them gave each one a
        // peak handle, which created another tap. The controller's list
        // carries no such node, so this tab is what breaks that loop.
        Column {
          width: parent.width
          spacing: Ui.s / 2
          visible: mixer.tab === "recording"

          Title {
            level: 2
            text: "RECORDING"
          }

          Repeater {
            model: mixer.tab === "recording" ? mixer.recordingStreams : []

            delegate: StreamRow {
              required property var modelData

              width: columns.width
              node: modelData
              capture: true
              candidates: mixer.inputDevices
              target: mixer.deviceOf(modelData)
              pulse: mixer.controller.pulse
              controller: mixer.controller
              mixerWindow: mixer
              onRouteRequested: function(n, device, capture) {
                mixer.controller.routeStream(n, device, capture)
              }
            }
          }
        }

        // --- Configuration tab ---
        //
        // What wiremix and pavucontrol offer and this app could not do: the
        // card's profile - including index 0, the profile that DISABLES the
        // device - and the device's per-channel levels. Two headed lists over
        // the two device sets rather than one concatenated model, so no
        // projection can rebuild every row when one set changes.
        Column {
          width: parent.width
          spacing: Ui.s / 2
          visible: mixer.tab === "configuration"

          Title {
            level: 2
            text: "OUTPUT DEVICES"
          }

          Repeater {
            model: mixer.tab === "configuration" ? mixer.outputDevices : []

            delegate: DeviceRow {
              required property var modelData

              width: columns.width
              node: modelData
              linkHandle: mixer.controller.deviceLinks[Model.nodeKey(modelData)]
              expanded: mixer.isExpanded(Model.nodeKey(modelData))
              controller: mixer.controller
              mixerWindow: mixer
              configuration: true
              onToggleExpanded: mixer.toggleDevice(Model.nodeKey(modelData))
            }
          }

          Item {
            width: 1
            height: Ui.s
          }

          Title {
            level: 2
            text: "INPUT DEVICES"
          }

          Repeater {
            model: mixer.tab === "configuration" ? mixer.inputDevices : []

            delegate: DeviceRow {
              required property var modelData

              width: columns.width
              node: modelData
              linkHandle: mixer.controller.deviceLinks[Model.nodeKey(modelData)]
              expanded: mixer.isExpanded(Model.nodeKey(modelData))
              controller: mixer.controller
              mixerWindow: mixer
              configuration: true
              onToggleExpanded: mixer.toggleDevice(Model.nodeKey(modelData))
            }
          }
        }
      }

      // Canonical placement: inside the viewport edge, and the rows end at
      // Ui.outerPad + 4 so nothing runs underneath it.
      ScrollBar {
        flickable: body
        anchors.right: parent.right
        anchors.rightMargin: 1
        anchors.top: parent.top
        anchors.topMargin: Ui.s
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Ui.s
        thickness: 3
      }
    }

    // --- the Graph tab body ---
    //
    // A sibling of the body, not a column inside it: see the note on `body`.
    // The canvas pans and zooms itself and claims the wheel, so the shared
    // Flickable above is collapsed whenever this is the tab on screen.
    //
    // `active` rather than `visible` alone, because a collapsed canvas whose
    // Repeater still had a model would build every card, take every peak hold
    // and hold a selection for a tab nobody is looking at.
    GraphTab {
      id: graphBody

      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: mixer.tabBarH
      anchors.bottom: parent.bottom
      visible: mixer.tab === "graph"
      controller: mixer.controller
      active: mixer.tab === "graph"
    }

    // --- the empty states ---
    //
    // Outside the Flickable and over the body area, so a tab with no rows
    // centres its glyph in the window rather than at the top of a column. They
    // are laid out over the body but paint nothing and accept no input when the
    // tab has rows, so a click reaches the rows underneath.
    EmptyState {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: mixer.tabBarH + Ui.m
      anchors.bottom: parent.bottom
      visible: mixer.tab === "apps" && mixer.playbackStreams.length === 0
      iconName: "music"
      text: "Nothing is playing"
    }

    EmptyState {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: mixer.tabBarH + Ui.m
      anchors.bottom: parent.bottom
      visible: mixer.tab === "devices"
        && mixer.outputDevices.length === 0 && mixer.inputDevices.length === 0
      iconName: "speaker"
      text: "No audio devices on this graph"
    }

    EmptyState {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: mixer.tabBarH + Ui.m
      anchors.bottom: parent.bottom
      visible: mixer.tab === "recording" && mixer.recordingStreams.length === 0
      iconName: "recording"
      text: "Nothing is recording"
    }

    EmptyState {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: mixer.tabBarH + Ui.m
      anchors.bottom: parent.bottom
      visible: mixer.tab === "configuration"
        && mixer.outputDevices.length === 0 && mixer.inputDevices.length === 0
      iconName: "settings-general"
      text: "No devices to configure"
    }

    EmptyState {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: mixer.tabBarH + Ui.m
      anchors.bottom: parent.bottom
      visible: mixer.tab === "graph" && mixer.graphNodes.length === 0
      iconName: "link"
      text: "No audio nodes on this graph"
    }

    // --- the popover layer ---
    //
    // The LAST child of the window's content item, so a popover paints over
    // the rows instead of under them, and `clip: true`, so a popover that
    // reaches a window edge stops at it.
    //
    // That pair is the whole answer to a dropdown that paints over the bar.
    // A list that opened as a surface of its own - a `PopupWindow`, a
    // `WlrLayershell` block - is not clipped by this window, is not a child of
    // anything in it, and is placed by the compositor rather than bounded by
    // the rectangle it is supposed to belong to. So a long list drawn that way
    // can reach past the window and land on the shell's bar, and scrolling it
    // is exactly when that happens. Drawn here it is an item of this window:
    // the window's own edges bound it, and the bar is never involved.
    //
    // Not a raised window and not an exclusive zone either. The mixer stays an
    // ordinary toplevel, which is the whole reason it appears in
    // `hyprctl clients` at all.
    Item {
      id: popLayer

      anchors.fill: parent
      clip: true

      // Click-away, under the popover and over everything else, so a click that
      // is not on the list dismisses it rather than reaching the row beneath.
      // A popover whose only dismissal is its own trigger is a popover a user
      // has to hunt for. The area is enabled only while something is open, so
      // a closed mixer routes every click exactly as it did before.
      MouseArea {
        anchors.fill: parent
        enabled: mixer.popKey !== ""
        acceptedButtons: Qt.LeftButton
        onClicked: mixer.closePop()
      }

      // The reason a control could not act, anchored to that control.
      //
      // Drawn here for the same reason the list is: this layer is the window's
      // last child and it is clipped, so a bubble paints over the rows and stops
      // at the window's edge. It is a plain Rectangle, which takes no pointer
      // input at all, so a bubble under the cursor is still a click on whatever
      // is beneath it - a tooltip that swallowed the click would be the one
      // control on this window that takes a gesture and gives nothing back.
      Rectangle {
        id: tipBox

        visible: mixer.tipText !== "" && mixer.tipAnchor !== null
        color: Ui.solid("background_1")
        // Corners follow RoundingPolicy (hypr.decoration.rounding).
        radius: RoundingPolicy.radius
        border.width: 1
        border.color: Ui.tint("foreground_1", 0.4)
        // `mapToItem` is a method call, so this tracks the anchor ITEM and not
        // its geometry: the bubble follows the control that owns the reason, and
        // the row that goes away takes its bubble with it rather than leaving one
        // over the row that took its place.
        readonly property point origin: mixer.tipAnchor === null
          || mixer.tipAnchor === undefined
          ? Qt.point(0, 0)
          : mixer.tipAnchor.mapToItem(popLayer, 0, 0)
        readonly property real anchorH: mixer.tipAnchor === null
          || mixer.tipAnchor === undefined ? 0 : mixer.tipAnchor.height

        width: Math.min(tipLabel.implicitWidth + 2 * Ui.m,
          Math.max(0, popLayer.width - 2 * Ui.m))
        height: tipLabel.implicitHeight + 2 * Ui.s
        x: Math.max(Ui.m, Math.min(popLayer.width - Ui.m - width, origin.x))
        // Under the control when there is room for it, over it when there is not:
        // the chip a window's last row sits on has nothing below it, and a bubble
        // clamped to the bottom edge reads as a second row of the list rather
        // than as an aside to the control.
        y: origin.y + tipBox.anchorH + Ui.s / 2 + height > popLayer.height - Ui.m
          ? Math.max(Ui.m, origin.y - height - Ui.s / 2)
          : origin.y + tipBox.anchorH + Ui.s / 2

        Title {
          id: tipLabel

          anchors.centerIn: parent
          width: Math.min(implicitWidth, Math.max(0, tipBox.width - 2 * Ui.m))
          level: 5
          text: mixer.tipText
          color: Ui.solid("foreground_0")
        }
      }

      SelectorPopover {
        id: pop

        visible: mixer.popKey !== "" && mixer.popItems.length > 0
        items: mixer.popItems
        host: popLayer
        anchorItem: mixer.popAnchorItem
        highlight: mixer.popIndex
        // The key is the one that is open, which is the row being told to act:
        // the entry alone cannot name it, and a commit without one is dropped by
        // every row that checks for its own.
        onActivated: function(entry) { mixer.commitPop(mixer.popKey, entry) }
        onReverted: mixer.closePop()
        onStepped: function(delta) { mixer.stepOpen(delta) }
        onSeated: function(at) { mixer.seatOpen(at) }
        onPointed: function(index) { mixer.pointOpen(index) }
        // A wheel over a list that fits: the body is the page, and a scroll
        // belongs to whatever is under the pointer, so the gesture is applied to
        // it in the same rows the list scrolls itself by. The body stays
        // non-interactive - its scroll offset is what the open list's anchor is
        // measured against - so this is the one door a scroll comes through
        // while a list is up, and the scrollbar is the other.
        onPaged: function(notches) {
          const maxY = Math.max(0, body.contentHeight - body.height)
          body.contentY = Math.max(0, Math.min(maxY, body.contentY - notches * pop.rowH))
        }
      }
    }
  }
}