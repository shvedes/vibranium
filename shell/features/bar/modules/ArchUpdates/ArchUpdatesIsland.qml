pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import qs.common
import "Model.js" as Model

// Arch updates island: searchable package table for official and AUR
// updates with macOS-Finder-style checkboxes. Rows are selected with a
// click; "Update Official" / "Update AUR" then update exactly the checked
// packages of that type (all of them when nothing is checked).
//
// The table shows only the new version ("pkg new") with a Package/Version
// header; neither column ever elides - the card is fixed-size and wide
// rows scroll horizontally past it instead.
//
// NOTE: anchorItem / anchorWindow / barPosition live on the shared
// host, never here - a redeclaration shadows the host wiring and
// silently breaks positioning (the card then parks at the screen
// corner instead of under the module).
Item {
  id: root

  property var packages: []
  property string islandState: "idle"
  property string errorText: ""
  property bool updating: false
  // Loading skeleton: while a fetch or update runs the table chrome
  // (header, zebra rows) stays drawn but blank, with a spinner wash
  // over it so it reads as a placeholder, not a live table.
  readonly property bool skeleton: root.updating || root.islandState === "loading"
  // Up-to-date empty state: ready/idle with zero packages. Reuses the
  // blank table under a dim + info overlay (error pattern).
  readonly property bool upToDate: !root.skeleton && root.islandState !== "error" && root.packages.length === 0
  // Rows the table shows at once. The list's model is at least this long
  // - live rows plus filler below - so the table never shifts height.
  // The list's 140px viewport cap is this window at the 20px row height.
  readonly property int _rowWindow: 7
  // Live rows padded up to the window. Selection, search counts and
  // measuring keep reading `filtered`; only the list sees the padded
  // array, and its dependency set is packages+query alone - this array
  // IS the list's stableModel, so a selection change must not hand it a
  // new array (a new stableModel recreates every delegate).
  readonly property var _liveRows: Model.rowWindow(root.filtered, root._rowWindow)
  // The table is a placeholder while a fetch or an update is in flight,
  // while the fetch failed, or while there is nothing to show: its rows
  // stand blank under a veil. One switch says so everywhere - the rows'
  // own presentation, their selectable test, the table's scroll and the
  // overlays above them - so they cannot disagree about what the table
  // is showing.
  readonly property bool _blank: root.skeleton || root.islandState === "error" || root.upToDate
  // How much of the table is still placeholder: 1 while the bars stand,
  // 0 once the real rows own it. The handover from blank to live
  // dissolves instead of switching in a single frame - the rows that
  // arrive are born as bars (this is still 1 when they are built) and
  // then fade into their content.
  property real _skeletonMix: root._blank ? 1 : 0
  Behavior on _skeletonMix {
    enabled: MotionPolicy.enabled
    Glide { duration: Ui.normalMs }
  }

  signal updateRequested(bool aur, var names)
  // Full-system update: official + AUR in one pass.
  signal updateSystemRequested()
  signal refreshRequested()

  property string query: ""

  // Selection map: "<source>:<name>" -> true. Reassigned (not mutated) so
  // delegate bindings re-evaluate on every toggle.
  property var selected: ({})

  // Each readout below is a forwarding view onto the model, so no
  // consumer names the derivation and each keeps the dependency set it
  // had inline: the filter and the counts read packages (and, for the
  // filter, the query); the selection readouts read the selection map.
  // They are deliberately NOT merged into one derived object - a single
  // object would re-derive the filter on every checkbox click, handing
  // List.stableModel a new array and recreating every delegate.
  readonly property var filtered: Model.filterPackages(root.packages, root.query)
  readonly property var _counts: Model.sourceCounts(root.packages)

  readonly property int officialCount: root._counts.official
  readonly property int aurCount: root._counts.aur

  // Number of checked rows across both sources.
  readonly property int selectedCount: Model.selectedCount(root.selected)

  // True when every filtered package is selected (exact membership, not
  // just count). Uses filtered so search scopes select-all; when no filter
  // it equals packages.length implicitly but also tolerates extra selected
  // keys outside the filtered set.
  readonly property bool allSelected: Model.allSelected(root.filtered, root.selected)

  // Selected package names per source; empty array = "nothing selected".
  readonly property var selectedNames: Model.selectedNames(root.selected)

  // The key format is the model's; this forwarder keeps root.selKey
  // callable from the delegate components below.
  function selKey(pkg): string {
    return Model.selKey(pkg)
  }

  // NOTE: named toggleRow on purpose - it toggles table rows, which
  // must not be confused with the host's show/toggle window verbs.
  function toggleRow(pkg) {
    if (!pkg || typeof pkg !== "object") return
    root.selected = Model.toggleKey(root.selected, root.selKey(pkg))
  }

  function clearSelection() {
    root.selected = Model.emptySelection()
  }

  function toggleAll() {
    root.selected = Model.toggleAll(root.selected, root.allSelected, root.filtered)
  }

  // Drop selections for packages that no longer exist (updated away).
  // The model's null is its "nothing was stale" answer: leave the
  // property alone rather than reassign an equal map and re-run every
  // delegate binding for nothing.
  function pruneSelection() {
    const next = Model.pruneKeys(root.selected, root.packages)
    if (next !== null) root.selected = next
  }
  onPackagesChanged: root.pruneSelection()

  // Dropdown state at island level: the DropdownSlots live inside the
  // lazy contentComponent and bind their `open` to these bools (all
  // toggling happens on the bools, never on the slots directly). The
  // slots die with the content, so this state also survives open/close
  // cycles - reset below when the island closes.
  property bool warnOpen: false

  // A selection that empties deactivates "Update selected" - its warning
  // dropdown must not outlive its button, so fold it too. Covers every
  // deselect path: row clicks, select-all toggle, prune, island close.
  onSelectedCountChanged: {
    if (root.selectedCount === 0 && root.warnOpen) root.warnOpen = false
  }

  // --- table geometry: fit the widest row within caps ---
  // The measuring is imperative and stays here (TextMetrics is shared
  // state, see MenuPanel); the arithmetic that turns those measurements
  // into two column widths is the model's, and it takes this island's
  // caps as arguments rather than owning them.
  property real nameColW: 120
  property real verColW: 60
  // Hard ceiling for the version column (hash versions middle-elide past it).
  readonly property real _verCap: 120
  TextMetrics {
    id: tm

    font.pixelSize: Ui.fontXs
    font.family: Ui.fontFamily
    font.bold: false
  }

  function measureTable() {
    let nw = 0
    let vw = 0
    const f = root.filtered
    // "Version" header is bold fontXs -> measure it so verColW never clips it.
    tm.font.bold = true
    tm.text = "Version"
    vw = tm.width
    for (let i = 0; i < f.length; i++) {
      const p = f[i]
      tm.font.bold = true
      tm.text = String(p.name || "")
      if (tm.width > nw) nw = tm.width
      tm.font.bold = false
      tm.text = String(p.candidate || "")
      if (tm.width > vw) vw = tm.width
    }
    tm.font.bold = false
    const w = Model.columnWidths(nw, vw, root.islandContentWidth - 2 * Ui.outerPad,
      root._rowChrome, { minName: 48, minVer: 52, verPad: 4, verCap: root._verCap })
    root.nameColW = w.name
    root.verColW = w.ver
  }
  onFilteredChanged: {
    root.measureTable()
    // The keyboard cursor is an index into the previous row set. A filter
    // swap recreates every delegate, so index 0 now names a different
    // package - leaving it seated paints the highlight bar plus the focus
    // ring on a row nobody pointed at (the "first entry looks selected"
    // report after filter-then-clear). Unseat; the next arrow re-enters
    // from the edge it comes from.
    root._resetCursor()
  }

  // Drop the table cursor. Runs synchronously inside onModelChanged:
  // the view seats index 0 synchronously as part of the model
  // assignment itself (before onModelChanged fires), so clearing it in
  // the same turn means the -1 -> 0 -> -1 transient never reaches a
  // frame: no highlight-bar glide and no focus ring ever paints on row
  // 0. The previous deferred (callLater) clear left exactly that window
  // open, which read as the first entry flashing on every keystroke.
  // Arrow-key motion never reassigns the model, so a deliberate cursor
  // survives.
  function _resetCursor() {
    if (pkgList && pkgList.currentIndex !== -1) pkgList.seat(-1, "land")
  }
  // First open while the deferred boot refresh has not run yet: fetch
  // now instead of showing the idle empty state until the 90s timer
  // fires. Single-flight guarded in the service, so a concurrent boot
  // refresh collapses into one cycle.
  Component.onCompleted: {
    root.measureTable()
    if (root.islandState === "idle") Qt.callLater(() => root.refreshRequested())
  }

  // The UI font resolves asynchronously at boot (SystemFont probes GTK);
  // a first measure in the fallback font would freeze undersized columns,
  // so re-measure if the family lands after us.
  Connections {
    target: SystemFont
    function onFamilyChanged() { root.measureTable() }
  }

  // Row geometry shared by the header and the delegates so the columns
  // always line up:
  //   [inset] checkbox(14) gap icon(14 in an 18 slot) gap NAME gap VERSION [inset]
  readonly property real _rowInset: Ui.s
  readonly property real _checkW: 14
  readonly property real _iconW: 14
  // Icon cell: the glyph plus 2px of padding on each side.
  readonly property real _iconSlotW: root._iconW + 4
  readonly property real _gap: 4
  // Vertical scrollbar gutter: the bar (3px + 1px margin) overlays the
  // viewport; reserve its width in the row chrome so the "Version" column
  // never runs under it and the table width accounts for it.
  readonly property real _vBarGutter: 6
  // Fixed width around the name/version pair inside a row (checkbox +
  // icon slot + the three gaps between the four cells).
  readonly property real _rowInner: root._checkW + root._gap + root._iconSlotW + 2 * root._gap
  // Same, plus the outer insets - sized against the card body.
  readonly property real _rowChrome: 2 * root._rowInset + root._rowInner + root._vBarGutter
  readonly property real _neededW: root.nameColW + root.verColW + root._rowChrome

  // Static card size: the island never grows or shrinks with content
  // (filtering, refresh swaps, the spinner block) so it never jumps under
  // the bar; wide rows scroll horizontally instead of widening it.
  // 440 gives the table ~14px more breathing room than 420 so the
  // "Version" header and its scrollbar never kiss the card edge.
  property int islandContentWidth: 440
  // The table spans the card body, or wider (horizontal scroll) when the
  // widest row does not fit.
  readonly property real tableW: Math.max(root._neededW, root.islandContentWidth - 2 * Ui.outerPad)

  // Constant window size: fixed card dimensions, the same as when the
  // list is shown (header + 7-row table + search field + room for the
  // warning dropdown). 310 = 330 less the 14px divider and its gap.
  //
  // Heavy queue: more than 200 pending packages (the threshold is
  // Model.HEAVY_QUEUE_MIN, one definition shared with the module's
  // tooltip). One condition feeds the warning box, the red total and the
  // window-height delta below, so the three cannot disagree about what
  // "heavy" means. The whole feature also gates on
  // shell.statusbar.archUpdatesHeavyWarning (Settings).
  readonly property bool heavyWarnEnabled: Settings.statusbarArchUpdatesHeavyWarning
  readonly property bool heavyQueue: Model.heavyQueue(root.packages, root.heavyWarnEnabled)
  // Height the heavy-updates warning adds on top of the fixed 310: the
  // box plus one actions-column gap (5). Read off the live content so a
  // font change or a wrapped second line resizes exactly; the content
  // only exists while the host shows it, and the host freezes the last
  // live footprint for the closed window.
  readonly property real _warnExtra: contentRoot.warnExtra
  property int islandContentHeight: 310 + (root.heavyQueue ? root._warnExtra : 0)
  property bool islandSelfAnimating: false
  property var islandHost: null

  // No keyboard target: the package table is mouse-only (scroll on long
  // tables, checkbox clicks). Null is the router's normal answer for an
  // island with nothing to navigate, so arrows and Enter fall through.
  property var islandNavTarget: null

  // Stand the shared key router down while the filter field holds the
  // keyboard. This island is the reason `IslandNav.blocked` exists: the router
  // runs its key map with `Keys.BeforeItem` priority, which is what makes the
  // arrows reach the package table instead of being eaten by whatever inner
  // Flickable holds focus - and that same priority would otherwise make them
  // untypeable in this field.
  //
  // The field's own focus is the right signal, not a flag: it is the exact
  // condition under which typing must win, and it is already tracked (the
  // island arms and disarms focus around its own lifecycle).
  readonly property bool blockedNavKeys: contentRoot.searchInput !== null
    && contentRoot.searchInput !== undefined
    && contentRoot.searchInput.focused === true

  // THE ESCAPE LADDER, in the only order that works.
  //
  // Clear the filter, release the field, close the island. Releasing focus is
  // the rung that was missing, and its absence made the island feel broken:
  // the field takes focus by default and the query starts empty, so "the
  // query is empty" was the answer to the very first key a user pressed - one
  // Escape, and the island was gone. Worse, because the field holds focus the
  // whole time, every arrow was being answered as "the router is suspended",
  // so the package table could not be walked at all until focus was released
  // by some other means.
  //
  // One press now costs one rung, which is what makes it conventional: Escape
  // walks back out through the layers rather than cutting to the end.
  function escapeLadder(field): bool {
    if (root.query !== "") {
      root.query = ""
      return true
    }
    if (field !== null && field !== undefined && field.focused === true) {
      field.releaseFocus()
      // Spend the latch as well: re-grabbing the field the moment it is
      // released would make the rung a no-op, and an on-screen field that
      // steals the keyboard back the instant you leave it is the behaviour
      // this whole ladder exists to undo.
      contentRoot._searchFocusArmed = false
      return true
    }
    if (root.islandHost !== null && root.islandHost !== undefined) {
      root.islandHost.close()
      return true
    }
    return false
  }

  // De-focus net: a press on any empty, un-clickable spot of the card
  // (section gaps, space under short content) releases the search field.
  // Sits beneath the content column so real controls and rows keep
  // their own clicks.
  // Content lent to the shared host: incubated on show, destroyed after
  // the close fade.
    Item {
      id: contentRoot

      anchors.fill: parent

      // Height the heavy-updates warning adds to the column (its box plus
      // one actions-row gap); zero while the box is hidden. The island's
      // islandContentHeight binding reads this through contentRoot.
      readonly property real warnExtra: updateWarn.visible ? updateWarn.height + actionsCol.spacing : 0

      // The filter field, reached from the island root. An id is visible only
      // inside its own component scope, so `blockedNavKeys` - which lives
      // outside contentRoot - needs this alias to ask whether the field
      // currently holds focus.
      property alias searchInput: searchField

      // The search field owns active focus as the island opens, so typing
      // filters without a click first - but only when there is more than
      // one package to sift. Up to date (or a single pending row) leaves
      // the field unfocused; filtering those needs no head start. The
      // latch is armed per show - the host incubates this content fresh
      // every time - and is one-shot: the grab retires it, and so does
      // the de-focus net below, so no later unlock can pull the field
      // back from a user who left it. A count refusal retires nothing, so
      // results landing later (a refresh completing while open) still
      // earn the grab.
      property bool _searchFocusArmed: true

      // A disabled item takes no active focus, and the field is locked
      // whenever the skeleton is up (a fetch or an update runs), so the
      // grab waits for the unlock: onEnabledChanged calls back in. The
      // latch is spent only once the deferred grab really lands, which
      // leaves a field that locks again inside that turn still owed one.
      function armSearchFocus() {
        if (!contentRoot._searchFocusArmed || !searchField.enabled) return
        if (root.packages.length <= 1) return
        Qt.callLater(() => {
          if (!contentRoot._searchFocusArmed || !searchField.enabled) return
          if (root.packages.length <= 1) return
          contentRoot._searchFocusArmed = false
          searchField.grabFocus()
        })
      }

      Component.onCompleted: contentRoot.armSearchFocus()

  MouseArea {
    z: -1
    anchors.fill: parent
    // Retiring the latch is part of leaving: without it the next enable
    // transition would read as an unanswered grab and take the field back.
    onPressed: {
      contentRoot._searchFocusArmed = false
      searchField.releaseFocus()
    }
  }

  Column {
    id: body

    width: parent.width
    spacing: 6

    // Header: section-cap title (lib Title level 2 - the caps style the
    // network island uses for KNOWN/OTHER NETWORKS) + level 4 (subtitle),
    // no local font/size overrides, so the header tracks the shared
    // levels like every other island. Title row mirrors the network
    // island's section headers: small foreground_1 glyph at 70% before
    // the caps title.
    Column {
      width: parent.width
      spacing: 2

      Row {
        anchors.left: parent.left
        spacing: Ui.s

        Icon {
          anchors.verticalCenter: parent.verticalCenter
          name: "package"
          colorKey: "foreground_1"
          size: 14
          opacity: 0.7
        }

        Title {
          level: 2
          anchors.verticalCenter: parent.verticalCenter
          text: "PACKAGE UPDATES"
        }
      }

      // Single subtitle line: totals plus the refresh cadence, or the
      // failure note when a check went wrong. Wraps only for long error
      // strings; the level owns size/weight/color otherwise. While a
      // fetch or update runs a small spinner rides in front of the line
      // - the busy indicator lives here, not over the table.
      Row {
        width: parent.width
        // No dead gap while the spinner is hidden.
        spacing: statusIcon.visible ? root._gap : 0

        Icon {
          id: statusIcon

          visible: root.skeleton
          width: root._iconW
          height: root._iconW
          anchors.verticalCenter: parent.verticalCenter
          name: "update"
          colorKey: "foreground_1"
          size: root._iconW
          opacity: 0.5
          transformOrigin: Item.Center

          // A looping animation has no Behavior to disable and `Animation` has
          // no `enabled` member, so `running` is the gate. With the switch off
          // the reset below parks the rotation at 0 and the icon is the same
          // glyph the header shows statically, so the busy state is still
          // legible - it just stops moving.
          RotationAnimation on rotation {
            from: 0
            to: 360
            duration: 1000
            loops: Animation.Infinite
            running: root.skeleton && MotionPolicy.enabled
            onRunningChanged: if (!running) statusIcon.rotation = 0
          }
        }

        Title {
          level: 4
          // Full width while idle; reserve the spinner's slot only while
          // it is visible so the idle subtitle stays flush with the title.
          width: parent.width - (statusIcon.visible ? statusIcon.width + parent.spacing : 0)
          wrapMode: Text.WordWrap
          // StyledText so the heavy-queue total can be painted red on
          // its own; counts are numeric, so no markup escaping is needed.
          textFormat: Text.StyledText
          text: {
            if (root.islandState === "loading") return "Checking for updates..."
            if (root.islandState === "error") return "Failed to fetch updates"
            const n = root.packages.length
            if (n === 0) return "System is up to date"
            // Heavy backlog: only the total goes red, the rest of the
            // line keeps the muted base color.
            const total = root.heavyQueue
              ? "<font color=\"" + Ui.solid("red") + "\">" + n + "</font>"
              : String(n)
            return total + " update" + (n === 1 ? "" : "s")
              + " (" + root.officialCount + " official, " + root.aurCount + " AUR)"
          }
          // Red while a check failed; the level-4 muted default
          // otherwise (the heavy-queue red lives in the font tag).
          color: root.islandState === "error"
            ? Ui.solid("red") : Ui.tint("foreground_1", 0.5)
        }
      }
    }

    // Refresh + update buttons. Full-bleed (no side insets). Refresh is
    // blue; Update selected is green and gated on any selection. It opens
    // a warning dropdown - partial upgrades can break a system - and the
    // red "I Understand" row confirms and launches the update.
    Column {
      id: actionsCol

      width: parent.width
      spacing: 5

      // Heavy queue caution (the root.heavyQueue condition, gated by the
      // settings toggle), directly above the first button. Pure lib Notice
      // text - no icon, no actions; the buttons below stay the only
      // actions.
      Notice {
        id: updateWarn

        width: parent.width
        tone: "danger"
        message: "You have many pending updates. Long backlogs raise the risk of conflicts and delay security and stability fixes.\nUpdate your OS regularly."
        visible: root.heavyQueue
      }

      Button {
        width: parent.width
        label: "Refresh"
        variant: "primary"
        accentColor: Ui.solid("blue")
        height: 22
        implicitHeight: 22
        // Unclickable while a refresh is in flight (islandState "loading")
        // or an update runs - the Button lib dims to 0.45 and kills hover
        // on enabled: false.
        enabled: !root.updating && root.islandState !== "loading"
        onClicked: root.refreshRequested()
      }

      // Update buttons share one row: selection-scoped on the left,
      // full-system on the right.
      Row {
        width: parent.width
        spacing: parent.spacing

        Button {
          id: updateSelectedBtn

          width: (parent.width - parent.spacing) / 2
          label: root.selectedCount > 0 ? "Update Selected (" + root.selectedCount + ")" : "Update Selected"
          variant: "primary"
          accentColor: Ui.solid("green")
          height: 22
          implicitHeight: 22
          enabled: !root.updating && root.selectedCount > 0
          onClicked: {
            // Full selection is not a partial upgrade -> skip the warning.
            if (root.selectedCount > 0 && root.selectedCount === root.packages.length) {
              root.warnOpen = false
              const aur = root.selectedNames.aur.length > 0
              root.updateRequested(aur, root.selectedNames.official.concat(root.selectedNames.aur))
            } else {
              root.warnOpen = !root.warnOpen
            }
          }
        }

        Button {
          id: updateSystemBtn

          width: (parent.width - parent.spacing) / 2
          label: "Update System"
          variant: "primary"
          accentColor: Ui.solid("orange")
          height: 22
          implicitHeight: 22
          enabled: !root.updating && (root.officialCount > 0 || root.aurCount > 0)
          onClicked: {
            root.warnOpen = false
            root.updateSystemRequested()
          }
        }
      }

      DropdownSlot {
        id: warnSlot

        width: parent.width
        // The island's inter-block rhythm (actionsCol.spacing) owns
        // both outer margins - above the box and below the button - so
        // the dropdown breathes evenly; the slot adds nothing of its own.
        gap: 0
        open: root.warnOpen
        // Hidden, not just zero-height, when closed so the body Column
        // does not reserve a spacing gap for a folded slot.
        visible: open || closing

        Column {
          width: parent.width
          spacing: body.spacing

          Notice {
            width: parent.width
            tone: "warning"
            message: "Partial upgrades are not supported by Arch Linux."
          }

          DropdownButton {
            width: parent.width
            text: "I Understand"
            accent: Ui.solid("red")
            enabled: root.selectedCount > 0
            onClicked: {
              // Do not launch a full update if the selection emptied
              // while the warning was open (filter change, prune).
              if (root.selectedCount === 0) {
                root.warnOpen = false
                return
              }
              root.warnOpen = false
              // A mixed selection goes through yay (it resolves repo and
              // AUR names in one run); official-only keeps pacman.
              const aur = root.selectedNames.aur.length > 0
              root.updateRequested(aur,
                root.selectedNames.official.concat(root.selectedNames.aur))
            }
          }
        }
      }
    }

    InputField {
      id: searchField

      // Full-bleed like the buttons above it.
      width: parent.width
      placeholder: "Filter packages..."
      implicitHeight: 26
      fontSize: Ui.fontS
      // Native filter chrome: filter glyph plus filtered/total counter
      // inside the field (launcher/clipboard pattern, not local overrides).
      inputRole: "filter"
      filterIconAlways: true
      counterVisible: true
      counterMatched: root.filtered.length
      counterTotal: root.packages.length
      // The field is locked exactly while the skeleton is up, and a
      // locked field cannot hold focus, so the unlock is the second
      // half of the opening grab.
      enabled: !root.updating && root.islandState !== "loading"
      onEnabledChanged: if (enabled) contentRoot.armSearchFocus()
      onEdited: text => root.query = text
      onEscaped: root.escapeLadder(text)
    }

    // Package table: header row + capped list, sharing one horizontal
    // flick so long rows scroll sideways instead of eliding. Hidden while
    // a fetch or an update is in flight (the skeleton wash takes its
    // place).
    Item {
      id: tableBlock

      visible: root.skeleton || root.islandState === "error" || root.upToDate || (root.filtered.length > 0 && !root.updating && root.islandState !== "loading")
      width: parent.width
      height: visible ? headerRow.height + pkgList.height : 0

      Flickable {
        id: hScroll

        anchors.fill: parent
        contentWidth: Math.max(width, root.tableW)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: root.tableW > width + 1

        Column {
          width: hScroll.contentWidth

          // Column headers
          Item {
            id: headerRow

            width: parent.width
            height: 20

            // No hover tint anywhere in the table: the only hover
            // affordance is the pointer cursor over the checkboxes.

            Row {
              anchors.fill: parent
              anchors.leftMargin: root._rowInset
              // Right inset includes the scrollbar gutter: the vertical
              // bar overlays the viewport edge, so rows end before it and
              // the Version column can never run underneath.
              anchors.rightMargin: root._rowInset + root._vBarGutter
              spacing: root._gap

              CheckBox {
                anchors.verticalCenter: parent.verticalCenter
                checked: root.allSelected
                enabled: !root.skeleton && root.islandState !== "error" && !root.upToDate
                opacity: (root.skeleton || root.islandState === "error" || root.upToDate) ? 0.35 : 1
              }

              // Keep icon slot empty in header so Package/Version columns align:
              // header's checkbox occupies _checkW, then gap, then empty icon slot
              // so the text columns start at the same x as delegate rows.
              Item {
                width: root._iconSlotW
                height: parent.height
              }

              Title {
                level: 5
                width: parent.width - root._rowInner - root.verColW
                anchors.verticalCenter: parent.verticalCenter
                text: "Package"
                elide: Text.ElideNone
                color: Ui.tint("foreground_1", 0.6)
                font.pixelSize: Ui.fontXs
                font.bold: true
              }

              Title {
                level: 5
                width: root.verColW
                anchors.verticalCenter: parent.verticalCenter
                text: "Version"
                elide: Text.ElideNone
                horizontalAlignment: Text.AlignRight
                color: Ui.tint("foreground_1", 0.6)
                font.pixelSize: Ui.fontXs
                font.bold: true
              }
            }

            // Click-only: toggles all. No hover effects anywhere in the
            // table - rows, header and checkboxes alike.
            MouseArea {
              id: headerArea

              anchors.fill: parent
              onClicked: root.toggleAll()
            }
          }

          Item {
            width: parent.width
            height: pkgList.height

            List {
              id: pkgList

              // Mouse-only table: no keyboard cursor, so no sliding bar and
              // no seated index. A ListView starts at currentIndex 0, and
              // -1 keeps it unseated from the first frame.
              selectionHighlight: false
              currentIndex: -1
              // A skeleton or error row is not a package, so it is not a
              // target either: without this the cursor would park on a
              // loading placeholder and Enter would answer for a row that
              // does not exist. A padding filler is the same thing by
              // another name - it is only there to hold the table's
              // footprint, so the cursor must not stop on one and paint a
              // band over an empty row. Both tests read the same switch
              // that says the table is a placeholder, so "selectable"
              // cannot disagree with "is a package row" the way a second
              // list of its own would.
              isSelectable: i => !root._blank && !Model.isFiller(root._liveRows[i])
              width: parent.width
              height: Math.min(contentHeight, 140)
              // The list always holds the live rows. The blank table is
              // what those rows LOOK like while the table is a
              // placeholder - each row's own bar stands in for its
              // content - so the handover between the two is a dissolve
              // and not a model swap that recreates every delegate in a
              // single frame. On fetch error the rows stand blank under a
              // dimmed overlay + warning icon (constant window).
              stableModel: root._liveRows
              spacing: 0
              interactive: contentHeight > height && !root._blank
              // Short tables never take the wheel: long tables scroll natively
              // through interactive above, so stepping here would only walk the
              // keyboard cursor across rows that cannot scroll.
              wheelSteps: false
              delegate: rowDelegate
              // No focus border: with no keyboard cursor there is nothing to
              // mark, and a ring would read as a selection nobody made.
              focusBorder: false
              // The model assignment above seats index 0 synchronously, so
              // this clears it back in the same turn (see _resetCursor):
              // the transient never paints.
              onModelChanged: root._resetCursor()
              // Toggling is the row click's business (see rowDelegate): the
              // checkbox is visual-only by design and its parent owns the
              // click, so there is no keyboard path answering for a row.
              clip: true
            }
          }
        }
      }

      // Vertical scrollbar: fixed in the viewport (tableBlock) so it
      // never scrolls away with the horizontal flick and never gets
      // clipped at the content edge. Below the header row. It rides the
      // live rows: while the table is a placeholder the rows it measures
      // are not the ones on screen, so the thumb goes with them and
      // fades in as the real rows take over.
      Item {
        anchors.fill: parent
        opacity: 1 - root._skeletonMix
        visible: opacity > 0

        ScrollBar {
          flickable: pkgList
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.topMargin: headerRow.height
          anchors.bottom: parent.bottom
          anchors.rightMargin: 1
          thickness: 3
          radius: RoundingPolicy.radius
        }
      }

      // Skeleton wash: brighter-than-background veil over the blank
      // table so it reads as a not-yet-functional placeholder (site
      // layout skeleton) instead of an empty list. The spinner itself
      // lives in the header, in front of the status line - the wash is
      // only the veil. Input blocker sits under the veil so the frozen
      // table cannot be scrolled or clicked while loading.
      MouseArea {
        anchors.fill: parent
        enabled: root.skeleton
        hoverEnabled: true
      }

      Rectangle {
        anchors.fill: parent
        visible: root.skeleton || opacity > 0
        opacity: root.skeleton ? 1 : 0
        color: Ui.tint("background_0", 0.45)

        // The veil lifts with the rows it dims: a hard cut here would
        // undo the dissolve the rows just made.
        Behavior on opacity {
          enabled: MotionPolicy.enabled
          Glide { duration: Ui.normalMs }
        }
      }

      // Conventional website skeleton shimmer: a soft wash over the blank rows
      // that breathes on the shared skeleton cadence. The cadence and its
      // stagger belong to `SkeletonPulse`, which is what the per-row
      // placeholders in this file and the ones in the Bluetooth and Network
      // islands already run, so there is no second set of these numbers here
      // to retune. The error overlay above hides it: an error is a static
      // skeleton by design.
      Item {
        anchors.fill: parent
        visible: root.skeleton || opacity > 0
        opacity: root.skeleton ? 1 : 0
        clip: true

        // The sweep goes with the veil it rides (see the wash above).
        Behavior on opacity {
          enabled: MotionPolicy.enabled
          Glide { duration: Ui.normalMs }
        }

        Rectangle {
          anchors.fill: parent
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.5; color: Ui.tint("foreground_1", 0.10) }
            GradientStop { position: 1.0; color: "transparent" }
          }
          opacity: 0.55

          // `running` rather than a shortened duration, because a looping
          // animation has no Behavior to disable: with the compositor switch
          // off the wash holds its resting opacity and the table still reads
          // as a placeholder, it just stops breathing.
          SequentialAnimation on opacity {
            loops: Animation.Infinite
            running: root.skeleton && MotionPolicy.enabled
            SkeletonPulse { index: 0 }
          }
        }
      }

      // Error overlay: keep skeleton as-is (no flashing), dim list background over it
      // and show big centered red warning icon with generic message (not red).
      Item {
        anchors.fill: parent
        visible: opacity > 0
        // The dim rides the placeholder mix, so the overlay arrives and
        // leaves with the same dissolve the rows do - it is part of the
        // blank table's presentation, not a separate cut on top of it.
        opacity: root.islandState === "error" ? root._skeletonMix : 0

        Rectangle {
          anchors.fill: parent
          color: Ui.tint("background_0", 0.62)
        }

        Column {
          anchors.centerIn: parent
          width: parent.width - 32
          spacing: 10

          Icon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: "warning"
            colorKey: "red"
            size: 56
          }

          Title {
            level: 3
            width: parent.width
            text: "Unable to load updates"
            color: Ui.tint("foreground_1", 0.6)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
        }
      }

      // Up-to-date overlay: static skeleton under a dim, big centered
      // check glyph with generic text (muted, not accent).
      Item {
        anchors.fill: parent
        visible: opacity > 0
        // As with the error overlay: the dim is part of the blank
        // table's presentation, so it dissolves with it.
        opacity: root.upToDate ? root._skeletonMix : 0

        Rectangle {
          anchors.fill: parent
          color: Ui.tint("background_0", 0.62)
        }

        Column {
          anchors.centerIn: parent
          width: parent.width - 32
          spacing: 10

          Icon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: "check"
            colorKey: "foreground_1"
            size: 56
          }

          Title {
            level: 3
            width: parent.width
            text: "System is up to date"
            color: Ui.tint("foreground_1", 0.6)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
        }
      }
    }

    Title {
      level: 5
      visible: root.islandState === "ready" && root.packages.length > 0 && root.filtered.length === 0
      // No height binding: the Column already collapses invisible children.
      width: parent.width
      text: "No matches"
      horizontalAlignment: Text.AlignHCenter
      color: Ui.tint("foreground_1", 0.5)
      font.pixelSize: Ui.fontS
      font.italic: true
    }

    // Fetch/update in progress: the table block above renders the
    // loading skeleton (blank zebra rows under the skeleton wash), sized
    // to the live list's footprint, and the header carries the spinner.
  }

  Component {
    id: pkgDelegate

    Item {
      id: row

      required property var modelData
      required property int index
      width: ListView.view ? ListView.view.width : 300
      height: 20

      readonly property var pkg: row.modelData
      readonly property string selKey: row.pkg ? root.selKey(row.pkg) : ""
      readonly property bool isAur: row.pkg && String(row.pkg.source || "") === "aur"
      readonly property bool checked: row.pkg && root.selected[row.selKey] === true
      readonly property string pkgName: row.pkg ? String(row.pkg.name || "") : ""
      readonly property string cand: row.pkg ? String(row.pkg.candidate || "") : ""

      // Zebra striping (Finder-style) + click surface from the shared
      // row: even rows carry the faint band; hover and selection never
      // recolor it. Content declares below, painting above the band.
      ZebraRow {
        anchors.fill: parent
        rowIndex: row.index
        onClicked: root.toggleRow(row.pkg)
      }

      Row {
        anchors.fill: parent
        anchors.leftMargin: root._rowInset
        // Gutter included like the header: row content ends before the
        // overlaid scrollbar instead of underneath it.
        anchors.rightMargin: root._rowInset + root._vBarGutter
        spacing: root._gap

        // Checkbox
        CheckBox {
          anchors.verticalCenter: parent.verticalCenter
          checked: row.checked
        }

        // Source icon in a padded slot: even breathing room around it so
        // it never crowds the checkbox or the name. archlinux for official
        // repos, package for AUR.
        Item {
          width: root._iconSlotW
          height: root._iconW
          anchors.verticalCenter: parent.verticalCenter

          Icon {
            anchors.centerIn: parent
            name: row.isAur ? "package" : "archlinux"
            colorKey: row.isAur ? "foreground_1" : "foreground_0"
            size: root._iconW
          }
        }

        Title {
          level: 5
          width: parent.width - root._rowInner - root.verColW
          anchors.verticalCenter: parent.verticalCenter
          text: row.pkgName
          elide: Text.ElideRight
          color: Ui.solid("foreground_0")
          font.pixelSize: Ui.fontXs
          font.bold: true
        }

        Title {
          level: 5
          width: root.verColW
          anchors.verticalCenter: parent.verticalCenter
          text: row.cand
          elide: Text.ElideMiddle
          horizontalAlignment: Text.AlignRight
          color: Ui.tint("accent", 1)
          font.pixelSize: Ui.fontXs
        }
      }
    }
  }

  // Skeleton rows: zebra stripes + disabled checkboxes + conventional
  // website-style flashing placeholders for Package/Version. Each bar
  // pulses opacity in a staggered loop while `root.skeleton` is true,
  // mimicking the shimmer/skeleton pattern used on web content loaders.
  Component {
    id: skeletonDelegate

    Item {
      id: skeletonRow

      required property int index
      width: ListView.view ? ListView.view.width : 300
      height: 20

      // Same zebra parity as the live rows (shared row, decorative:
      // band only, no click surface).
      ZebraRow {
        anchors.fill: parent
        rowIndex: skeletonRow.index
        interactive: false
      }

      Row {
        anchors.fill: parent
        anchors.leftMargin: root._rowInset
        anchors.rightMargin: root._rowInset + root._vBarGutter
        spacing: root._gap

        CheckBox {
          anchors.verticalCenter: parent.verticalCenter
          checked: false
          enabled: false
          opacity: 0.35
        }

        Item {
          width: root._iconSlotW
          height: root._iconW
          anchors.verticalCenter: parent.verticalCenter
        }

        Item {
          width: parent.width - root._rowInner - root.verColW
          height: parent.height

          Rectangle {
            width: parent.width * (0.48 + (skeletonRow.index % 3) * 0.16)
            height: 8
            radius: RoundingPolicy.radius
            anchors.verticalCenter: parent.verticalCenter
            color: Ui.tint("foreground_1", 0.14)
            opacity: 0.55

            SequentialAnimation on opacity {
              loops: Animation.Infinite
              running: root.skeleton && MotionPolicy.enabled
              SkeletonPulse { index: skeletonRow.index }
            }
          }
        }

        Item {
          width: root.verColW
          height: parent.height

          Rectangle {
            width: parent.width * 0.62
            height: 8
            radius: RoundingPolicy.radius
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            color: Ui.tint("foreground_1", 0.14)
            opacity: 0.55

            SequentialAnimation on opacity {
              loops: Animation.Infinite
              running: root.skeleton && MotionPolicy.enabled
              SkeletonPulse { index: skeletonRow.index; offset: 150 }
            }
          }
        }
      }
    }
  }

  // The list's single delegate: per-row skeleton-vs-package switch lives
  // INSIDE where modelData exists (a ListView delegate is one Component
  // for the whole list; modelData at list scope is undefined and the
  // old ternary there threw a ReferenceError every row).
  Component {
    id: rowDelegate

    Item {
      id: rowCell

      required property var modelData
      required property int index
      width: ListView.view ? ListView.view.width : 300
      height: 20

      // Every field the row paints comes from one projection: the model
      // decides what a package row IS (and what a skeleton or padding
      // filler is not), this block only forwards it.
      readonly property var _row: Model.rowView(rowCell.modelData, root.selected)
      readonly property bool isFiller: rowCell._row.filler
      readonly property string selKey: rowCell._row.key
      readonly property bool checked: rowCell._row.checked
      readonly property bool isAur: rowCell._row.aur
      readonly property string pkgName: rowCell._row.name
      readonly property string cand: rowCell._row.candidate

      // The row's two faces: the placeholder bar and the package it
      // carries. A filler row only ever has the bar - it is the empty
      // space under the last package. A package row is born as a bar
      // while the table is a placeholder and dissolves into its content
      // as the real rows take over, so the handover never switches one
      // picture for another in a single frame.
      readonly property real barOpacity: rowCell.isFiller ? 1 : root._skeletonMix
      readonly property real contentOpacity: rowCell.isFiller ? 0 : 1 - root._skeletonMix

      // Zebra band and the row's click surface. A placeholder row is
      // not interactive and never answers for a package: the table
      // behind it is not a package list yet.
      ZebraRow {
        anchors.fill: parent
        rowIndex: rowCell.index
        interactive: rowCell.isFiller ? false : true
        onClicked: if (!rowCell.isFiller) root.toggleRow(rowCell.modelData)
      }

      Row {
        anchors.fill: parent
        anchors.leftMargin: root._rowInset
        anchors.rightMargin: root._rowInset + root._vBarGutter
        spacing: root._gap

        CheckBox {
          anchors.verticalCenter: parent.verticalCenter
          checked: rowCell.isFiller ? false : rowCell.checked
          // A placeholder row's checkbox is dim and dead. A package
          // row's is dim only while the row is still standing in as a
          // placeholder, and brightens with the content it belongs to.
          enabled: !rowCell.isFiller && !root._blank
          opacity: 0.35 + 0.65 * rowCell.contentOpacity
        }

        // Source icon slot: empty while skeleton, archlinux/package
        // icon once live.
        Item {
          width: root._iconSlotW
          height: root._iconW
          anchors.verticalCenter: parent.verticalCenter

          Icon {
            anchors.centerIn: parent
            // The icon arrives with the content it marks.
            opacity: rowCell.contentOpacity
            visible: opacity > 0
            name: rowCell.isAur ? "package" : "archlinux"
            colorKey: rowCell.isAur ? "foreground_1" : "foreground_0"
            size: root._iconW
          }
        }

        // Package name, or the pulsing placeholder bar while skeleton.
        Item {
          width: parent.width - root._rowInner - root.verColW
          height: parent.height

          // The placeholder bar the row dissolves out of. It sits UNDER
          // the name so the text reads over it while the two trade
          // places, and the wrapper - not the bar - carries the
          // handover fade, so the pulse and the dissolve never fight
          // over one property.
          Item {
            anchors.fill: parent
            opacity: rowCell.barOpacity
            visible: opacity > 0

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width * (0.48 + (rowCell.index % 3) * 0.16)
              height: 8
              radius: RoundingPolicy.radius
              color: Ui.tint("foreground_1", 0.14)
              opacity: 0.55

              SequentialAnimation on opacity {
                loops: Animation.Infinite
                running: root.skeleton && MotionPolicy.enabled
                SkeletonPulse { index: rowCell.index }
              }
            }
          }

          Title {
            level: 5
            anchors.fill: parent
            opacity: rowCell.contentOpacity
            visible: opacity > 0
            text: rowCell.pkgName
            elide: Text.ElideRight
            color: Ui.solid("foreground_0")
            font.pixelSize: Ui.fontXs
            font.bold: true
          }
        }

        // Version column, or its placeholder bar while skeleton.
        Item {
          width: root.verColW
          height: parent.height

          // As with the name column: the bar underneath, the version
          // over it.
          Item {
            anchors.fill: parent
            opacity: rowCell.barOpacity
            visible: opacity > 0

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: parent.right
              width: parent.width * 0.62
              height: 8
              radius: RoundingPolicy.radius
              color: Ui.tint("foreground_1", 0.14)
              opacity: 0.55

              SequentialAnimation on opacity {
                loops: Animation.Infinite
                running: root.skeleton && MotionPolicy.enabled
                SkeletonPulse { index: rowCell.index; offset: 150 }
              }
            }
          }

          Title {
            level: 5
            anchors.fill: parent
            opacity: rowCell.contentOpacity
            visible: opacity > 0
            text: rowCell.cand
            elide: Text.ElideMiddle
            horizontalAlignment: Text.AlignRight
            color: Ui.tint("accent", 1)
            font.pixelSize: Ui.fontXs
          }
        }
      }
    }
  }
}

// Close-path resets. The content (search field, selection,
  // dropdowns) is incubated fresh on every show, so open state never
  // survives a close by construction; the explicit resets below only
  // cover a teardown that outlives the fade.
  Component.onDestruction: {
    root.clearSelection()
    root.warnOpen = false
  }
}
