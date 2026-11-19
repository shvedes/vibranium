pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import qs.features.menu
import "MenuLib.js" as MenuLib
import "../../common/text/Format.js" as Format
import "../../common/math/Range.js" as Range

// Single ListView delegate covering every row type. One flat declarative
// tree: types are mutually exclusive, so per-type blocks bind `visible`.
//
// LAYOUT LAW (violating this made labels vanish once):
// a width must never depend on a parent that sizes itself from that same
// child. Horizontal extents come from ANCHORS or explicit numbers only.
// Positioner children carry no anchors; hidden trail members collapse to
// zero width.
//
// DESIGN RULES (user directives):
// - Plain entries everywhere. Selects expand into an inline dropdown of
//   OptionRow boxes - arrows drive the cursor, Enter picks. A group row
//   unfolds the same way over whole entries (GroupRow), so a nested family
//   of toggles is one row on the page. Numbers and
//   ranges show just their value - +/- keys and the wheel adjust, Enter
//   opens the numeric editor.
// - Selection background switches INSTANTLY; rows do not paint hover
//   fills (a parked pointer would leave ghost tints behind keyboard
//   navigation).
// - Sharp corners across the whole module, toggles included.
// - Shared chrome comes from qs.ui (Toggle, Notice, BodyText, Divider,
//   IconButton); menu-specific editors live beside this file.
Item {
  id: row
  // SPLIT MAP (one owner each, no behavior change): row types live
  // behind expLoader (Toggle/Select/Stepper/Text/Option views in the
  // expansion shell) while the main line stays inline - Toggle pill,
  // Select label, Stepper value/seek, Text value, Option chevron.
  // Type predicates (isToggle/isSelect/hasStepper/isText) are the
  // contract both halves read; nothing else in this file names a type.

  // Model-injected identity: the row record plus its row position. A
  // ScriptModel exposes exactly one role and it is the whole record, so
  // `modelData` IS the row and the panel hands it to `itm` - there is no
  // wrapper to unwrap and no `key` role to declare (it would have no
  // source, and a `required` property with no source is a hard "Cannot
  // create delegate"). Required so handlers inside this file can resolve
  // both under Bound behavior.
  required property var modelData
  required property int index

  // Normalized item payload; a search index entry when searchResult.
  property var itm: null
  property bool sel: false
  property bool searchResult: false

  // --- type helpers ---
  readonly property string ptype: itm && itm.type === "separator"
    ? "separator" : searchResult ? "result" : (itm ? itm.type : "")
  readonly property bool isSep: ptype === "separator"
  readonly property bool isToggle: ptype === "toggle"
  readonly property bool isSelect: ptype === "select"
  readonly property bool isActionSelect: isSelect && itm && itm.var === ""
    && (itm.onSelect !== "" || itm.onCall !== "")
  readonly property bool isOption: ptype === "option"
  readonly property bool isNumber: ptype === "number"
  readonly property bool isRange: ptype === "range"
  readonly property bool isText: ptype === "text"
  readonly property bool isSubmenu: ptype === "submenu"
  readonly property bool isExpandable: ptype === "expandable"
  readonly property bool isGroup: ptype === "group"
  readonly property bool infoOnly: itm && itm.infoOnly === true
  readonly property bool hasStepper: isNumber || isRange

  // The choices the open dropdown shows: a flow stage's own list while that
  // stage renders, else the row's declared options. Every reader below - the
  // seed, the stepper, the picker and the dropdown's own layout - goes through
  // this one property, so a stage declaring options cannot be sized from the
  // parent row's list.
  readonly property var optionList: {
    const stage = row.isFlow ? row.flowStep : null
    const declared = stage && stage.options !== undefined ? stage.options
      : (itm && itm.options !== undefined && itm.options !== null ? itm.options : [])
    if (Array.isArray(declared)) return declared
    return declared && declared.length !== undefined
      ? Array.prototype.slice.call(declared) : []
  }
  // Left/Right pages the inline dropdown by this stride, which the
  // library derives from the option count; a single-column dropdown has
  // no stride (0 = key falls through).
  readonly property int optionCount: row.optionList.length
  // Repeated option values share one stored value, but only the first row is
  // the choice. Marking every twin paints several accents for one selection.
  readonly property int chosenIndex: {
    if (itm && itm.marker === false) return -1
    if (!st || st.value === undefined || st.value === null) return -1
    const value = String(st.value)
    for (let i = 0; i < optionList.length; i++) {
      const opt = optionList[i]
      if (opt && String(opt.value ?? "") === value) return i
    }
    return -1
  }
  readonly property int optionColumnStride: MenuLib.optionColumnStride(optionCount)
  // Two ownership chains meet at a group row. It owns its children and their
  // nested dropdowns recursively, each with its own cursor and bar. The list
  // owns only the page row: one reveal claim and one card resize, fed by this
  // row's settled height. A child's background is drawn by its parent group's
  // bar, which tracks the child's live geometry.
  // Child rows of a group row. The row set is a projection that converts role
  // payloads and can drop a nested array, so the live page item is resolved by
  // uid the way a flow row's stages are - uids always survive the mirror.
  readonly property var groupSource: {
    Menu.rev
    if (!row.isGroup || searchResult || !itm) return null
    if (Menu.traceEnabled && nested) Menu.trace("grp.source", {
      id: String(itm.id ?? ""), uid: String(itm.uid ?? ""), nested: nested,
      kids: Array.isArray(itm.children) ? itm.children.length : -1,
      type: String(itm.type ?? "")
    })
    if (itm.uid) {
      const pristine = Menu.itemByUid(itm.uid)
      if (pristine && pristine.type === "group" && Array.isArray(pristine.children))
        return pristine
    }
    // A group nested inside another group is not a page row, so itemByUid
    // cannot resolve it. Its own normalized record carries children.
    return itm.type === "group" && Array.isArray(itm.children) ? itm : null
  }
  // The children the dropdown lists. A child carrying its own `when` (a bar
  // module that does not exist on this chassis) is a gated row like any other,
  // so it is left out while its verdict is false instead of being offered as a
  // switch that does nothing. rev is read because a guard batch answers later.
  readonly property var groupChildren: {
    Menu.rev
    const src = row.groupSource
    if (!src || !Array.isArray(src.children)) return []
    const kids = src.children
    // Under the "/" filter the group stays on the page when one of its
    // descendants matched. Narrow the child list to the branches that matched
    // instead of flattening them into page rows: the child is then drawn by
    // this dropdown, on its own bar and background. A group whose OWN label
    // matched keeps its whole subtree (it is not in `trimmed`).
    const scoped = Menu.scopedActive
    const trimmed = scoped
      && Menu.scopedTrimmedGroups[String(src.uid ?? "")] === true
    const visible = scoped ? Menu.scopedVisibleUids : null
    const out = []
    for (let i = 0; i < kids.length; i++) {
      const kid = kids[i]
      if (!kid) continue
      // A provider marker expands to a surface-owned live row set (fonts).
      // Resolved inside this binding so a scan landing later re-renders it.
      if (kid.type === "provider") {
        const rows = Menu.providerFontRows(kid)
        for (let r = 0; r < rows.length; r++) out.push(rows[r])
        continue
      }
      if (trimmed && visible[String(kid.uid ?? "")] !== true) continue
      // Only a child with a guard of its own is asked: an ungated child is
      // always usable, and a provider's `visible` predicate describes a page
      // row, not a switch inside a dropdown.
      const gated = (typeof kid.when === "string" && kid.when.trim() !== "")
        || (kid.requires !== undefined && kid.requires !== null)
      if (gated && Menu.isUnavailable(kid)) continue
      out.push(kid)
    }
    return out
  }
  readonly property bool hasGroup: row.groupChildren.length > 0
  // Of an open chain, only the deepest group is where the cursor lives. An
  // ancestor with an open child group is a level already passed through, so
  // its chevron reads idle while the current one keeps the accent.
  function isCurrentOpenGroup() {
    const kid = row._focusedChildRow()
    return isGroup && dropdownOpen && (!kid || !kid.isGroup || !kid.dropdownOpen)
  }
  readonly property bool currentOpenGroup: row.isCurrentOpenGroup()
  // A group's own slot hosts the children's rows. While any child slot is
  // live, the group's height follows that geometry without a second ease.
  readonly property bool nestedSlotLive: {
    const view = row._groupView
    const rep = view && view.childrenRepeater
    if (!rep) return false
    for (let i = 0; i < rep.count; i++) {
      const item = rep.itemAt(i)
      const kid = item && item.liveRow
      if (kid && (kid.expanded || kid.infoOpen || kid.slotMotionMs > 0)) return true
    }
    return false
  }
  readonly property bool hasEditor: hasStepper || isText

  // A nested row is the same row type drawn one register smaller under a
  // parent group entry. Every view, state write and animation below is the
  // page row's; only the register shrinks, and the host owns the push that
  // reveals the slots instead of the card resizing for them.
  property bool nested: false
  // Page rows are depth 0; each group's children load one level deeper. The
  // cursor fill alternates on this parity so nested levels read apart.
  property int nestedDepth: 0
  readonly property real titleFontPx: nested ? Ui.fontM : Ui.fontL
  readonly property real valueFontPx: nested ? Ui.fontXs : Ui.fontS
  readonly property real iconBox: nested ? Ui.childIconW : Ui.rowIconW
  readonly property real barWidth: nested ? Math.round(Ui.barW * 0.6) : Ui.barW
  readonly property real barGap: nested ? Ui.s : Ui.barGap
  readonly property real chevronWidth: nested ? 12 : Ui.chevronW
  // The host reads this to grow its selection bar and push the neighbours.
  readonly property real nestedSlotH: descSlot.height + expandSlot.height
  // Breathing room below an open slot, scaled by the slot's live height. The
  // full pad is owed once the slot has grown past it and retracts with the
  // fold, so the row's height stays continuous across both edges. Reading
  // `open` here wrote the whole pad in one frame at unfold and removed it in
  // one frame at fold while the slot was still at full height; every scroll
  // consumer of the row, chiefly the close-seat tracking, read that step as
  // motion and answered it with its own one-frame seat.
  readonly property real dropdownPad: Ui.dropdownBarPad * Range.clamp01(
    Math.max(descSlot.height, expandSlot.height) / Ui.dropdownBarPad)
  onHeightChanged: if (Menu.traceEnabled)
    Menu.trace("entry.rowH", {
      id: String(itm?.id ?? ""), h: Math.round(height * 10) / 10,
      y: Math.round(y * 10) / 10, closing: row._shellClosing
    })
  // The bar grows by the slots' OWN height from the row's rest height. A
  // slot's y is its anchor below mainLine and carries a Ui.m margin the
  // compact row does not; including that margin in the bar height puts the
  // bar above its seat while the slot closes. Height stays continuous to
  // zero and covers the copy: the slot's bottom gap counts toward it.
  readonly property real nestedBarH: {
    let bottom = staticRowH
    if (descSlot.height > 0) bottom = Math.max(bottom, staticRowH + descSlot.height)
    if (expandSlot.height > 0) bottom = Math.max(bottom, staticRowH + expandSlot.height)
    return bottom
  }
  readonly property real nestedSettledBarH: {
    let bottom = staticRowH
    if (descSlot.settledH > 0) bottom = Math.max(bottom, staticRowH + descSlot.settledH)
    if (expandSlot.settledH > 0) bottom = Math.max(bottom, staticRowH + expandSlot.settledH)
    return bottom
  }
  readonly property int nestedSlotMs: Math.max(descSlot.slotMs, expandSlot.slotMs)
  signal activated()
  // Emitted when this row's slots come to rest, including at the end of a close.
  // A host uses it to release the service's per-row close latch.
  signal slotMotionEnded()
  // Emitted at the start of a slot fold. The panel rides the list's scroll
  // back to the reveal origin on this edge so the two motions land together.
  signal slotCloseStarted()

  // Free-text prompt hosted inside a select row's expansion: picking the
  // dropdown option whose value matches editValue swaps the dropdown for
  // the text editor (prefilled with editText) instead of closing the
  // menu. Enter commits through editCall and keeps the menu open;
  // Escape or any collapse clears the mode back to the dropdown.
  property bool promptOpen: false

  // Staged-flow cursor (spec 39). Null-flow rows ignore it and keep the
  // promptOpen path. Flow rows read the current step kind from
  // MenuLib.flowStep(itm, flowIndex) and render exactly one stage.
  // Source healing: the ListModel mirror converts role payloads on store
  // and may drop nested descriptors, so when the delegate copy arrives
  // without flow the pristine page item is resolved by uid (uids always
  // survive the mirror). Search hits stay plain (flowSrc null there).
  readonly property var flowSrc: {
    Menu.rev
    if (searchResult || !itm) return null
    if (MenuLib.isFlow(itm)) return itm
    const pristine = Menu.itemByUid(itm.uid)
    if (pristine && MenuLib.isFlow(pristine)) return pristine
    return null
  }
  readonly property bool isFlow: row.flowSrc !== null
  readonly property int flowIndex: {
    Menu.rev
    return itm && itm.uid ? Menu.flowIndexOf(itm) : 0
  }
  readonly property var flowStep: row.flowSrc ? MenuLib.flowStep(row.flowSrc, row.flowIndex) : null
  readonly property string flowKind: row.flowStep ? String(row.flowStep.kind) : ""

  // --- shared state ---
  readonly property var st: {
    Menu.rev
    return searchResult || !itm ? null : Menu.stateOf(itm)
  }
  // A row that cannot be used right now (see Menu.isUnavailable): drawn under
  // a mute box, skipped by the cursor, inert. rev and condRev are read so a
  // guard verdict, a dead link or a store write re-answers this binding - none
  // of them changes the row set.
  readonly property bool unavailable_: {
    Menu.condRev
    Menu.rev
    return itm && !searchResult ? Menu.isUnavailable(itm) : false
  }
  readonly property bool enabled_: itm && !searchResult
    ? itm.enabled !== false && !Menu.isDisabled(itm) && !row.unavailable_ : true

  // Expansion (editors / info body) syncs imperatively from the service
  // store: rev bumps re-apply the canonical value immune to delegate
  // lifecycle churn. The property exists to raise on_RevEchoChanged; it has no
  // other reader.
  property int _revEcho: Menu.rev

  on_RevEchoChanged: {
    syncExpanded()
    if (!row.dropdownOpen) return
    const optList = row.optionList
    if (optList.length === 0) {
      row.optionIndex = -1
      return
    }
    if (row.optionIndex < 0) row.optionIndex = MenuLib.optionSeedIndex(optList, row.optionSeed())
    else row.optionIndex = Range.clamp(row.optionIndex, 0, optList.length - 1)
  }
  Component.onCompleted: {
    syncExpanded()
  }

  function syncExpanded() {
    if (!itm || searchResult) return
    const stNow = Menu.stateOf(itm)
    row.expanded = stNow.expanded === true
    row.infoOpen = stNow.info === true
  }

  // For editors; info-only rows expand into the body view. Selects
  // expand into their inline dropdown.
  property bool expanded: false
  // Generic staged confirmation (replaces per-service timerStage etc.)
  property int confirmStage: 0
  readonly property var confirm: Menu.confirmFor(itm)
  // Key-triggered deletion (Delete / Ctrl+D, routed from the panel):
  // reuses the confirm slot with a confirm object synthesized from
  // delCommand, so regular activation keeps its own behavior (select
  // dropdowns, editors, actions) and only Delete/Ctrl+D arms this path.
  property bool deleteArmed: false
  readonly property var deleteConfirm: itm && typeof itm.delCommand === "string" && itm.delCommand !== ""
    ? {
        stages: 2,
        hint: "Press Delete again to remove this timer",
        armed: "<b><u>Press Delete again to confirm removal</u></b>",
        label: "Remove timer"
      } : null
  readonly property var activeConfirm: row.deleteArmed ? row.deleteConfirm : row.confirm

  // Universal ctrl+i channel: the description dropdown. Independent of
  // `expanded` so a collapsed row can preview its description.
  property bool infoOpen: false

  // Description OWNERSHIP - the single source of truth for who renders
  // the description. An expanded row always shows it inside the
  // expansion shell (behind the hairline next to options/editor/body);
  // a collapsed row shows it in the standalone ctrl+i slot below the
  // line. Exactly one owner at any moment - renderers below only read
  // these flags, the rule lives nowhere else.
  readonly property bool descInShell: expanded
  readonly property bool descInSlot: infoOpen
    && (descText !== "" || warnText !== "")
    && !descInShell

  // Transient validation message shown under the editor; fades like the
  // info body does.
  property string editorError: ""

  function clearEditorError() {
    editorError = ""
  }

  function showEditorError(msg) {
    editorError = msg
    // 3s base, +1s per additional 5 words - verbose messages linger.
    const words = String(msg).trim().split(/\s+/).filter(w => w !== "").length
    errorClear.interval = 3000 + Math.floor(words / 5) * 1000
    errorClear.restart()
  }

  Timer {
    id: errorClear

    // Interval is computed per message in showEditorError(); this
    // declaration only exists so restart() has a target.

    onTriggered: row.editorError = ""
  }
  readonly property bool confirmOpen: row.activeConfirm !== null && expanded
  readonly property bool dropdownOpen: row.confirmOpen ? false
    : row.isFlow ? (expanded && row.flowKind === "select")
    : row.isGroup ? (expanded && row.hasGroup)
    : (isSelect && expanded && !row.promptOpen)
  readonly property bool editorOpen: row.confirmOpen ? false
    : row.isFlow ? (expanded && (row.flowKind === "number"
      || row.flowKind === "range" || row.flowKind === "text"))
    : ((hasEditor || row.promptOpen) && expanded)

  // Dropdown cursor; -1 closed. Starts on the stored choice so Enter-
  // Enter re-picks it without touching the arrows.
  property int optionIndex: -1

  // Group dropdown cursor; -1 closed. A group lists its children in one
  // column, so the cursor is the child the arrows and Enter act on.
  property int childIndex: -1
  // The live group component, while it is loaded. Keys that land on an open
  // child dropdown are delegated to that child's own row.
  property var _groupView: null
  property int _prevChildIndex: -1
  // The expansion shell survives the close ease. The slot's closing flag is
  // set from its own change handler, so a latch at row level keeps the loader
  // alive across that turn and keeps the last view key when the host rebuilds.
  readonly property bool _shellClosing: descSlot.closing || expandSlot.closing
  // `expanded` drops before the slot publishes `closing`, so `active` built
  // from those two alone goes false for one turn at the close edge. The loader
  // then tears down and rebuilds its view: the options flash empty and fade in
  // again while the card is folding. Keep it alive from the first open until
  // the slot's own terminal edge instead.
  property bool _expLoaderKeep: false
  // One shell build per open. A second build at the close edge is the flash
  // the loader latch exists to prevent.
  property int debugExpBuilds: 0
  Connections {
    target: expLoader
    function onItemChanged() { if (expLoader.item) row.debugExpBuilds++ }
  }
  Connections {
    target: expandSlot
    function onCloseFinished() { row._expLoaderKeep = false }
  }
  property int _lastStageKey: -1
  // Full height of the expansion copy while it is open. The fade keeps this
  // denominator through the close, when the copy unloads and the live height
  // collapses to the editor alone.
  property real _shellContentH: 0
  // Geometry published for the frame probe: the row's line stack and the
  // expansion slot it unfolds under, for gap and bar coverage checks.
  property alias debugMainLine: mainLine
  // A nested row's line stack is centred in its compact rest height, so the
  // rest box ends ABOVE where a Ui.m anchor margin would put a slot. Split
  // that margin: anchor at the rest box, carry the remainder as the slot's
  // top gap. The slot then starts and ends inside the row's rest-height
  // claim, leaving equal space above the copy and below it.
  readonly property real nestedSlotLead: Math.max(0,
    staticRowH - mainLine.y - mainLine.height)
  readonly property real nestedSlotTopGap: Math.max(0, Ui.m - nestedSlotLead)
  readonly property real debugSlotY: expandSlot.y
  readonly property real debugSlotH: expandSlot.height
  readonly property real debugEditorH: expLoader.item && expLoader.item.debugEditorHost
    ? expLoader.item.debugEditorHost.height : 0
  readonly property string debugGhostLabels: expLoader.item
    && expLoader.item.debugEditorHost
    ? expLoader.item.debugEditorHost.debugGhostLabels : ""

  // A guard landing (or a store write) can remove a child under the cursor;
  // the index then points past the end, so it retreats to the last child.
  onGroupChildrenChanged: {
    const kids = row.groupChildren.length
    const trimmed = Menu.scopedActive && row.isGroup
      && Menu.scopedTrimmedGroups[String(groupSource?.uid ?? "")] === true
    if (trimmed && row.dropdownOpen) {
      // The filter narrowed this group's children to the matching branches.
      // Seed the cursor on one of those children: otherwise the group is open
      // with a stale -1 cursor, no child delegate and no focus bar, and the
      // trim reads as a naked list of options with no dropdown behind it.
      let seat = -1
      for (let i = 0; i < kids; i++) if (_childSeatOk(i)) { seat = i; break }
      if (seat >= 0) { row.childIndex = seat; return }
    }
    if (row.childIndex >= kids) {
      let seat = -1
      for (let i = kids - 1; i >= 0; i--) {
        if (_childSeatOk(i)) { seat = i; break }
      }
      row.childIndex = seat
    }
  }

  // A nested description belongs to the child under the cursor, not to the
  // group row. Panel-side closeTrailingInfo only sees page rows, so arrows, a
  // click on another child, or collapsing the group have to fold any child
  // slot left open themselves. Keyed on childIndex so every path is covered.
  onChildIndexChanged: {
    const target = row.childIndex
    const outgoing = row._prevChildIndex
    row._prevChildIndex = target
    Menu.trace("grp.child", {
      idx: target, outgoing: outgoing,
      extra: row._groupView ? Math.round(row._groupView.liveExtra * 10) / 10 : 0,
      slotMs: row.slotMotionMs
    })
    // The outgoing child is folded in THIS turn. The deferred sweep below
    // talks to the model and cannot run inside the rev that changed the
    // cursor; its delegate is a fixed index, so reading it does not
    // re-evaluate groupChildren. A deferred fold paints the outgoing
    // description over the row the cursor holds.
    if (outgoing >= 0 && outgoing !== target) {
      const rep = row._groupView ? row._groupView.childrenRepeater : null
      const prev = rep ? rep.itemAt(outgoing) : null
      const kid = prev && prev.liveRow ? prev.liveRow.itm : null
      Menu.trace("grp.outgoing", {
        idx: outgoing, rep: !!rep, prev: !!prev, kid: !!kid,
        info: !!kid && Menu.infoOpen(kid), expanded: !!kid && Menu.isExpanded(kid)
      })
      if (kid) {
        if (Menu.infoOpen(kid)) Menu.setInfo(kid, false)
        if (Menu.isExpanded(kid)) Menu.setExpanded(kid, false)
      }
    }
    // Deferred: this handler can fire while groupChildren is re-evaluating off
    // rev, and a synchronous state write there closes the loop back onto it.
    Qt.callLater(function() {
      if (row.childIndex !== target) return
      const kids = row.groupChildren
      for (let i = 0; i < kids.length; i++) {
        if (i === target) continue
        const kid = kids[i]
        if (kid && Menu.infoOpen(kid)) Menu.setInfo(kid, false)
        // A nested editor or dropdown is modal for its own child: leaving that
        // child folds it, so re-seating it later opens a fresh row, not a state
        // remembered from the last visit.
        if (kid && Menu.isExpanded(kid)) Menu.setExpanded(kid, false)
      }
    })
  }

  // The value the dropdown cursor should open on. Flow rows seed from the
  // stored stage value so Back lands on the picked option; plain rows seed
  // from live state. `st` can be null (search hits, or a row with no state
  // yet) and a null seed is the library's own decline, so the cursor falls to
  // the first option rather than to no option at all.
  function optionSeed() {
    if (row.isFlow) {
      const stored = Menu.flowValuesOf(row.itm)[String(row.flowIndex)]
      if (stored !== undefined) return stored
    }
    return row.st ? row.st.value : undefined
  }

  // The group cursor only seats on children a keyboard user may act on: a
  // guarded-disabled or unavailable child stays listed but is skipped, the
  // same way List.move skips non-selectable page rows.
  function _childSeatOk(index) {
    const kids = row.groupChildren
    if (index < 0 || index >= kids.length) return false
    const kid = kids[index]
    return !!kid && kid.selectable === true && kid.enabled !== false
      && !Menu.isDisabled(kid) && !Menu.isUnavailable(kid)
  }
  function _firstChildSeat() {
    const kids = row.groupChildren.length
    for (let i = 0; i < kids; i++) if (_childSeatOk(i)) return i
    return -1
  }
  function _nextChildSeat(from, direction) {
    const kids = row.groupChildren.length
    for (let n = 1; n <= kids; n++) {
      const idx = ((from + direction * n) % kids + kids) % kids
      if (_childSeatOk(idx)) return idx
    }
    return from
  }

  onDropdownOpenChanged: {
    if (!dropdownOpen) return
    if (row.isGroup) {
      row.childIndex = _firstChildSeat()
      return
    }
    const optList = row.optionList
    optionIndex = optList.length === 0
      ? -1 : MenuLib.optionSeedIndex(optList, row.optionSeed())
  }

  // --- payload views ---
  readonly property string displayLabel: itm ? String(itm.label ?? "") : ""
  readonly property string previewFontFamily: itm && typeof itm.previewFontFamily === "string" ? itm.previewFontFamily : ""
  // Leading accent word for the sub line (timer commands): plain text in,
  // accent element out, rendered AHEAD of the muted copy. Static per row
  // (rows rebuild wholesale on data changes); the muted copy keeps its
  // own live rule below.
  readonly property string subLead: itm && typeof itm.subLead === "string" ? itm.subLead : ""
  // Trailing accent word for the sub line ("active"): plain text in, a
  // dedicated accent element out - deliberately markup-free, so no
  // escaping is ever needed and the sanitizer stays out of it.
  // Flow rows may override it per stage (stage subAccent wins while its
  // step renders); rev capture makes the swap live on stage changes.
  // Gated on expanded: collapsed rows always show the top-level copy.
  readonly property string subAccent: {
    Menu.rev
    const stage = MenuLib.stageText(row.expanded, row.flowStep, "subAccent")
    if (stage !== null && stage !== "") return stage
    return itm && typeof itm.subAccent === "string" ? itm.subAccent : ""
  }
  // Search hits carry their breadcrumb ("root > section > page").
  // rev capture keeps payload strings (section counts mutate in place)
  // live without any model churn.
  // Flow rows may override the sub per stage: a declared stage sub (even
  // "") wins over provider and top-level while its step renders, so the
  // wizard narrates each input; rev capture flips it on stage changes.
  // Gated on expanded: collapsed rows always show the top-level copy.
  readonly property string subText: {
    if (searchResult) {
      // Search rows keep their own copy: the group header above names the
      // breadcrumb, so repeating it under every row would restate the
      // section once per entry. Single-page hits have no path to
      // show and keep the same fallback.
      Menu.rev
      const sov = Menu.subFor(itm)
      if (sov !== "") return sov
      return String(itm?.sub ?? "")
    }
    Menu.rev
    const stage = MenuLib.stageText(row.expanded, row.flowStep, "sub")
    if (stage !== null) return stage
    const ov = Menu.subFor(itm)
    if (ov !== "") return ov
    return String(itm?.sub ?? "")
  }
  // Flow rows may override the description per stage, same rule as sub.
  readonly property string descText: {
    Menu.rev
    const stage = MenuLib.stageText(row.expanded, row.flowStep, "desc")
    if (stage !== null) return stage
    return String(itm?.desc ?? "")
  }
  // Flow rows may override the warning per stage, like sub and desc, so a
  // stage can put a message box in the expansion shell and change its height.
  readonly property string warnText: {
    Menu.rev
    const stage = MenuLib.stageText(row.expanded, row.flowStep, "warning")
    if (stage !== null) return stage
    return String(itm?.warning ?? "")
  }
  readonly property string bodyText: String(itm?.body ?? "")
  // Active marker. A guard expression is one source for it (Menu.isChecked
  // over the batched bash verdicts); `active` is the data-driven one, set
  // by a service that tracks the state in JS instead of evaluating a shell
  // condition. The rev capture re-runs the binding when such a service
  // re-stamps the flag in place, which a plain property read cannot see.
  readonly property bool mark: {
    Menu.rev
    if (searchResult || !itm) return false
    return Menu.isChecked(itm) || itm.active === true
  }
  // The group path a search separator names, "" for a bare hairline.
  // Plain breadcrumb text ("a > b"), rendered in the sub-line register.
  readonly property string sepLabel: row.isSep ? String(itm?.label ?? "") : ""
  // Per-row line registers. Copy the primary face covers rests on the
  // compact token; copy that reaches a fallback face takes the taller one.
  // The panel's model-side estimate uses the same rule, so the card and the
  // delegate agree about the row's height.
  readonly property real labelLineH: row.isSep ? 0
    : nested ? RowGeometry.childLabelLineH
    : RowGeometry.labelHFor(row.displayLabel)
  readonly property real subLineH: row.isSep
    ? RowGeometry.subHFor(row.sepLabel)
    : RowGeometry.subHFor(RowGeometry.subSampleFor(itm, row.subText))
  readonly property real staticRowH: row.isSep ? 0
    : nested ? RowGeometry.childRestH(row.restKind)
    : RowGeometry.restHFor(row.restKind, row.labelLineH, row.subLineH)
  // The separator's rest height, from the shared row rule (RowGeometry): the
  // breadcrumb's pinned line plus its breathing, or the bare hairline. A
  // newborn delegate reports this before its own Text polishes because the
  // number is the shared line token rather than this row's laid-out text.
  readonly property real sepH: !row.isSep ? 0
    : nested ? RowGeometry.childRestSeparator(row.sepLabel !== "")
    : RowGeometry.restSeparatorFor(row.sepLabel !== "", row.subLineH)
  readonly property string iconName: itm ? String(itm.icon ?? "") : ""
  // The emoji the row stands for, painted in the icon slot when the row
  // declares no icon NAME. Carried by the emoji picker's bundle as `glyph`
  // (MenuLib's default for the field).
  //
  // An icon NAME wins: a row carrying both is asking for the named icon, and
  // the glyph is a preview of the value rather than a second icon.
  //
  // `glyph` ONLY - never the row's `value`, which on a number/text/select row
  // is its live content ("Add timer" carries the starting minute) and would
  // paint that value as a preview beside a label already naming the row. A
  // grid cell can afford to derive its glyph from `value`, because there the
  // cell shows the glyph INSTEAD of a label; a list row shows both.
  readonly property string glyphText: {
    if (iconName !== "") return ""
    const g = itm && itm.glyph !== undefined && itm.glyph !== null
      ? String(itm.glyph) : ""
    return g
  }
  readonly property bool hasIconSlot: row.iconName !== "" || row.glyphText !== ""
  // The swatch columns name the record directly as well as through `itm`,
  // because `itm` is a settable alias and a caller that hands this row a
  // normalized payload of its own (a search index entry) is not obliged to
  // have carried the palette into it.
  readonly property var palette: itm && itm.palette ? itm.palette
    : (modelData && modelData.palette ? modelData.palette : [])
  // Swatch gate -> the palette Repeater reads this, so rows without swatches
  // instantiate no dot delegates.
  readonly property bool hasPalette: !!(itm && itm.palette && itm.palette.length > 0)

  // --- numeric views ---
  readonly property real minimum: itm ? Number(itm.min) : 0
  readonly property real maximum: itm ? Number(itm.max) : 100
  readonly property real stepSize: itm && Number(itm.step) > 0 ? Number(itm.step) : 1
  readonly property int decimals: itm ? MenuLib.decimalsOf(itm.step) : 0
  readonly property real numericValue: {
    const v = Number(st ? st.value : NaN)
    return isNaN(v) ? minimum : v
  }
  readonly property string unitSuffix: MenuLib.unitSuffix(itm ? itm.unit : "")
  readonly property string numericDisplay:
    MenuLib.numberDisplay(Menu.displayFor(itm), numericValue, decimals, unitSuffix)
  // Progress rows carry their fill in progressValue (0-100) rather than
  // the editable value slot.
  readonly property real ratio: ptype === "progress"
    ? MenuLib.clamp(Number(itm ? itm.progressValue : 0) / 100, 0, 1)
    : MenuLib.clamp((numericValue - minimum)
      / Math.max(0.000001, maximum - minimum), 0, 1)

  // Toggle state: fully reactive via Menu helper (core-backed for caffeine)
  readonly property bool toggleOn: {
    Menu.rev
    return Menu.isToggleOn(itm) && row.isToggle
  }

  // Provider icon accent (caffeine's red slash while active): fully
  // reactive via Menu helper, like toggleOn above. Rows without a
  // provider resolve to "" and stay monochrome.
  readonly property string iconAccentKey: {
    Menu.rev
    return Menu.iconAccentFor(itm)
  }
  // Memoized provider value-active flag -> the stepper value Text reads
  // this twice (color + bold), so one rev-keyed dispatch feeds both and
  // rendering stays identical.
  readonly property bool valueActive: {
    Menu.rev
    return Menu.isValueActive(itm)
  }

  // Select current option label.
  readonly property string selectLabel: !isSelect || !st ? ""
    : (Menu.rev, MenuLib.optionLabelFor(itm.options ?? [], st.value))

  // --- select value swap ---
  // The right-hand value of a select does not trade places in one frame
  // (selectGhost and selectSwap below): the label that is leaving the
  // slot is remembered here, because the binding that just moved no
  // longer holds it and the live Text already carries the new one. Blank
  // until a label has been on screen, so a delegate's first layout is a
  // plain fill and never a swap.
  property string _selShown: ""
  // How far each half travels: a little over one line of the value font,
  // so the outgoing label clears the slot as the incoming one lands.
  readonly property real selectRise: 14

  // --- geometry ---
  //
  // The rest height is RowGeometry's rule applied to the row's KIND, never to
  // its text: the panel sizes the card from the model with the same rule,
  // before this delegate exists, so the two cannot disagree about a string one
  // of them shaped. Slots are the only thing that moves a live row off it.
  // Which of the three resting shapes this row is: a theme row spends its
  // second line on the swatch strip, a row with any sub-line copy spends it on
  // that line, and everything else is one line. The gate is the COPY itself -
  // an empty Text draws no line, and a pinned one must not be allowed to claim
  // one it does not draw.
  // The row's rest shape, from MenuLib's rule - the same call MenuPanel makes
  // for the card's estimate. It reads the copy this row RENDERS (subText),
  // which already carries the provider override, so classifying a row costs no
  // provider call beyond the one the sub line itself makes.
  readonly property string restKind: MenuLib.restKind(itm, row.subText)
  // The second line is spent when the kind says so. A pinned line box cannot
  // answer this (a Text that held copy and was cleared reports its old line
  // until the next layout pass), and a measured copy disagreed with the card
  // the moment the row was classified from copy the delegate had not laid out.
  readonly property bool hasSubLine: row.restKind === "sub"
  width: ListView.view ? ListView.view.width : 240
  // Progress bars and range tracks live INLINE in the trail cluster, so
  // every row keeps the same height as its neighbors.
  // In nested mode the slots are overlays: the host grows its selection bar
  // and pushes the neighbours, so this box stays at the row's rest height.
  height: isSep ? sepH : row.nested ? row.staticRowH
    : row.staticRowH + descSlot.height + expandSlot.height
      // A page group's dropdown is drawn by the list's selection bar, which
      // runs to the row's full bottom. Nested dropdowns stop Ui.m short of
      // their slot's bottom, so reserve the same visual breathing below the
      // slot here: otherwise the parent box hugs its last child while every
      // nested box has a clear gap, and the even ramp breaks at the top.
      // dropdownPad carries that breathing on the slot's own clock.
      + dropdownPad
  // Guard-disabled rows and types the menu cannot act on fade alike; an
  // unavailable row keeps its contrast and is muted by its mute box instead.
  opacity: itm && !searchResult && (Menu.isDisabled(itm)
    || row.unavailable_ || itm.enabled === false) ? 0.4 : 1
  readonly property real labelWidth: labelCol.width
  property alias debugValueText: valueText
  property alias debugLabelCol: labelCol
  // What this row's own left side needs: the label, or the sub line when it
  // is the wider of the two (with its lead and tail beside it). Compared
  // against labelWidth this is the elision verdict for the row - the card
  // is sized by MenuPanel's width pass, and the two have to agree to the
  // pixel for nothing here to clip.
  readonly property real labelNeeded: Math.max(lbl.implicitWidth,
    subMain.implicitWidth
      + (subLeadEl.implicitWidth > 0 ? subLeadEl.implicitWidth + subRow.spacing : 0)
      + (subTail.implicitWidth > 0 ? subTail.implicitWidth + subRow.spacing : 0))
  readonly property bool textElided: labelCol.width + 0.5 < labelNeeded
  // True while the card is between two widths (MenuPanel's width glide).
  // The row animates nothing of its own accord here: the card is the thing
  // moving, and the row's copy rides it.
  property bool cardSettling: false
  // How much of this row's copy the card can show RIGHT NOW, 1 at rest.
  //
  // While the card grows, the widest line on the page does not fit for the
  // first half of the glide, and an elided sub read as a stutter: the
  // ellipsis was there for ~90ms and then was not, once per row, on every
  // navigation into a wider page. So during the glide the copy is painted
  // whole and clipped at the column (a left-anchored reveal) and fades in
  // with the space it has, and the ellipsis returns the moment the card is
  // done - where it is still needed for copy that genuinely does not fit.
  //
  // Rests at 1 whatever the card is doing, so a card that is too narrow for
  // a row at rest elides exactly as before: this is the glide, not the fit.
  readonly property real textReveal: cardSettling && labelNeeded > 0
    ? Range.clamp01(labelCol.width / labelNeeded) : 1
  readonly property real descSlotH: descSlot.height
  // How long this row's slots take, for anything that has to move in step with
  // them - the card's own resize, chiefly (MenuPanel's slot region).
  //
  // LATCHED, and that is the whole point. Each slot derives its duration from
  // its measured content (DropdownSlot.slotMs), so the figure only exists once
  // the content has laid out, and it is GONE the moment the content unloads -
  // which is what happens on close, one tick after the close ease starts. Read
  // live, this published 200ms while a slot was opening and 120ms (the
  // floor, an empty content) while the same slot was closing, so a consumer
  // that resized the card in step with the row ran the two directions of ONE
  // motion on two different clocks. Traced: an open armed at 200ms and its
  // collapse at 120ms.
  //
  // So the row publishes the largest duration it has seen for the unfold in
  // progress, and holds it until every slot is closed. Monotonic on purpose:
  // a duration may only be measured upwards, never downwards, because the only
  // thing that can make it smaller is the content going away - which is the
  // end of the motion, not a new one.
  property int _slotMsLatch: 0
  readonly property int slotMotionMs: Math.max(_slotMsLatch,
    row.isGroup && row._focusedChildRow()
      ? row._focusedChildRow().nestedSlotMs : 0)

  // Called from the slots' open/closing transitions. Re-samples every time a
  // slot starts or stops, and takes the max, so the latch is the largest
  // figure any live slot has offered during this unfold.
  function _latchSlotMs() {
    const live = descSlot.open || descSlot.closing
      || expandSlot.open || expandSlot.closing
    Menu.trace("entry.latch", {
      id: String(itm?.id ?? ""), nested: nested, live: live,
      dOpen: descSlot.open, dClosing: descSlot.closing,
      eOpen: expandSlot.open, eClosing: expandSlot.closing,
      dH: Math.round(descSlot.height * 10) / 10,
      eH: Math.round(expandSlot.height * 10) / 10,
      ms: Math.max(descSlot.slotMs, expandSlot.slotMs)
    })
    if (!live) {
      row._slotMsLatch = 0
      row.slotMotionEnded()
      // The held verdict belongs to the unfold that is over. Releasing here
      // rather than on the next open is what lets a dropdown that does NOT
      // resize the region animate normally on the next keystroke: the hold is
      // a property of one unfold, not of the row, and `release()` clears the
      // gate the Behaviors actually read.
      descSlot.release()
      expandSlot.release()
      return
    }
    const now = Math.max(descSlot.slotMs, expandSlot.slotMs)
    if (now > row._slotMsLatch) row._slotMsLatch = now
  }

  // This unfold resizes the region, and the region resize is not animated.
  //
  // Panel-side slot claim (see MenuPanel.expansionNeedH).
  readonly property real expandSlotH: expandSlot.height
  // Collapse progress of the expansion slot: 1 while open, easing to 0 as
  // the slot folds. The dropdown body already fades on this ratio; the
  // nested cursor bars ride it too, so they fade out with the content they
  // belong to instead of blinking off on the frame `dropdownOpen` flips.
  readonly property real expandFade: Range.clamp01(
    expandSlot.height / Math.max(1, expandSlot._settledHLatch))
  // Where this row lands once its slots finish unfolding, known from the
  // moment they open. The list's reveal reads this (List.rowSettledHeight)
  // so a dropdown on the last row is scrolled into view in ONE ease that
  // runs alongside the slot's own, instead of being chased frame by frame
  // - chasing it decelerates to a stop at each handover and lurches on.
  readonly property real restHeight: isSep ? sepH : row.staticRowH
  // The open slot's bottom gap is counted in its own height, but the row's
  // rendered box also carries the list's row gap below it: the live row ends
  // one Ui.s past the sum of its parts. Leaving that out made every open row
  // publish a settled height 8px short of its own live height, so the list
  // seated to the short value and made a visible second scroll to catch up.
  readonly property real settledHeight: isSep ? sepH
    : restHeight + descSlot.settledH + expandSlot.settledH
      + ((descSlot.settledH + expandSlot.settledH > 0) ? Ui.s : 0)

  // --- uniform API used by the panel ---

  // Right-click: close an open dropdown, otherwise navigate back one
  // level (pop; at root this closes the menu).
  function rightClick() {
    if (dropdownOpen) {
      collapse()
      return
    }
    if (!searchResult && Menu.stack.length > 1) Menu.pop()
    else Menu.close()
  }

  function activate() {
    if (!enabled_) return
    // An open editor owns activation: Enter or a click commits its value.
    // Falling through to the type switch would call openEditor() again and
    // toggle the slot shut, reading as an Escape the user never pressed.
    if (editorOpen && commitOpenEditor()) return
    // The host seats its cursor on the child whose row activated, so a click
    // and Enter take the same path through the group as through the page.
    row.activated()
    const _wasFiltered = Menu.scopedActive
    try {
      // Generic staged confirmation (timer, recording, clearHistory and any
      // future JSON-declared `confirm`).
      const cf = row.confirm
      if (cf) {
        if (cf.action === "clearHistory") {
          const has = Registry.get("appLauncher", "hasUsageHistory")
          if (has === false) return
        }
        if (!row.expanded) {
          row.setExpanded(true)
          row.confirmStage = 1
        } else if (row.confirmStage < cf.stages) {
          row.confirmStage = cf.stages
        } else {
          Menu.handleConfirm(itm)
          row.confirmStage = 0
          row.collapse()
          if (itm && itm.close === true) Menu.close()
        }
        return
      }
      switch (ptype) {
        case "submenu": {
          const pushPanel = Menu.probeSource
          if (pushPanel && typeof pushPanel.pushPage === "function") pushPanel.pushPage(itm.page)
          else Menu.push(itm.page)
          break
        }
        case "toggle":
          flip(!toggleOn)
          if (itm && itm.close === true) Menu.close()
          break
        case "action":
          if (itm && itm.id === "timer.stop") {
            Menu.handleConfirm({ id: "timer" })
            return
          }
          if (itm.call !== "")
            Menu.runCall(itm.call, itm.value !== undefined ? itm.value : "")
          else
            Menu.runCommand(itm.command, itm.value !== undefined ? itm.value : "")
          // keepOpen: the row summons something in place (a picker page
          // pushed onto this stack, a refresh) and the menu must survive
          // so Esc can walk back - the classic close would kill the chain
          // the summon was made from.
          if (!(itm && itm.keepOpen === true)) Menu.close()
          break
        case "select":
          setExpanded(!expanded)
          break
        case "option":
          Menu.commitOption(itm)
          break
        case "range":
        case "number":
        case "text":
          openEditor()
          break
        case "expandable":
          if (!row.infoOnly && (bodyText !== "" || descText !== "")) setExpanded(!expanded)
          break
        case "group":
          setExpanded(!expanded)
          break
        case "result":
          if (itm) {
            const panel = Menu.probeSource
            if (panel && typeof panel.consumePendingResult === "function") {
              panel.pendingResult = itm
              Qt.callLater(panel.consumePendingResult)
            } else {
              Menu.jumpTo(itm.pageId, itm.row)
            }
          }
          break
      }
    } finally {
      if (_wasFiltered && Menu.scopedActive) {
        if (Menu.panel) Menu.panel._scopedClearByAction = true
        Menu.clearScoped()
      }
    }
  }

  function flip(state) {
    if (!itm) return
    // Both routes to a toggle land here - the row's own activation and the
    // pill's click - so this is the only place that sees either, and the
    // only place that can report one exactly once.
    // The same DEBUG line as a staged choice, for the same reason: a toggle
    // flip is a state change, and the state change itself is already
    // reported by whoever consumes it - a setting write prints
    // "shell.wallpaper.enabled updated to false", and that is the line worth
    // reading. "Show wallpaper chosen in General checked=true" restates it
    // one step earlier and says less.
    const _wasFiltered = Menu.scopedActive
    try {
      if (Menu.handleToggle(itm, state)) return
      const guarded = typeof itm.checked === "string" && itm.checked !== ""
      if (guarded) {
        // Literal/mirror toggle: stamp the requested state so the pill
        // flips instantly, then reconcile against reality via a guard
        // re-evaluation (which overwrites guardChecked with the actual
        // result of the action). No session/store write happens.
        Menu.setGuardChecked(itm, state)
        if (itm.onToggle) Menu.runCommand(itm.onToggle, state)
        Menu.refreshGuards()
      } else {
        // var-bound toggles (settings) have no onToggle - they persist
        // through the store. Literal toggles need an onToggle.
        if (itm.var === "" && !itm.onToggle) return
        Menu.setChecked(itm, state)
        if (itm.onToggle) Menu.runCommand(itm.onToggle, state)
      }
    } finally {
      if (_wasFiltered && Menu.scopedActive) {
        if (Menu.panel) Menu.panel._scopedClearByAction = true
        Menu.clearScoped()
      }
    }
  }

  function setExpanded(value) {
    if (!itm || searchResult) return
    Menu.setExpanded(itm, value)
  }

  function _focusedChildRow() {
    const view = row._groupView
    const item = view && view.cursorItem
    return item && item.liveRow ? item.liveRow : null
  }

  function collapse() {
    // A child's editor or dropdown is a row of its own: folding the group
    // folds whichever nested one is open with it.
    const view = row._groupView
    if (view) {
      const kids = view.childrenRepeater
      for (let i = 0; i < kids.count; i++) {
        const item = kids.itemAt(i)
        if (item && item.liveRow && item.liveRow.expanded) item.liveRow.collapse()
      }
    }
    Menu.clearDescendantState(itm)
    setExpanded(false)
    optionIndex = -1
    row.childIndex = -1
    row.confirmStage = 0
    row.deleteArmed = false
    row.promptOpen = false
    if (row.isFlow && itm) Menu.resetFlow(itm)
  }

  // Drive the select value swap. Called from selectText's own text
  // change: the outgoing label is what the slot was showing, the
  // incoming one is already in the live Text. A first fill (blank before)
  // and a slot that renders nothing (action-select) swap plain.
  function onSelectValueChanged() {
    const incoming = selectText.text
    const outgoing = row._selShown
    row._selShown = incoming
    if (outgoing === "" || incoming === "") return
    // The slot's own visibility is the single source for when it carries
    // a value at all, so the guard reads it rather than repeating the rule.
    if (!selectText.visible) return
    if (!MotionPolicy.enabled) return
    // The leaving layer picks up exactly where the live one stands, so a
    // change landing mid-swap hands the motion over instead of
    // restarting it from the slot's rest position.
    selectGhost.text = outgoing
    selectGhost.opacity = selectText.opacity
    ghostRise.from = liveShift.y
    ghostFade.from = selectGhost.opacity
    liveShift.y = row.selectRise
    selectText.opacity = 0
    selectSwap.restart()
  }

  // Delete / Ctrl+D from the panel: open (or advance) the staged
  // deletion confirmation for rows that declare a delCommand, mirroring
  // the generic confirm flow in activate(). The final stage runs the
  // delCommand template; the menu stays open and the owning service
  // re-composes its page.
  function requestDelete() {
    if (!enabled_ || !itm || row.deleteConfirm === null) return
    // Armed from the first key: even an already-expanded row (open
    // dropdown) swaps its expansion to the deletion confirmation.
    row.deleteArmed = true
    if (!row.expanded) {
      row.setExpanded(true)
      row.confirmStage = 1
    } else if (row.confirmStage < row.deleteConfirm.stages) {
      row.confirmStage = row.deleteConfirm.stages
    } else {
      const dc = String(itm.delCommand ?? "")
      row.confirmStage = 0
      row.deleteArmed = false
      row.collapse()
      if (dc !== "")
        Menu.runCommand(dc, itm.value !== undefined ? String(itm.value) : "")
    }
  }

  // Panel-driven dropdown navigation; returns true when consumed.
  function moveOption(direction) {
    if (row.isGroup) {
      // An open child slot owns the arrows, the way a page row's own dropdown
      // does: moving to a neighbour while one is open would close it mid-move
      // and leave a stale bar. A child dropdown takes the arrow into its own
      // option cursor; an editor keeps the key for its field.
      const childRow = row._focusedChildRow()
      if (childRow && childRow.expanded) {
        if (childRow.dropdownOpen && childRow.moveOption(direction)) return true
        return true
      }
      const kids = row.groupChildren.length
      // A direction of 0 is a page key that has no column to page to: leave it
      // for the row's own step handling.
      if (!row.dropdownOpen || kids === 0 || direction === 0) return false
      const base = row.childIndex < 0 ? (direction > 0 ? -1 : kids) : row.childIndex
      row.childIndex = _nextChildSeat(base, direction)
      return true
    }
    const opts = row.optionList
    if (!dropdownOpen || opts.length === 0) return false
    // A dropdown that has just been opened (or whose cursor was cleared)
    // starts with no option selected (-1). Stepping from -1 must land on
    // the first option going forward and on the last going back, mirroring
    // List.move's unseated-cursor handling - otherwise Tab from -1 lands
    // on the first option but Shift-Tab lands on the pre-last one.
    let base = optionIndex
    if (base < 0) base = direction > 0 ? -1 : opts.length
    optionIndex = ((base + direction) % opts.length + opts.length) % opts.length
    return true
  }

  function commitOpenEditor() {
    if (!editorOpen) return false
    const shell = expLoader.item
    if (shell && typeof shell.commitNow === "function") {
      shell.commitNow()
      return true
    }
    return false
  }

  function pickCurrent() {
    if (!dropdownOpen || !itm) return false
    if (row.isGroup) {
      const childRow = row._focusedChildRow()
      if (childRow && childRow.dropdownOpen) return childRow.pickCurrent()
      if (!childRow || row.childIndex < 0) return false
      // The child's own row owns the activation, so a select opens its
      // options, a number opens its editor, and a toggle flips in place.
      childRow.activate()
      return true
    }
    const opts = row.optionList
    if (optionIndex < 0 || optionIndex >= opts.length) return false
    pick(opts[optionIndex].value)
    return true
  }

  // Swap this select row's dropdown for a free-text field (prompt mode).
  // Nothing is persisted here - the option that leads here only asks for
  // text; the editor's Enter commits through editCall.
  function openEditPrompt() {
    if (!itm || !row.isSelect || !enabled_) return
    optionIndex = -1
    row.promptOpen = true
    Menu.setExpanded(itm, true)
    // Focus must land without waiting for the watchdog tick, or early
    // keystrokes leak into the query instead of the field.
    Qt.callLater(grabEditorFocus)
  }

  // Advance one flow stage. Select stages store the picked value, editor
  // stages store the committed text/number. Last stage falls through to
  // the row's normal commit (pick/commitEditor with the accumulated
  // flowValues attached).
  function advanceFlow(value) {
    const src = row.flowSrc
    if (!src || !itm) { return false }
    Menu.setFlowValue(itm, row.flowIndex, value)
    // One read of the stage map: the skip rule weighs every stored value,
    // and the row must not re-read controller state per candidate stage.
    const next = MenuLib.nextFlowIndex(src, row.flowIndex + 1,
      Menu.flowValuesOf(itm))
    if (next >= MenuLib.flowCount(src)) { return false }
    Menu.setFlowIndex(itm, next)
    const upcoming = MenuLib.flowStep(src, next)
    // Option cursor re-seeds on dropdown entry (see onDropdownOpenChanged);
    // editor focus lands via the same path as openEditor().
    Qt.callLater(grabEditorFocus)
    return true
  }

  function backFlow() {
    if (!row.isFlow || row.flowIndex <= 0) return false
    Menu.setFlowIndex(itm, row.flowIndex - 1)
    Qt.callLater(grabEditorFocus)
    return true
  }

  // Seeded number for flow number/range stages: the stored stage value
  // when parseable, else the stage's own declared value, else the row
  // value. One place feeds both the picker's value and its seed text, so
  // Back-restored input and first-open defaults always agree (and the seed
  // text below can pair the value with the STAGE suffix - the row-level
  // display uses the top-level unit, which one-shot rows like Add timer do
  // not declare).
  function flowSeedNumber() {
    if (row.isFlow && (row.flowKind === "number" || row.flowKind === "range")) {
      const raw = Menu.flowValuesOf(itm)[String(row.flowIndex)]
      if (raw !== undefined) {
        const n = Number(String(raw).trim().split(/\s+/)[0])
        if (!isNaN(n)) return n
      }
      // The stage's own value, read live rather than through the row state:
      // a row's state is seeded once per menu session, so a page republished
      // while it is open (idle timers deleted) would keep the old suggested
      // minute from its first render.
      const stage = row.flowStep
      if (stage && stage.value !== undefined) {
        const n = Number(stage.value)
        if (!isNaN(n)) return n
      }
    }
    return row.numericValue
  }

  function pick(value) {
    const _wasFiltered = Menu.scopedActive
    try {
      if (row.isFlow && row.flowKind === "select") {
        if (row.advanceFlow(value)) { return }
        // Last select stage: fall through to the normal commit below
        // with the accumulated values available via Menu.flowValuesOf.
      }
      // Prompt option (free text inside the dropdown): open the editor
      // in place instead of committing + closing. The daemon only hears
      // about it when the editor's Enter runs editCall.
      if (itm && itm.editValue !== undefined
          && String(value) === String(itm.editValue)) {
        row.openEditPrompt()
        return
      }
      const isAction = row.isActionSelect
      collapse()
      // Settings selects: no-op if same value to avoid redundant IO.
      // Action-selects (recording) must always fire, even if picking the
      // same label again (e.g. Screen when value already "screen").
      if (!isAction && st && String(st.value) === String(value)) return
      Menu.setValue(itm, value)
      if (isAction) {
        if (itm && itm.keepOpen) {
          // keepOpen action-select (idle timers): the pick has no
          // capture UI behind it, so only the dropdown collapses - the
          // menu stays open and the call fires in place.
          if (itm.onCall !== "") Menu.runCall(itm.onCall, value)
          else Menu.runCommand(itm.onSelect, value)
        } else {
          // Action-select (recording): close menu first so capture UIs
          // like `slurp` don't composite over the still-visible layer.
          Menu.close()
          Qt.callLater(() => itm.onCall !== ""
            ? Menu.runCall(itm.onCall, value)
            : Menu.runCommand(itm.onSelect, value))
        }
      } else {
        if (itm.onCall !== "") Menu.runCall(itm.onCall, value)
        else Menu.runCommand(itm.onSelect, value)
      }
    } finally {
      if (_wasFiltered && Menu.scopedActive) {
        if (Menu.panel) Menu.panel._scopedClearByAction = true
        Menu.clearScoped()
      }
    }
  }

  function toggleInfo() {
    if (!itm || searchResult) return
    // A group's dropdown holds whole rows: ctrl+i addresses the child under
    // the cursor, so its description unfolds inside the parent's dropdown.
    if (row.isGroup && row.dropdownOpen && row.childIndex >= 0) {
      const kid = row.groupChildren[row.childIndex]
      if (!kid) return
      const desc = String(kid.desc ?? "")
      const warn = String(kid.warning ?? "")
      if (desc === "" && warn === "") return
      Menu.setInfo(kid, !Menu.infoOpen(kid))
      return
    }
    if (descText === "" && warnText === "") return
    // An expanded row already renders its description in-shell; there
    // is nothing for ctrl+i to toggle without stacking a second copy.
    if (row.descInShell) return
    Menu.setInfo(itm, !Menu.infoOpen(itm))
  }

  function stepBy(direction) {
    if (!hasStepper || !enabled_) return
    if (Menu.isNumberActive(itm)) return
    let next = MenuLib.clamp(numericValue + direction * stepSize,
      minimum, maximum)
    next = MenuLib.quantize(next)
    if (next === numericValue) return
    Menu.setValue(itm, next)
    if (Menu.handleNumberChange(itm, next)) return
    Menu.runCommand(itm.onChange, Format.fixed(next, decimals) + unitSuffix)
  }

  function openEditor() {
    if (!hasEditor || !enabled_) return
    Menu.setValue(itm, isText ? String(st.value ?? "") : numericValue)
    setExpanded(true)
    // Focus must land without waiting for the expansion to settle, or
    // early keystrokes leak into the query instead of the field. The
    // editor-open signal below completes what this fast path misses.
    Qt.callLater(grabEditorFocus)
  }

  // Sub copy updates instantly with no slide or fade: live countdowns
  // re-evaluate every second and any motion would replay on each tick.
  function grabEditorFocus() {
    if (!editorOpen) return
    const shell = expLoader.item
    if (shell && shell.takeFocus) shell.takeFocus()
  }

  function commitEditor(text) {
    if (row.isFlow && (row.flowKind === "text" || row.flowKind === "number"
        || row.flowKind === "range")) {
      if (row.advanceFlow(String(text))) return
      row.commitFlow()
      return
    }
    // Prompt mode on a select row: the field holds free text for the
    // editCall template. An empty commit quietly closes - the row keeps
    // its prior action/command. The Registry hub passes multi-word
    // values as one argument, so quotes and spaces stay intact.
    if (row.promptOpen) {
      const pt = String(text).trim()
      row.promptOpen = false
      collapse()
      if (pt !== "" && itm && itm.editCall !== undefined && itm.editCall !== "")
        Menu.runCall(itm.editCall, pt)
      return
    }
    if (isText) {
      const t = String(text).trim()
      // Settings-backed text (var): persist directly, honoring allowEmpty
      // (e.g. shell.statusbar.networkRightClick). Non-setting text (action)
      // keeps the clear-then-run behavior.
      if (itm && itm.var !== undefined && itm.var !== "") {
        Menu.setValue(itm, t)
        if (t !== "" && itm.onSubmit) Menu.runCommand(itm.onSubmit, t)
        collapse()
        return
      }
      // An action text row with no command has nothing to run: the typed text
      // is the value, so keep it in state instead of clearing it on commit.
      if (itm && itm.onSubmit) {
        Menu.setValue(itm, "")
        Menu.runCommand(itm.onSubmit, t)
      } else {
        Menu.setValue(itm, t)
      }
      collapse()
      return
    }
    // Erased everything -> silent discard: close without applying.
    if (String(text).trim() === "") {
      collapse()
      return
    }
    const typed = MenuLib.leadingNumber(text)
    // Unsupported data silently restores the current actual value and
    // keeps the editor open for another try.
    if (typed === null) {
      Menu.setValue(itm, numericValue)
      Qt.callLater(grabEditorFocus)
      return
    }
    let next = MenuLib.quantize(MenuLib.clamp(typed, minimum, maximum))
    // Unchanged values close without firing onChange — unless the
    // entry has an onChange command (e.g. timer start) that should
    // fire on every commit.
    if (next === numericValue) {
      if (Menu.handleNumberChange(itm, next)) { collapse(); closeIfArmed(); return }
      if (itm.onChange && itm.onChange !== "")
        Menu.runCommand(itm.onChange, Format.fixed(next, decimals) + unitSuffix)
      collapse()
      return
    }
    Menu.setValue(itm, next)
    if (Menu.handleNumberChange(itm, next)) { collapse(); closeIfArmed(); return }
    Menu.runCommand(itm.onChange, Format.fixed(next, decimals) + unitSuffix)
    collapse()
  }

  // Final flow commit: dispatches through the row's existing verbs so
  // guards/Registry/IPC see exactly what a single-type row would send.
  // Select-last flows use onCall/onSelect with the last value; editor-last
  // flows use onChange/onSubmit/editCall with the last text. The full
  // stage map stays readable via Menu.flowValuesOf(itm) for services
  // that need every step (Idle add-wizard in spec 40).
  function commitFlow() {
    const src = row.flowSrc
    if (!itm || !src) { collapse(); return }
    const vals = Menu.flowValuesOf(itm)
    if (typeof Menu.handleFlow === "function"
      && Menu.handleFlow(src, vals)) { collapse(); return }
    const lastIdx = MenuLib.flowCount(src) - 1
    const last = vals[String(lastIdx)]
    const text = last !== undefined ? String(last) : ""
    collapse()
    if (itm.onCall !== "") Menu.runCall(itm.onCall, text)
    else if (itm.onSelect !== "") Menu.runCommand(itm.onSelect, text)
    else if (itm.onChange !== "") Menu.runCommand(itm.onChange, text)
    else if (itm.editCall !== "") Menu.runCall(itm.editCall, text)
    else if (itm.onSubmit !== "") Menu.runCommand(itm.onSubmit, text)
    closeIfArmed()
  }

  // Provider/type rows that opt into `"close": true` dismiss the whole
  // menu once their commit lands (timer start mirrors the action-select
  // close: no capture UI should appear over the layer). Toggles honor
  // the same flag in activate(); number commits land here.
  function closeIfArmed() {
    if (itm && itm.close === true) Menu.close()
  }

  // --- visuals ---

  Rectangle {

    anchors.fill: parent
    visible: !row.isSep
    // Always transparent: the ListView sliding highlight bar paints the
    // selection behind the rows (see MenuPanel list highlight). Fading
    // this rect instead blended mid-tones over the card and flashed.
    // Keyboard/click cursor only - no hover tints.
    color: "transparent"
  }

  // A labeled separator breaks the hairline around its text instead of
  // covering a full-width line with an opaque chip. The text then sits on
  // whatever the surface behind it is - card or dropdown - with no fill of
  // its own, so it cannot read as a dimmer patch inside the dropdown.
  // The chip starts half a spacing unit left of the entries' own edge,
  // putting the text flush with entry labels; the line fills the rest.
  Divider {
    anchors.verticalCenter: parent.verticalCenter
    // Labeled: the line starts only after the text, so nothing paints under
    // the label. Unlabeled: the bare full-bleed line from the original.
    anchors.left: row.sepLabel !== "" ? sepChip.right : parent.left
    anchors.right: parent.right
    anchors.leftMargin: row.sepLabel !== "" ? 0 : Ui.m + 2
    anchors.rightMargin: Ui.m + 2
    visible: row.isSep
  }

  Item {
    id: sepChip

    visible: row.isSep && row.sepLabel !== ""
    anchors.left: parent.left
    anchors.leftMargin: Ui.m - Ui.s / 2
    anchors.verticalCenter: parent.verticalCenter
    width: sepText.width + Ui.s
    height: sepText.height

    Text {
      id: sepText

      anchors.left: parent.left
      anchors.leftMargin: Ui.s / 2
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, row.width - 2 * (Ui.m + 2) - Ui.s)
      height: row.subLineH
      verticalAlignment: Text.AlignVCenter
      text: row.sepLabel
      // Entry-title tone, bold: the group header reads as a title row
      // rather than a second text tone beside the rows.
      color: Ui.solid("foreground_0")
      font.pixelSize: Ui.fontXs
      font.family: Ui.fontFamily
      font.bold: true
      elide: Text.ElideRight
      textFormat: Text.PlainText
    }
  }

  MouseArea {

    anchors.fill: parent
    // A muted conditional row is inert: it must not even take the cursor on a
    // click, or the bar would sit on a row that cannot be activated.
    enabled: !row.isSep && row.enabled_
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: mouse => {
      if (mouse.button === Qt.RightButton) {
        row.rightClick()
        return
      }
      // An explicit click takes the selection with it.
      const view = row.ListView.view
      if (view && !row.isSep && row.itm && view.currentIndex !== row.index)
        view.currentIndex = row.index
      row.activate()
    }
  }

  // No wheel on a row. The menu is keyboard-only, so a scroll over a stepper
  // row no longer moves its value: the wheel is the one input a menu refuses,
  // all the way down to the rows.

  // --- main line: icon | label | trail cluster ---

  Item {
    id: mainLine

    visible: !row.isSep
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Ui.m
    anchors.rightMargin: Ui.m
    anchors.top: parent.top
    // A compact row rests at rowMinH, whose slack is larger than the line
    // stack's padding: a fixed top margin would seat the title high. Centre
    // the stack in the rest height at that register; the page register keeps
    // its pinned padding.
    anchors.topMargin: row.nested
      ? Math.max(0, Math.round((row.staticRowH - labelColH) / 2)) : Ui.rowPadV
    // Synchronous line-stack height. ListView displaces neighbors during
    // incremental inserts using creation-time geometry, but a Column only
    // reports its height after its first polish pass - one frame late,
    // which made revealed rows overlap the entry under them by exactly
    // the missing delta. The stack is RowGeometry's, so the number exists at
    // creation; the Column below remains THE layout - it settles to this same
    // number a frame later, and the panel's model-side estimate is the same
    // rule asked about the row record.
      readonly property int labelColH: row.nested
        ? RowGeometry.childColH(row.restKind)
        : RowGeometry.colHFor(row.restKind, row.labelLineH, row.subLineH)

    height: labelColH

    Icon {
      id: iconImg

      visible: row.iconName !== ""
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      size: row.iconBox
      name: row.iconName
      // The glyph stays in the ordinary foreground so the swatch strip below
      // - painted in the theme's real colors - is the only place color is
      // sampled.
      colorKey: "foreground_0"
      accentKey: row.iconAccentKey
    }

    // The glyph half of the icon slot: the emoji itself, for a row that
    // declares no icon name (the emoji picker's rows). It occupies the same
    // Ui.rowIconW box the Icon does, so a row with either one lays out
    // identically and the label column starts at the same edge.
    //
    // Pinned to the color emoji font, for the reason GridCell gives: the
    // glyph is one emoji codepoint, so a direct family hit avoids the
    // fallback scan across every installed font that shaping it under the UI
    // font pays on first use. Sized to the slot rather than the row, so a
    // tall keyword label beside it does not scale the emoji with it.
    Text {

      visible: row.glyphText !== ""
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: row.iconBox
      height: row.iconBox
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      text: row.glyphText
      color: Ui.solid("foreground_0")
      font.pixelSize: Math.round(row.iconBox * 0.86)
      font.family: "Noto Color Emoji"
      textFormat: Text.PlainText
      // A flag is several codepoints (the tag sequence) and can outrun the
      // slot; eliding keeps it inside the reserved box rather than letting it
      // push the label column.
      elide: Text.ElideRight
    }

    Column {
      id: labelCol

      anchors.left: row.hasIconSlot ? iconImg.right : parent.left
      anchors.leftMargin: row.hasIconSlot ? Ui.s : 0
      anchors.right: row.isRange ? seekBar.left
        : row.ptype === "progress" ? progressBar.left
        : row.isToggle ? togglePill.left
        : row.isSelect ? selectText.left
        : row.hasStepper ? valueText.left
        : row.isText ? textVal.left
        : row.isGroup ? chevronExp.left
        : (row.isSubmenu || row.searchResult) ? chevronFwd.left
        : row.isExpandable ? chevronExp.left
        : parent.right
      anchors.rightMargin: Ui.s
      anchors.verticalCenter: parent.verticalCenter
      spacing: 1

        // Title line. A swatch strip takes the line below rather than riding
        // the name: the name is what the row is picked by.
        Text {
          id: lbl
          // Sized to the NAME: the swatch line below is full width in its own
          // right, so nothing on this line shares it. Capped at the Column's
          // width so a long name elides instead of running into the trail.
          width: Math.min(implicitWidth, parent.width)
          // The row reserves this line from RowGeometry, so its height cannot
          // be a function of this label's glyphs. The item takes the token as
          // its height and centres the line inside it: lineHeightMode would
          // make the token the line box itself, leaving a short line at the
          // top of a fallback-sized box while the icon centres beside it.
          height: row.labelLineH
          verticalAlignment: Text.AlignVCenter
          text: row.displayLabel
          color: Theme.color("foreground_0")
          font.pixelSize: row.titleFontPx
          font.family: row.previewFontFamily !== "" ? row.previewFontFamily : Ui.fontFamily
          elide: row.textReveal < 1 ? Text.ElideNone : Text.ElideRight
          clip: row.textReveal < 1
          opacity: row.textReveal
          textFormat: Text.PlainText
        }

        // Second line: optional leading accent word (command), the muted
        // copy, and an optional trailing accent word ("• active"). Packing
        // mirrors the sizing contract: the lead yields to the faint copy
        // (content width, capped at half) and elides instead, so the time
        // is never squeezed out and nothing drifts right. Lead and trail
        // together are degenerate (no producer makes both); the muted copy
        // keeps its exact formula when the lead is absent.
        Row {
          id: subRow
          width: parent.width
          spacing: 4
          // No visibility flag anywhere in this subtree, and the Row's height
          // IS the gate. Each child below carries an empty `text` rather than
          // a `visible: false`, and the line is the shared sub-line token when
          // any child has copy to show - a lead-only row spends the line on
          // the lead, so a near-zero muted Text can never clip it.
          //
          // A `visible` gate here is read once while the delegate is mid-swap
          // and nothing re-asserts it: a row that opened with its subtext lost
          // the line for the rest of the session, and the flag then drifted
          // onto rows that have no subtext at all. A `Text`'s own height can
          // no longer answer it either: every line here is pinned, so the copy
          // itself is the only honest gate.
          height: row.hasSubLine ? row.subLineH : 0

          Text {
            id: subLeadEl

            // Yield to the faint copy: content width capped by whatever it
            // keeps. Reads evaluated widths one way only - no loop.
            width: Math.min(implicitWidth, subMain.implicitWidth > 0
              ? Math.max(0, parent.width - subMain.width - parent.spacing) : parent.width)
            anchors.verticalCenter: parent.verticalCenter
            text: row.subLead
            color: Ui.solid("accent")
            font.pixelSize: Ui.fontXs
            font.family: row.previewFontFamily !== "" ? row.previewFontFamily : Ui.fontFamily
            elide: row.textReveal < 1 ? Text.ElideNone : Text.ElideRight
            clip: row.textReveal < 1
            opacity: row.textReveal
            textFormat: Text.PlainText
          }

          Text {
            id: subMain
            // The Row pins the sub-line height; the copy keeps its natural
            // line height and centres inside it, so a short Latin line does
            // not sit at the top of a fallback-sized box.
            anchors.verticalCenter: parent.verticalCenter
            // Content width (capped), never fill width: neighbors must ride
            // the text's edge, not the row's. Capped at half width like the
            // trail so a long command (lead) always leaves the faint copy
            // whole; without a lead the formula below is untouched.
            //
            // Natural width while the Row has none yet: labelColH measures
            // this Text's height, and an elided Text at zero width measures
            // zero, which is a row reading as one line before its anchors
            // have resolved.
            width: subLeadEl.implicitWidth > 0
              ? Math.min(implicitWidth, (parent.width - parent.spacing) / 2)
              : subTail.implicitWidth > 0
                ? Math.min(implicitWidth, parent.width - subTail.width - parent.spacing)
                : parent.width > 0 ? parent.width : implicitWidth
            // Item subtexts support the <b>/<i>/<u> subset via
            // styledMarkup - search rows show the live sub, because the
            // group header above names the breadcrumb.
            //
            // Empty rather than hidden when there is no muted copy to show.
            // The Row above measures `text`, which is why nothing here needs a
            // visibility flag.
            text: row.subText === "" ? ""
              : MenuLib.styledMarkup(row.subText)
                + (subTail.implicitWidth > 0 ? " •" : "")
            // Search hits read the default muted copy: the group header
            // above already carries the section in accent.
            color: Ui.tint("foreground_1", 0.55)
            font.pixelSize: Ui.fontXs
            font.family: row.previewFontFamily !== "" ? row.previewFontFamily : Ui.fontFamily
            elide: row.textReveal < 1 ? Text.ElideNone : Text.ElideRight
            clip: row.textReveal < 1
            opacity: row.textReveal
            textFormat: Text.StyledText
          }

          Text {
            id: subTail
            width: Math.min(implicitWidth, (parent.width - parent.spacing) / 2)
            anchors.verticalCenter: parent.verticalCenter
            text: row.subAccent
            color: Ui.solid("accent")
            font.pixelSize: Ui.fontXs
            font.family: row.previewFontFamily !== "" ? row.previewFontFamily : Ui.fontFamily
            elide: row.textReveal < 1 ? Text.ElideNone : Text.ElideRight
            clip: row.textReveal < 1
            opacity: row.textReveal
            textFormat: Text.PlainText
          }
        }

        // Swatch line: a theme-remover row's own colors as 8px dots, and
        // nothing else. The line is the strip alone, so its height is the
        // dot's own size.
        Row {
          width: parent.width
          visible: !!(itm && itm.palette && itm.palette.length > 0)
          spacing: 4
          Repeater {
            // Gated on the row actually carrying a palette, so ordinary rows
            // own no dot delegates.
            model: row.hasPalette ? itm.palette : []
            delegate: Rectangle {
              required property var modelData
              required property int index
              width: RowGeometry.swatchH
              height: RowGeometry.swatchH
              radius: RowGeometry.swatchH / 2
              color: modelData
              border.width: 0.6
              border.color: Ui.tint("background_3", 0.5)
            }
          }
        }
    }

    // --- right side: value box + optional bar ---
    //
    // The VALUE BOX anchors to the entry's right edge and sizes to its
    // content (never hardcoded - long values display fully). Whatever
    // the type puts its value there: toggle pill, select label, numeric
    // text, "N %" percentage. Bars are standalone components floating
    // LEFT of the box, vertically centered to the entry like everything
    // else - they never shift the value.

    ProgressBar {
      id: seekBar

      anchors.right: valueText.left
      anchors.rightMargin: row.barGap
      anchors.verticalCenter: parent.verticalCenter
      visible: row.isRange
      width: row.barWidth
      height: Ui.barH
      value: row.ratio * 100
      dimWhenEmpty: false
      color: Ui.tint("accent", 0.2)
      fillColor: row.sel || row.editorOpen
        ? Theme.color("accent") : Ui.tint("accent", 0.55)
      animationsEnabled: MotionPolicy.enabled

      // Range seek: drag or click snaps to step, commits once on release.
      MouseArea {
        anchors.fill: parent
        anchors.topMargin: -6
        anchors.bottomMargin: -6
        enabled: row.isRange && row.enabled_
        cursorShape: Qt.PointingHandCursor

        property bool dirty: false

        function seek(x) {
          const frac = Range.clamp01(x / Math.max(1, width))
          const raw = row.minimum + frac * (row.maximum - row.minimum)
          const snapped = row.minimum
            + Math.round((raw - row.minimum) / row.stepSize) * row.stepSize
          const next = MenuLib.quantize(MenuLib.clamp(snapped,
            row.minimum, row.maximum))
          if (next === row.numericValue) return
          dirty = true
          Menu.setValue(row.itm, next)
        }

        onPressed: mouse => {
          dirty = false
          seek(mouse.x)
        }
        onPositionChanged: mouse => {
          if (pressed) seek(mouse.x)
        }
        onReleased: {
          if (!dirty) return
          dirty = false
          Menu.runCommand(row.itm.onChange, row.numericDisplay)
        }
      }
    }

    // Progress rows: percentage in the value slot, bar floating left.
    ProgressBar {
      id: progressBar

      anchors.right: pctText.left
      anchors.rightMargin: row.barGap
      anchors.verticalCenter: parent.verticalCenter
      visible: row.ptype === "progress"
      width: row.barWidth
      height: Ui.barH
      value: row.ratio * 100
      dimWhenEmpty: false
      color: Ui.tint("accent", 0.2)
      fillColor: row.sel ? Theme.color("accent") : Ui.tint("accent", 0.55)
      animationsEnabled: MotionPolicy.enabled
    }

    Text {
      id: pctText

      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: row.ptype === "progress"
      width: visible ? MenuLib.valueSlotW(Menu.unifiedBarValueW,
        pctMetrics.width, 4, 80) : 0
      height: 18
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: Text.AlignRight
      text: Format.percentInt(row.ratio) + " %"
      color: Ui.tint("foreground_1", 0.75)
      font.pixelSize: row.valueFontPx
      font.family: Ui.fontFamily
      textFormat: Text.PlainText
      elide: Text.ElideNone
      clip: false
      wrapMode: Text.NoWrap

      TextMetrics {
        id: pctMetrics

        font.pixelSize: row.valueFontPx
        font.family: Ui.fontFamily
        text: "100 %"
      }
    }

    // number/range: current value as quiet text; numbers adjust via
    // +/- keys, the wheel and the editor's internal steppers.
    // Unified column: when MenuPanel detects ≥2 bars, all value boxes
    // share Menu.unifiedBarValueW so little bars form a perfect vertical
    // line. Right-hand values never elide – label truncates instead.
    Text {
      id: valueText

      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: row.hasStepper
      width: visible ? MenuLib.valueSlotW(Menu.unifiedBarValueW,
        valueMetrics.width, 6, 140) : 0
      height: 18
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: Text.AlignRight
      // hideValue rows (e.g. "Add timer") leave the slot blank - the
      // value is an input for the picker, not a readout of current state.
      text: itm && itm.hideValue ? "" : row.numericDisplay
      color: row.valueActive ? Theme.color("accent")
        : row.editorOpen ? Theme.color("accent")
        : Ui.tint("foreground_1", 0.75)
      font.pixelSize: row.valueFontPx
      font.family: Ui.fontFamily
      font.bold: row.editorOpen || row.valueActive
      // A normal readout fits its slot and never elides. A pathological unit
      // can exceed even the reserved cap; then shortening the value is the
      // only alternative to painting it over the title.
      elide: Text.ElideRight
      clip: true
      wrapMode: Text.NoWrap
      textFormat: Text.PlainText

      // Same focus-vibrancy fade as the select value.
      Behavior on color {
        enabled: MotionPolicy.enabled
        ColorAnim {}
      }

      TextMetrics {
        id: valueMetrics

        font.pixelSize: row.valueFontPx
        font.family: Ui.fontFamily
        text: MenuLib.widestValueString(row.itm) || "888.88"
      }
    }

    // select: current option label – never elides, card reserves widest option.
    //
    // A change does not swap the text in place. The outgoing label slides
    // UP out of the slot while fading, and the incoming one slides up
    // into it from below: a reel drops the new value in from above, so
    // this runs the other way. The leaving copy occupies the slot beside
    // the live Text, sized to its own metrics, so a longer label leaving
    // for a shorter one keeps its own box instead of being cut to the new
    // one's reservation.
    Text {
      id: selectGhost

      // Empty outside a swap: nothing painted, nothing measured.
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: text !== ""
      width: visible ? MenuLib.valueSlotW(0, Math.ceil(ghostMetrics.width),
        0, 220) : 0
      height: 18
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: Text.AlignRight
      text: ""
      opacity: 0
      color: row.dropdownOpen ? Theme.color("foreground_0")
        : Ui.tint("foreground_1", 0.75)
      font.pixelSize: row.valueFontPx
      font.family: Ui.fontFamily
      elide: Text.ElideNone
      clip: false
      wrapMode: Text.NoWrap
      textFormat: Text.PlainText

      transform: Translate { id: ghostShift; y: 0 }

      TextMetrics {
        id: ghostMetrics

        font.pixelSize: row.valueFontPx
        font.family: Ui.fontFamily
        text: selectGhost.text
      }
    }

    // The swap: one rising pair per layer. The outgoing pair continues
    // from wherever the incoming layer stands, both `from` values seeded
    // by onSelectValueChanged just before it restarts this, so a change
    // landing mid-swap hands the motion over rather than restarting it.
    ParallelAnimation {
      id: selectSwap

      NumberAnimation {
        target: liveShift
        property: "y"
        from: row.selectRise
        to: 0
        duration: MotionPolicy.duration(Ui.fastMs)
        easing.type: Easing.OutCubic
      }
      NumberAnimation {
        target: selectText
        property: "opacity"
        from: 0
        to: 1
        duration: MotionPolicy.duration(Ui.fastMs)
        easing.type: Easing.OutCubic
      }
      NumberAnimation {
        id: ghostRise
        target: ghostShift
        property: "y"
        to: -row.selectRise
        duration: MotionPolicy.duration(Ui.fastMs)
        easing.type: Easing.OutCubic
      }
      NumberAnimation {
        id: ghostFade
        target: selectGhost
        property: "opacity"
        to: 0
        duration: MotionPolicy.duration(Ui.fastMs)
        easing.type: Easing.OutCubic
      }

      // Nothing left to hold once the leaving label is gone.
      onFinished: selectGhost.text = ""
    }

    Text {
      id: selectText

      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: row.isSelect && !row.isActionSelect
      // Width probe (house pattern, see valueMetrics): sizing off the
      // item's own implicitWidth loops the binding and freezes the box
      // stale after picking a longer option. A select value never joins
      // the shared stepper column (0), and its reservation is the widest
      // option, capped.
      width: visible ? MenuLib.valueSlotW(0, Math.ceil(selectMetrics.width),
        0, 220) : 0
      height: 18
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: Text.AlignRight
      text: row.selectLabel
      onTextChanged: row.onSelectValueChanged()
      color: row.dropdownOpen ? Theme.color("foreground_0")
        : Ui.tint("foreground_1", 0.75)
      font.pixelSize: row.valueFontPx
      font.family: Ui.fontFamily
      elide: Text.ElideNone
      clip: false
      wrapMode: Text.NoWrap
      textFormat: Text.PlainText

      // Focus vibrancy fades like the progress fills, not snaps.
      Behavior on color {
        enabled: MotionPolicy.enabled
        ColorAnim {}
      }

      transform: Translate { id: liveShift; y: 0 }

      TextMetrics {
        id: selectMetrics

        font.pixelSize: row.valueFontPx
        font.family: Ui.fontFamily
        text: row.selectLabel
      }
    }

    // text: stored value – never elides, label truncates instead.
    Text {
      id: textVal

      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: row.isText
      // Same probe pattern as selectText: never size off implicitWidth.
      // A text value never joins the shared stepper column (0).
      width: visible ? MenuLib.valueSlotW(0, Math.ceil(textMetrics.width),
        0, 180) : 0
      height: 18
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: Text.AlignRight
      text: {
        const v = row.st ? String(row.st.value ?? "") : ""
        return v !== "" ? v : String(row.itm?.placeholder ?? "")
      }
      color: {
        const v = row.st ? String(row.st.value ?? "") : ""
        return v !== "" ? Theme.color("foreground_1")
          : Ui.tint("foreground_1", 0.35)
      }
      font.pixelSize: row.valueFontPx
      font.family: Ui.fontFamily
      font.italic: row.st ? String(row.st.value ?? "") === "" : false
      elide: Text.ElideNone
      clip: false
      wrapMode: Text.NoWrap
      textFormat: Text.PlainText

      // Same focus-vibrancy fade as the select value.
      Behavior on color {
        enabled: MotionPolicy.enabled
        ColorAnim {}
      }

      TextMetrics {
        id: textMetrics

        font.pixelSize: row.valueFontPx
        font.family: Ui.fontFamily
        text: {
          const v = row.st ? String(row.st.value ?? "") : ""
          return v !== "" ? v : String(row.itm?.placeholder ?? "")
        }
      }
    }

    Toggle {
      id: togglePill

      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: row.isToggle
      checked: row.toggleOn
      dimmed: !row.enabled_
      animationsEnabled: MotionPolicy.enabled
      onToggled: state => row.flip(state)
    }

    // submenu / search result: navigates forward
    Item {
      id: chevronFwd

      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? row.chevronWidth : 0
      height: 16
      visible: row.isSubmenu || row.searchResult

      Chevron {
        anchors.centerIn: parent
        direction: "right"
        // The same rule a group's chevron follows: accent marks something that
        // is open. A link is never open - the page it opens replaces this one -
        // so it stays muted, and being merely focused (the cursor bar already
        // says that) does not tint it.
        color: Ui.tint("foreground_1", 0.5)
      }
    }

    // expandable: chevron down/up. Shown only when the row actually has
    // something to expand (matches activate()'s guard) - a dead chevron
    // on reference rows would imply a dropdown that isn't there.
    // Info-only rows never expand, so they never show one either.
    Item {
      id: chevronExp

      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? row.chevronWidth : 0
      height: 16
      visible: (row.isGroup && row.hasGroup)
        || (row.isExpandable && !row.infoOnly && (row.descText !== "" || row.bodyText !== ""))

      Chevron {
        anchors.centerIn: parent
        direction: row.expanded ? "up" : "down"
        // A group's chevron marks the open dropdown, not the focused row. The
        // cursor bar already says which row is selected, and an accent arrow on
        // a collapsed group claimed an expansion that was not there yet.
        color: row.isGroup
          ? (row.currentOpenGroup ? Theme.color("accent")
            : Ui.tint("foreground_1", 0.5))
          : (row.expanded || row.sel ? Theme.color("accent")
            : Ui.tint("foreground_1", 0.5))
      }
    }

    // option rows (dropdown cells): bullet gutter
    Item {

      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Ui.optMarkW
      height: 16
      visible: row.isOption

      Text {
        anchors.centerIn: parent
        visible: row.isOption && Menu.optionIsChosen(row.itm)
        text: "\u2713"
        color: Theme.color("accent")
        font.pixelSize: Ui.fontM
        font.family: Ui.fontFamily
        textFormat: Text.PlainText
      }
    }
  }

  // --- ctrl+i description dropdown ---
  // In-flow expansion: shifts the rows below down and they scroll under
  // it - the card only grows when this slot cannot fit the current
  // region at all (see MenuPanel listRegionH).
  DropdownSlot {
    id: descSlot

    // A nested row paints its overlay above the siblings that follow it in
    // the group's column, the way the group's own cursor bar does.
    z: nested ? 1 : 0

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: mainLine.bottom
    // One gap value everywhere around the hairline: row-to-line,
    // line-to-text and text-to-next-row all read Ui.m, so the separator
    // sits centered between entry and description by construction.
    // A nested slot anchors at the row's rest bottom and carries the rest of
    // its top padding inside topGap, so the slot ends where the bar ends.
    anchors.topMargin: nested ? row.nestedSlotLead : Ui.m
    topGap: nested ? row.nestedSlotTopGap : 0
    open: row.descInSlot
    onOpenChanged: row._latchSlotMs()
    onClosingChanged: row._latchSlotMs()
    onHeightChanged: if (Menu.traceEnabled) Menu.trace("entry.descH", {
      id: String(itm?.id ?? ""), nested: nested,
      h: Math.round(descSlot.height * 10) / 10,
      settled: Math.round(descSlot.settledH * 10) / 10,
      op: Math.round(descCol.opacity * 100) / 100,
      barH: Math.round(nestedBarH * 10) / 10, stat: Math.round(staticRowH * 10) / 10,
      dy: Math.round(descSlot.y * 10) / 10, ms: descSlot.slotMs,
      held: descSlot._held
    })

    Column {
      id: descCol

      x: Ui.m
      width: parent.width - 2 * Ui.m
      spacing: Ui.m
      // A nested copy rides the bar's reveal: the text cannot appear before
      // the background that backs it, nor outlive it on the way back.
      opacity: nested ? Range.clamp01(
        descSlot.height / Math.max(1, descCol.implicitHeight + Ui.m)) : 1

      Divider {
        width: parent.width
        color: Ui.tint("background_3", 0.8)
      }

      BodyText {
        width: parent.width
        visible: row.descText !== ""
        markup: true
        // Gated on the slot being open or easing shut -> closed rows keep
        // the slot structure but skip styledMarkup parsing entirely.
        text: (descSlot.open || descSlot.closing) ? MenuLib.styledMarkup(row.descText) : ""
      }

      // Warnings ride the ctrl+i slot exactly as they ride the expansion
      // shell. Toggles and bool options never expand, so this slot is
      // their only warning surface.
      Notice {
        width: parent.width
        // Same open-or-closing gate as the description above -> no markup
        // parsing while the slot is shut.
        message: (descSlot.open || descSlot.closing) ? MenuLib.styledMarkup(row.warnText) : ""
        markup: true
        visible: row.warnText !== ""
      }
    }
  }

  // --- expansion slot ---
  // Editors and info bodies live here. The slot owns the animation so
  // opening AND closing glide; DropdownSlot's closing window keeps the
  // loader's content instantiated while the height eases to zero.
  DropdownSlot {
    id: expandSlot

    z: nested ? 1 : 0

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: mainLine.bottom
    // Same hairline rhythm as the ctrl+i slot: one gap value everywhere
    // (row-to-line, line-to-content, content-to-next-row), so an opened
    // editor or dropdown breathes identically to a description.
    // Same split as the description slot: anchor at the rest bottom, carry
    // the remaining top padding inside the slot.
    anchors.topMargin: nested ? row.nestedSlotLead : Ui.m
    topGap: nested ? row.nestedSlotTopGap : 0
    open: row.expanded
    // Only while the group is OPEN. A live nested child's geometry is the
    // motion an open group rides; once the group itself folds, THIS slot's
    // close is the motion. Following a child's closing tail there switched
    // the Behavior off (motion = !followNested), so the row snapped to its
    // rest height in one frame - and the close seat read that as a finished
    // fold and restored the whole scroll in one write.
    followNested: row.isGroup && row.expanded && row.nestedSlotLive
    onOpenChanged: row._latchSlotMs()
    onClosingChanged: row._latchSlotMs()
    onHeightChanged: if (Menu.traceEnabled) Menu.trace("entry.expandH", {
      id: String(itm?.id ?? ""), nested: nested,
      h: Math.round(expandSlot.height * 10) / 10,
      settled: Math.round(expandSlot.settledH * 10) / 10,
      active: expLoader.active, item: !!expLoader.item,
      loaderH: Math.round(expLoader.height * 10) / 10,
      op: Math.round(expLoader.opacity * 100) / 100,
      barH: Math.round(nestedBarH * 10) / 10, ms: expandSlot.slotMs,
      held: expandSlot._held
    })

    Loader {
      id: expLoader

      active: row.expanded || row._shellClosing || row._expLoaderKeep
      onHeightChanged: if (row.expanded && !row._shellClosing && height > 0)
        row._shellContentH = height
      height: row._shellClosing && row._shellContentH > 0
        ? row._shellContentH : (item ? item.implicitHeight : 0)
      width: parent.width
      // Fade against the slot's destination, held through the close. The
      // old denominator (content + Ui.m) missed the nested top gap, so the
      // content reached full opacity while the slot - and the neighbour
      // push driven by its live height - still had several pixels to travel.
      opacity: nested ? row.expandFade : 1
      sourceComponent: expansionComp
    }
  }

  onExpandedChanged: {
    if (expanded) row._expLoaderKeep = true
    if (Menu.traceEnabled) Menu.trace("entry.exp", {
      id: String(itm?.id ?? ""), expanded: expanded, index: index,
      auto: row.ListView.view ? row.ListView.view.autoRevealIndex : -99
    })
    if (expanded) {
      // Re-arm the nested-follow verdict for THIS unfold. The close edge
      // below clears the flag outright, and an unfold is the only place it
      // has an answer to give, so the binding is re-established per open
      // rather than left to survive a close that wrote over it.
      if (row.isGroup) expandSlot.followNested = Qt.binding(function() {
        return row.expanded && row.nestedSlotLive
      })
      const view = row.ListView.view
      // A standing pin freezes the highlight bar on the geometry of a row
      // the cursor has already left (the search projection's origin). An
      // expanding row - a dropdown opening - is a deliberate seat, so
      // release it here: otherwise the bar stays on the old row and does
      // not grow with the unfold, which reads as a focus background that
      // does not cover the entry.
      if (view) {
        if (typeof view.unpinHighlight === "function") view.unpinHighlight()
        view._keepCursor = false
        view.autoRevealIndex = index
      }
    } else {
      // Drop the nested follow at the close edge. The verdict is about the
      // child's fold inside an OPEN group; kept across the close it disables
      // this slot's height Behavior, and the row then reaches its rest height
      // in the same frame the close starts - which the close seat reads as a
      // finished fold and answers with a one-frame write to the origin.
      if (row.isGroup) expandSlot.followNested = false
      // The close edge sits at the state write; the panel paces the resize
      // from it:
      // a close driven resize has to be paced by the fold that caused it.
      row.slotCloseStarted()
      const view = row.ListView.view
      if (view && view.autoRevealIndex === index) {
        const panel = Menu.panel
        const it = panel && panel.rowsModel && panel.rowsModel[index]
        Menu.trace("entry.expClear", {
          id: String(itm?.id ?? ""), index: index,
          modelOpen: !!(it && (Menu.isExpanded(it) || Menu.infoOpen(it)))
        })
        view.autoRevealIndex = -1
      }
      row.confirmStage = 0
      row.promptOpen = false
    }
  }

  // Editor focus follows the rendered view, not the expansion event:
  // onExpandedChanged runs before dependent bindings settle (editorOpen
  // still reads false there), while this fires exactly when the editor
  // becomes live. Plain rows keep their own focus path in openEditor();
  // this only covers flow-driven editor stages.
  onEditorOpenChanged: {
    // Completes every open path (plain openEditor and flow stages
    // alike): fires exactly when the editor becomes live, so no per-row
    // retry timer is needed to chase the expansion.
    if (editorOpen) {
      Qt.callLater(grabEditorFocus)
    }
  }

  onInfoOpenChanged: {
    const shouldReveal = infoOpen && descText !== "" && !descInShell
    if (shouldReveal) {
      const view = row.ListView.view
      if (view) {
        view.autoRevealIndex = index
        // Last-row desc must be forced visible: pursuit alone may not scroll
        // when contentHeight < view height (panel keeps resting size).
        // Position the last row at end to guarantee its descSlot is not clipped.
        if (index === view.count - 1 && typeof view.revealEnd === "function")
          view.revealEnd(index)
      }
    } else {
      row.slotCloseStarted()
      const view = row.ListView.view
      if (view && view.autoRevealIndex === index) {
        const panel = Menu.panel
        const it = panel && panel.rowsModel && panel.rowsModel[index]
        Menu.trace("entry.infoClear", {
          id: String(itm?.id ?? ""), index: index,
          modelOpen: !!(it && (Menu.isExpanded(it) || Menu.infoOpen(it)))
        })
        view.autoRevealIndex = -1
      }
    }
  }

  Component.onDestruction: {
    const view = row.ListView.view
    if (!view || view.autoRevealIndex !== index) return
    // A wholesale row swap destroys delegates and recreates them at the same
    // indices. A direct clear lets a stale result row at this index retire a
    // claim held by the new open row. The MODEL row that owns the index is the
    // authority for the verdict.
    Qt.callLater(function() {
      if (view.autoRevealIndex !== index) return
      const panel = Menu.panel
      const it = panel && panel.rowsModel && panel.rowsModel[index]
      Menu.trace("entry.destroyClear", {
        id: String(itm?.id ?? ""), index: index,
        modelOpen: !!(it && (Menu.isExpanded(it) || Menu.infoOpen(it)))
      })
      if (it && (Menu.isExpanded(it) || Menu.infoOpen(it))) return
      view.autoRevealIndex = -1
    })
  }

  // Expansion shell: the editor or the body text, plus - when the item
  // carries a description alongside an interactive editor - a hairline
  // separating the ctrl+i block underneath.
  Component {
    id: expansionComp

    Column {
      id: wrapCol

      property alias debugEditorHost: stageHost

      function takeFocus() {
        const inner = stageHost.frontItem
        if (inner && inner.takeFocus) inner.takeFocus()
      }

      function commitNow() {
        const inner = stageHost.frontItem
        if (inner && inner.commitNow) inner.commitNow()
      }

      width: parent.width
      spacing: Ui.m

      readonly property bool editorView: row.editorOpen
      readonly property bool confirmView: row.confirmOpen
      readonly property bool showDesc: (row.descInShell || row._shellClosing)
        && row.descText !== ""
      // Warning rides the same expansion shell, always BELOW the
      // description under the block's single hairline - which stays in
      // place even when no description precedes the warning.
      readonly property bool showWarn: (row.descInShell || row._shellClosing)
        && row.warnText !== ""
      onShowWarnChanged: if (Menu.traceEnabled && row.isText)
        Menu.trace("shell.warn", {
          id: String(itm?.id ?? ""), visible: showWarn,
          closing: row._shellClosing
        })
      // Staged-flow swap: a view-to-view change keeps the outgoing body alive
      // as a ghost layer and runs both views on one slide-fade. Going forward
      // the incoming view enters from the right while the old one leaves to
      // the left; ESC reverses both. Opening and closing cut, because the
      // slot's own height glide already carries those. The slot's height reads
      // only the front layer, so the ghost is a visual overlay that fades
      // without resizing the card underneath it.
      Item {
        id: stageHost

        width: parent.width
        height: frontLayer ? frontLayer.height : 0
        // The front layer's height changes the instant the layers swap. Left
        // raw, the content layout snaps to the new type's size in one frame
        // and the slot's own ease just chases a value that already moved.
        // Ride the same clock as the slide so the box transforms with it.
        property bool _swapping: false
        Behavior on height {
          enabled: stageHost._swapping
          NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
        }
        // Closed is its own key (-1). Only view-to-view swaps within one
        // expansion glide animate (dropdown -> editor, stage to stage, back).
        // Derive the view from the row's stable facts, not from editorOpen:
        // on open, expanded flips a frame before editorOpen's binding has
        // re-evaluated, so reading it here sent the key through 1000 (body)
        // and made an opening editor slide in as if it were a stage swap.
        property int stageKey: !row.expanded ? -1
          : row.isFlow ? row.flowIndex
          : row.isGroup ? 1004
          : row.dropdownOpen ? 1001
          : row.confirmOpen ? 1003
          : (row.hasEditor || row.promptOpen) ? 1002
          : 1000
        property int _prevStageKey: -1
        // The close drops expanded/editorOpen in the same turn the slot starts
        // folding. Hold the last view until the loader is released so its
        // height - and the content's fade - ride the fold out.
        readonly property int liveStageKey: stageKey !== -1
          ? stageKey : row._lastStageKey

        // Two alternating layers. At rest the front paints and the other is
        // parked invisible; on a swap the parked layer becomes the incoming
        // view and the old front becomes its outgoing ghost.
        property bool _frontA: true
        property Component _compA: null
        property Component _compB: null
        // Each layer remembers the option list it was built with, so a layer
        // becoming a ghost keeps the list that was on screen instead of the
        // next stage's data.
        property var _compAFrozen: null
        property var _compBFrozen: null
        // The view and the copy beside it are frozen per layer as one set, so
        // a ghost keeps the stage's whole body - options, description and
        // message box - while the incoming layer carries the next stage's.
        property Component _viewA: null
        property Component _viewB: null
        property string _descA: ""
        property string _descB: ""
        property string _warnA: ""
        property string _warnB: ""
        readonly property Loader frontLayer: _frontA ? layerA : layerB
        readonly property Item frontItem: frontLayer ? frontLayer.item : null

        // A view-to-view swap is a full-width replacement: the incoming body
        // starts entirely off the right edge and the outgoing one leaves by
        // the left, both fading as they travel. A short nudge reads as an
        // in-place type change rather than a slide.
        readonly property int slidePx: stageHost.width
        // Captured at swap time: the option labels the outgoing layer actually
        // keeps while it fades, for the live regression probe.
        property string debugGhostLabels: ""

        function currentOptions() {
          return row.isFlow
            ? (row.flowStep && row.flowStep.options ? row.flowStep.options : [])
            : (row.itm ? row.itm.options ?? [] : [])
        }

        function componentFor(key) {
          if (key < 0) return null
          // Flow stages use their index as the key; their kind names the view
          // and stays stable with the stage the key denotes.
          if (row.isFlow) {
            if (row.flowKind === "select") return optionsComp
            if (row.flowKind === "text" || row.flowKind === "number"
              || row.flowKind === "range") return editorComp
            return bodyComp
          }
          if (key === 1004) return groupComp
          if (key === 1003) return confirmComp
          if (key === 1001) return optionsComp
          if (key === 1002) return editorComp
          return bodyComp
        }

        onLiveStageKeyChanged: if (Menu.traceEnabled)
          Menu.trace("stage.key", {
            id: String(itm?.id ?? ""), key: liveStageKey,
            stage: stageKey, last: _lastStageKey,
            item: !!stageHost.frontItem, ih: stageHost.frontItem
              ? Math.round(stageHost.frontItem.implicitHeight * 10) / 10 : -1
          })

        // The host is created only after the row is open, so stageKey is born
        // at its first view. Seed the front layer there without a slide - the
        // slot's open ease is the announcement.
        Component.onCompleted: {
          if (stageKey === -1) return
          stageHost._prevStageKey = stageKey
          const front = _frontA ? layerA : layerB
          const opts = stageHost.currentOptions()
          const view = stageHost.componentFor(stageKey)
          const desc = row.descText
          const warn = row.warnText
          if (_frontA) {
            stageHost._viewA = view
            stageHost._compAFrozen = opts
            stageHost._descA = desc
            stageHost._warnA = warn
            stageHost._compA = null
            stageHost._compA = stageViewComp
          } else {
            stageHost._viewB = view
            stageHost._compBFrozen = opts
            stageHost._descB = desc
            stageHost._warnB = warn
            stageHost._compB = stageViewComp
          }
          front.x = -Ui.m
          front.opacity = 1
        }

        function swap(key, dir) {
          const incoming = _frontA ? layerB : layerA
          const outgoing = _frontA ? layerA : layerB
          const ghostView = outgoing.item && outgoing.item.viewItem
          const ghostModel = ghostView && ghostView.optionModel
          stageHost.debugGhostLabels = ghostModel && ghostModel.map
            ? ghostModel.map(o => o.label).join("|") : ""
          swapAnim.stop()
          stageHost._swapping = true
          // The outgoing body survives the fade, so it would keep keyboard
          // focus: an Enter after an Esc-back would commit through the hidden
          // editor and close the flow. Disabling it releases focus to the
          // list; the incoming layer takes focus when its stage asks for it.
          incoming.enabled = true
          outgoing.enabled = false
          const opts = currentOptions()
          const view = componentFor(key)
          const desc = row.descText
          const warn = row.warnText
          if (_frontA) {
            stageHost._viewB = view
            stageHost._compBFrozen = opts
            stageHost._descB = desc
            stageHost._warnB = warn
            stageHost._compB = null
            stageHost._compB = stageViewComp
          } else {
            stageHost._viewA = view
            stageHost._compAFrozen = opts
            stageHost._descA = desc
            stageHost._warnA = warn
            stageHost._compA = null
            stageHost._compA = stageViewComp
          }
          _frontA = !_frontA
          // Reset both legs before starting: the ghost of the previous swap
          // carries an off-edge offset that the next incoming must not inherit.
          incoming.x = -Ui.m + dir * slidePx
          incoming.opacity = 0
          outgoing.x = -Ui.m
          outgoing.opacity = 1
          inSlide.from = -Ui.m + dir * slidePx
          inSlide.target = incoming
          inFade.from = 0
          inFade.target = incoming
          outSlide.from = -Ui.m
          outSlide.to = -Ui.m - dir * slidePx
          outSlide.target = outgoing
          outFade.from = 1
          outFade.target = outgoing
          swapAnim.start()
        }

        function cutTo(key) {
          swapAnim.stop()
          stageHost._swapping = false
          const incoming = _frontA ? layerB : layerA
          const outgoing = _frontA ? layerA : layerB
          incoming.enabled = true
          outgoing.enabled = false
          const opts = currentOptions()
          const view = componentFor(key)
          const desc = row.descText
          const warn = row.warnText
          if (_frontA) {
            stageHost._viewB = view
            stageHost._compBFrozen = opts
            stageHost._descB = desc
            stageHost._warnB = warn
            stageHost._compB = null
            stageHost._compB = stageViewComp
          } else {
            stageHost._viewA = view
            stageHost._compAFrozen = opts
            stageHost._descA = desc
            stageHost._warnA = warn
            stageHost._compA = null
            stageHost._compA = stageViewComp
          }
          _frontA = !_frontA
          incoming.x = -Ui.m
          incoming.opacity = 1
          outgoing.x = -Ui.m
          outgoing.opacity = 0
        }

        onStageKeyChanged: {
          if (Menu.traceEnabled) Menu.trace("stage.changed", {
            id: String(itm?.id ?? ""), from: stageHost._prevStageKey,
            to: stageKey, expanded: row.expanded, editor: row.editorOpen
          })
          if (stageKey !== -1) row._lastStageKey = stageKey
          const prev = stageHost._prevStageKey
          stageHost._prevStageKey = stageKey
          if (prev === -1 || stageKey === -1) {
            // Open / close: the slot's height glide is the whole motion.
            swapAnim.stop()
            stageHost._swapping = false
            const front = _frontA ? layerA : layerB
            front.enabled = true
            front.x = -Ui.m
            front.opacity = 1
            return
          }
          if (MotionPolicy.enabled) swap(stageKey, stageKey > prev ? 1 : -1)
          else cutTo(stageKey)
        }

        // The views slide inside the dropdown's content gutter. Clipping at
        // the padding boundary keeps neither the incoming nor the outgoing
        // body painting over the border; the layers carry their own Ui.m
        // inset, cancelled by their base offset so their resting place is
        // unchanged. Height spans both layers so the ghost is not cut short
        // vertically while the slot eases to the new content's height.
        Item {
          id: stageClip

          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.leftMargin: Ui.m
          anchors.rightMargin: Ui.m
          height: Math.max(layerA.height, layerB.height)
          clip: true

          Loader {
            id: layerA

            x: -Ui.m
            width: stageHost.width
            height: item ? item.implicitHeight : 0
            sourceComponent: stageHost._compA
            opacity: 0
            onItemChanged: if (item) {
              item.viewFrozen = stageHost._compAFrozen
              item.infoDesc = stageHost._descA
              item.infoWarn = stageHost._warnA
              // Last: assigning the component creates the inner view, which
              // reads the frozen data the three lines above just supplied.
              item.viewComponent = stageHost._viewA
            }
          }

          Loader {
            id: layerB

            x: -Ui.m
            width: stageHost.width
            height: item ? item.implicitHeight : 0
            sourceComponent: stageHost._compB
            opacity: 0
            onItemChanged: if (item) {
              item.viewFrozen = stageHost._compBFrozen
              item.infoDesc = stageHost._descB
              item.infoWarn = stageHost._warnB
              item.viewComponent = stageHost._viewB
            }
          }
        }

        ParallelAnimation {
          id: swapAnim

          onFinished: stageHost._swapping = false

          NumberAnimation {
            id: inSlide
            property: "x"
            to: -Ui.m
            duration: Ui.normalMs
            easing.type: Easing.InOutCubic
          }
          NumberAnimation {
            id: inFade
            property: "opacity"
            to: 1
            duration: Ui.normalMs
            easing.type: Easing.InOutCubic
          }
          NumberAnimation {
            id: outSlide
            property: "x"
            duration: Ui.normalMs
            easing.type: Easing.InOutCubic
          }
          NumberAnimation {
            id: outFade
            property: "opacity"
            to: 0
            duration: Ui.normalMs
            easing.type: Easing.InOutCubic
          }
        }
      }

      readonly property bool dropdownView: row.dropdownOpen

      // Validation error: red-tinted box fading in/out.
      Notice {
        message: row.editorError
        tone: "danger"
        x: Ui.m
        width: parent.width - 2 * Ui.m
      }

    }
  }

  Component {
    id: bodyComp

    Item {
      width: parent.width
      implicitHeight: bodyLabel.height

      BodyText {
        id: bodyLabel

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Ui.m
        anchors.rightMargin: Ui.m
        // Expandable bodies win; other expanded plain rows show their
        // description here. Both are declarative copy, so both render
        // the whitelisted markup.
        markup: true
        text: MenuLib.styledMarkup(row.isExpandable && row.bodyText !== ""
          ? row.bodyText : row.descText)
        visible: text !== ""
      }
    }
  }

  Component {
    id: groupComp

    // Inline dropdown of entries: the compact form of the rows this entry
    // groups, one column, one cursor. The arrows walk it exactly like a select
    // dropdown, Enter flips the child under the cursor, and the bar paints the
    // selection behind the row the cursor holds.
    Item {
      id: groupRoot

      property alias focusBar: focusBar
      property alias groupCol: groupCol

      width: parent.width
      // The nested slot is an overlay, excluded from this box, so opening it
      // cannot resize the card. Rows below slide inside the clipped box.
      // The box grows only by the shortfall the child could not push into.
      // A group that still fits the card viewport keeps the window size.
      implicitHeight: groupCol.height + groupRoot.boxNeed
      clip: true

      readonly property real focusRestH: cursorItem ? cursorItem.restH : 0
      readonly property real focusBarH: cursorItem ? cursorItem.barH : 0
      // The bar eases with the child's slot. liveExtra is that same frame's
      // growth; every push motion below is a pure function of it, so the
      // column, the rows and the bar share one clock. A Behavior on any of
      // them re-eases the value a frame late and desynchronises the reveal.
      // Read the cursor row once: focusBarH and focusRestH are separate
      // bindings and can straddle a cursor change, reporting one row's bar
      // against the previous row's rest. That phantom extra moves the column
      // for a frame and leaves the bar a second glide back to its seat.
      readonly property real liveExtra: {
        const it = groupRoot.cursorItem
        return it ? Math.max(0, it.barH - it.restH) : 0
      }
      // The destination extra, held through the close: settledH drops to zero
      // the instant `open` flips, so reading it live would collapse the
      // progress to zero in one frame and snap the card shut.
      readonly property real settledExtra: {
        const it = groupRoot.cursorItem
        return it ? Math.max(0, it.settledBarH - it.restH) : 0
      }
      property real _settledExtraLatch: 0
      onSettledExtraChanged: if (settledExtra > 0) _settledExtraLatch = settledExtra
      // One progress for the whole push: the neighbour slide, the column
      // shift and the box growth all read this fraction of their destination,
      // so they start and land together with the expand or fold.
      readonly property real pushProgress: _settledExtraLatch > 0
        ? Math.min(1, Math.max(0, liveExtra / _settledExtraLatch)) : 0

      // The group column is split at its middle. A child in the top half
      // pushes the rows BELOW it down; there is no reason to drag the column
      // up as well when room below can absorb the slot. A child in the bottom
      // half has no room worth pushing into below, so it slides the column up
      // and only the remaining shortfall grows the box. Both derive from the
      // same live frame as the bar.
      readonly property bool topHalf: row.childIndex < (
        groupRoot.childrenRepeater ? groupRoot.childrenRepeater.count / 2 : 0)
      readonly property real roomAbove: cursorItem ? cursorItem.y : 0
      readonly property real roomBelow: Math.max(0,
        groupCol.height - roomAbove - focusRestH)
      readonly property real pushUp: topHalf ? 0 : roomAbove
      // Destinations of the three pushes, all scaled by pushProgress.
      readonly property real overflowTarget: Math.min(_settledExtraLatch, pushUp)
      readonly property real boxTarget: Math.max(0,
        _settledExtraLatch - pushUp - roomBelow)
      readonly property real overflow: pushProgress * overflowTarget
      readonly property real boxNeed: pushProgress * boxTarget

      onFocusBarHChanged: if (Menu.traceEnabled) Menu.trace("grp.barH", {
        id: String(itm?.id ?? ""), idx: row.childIndex,
        y: Math.round(focusBar.y * 10) / 10,
        colY: Math.round(groupCol.y * 10) / 10,
        barH: Math.round(focusBarH * 10) / 10,
        rest: Math.round(focusRestH * 10) / 10,
        extra: Math.round(liveExtra * 10) / 10,
        box: Math.round(boxNeed * 10) / 10,
        overflow: Math.round(overflow * 10) / 10
      })



      // A child can carry its own sub line or ctrl+i slot, so rows have no
      // shared fixed height. The cursor follows the live delegate. Holding the
      // last item while itemAt is null mid-reveal keeps the bar off the row
      // above; childIndex < 0 is the only clear.
      property Item cursorItem: null
      property int cursorIndex: row.childIndex
      function trackCursor() {
        // Collapse clears childIndex, but the bar must keep reading its last
        // row while the slot folds - otherwise y and height snap to zero and
        // it vanishes before its collapse fade can play.
        if (row.childIndex < 0) return
        const it = groupRepeater.itemAt(row.childIndex)
        if (it) groupRoot.cursorItem = it
      }
      onCursorIndexChanged: groupRoot.trackCursor()
      Connections {
        target: groupRepeater

        function onItemAdded(index, item) { groupRoot.trackCursor() }
        function onItemRemoved(index, item) { groupRoot.trackCursor() }
      }
      // Exposed so the owning row can fold an open child editor with the
      // group, delegate keys to it, and publish its need-based growth to the
      // card's slot claim.
      property var childrenRepeater: groupRepeater

      // Entrance fade, matching the select dropdown: opening reads as an
      // arrival rather than watching the card grow under static copy.
      Component.onCompleted: {
        row._groupView = groupRoot
        groupRoot.trackCursor()
        if (MotionPolicy.enabled && row.dropdownOpen) {
          groupRoot.opacity = 0
          groupEnter.restart()
        }
      }
      Component.onDestruction: {
        if (row._groupView === groupRoot) row._groupView = null
      }
      NumberAnimation {
        id: groupEnter

        target: groupRoot
        property: "opacity"
        to: 1
        duration: Ui.fastMs + 20
        easing.type: Easing.OutCubic
      }

      // Each nested bar gets the shared elevation halo. The page-level
      // dropdown needs none: its bar already sits on the card.
      SoftShadow {
        host: focusBar
        opacity: focusBar.opacity
      }

      Rectangle {
        id: focusBar

        // Stay painted through the fold: `dropdownOpen` flips on the frame the
        // collapse is called, while the content it belongs to is still fading.
        // Opacity rides the slot's collapse progress so the bar and its halo
        // are swallowed by the same motion as the dropdown body.
        visible: groupRoot.cursorItem !== null
          && (row.dropdownOpen || row.expandFade > 0.001)
        opacity: row.dropdownOpen ? 1 : row.expandFade
        // The fill stays the plain two-shade step; only the left edge borrows
        // a palette color directly, one per depth. No mixing, no alpha.
        // Cool and warm alternate so no two neighbouring levels sit in the
        // same part of the spectrum; the brightest hue lands at the deepest
        // level as a finishing cue.
        readonly property var levelHues: [
          "blue", "orange", "cyan", "yellow", "green", "red", "purple", "pink"
        ]
        property string hueKey: focusBar.levelHues[
          row.nestedDepth % focusBar.levelHues.length]
        // The ramp starts one step ABOVE the page cursor's background_1 bar,
        // the way the option cursor sits a step above the row it unfolds in.
        // Starting on background_1 instead painted the first dropdown's bar
        // on its parent's identical shade, leaving only its edge and halo.
        // From there the two tones alternate, so no neighbouring level sits
        // in the same shade - even levels take the wash, odd ones the solid.
        property color barFill: row.nestedDepth % 2 === 0
          ? Ui.tint("background_2", 0.7) : Theme.color("background_1")
        color: focusBar.barFill
        radius: RoundingPolicy.radius
        border.width: 1
        border.color: Ui.solid("background_3")
        x: Ui.m
        y: groupRoot.cursorItem ? groupRoot.cursorItem.y + groupCol.y : 0
        width: groupRoot.width - 2 * Ui.m
        // The focused row and its nested description share one continuous
        // background: the bar grows by exactly the overlay's height.
        // While the dropdown unfolds the bar is already at its final row, so
        // its bottom can reach the slot's lower edge before the slot has grown
        // past it and the bar paints over the dropdown's border. Cap it to the
        // live slot: the bar reveals top-down with the unfold and is whole
        // once the slot has settled.
        height: Math.max(0, Math.min(groupRoot.focusBarH,
          row.expandSlotH - y - expandSlot.gap))

        // Glide only between children at rest. During a reveal y follows
        // groupCol directly; a second glide on top of the bar's own tween
        // desynchronises the two and breaks the shared edge on collapse.
        Behavior on y {
          enabled: MotionPolicy.enabled && !groupEnter.running
            && groupRoot.liveExtra <= 0
          NumberAnimation {
            duration: Ui.fastMs
            easing.type: Easing.OutCubic
            onFinished: Menu.trace("grp.barDone", {
              y: Math.round(focusBar.y * 10) / 10,
              idx: row.childIndex, liveExtra: groupRoot.liveExtra
            })
          }
        }
        onYChanged: if (Menu.traceEnabled) Menu.trace("grp.barY", {
          y: Math.round(focusBar.y * 10) / 10, idx: row.childIndex,
          liveExtra: Math.round(groupRoot.liveExtra * 10) / 10,
          glide: groupRoot.liveExtra <= 0
        })
        // Height and y track the delegate directly at reveal time: the child's
        // slot is the one animation, so the bar must not carry a second curve.
      }

      // The hue marks a descent into another dropdown, not merely a focus.
      // A cursor resting on a toggle or any other leaf keeps the plain bar.
      function cursorOpensGroup() {
        const kid = groupRoot.cursorItem && groupRoot.cursorItem.liveRow
        return !!(kid && kid.isGroup && kid.dropdownOpen)
      }

      // The raw palette hue as a solid strip over the bar's own left border.
      // QML Rectangle borders apply to all four sides, so the one-sided case
      // is a separate piece; inset by the corner radius to stay inside the
      // rounded outline instead of squaring off its ends.
      //
      // The strip scales its live height by the focused child's own slot
      // progress - the same fraction the bar and the neighbour push ride. It
      // climbs and retracts on that slot's clock, so it can neither finish
      // ahead of the unfold nor linger after the fold. `visible` keeps it
      // painting while the fraction is still above zero: it must not blink
      // out on the frame the child closes, before the fold has run.
      readonly property bool depthStripWanted: focusBar.visible && cursorOpensGroup()
      readonly property real depthReveal: groupRoot.pushProgress

      onDepthStripWantedChanged: if (Menu.traceEnabled) Menu.trace("grp.depthStrip", {
        id: String(row.itm?.id ?? ""), wanted: depthStripWanted,
        reveal: Math.round(depthReveal * 100) / 100
      })

      Rectangle {
        id: depthStrip

        visible: depthStripWanted || depthReveal > 0
        x: focusBar.x
        y: focusBar.y + Math.min(RoundingPolicy.radius, focusBar.height / 2)
        width: 3
        height: Math.max(0, focusBar.height
          - 2 * Math.min(RoundingPolicy.radius, focusBar.height / 2)) * depthReveal
        color: Theme.color(focusBar.hueKey)
      }

      Column {
        id: groupCol

        x: Ui.m
        width: parent.width - 2 * Ui.m
        y: -groupRoot.overflow

        // No Behavior: overflow is the same frame's slot growth the bar reads.

        Repeater {
          id: groupRepeater

          model: row.groupChildren

          delegate: GroupRow {
            width: groupCol.width
            // Pass this row's depth on so each loaded child increments it;
            // without this every nested row reports depth 1 and the fill and
            // edge hue never change past the first dropdown.
            nestedDepth: row.nestedDepth
            // The slot's growth plus the room below the focused child carry
            // the following rows past the box edge.
            slideY: index > row.childIndex && groupRoot.liveExtra > 0
              ? groupRoot.liveExtra : 0
            onPicked: row.childIndex = index
          }
        }
      }
    }
  }

  Component {
    id: optionsComp

    // Inline dropdown: option boxes in one or two columns. Long lists
    // (codec selection) halve their height instead of scrolling forever;
    // short ones keep the single-column look. Column-major fill keeps
    // the linear option cursor walking naturally top-to-bottom.
    Item {
      id: optsRoot

      width: parent.width
      // Entrance fade (the page summon's slideAnim, minus the slide):
      // opening reads as an arrival rather than watching elided entries
      // grow into the widening card. Fade only, deliberately - sliding
      // the container would sweep the option cursor bar across with it,
      // and the cursor's position is meaningful. Runs once, when the
      // expansion is built for an open dropdown; the close path needs
      // none, since the content unloads a tick after the close ease
      // starts and the card shrinks behind already-fitted rows.
      Component.onCompleted: {
        if (MotionPolicy.enabled && row.dropdownOpen) {
          optsRoot.opacity = 0
          dropEnter.restart()
        }
      }
      NumberAnimation {
        id: dropEnter
        target: optsRoot
        property: "opacity"
        to: 1
        duration: Ui.fastMs + 20
        easing.type: Easing.OutCubic
      }
      // A ghosted view keeps the option list it was built with: the row's
      // live flow step already names the NEXT stage by the time the outgoing
      // layer starts fading, so reading it here would swap the list under a
      // still-visible body (the row's plain options read as "Legacy option").
      property var frozenOptions: null
      readonly property var optionModel: frozenOptions !== null
        ? frozenOptions
        : (row.isFlow
          ? (row.flowStep && row.flowStep.options ? row.flowStep.options : [])
          : (row.itm ? row.itm.options ?? [] : []))
      readonly property int count: optsRoot.optionModel.length
      readonly property bool twoCols: MenuLib.optionColumnCount(count) > 1
      readonly property int colCount: MenuLib.optionColumnCount(count)
      readonly property int rowCount: MenuLib.optionRowCount(count)
      readonly property real cellW:
        (optsGrid.width - (colCount - 1) * Ui.m) / colCount

      implicitHeight: optsGrid.height

      // Sliding option cursor: one bar gliding behind the options,
      // mirroring the entry-list highlight. Per-row crossfades flashed
      // mid-tones, so rows stay unpainted and this rect owns the motion.
      // Column-major mapping matches the grid flow (TopToBottom).
      function optCol(idx) {
        return MenuLib.optionCellCol(idx, optsRoot.count)
      }
      function optRow(idx) {
        return MenuLib.optionCellRow(idx, optsRoot.count)
      }
      function optRowH(r) {
        let h = 0
        const kids = optsGrid.children
        for (let k = 0; k < kids.length; k++) {
          const rr = optsRoot.twoCols ? k % optsRoot.rowCount : k
          if (rr === r && kids[k] && kids[k].height > h) h = kids[k].height
        }
        return h > 0 ? h : 28
      }
      function optRowY(idx) {
        const r = optsRoot.optRow(idx)
        let y = 0
        for (let i = 0; i < r; i++) y += optsRoot.optRowH(i) + 1
        return y
      }

      // Same elevation as the group and entry cursors, so every selector
      // reads at the same depth. Declared before the cursor to paint behind.
      SoftShadow {
        host: optCursor
        opacity: optCursor.opacity
      }

      Rectangle {
        id: optCursor

        // Same collapse fade as the group cursor: the bar is part of the
        // dropdown body, so it leaves with that body rather than on the frame
        // `dropdownOpen` drops.
        visible: row.dropdownOpen || row.expandFade > 0.001
        opacity: row.dropdownOpen ? 1 : row.expandFade
        // One step ABOVE the surface this sits on, the way the list bar is one
        // step above the card. The open row's own bar already paints the whole
        // dropdown background_1 - it unfolds inside the focused row - so a
        // background_1 plate here would be a same-shade fill and the edge
        // would carry the cursor alone. Held at 0.7 alpha so the step above
        // arrives as a wash over that surface rather than a slab on it. Same
        // inset hairline and same rounding as the entry cursor, so an option
        // and an entry read alike.
        color: Ui.tint("background_2", 0.7)
        radius: RoundingPolicy.radius
        border.width: 1
        border.color: Ui.solid("background_3")
        x: Ui.m + optsRoot.optCol(row.optionIndex) * (optsRoot.cellW + Ui.m)
        y: optsRoot.optRowY(row.optionIndex)
        width: optsRoot.cellW
        height: optsRoot.optRowH(row.optionIndex)

        // No entrance glide: on creation these all read 0 until the grid
        // lays out, so an enabled Behavior would sweep the cursor from the
        // corner to the seeded option on every open. It snaps to place
        // while the entrance fade above plays, then glides normally.
        Behavior on x {
          enabled: MotionPolicy.enabled && !dropEnter.running
          NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
        }
        Behavior on y {
          enabled: MotionPolicy.enabled && !dropEnter.running
          NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
        }
        Behavior on width {
          enabled: MotionPolicy.enabled && !dropEnter.running
          NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
        }
        Behavior on height {
          enabled: MotionPolicy.enabled && !dropEnter.running
          NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
        }
      }

      Grid {
        id: optsGrid

        x: Ui.m
        width: parent.width - 2 * Ui.m
        rows: rowCount
        columns: colCount
        flow: Grid.TopToBottom
        columnSpacing: Ui.m
        rowSpacing: 1

        Repeater {
          model: optsRoot.optionModel

          delegate: OptionRow {
            width: optsRoot.cellW
            // The card is mid-width while its glide runs; each entry
            // reveals its copy with the growth, like normal rows do.
            settling: row.cardSettling
            cursor: row.optionIndex === index
            chosen: index === row.chosenIndex
            onPicked: value => row.pick(value)
          }
        }
      }
    }
  }

  // One stage body: the view for the stage plus the copy that belongs to it.
  // Both live in the same slide layer, so a description or message box leaves
  // with the outgoing stage and arrives with the incoming one instead of
  // blinking in place while the input slides past it.
  Component {
    id: stageViewComp

    Column {
      id: stageView

      property Component viewComponent: null
      property var viewFrozen: null
      property string infoDesc: ""
      property string infoWarn: ""
      readonly property Item viewItem: viewLoader.item

      width: parent.width
      // Same gap as the shell used between the view and its copy. Without a
      // column the view and the info block both sat at y=0 and painted over
      // each other; the stack is what makes the box grow for the copy.
      spacing: Ui.m

      function takeFocus() {
        if (viewLoader.item && viewLoader.item.takeFocus) viewLoader.item.takeFocus()
      }
      function commitNow() {
        if (viewLoader.item && viewLoader.item.commitNow) viewLoader.item.commitNow()
      }

      Loader {
        id: viewLoader

        width: parent.width
        height: item ? item.implicitHeight : 0
        sourceComponent: stageView.viewComponent
        onItemChanged: if (item && item.frozenOptions !== undefined)
          item.frozenOptions = stageView.viewFrozen
      }

      Column {
        id: infoCol

        width: parent.width
        spacing: Ui.m

        Divider {
          width: parent.width
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: Ui.m
          visible: stageView.infoDesc !== "" || stageView.infoWarn !== ""
        }

        Item {
          id: descItem

          width: parent.width
          height: visible ? descLabel.height : 0
          visible: stageView.infoDesc !== ""

          BodyText {
            id: descLabel

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Ui.m
            markup: true
            text: MenuLib.styledMarkup(stageView.infoDesc)
          }
        }

        Notice {
          x: Ui.m
          width: parent.width - 2 * Ui.m
          markup: true
          message: MenuLib.styledMarkup(stageView.infoWarn)
          visible: stageView.infoWarn !== ""
        }
      }
    }
  }

  Component {
    id: editorComp

    InlineEditor {
      id: stageEditor

      width: parent.width
      keepFocusAccent: row.expanded || row._shellClosing
      isText: row.isFlow ? row.flowKind === "text"
        : (row.isText || row.promptOpen)
      placeholder: String((row.isFlow && row.flowStep && row.flowStep.placeholder)
        || row.itm?.placeholder || "value")
      // Flow stages reseed from the stored stage value so Back never
      // loses typed input; otherwise the row state seeds as before.
      initialText: {
        Menu.rev
        // A flow stage seeds from its OWN stored value only: the row's
        // value is the row's primary kind (the minutes of a number
        // stage), and a text stage inheriting it would open on a stray
        // number instead of its placeholder.
        const seed = MenuLib.stageSeedText(row.isFlow, row.flowKind,
          row.isFlow ? Menu.flowValuesOf(itm)[String(row.flowIndex)] : undefined)
        if (seed !== null) return seed
        if (row.promptOpen) return String(row.itm?.editText ?? "")
        return (row.st ? String(row.st.value ?? "") : "")
      }
      numericValue: {
        Menu.rev
        return row.flowSeedNumber()
      }
      decimals: row.decimals
      minimum: row.isFlow && row.flowStep && row.flowStep.min !== undefined
        ? Number(row.flowStep.min) : row.minimum
      maximum: row.isFlow && row.flowStep && row.flowStep.max !== undefined
        ? Number(row.flowStep.max) : row.maximum
      stepSize: row.isFlow && row.flowStep && row.flowStep.step !== undefined
        ? Number(row.flowStep.step) : row.stepSize
      unitSuffix: MenuLib.stageUnitSuffix(
        row.flowStep ? row.flowStep.unit : undefined, row.unitSuffix)

      // A swap keeps the outgoing editor alive as a ghost. Its field can have
      // a deferred accepted()/escaped() still queued, which lands after the
      // panel has already advanced the flow; acting on it would commit the
      // next stage and close the row. Only the front layer owns the row's
      // commit and escape verbs.
      function ownsRow() {
        const host = expLoader.item && expLoader.item.debugEditorHost
        return !host || (host.frontItem && host.frontItem.viewItem === stageEditor)
      }
      onCommit: text => { if (stageEditor.ownsRow()) row.commitEditor(text) }
      onInvalid: msg => row.showEditorError(msg)
      onRecovered: row.clearEditorError()
      onEscaped: { if (stageEditor.ownsRow() && !row.backFlow()) row.collapse() }
    }
  }

  Component {
    id: confirmComp

    ConfirmSlot {
      width: parent.width
      // Loader heights come from implicitHeight; mirror the live slot
      // height so the expansion shell tracks the open animation 1:1.
      implicitHeight: height
      readonly property var cf: row.activeConfirm
      open: true
      // Single-stage confirms (recording) arm immediately: map them to
      // the armed stage so the button fills red while the hint copy
      // stays (armed falls back to hint below).
      stage: cf ? (cf.stages === 1 ? 2 : row.confirmStage) : 0
      hintText: cf ? cf.hint : ""
      // For single-stage confirms (recording) armed is empty, show hint.
      armedText: cf ? (cf.armed !== "" ? cf.armed : cf.hint) : ""
      confirmText: cf ? cf.label : ""
      onConfirmed: {
        if (!cf) return
        if (row.confirmStage < cf.stages) {
          row.confirmStage = cf.stages
        } else if (row.deleteArmed) {
          row.requestDelete()
        } else {
          Menu.handleConfirm(itm)
          row.confirmStage = 0
          row.collapse()
          if (itm && itm.close === true) Menu.close()
        }
      }
    }
  }

  // A row that cannot be used right now (see Menu.isUnavailable): a card-toned
  // fill over the whole row mutes the copy underneath instead of the row
  // vanishing, and it fades out the moment every condition starts holding.
  // Drawn last so it covers the open slots too. No outline: the fill is the
  // card color, so it only mutes what is behind it and consecutive muted rows
  // read as one area.
  //
  // The fade is an explicit tween started by the verdict's own change, not a
  // Behavior on the opacity binding. A Behavior also eases the binding's first
  // value at construction - and a page must never fade its muted rows in, they
  // are built muted - so it needs a gate armed from Component.onCompleted,
  // which is one turn after the value it has to leave alone. Starting the
  // tween from the change instead has neither problem: construction only sets
  // the resting value, and a flip that lands mid-fade redirects the box from
  // wherever it already is rather than from an endpoint.
  Rectangle {
    id: muteBox

    // A nested unavailable row is dimmed by its own opacity; a fill here would
    // read as a stray box inside the parent's dropdown.
    visible: !nested
    anchors.fill: parent
    color: Ui.solid("background_0")
    opacity: 0
    // Change detector for row.unavailable_, so the tween is started from a
    // handler of this box's own rather than from a signal name derived from a
    // trailing-underscore property. The initial binding is not a change.
    property bool muted: row.unavailable_

    onMutedChanged: muteBox.settle(MotionPolicy.enabled)

    Component.onCompleted: muteBox.settle(false)

    // `motion` false means "land on the resting value at once": construction,
    // and the animations-off case, which is the same landing without the ease.
    function settle(motion) {
      const want = row.unavailable_ ? 0.6 : 0
      if (!motion) {
        muteFade.stop()
        muteBox.opacity = want
        return
      }
      muteFade.to = want
      muteFade.restart()
    }

    NumberAnimation {
      id: muteFade

      target: muteBox
      property: "opacity"
      duration: Ui.normalMs
      easing.type: Easing.OutCubic
    }
  }
}
