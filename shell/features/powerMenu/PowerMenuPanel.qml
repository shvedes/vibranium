pragma ComponentBehavior: Bound
// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import qs.common
import qs.features.powerMenu
import "../../common/ui/SlotGrowth.js" as SlotGrowth

// Power menu card - declarative via PanelCard + PanelFocus.
// Filtering is simple substring AND over label/sub/desc.
PanelCard {
  id: panel

  maxHeight: 600
  hardMaxHeight: 1200
  outerPad: Ui.outerPad
  filterH: Ui.filterH
  listTopGap: Ui.listTopGap
  emptyMinH: Ui.emptyMinH
  baseWidth: 360
  rowIconW: 26
  _maxLabelW: 400
  count: list.count
  contentHeight: list.contentHeight
  rows: panel._rows
  // The gap between rows is the LIST's, read rather than assumed: the card
  // sums the same gap the list places, so the region's bottom edge stays on
  // a row boundary whatever a surface decides to space its rows by.
  rowSpacing: list.spacing
  exactListH: count > 0 ? list.fitHeight(panel.availListH) : -1
  // The list owns the growth claim (List.revealNeedH) and the rule that turns
  // it into a region lives once, in SlotGrowth.js - the same one the menu,
  // the launcher and the password manager use, so a staged confirm under an
  // action row cannot be sized by a different geometry than a dropdown
  // anywhere else in the shell.
  //
  // `slotOpen` is separate from the region override because a slot that fits
  // in the resting region asks for no resize while still making the content
  // taller; see PanelCard._latchRestingBuffer.
  slotOpen: list.revealNeedH > 0
  slotRegionH: SlotGrowth.regionForSlot(
    list, panel.restingListH, panel.screenMaxListH, Ui.s)
  // A keystroke is a real resize, so the card glides to its fitted height
  // even inside the show gate - the launcher carve-out, same rule: without
  // this a filter typed before the appear animation finishes snaps.
  sizeMotionDuringGate: panel.searching
  // The fault box is all that is card-level now: the confirm stage is a row
  // slot, so it grows the list's own region instead of the card's reserve.
  bottomReserve: panel.reserveH

  readonly property bool searching: PowerMenu.query !== ""
  readonly property var _rows: PowerMenu.results

  // The staged confirm under one destructive row. One action at a time, and
  // the ACTION is the service's (PowerMenu.confirmationAction - the only thing
  // confirmPending will run), while the row and the stage are the panel's,
  // exactly as they are for the clipboard, launcher, pass and wallpaper-picker
  // rows. So the question opens under the action that asked for it and the
  // list grows for it; the card reserves nothing below the list.
  property int _confirmIndex: -1
  property int _confirmStage: 0
  readonly property bool armed: panel._confirmIndex >= 0
  // Open OR still folding shut. The two are not the same span on purpose:
  // `_confirmIndex` ends at the cancel, the list claim ends when the slot is
  // flat (see closeConfirm), and anything that must not read a slot-inflated
  // geometry - the height table's guard, the highlight bar - spans both.
  readonly property bool slotInFlight: panel.armed || list.autoRevealIndex >= 0

  // One box for both faults: a config fault names the file state, a dispatch
  // fault names the verdict Session returned. Both clear on the next arm.
  readonly property string faultMessage: PowerMenu.configFaultMessage !== ""
    ? PowerMenu.configFaultMessage
    : (panel._faultText[PowerMenu.dispatchFault] ?? "")
  readonly property var _faultText: ({
    confirmation_required: "Session needs an on-screen confirmation for that action",
    unknown_action: "Session did not run that action",
    busy: "A session action is already running",
    failed: "The session action could not start",
    confirmation_unavailable: "Session exposes no confirmation gate",
    dispatch_error: "The confirmation could not be delivered",
    nothing_to_confirm: "Nothing to confirm"
  })
  readonly property real reserveH: faultNotice.height > 0 ? faultNotice.height + Ui.s : 0

  readonly property bool primarySurface: visible
  property int _swapGen: 0
  property bool _rowsPending: false
  // The record array the model shows. syncRows is its only writer and the
  // ScriptModel below reads it through `values`, so this is the model's whole
  // data path - and it holds the same record objects a filter returns, never
  // copies of them, which is what keeps a payload comparison by identity from
  // calling every keystroke a change.
  property var _records: []
  // Keyed action rows. Keys are the action id (stable across filtering,
  // which returns the same record objects), so a query change diffs
  // incrementally instead of resetting the view and losing the bar.
  ScriptModel {
    id: actionModel
    values: panel._records
    // `id` is the identity the height table already keys on and the one this
    // panel already treats as a row key, so the model's own identity field
    // and List's rowIdentity name the same thing. The records reach the
    // delegate whole, as modelData - there is no wrapper role to unwrap.
    objectProp: "id"
    // Payloads compare by identity, as they did under the keyed model: a
    // record mutated in place after a sync was invisible there, and the
    // default (Structure) would compare by content and re-emit it.
    comparisonMode: ObjectComparison.Identity
  }
  // Identity epoch for List's height table. A ScriptModel reports neither a
  // revision nor a key-set flag, so the panel owns the counter: the key
  // sequence is folded into _keySeq, and every sequence that differs from the
  // last one advances the epoch. A fingerprint alone would not do - List.qml
  // wants the revision monotone, and reordering back to an earlier sequence
  // repeats a fingerprint. Driven from a handler rather than from a binding,
  // because a binding that writes the value it reads is a loop and the engine
  // reports one on every pass.
  property int identityRevision: 0
  property var _keySeq: ""
  Connections {
    target: actionModel
    function onValuesChanged() {
      const seq = panel.keySeq(panel._records)
      if (seq === panel._keySeq) return
      panel._keySeq = seq
      panel.identityRevision = panel.identityRevision + 1
    }
  }
  function keySeq(rows) {
    const pool = Array.isArray(rows) ? rows : []
    let seq = ""
    for (let i = 0; i < pool.length; i++) {
      const rec = pool[i]
      // A space separates the keys, and PowerMenu normalizes every id at
      // load (whitespace runs -> '-'), so no id can hold one: the separator
      // cannot forge a boundary between two rows' keys.
      if (i > 0) seq += " "
      seq += String(rec && rec.id !== undefined ? rec.id : "")
    }
    return seq
  }
  // The one refusal the keyed model's validate does not make. ScriptModel
  // accepts a duplicate id - four rows in, four rows out, no error - so this
  // stays here: two config entries that normalize to the same id would
  // otherwise put two live rows on one identity, and all List can do with
  // that is refuse to measure either of them.
  function keyedRows(source) {
    const pool = Array.isArray(source) ? source : []
    const rows = new Array(pool.length)
    const seen = {}
    for (let i = 0; i < pool.length; i++) {
      const rec = pool[i]
      const key = String(rec && rec.id !== undefined ? rec.id : "")
      if (key === "" || seen[key] !== undefined) return null
      seen[key] = true
      rows[i] = rec
    }
    return rows
  }

  Component.onCompleted: {
    PowerMenu._attachPanel(panel)
    panel.syncRows()
  }
  Component.onDestruction: PowerMenu._detachPanel(panel)
  TapHandler { onTapped: focusCtrl.grabFilter() }

  Connections {
    target: PowerMenu
    function onResultsChanged() {
      panel.closeConfirm()
      panel.syncRows()
      if (!panel.searching) panel.recalcWidth()
    }
    function onVisibleChanged() {
      if (!PowerMenu.visible) { focusCtrl.mode = "list"; return }
      panel.show()
      searchField.text = ""
      list.settle(0, true)
      focusCtrl.grabList()
    }
    // The service disarms wherever it owns the stage - a config reload, the
    // surface closing, the confirm path - so the row's dropdown follows the
    // action it names rather than outliving it.
    function onConfirmationArmedChanged() {
      if (!PowerMenu.confirmationArmed) panel.closeConfirm()
    }
  }

  function syncRows() {
    if (panel._rowsPending) return
    panel._rowsPending = true
    Qt.callLater(() => {
      panel._rowsPending = false
      panel._swapGen++
      const g = panel._swapGen
      list.swapRun(g, v => v === panel._swapGen, () => {
        const rows = panel.keyedRows(panel._rows)
        // One write with nothing behind it. `values` is the only write a
        // ScriptModel has and it cannot be mutated from outside, so the
        // repair pass the keyed model needed - a refusal returned as a result
        // code, then a deliberate full replace - has no counterpart to run. A
        // refused set still writes nothing at all, exactly as it did when
        // both writes were skipped: the previous rows stay on screen until a
        // set that passes arrives.
        if (rows !== null) panel._records = rows
        list.settle(0, true)
      })
      Qt.callLater(() => panel.reassertFocus())
    })
  }
  function reassertFocus() { focusCtrl.reassert() }

  PanelFocus {
    id: focusCtrl
    searchField: searchField
    serviceVisible: PowerMenu.visible
  }
  readonly property alias input: searchField.input
  property alias mode: focusCtrl.mode
  function grabList() { focusCtrl.grabList() }
  function grabFilter() { focusCtrl.grabFilter() }

  function currentRow() { return list.currentItem }
  function moveSelection(dir) {
    if (!list.move(dir)) return
    // Leaving the armed row closes its dropdown.
    if (panel.armed && panel._confirmIndex !== list.currentIndex) panel.closeConfirm()
  }
  // Open the staged confirm under `idx`. Arming is what the activation did:
  // the service holds the action name, this holds the row it went with.
  function armConfirm(idx) {
    panel._confirmIndex = idx
    panel._confirmStage = 1
    list.autoRevealIndex = idx
  }
  // One stage per activation, from either direction - Enter on the armed row
  // or a click on its button - so the hint and the armed state cannot be
  // reached by two different rules.
  function advanceConfirm() {
    if (panel._confirmStage >= 2) { PowerMenu.confirmPending(); return }
    panel._confirmStage++
  }
  function closeConfirm() {
    if (panel._confirmIndex < 0 && !PowerMenu.confirmationArmed) return
    panel._confirmIndex = -1
    panel._confirmStage = 0
    PowerMenu.cancelPending()
    // The list's claim is NOT released here, and that is the whole of the
    // "collapsing the dropdown grows the window and leaves a gap under the
    // list" defect. `autoRevealIndex` IS the card's `slotOpen`, so clearing it
    // at the START of the collapse tells the card no slot is open one turn
    // before the row is actually flat - and `_latchRestingBuffer` takes its
    // next sample right then, latching the inflated contentHeight as the
    // RESTING size. It only re-latches on a row-set change, so the card stayed
    // 60px too tall with the collapsed dropdown's gap still in it, across
    // reopens.
    //
    // Measured on this panel with the claim released at the collapse (row 4 of
    // 6, a 62px slot):
    //   open     contentHeight 354  restingBufH 0     region 292  card 364
    //   +1 turn  row still 87px     restingBufH 354   region 354  card 426
    //   settled  contentHeight 292  restingBufH 354   region 354  card 426
    //
    // So the claim is released by the row that owns it, on the slot's own
    // terminal edge (releaseReveal), which is also after any destruction that
    // takes the row with it. Until then the claim keeps `slotOpen` true, which
    // keeps both resting latches gated - that is what they are gated FOR.
  }
  // Released by the row whose slot held the claim, once that slot has finished
  // collapsing (DropdownSlot.closeFinished) or is being destroyed. Guarded on
  // the claim itself, so a row still folding shut cannot release a claim a
  // later arming has already taken for another row.
  function releaseReveal(idx) {
    if (list.autoRevealIndex !== idx) return
    list.autoRevealIndex = -1
  }
  function activateCurrent() {
    const idx = list.currentIndex
    if (idx < 0 || idx >= panel._rows.length) { list.settle(0, true); return }
    // An armed dropdown is modal for its own row: the next activation on it
    // arms the second stage, the one after that confirms. Any other row
    // answers nothing - its own activation routes instead.
    if (panel.armed && panel._confirmIndex === idx) { panel.advanceConfirm(); return }
    panel.closeConfirm()
    PowerMenu.activate(panel._rows[idx])
    // A destructive row arms the service's stage instead of dispatching, and
    // the dropdown is that stage seen on the row that asked for it. Reading
    // the armed flag rather than testing destructiveness here keeps the
    // one rule in the service, where the allowlist lives.
    if (PowerMenu.confirmationArmed) panel.armConfirm(idx)
  }
  function escapeChain() {
    if (panel.armed) { panel.closeConfirm(); return }
    if (focusCtrl.mode === "filter") {
      if (PowerMenu.query !== "") { PowerMenu.clearQuery(); searchField.text = ""; return }
      focusCtrl.grabList(); return
    }
    if (PowerMenu.query !== "") { PowerMenu.clearQuery(); searchField.text = ""; return }
    PowerMenu.close()
  }
  function scrollBy(factor) { list.pageBy(factor) }
  function jumpEnd(last) { list.jumpEnd(last) }

  function handleKey(event) {
    const k = event.key
    const ctrl = event.modifiers & Qt.ControlModifier
    const meta = event.modifiers & Qt.MetaModifier
    if (k === Qt.Key_F && ctrl) { focusCtrl.grabFilter(); event.accepted = true; return }
    switch (k) {
      case Qt.Key_Down:
      case Qt.Key_Tab: panel.moveSelection(1); event.accepted = true; return
      case Qt.Key_Up:
      case Qt.Key_Backtab: panel.moveSelection(-1); event.accepted = true; return
      case Qt.Key_PageUp: panel.scrollBy(-0.8); event.accepted = true; return
      case Qt.Key_PageDown: panel.scrollBy(0.8); event.accepted = true; return
      case Qt.Key_Home: panel.jumpEnd(false); event.accepted = true; return
      case Qt.Key_End: panel.jumpEnd(true); event.accepted = true; return
      case Qt.Key_Escape: panel.escapeChain(); event.accepted = true; return
      case Qt.Key_Return:
      case Qt.Key_Enter: panel.activateCurrent(); event.accepted = true; return
      case Qt.Key_Backspace:
      case Qt.Key_Delete:
        if (focusCtrl.mode === "list") { focusCtrl.grabFilter(); event.accepted = true; return }
        break
      case Qt.Key_Space:
        if (focusCtrl.mode === "list" && !searchField.focused) { panel.activateCurrent(); event.accepted = true; return }
        break
    }
     if (!ctrl && !meta && event.text.length === 1 && event.text.charCodeAt(0) >= 32) {
       if (focusCtrl.mode === "list") {
         PowerMenu.submit(event.text)
         searchField.text = event.text
         focusCtrl.grabFilter()
         event.accepted = true
       }
     }

  }
  Keys.onPressed: event => panel.handleKey(event)

  Item {
    id: filterBar
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: panel.outerPad
    anchors.rightMargin: panel.outerPad
    anchors.topMargin: panel.outerPad
    height: panel.filterH
    InputField {
      id: searchField
      anchors.fill: parent
       implicitHeight: panel.filterH
       placeholder: "Filter power actions..."
       inputRole: "filter"
       filterIconAlways: true
      clearable: false
       onEdited: text => PowerMenu.submit(text)

      onAccepted: panel.activateCurrent()
      onEscaped: panel.escapeChain()
    }
  }

  Item {
    id: listBox
    anchors.top: filterBar.bottom
    anchors.topMargin: panel.listTopGap
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: panel.outerPad
    anchors.rightMargin: panel.outerPad
    height: panel.listRegionH
    List {
      id: list
      anchors.fill: parent
      // Bound once: the model object is the single data path, and a filter
      // change writes only its `values`, so the diff happens inside the model
      // instead of handing the view a new one - the view keeps its state.
      model: actionModel
      interactive: false
      // Library highlight glides for focus moves, filtered or not
      // - same gate as MenuPanel, narrowed to the cursor-row rule every panel
      // with in-flow slots keeps: the bar snaps while the focused row carries
      // an unfolding confirm, because it rides that row's height.
      highlightMotion: MotionPolicy.enabled && panel._confirmIndex !== list.currentIndex
      // Never learn while a slot is open OR still folding shut (see
      // LauncherPanel): the slot is in-flow under the row, so an inflated
      // height would poison the table's average and the fit would resolve
      // against a height no row carries again. `slotInFlight` and not `armed`,
      // because the collapse outlives the cancel by a whole slot animation.
      measureGuard: idx => !panel.slotInFlight
      // Height table keyed by row identity. A submit re-sorts `results` on
      // every keystroke, and the rows are two lines only when a sub is
      // present, so index keys would hand a measured height to whichever row
      // slid into that slot. The key is the action id, the same field
      // objectProp names, and `keyedRows` refuses a set with a missing or
      // repeated id, so the keys are unique by the time they reach here. The
      // index fallback is what keeps a row renderable for a record the key
      // lookup would rather not name.
      rowIdentity: index => String(actionModel.values[index]?.id ?? index)
      // Identity epoch for the height table, counted by the panel (see
      // identityRevision): it advances whenever the key SEQUENCE changes, so
      // a re-rank that keeps the same count and the same first and last
      // action still moves it and prunes what the new key set no longer
      // claims.
      identityRevision: panel.identityRevision
      // NO trailing space here, and this is the whole of the "the power menu
      // scrolls a couple of pixels instead of showing every action" bug.
      //
      // trailSpace is a VIEW FOOTER: it lives inside contentHeight, so it is
      // real content the card must own room for. `exactListH` does own it -
      // fitHeight adds the trail to the last row's bottom edge before testing
      // it against `avail` (List.qml:687). But the card's resting region
      // falls back to MODEL math - modelContentH / snappedListH through
      // RowMetrics, which sums rows and inter-row gaps and knows nothing
      // about a list's footer. So the two disagree by exactly the trail, and
      // the fallback wins on every open: PanelCard.show() drops _restingFitH
      // and restingBufH, and nothing re-latches the fit until `exactListH`
      // CHANGES - which on a reopen with the same six actions it does not.
      //
      // Measured live on this panel (six actions, 47px rows, trail 2):
      //   open        contentHeight 294, viewH 292, over 2, region 292
      //   after a keystroke and back: contentHeight 294, viewH 294, over 0
      // The 2px that reappears on every open is the footer's, and the last
      // row is cut by it. outerPad below the region is already the single
      // bottom-gap authority (the same reason MenuPanel.qml:3823-3826 holds
      // its list at 0, as the launcher, clipboard and wallpaper picker do):
      // an in-content pad stacks with it while the region does not know.
      trailSpace: 0
      clip: true
      // The list reveals the armed row's confirm: the claim the card grows
      // for is the list's (see slotRegionH above), and the seat is the list's
      // to take when the row does not fit the region.
      autoRevealEnabled: true
      delegate: Item {
        id: row
        required property int index
        // A ScriptModel exposes exactly one role, and it is the record
        // itself: modelData IS the row, not a wrapper carrying it under a
        // payload key and not a per-row delegate context object. The identity
        // is reachable as modelData.id, which is the field objectProp names.
        required property var modelData

        // Resting line heights from the RECORD (sub presence) and the font
        // metrics, ceil'd to the line box - the same floor the launcher entry
        // carries (LauncherEntry.qml:129-152). A newborn delegate has not
        // polished, so its Texts report no implicit height, the label column
        // measures 0 and the row sits at the Ui.rowMinH floor until they do.
        //
        // Measured on this panel, at delegate birth with six actions loaded:
        // rows 34,34,34,34,34,34 (true content 216) before the polish,
        // 47,47,47,47,47,47 (294) after - so the growth is real, 13px a row.
        //
        // It is NOT what made the card short, and the distinction is the
        // reason this floor is hardening rather than the fix: `exactListH`
        // TRACKS it. Writing one delegate's height by hand, changing nothing
        // else, moved the card's fit by exactly the 20px written
        // (294 -> 314), with the fit equal to the true content on both
        // sides - so the fit's read of `itemAtIndex(i).height` is a real
        // dependency and the card recovers on its own. See trailSpace above
        // for the 2px that actually did not recover.
        //
        // What the floor buys is that the row's height is the same number at
        // birth and at rest, so the height table's first measurement of a row
        // is the row's real one and the selection bar - which rides the
        // cursor row's height - does not jump on the frame the text
        // polishes. Same argument as LauncherEntry's.
        //
        // These are the COLUMN's floor, not its height: labelCol still grows
        // to the real line box (see labelCol), so a font whose Text box
        // exceeds the metric is never clipped.
        // One read of the sub line, hoisted so the floor below and the Text
        // that paints it cannot disagree about presence.
        readonly property string subText: row.modelData ? String(row.modelData.sub ?? "") : ""
        // The action's own label, which is what the confirm slot names: the
        // copy belongs to the row that is showing it, not to a card-level
        // stage that could outlive the row it was armed for.
        readonly property string actionLabel: row.modelData ? String(row.modelData.label ?? "") : ""
        FontMetrics {
          id: labelFontMetrics
          font.pixelSize: Ui.fontL
          font.family: Ui.fontFamily
        }
        FontMetrics {
          id: subFontMetrics
          font.pixelSize: Ui.fontXs
          font.family: Ui.fontFamily
        }
        readonly property real labelLineH: Math.ceil(labelFontMetrics.height)
        readonly property real subLineH: Math.ceil(subFontMetrics.height)
        readonly property real linesH: labelLineH
          + (row.subText !== "" ? 1 + subLineH : 0)

        width: ListView.view ? ListView.view.width : 240
        // The confirm slot is in-flow under the row, so the row grows with it
        // 1:1 - the height tracks the slot's open/close animation, the same
        // linear sum every other row with a dropdown keeps.
        readonly property real confirmSlotH: confirmSlot ? confirmSlot.height : 0
        readonly property real slotMotionMs: confirmSlot && (confirmSlot.open || confirmSlot.closing)
          ? confirmSlot.slotMs : 0
        height: Math.max(Ui.rowMinH, mainLine.height + 2 * Ui.rowPadV) + row.confirmSlotH
        // Always transparent: the List sliding highlight bar paints the
        // selection behind the rows (see common/ui/List). Same as menu Entry.
        Rectangle { anchors.fill: parent; color: "transparent" }
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onClicked: mouse => {
            if (mouse.button === Qt.RightButton) { PowerMenu.close(); return }
            if (list.currentIndex !== row.index) list.seat(row.index, "click")
            // Routed through the panel, which owns the staged confirm: a
            // click on the armed row advances it, exactly as Enter does.
            panel.activateCurrent()
          }
        }
        Item {
          id: mainLine
          anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.topMargin: Ui.rowPadV
          anchors.leftMargin: Ui.m; anchors.rightMargin: Ui.m
          height: labelCol.height
          Icon {
            id: iconImg
            visible: (row.modelData ? String(row.modelData.icon ?? "") : "") !== ""
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            name: row.modelData ? String(row.modelData.icon ?? "") : ""
            colorKey: "foreground_0"
            size: 20
          }
          Column {
            id: labelCol
            // The resting height, from the record and the font metrics (see
            // linesH), so it reads the same before and after the delegate
            // polishes. implicitHeight is the floor's other side: it is the
            // live line box, 0 until the polish, and it stays the authority
            // for a font whose metrics understate it.
            height: Math.max(implicitHeight, row.linesH)
            anchors.left: iconImg.visible ? iconImg.right : parent.left; anchors.leftMargin: iconImg.visible ? 8 : 0
            anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Text {
              width: parent.width
              text: row.modelData ? String(row.modelData.label ?? "") : ""
              color: Ui.tint("foreground_0", 1)
              font.pixelSize: Ui.fontL
              font.family: Ui.fontFamily
              elide: Text.ElideRight
            }
            Text {
              width: parent.width; visible: row.subText !== ""
              text: row.subText
              color: Ui.tint("foreground_1", 0.55)
              font.pixelSize: Ui.fontXs
              font.family: Ui.fontFamily
              elide: Text.ElideRight
            }
          }
        }

        // Staged confirm under the row that asked for it, the same slot the
        // clipboard, launcher, pass and wallpaper-picker rows carry. Stage 1
        // is the hint the activation bought; stage 2 is the second one, and
        // only confirmPending() runs anything.
        ConfirmSlot {
          id: confirmSlot

          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: mainLine.bottom
          topGap: Ui.m
          open: panel._confirmIndex === row.index
            && PowerMenu.isDestructive(row.modelData ? row.modelData.action : "")
          stage: panel._confirmIndex === row.index ? panel._confirmStage : 0
          confirmText: row.actionLabel === "" ? "Confirm" : "Confirm " + row.actionLabel
          hintText: row.actionLabel === "" ? "Press Enter to confirm" : "Press Enter to confirm " + row.actionLabel
          armedText: "<b><u>Press Enter again to confirm " + (row.actionLabel === "" ? "this action" : row.actionLabel) + "</u></b>"
          onConfirmed: panel.advanceConfirm()
          // The claim on the list - the card's `slotOpen` - is released here,
          // at the slot's terminal edge, and not when the row stops being
          // armed. See closeConfirm for what the earlier edge cost.
          onCloseFinished: panel.releaseReveal(row.index)
        }

        // A row that is destroyed mid-collapse takes its slot's grace timer
        // with it, so `closeFinished` never arrives for it; without this the
        // claim would name a row that is no longer on screen.
        Component.onDestruction: panel.releaseReveal(row.index)
      }
    }
    Text {
      anchors.centerIn: parent
      visible: list.count === 0 && PowerMenu.visible
      text: PowerMenu.query !== "" ? "No matches" : "Empty"
      color: Ui.tint("foreground_1", 0.4)
      font.pixelSize: Ui.fontS
      font.family: Ui.fontFamily
      font.italic: true
    }
  }

  function probeFocus() { return focusCtrl.probe() }

  // Config or dispatch fault. Plain text, so a verdict read off the wire
  // never renders as markup. The one box left below the list: the staged
  // confirm is a row slot now, so the card reserves room only for this.
  Notice {
    id: faultNotice

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: listBox.bottom
    anchors.topMargin: Ui.s
    tone: "danger"
    message: panel.faultMessage
  }
}
