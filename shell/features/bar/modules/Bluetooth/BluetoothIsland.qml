pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import Quickshell.Bluetooth
import qs.common
import "Model.js" as Model

// The bluetooth island: a header with the adapter status + on/off toggle,
// then the device list - remembered (paired) devices first, then whatever
// discovery turned up, both by name. Scanning is never automatic: it only
// runs when the user presses the Refresh button on the "AVAILABLE DEVICES"
// header (or in the empty state), and stops on its own after a bounded
// window. While a scan runs the button is faded and inert.
// Paired rows unfold the shared DropdownSlot - Connect/Disconnect plus a
// red Forget button; unpaired rows pair on click. The list is a
// primitives snapshot (Model.deviceRow) refreshed on a light poll, with
// the scroll position carried across refreshes so new devices never yank
// the view back to the top.
//
// Per-section scrolling: PAIRED and AVAILABLE each own a List + ScrollBar
// bounded to that section, not a single bar for the whole island.
Item {
  id: root

  property int islandContentWidth: 380
  // The card's padded body holds the content: add the outer padding to the
  // content's implicit height so nothing clips. Read off the live body
  // while the host shows this island; the host freezes the last live
  // footprint for the closed window.
  property int islandContentHeight: Math.ceil(body.implicitHeight) + 2 * Ui.outerPad
  // Paired rows unfold DropdownSlots, whose heights are already eased; the
  // host steps its window-height Behavior aside so the window tracks them
  // frame by frame (one easing only).
  property bool islandSelfAnimating: true
  property var islandHost: null

  // Horizontal inset for each device row's content, mirroring the menu
  // entry insets so rows read like menu entries.
  readonly property real rowPad: 6

  // Right gutter for the overlaid scrollbar: the bar (3px + 1px
  // margin) draws inside the viewport edge (ArchUpdates/Battery
  // pattern) and rows already end at rowPad, so nothing runs under it.

  // --- bluetooth state ---
  readonly property var adapter: Bluetooth.defaultAdapter
  readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []

  readonly property string connectedDeviceName: {
    for (const d of root.devices) {
      if (d.connected) return String(d.deviceName || d.name || "")
    }
    return ""
  }
  readonly property string headerSubtext: {
    if (!root.adapter) return "No adapter"
    if (!root.adapter.enabled) return "Turned off"
    return root.connectedDeviceName !== "" ? root.connectedDeviceName : "Not connected"
  }

  // --- device list state ---
  property var pairedRows: []
  property var availableRows: []
  property string actionAddress: ""
  property string actionKind: "" // "connect" | "pair" | "disconnect" | "forget"
  // The row whose action dropdown is open (a connected or paired row).
  property string dropdownAddress: ""

  readonly property bool busy: root.actionKind !== ""

  // A scan is running. Only a manual Refresh starts one - never the island
  // opening, never a poll tick.
  readonly property bool refreshing: root.adapter ? root.adapter.discovering : false

  // AVAILABLE DEVICES rows: a four-row window, ArchUpdates-style. Live
  // rows fill from the top and static skeleton rows pad the rest, so
  // discoveries land on laid-out rows instead of growing the section and
  // the window holds still while devices arrive. The skeletons pulse only
  // with an empty list and a scan in flight (see _availableScanning);
  // beside real rows they are fully static, like the network island's.
  readonly property int _availableWindow: 4
  readonly property var _availableFiller: root._fillerRows()
  function _fillerRows() {
    const out = []
    const n = Math.max(0, root._availableWindow - root.availableRows.length)
    for (let i = 0; i < n; i++) out.push({})
    return out
  }

  // The live BlueZ device behind a row. Rows carry primitives only, so
  // actions resolve the backend object here rather than holding a wrapper
  // that can dangle mid-incubation.
  function deviceForAddress(address) {
    if (!address) return null
    for (const d of root.devices) {
      if (d.address === address) return d
    }
    return null
  }

  // Do the live devices still carry exactly the fields the two row lists
  // already hold? This is the poll's decision, and it runs before the
  // snapshot rather than after it: an unchanged device set is the common
  // case, and the fields a row holds are the fields this compares, so the
  // comparison alone settles the tick - a Model.deviceRow snapshot per
  // device, a full re-sort and a re-partition do not happen only to be
  // dropped.
  //
  // Sound without sorting, which is what makes it cheap. Both lists are a
  // pure function of the compared fields - the sort order (connected, then
  // known, then the device label), the paired/available split (known) and
  // the snapshot itself - so an identical multiset of those fields under
  // the same addresses produces an identical sorted sequence, and both
  // per-list deviceRowsEqual comparisons then hold. Matching row.name and
  // row.address pins the label too: deviceLabel falls back from the name to
  // the address on the same condition on both sides.
  //
  // The enumeration position is compared too, and that is the one thing the
  // fields do not carry. Two devices can tie on every sort key (same
  // connected, same known, same label) and sortDeviceRows is a stable sort,
  // so their order in the lists is BlueZ's enumeration order rather than
  // anything the fields decide. Requiring the held rows to run in the same
  // increasing order pins that without a sort: a BlueZ reshuffle with no
  // field changed reads as a change and takes the rebuild, which is what
  // the unconditional sync already did.
  //
  // The live set is keyed by address and holds device references and
  // positions, not snapshots: this reads.
  //
  // Devices with no address are skipped exactly as the snapshot loop below
  // skips them, so the counts line up. Held here rather than in Model.js
  // because it is the island's own poll, and Model.deviceRowsEqual - the
  // predicate it stands in for - is not on that library's surface either.
  function deviceSetUnchanged(devices) {
    const live = {}
    let count = 0
    for (let i = 0; i < devices.length; i++) {
      const d = devices[i]
      if (!d) continue
      const address = String(d.address || "")
      if (address === "") continue
      live[address] = { device: d, order: i }
      count++
    }
    const held = root.pairedRows.concat(root.availableRows)
    if (held.length !== count) return false
    // Strictly increasing, so the held order is the live enumeration order
    // and two fully tied rows cannot have swapped places behind the fields.
    let lastOrder = -1
    for (const kept of held) {
      const row = kept || {}
      const entry = live[String(row.address || "")]
      if (entry === undefined) return false
      if (entry.order <= lastOrder) return false
      lastOrder = entry.order
      const dev = entry.device
      if (String(dev.deviceName || dev.name || "") !== String(row.name || "")) return false
      if (String(dev.icon || "") !== String(row.icon || "")) return false
      if (!!dev.connected !== !!row.connected) return false
      if (Model.isKnown(dev) !== !!row.known) return false
      if (!!dev.pairing !== !!row.pairing) return false
      if (!!dev.trusted !== !!row.trusted) return false
      if (!!dev.batteryAvailable !== !!row.batteryAvailable) return false
      if ((Number(dev.battery) || 0) !== (Number(row.battery) || 0)) return false
    }
    return true
  }

  function syncDevices() {
    const cur = root.adapter && root.adapter.enabled ? root.devices : []
    if (root.deviceSetUnchanged(cur)) {
      root.checkActionCompletion()
      return
    }
    const rows = []
    // While the adapter is off nothing is shown (paired or otherwise) - the
    // list is gone and the empty state explains why.
    for (const d of cur) {
      const r = Model.deviceRow(d)
      if (r && r.address !== "") rows.push(r)
    }
    const sorted = Model.sortDeviceRows(rows)
    const paired = []
    const avail = []
    for (let i = 0; i < sorted.length; i++) {
      const r = sorted[i]
      if (r.known) paired.push(r)
      else avail.push(r)
    }
    // The assignment stays conditional even though the gate has already
    // decided something moved: a fresh array resets the List's model and
    // recreates every delegate, and the scroll pursuit and settle restore
    // then fight over contentY mid-dropdown. One list can hold the change
    // on its own (a device pairs, or a known one goes unknown), and the
    // other must keep its identity.
    if (!Model.deviceRowsEqual(root.pairedRows, paired)) root.pairedRows = paired
    if (!Model.deviceRowsEqual(root.availableRows, avail)) root.availableRows = avail
    root.checkActionCompletion()
  }

  // --- actions ---

  function beginAction(kind, address) {
    root.actionAddress = address
    root.actionKind = kind
  }

  function runAction(kind, row, fn) {
    const dev = root.deviceForAddress(row.address)
    if (!dev) return
    root.beginAction(kind, row.address)
    fn(dev)
  }

  // Clicking a row: connected/paired rows toggle their action dropdown
  // (re-clicking closes it); unpaired rows pair straight away.
  function connectRow(row) {
    if (root.busy) return
    if (row.connected || row.known) {
      if (root.dropdownAddress === row.address) {
        root.closeDropdowns()
        return
      }
      root.closeDropdowns()
      root.dropdownAddress = row.address
      return
    }
    root.runAction("pair", row, d => d.pair())
  }

  function connectDevice(row) {
    root.closeDropdowns()
    root.runAction("connect", row, d => d.connect())
  }

  function disconnectRow(row) {
    root.closeDropdowns()
    root.runAction("disconnect", row, d => d.disconnect())
  }

  function forgetRow(row) {
    root.closeDropdowns()
    const dev = root.deviceForAddress(row.address)
    if (dev) dev.forget()
    // Forget drops the device out of BlueZ's list entirely, so no tracked
    // terminal state reliably arrives. Clear the busy latch immediately
    // rather than block the island - the row updates on the next sync.
    root.clearAction()
  }

  // Close whichever dropdown is open (called before opening another).
  function closeDropdowns() {
    root.dropdownAddress = ""
  }

  // Reset the whole in-flight action so no path forgets a field.
  function clearAction() {
    actionTimeout.stop()
    root.actionAddress = ""
    root.actionKind = ""
    root.closeDropdowns()
  }

  // A mid-flight action completes once the device reaches the target state:
  // connect->connected, pair->paired, disconnect->disconnected. Poll ticks
  // call this after syncing. A vanished device is also terminal (forget and
  // churn can drop it from the list entirely), which would otherwise leave
  // `busy` latched until the island reopens.
  function checkActionCompletion() {
    if (root.actionKind === "" || root.actionAddress === "") return
    const dev = root.deviceForAddress(root.actionAddress)
    if (!dev) {
      root.clearAction()
      return
    }
    let done = false
    if (root.actionKind === "connect") done = dev.connected
    else if (root.actionKind === "pair") done = dev.paired || dev.bonded
    else if (root.actionKind === "disconnect") done = !dev.connected
    if (done) root.clearAction()
  }

  // Named intervals (no bare numbers on any Timer): action timeout,
  // discovery delay/cap, device poll cadence.
  readonly property int actionTimeoutMs: 30000
  readonly property int refreshDelayMs: 800
  readonly property int refreshCapMs: 15000
  readonly property int pollMs: 2000

  // BlueZ can take a while to accept a connect; the action must outlast it
  // so the timeout lands on the right row (and never latches `busy`).
  Timer {
    id: actionTimeout

    interval: root.actionTimeoutMs
    repeat: false
    onTriggered: {
      root.clearAction()
    }
  }
  onActionKindChanged: {
    if (root.actionKind !== "") actionTimeout.restart()
    else actionTimeout.stop()
  }

  // --- manual refresh ---
  // Never automatic: opening the island or a poll tick never starts a scan.
  // The Refresh button restarts the inquiry (settling the old session down
  // first - BlueZ needs a beat before re-accepting one) and caps it at a
  // bounded window so the radio is not left scanning.
  function refreshScan() {
    if (!root.adapter || !root.adapter.enabled || root.refreshing) return
    root.adapter.discovering = false
    refreshDelay.restart()
    refreshCap.start()
  }

  Timer {
    id: refreshDelay

    interval: root.refreshDelayMs
    repeat: false
    onTriggered: {
      if (root.adapter && root.adapter.enabled) root.adapter.discovering = true
    }
  }
  // The quickshell discovery session does not end on its own, so the scan
  // is bounded here - after this the Refresh button becomes active again.
  Timer {
    id: refreshCap

    interval: root.refreshCapMs
    repeat: false
    onTriggered: {
      if (root.adapter) root.adapter.discovering = false
    }
  }

  // True for as long as a scan is actually in flight: the settle beat
  // (refreshDelay) plus the discovery window itself. Declared below the
  // timers and reading the id bare (ids resolve lexically, never as
  // members of root).
  readonly property bool _availableScanning:
    (root.refreshing || refreshDelay.running) && root.availableRows.length === 0

  // Stop any scan the moment the content is torn down. The host
  // destroys the content after the close fade, so teardown is close.
  Component.onDestruction: {
    if (root.adapter && root.adapter.enabled) root.adapter.discovering = false
    refreshDelay.stop()
    refreshCap.stop()
  }

  // Sync on every show: the content is incubated fresh, so creation
  // is open.
  Component.onCompleted: Qt.callLater(root.syncDevices)

  // Keep the list fresh (state changes, freshly discovered devices) and
  // settle in-flight actions. Never starts a scan. The content only
  // exists while the host shows it, so an always-on poll is open-gated
  // by lifetime.
  Timer {
    id: poll

    interval: root.pollMs
    repeat: true
    running: true
    onTriggered: root.syncDevices()
  }

  // --- content lent to the shared host ---
  // Incubated on show, destroyed after the close fade. The card sizes
  // from body.implicitHeight through islandContentHeight above.

  Column {
    id: body

    width: parent.width
    spacing: Ui.m

    // Header: "Bluetooth" with the adapter state as subtext, and the
    // shared qs.common Toggle bound to the adapter's power state on its right
    // border - same composition as the network island's header.
    // Uses lib Title levels 1 (island) + 4 (subtitle) instead of
    // hardcoded Text blocks.
    Row {
      width: parent.width
      spacing: Ui.m

      Column {
        width: parent.width - btToggle.implicitWidth - parent.spacing
        spacing: 2

        Title {
          level: 1
          width: parent.width
          text: "Bluetooth"
          elide: Text.ElideRight
        }

        Title {
          level: 4
          width: parent.width
          text: root.headerSubtext
          elide: Text.ElideRight
        }
      }

      Toggle {
        id: btToggle

        anchors.verticalCenter: parent.verticalCenter
        checked: root.adapter ? root.adapter.enabled : false
        // No adapter: the shared Toggle renders faded and inert on its own.
        dimmed: !root.adapter
        onToggled: state => {
          if (!root.adapter) return
          root.adapter.enabled = state
        }
      }
    }

    // Empty state when no adapter or adapter off -> outside the per-section
    // lists so it does not share their scrollbars.
    Title {
      id: emptyText
      level: 5
      visible: !root.adapter || !root.adapter.enabled
      width: parent.width
      text: !root.adapter ? "No bluetooth adapter" : "Turn on Bluetooth to scan"
      wrapMode: Text.WordWrap
    }

    // PAIRED DEVICES: per-section List + ScrollBar, always visible when the
    // adapter is enabled.
    Item {
      id: pairedSection
      visible: root.adapter && root.adapter.enabled
      width: parent.width
      height: pairedColumn.implicitHeight

      Column {
        id: pairedColumn
        width: parent.width
        spacing: 0

        // Section header -> lib Title level 2 (caps, muted) instead of
        // hardcoded Text with manual font/letterSpacing. Title row
        // mirrors the network island's section headers: small
        // foreground_1 glyph at 70% before the caps title.
        Item {
          width: parent.width
          height: 26
          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Ui.s

            Icon {
              anchors.verticalCenter: parent.verticalCenter
              name: "bluetooth-connected"
              colorKey: "foreground_1"
              size: 14
              opacity: 0.7
            }

            Title {
              level: 2
              anchors.verticalCenter: parent.verticalCenter
              text: "PAIRED DEVICES"
            }
          }
        }

        Title {
          id: pairedHint
          level: 5
          visible: root.pairedRows.length === 0
          width: parent.width
          text: "No paired devices"
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          topPadding: Ui.s
          bottomPadding: Ui.s
        }

        Item {
          visible: root.pairedRows.length > 0
          width: parent.width
          height: pairedList.height

          List {
            id: pairedList
            // No keyboard cursor here: the shared highlight bar would
            // sit on row 0 forever. Dropdown-open rows tint themselves
            // in the delegate.
            selectionHighlight: false
            // Dropdown rows reveal through the shared contract (see
            // deviceDelegate): the claim is the row index, the pursuit
            // holds it as the slot grows and eases on every height step.
            pursuitAnimated: true
            width: parent.width
            height: Math.min(pairedList.contentHeight, 152)
            stableModel: root.pairedRows
            spacing: 0
            interactive: pairedList.contentHeight > pairedList.height
            delegate: deviceDelegate
          }

          // Overlaid inside the viewport edge (ArchUpdates/Battery
          // pattern): rows already end at rowPad.
          ScrollBar {
            id: pairedBar
            flickable: pairedList
            anchors.right: parent.right
            anchors.rightMargin: 1
            anchors.top: pairedList.top
            anchors.topMargin: 8
            anchors.bottom: pairedList.bottom
            anchors.bottomMargin: 8
            thickness: 3
            radius: RoundingPolicy.radius
          }
        }
      }
    }

    // AVAILABLE DEVICES: per-section List + ScrollBar + lib Button.
    Item {
      id: availableSection
      visible: root.adapter && root.adapter.enabled
      width: parent.width
      height: availableColumn.implicitHeight

      Column {
        id: availableColumn
        width: parent.width
        spacing: 0

        // Section header with lib Button (background, border, press) for
        // the chrome, in the same outline style as the other island
        // actions.
        Item {
          width: parent.width
          height: 26
          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Ui.s

            Icon {
              anchors.verticalCenter: parent.verticalCenter
              name: "bluetooth-searching"
              colorKey: "foreground_1"
              size: 14
              opacity: 0.7
            }

            Title {
              level: 2
              anchors.verticalCenter: parent.verticalCenter
              text: "AVAILABLE DEVICES"
            }
          }
          Button {
            id: refreshBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            variant: "outline"
            label: root.refreshing ? "Refreshing" : "Refresh"
            // Button is 28px tall (Ui.buttonHeight); header is 26px.
            // Shrink to fit so it sits centered without clipping.
            height: 22
            implicitHeight: 22
            enabled: !root.refreshing
            onClicked: root.refreshScan()
          }
        }

        Item {
          visible: root.availableRows.length > 0
          width: parent.width
          height: availableList.height

          List {
            id: availableList
            // Same as pairedList above: no cursor, delegate-owned tint.
            selectionHighlight: false
            pursuitAnimated: true
            width: parent.width
            height: Math.min(availableList.contentHeight, 152)
            stableModel: root.availableRows
            spacing: 0
            interactive: availableList.contentHeight > availableList.height
            delegate: deviceDelegate
          }

          // Overlaid inside the viewport edge (ArchUpdates/Battery
          // pattern): rows already end at rowPad.
          ScrollBar {
            id: availableBar
            flickable: availableList
            anchors.right: parent.right
            anchors.rightMargin: 1
            anchors.top: availableList.top
            anchors.topMargin: 8
            anchors.bottom: availableList.bottom
            anchors.bottomMargin: 8
            thickness: 3
            radius: RoundingPolicy.radius
          }
        }

        // Filler skeleton rows under the live ones, up to the four-row
        // window: static whenever real rows are on screen, pulsing with
        // an empty list and a scan in flight (see _availableScanning).
        Item {
          visible: root.availableRows.length < root._availableWindow
          width: parent.width
          height: fillerList.height

          List {
            id: fillerList

            selectionHighlight: false
            width: parent.width
            height: fillerList.contentHeight
            stableModel: root._availableFiller
            spacing: 0
            interactive: false
            delegate: availableSkeletonDelegate
            clip: true
          }
        }
      }
    }
  }

  // AVAILABLE DEVICES empty-state row: 28px icon slot, title bar and
  // subtext bar matching the device row's column layout. Bars pulse on
  // the shared stagger only while a scan is in flight
  // (root._availableScanning) and only while MotionPolicy grants motion:
  // with the scan idle, or with animations off, running: false freezes
  // every animation at the resting opacity.
  Component {
    id: availableSkeletonDelegate

    Item {
      id: skeletonRow

      required property int index
      width: ListView.view ? ListView.view.width : 240
      height: 38

      Row {
        anchors.fill: parent
        anchors.leftMargin: root.rowPad
        anchors.rightMargin: root.rowPad
        spacing: Ui.m

        Rectangle {
          width: 28
          height: 28
          radius: RoundingPolicy.radius
          anchors.verticalCenter: parent.verticalCenter
          color: Ui.tint("foreground_1", 0.13)
          opacity: 0.55

          SequentialAnimation on opacity {
            loops: Animation.Infinite
            running: root._availableScanning && MotionPolicy.enabled
            SkeletonPulse { index: skeletonRow.index }
          }
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - 28 - Ui.m
          spacing: 4

          Rectangle {
            width: parent.width * (0.52 + ((Number(skeletonRow.index) || 0) % 2) * 0.2)
            height: 8
            radius: RoundingPolicy.radius
            color: Ui.tint("foreground_1", 0.14)
            opacity: 0.55

            SequentialAnimation on opacity {
              loops: Animation.Infinite
              running: root._availableScanning && MotionPolicy.enabled
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
              running: root._availableScanning && MotionPolicy.enabled
              SkeletonPulse { index: skeletonRow.index; offset: 150 }
            }
          }
        }
      }
    }
  }

  // Shared device row delegate -> used by both per-section Lists. The
  // DropdownSlot's body is a Column parented into the slot (so the buttons
  // inside it take the slot's spacing) and the selected tint covers the
  // whole chrome, dropdown included, like the network island and the
  // Settings menus.
  Component {
    id: deviceDelegate

    Item {
      id: row
      required property var modelData
      required property int index
      width: ListView.view ? ListView.view.width : 240
      // ListView.view is pairedList or availableList depending on which
      // section instantiated this delegate.
      height: baseRow.height + discSlot.height + (row.isDropdownRow ? Ui.m : 0)

      readonly property var dev: row.modelData
      // The owning shared List (pairedList or availableList), reached
      // through the view attached property. Held as var so the reveal
      // contract is written against the library, not the builtin ListView.
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
        if (!row.isDropdownRow) {
          if (v.autoRevealIndex === row.index) v.autoRevealIndex = -1
          return
        }
        v.revealEnd(row.index)
      }
      onIsDropdownRowChanged: revealOpen()
      Component.onCompleted: Qt.callLater(revealOpen)

      readonly property bool connected: row.dev ? !!row.dev.connected : false
      readonly property bool known: row.dev ? !!row.dev.known : false
      readonly property bool actionOn: row.dev ? (root.actionAddress === row.dev.address && root.actionKind !== "") : false
      readonly property bool spinning: row.actionOn && (root.actionKind === "connect" || root.actionKind === "pair")
      readonly property bool isDropdownRow: row.dev ? root.dropdownAddress === row.dev.address : false
      readonly property string name: row.dev ? Model.deviceLabel(row.dev) : ""
      // Icon for the device's class (keyboard/mouse/gamepad/speaker/monitor),
      // falling back to the generic bluetooth glyph when the class is unknown.
      readonly property string iconName: row.dev ? Model.deviceIconName(row.dev) : ""

      // Device chrome -> base row + dropdown. The Rectangle fills the
      // whole chrome (including open dropdown) for the selected
      // background_2 tint, like the network island and Settings menus.
      Rectangle {
        anchors.fill: parent
        color: row.isDropdownRow ? Ui.solid("background_2")
          : (hoverArea.containsMouse ? Ui.tint("foreground_1", 0.06) : "transparent")
        radius: RoundingPolicy.radius
      }

      Item {
        id: baseRow
        width: parent.width
        height: 38

        Item {
          id: iconWrap
          anchors.left: parent.left
          anchors.leftMargin: root.rowPad
          anchors.top: parent.top
          anchors.topMargin: (parent.height - height) / 2
          width: 16
          height: 16
          Icon {
            id: devIcon
            anchors.fill: parent
            name: row.iconName !== "" ? row.iconName : "bluetooth"
            colorKey: row.connected ? "accent" : "foreground_1"
            size: 16
            opacity: row.spinning ? 0 : 1
            Behavior on opacity {
              enabled: MotionPolicy.enabled
              NumberAnimation { duration: Ui.fastMs }
            }
          }
          Icon {
            id: connectSpinner
            anchors.centerIn: parent
            name: "update"
            colorKey: "foreground_1"
            size: 16
            opacity: row.spinning ? 0.9 : 0
            visible: opacity > 0.01
            transformOrigin: Item.Center
            Behavior on opacity {
              enabled: MotionPolicy.enabled
              NumberAnimation { duration: Ui.fastMs }
            }
            // The spinner is motion whether or not it is a Behavior, so
            // the gate is on `running` as well as the reveal tween: with
            // the policy off the glyph holds its static angle.
            RotationAnimation on rotation {
              from: 0
              to: 360
              duration: 1000
              loops: Animation.Infinite
              running: row.spinning && MotionPolicy.enabled
              onRunningChanged: if (!running) connectSpinner.rotation = 0
            }
          }
        }

        Column {
          anchors.left: iconWrap.right
          anchors.leftMargin: Ui.m
          anchors.right: statusText.left
          anchors.rightMargin: Ui.m
          anchors.verticalCenter: parent.verticalCenter
          spacing: 1

          Title {
            level: 3
            width: parent.width
            text: row.name
            color: row.connected ? Ui.solid("foreground_0") : Ui.solid("foreground_1")
            font.bold: row.connected
          }

          Title {
            level: 4
            width: parent.width
            text: Model.subtextFor(row.dev)
          }
        }

        // In-flight action feedback only ("Connecting..." etc.): the
        // connected state reads off the accent icon, so this collapses
        // to zero width otherwise and the text column goes full-bleed.
        Item {
          id: statusText
          anchors.right: parent.right
          anchors.rightMargin: root.rowPad
          anchors.verticalCenter: parent.verticalCenter
          width: (row.actionOn && !row.spinning) ? statusLabel.implicitWidth : 0
          height: statusLabel.implicitHeight

          Title {
            id: statusLabel
            level: 4
            visible: row.actionOn && !row.spinning
            anchors.verticalCenter: parent.verticalCenter
            text: root.actionKind === "connect" ? "Connecting..."
              : root.actionKind === "pair" ? "Pairing..."
              : root.actionKind === "forget" ? "Forgetting..." : "Disconnecting..."
            color: Ui.tint("foreground_1", 0.6)
            font.bold: true
          }
        }
      }

      DropdownSlot {
        id: discSlot

        anchors.top: baseRow.bottom
        topGap: Ui.m
        anchors.left: parent.left
        anchors.right: parent.right
        open: row.isDropdownRow

        // Deferred body: the two device buttons and the two info rows
        // belong to the one device whose dropdown is open, so the slot
        // builds them on open and releases them with the close fade
        // instead of every paired and discovered row carrying a control
        // set it never shows.
        nestedContent: Component {
          Column {
            x: Ui.m
            width: parent.width - 2 * Ui.m
            spacing: Ui.m

            Column {
              width: parent.width
              spacing: Ui.s

              Row {
                width: parent.width
                spacing: Ui.m

                Title {
                  level: 4
                  width: 110
                  text: "MAC address"
                  color: Ui.tint("foreground_1", 0.6)
                  elide: Text.ElideRight
                }

                Title {
                  level: 3
                  width: parent.width - 110 - parent.spacing
                  text: String(row.dev.address || "")
                  elide: Text.ElideRight
                }
              }

              Row {
                width: parent.width
                spacing: Ui.m

                Title {
                  level: 4
                  width: 110
                  text: "Trusted"
                  color: Ui.tint("foreground_1", 0.6)
                  elide: Text.ElideRight
                }

                Title {
                  level: 3
                  width: parent.width - 110 - parent.spacing
                  text: row.dev.trusted ? "Yes" : "No"
                  elide: Text.ElideRight
                }
              }
            }

            Row {
              width: parent.width
              spacing: Ui.s

              DropdownButton {
                width: forgetBtn.visible ? (parent.width - parent.spacing) / 2 : parent.width
                text: row.connected ? "Disconnect" : "Connect"
                accent: Ui.solid("accent")
                onClicked: row.connected ? root.disconnectRow(row.dev) : root.connectDevice(row.dev)
              }

              DropdownButton {
                id: forgetBtn
                width: (parent.width - parent.spacing) / 2
                text: "Forget"
                accent: Ui.solid("red")
                visible: row.known
                onClicked: root.forgetRow(row.dev)
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
        onClicked: root.connectRow(row.dev)
      }
    }
  }
}
