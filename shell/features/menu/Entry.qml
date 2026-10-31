pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import qs.features.menu
import "MenuLib.js" as MenuLib

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
//   OptionRow boxes - arrows drive the cursor, Enter picks. Numbers and
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
  readonly property bool infoOnly: itm && itm.infoOnly === true
  readonly property bool hasStepper: isNumber || isRange

  // Left/Right pages the inline dropdown by this stride, which the
  // library derives from the option count; a single-column dropdown has
  // no stride (0 = key falls through).
  readonly property int optionCount: itm ? (itm.options ?? []).length : 0
  readonly property int optionColumnStride: MenuLib.optionColumnStride(optionCount)
  readonly property bool hasEditor: hasStepper || isText

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
  readonly property bool enabled_: itm && !searchResult
    ? itm.enabled !== false && !Menu.isDisabled(itm) : true

  // Expansion (editors / info body) syncs imperatively from the service
  // store: rev bumps re-apply the canonical value immune to delegate
  // lifecycle churn.
  property int _revEcho: Menu.rev

  on_RevEchoChanged: {
    syncExpanded()
    if (!row.dropdownOpen) return
    const current = !searchResult && itm
      ? (Menu.itemByUid(itm.uid) || itm) : itm
    const opts = row.isFlow && row.flowStep && row.flowStep.options
      ? row.flowStep.options : current ? current.options ?? [] : []
    const optList = Array.isArray(opts) ? opts : Array.prototype.slice.call(opts)
    if (optList.length === 0) {
      row.optionIndex = -1
      return
    }
    if (row.optionIndex < 0) {
      let seed = row.st ? row.st.value : undefined
      if (row.isFlow) {
        const stored = Menu.flowValuesOf(row.itm)[String(row.flowIndex)]
        if (stored !== undefined) seed = stored
      }
      row.optionIndex = MenuLib.optionSeedIndex(optList, seed)
    } else {
      row.optionIndex = Math.max(0, Math.min(row.optionIndex, optList.length - 1))
    }
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
    : (isSelect && expanded && !row.promptOpen)
  readonly property bool editorOpen: row.confirmOpen ? false
    : row.isFlow ? (expanded && (row.flowKind === "number"
      || row.flowKind === "range" || row.flowKind === "text"))
    : ((hasEditor || row.promptOpen) && expanded)

  // Dropdown cursor; -1 closed. Starts on the stored choice so Enter-
  // Enter re-picks it without touching the arrows.
  property int optionIndex: -1

  onDropdownOpenChanged: {
    if (!dropdownOpen) return
    const opts = row.isFlow && row.flowStep && row.flowStep.options
      ? row.flowStep.options : itm ? itm.options ?? [] : []
    const optList = Array.isArray(opts) ? opts : Array.prototype.slice.call(opts)

    // Flow rows seed the cursor from the stored stage value so Back
    // lands on the picked option; plain rows seed from live state.
    // `st` can be null (search hits, or a row with no state yet), and a
    // throw here leaves optionIndex at -1, so the dropdown renders with
    // its cursor on no option until the user steps once.
    let seed = st ? st.value : undefined
    if (row.isFlow) {
      const stored = Menu.flowValuesOf(itm)[String(row.flowIndex)]
      if (stored !== undefined) seed = stored
    }
    if (optList.length === 0) optionIndex = -1
    else optionIndex = MenuLib.optionSeedIndex(optList, seed)
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
  readonly property string warnText: String(itm?.warning ?? "")
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
  // Live font metrics for the separator label below (fontXs, the
  // breadcrumb register's size), so a newborn delegate reports the resting
  // height before its own Text polishes - the same floor pattern the
  // main line uses for its label column.
  FontMetrics {
    id: sepMetrics

    font.pixelSize: Ui.fontXs
    font.family: Ui.fontFamily
  }
  // The group path a search separator names, "" for a bare hairline.
  // Plain breadcrumb text ("a > b"), rendered in the sub-line register.
  readonly property string sepLabel: row.isSep ? String(itm?.label ?? "") : ""
  // Breathing above and below the separator label; the hairline itself
  // needs none. Added on both sides of the line box on the delegate and
  // in the panel estimator alike, so the two stay one number.
  readonly property int sepPadV: 3
  readonly property real sepLineH: Math.max(sepText.implicitHeight, Math.ceil(sepMetrics.height))
  readonly property real sepH: !row.isSep ? 0
    : sepLabel === "" ? 10 : sepLineH + 2 * row.sepPadV
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
  // The theme columns name the record directly as well as through `itm`,
  // because `itm` is a settable alias and a caller that hands this row a
  // normalized payload of its own (a search index entry) is not obliged to
  // have carried the theme fields into it.
  readonly property var palette: itm && itm.palette ? itm.palette
    : (modelData && modelData.palette ? modelData.palette : [])
  // Swatch gate -> the palette Repeater reads this, so non-theme rows
  // instantiate no dot delegates while theme rows render unchanged.
  readonly property bool hasPalette: !!(itm && itm.palette && itm.palette.length > 0)
  readonly property string lightLabel: itm && typeof itm.light === "string" ? itm.light
    : (modelData && typeof modelData.light === "string" ? modelData.light : "")
  readonly property bool isThemeRow: (modelData && typeof modelData.light === "string" && modelData.light !== "")
    || (itm && typeof itm.light === "string" && itm.light !== "")

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
  width: ListView.view ? ListView.view.width : 240
  // Progress bars and range tracks live INLINE in the trail cluster, so
  // every row keeps the same height as its neighbors.
  height: isSep ? sepH
    : Math.max(Ui.rowMinH,
        mainLine.height + 2 * Ui.rowPadV)
      + descSlot.height + expandSlot.height
  opacity: enabled_ ? 1 : 0.4
  readonly property real labelWidth: labelCol.width
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
    ? Math.max(0, Math.min(1, labelCol.width / labelNeeded)) : 1
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
  readonly property int slotMotionMs: _slotMsLatch

  // Called from the slots' open/closing transitions. Re-samples every time a
  // slot starts or stops, and takes the max, so the latch is the largest
  // figure any live slot has offered during this unfold.
  function _latchSlotMs() {
    const live = descSlot.open || descSlot.closing
      || expandSlot.open || expandSlot.closing
    if (!live) {
      row._slotMsLatch = 0
      // The held verdict belongs to the unfold that is over. Releasing here
      // rather than on the next open is what lets a dropdown that does NOT
      // resize the region animate normally on the next keystroke: the hold is
      // a property of one unfold, not of the row, and `release()` clears the
      // gate the Behaviors actually read rather than just the flag.
      row._slotSettle = false
      descSlot.release()
      expandSlot.release()
      return
    }
    const now = Math.max(descSlot.slotMs, expandSlot.slotMs)
    if (now > row._slotMsLatch) row._slotMsLatch = now
  }

  // This unfold resizes the region, and the region resize is not animated.
  //
  // MONOTONIC, for the same reason _slotMsLatch is: the verdict is published
  // while the dropdown is opening and is gone by the time it closes, so the
  // close needs the value the open was given. Taking the latest reading
  // instead would animate the open and not the collapse - one motion, two
  // clocks - which is the seam this exists to remove.
  property bool _slotSettle: false

  // Land both slots at their destination and hold them there. Called from the
  // panel's verdict, never from a slot's own transition: a slot cannot know
  // whether the region is about to grow for it, and asking the row first and
  // the panel second would be a turn too late - the slot's height has already
  // been written by then, and its Behavior has already armed.
  function _settleSlots() {
    if (row._slotSettle) return
    row._slotSettle = true
    if (descSlot.open || descSlot.closing) descSlot.land()
    if (expandSlot.open || expandSlot.closing) expandSlot.land()
  }
  // Panel-side slot claim (see MenuPanel.expansionNeedH).
  readonly property real expandSlotH: expandSlot.height
  // Where this row lands once its slots finish unfolding, known from the
  // moment they open. The list's reveal reads this (List.rowSettledHeight)
  // so a dropdown on the last row is scrolled into view in ONE ease that
  // runs alongside the slot's own, instead of being chased frame by frame
  // - chasing it decelerates to a stop at each handover and lurches on.
  readonly property real restHeight: isSep ? sepH
    : Math.max(Ui.rowMinH,
        mainLine.height + 2 * Ui.rowPadV)
  readonly property real settledHeight: isSep ? sepH
    : restHeight + descSlot.settledH + expandSlot.settledH

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
      if (_wasFiltered && Menu.scopedActive) Menu.clearScoped()
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
      if (_wasFiltered && Menu.scopedActive) Menu.clearScoped()
    }
  }

  function setExpanded(value) {
    if (!itm || searchResult) return
    Menu.setExpanded(itm, value)
  }

  function collapse() {
    setExpanded(false)
    optionIndex = -1
    row.confirmStage = 0
    row.deleteArmed = false
    row.promptOpen = false
    if (row.isFlow && itm) Menu.resetFlow(itm)
  }

  // Drive the select value swap. Called from selectText's own text
  // change: the outgoing label is what the slot was showing, the
  // incoming one is already in the live Text. A first fill (blank
  // before) and a slot that renders nothing (action-select, theme rows)
  // swap plain.
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
    const opts = row.isFlow && row.flowStep && row.flowStep.options
      ? row.flowStep.options : itm ? itm.options ?? [] : []
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

  function pickCurrent() {
    if (!dropdownOpen || !itm) return false
    const opts = row.isFlow && row.flowStep && row.flowStep.options
      ? row.flowStep.options : itm.options ?? []
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
  // when parseable, else the row value. One place feeds both the picker's
  // value and its seed text, so Back-restored input and first-open
  // defaults always agree (and the seed text below can pair the value
  // with the STAGE suffix - the row-level display uses the top-level
  // unit, which one-shot rows like Add timer do not declare).
  function flowSeedNumber() {
    if (row.isFlow && (row.flowKind === "number" || row.flowKind === "range")) {
      const raw = Menu.flowValuesOf(itm)[String(row.flowIndex)]
      if (raw !== undefined) {
        const n = Number(String(raw).trim().split(/\s+/)[0])
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
      if (_wasFiltered && Menu.scopedActive) Menu.clearScoped()
    }
  }

  function toggleInfo() {
    if (!itm || searchResult || (descText === "" && warnText === "")) return
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
    Menu.runCommand(itm.onChange, next.toFixed(decimals) + unitSuffix)
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
      // keeps the clear-then-run behaviour.
      if (itm && itm.var !== undefined && itm.var !== "") {
        Menu.setValue(itm, t)
        if (t !== "" && itm.onSubmit) Menu.runCommand(itm.onSubmit, t)
        collapse()
        return
      }
      // Empty means "no value": clear quietly and leave.
      Menu.setValue(itm, "")
      if (t !== "") Menu.runCommand(itm.onSubmit, t)
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
        Menu.runCommand(itm.onChange, next.toFixed(decimals) + unitSuffix)
      collapse()
      return
    }
    Menu.setValue(itm, next)
    if (Menu.handleNumberChange(itm, next)) { collapse(); closeIfArmed(); return }
    Menu.runCommand(itm.onChange, next.toFixed(decimals) + unitSuffix)
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
    id: bg

    anchors.fill: parent
    visible: !row.isSep
    // Always transparent: the ListView sliding highlight bar paints the
    // selection behind the rows (see MenuPanel list highlight). Fading
    // this rect instead blended mid-tones over the card and flashed.
    // Keyboard/click cursor only - no hover tints.
    color: "transparent"
  }

  Divider {
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Ui.m + 2
    anchors.rightMargin: Ui.m + 2
    visible: row.isSep
  }

  // Labeled group separator: the breadcrumb text sits on a chip of the
  // card background occluding the hairline behind it, so the path takes
  // whatever width it needs and the line fills the rest. The chip starts
  // half a spacing unit left of the entries' own edge, putting the text
  // flush with entry labels; the divider keeps its own insets behind.
  // Unlabeled separators keep the bare full-bleed line above.
  Rectangle {
    visible: row.isSep && row.sepLabel !== ""
    anchors.left: parent.left
    anchors.leftMargin: Ui.m - Ui.s / 2
    anchors.verticalCenter: parent.verticalCenter
    width: sepText.width + Ui.s
    height: sepText.height
    color: Ui.solid("background_0")

    Text {
      id: sepText

      anchors.left: parent.left
      anchors.leftMargin: Ui.s / 2
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, row.width - 2 * (Ui.m + 2) - Ui.s)
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
    id: clickArea

    anchors.fill: parent
    enabled: !row.isSep
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

  WheelHandler {
    enabled: row.hasStepper && row.enabled_

    onWheel: wheel => row.stepBy(wheel.angleDelta.y > 0 ? 1 : -1)
  }

  // --- main line: icon | label | trail cluster ---

  Item {
    id: mainLine

    visible: !row.isSep
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Ui.m
    anchors.rightMargin: Ui.m
    anchors.top: parent.top
    anchors.topMargin: Ui.rowPadV
     // Synchronous line-stack height. ListView displaces neighbors during
    // incremental inserts using creation-time geometry, but a Column only
    // reports its height after its first polish pass - one frame late,
    // which made revealed rows overlap the entry under them by exactly
    // the missing delta. The Texts know their metrics immediately, so
    // compute the stack from those; the Column below remains THE layout -
    // it settles to this same number a frame later.
      readonly property int labelColH: isThemeRow
        // Theme rows: the title line, the 8px swatch strip, and the Column's
        // one spacing unit between them. The strip is dots alone, so the dot
        // size is the line's height - no text on it to measure, and the
        // estimate MenuPanel snaps the card against reads this same number.
        ? lbl.implicitHeight + 1 + 8
        // The second line, measured off the Row's own height: tallest of the
        // copy that is actually there, usually the muted text, and the lead
        // on a lead-only row, so an empty muted Text can never clip it. A
        // visibility flag cannot decide this - see the Row below.
        : lbl.implicitHeight + (subRow.height > 0 ? 1 + subRow.height : 0)

    height: labelColH

    Icon {
      id: iconImg

      visible: row.iconName !== ""
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      size: Ui.rowIconW
      name: row.iconName
      // The active theme's accent belongs to its NAME alone. The glyph stays
      // in the ordinary foreground so the row reads as "this one is marked"
      // rather than three separate things lighting up, and so the swatch
      // strip below - which is painted in the theme's real colours and is the
      // whole point of the row - is the only place colour is sampled.
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
      id: glyphImg

      visible: row.glyphText !== ""
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Ui.rowIconW
      height: Ui.rowIconW
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      text: row.glyphText
      color: Ui.solid("foreground_0")
      font.pixelSize: Math.round(Ui.rowIconW * 0.86)
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
        : (row.isSubmenu || row.searchResult) ? chevronFwd.left
        : row.isExpandable ? chevronExp.left
        : parent.right
      anchors.rightMargin: Ui.s
      anchors.verticalCenter: parent.verticalCenter
      spacing: 1

        // Title line. The theme's own colours and the word qualifying them
        // take the line below rather than riding the name: the name is what
        // the row is picked by, and a qualifier hanging off it in a muted
        // grey only competes with the accent an active row paints it in.
        Text {
          id: lbl
          // Sized to the NAME: the swatch line below is full width in its own
          // right, so nothing on this line shares it. Capped at the Column's
          // width so a long name elides instead of running into the trail.
          width: Math.min(implicitWidth, parent.width)
          text: row.displayLabel
          color: (row.isThemeRow && row.mark) ? Theme.color("accent") : Theme.color("foreground_0")
          font.pixelSize: Ui.fontL
           font.family: row.previewFontFamily !== "" ? row.previewFontFamily : Ui.fontFamily
           elide: row.textReveal < 1 ? Text.ElideNone : Text.ElideRight
           clip: row.textReveal < 1
           opacity: row.textReveal
           textFormat: Text.PlainText
        }

        // Sizing row kept for height compat, hidden
        Row {
          id: themeSubRow
          width: parent.width
          visible: false
          height: 0
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
          // a `visible: false`, and the height is the tallest child that
          // actually has copy to show - a lead-only row measures the lead, so
          // a near-zero muted Text can never clip it.
          //
          // A `visible` gate here is read once while the delegate is mid-swap
          // and nothing re-asserts it: a row that opened with its subtext lost
          // the line for the rest of the session, and the flag then drifted
          // onto rows that have no subtext at all. An empty Text still
          // measures one line, so "no copy" alone cannot stand in for the
          // gate either - hence the measurement.
          height: Math.max(
            subLeadEl.text !== "" ? subLeadEl.implicitHeight : 0,
            subMain.text !== "" ? subMain.implicitHeight : 0,
            subTail.text !== "" ? subTail.implicitHeight : 0)

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
            // Empty rather than hidden when there is no muted copy to show: a theme
            // row spends the second line on its own light label, so the two
            // never both draw. The Row above measures `text`, which is why
            // nothing here needs a visibility flag.
            text: row.lightLabel !== "" || row.subText === "" ? ""
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

        // Swatch line: the theme's own colours as 8px dots, and nothing else.
        // The mode is the row's icon now, and a family's variant count is
        // what its own dropdown is for, so a second text column here would
        // only repeat what the glyph and the list already say. The line is
        // the strip alone, so its height is the dot's own size.
        Row {
          id: paletteRow
          width: parent.width
          visible: !!(itm && itm.palette && itm.palette.length > 0)
          spacing: 4
          Repeater {
            // Gated on the row actually carrying a palette -> non-theme
            // rows own no dot delegates; theme rows fill as before.
            model: row.hasPalette ? itm.palette : []
            delegate: Rectangle {
              required property var modelData
              required property int index
              width: 8
              height: 8
              radius: 4
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
      anchors.rightMargin: Ui.barGap
      anchors.verticalCenter: parent.verticalCenter
      visible: row.isRange
      width: Ui.barW
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
          const frac = Math.min(1, Math.max(0, x / Math.max(1, width)))
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
      anchors.rightMargin: Ui.barGap
      anchors.verticalCenter: parent.verticalCenter
      visible: row.ptype === "progress"
      width: Ui.barW
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
      text: Math.round(row.ratio * 100) + " %"
      color: Ui.tint("foreground_1", 0.75)
      font.pixelSize: Ui.fontS
      font.family: Ui.fontFamily
      textFormat: Text.PlainText
      elide: Text.ElideNone
      clip: false
      wrapMode: Text.NoWrap

      TextMetrics {
        id: pctMetrics

        font.pixelSize: Ui.fontS
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
      font.pixelSize: Ui.fontS
      font.family: Ui.fontFamily
      font.bold: row.editorOpen || row.valueActive
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
        id: valueMetrics

        font.pixelSize: Ui.fontS
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
      font.pixelSize: Ui.fontS
      font.family: Ui.fontFamily
      elide: Text.ElideNone
      clip: false
      wrapMode: Text.NoWrap
      textFormat: Text.PlainText

      transform: Translate { id: ghostShift; y: 0 }

      TextMetrics {
        id: ghostMetrics

        font.pixelSize: Ui.fontS
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
      visible: row.isSelect && !row.isActionSelect && row.lightLabel === ""
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
      font.pixelSize: Ui.fontS
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

        font.pixelSize: Ui.fontS
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
      font.pixelSize: Ui.fontS
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

        font.pixelSize: Ui.fontS
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
      width: visible ? Ui.chevronW : 0
      height: 16
      visible: row.isSubmenu || row.searchResult

      Chevron {
        anchors.centerIn: parent
        direction: "right"
        color: row.sel ? Theme.color("accent")
          : Ui.tint("foreground_1", 0.5)
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
      width: visible ? Ui.chevronW : 0
      height: 16
      visible: row.isExpandable && !row.infoOnly && (row.descText !== "" || row.bodyText !== "")

      Chevron {
        anchors.centerIn: parent
        direction: row.expanded ? "up" : "down"
        color: row.expanded || row.sel ? Theme.color("accent")
          : Ui.tint("foreground_1", 0.5)
      }
    }

    // option rows (dropdown cells): bullet gutter
    Item {
      id: optMark

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

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: mainLine.bottom
    // One gap value everywhere around the hairline: row-to-line,
    // line-to-text and text-to-next-row all read Ui.m, so the separator
    // sits centered between entry and description by construction.
    anchors.topMargin: Ui.m
    open: row.descInSlot
    onOpenChanged: row._latchSlotMs()
    onClosingChanged: row._latchSlotMs()

    Column {
      x: Ui.m
      width: parent.width - 2 * Ui.m
      spacing: Ui.m

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

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: mainLine.bottom
    // Same hairline rhythm as the ctrl+i slot: one gap value everywhere
    // (row-to-line, line-to-content, content-to-next-row), so an opened
    // editor or dropdown breathes identically to a description.
    anchors.topMargin: Ui.m
    open: row.expanded
    onOpenChanged: row._latchSlotMs()
    onClosingChanged: row._latchSlotMs()

    Loader {
      id: expLoader

      active: row.expanded || expandSlot.closing
      width: parent.width
      // Continuous binding: adopt-once would freeze the height before
      // content finished laying out.
      height: item ? item.implicitHeight : 0
      sourceComponent: expansionComp
    }
  }

  onExpandedChanged: {
    if (expanded) {
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
      const view = row.ListView.view
      if (view && view.autoRevealIndex === index) view.autoRevealIndex = -1
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
      const view = row.ListView.view
      if (view && view.autoRevealIndex === index) view.autoRevealIndex = -1
    }
  }

  Component.onDestruction: {
    const view = row.ListView.view
    if (view && view.autoRevealIndex === index) view.autoRevealIndex = -1
  }

  // Expansion shell: the editor or the body text, plus - when the item
  // carries a description alongside an interactive editor - a hairline
  // separating the ctrl+i block underneath.
  Component {
    id: expansionComp

    Column {
      id: wrapCol

      function takeFocus() {
        const inner = innerLoader.item
        if (inner && inner.takeFocus) inner.takeFocus()
      }

      width: parent.width
      spacing: Ui.m

      readonly property bool editorView: row.editorOpen
      readonly property bool confirmView: row.confirmOpen
      readonly property bool showDesc: row.descInShell
        && row.descText !== ""
      // Warning rides the same expansion shell, always BELOW the
      // description under the block's single hairline - which stays in
      // place even when no description precedes the warning.
      readonly property bool showWarn: row.descInShell
        && row.warnText !== ""
      // Staged-flow slide: the incoming stage glides in from the right
      // (24px -> 0, 0 -> 1 opacity, Ui.fastMs OutCubic) while the slot's
      // own height still eases on the shared Glide curve. Animations off
      // cuts instantly - no offset, no fade.
      Item {
        id: stageHost

        width: parent.width
        height: innerLoader.height
        // Closed is its own key (-1): the first view on expand never
        // slides - the slot height glide already announces the opening.
        // Only view-to-view swaps within one expansion glide (dropdown ->
        // editor, stage to stage, back again). Opening (-1 -> view) and
        // closing (view -> -1) cut instantly.
        property int stageKey: !row.expanded ? -1
          : row.isFlow ? row.flowIndex
          : row.dropdownOpen ? 1001 : row.editorOpen ? 1002
          : row.confirmOpen ? 1003 : 1000
        property int _prevStageKey: -1

        onStageKeyChanged: {
          const swap = stageHost._prevStageKey !== -1 && stageHost.stageKey !== -1
          stageHost._prevStageKey = stageHost.stageKey
          if (swap && MotionPolicy.enabled) { stageSlide.restart(); stageFade.restart() }
          else { innerLoader.x = 0; innerLoader.opacity = 1 }
        }

        Loader {
          id: innerLoader

          width: parent.width
          height: item ? item.implicitHeight : 0
          sourceComponent: wrapCol.confirmView ? confirmComp
            : wrapCol.dropdownView ? optionsComp
            : wrapCol.editorView ? editorComp
            : row.expanded ? bodyComp : null
        }

        NumberAnimation {
          id: stageSlide

          target: innerLoader
          property: "x"
          from: 24
          to: 0
          duration: Ui.fastMs
          easing.type: Easing.OutCubic
        }

        NumberAnimation {
          id: stageFade

          target: innerLoader
          property: "opacity"
          from: 0
          to: 1
          duration: Ui.fastMs
          easing.type: Easing.OutCubic
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

      // Single hairline over the info block: it sits above the
      // description when one exists, else directly above a lone
      // warning - never one line per section.
      Divider {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Ui.m
        visible: wrapCol.showDesc || wrapCol.showWarn
        color: Ui.tint("background_3", 0.8)
      }

      Item {
        width: parent.width
        height: visible ? descLabel.height : 0
        visible: wrapCol.showDesc

        BodyText {
          id: descLabel

          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: Ui.m
          markup: true
          text: MenuLib.styledMarkup(row.descText)
        }
      }

      // Warning trails the description with no separator of its own -
      // the block shares the single hairline above. Declarative copy,
      // so it renders the same whitelisted inline markup as desc.
      Notice {
        message: MenuLib.styledMarkup(row.warnText)
        markup: true
        x: Ui.m
        width: parent.width - 2 * Ui.m
        visible: wrapCol.showWarn
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
      readonly property int count: row.isFlow && row.flowStep
        ? (row.flowStep.options ?? []).length : row.itm ? (row.itm.options ?? []).length : 0
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

      Rectangle {
        id: optCursor

        visible: row.dropdownOpen
        color: Theme.color("background_1")
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
          model: row.isFlow && row.flowStep && row.flowStep.options
            ? row.flowStep.options : row.itm ? row.itm.options ?? [] : []

          delegate: OptionRow {
            width: optsRoot.cellW
            // The card is mid-width while its glide runs; each entry
            // reveals its copy with the growth, like normal rows do.
            settling: row.cardSettling
            cursor: row.optionIndex === index
            chosen: (row.itm && row.itm.marker === false) ? false : (row.st ? String(row.st.value) === String(modelData.value) : false)
            onPicked: value => row.pick(value)
          }
        }
      }
    }
  }

  Component {
    id: editorComp

    InlineEditor {
      width: parent.width
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

      onCommit: text => row.commitEditor(text)
      onInvalid: msg => row.showEditorError(msg)
      onRecovered: row.clearEditorError()
      onEscaped: { if (!row.backFlow()) row.collapse() }
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
}
