pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import qs.features.pickers.theme

// Theme picker overlay. A horizontal deck of theme cards, each card an
// imaginary desktop screenshot drawn as a skeleton in that theme's own
// colors (ThemePreview).
//
// THE DECK IS THE WALLPAPER DECK. The selected theme is the big card in the
// middle, and its neighbours are narrow slices tucked under its left and
// right edges, one step further out. Every card exists as its own item, so
// moving the selection glides the whole row: the outgoing card shrinks into
// a slice while the incoming one grows out of its slice. Tab and Shift+Tab
// move through the deck exactly as they do in the wallpaper picker.
//
// FAMILIES OPEN ON PURPOSE. A family is a card with its variants kept
// closed until the user explicitly selects it with Enter, Space or a click.
// Moving through the deck never opens one. When it does open, the variants
// slide down from behind the parent into a second, smaller copy of the same
// deck: one selected variant in the middle and its neighbour variants as
// slices at the edges. Left/Right (and Tab/Shift+Tab) then walk that row,
// and Enter applies the selected one. Esc closes the family row before it
// closes the picker.
//
// A PREVIEW NEVER REFLOWS. ThemePreview is laid out once at the deck's big
// card size and then cover-scaled into whatever frame it occupies, so a
// card growing out of a slice scales a still skeleton instead of resizing
// every bar inside it.
//
// The service owns the listing, the palette scan and the apply gate; this
// file owns the deck's geometry, its window and its keys.
Item {
  id: panel

  // Ceilings from the view's ScreenCeiling. The deck is a share of the
  // screen, not of the window it lives in: the window is sized from this
  // panel.
  property real maxHeight: 600
  property real hardMaxHeight: 1200

  readonly property var rows: ThemePicker.rows

  // Search field text. The deck filters directly on it; clearing the box is
  // clearing the filter. While a query is active, a family is flattened into
  // its individual variants: each is a normal entry that applies directly,
  // instead of a parent card that expands onto its first child.
  property alias query: themeSearch.text
  property var filteredRows: []
  // Every card the deck can show: each family/standalone row plus every
  // family variant as its own entry. The set is stable while filtering, so a
  // variant is moved by the slot map instead of being created after the query
  // turns on; that is what lets it glide in with the rest of the deck.
  readonly property var deckRows: {
    const out = []
    const all = panel.rows || []
    for (let i = 0; i < all.length; i++) {
      const row = all[i]
      out.push(row)
      const variants = Array.isArray(row.variants) ? row.variants : []
      for (let v = 0; v < variants.length; v++) {
        out.push(panel._variantEntry(row.label, variants[v]))
      }
    }
    return out
  }
  // Row key -> slot in the current deck set. Standalone rows and filtered
  // variant entries share this lookup by folder, so the delegates and the
  // slot map always describe the same set.
  property var _slots: ({})
  readonly property bool queryActive: panel.query.trim() !== ""

  // Selected ROW: one standalone theme or one family.
  property int selIndex: 0
  // Focused variant in an open family. Always 0 for a standalone.
  property int variantIndex: 0

  // A family is open only after an explicit select. The row's variants are
  // instantiated only while this is true.
  property bool _expanded: false
  // The variant row's own arrival, one tick behind `_expanded`, so its
  // cards are born behind the parent and then slide down into place.
  property bool _variantOpen: false

  // Open fade and the deck's own settle. `_settled` keeps geometry tweens
  // off until the surface has taken the screen's size, so the first frame
  // cannot animate the deck out of zero-sized cards.
  property bool _fade: false
  property bool _settled: false
  property bool _seated: false
  // The focused folder across a row-set change (a rescan, a theme switch),
  // so the deck does not jump back to the active theme.
  property string _keepFolder: ""

  readonly property var currentRow: {
    const list = panel.filteredRows
    if (!list || list.length === 0) return null
    const i = Math.max(0, Math.min(panel.selIndex, list.length - 1))
    return list[i]
  }
  readonly property bool family: panel.currentRow !== null
    && Array.isArray(panel.currentRow.variants)
    && panel.currentRow.variants.length > 1
  readonly property var variants: panel.family ? panel.currentRow.variants : []
  readonly property var focusedTheme: panel.family && panel._expanded
    ? panel.variants[Math.max(0, Math.min(panel.variantIndex, panel.variants.length - 1))]
    : panel.currentRow

  // ---- main deck geometry --------------------------------------------------
  // The wallpaper picker's cascade shape: a 16:9 big card that is the deck's
  // height, narrow slices at 82% of it, and one slice step of travel so
  // consecutive cards overlap by the same amount.
  //
  // The vertical budget is read from the items that actually surround the
  // deck, not guessed in pixels: the search field sits two bar-heights down,
  // the footer is anchored to the bottom, and the caption's real implicit
  // height sits between them. This is what keeps fractional-scaling type from
  // landing on the hints when a family row opens. The collapsed deck may use
  // the whole band; the expanded form shrinks just enough for the child row,
  // then re-centres in the same band.
  readonly property real searchTop: Math.max(Ui.l, Math.round(DesktopLayoutState.barHeight * 2))
  readonly property real contentTop: panel.searchTop + Ui.filterH + Ui.m
  readonly property real contentBottom: footer.y - caption.implicitHeight - Ui.m * 2
  readonly property real contentH: Math.max(0, panel.contentBottom - panel.contentTop)
  readonly property real fitCollapsedH: Math.max(160, panel.contentH)
  // bigH + vBigH (52% of bigH) + the variant gap must fit the same band.
  readonly property real fitExpandedH: Math.max(160, (panel.contentH - panel.vGap - 6) / 1.52)
  readonly property real deckH: Math.round(Math.max(160, Math.min(
    panel.height * 0.56,
    panel.maxHeight,
    panel._expanded ? panel.fitExpandedH : panel.fitCollapsedH)))
  readonly property real bigH: Math.round(Math.min(panel.deckH, panel.width * 0.54 * 9 / 16))
  readonly property real bigW: Math.round(panel.bigH * 16 / 9)
  readonly property real sliceW: Math.round(panel.bigW * 0.13)
  readonly property real sliceH: Math.round(panel.bigH * 0.82)
  readonly property real sliceOverlap: Math.round(panel.sliceW * 0.30)
  readonly property real sliceStep: panel.sliceW - panel.sliceOverlap
  readonly property real centerX: Math.round(panel.width / 2)

  // ---- opened-family geometry ---------------------------------------------
  // A second, smaller deck below the parent: the same arithmetic at 52% of
  // the parent's height, so the child row reads as the same surface.
  readonly property real vBigH: Math.round(panel.bigH * 0.52)
  readonly property real vBigW: Math.round(panel.vBigH * 16 / 9)
  readonly property real vSliceW: Math.round(panel.vBigW * 0.13)
  readonly property real vSliceH: Math.round(panel.vBigH * 0.82)
  readonly property real vSliceOverlap: Math.round(panel.vSliceW * 0.30)
  readonly property real vSliceStep: Math.round(panel.vSliceW - panel.vSliceOverlap)
  readonly property real vGap: Math.round(Ui.m + 2)
  readonly property real vBand: panel._expanded ? panel.vBigH + panel.vGap + 6 : 0
  readonly property real stageH: panel.bigH + panel.vBand
  readonly property real stageAreaH: Math.max(0, panel.contentBottom - panel.contentTop)
  readonly property real stageY: Math.round(
    panel.contentTop + Math.max(0, (panel.stageAreaH - panel.stageH) / 2))

  function tileX(rel) {
    if (rel === 0) return Math.round(panel.centerX - panel.bigW / 2)
    if (rel < 0) {
      return Math.round(panel.centerX - panel.bigW / 2 - panel.sliceW
        + panel.sliceOverlap + (rel + 1) * panel.sliceStep)
    }
    return Math.round(panel.centerX + panel.bigW / 2
      - panel.sliceOverlap + (rel - 1) * panel.sliceStep)
  }
  // A gentle downward cascade outward, kept inside the slice's own inset so a
  // slice never leaves the deck's band.
  function tileY(rel) {
    if (rel === 0) return 0
    return Math.round((panel.bigH - panel.sliceH) / 2 + Math.min(Math.abs(rel), 8) * 3)
  }
  function variantTileX(rel) {
    if (rel === 0) return Math.round(panel.centerX - panel.vBigW / 2)
    if (rel < 0) {
      return Math.round(panel.centerX - panel.vBigW / 2 - panel.vSliceW
        + panel.vSliceOverlap + (rel + 1) * panel.vSliceStep)
    }
    return Math.round(panel.centerX + panel.vBigW / 2
      - panel.vSliceOverlap + (rel - 1) * panel.vSliceStep)
  }
  function variantTileY(rel) {
    if (rel === 0) return 0
    return Math.round((panel.vBigH - panel.vSliceH) / 2 + Math.min(Math.abs(rel), 8) * 2)
  }

  // ---- helpers -------------------------------------------------------------
  function _folderOf(theme) {
    return theme ? String(theme.folder ?? "") : ""
  }
  function _hay(label, folder) {
    return (String(label ?? "") + " " + String(folder ?? "")).toLowerCase()
  }
  function _variantEntry(family, variant) {
    const fam = String(family ?? "")
    const child = String(variant.label ?? "")
    return {
      family: "",
      label: fam !== "" && child.toLowerCase() !== fam.toLowerCase()
        ? fam + " " + child : child,
      folder: String(variant.folder ?? ""),
      light: variant.light,
      colors: variant.colors,
      variants: []
    }
  }
  function _entryMatches(entry, parts) {
    const hay = panel._hay(entry.label, entry.folder)
    for (let p = 0; p < parts.length; p++) {
      if (hay.indexOf(parts[p]) < 0) return false
    }
    return true
  }
  function _rowKey(row) {
    if (!row) return ""
    const fam = String(row.family ?? "")
    return fam !== "" ? "f:" + fam : "s:" + String(row.folder ?? "")
  }
  function _slotOf(row) {
    const slot = panel._slots[panel._rowKey(row)]
    return typeof slot === "number" ? slot : -1
  }
  // Recompute the deck's row set from the query. Called from both the row
  // source and the field, so the filter never depends on which signal landed
  // first; every token has to appear somewhere in the row (family label,
  // folder, or one of its variants).
  function _refilter() {
    const all = panel.rows || []
    const q = String(panel.query ?? "").toLowerCase().trim()
    const slots = ({})
    if (q === "") {
      for (let i = 0; i < all.length; i++) slots[panel._rowKey(all[i])] = i
      panel.filteredRows = all
      panel._slots = slots
      return
    }
    const parts = q.split(/\s+/)
    const out = []
    for (let i = 0; i < all.length; i++) {
      const row = all[i]
      const variants = Array.isArray(row.variants) ? row.variants : []
      if (variants.length > 1) {
        // A filtered family is not a card of its own: every variant that
        // matches is an entry, so selecting one applies that variant directly.
        for (let v = 0; v < variants.length; v++) {
          const entry = panel._variantEntry(row.label, variants[v])
          if (panel._entryMatches(entry, parts)) out.push(entry)
        }
        continue
      }
      if (panel._entryMatches(row, parts)) out.push(row)
    }
    for (let i = 0; i < out.length; i++) slots[panel._rowKey(out[i])] = i
    panel.filteredRows = out
    panel._slots = slots
  }
  function _primaryOf(row) {
    if (!row) return null
    return Array.isArray(row.variants) && row.variants.length > 0 ? row.variants[0] : row
  }
  function _isActiveFolder(folder) {
    return String(folder ?? "") !== ""
      && String(folder).toLowerCase() === ThemePicker.activeFolder
  }
  function _isActiveRow(row) {
    if (!row) return false
    // Standalone rows carry an empty `variants` array, so checking the array
    // alone would skip their own folder and never light the active border.
    if (panel._isActiveFolder(row.folder)) return true
    if (Array.isArray(row.variants)) {
      for (let i = 0; i < row.variants.length; i++) {
        if (panel._isActiveFolder(row.variants[i].folder)) return true
      }
    }
    return false
  }
  function _displayLabel() {
    const row = panel.currentRow
    if (!row) return ""
    if (!panel.family || !panel._expanded) return String(row.label ?? "")
    const v = panel.focusedTheme
    const child = v ? String(v.label ?? "") : ""
    if (child.toLowerCase() === String(row.label ?? "").toLowerCase()) return child
    return String(row.label ?? "") + " " + child
  }
  function _meta() {
    const row = panel.currentRow
    if (!row) return ""
    const bits = []
    if (panel.family) {
      bits.push(panel._expanded ? panel.variants.length + " variants" : "Enter to expand")
    }
    const t = panel.focusedTheme
    if (t) bits.push(t.light ? "Light" : "Dark")
    if (t && panel._isActiveFolder(t.folder)) bits.push("Current")
    return bits.join(" · ")
  }

  // ---- selection -----------------------------------------------------------
  function _locate(folder) {
    const want = String(folder ?? "").toLowerCase()
    if (want === "") return { row: -1, variant: 0 }
    for (let i = 0; i < panel.filteredRows.length; i++) {
      const row = panel.filteredRows[i]
      // A standalone theme has variants: [] (not a family row); its own
      // folder is the value to match before walking a family's children.
      if (String(row.folder ?? "").toLowerCase() === want) {
        return { row: i, variant: 0 }
      }
      if (Array.isArray(row.variants)) {
        for (let v = 0; v < row.variants.length; v++) {
          if (String(row.variants[v].folder ?? "").toLowerCase() === want) {
            return { row: i, variant: v }
          }
        }
      }
    }
    return { row: -1, variant: 0 }
  }
  function _activeVariantIndex(row) {
    if (!row || !Array.isArray(row.variants)) return 0
    for (let i = 0; i < row.variants.length; i++) {
      if (panel._isActiveFolder(row.variants[i].folder)) return i
    }
    return 0
  }
  function _focusedFolder() {
    return panel._folderOf(panel.focusedTheme)
  }

  function collapseVariants() {
    panel._expanded = false
    panel._variantOpen = false
    variantTimer.stop()
  }

  function expandVariants() {
    if (!panel.family) return
    if (panel._expanded) return
    panel.variantIndex = panel._activeVariantIndex(panel.currentRow)
    panel._keepFolder = panel._folderOf(panel.variants[panel.variantIndex])
    panel._expanded = true
    panel._variantOpen = false
    variantTimer.stop()
    if (!MotionPolicy.enabled) {
      panel._variantOpen = true
      return
    }
    variantTimer.restart()
  }

  Timer {
    id: variantTimer
    interval: 30
    onTriggered: panel._variantOpen = true
  }

  function _seatOnActive() {
    const at = panel._locate(ThemePicker.activeFolder)
    panel.selIndex = at.row >= 0 ? at.row : 0
    panel.variantIndex = at.row >= 0 ? at.variant : 0
    panel._keepFolder = panel._focusedFolder()
    // A summon that lands before the first scan has no rows to seat on. Stay
    // unseated so the arriving rows run this again, instead of leaving the
    // deck parked on row zero rather than the applied theme.
    panel._seated = panel.filteredRows.length > 0
    panel.collapseVariants()
  }

  // A rescan can move rows under the deck. Keep the focused theme rather
  // than the index. An open family survives only while it is still the same
  // row; a structural change closes it rather than showing a stale child set.
  function _syncRows() {
    if (panel.queryActive) {
      panel._syncFilter()
      return
    }
    const at = panel._locate(panel._keepFolder)
    if (at.row >= 0) {
      if (panel._expanded && at.row !== panel.selIndex) panel.collapseVariants()
      panel.selIndex = at.row
      panel.variantIndex = at.variant
      return
    }
    panel.collapseVariants()
    const n = panel.filteredRows ? panel.filteredRows.length : 0
    if (n === 0) return
    panel.selIndex = Math.max(0, Math.min(panel.selIndex, n - 1))
    panel.variantIndex = Math.max(0, Math.min(panel.variantIndex, Math.max(0, panel.variants.length - 1)))
  }

  // A query change is a different deck: keep the focused row only while it
  // survives the filter, otherwise land on the first hit. An open family is
  // closed because its child row is no longer the thing being browsed.
  function _syncFilter() {
    panel.collapseVariants()
    panel.variantIndex = 0
    const n = panel.filteredRows ? panel.filteredRows.length : 0
    if (n === 0) {
      panel.selIndex = 0
      panel._keepFolder = ""
      return
    }
    let at = panel._locate(panel._keepFolder)
    // If the row being browsed no longer matches the query, prefer the theme
    // that is actually applied over the first alphabetical hit. Typing a
    // filter must not quietly move the cursor to a different theme that Enter
    // or a click can then apply.
    if (at.row < 0) at = panel._locate(ThemePicker.activeFolder)
    panel.selIndex = at.row >= 0 ? at.row : 0
    panel.variantIndex = at.row >= 0 ? at.variant : 0
    if (at.row >= 0) {
      const selected = panel.filteredRows[at.row]
      panel._keepFolder = at.variant > 0 && Array.isArray(selected.variants)
        ? panel._folderOf(selected.variants[at.variant])
        : panel._folderOf(selected)
    } else {
      panel._keepFolder = ""
    }
  }

  function selectRow(index) {
    const n = panel.filteredRows ? panel.filteredRows.length : 0
    if (n === 0) return
    const next = Math.max(0, Math.min(index, n - 1))
    if (next === panel.selIndex) return
    panel.collapseVariants()
    panel.selIndex = next
    panel.variantIndex = panel._activeVariantIndex(panel.currentRow)
    panel._keepFolder = panel._focusedFolder()
  }
  function moveRow(dir) {
    const n = panel.filteredRows ? panel.filteredRows.length : 0
    if (n === 0) return
    // A single step off either end lands on the other end, exactly like the
    // wallpaper deck. Home/End still select the absolute ends.
    const next = dir === 1 || dir === -1
      ? ((panel.selIndex + dir) % n + n) % n
      : Math.max(0, Math.min(panel.selIndex + dir, n - 1))
    panel.selectRow(next)
  }
  function moveVariant(dir) {
    if (!panel.family || !panel._expanded) return
    const n = panel.variants.length
    if (n === 0) return
    panel.variantIndex = ((panel.variantIndex + dir) % n + n) % n
    panel._keepFolder = panel._folderOf(panel.variants[panel.variantIndex])
  }
  function activateCurrent() {
    if (panel.family && !panel._expanded) {
      panel.expandVariants()
      return
    }
    const folder = panel._focusedFolder()
    if (folder === "") return
    ThemePicker.apply(folder)
  }

  // ---- open / focus --------------------------------------------------------
  function reveal() {
    panel._fade = false
    panel._settled = false
    revealTimer.restart()
  }

  Timer {
    id: revealTimer
    interval: 16
    onTriggered: {
      if (!ThemePicker.visible) return
      panel._settled = true
      panel._fade = true
    }
  }

  Connections {
    target: ThemePicker

    function onVisibleChanged() {
      if (!ThemePicker.visible) {
        panel._fade = false
        panel._settled = false
        panel.collapseVariants()
        panel._seated = false
        // Keep the query and filtered deck through the fade. Clearing it here
        // rebuilds the deck as all rows while it is still fading out, so the
        // card visibly jumps to the first theme (Antix) on every close.
        revealTimer.stop()
        return
      }
      panel._seated = false
      if (themeSearch.text !== "") themeSearch.text = ""
      panel._refilter()
      panel.collapseVariants()
      panel._seatOnActive()
      panel.reveal()
      focusCtrl.grabList()
    }
  }

  onRowsChanged: {
    panel._refilter()
    if (!ThemePicker.visible) return
    if (!panel._seated) panel._seatOnActive()
    else panel._syncRows()
  }

  onQueryChanged: {
    panel._refilter()
    if (!ThemePicker.visible || !panel._seated) return
    panel._syncFilter()
  }

  Component.onCompleted: {
    panel._refilter()
    // The panel can be built while the service is already open (the loader is
    // attached with the overlay). In that case visibleChanged has already
    // happened and would never seat the deck, leaving it on row zero - the
    // first card, not the applied theme.
    if (ThemePicker.visible) {
      panel._seatOnActive()
      panel.reveal()
      focusCtrl.grabList()
    }
  }

  PanelFocus {
    id: focusCtrl
    searchField: themeSearch
    serviceVisible: ThemePicker.visible
  }

  function handleKey(event) {
    const k = event.key
    const ctrl = event.modifiers & Qt.ControlModifier
    const alt = event.modifiers & Qt.AltModifier
    const open = panel._expanded && panel.family
    if (k === Qt.Key_F && ctrl) {
      focusCtrl.grabFilter()
      event.accepted = true
      return
    }
    if (k === Qt.Key_Escape) {
      if (panel.query !== "") {
        themeSearch.clear()
        event.accepted = true
        return
      }
      if (open) panel.collapseVariants()
      else ThemePicker.close()
      event.accepted = true
      return
    }
    if (k === Qt.Key_Backspace && panel.query !== "" && !themeSearch.focused) {
      themeSearch.text = panel.query.slice(0, -1)
      event.accepted = true
      return
    }
    if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
      panel.activateCurrent()
      event.accepted = true
      return
    }
    if (k === Qt.Key_Home) {
      if (open) {
        panel.variantIndex = 0
        panel._keepFolder = panel._folderOf(panel.variants[0])
      } else {
        panel.selectRow(0)
      }
      event.accepted = true
      return
    }
    if (k === Qt.Key_End) {
      if (open) {
        panel.variantIndex = Math.max(0, panel.variants.length - 1)
        panel._keepFolder = panel._folderOf(panel.variants[panel.variantIndex])
      } else {
        panel.selectRow(panel.filteredRows.length - 1)
      }
      event.accepted = true
      return
    }
    // Tab and Shift+Tab mean "next/previous card", exactly as in the
    // wallpaper picker. In the main deck that is the next theme; in an open
    // family row it is the next variant, because that row is the deck being
    // browsed.
    if (k === Qt.Key_Tab && !ctrl) {
      if (open) panel.moveVariant(1)
      else panel.moveRow(1)
      event.accepted = true
      return
    }
    if (k === Qt.Key_Backtab) {
      if (open) panel.moveVariant(-1)
      else panel.moveRow(-1)
      event.accepted = true
      return
    }
    if (!ctrl) {
      if (k === Qt.Key_Left) {
        if (open) panel.moveVariant(-1)
        else panel.moveRow(-1)
        event.accepted = true
        return
      }
      if (k === Qt.Key_Right) {
        if (open) panel.moveVariant(1)
        else panel.moveRow(1)
        event.accepted = true
        return
      }
    }
    // A surface with a search box spends its printable keys on the query, not
    // on one-letter navigation. The deck keeps the keyboard while this runs,
    // so arrows and Tab continue to walk the filtered cards; Ctrl+F or a click
    // hands the field the caret for full editing.
    if (!ctrl && !alt && !themeSearch.focused && event.text.length === 1
        && event.text !== " " && event.text.charCodeAt(0) >= 32) {
      themeSearch.type(panel.query + event.text)
      // The first printable key starts the query and hands the caret to the
      // field. Subsequent keys type natively; Up/Down/Tab still reach the deck
      // through InputField.forwardNavigation.
      focusCtrl.grabFilter()
      event.accepted = true
    }
  }
  Keys.onPressed: event => panel.handleKey(event)

  // ---- surface -------------------------------------------------------------
  MouseArea {
    anchors.fill: parent
    onClicked: ThemePicker.close()
  }

  Item {
    id: stage

    anchors.horizontalCenter: parent.horizontalCenter
    y: panel.stageY
    width: panel.width
    height: panel.stageH
    clip: true
    opacity: panel._fade ? 1 : 0

    Behavior on y {
      enabled: MotionPolicy.enabled && panel._settled
      Glide { duration: Ui.slowMs }
    }
    Behavior on height {
      enabled: MotionPolicy.enabled && panel._settled
      Glide { duration: Ui.slowMs }
    }
    Behavior on opacity {
      enabled: MotionPolicy.enabled
      Glide { duration: Ui.fastMs }
    }

    // ---- the main deck ----------------------------------------------------
    // The model holds every possible card, not only the current hits. A
    // filtered family has no parent card of its own, but its variant entries
    // already exist here: filtering only changes their slot, opacity and
    // preview, so they animate in instead of being created fully formed.
    Repeater {
      model: panel.deckRows

      delegate: Item {
        id: rowCard

        required property var modelData
        required property int index

        readonly property int slot: panel._slotOf(rowCard.modelData)
        readonly property bool matched: rowCard.slot >= 0
        readonly property int rel: rowCard.matched ? rowCard.slot - panel.selIndex : 0
        readonly property bool selected: rowCard.matched && rowCard.rel === 0
        readonly property var primary: panel._primaryOf(rowCard.modelData)

        // An unmatched card glides to the centre, shrinks to a slice and
        // fades; a card that becomes a hit grows back out of that same place.
        x: rowCard.matched ? panel.tileX(rowCard.rel)
          : Math.round(panel.centerX - panel.sliceW / 2)
        y: rowCard.matched ? panel.tileY(rowCard.rel) : 0
        width: rowCard.matched ? (rowCard.selected ? panel.bigW : panel.sliceW) : panel.sliceW
        height: rowCard.matched ? (rowCard.selected ? panel.bigH : panel.sliceH) : panel.sliceH
        z: rowCard.matched ? (rowCard.selected ? 100 : 60 - Math.min(Math.abs(rowCard.rel), 30)) : 10
        // While a family is open its child deck owns the space below; the
        // slices stay put and fade back rather than popping out, so a later
        // selection still has a card to grow from.
        opacity: !rowCard.matched ? 0 : rowCard.selected ? 1 : (panel._expanded ? 0.25 : 0.9)

        Behavior on x {
          enabled: MotionPolicy.enabled && panel._settled
          Glide { duration: Ui.slowMs }
        }
        Behavior on y {
          enabled: MotionPolicy.enabled && panel._settled
          Glide { duration: Ui.slowMs }
        }
        Behavior on width {
          enabled: MotionPolicy.enabled && panel._settled
          Glide { duration: Ui.slowMs }
        }
        Behavior on height {
          enabled: MotionPolicy.enabled && panel._settled
          Glide { duration: Ui.slowMs }
        }
        Behavior on opacity {
          enabled: MotionPolicy.enabled
          Glide { duration: Ui.fastMs }
        }

        Rectangle {
          id: rowFrame

          anchors.fill: parent
          radius: RoundingPolicy.radius
          color: rowCard.primary && rowCard.primary.colors
            ? (rowCard.primary.colors.background || "#141414")
            : "#141414"
          border.width: rowCard.selected && panel._isActiveRow(rowCard.modelData) ? 2 : 1
          border.color: rowCard.selected && panel._isActiveRow(rowCard.modelData)
            ? Ui.solid("accent")
            : Ui.tint("background_3", 1)
          clip: true

          // A preview is laid out once at the big card's size and then
          // cover-scaled into the frame. A card growing out of a slice
          // therefore scales a finished skeleton instead of reflowing every
          // bar inside it, which is the jump the resize used to cause.
          Item {
            id: rowShot

            anchors.fill: parent
            anchors.margins: rowFrame.border.width
            clip: true

            // A filtered-out card keeps its preview while it fades, but an
            // inactive variant owns none: the model is wide enough to hold
            // every variant without paying for every skeleton all the time.
            Loader {
              anchors.fill: parent
              active: rowCard.matched || rowCard.opacity > 0.01
              sourceComponent: rowPreview
            }

            Component {
              id: rowPreview

              Item {
                anchors.fill: parent
                clip: true

                readonly property real fit: Math.max(
                  width / Math.max(1, panel.bigW),
                  height / Math.max(1, panel.bigH))

                ThemePreview {
                  width: panel.bigW
                  height: panel.bigH
                  x: Math.round((parent.width - width) / 2)
                  y: Math.round((parent.height - height) / 2)
                  scale: parent.fit
                  colors: rowCard.primary && rowCard.primary.colors ? rowCard.primary.colors : ({})
                  light: rowCard.primary ? rowCard.primary.light : false
                }
              }
            }
          }
        }

        MouseArea {
          anchors.fill: parent
          enabled: rowCard.matched
          onClicked: mouse => {
            const folder = panel._folderOf(rowCard.modelData)
            const selected = rowCard.selected
            const slot = rowCard.slot
            focusCtrl.grabList()
            // Apply the card that was clicked, not whatever the deck has
            // re-selected by the time the focus handoff finishes. A family
            // card has no folder of its own and still goes through the
            // expand/apply path.
            if (!selected) panel.selectRow(slot)
            else if (folder !== "") ThemePicker.apply(folder)
            else panel.activateCurrent()
          }
        }
      }
    }

    // ---- the opened family: a second deck below the parent ---------------
    Repeater {
      model: panel._expanded && panel.family ? panel.variants : []

      delegate: Item {
        id: variantCard

        required property var modelData
        required property int index

        readonly property int rel: variantCard.index - panel.variantIndex
        readonly property bool selected: variantCard.rel === 0
        readonly property bool open: panel._variantOpen && panel._settled

        x: variantCard.open
          ? panel.variantTileX(variantCard.rel)
          : Math.round(panel.centerX - panel.vBigW / 2)
        y: variantCard.open
          ? Math.round(panel.bigH + panel.vGap + panel.variantTileY(variantCard.rel))
          : Math.round(panel.bigH * 0.55)
        width: variantCard.selected ? panel.vBigW : panel.vSliceW
        height: variantCard.selected ? panel.vBigH : panel.vSliceH
        opacity: variantCard.open ? (variantCard.selected ? 1 : 0.9) : 0
        z: variantCard.selected ? 50 : 40 - Math.min(Math.abs(variantCard.rel), 20)

        Behavior on x {
          enabled: MotionPolicy.enabled && panel._settled
          Glide { duration: Ui.slowMs }
        }
        Behavior on y {
          enabled: MotionPolicy.enabled && panel._settled
          Glide { duration: Ui.slowMs }
        }
        Behavior on width {
          enabled: MotionPolicy.enabled && panel._settled
          Glide { duration: Ui.slowMs }
        }
        Behavior on height {
          enabled: MotionPolicy.enabled && panel._settled
          Glide { duration: Ui.slowMs }
        }
        Behavior on opacity {
          enabled: MotionPolicy.enabled
          Glide { duration: Ui.fastMs }
        }

        Rectangle {
          id: variantFrame

          anchors.fill: parent
          radius: RoundingPolicy.radius
          color: variantCard.modelData.colors && variantCard.modelData.colors.background
            ? variantCard.modelData.colors.background
            : "#141414"
          // Same frame rule as the main deck: the selected card is already
          // the big one, so the accent border means only one thing here -this
          // is the theme currently applied.
          border.width: panel._isActiveFolder(variantCard.modelData.folder) ? 2 : 1
          border.color: panel._isActiveFolder(variantCard.modelData.folder)
            ? Ui.solid("accent")
            : Ui.tint("background_3", 1)
          clip: true

          Item {
            id: variantShot

            anchors.fill: parent
            anchors.margins: variantFrame.border.width
            clip: true

            readonly property real fit: Math.max(
              variantShot.width / Math.max(1, panel.vBigW),
              variantShot.height / Math.max(1, panel.vBigH))

            ThemePreview {
              width: panel.vBigW
              height: panel.vBigH
              x: Math.round((variantShot.width - width) / 2)
              y: Math.round((variantShot.height - height) / 2)
              scale: variantShot.fit
              colors: variantCard.modelData.colors || ({})
              light: variantCard.modelData.light
            }
          }
        }

        MouseArea {
          anchors.fill: parent
          onClicked: {
            focusCtrl.grabList()
            if (variantCard.selected) ThemePicker.apply(String(variantCard.modelData.folder ?? ""))
            else panel.moveVariant(variantCard.rel)
          }
        }
      }
    }
  }

  Column {
    id: caption

    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: stage.bottom
    anchors.topMargin: Ui.m
    // Screen-based, not card-based: the caption's implicit height feeds the
    // deck's vertical budget, so a width tied to bigW would make the budget
    // depend on the deck it is sizing. A wider strip also keeps long family
    // labels readable.
    width: Math.min(900, Math.max(0, panel.width - 2 * Ui.outerPad))
    visible: panel.filteredRows.length > 0
    opacity: panel._fade ? 1 : 0

    Behavior on opacity {
      enabled: MotionPolicy.enabled
      Glide { duration: Ui.fastMs }
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: panel._displayLabel()
      color: panel.focusedTheme && panel._isActiveFolder(panel.focusedTheme.folder)
        ? Ui.solid("accent")
        : Ui.solid("foreground_0")
      font.pixelSize: Ui.fontCardTitle
      font.family: Ui.fontFamily
      font.bold: true
      elide: Text.ElideMiddle
      textFormat: Text.PlainText
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: panel._meta()
      color: Ui.tint("foreground_1", 0.65)
      font.pixelSize: Ui.fontS
      font.family: Ui.fontFamily
      elide: Text.ElideRight
      textFormat: Text.PlainText
    }
  }

  EmptyState {
    anchors.centerIn: parent
    width: Math.max(0, panel.width - 64)
    visible: panel.rows.length === 0 || panel.filteredRows.length === 0
    opacity: panel._fade ? 1 : 0
    text: panel.rows.length === 0 ? "Loading themes" : "No matching themes"
    iconName: "theme"
    iconColorKey: "foreground_1"
    iconSize: 112
    iconOpacity: 0.5
    textSize: Math.round(Ui.fontCardTitle * 1.5)
    maxTextWidth: 560
  }

  // The field owns the caret, so it also owns Left/Right for text editing.
  // Up/Down and Tab/Backtab still walk the deck; NavKeys maps them here.
  function handleSearchNavigation(k) {
    const open = panel._expanded && panel.family
    if (k === Qt.Key_Tab || k === Qt.Key_Down) {
      if (open) panel.moveVariant(1)
      else panel.moveRow(1)
    } else if (k === Qt.Key_Backtab || k === Qt.Key_Up) {
      if (open) panel.moveVariant(-1)
      else panel.moveRow(-1)
    }
  }

  function escapeSearch() {
    if (panel.query !== "") {
      themeSearch.clear()
      focusCtrl.grabList()
      return
    }
    focusCtrl.grabList()
    if (panel._expanded && panel.family) panel.collapseVariants()
    else ThemePicker.close()
  }

  InputField {
    id: themeSearch

    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    anchors.topMargin: panel.searchTop
    width: Math.min(360, Math.max(0, panel.width - 2 * Ui.outerPad))
    height: Ui.filterH
    z: 200
    visible: panel.rows.length > 0
    opacity: panel._fade ? 1 : 0
    inputRole: "search"
    // The deck keeps keyboard focus while filtering, so the field's own
    // activeFocus never lights up. A live query is the same engaged state.
    engaged: panel.query !== ""
    forwardNavigation: true
    placeholder: "Search themes..."
    onNavigationRequested: (key, modifiers) => panel.handleSearchNavigation(key)
    onAccepted: {
      panel.activateCurrent()
      focusCtrl.grabList()
    }
    onEscaped: panel.escapeSearch()
    onFocusedChanged: focusCtrl.mode = themeSearch.focused ? "filter" : "list"

    Behavior on opacity {
      enabled: MotionPolicy.enabled
      Glide { duration: Ui.fastMs }
    }
  }

  function _key(name, color) {
    return "<font color=\"" + color + "\">" + name + "</font>"
  }
  function _legend() {
    const accent = Ui.solid("accent")
    const open = panel._expanded && panel.family
    const nav = panel._key("←/→", accent) + " · " + panel._key("Tab", accent)
      + (open ? " variants" : " themes")
    const decide = panel.family && !open
      ? " · " + panel._key("Enter", accent) + " / " + panel._key("Space", accent) + " expand"
      : " · " + panel._key("Enter", accent) + " / " + panel._key("Space", accent) + " apply"
    const back = open ? " · Esc back" : " · Esc close"
    return nav + decide + back
  }

  Text {
    id: footer

    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Ui.outerPad * 2
    width: Math.max(0, panel.width - 2 * Ui.outerPad)
    horizontalAlignment: Text.AlignHCenter
    opacity: panel._fade ? 1 : 0
    text: panel._legend()
    color: Ui.tint("foreground_1", 0.7)
    font.pixelSize: Ui.fontL
    font.family: Ui.fontFamily
    elide: Text.ElideRight
    textFormat: Text.StyledText

    Behavior on opacity {
      enabled: MotionPolicy.enabled
      Glide { duration: Ui.fastMs }
    }
  }
}
