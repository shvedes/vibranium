// Probe: the rest of common/ui - name resolution, geometry, state machines
// and the motion primitives, headless, in a real event loop.
//
// ui.qml already owns the design tokens, Ui.tint/Ui.alpha, Chip's layout set,
// CheckBox.boxSize, ProgressBar's clamp, Divider's hairline, Title's level
// heights, Notice.danger, Toggle.toggle() and MotionPolicy.duration. This
// probe is the other half: everything with logic in it.
//
// Three things make it work that a snapshot cannot do:
//
//   1. Everything is read from a later event-loop turn. Icon's own header
//      says the palette lands milliseconds after boot, and the boot scan
//      that fills Icons._raw lands even later: at Component.onCompleted the
//      icon set is 0 entries and every icon's source is still the empty
//      string, so a snapshot taken there would "prove" that no icon name
//      resolves. On the first turn the scan is in (178 assets) and the URLs
//      are real. Text metrics move too - the same label measures 187 wide at
//      onCompleted and 249 on a later turn, which is why PanelCard's
//      recalcWidth() is called at turn 20 and its numbers are compared
//      against TextMetrics read on that same turn.
//   2. The tweens are sampled in flight. Glide is the number counterpart of
//      the ColorAnim ui.qml samples, CapsChip carries its own two 150ms
//      Behaviors, ProgressBar glides its fill, DropdownSlot glides its height
//      and GridList sweeps its contentY. Each is sampled on five successive
//      turns, and the sample list is reduced to the claim - it starts below
//      the target, rises every turn, never passes the target, and lands on it
//      - because the exact value on any one turn is a function of how long
//      that turn happened to be. Pinning those floats would be pinning the
//      frame clock; it also went flaky for real, which is how the reduction
//      earned its place.
//   3. Nothing here is read through a snapshot of a state nobody drove. The
//      click paths are driven at the signal level (ConfirmSlot.confirmed(),
//      DropdownButton.clicked(), ZebraRow.clicked(null)) because a real press
//      needs a compositor; the hover and press tints those components key off
//      containsMouse/containsPress are therefore out of reach and are
//      recorded as skips in the driver rather than asserted.
//
// What this environment cannot do, and says so rather than faking: there is
// no compositor, so PanelWindow cannot be constructed at all; and
// Quickshell.screens is empty, so there is no virtual screen to lay out on.
// Both are reported as findings, not papered over.

import QtQuick
import Quickshell
import qs.common
import "common/collections/ZoneGeometry.js" as Zone
import "common/text/StringUtils.js" as SU

Item {
  id: root
  width: 640
  height: 900

  property int phase: 0
  property string scrimError: "not-attempted"

  // ---- tween sample buffers -------------------------------------------
  //
  // A tween's exact value one event-loop turn in is a function of how long
  // that turn happened to be, so pinning it to fifteen digits is pinning the
  // frame clock. What is stable - and what is actually the claim - is the
  // shape of the trace: it starts below the target, rises every sample, never
  // passes the target, and lands on it. The raw values are still reported, so
  // a reader can see the trace, but the assertions read the verdicts.
  property var glideV: []
  property var capsScaleV: []
  property var capsOpacityV: []
  property var barFillV: []
  property var slotShortHV: []
  property var slotShortOV: []
  property var slotTallHV: []
  property var slotTallOV: []
  property var sweepYV: []
  property var gateHV: []
  // The height the escape-driven tween starts from: the card is shrinking,
  // so the target is the lower of the two and every in-flight sample has to
  // sit between the target and this.
  property real gateStartH: 0

  // ---- signal sinks ---------------------------------------------------
  // Counters, not booleans: "the handler fired" and "it fired twice" are
  // different bugs.
  property int confirmHits: 0
  property int cancelHits: 0
  property int zebraClicks: 0
  property int dbtnClicks: 0
  property int dbtnOffClicks: 0
  property int closeFinishedShort: 0
  property int closeFinishedCycle: 0
  property int closeFinishedReopen: 0
  property int closeFinishedTall: 0
  property var cycleBody: null
  property var reopenBody: null

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  // ---- the components under test ---------------------------------------

  // Icon: one per interesting arm of the resolution rule. `mic-off` carries
  // an indicator element but declares no behavior, `bluetooth-connected`
  // declares blink, `volume-max` carries tier classes, and the last four are
  // the unknown name, the empty name, the literal colorKey and the invalid
  // accentKey cases.
  Icon { id: icPlain; x: 0; y: 0; name: "clock" }
  Icon { id: icTwo; x: 40; y: 0; name: "mic-off"; accentKey: "red"; indicatorActive: true }
  Icon { id: icBlink; x: 80; y: 0; name: "bluetooth-connected"; accentKey: "red"; indicatorActive: true; indicatorAnim: "blink" }
  Icon { id: icJunk; x: 120; y: 0; name: "bluetooth-connected"; accentKey: "red"; indicatorActive: true; indicatorAnim: "not-a-behavior" }
  Icon { id: icStatic; x: 160; y: 0; name: "mic-off"; accentKey: "red" }
  Icon { id: icNoAccent; x: 200; y: 0; name: "mic-off"; indicatorActive: true }
  Icon { id: icNotActive; x: 240; y: 0; name: "mic-off"; accentKey: "red"; indicatorActive: false }
  Icon { id: icTier1; x: 280; y: 0; name: "volume-max"; dimTiers: 1 }
  Icon { id: icTier0; x: 320; y: 0; name: "volume-max" }
  Icon { id: icBig; x: 360; y: 0; name: "mic-off"; size: 40 }
  Icon { id: icLit; x: 400; y: 0; name: "mic-off"; colorKey: "#ff0000" }
  Icon { id: icBadAccent; x: 440; y: 0; name: "mic-off"; accentKey: "not_a_palette_key" }
  Icon { id: icUnknown; x: 480; y: 0; name: "definitely_not_an_icon" }
  Icon { id: icNoName; x: 520; y: 0; name: "" }
  Icon { id: icNoColorKey; x: 560; y: 0; name: "mic-off"; colorKey: "" }

  // GridList: a 3-column grid whose 7 items leave a half-empty final row, a
  // 10-item grid whose last row holds exactly one cell, an empty grid for the
  // count === 0 guards, a short viewport for the wrap sweep, and one laid
  // out at the exact cell width MenuPanel's own formula derives.
  GridList {
    id: grid
    x: 0
    y: 40
    width: 300
    height: 120
    cellWidth: 100
    cellHeight: 40
    cols: 3
    model: 7
    delegate: Item {}
  }
  GridList {
    id: gridTen
    x: 0
    y: 200
    width: 300
    height: 200
    cellWidth: 100
    cellHeight: 40
    cols: 3
    model: 10
    delegate: Item {}
  }
  GridList {
    id: gridEmpty
    x: 0
    y: 440
    width: 300
    height: 120
    cellWidth: 100
    cellHeight: 40
    cols: 3
    model: 0
    delegate: Item {}
  }
  GridList {
    id: sweepGrid
    x: 320
    y: 40
    width: 300
    height: 40
    cellWidth: 100
    cellHeight: 40
    cols: 3
    model: 12
    delegate: Item {}
  }
  GridList {
    id: cancelGrid
    x: 320
    y: 120
    width: 300
    height: 40
    cellWidth: 100
    cellHeight: 40
    cols: 3
    model: 12
    delegate: Item {}
  }
  GridList {
    id: gridFit
    x: 320
    y: 200
    width: root.fitSide * 8
    height: 80
    cellWidth: root.fitSide
    cellHeight: 40
    cols: 8
    model: 8
    delegate: Item {}
  }
  readonly property int fitCols: Math.max(1, Math.floor(392 / 46))
  readonly property real fitSide: Math.floor(392 / root.fitCols)

  // ScrollBar: a long flickable, a short one, a zero-height bar (the
  // minimumSize divide guard) and a minThumb larger than the bar.
  Flickable {
    id: longFlick
    x: 0
    y: 600
    width: 80
    height: 200
    contentWidth: 80
    contentHeight: 800
  }
  ScrollBar { id: barLong; x: 90; y: 600; flickable: longFlick; height: 200 }
  Flickable {
    id: shortFlick
    x: 130
    y: 600
    width: 80
    height: 200
    contentWidth: 80
    contentHeight: 150
  }
  ScrollBar { id: barShort; x: 220; y: 600; flickable: shortFlick; height: 200 }
  ScrollBar { id: barZero; x: 230; y: 600; flickable: longFlick; height: 0 }
  ScrollBar { id: barFat; x: 250; y: 600; flickable: longFlick; height: 200; minThumb: 500; thickness: 6; radius: 3 }
  ScrollBar { id: barPinned; x: 280; y: 600; flickable: longFlick; height: 200; autoHide: false }

  // The number tween, driven by hand the way Glide's own comment says its one
  // non-template role is: target + restart().
  Item {
    id: glideTarget
    x: 0
    y: 0
    width: 10
    height: 10
    property real v: 0
  }
  Glide { id: glide; target: glideTarget; property: "v"; from: 0; to: 100 }
  Glide { id: glidePristine }

  // DropdownSlot, four of them so the open path, the close path, the
  // reopen-inside-the-grace-window path and the never-opened path cannot
  // tread on each other.
  DropdownSlot {
    id: slotShort
    x: 320
    y: 300
    width: 200
    nestedContent: Component { Rectangle { width: 30; height: 30; color: "green" } }
    onCloseFinished: root.closeFinishedShort++
    Rectangle { width: 40; height: 40; color: "red" }
  }
  DropdownSlot {
    id: slotTall
    x: 320
    y: 380
    width: 200
    gap: 4
    nestedContent: Component { Rectangle { width: 30; height: 30; color: "blue" } }
    onCloseFinished: root.closeFinishedTall++
    Rectangle { width: 100; height: 400; color: "blue" }
  }
  DropdownSlot {
    id: slotCycle
    x: 320
    y: 420
    width: 200
    nestedContent: Component { Rectangle { width: 30; height: 30; color: "yellow" } }
    onCloseFinished: root.closeFinishedCycle++
    Rectangle { width: 40; height: 40; color: "red" }
  }
  DropdownSlot {
    id: slotReopen
    x: 320
    y: 460
    width: 200
    nestedContent: Component { Rectangle { width: 30; height: 30; color: "cyan" } }
    onCloseFinished: root.closeFinishedReopen++
    Rectangle { width: 40; height: 40; color: "red" }
  }
  // Born closed and never opened: the grace window only arms on a transition.
  DropdownSlot {
    id: slotIdle
    x: 320
    y: 500
    width: 200
    Rectangle { width: 10; height: 10 }
  }

  // ConfirmSlot: the staged hint -> armed swap, and both declared signals.
  ConfirmSlot {
    id: confirm
    x: 0
    y: 40
    width: 200
    open: true
    onConfirmed: root.confirmHits++
    onCancelled: root.cancelHits++
  }
  ConfirmSlot {
    id: confirmArmed
    x: 0
    y: 120
    width: 200
    open: true
    stage: 2
  }

  // BodyText: tag-free in both formats, a whitelisted tag through the
  // styledMarkup contract, and the same tag NOT through it.
  BodyText { id: btPlainA; x: 540; y: 40; width: 90; text: "one two three four five six seven eight" }
  BodyText { id: btPlainB; x: 540; y: 80; width: 90; text: "one two three four five six seven eight"; markup: true }
  BodyText { id: btBoldMarkup; x: 540; y: 120; width: 90; text: SU.styledMarkup("<b>bold</b> tail"); markup: true }
  BodyText { id: btBoldPlain; x: 540; y: 160; width: 90; text: SU.styledMarkup("<b>bold</b> tail") }
  BodyText { id: btRawTag; x: 540; y: 200; width: 90; text: "<blink>z</blink>"; markup: true }
  BodyText { id: btEscapedTag; x: 540; y: 240; width: 90; text: SU.styledMarkup("<blink>z</blink>"); markup: true }
  BodyText { id: btNlPlain; x: 540; y: 280; width: 90; text: "a\nb" }
  BodyText { id: btNlRaw; x: 540; y: 320; width: 90; text: "a\nb"; markup: true }
  BodyText { id: btNlStyled; x: 540; y: 360; width: 90; text: SU.styledMarkup("a\nb"); markup: true }
  BodyText { id: btEmpty; x: 540; y: 400; width: 90; text: "" }
  BodyText { id: btStack; x: 540; y: 440; width: 90; text: "alpha beta gamma delta epsilon zeta eta theta" }

  // Card, Notice, Title, Divider, CapsChip, CheckBox, Toggle, ProgressBar
  // and the two button/row primitives, in pairs wherever "state must not
  // leak between two instances" is a claim worth making.
  Card { id: card; x: 0; y: 700; width: 200; height: 120 }
  Divider { id: divider; x: 0; y: 840; width: 120 }
  Notice { id: noticeWarn; x: 210; y: 700; width: 200; message: "careful" }
  Notice { id: noticeDanger; x: 210; y: 740; width: 200; message: "careful"; tone: "danger" }
  Notice { id: noticeEmpty; x: 210; y: 780; width: 200; message: "" }
  Notice { id: noticeMarkup; x: 210; y: 820; width: 200; message: "<b>bold</b>"; markup: true }
  Title { id: title1; x: 420; y: 700; level: 1; text: "abc" }
  Title { id: title3; x: 420; y: 720; level: 3; text: "abc" }
  Title { id: title4; x: 420; y: 740; level: 4; text: "abc" }
  Title { id: title5; x: 420; y: 760; level: 5; text: "abc" }
  Title { id: title0; x: 420; y: 780; level: 0; text: "abc" }
  Title { id: titleBig; x: 420; y: 800; level: 99; text: "abc" }
  CapsChip { id: capsOff; x: 420; y: 820 }
  CapsChip { id: capsOn; x: 480; y: 820; active: true }
  CheckBox { id: boxOn; x: 0; y: 620; checked: true }
  CheckBox { id: boxOff; x: 30; y: 620 }
  Toggle { id: togOn; x: 60; y: 620; width: 32; height: 16; checked: true }
  Toggle { id: togOff; x: 100; y: 620; width: 32; height: 16 }
  Toggle { id: togDim; x: 140; y: 620; width: 32; height: 16; dimmed: true }

  // Vignette: the shared radial darkening, in the three states its two
  // numbers can be in - fully in, half way in, and not at all. Its whole
  // contract is derived state, so it is read back as verdicts rather than
  // as floats.
  Vignette { id: vigFull; x: 0; y: 880; width: 200; height: 20; intensity: 0.45; progress: 1 }
  Vignette { id: vigHalf; x: 200; y: 880; width: 200; height: 20; intensity: 0.45; progress: 0.5 }
  Vignette { id: vigNone; x: 400; y: 880; width: 200; height: 20; intensity: 0; progress: 1 }
  ProgressBar { id: barEmpty; x: 0; y: 660; width: 100; value: 0 }
  ProgressBar { id: barHalf; x: 0; y: 680; width: 100; value: 50 }
  ProgressBar { id: barBusy; x: 0; y: 700; width: 100; indeterminate: true }
  ProgressBar { id: barLoud; x: 0; y: 720; width: 100; value: 25; dimWhenEmpty: false }
  DropdownButton { id: dbtnOn; x: 540; y: 700; width: 90; text: "Forget"; onClicked: root.dbtnClicks++ }
  DropdownButton { id: dbtnOff; x: 540; y: 740; width: 90; text: "Forget"; enabled: false; onClicked: root.dbtnOffClicks++ }
  DropdownButton { id: dbtnBare; x: 540; y: 780; width: 90; text: "" }
  ZebraRow {
    id: zebra0
    x: 540
    y: 820
    width: 90
    height: 20
    rowIndex: 0
    onClicked: root.zebraClicks++
  }
  ZebraRow { id: zebra1; x: 540; y: 840; width: 90; height: 20; rowIndex: 1 }
  ZebraRow { id: zebra2; x: 540; y: 860; width: 90; height: 20; rowIndex: 2 }
  ZebraRow { id: zebra3; x: 0; y: 460; width: 90; height: 20; rowIndex: 3 }
  ZebraRow { id: zebraSelOdd; x: 100; y: 460; width: 90; height: 20; rowIndex: 1; selected: true }
  ZebraRow { id: zebraSelEven; x: 200; y: 460; width: 90; height: 20; rowIndex: 2; selected: true }
  ZebraRow { id: zebraCursor; x: 300; y: 460; width: 90; height: 20; rowIndex: 0; hoverCursor: true; hoverable: true }
  ZebraRow { id: zebraStill; x: 0; y: 500; width: 90; height: 20; interactive: false }

  // PanelCard: parented into sized hosts so its own `width` binding is the
  // one under test - assigning width on the card would replace the binding.
  Item { id: hostPlain; x: 0; y: 860; width: 300; height: 30 }
  PanelCard { id: cardPlain; parent: hostPlain; anchors.centerIn: parent; maxHeight: 600; baseWidth: 360 }
  Item { id: hostEmpty; x: 320; y: 860; width: 300; height: 30 }
  PanelCard { id: cardEmpty; parent: hostEmpty; anchors.centerIn: parent; maxHeight: 600; baseWidth: 200; count: 0 }
  Item { id: hostRows; x: 0; y: 520; width: 300; height: 30 }
  PanelCard {
    id: cardRows
    parent: hostRows
    anchors.centerIn: parent
    maxHeight: 600
    baseWidth: 100
    count: 3
    rows: [{ label: "a really quite long label indeed" }, { label: "short" }, { label: "three" }]
  }
  Item { id: hostNarrow; x: 320; y: 520; width: 300; height: 30 }
  PanelCard {
    id: cardNarrow
    parent: hostNarrow
    anchors.centerIn: parent
    maxHeight: 300
    hasFilter: false
    baseWidth: 100
    count: 3
    rowLimit: 3
    rows: [{ label: "one" }, { label: "two" }, { label: "three" }]
  }
  Item { id: hostOneRowRegion; x: 320; y: 280; width: 300; height: 30 }
  PanelCard {
    id: cardOneRowRegion
    parent: hostOneRowRegion
    anchors.centerIn: parent
    maxHeight: 300
    hasFilter: false
    baseWidth: 100
    count: 1
    rowLimit: 10
    rows: [{ label: "only" }]
  }
  Item { id: hostFive; x: 320; y: 200; width: 300; height: 30 }
  PanelCard {
    id: cardFive
    parent: hostFive
    anchors.centerIn: parent
    maxHeight: 300
    hasFilter: false
    baseWidth: 100
    count: 5
    rowLimit: 3
    rows: [{ label: "one" }, { label: "two" }, { label: "three" }, { label: "four" }, { label: "five" }]
  }
  Item { id: hostFiveNoCap; x: 320; y: 240; width: 300; height: 30 }
  PanelCard {
    id: cardFiveNoCap
    parent: hostFiveNoCap
    anchors.centerIn: parent
    maxHeight: 300
    hasFilter: false
    baseWidth: 100
    count: 5
    rows: [{ label: "one" }, { label: "two" }, { label: "three" }, { label: "four" }, { label: "five" }]
  }
  Item { id: hostSlot; x: 0; y: 560; width: 640; height: 30 }
  PanelCard {
    id: cardSlot
    parent: hostSlot
    anchors.centerIn: parent
    maxHeight: 600
    hasFilter: false
    count: 2
    // A DECIDED region override, which is what the input became: the card no
    // longer sees the list's claim, only the answer. `slotOpen` is separate
    // because a slot that fits makes the content taller while asking for no
    // resize, and the two facts are not the same.
    slotOpen: true
    slotRegionH: 300
    bottomReserve: 10
    rows: [{ label: "x" }, { label: "y" }]
  }
  // The resting-FIT latch, driven through a whole open/unfold/close cycle
  // with the fit moving the way a consumer's `list.fitHeight()` reports it: UP
  // as the slot opens (each row's live height grows, and so does every row's y
  // beneath it) and then DOWN in steps as the slot collapses.
  //
  // This is the third attempt at one bug, and the shape is worth pinning
  // because each attempt failed differently: the growth rule ignored the scroll
  // offset, then the rule was right and the card still grew, because the growth
  // was coming from the FIT and not the growth path at all - a live fitHeight
  // measured against a slot-inflated content, handed to a resting region that
  // is documented as the height of the row set "with nothing open".
  //
  // It needs a card of its own. Reusing `cardSlot` looks free and is not: that
  // card is two rows, so its resting region is floored by `snappedListH`, which
  // reads the same `contentHeight` this cycle moves - the floor dominates and
  // the latch is masked behind it. Six rows with a 292px fit puts the floor
  // below the fit, which is the case the latch actually governs.
  Item { id: hostFitLatch; x: 0; y: 640; width: 640; height: 30 }
  PanelCard {
    id: cardFitLatch
    parent: hostFitLatch
    anchors.centerIn: parent
    maxHeight: 600
    hardMaxHeight: 1200
    hasFilter: false
    bottomReserve: 10
    count: 6
    rows: [{ label: "a" }, { label: "b" }, { label: "c" },
           { label: "d" }, { label: "e" }, { label: "f" }]
    exactListH: 292
    contentHeight: 292
    slotOpen: false
    slotRegionH: -1
  }
  property var fitTrail: []
  property int fitStep: 0
  function fitDrop(h) {
    cardFitLatch.exactListH = h
    cardFitLatch.contentHeight = h
  }
  function fitTurn() {
    root.fitStep++
    const s = root.fitStep
    if (s === 1) {
      kv("fl.restAtRest", cardFitLatch.restingListH)
      cardFitLatch.slotOpen = true
      return
    }
    if (s === 2) { fitDrop(532); return }        // slot open, content taller
    if (s === 3) {
      kv("fl.restWhileOpen", cardFitLatch.restingListH)
      kv("fl.fitSaidWhileOpen", cardFitLatch.exactListH)
      kv("fl.didNotGrow", cardFitLatch.restingListH === 292)
      cardFitLatch.slotOpen = false               // claim released, still tall
      root.fitTrail.push(cardFitLatch.restingListH)
      fitDrop(470)
      return
    }
    if (s === 4) { root.fitTrail.push(cardFitLatch.restingListH); fitDrop(380); return }
    if (s === 5) { root.fitTrail.push(cardFitLatch.restingListH); fitDrop(305); return }
    if (s === 6) { root.fitTrail.push(cardFitLatch.restingListH); fitDrop(292); return }
    if (s === 7) {
      root.fitTrail.push(cardFitLatch.restingListH)
      kv("fl.trail", root.fitTrail.join(","))
      kv("fl.movedDuringClose", root.fitTrail.some((v) => v !== 292))
      kv("fl.flatThroughout", root.fitTrail.every((v) => v === 292))
      kv("fl.landed", cardFitLatch.restingListH)
      kv("fl.backToRest", cardFitLatch.restingListH === 292)
      kv("fl.cardBack", cardFitLatch.cardHeight)
    }
  }

  Item { id: hostNoLabels; x: 320; y: 560; width: 300; height: 30 }
  PanelCard {
    id: cardNoLabels
    parent: hostNoLabels
    anchors.centerIn: parent
    maxHeight: 600
    baseWidth: 120
    count: 2
    rows: [{ label: "" }, { icon: "x" }]
  }
  Item { id: hostOneRow; x: 0; y: 820; width: 300; height: 30 }
  PanelCard { id: cardOneRow; parent: hostOneRow; anchors.centerIn: parent; maxHeight: 600; count: 1; rows: [{ label: "x" }] }
  Item { id: hostOneSub; x: 320; y: 820; width: 300; height: 30 }
  PanelCard { id: cardOneSub; parent: hostOneSub; anchors.centerIn: parent; maxHeight: 600; count: 1; rows: [{ label: "x", sub: "y" }] }
  Item { id: hostHole; x: 640; y: 820; width: 0; height: 30 }
  PanelCard { id: cardHole; parent: hostHole; anchors.centerIn: parent; maxHeight: 600; count: 1; rows: [null] }

  // The launcher's capped shape, with the clipboard suggestion and its
  // divider in the cap: twelve rows of which one is a 12px separator. That
  // composition is the whole point - a cap is not N average rows, and the
  // divider is the row that proves it. maxHeight is set from turn1, once the
  // fonts have settled, so the window allowance lands between the height
  // these rows really occupy and the height a row-COUNT scaling of the
  // resting buffer would claim for them.
  PanelCard {
    id: cardClipCap
    parent: hostHole
    anchors.centerIn: parent
    hasFilter: false
    baseWidth: 100
    count: 200
    rowLimit: 12
    rows: {
      const out = [{ label: "clip", sub: "/home/u/x", clip: true }, { kind: "separator" }]
      for (let i = 0; i < 198; i++) out.push({ label: "app " + i, sub: "desc " + i })
      return out
    }
  }

  // The show gate's escape: one card with the gate shut, so a resize can be
  // watched both ways - snapped with the flag clear, tweened with it set.
  PanelCard {
    id: cardGate
    parent: hostHole
    anchors.centerIn: parent
    hasFilter: false
    baseWidth: 100
    count: 1
    rows: [{ label: "one" }]
  }

  TextMetrics { id: labelMetrics; text: "a really quite long label indeed"; font.pixelSize: Ui.fontL; font.family: Ui.fontFamily }
  TextMetrics { id: capMetrics; text: "Mg"; font.pixelSize: Ui.fontL; font.family: Ui.fontFamily }
  TextMetrics { id: subMetrics; text: "Mg"; font.pixelSize: Ui.fontXs; font.family: Ui.fontFamily }
  // The basis the row estimate is now measured against: a real Text's line
  // box for the row's OWN label, which is what every row delegate reads.
  // Declared here so the card's estimate can be compared against it on the
  // same turn - a number the card produces and a number the engine produces
  // are only comparable when both were read in the same layout pass.
  Text {
    id: realLabelLine
    visible: false
    width: 1
    wrapMode: Text.NoWrap
    text: "x"
    font.pixelSize: Ui.fontL
    font.family: Ui.fontFamily
  }
  Text {
    id: realSubLine
    visible: false
    width: 1
    wrapMode: Text.NoWrap
    text: "y"
    font.pixelSize: Ui.fontXs
    font.family: Ui.fontFamily
  }

  // PanelFocus: a bare one for the list sink, a second for isolation, and one
  // wired to a real InputField so probe() has a genuine focused/text pair.
  PanelFocus { id: focusPlain; x: 0; y: 300; width: 20; height: 20 }
  PanelFocus { id: focusOther; x: 40; y: 300; width: 20; height: 20 }
  InputField { id: searchField; x: 80; y: 300; width: 120; height: Ui.inputHeight }
  PanelFocus { id: focusField; x: 220; y: 300; width: 20; height: 20; searchField: searchField }
  PanelFocus { id: focusField2; x: 250; y: 300; width: 20; height: 20; searchField: searchField }

  // ---- the event loop -------------------------------------------------
  //
  // The schedule, and why each read is where it is. The pump interval is 12ms
  // but Qt's coarse timer lands it nearer 16ms, so a turn index is only
  // meaningful as "later than", never as an exact elapsed time - which is the
  // same reason the tween samples are reduced to verdicts.
  //
  //   turn 0  Component.onCompleted: everything that needs no layout pass and
  //           no icon scan, plus the ScrimWindow attempt.
  //   turn 1  the icon scan has landed, so every name resolves here; the
  //           cursor machine and the signal drives run; every tween starts.
  //   2..6    five in-flight samples per tween.
  //   turn 8  the tween verdicts, off the sample lists.
  //   turn 12 Glide has landed (120ms); the short slot's height has landed
  //           (slotMs 120ms); the cycle slots are closed here.
  //   turn 14 the reopen slot is reopened, inside the grace window.
  //   turn 16 ScrollBar's position work: mid-list, the single-writer round
  //           trip, and the bottom seat.
  //   turn 20 PanelCard.recalcWidth(), once the font metrics have settled.
  //   turn 24 the settled content widths and the tall slot's height (260ms).
  //   turn 30 PanelCard's show gate has expired (280ms); Glide's target
  //           release is re-checked well after the tween ended.
  //   turn 48 the wrap sweep (540ms) has landed on its target.
  //   turn 50 the sentinel.
  Timer {
    id: pump
    interval: 12
    repeat: true
    running: true
    onTriggered: {
      root.phase++
      if (root.phase === 1) turn1()
      else if (root.phase === 2) turn2()
      else if (root.phase === 3) turn3()
      else if (root.phase === 4) turn4()
      else if (root.phase === 5) turn5()
      else if (root.phase === 6) turn6()
      else if (root.phase === 8) turn8()
      else if (root.phase === 12) turn12()
      else if (root.phase === 14) turn14()
      else if (root.phase === 16) turn16()
      else if (root.phase === 20) turn20()
      else if (root.phase === 24) turn24()
      else if (root.phase === 30) turn30()
      else if (root.phase === 48) turn48()
      // 31..37, not 30..36: turn30() already owns phase 30, and the chain is
      // first-match, so a range starting at 30 silently loses its first tick -
      // which is the one that opens the slot, and the assertions then hang off
      // a cycle that never started.
      else if (root.phase >= 31 && root.phase <= 37) fitTurn()
      else if (root.phase === 50) finish()
    }
  }

  Component.onCompleted: {
    kv("probe.error", "none")
    try {
      reportAtBoot()
      attemptScrimWindow()
    } catch (e) {
      kv("probe.thrown", "" + (e && e.message ? e.message : e))
    }
  }

  // ---- helpers --------------------------------------------------------

  // A child found by a property it uniquely carries, so the assertions do not
  // depend on the order children happen to be declared in.
  function childWith(obj, prop) {
    const kids = obj.children
    for (let i = 0; i < kids.length; i++) {
      if (kids[i][prop] !== undefined) return kids[i]
    }
    return null
  }
  // Where two children both carry the marker, declaration order is the only
  // way in: ProgressBar declares `fill` then `block`, Toggle declares `thumb`
  // then its MouseArea, ZebraRow its band then its MouseArea.
  function firstRect(o) { return o.children[0] }
  function labelOf(o) { return childWith(o, "text") }
  function areaOf(o) { return childWith(o, "cursorShape") }
  function baseOf(ic) { return childWith(ic, "source") }
  function loaderOf(ic) {
    const kids = ic.children
    for (let i = 0; i < kids.length; i++) {
      if (kids[i].active !== undefined && kids[i].item !== undefined) return kids[i]
    }
    return null
  }
  function indicatorOf(ic) {
    const l = loaderOf(ic)
    if (l === null || l.item === null) return null
    return childWith(l.item, "source")
  }
  // The Qt control inside the ScrollBar wrapper, and the shadow viewport it
  // measures the target through.
  function controlOf(sb) { return childWith(sb, "size") }
  function thumbOf(sb) { return controlOf(sb).contentItem }
  function shadowOf(sb) {
    const kids = sb.children
    for (let i = 0; i < kids.length; i++) {
      if (kids[i].interactive === false) return kids[i]
    }
    return null
  }
  function textsIn(o, out) {
    out = out || []
    const kids = o.children
    for (let i = 0; i < kids.length; i++) {
      const c = kids[i]
      if (c.text !== undefined && c.implicitWidth !== undefined) out.push(c)
      textsIn(c, out)
    }
    return out
  }
  function cellX(g, i) {
    const it = g.itemAtIndex(i)
    return it === null ? "no-cell" : it.x
  }
  function cellY(g, i) {
    const it = g.itemAtIndex(i)
    return it === null ? "no-cell" : it.y
  }
  function isDataUrl(s) { return /^data:image\/svg\+xml;utf8,/.test(String(s)) }
  function isArgb(s) { return /^#[0-9a-fA-F]{8}$/.test(String(s)) }
  function alphaOf(c) {
    const s = String(c)
    return isArgb(s) ? parseInt(s.slice(1, 3), 16) / 255 : "not-argb:" + s
  }
  function enc(h) { return encodeURIComponent(h) }
  function has(hay, needle) { return String(hay).indexOf(needle) >= 0 }
  function mixHex(a, b) {
    const pa = parseInt(a.substring(1), 16), pb = parseInt(b.substring(1), 16)
    const ch = (sa, sb, shift) => Math.round((((sa >> shift) & 255) + ((sb >> shift) & 255)) / 2)
    const n = (ch(pa, pb, 16) << 16) | (ch(pa, pb, 8) << 8) | ch(pa, pb, 0)
    return "#" + n.toString(16).padStart(6, "0")
  }
  function between(v, lo, hi) { return v > lo && v < hi }
  function sample(arr, v) { arr.push(v); return v }
  // Strictly rising, every sample distinct from the one before it.
  function rising(arr) {
    if (arr.length < 3) return false
    for (let i = 1; i < arr.length; i++) {
      if (!(arr[i] > arr[i - 1])) return false
    }
    return true
  }
  function allBelow(arr, target) {
    for (let i = 0; i < arr.length; i++) {
      if (arr[i] > target) return false
    }
    return true
  }
  function allBetween(arr, lo, hi) {
    for (let i = 0; i < arr.length; i++) {
      if (!between(arr[i], lo, hi)) return false
    }
    return true
  }
  function firstBetween(arr, lo, hi) { return arr.length > 0 && between(arr[0], lo, hi) }
  function sampleCount(arr) { return arr.length }
  function feq(a, b) { return Math.abs(a - b) < 1e-9 }
  function writeBack(sb, y) {
    sb._writePosition(y)
    return sb.target.contentY
  }
  // MenuPanel.qml:108-110 transcribed, so the grid is measured against the
  // consumer's own column arithmetic rather than a number typed into this file.
  function menuFit(innerW, spec) {
    const c = Math.max(1, Math.floor(innerW / spec))
    const side = Math.floor(innerW / c)
    return { cols: c, side: side, slack: innerW - c * side }
  }

  // ---- turn 0: what needs no layout pass and no scan ------------------

  function reportAtBoot() {
    // The headless substrate, so a later "could not do X" reads as a fact
    // about this environment rather than a guess.
    kv("env.motion.enabled", MotionPolicy.enabled)
    kv("env.validScreens", Ui.validScreens.length)
    kv("env.primaryScreen", Ui.primaryScreen === null ? "null" : "screen")
    kv("env.rootHasWindow", root.window === null ? "no" : "yes")

    // The icon set is empty at this point on purpose: the boot scan is a
    // Process that has not reported yet. Pinned so "the URL resolves on the
    // first turn" is a claim about the scan landing, not about luck.
    kv("icon.scan.bootIndexed", Icons.indexedCount)
    kv("icon.scan.bootReady", Icons.ready)
    kv("icon.url.bootLength", String(Icons.url("mic-off", "foreground_0", "", "", 0)).length)

    // The bar-icon tokens Icon sizes every glyph from.
    kv("icon.slot.token", icPlain.defaultSlotSize)
    kv("icon.canvas.token", icPlain.defaultCanvasSize)
    kv("icon.slot.isClampedHigh", icPlain.defaultSlotSize === 24)
    kv("icon.canvas.belowSlot", icPlain.defaultCanvasSize < icPlain.defaultSlotSize)
    kv("icon.dpr.read", icPlain._dpr)
    kv("icon.debugBounds", icPlain._debug)

    // Theme.color is the palette accessor underneath every icon colour. Its
    // fallback map is why an unknown key never yields "" - see the two
    // Icons.url comment lines claiming the opposite.
    kv("theme.unknownKey", Theme.color("not_a_palette_key"))
    kv("theme.emptyKey", Theme.color(""))

    // Enum values, read rather than assumed.
    kv("text.enum.PlainText", Text.PlainText)
    kv("text.enum.StyledText", Text.StyledText)
    kv("text.enum.WordWrap", Text.WordWrap)
    kv("text.enum.FixedHeight", Text.FixedHeight)
    kv("text.enum.ElideRight", Text.ElideRight)
    kv("easing.OutCubic", Easing.OutCubic)
    kv("image.Ready", Image.Ready)
    kv("loader.Ready", Loader.Ready)
    kv("pointing.cursor", Qt.PointingHandCursor)

    // Glide as a declared primitive, before anything drives it.
    kv("glide.duration.isGate", glidePristine.duration)
    kv("glide.duration.expected", MotionPolicy.duration(Ui.fastMs))
    kv("glide.easing", glidePristine.easing.type)
    kv("glide.easing.isOutCubic", glidePristine.easing.type === Easing.OutCubic)
    kv("glide.target.pristine", glidePristine.target === null ? "null" : "set")

    // PanelFocus's own defaults.
    kv("focus.mode.default", focusPlain.mode)
    kv("focus.serviceVisible.default", focusPlain.serviceVisible)
    kv("focus.searchField.default", focusPlain.searchField === null ? "null" : "set")
    kv("focus.sink.isItem", focusPlain.keySink !== null)
    kv("focus.sink.distinct", focusPlain.keySink !== focusOther.keySink)
    kv("focus.probe.noField", JSON.stringify(focusPlain.probe()))

    // The two-stage confirm slot, before any stage change.
    const t0 = textsIn(confirm)
    kv("confirm.textCount", t0.length)
    kv("confirm.hintText", t0.length > 0 ? t0[0].text : "none")
    kv("confirm.buttonText", t0.length > 1 ? t0[1].text : "none")
    kv("confirm.confirmText.default", confirm.confirmText)
    kv("confirm.hintText.default", confirm.hintText)
    kv("confirm.armedText.default", confirm.armedText)
    kv("confirm.height", confirm.height)
    kv("confirm.contentHeight", confirm.children[0].height)
    kv("confirm.gap", confirm.gap)
    kv("confirm.buttonHits", confirmHits)
    kv("confirm.cancelHits", cancelHits)
    kv("confirm.armed.text0", textsIn(confirmArmed)[0].text)
    kv("confirm.armed.isStage", confirmArmed.stage)
    kv("confirm.armed.format", textsIn(confirmArmed)[0].textFormat === Text.StyledText)

    // zebra parity across a 3-row and a 4-row set, plus the two selected rows
    // whose indices have different parity.
    kv("zebra.row0", String(firstRect(zebra0).color))
    kv("zebra.row1", String(firstRect(zebra1).color))
    kv("zebra.row2", String(firstRect(zebra2).color))
    kv("zebra.row3", String(firstRect(zebra3).color))
    kv("zebra.bandColor", String(zebra0.bandColor))
    kv("zebra.selectedColor", String(zebra0.selectedColor))
    kv("zebra.hoverColor", String(zebra0.hoverColor))
    kv("zebra.band.alpha", alphaOf(firstRect(zebra0).color))
    kv("zebra.selected.alpha", alphaOf(firstRect(zebraSelOdd).color))
    kv("zebra.hover.alpha", alphaOf(zebra0.hoverColor))
    kv("zebra.oddRow.color", String(firstRect(zebra1).color))
    kv("zebra.oddRow.alpha", alphaOf(firstRect(zebra1).color))
    kv("zebra.evenRow.alpha", alphaOf(firstRect(zebra2).color))
    kv("zebra.fourthRow.alpha", alphaOf(firstRect(zebra3).color))
    kv("zebra.sel.odd", String(firstRect(zebraSelOdd).color))
    kv("zebra.sel.even", String(firstRect(zebraSelEven).color))
    kv("zebra.sel.parityIrrelevant", String(firstRect(zebraSelOdd).color) === String(firstRect(zebraSelEven).color))
    kv("zebra.hovered.withoutPointer", zebra0.hovered)
    kv("zebra.hovered.optedIn", zebraCursor.hovered)
    kv("zebra.cursor.pointing", areaOf(zebraCursor).cursorShape === Qt.PointingHandCursor)
    kv("zebra.cursor.arrow", areaOf(zebra0).cursorShape === Qt.ArrowCursor)
    kv("zebra.area.visible", areaOf(zebra0).visible)
    kv("zebra.area.decoration", areaOf(zebraStill).visible)
    kv("zebra.area.hoverEnabled", areaOf(zebra0).hoverEnabled)
    kv("zebra.area.hoverEnabledOptedIn", areaOf(zebraCursor).hoverEnabled)
    kv("zebra.parity.threeRows",
      firstRect(zebra0).color === zebra0.bandColor
      && firstRect(zebra1).color !== zebra0.bandColor
      && firstRect(zebra2).color === zebra0.bandColor)
    kv("zebra.parity.fourRows",
      firstRect(zebra0).color === zebra0.bandColor
      && firstRect(zebra1).color !== zebra0.bandColor
      && firstRect(zebra2).color === zebra0.bandColor
      && firstRect(zebra3).color !== zebra0.bandColor)
    kv("zebra.clicks", zebraClicks)

    // Title's remaining levels, including the catch-all arms its colour and
    // pixelSize blocks end on. Levels 1 and 2 use solid colours (six-digit
    // hex, no alpha to parse), so those are compared to the palette token.
    kv("title1.px", title1.font.pixelSize)
    kv("title1.bold", title1.font.bold)
    kv("title1.color", title1.color)
    kv("title1.isSolidToken", String(title1.color) === Theme.color("foreground_0"))
    kv("title3.px", title3.font.pixelSize)
    kv("title3.bold", title3.font.bold)
    kv("title3.ls", title3.font.letterSpacing)
    kv("title3.color", title3.color)
    kv("title3.isSolidToken", String(title3.color) === Theme.color("foreground_1"))
    kv("title3.isSection", title3.isSection)
    kv("title3.isIsland", title3.isIsland)
    kv("title4.px", title4.font.pixelSize)
    kv("title4.bold", title4.font.bold)
    kv("title4.alpha", alphaOf(title4.color))
    kv("title5.px", title5.font.pixelSize)
    kv("title5.alpha", alphaOf(title5.color))
    kv("title0.px", title0.font.pixelSize)
    kv("title0.alpha", alphaOf(title0.color))
    kv("title0.isSection", title0.isSection)
    kv("title0.isIsland", title0.isIsland)
    kv("titleBig.px", titleBig.font.pixelSize)
    kv("titleBig.bold", titleBig.font.bold)
    kv("titleBig.alpha", alphaOf(titleBig.color))
    kv("title.elide.right", title3.elide === Text.ElideRight)
    kv("title.wrap.none", title3.wrapMode === Text.NoWrap)
    kv("title.format.plain", title3.textFormat === Text.PlainText)
    kv("title.cap.mixed", title3.font.capitalization === Font.MixedCase)

    // Notice: the fill/border tints and the empty-message collapse.
    kv("notice.warn.color", noticeWarn.color)
    kv("notice.warn.fillAlpha", alphaOf(noticeWarn.color))
    kv("notice.warn.borderAlpha", alphaOf(noticeWarn.border.color))
    kv("notice.warn.borderW", noticeWarn.border.width)
    kv("notice.warn.radius", noticeWarn.radius)
    kv("notice.warn.iw", noticeWarn.implicitWidth)
    kv("notice.warn.height", noticeWarn.height)
    kv("notice.warn.visible", noticeWarn.visible)
    kv("notice.danger.alpha", alphaOf(noticeDanger.color))
    kv("notice.danger.differsFromWarn", noticeDanger.color === noticeWarn.color ? "same" : "different")
    kv("notice.empty.visible", noticeEmpty.visible)
    kv("notice.empty.height", noticeEmpty.height)
    kv("notice.markup.format", noticeMarkup.children[0].textFormat === Text.StyledText)
    kv("notice.plain.format", noticeWarn.children[0].textFormat === Text.PlainText)

    // CheckBox: the box as layout, and the mark that only paints when
    // checked.
    kv("checkbox.w", boxOn.width)
    kv("checkbox.h", boxOn.height)
    kv("checkbox.iw", boxOn.implicitWidth)
    kv("checkbox.ih", boxOn.implicitHeight)
    kv("checkbox.radius", boxOn.radius)
    kv("checkbox.on.color", boxOn.color)
    kv("checkbox.on.border", boxOn.border.color)
    kv("checkbox.on.markVisible", labelOf(boxOn).visible)
    kv("checkbox.on.markCode", labelOf(boxOn).text.charCodeAt(0))
    kv("checkbox.on.markPx", labelOf(boxOn).font.pixelSize)
    kv("checkbox.off.color", boxOff.color)
    kv("checkbox.off.borderAlpha", alphaOf(boxOff.border.color))
    kv("checkbox.off.markVisible", labelOf(boxOff).visible)
    kv("checkbox.off.iw", boxOff.implicitWidth)

    // Toggle: geometry, the thumb's two seats, and the dimmed guard that
    // ui.qml does not cover (it covers enabled_ only).
    kv("toggle.on.iw", togOn.implicitWidth)
    kv("toggle.on.ih", togOn.implicitHeight)
    kv("toggle.on.radius", togOn.radius)
    kv("toggle.on.color", togOn.color)
    kv("toggle.on.thumbW", firstRect(togOn).width)
    kv("toggle.on.thumbH", firstRect(togOn).height)
    kv("toggle.on.thumbX", firstRect(togOn).x)
    kv("toggle.on.thumbX.expected", togOn.width - firstRect(togOn).width - 2)
    kv("toggle.on.thumbColor", firstRect(togOn).color)
    kv("toggle.off.thumbX", firstRect(togOff).x)
    kv("toggle.off.color", togOff.color)
    kv("toggle.dimmed.opacity", togDim.opacity)
    kv("toggle.dimmed.thumbX", firstRect(togDim).x)
    kv("toggle.dimmed.areaEnabled", areaOf(togDim).enabled)
    kv("toggle.on.areaEnabled", areaOf(togOn).enabled)
    kv("toggle.dimmed.stillChecked", togDim.checked)
    let dimToggled = 0
    togDim.toggled.connect(function () { dimToggled++ })
    togDim.toggle()
    kv("toggle.dimmed.emits", dimToggled)
    kv("toggle.dimmed.checkedAfter", togDim.checked)
    kv("toggle.on.unaffected", togOn.checked)

    // ProgressBar: the fill as layout, the empty-dim rule and the sweep
    // block's geometry. `fill` and `block` are both Rectangles, so they are
    // read by declaration order (ProgressBar.qml:49 then :72).
    kv("bar.iw", barEmpty.implicitWidth)
    kv("bar.h", barEmpty.height)
    kv("bar.clip", barEmpty.clip)
    kv("bar.empty.opacity", barEmpty.opacity)
    kv("bar.empty.fillW", barEmpty.children[0].width)
    kv("bar.empty.fillVisible", barEmpty.children[0].visible)
    kv("bar.half.fillW", barHalf.children[0].width)
    kv("bar.half.fillExpected", barHalf.width * barHalf.ratio)
    kv("bar.half.opacity", barHalf.opacity)
    kv("bar.loud.opacity", barLoud.opacity)
    kv("bar.loud.fillW", barLoud.children[0].width)
    kv("bar.busy.opacity", barBusy.opacity)
    kv("bar.busy.fillVisible", barBusy.children[0].visible)
    kv("bar.busy.blockVisible", barBusy.children[1].visible)
    kv("bar.busy.blockW", barBusy.children[1].width)
    kv("bar.busy.blockExpected", barBusy.width * 0.3)
    kv("bar.busy.blockH", barBusy.children[1].height)
    kv("bar.fillColor", barHalf.children[0].color)
    kv("bar.trackColor", barHalf.color)
    kv("bar.glideMs", barHalf.glideMs)

    // CapsChip: sized from its own label, and both resting states.
    kv("caps.label.iw", labelOf(capsOff).implicitWidth)
    kv("caps.width", capsOff.width)
    kv("caps.widthExpected", labelOf(capsOff).implicitWidth + 24)
    kv("caps.height", capsOff.height)
    kv("caps.heightExpected", labelOf(capsOff).implicitHeight + 10)
    kv("caps.radius", capsOff.radius)
    kv("caps.border", capsOff.border.width)
    kv("caps.label.text", labelOf(capsOff).text)
    kv("caps.label.ls", labelOf(capsOff).font.letterSpacing)
    kv("caps.label.bold", labelOf(capsOff).font.bold)
    kv("caps.label.px", labelOf(capsOff).font.pixelSize)
    kv("caps.off.restOpacity", capsOff.opacity)
    kv("caps.off.restScale", capsOff.scale)
    kv("caps.on.mirrors", capsOn.on === capsOn.active)
    kv("caps.on.opacity", capsOn.opacity)
    kv("caps.on.scale", capsOn.scale)

    // Vignette: the opacity is the level times the progress, the shape
    // scales with the progress, and a level of nothing draws nothing. The
    // floats are compared here and reported as verdicts, so the assertion
    // does not read a number the printer rounded.
    kv("vig.full.opacityIsLevelTimesProgress", feq(vigFull.opacity, 0.45))
    kv("vig.full.scaleIsSettled", feq(vigFull.scale, 1))
    kv("vig.full.visible", vigFull.visible)
    kv("vig.half.opacityIsHalfTheLevel", feq(vigHalf.opacity, 0.225))
    kv("vig.half.scaleIsTheWalkIn", feq(vigHalf.scale, 1.04))
    kv("vig.none.opacityIsZero", feq(vigNone.opacity, 0))
    kv("vig.none.hidden", !vigNone.visible)

    // DropdownButton: the disabled state as a full visual state, the resting
    // colours, and the click wiring. A real press needs a compositor, so
    // containsMouse/containsPress stay false and the hover/press tints are
    // out of reach - the click itself is driven at the signal level.
    kv("dbtn.height", dbtnOn.height)
    kv("dbtn.heightExpected", Ui.buttonHeight)
    kv("dbtn.radius", dbtnOn.radius)
    kv("dbtn.border", dbtnOn.border.width)
    kv("dbtn.opacity", dbtnOn.opacity)
    kv("dbtn.color.resting", dbtnOn.color)
    kv("dbtn.borderAlpha.resting", alphaOf(dbtnOn.border.color))
    kv("dbtn.accent", dbtnOn.accent)
    kv("dbtn.accent.isRedToken", String(dbtnOn.accent) === Theme.color("red"))
    kv("dbtn.scale.resting", dbtnOn.scale)
    kv("dbtn.label.visible", labelOf(dbtnOn).visible)
    kv("dbtn.label.color", labelOf(dbtnOn).color)
    kv("dbtn.label.bold", labelOf(dbtnOn).font.bold)
    kv("dbtn.label.px", labelOf(dbtnOn).font.pixelSize)
    kv("dbtn.bare.labelVisible", labelOf(dbtnBare).visible)
    kv("dbtn.off.opacity", dbtnOff.opacity)
    kv("dbtn.off.opacityExpected", Ui.disabledOpacity)
    kv("dbtn.off.color", dbtnOff.color)
    kv("dbtn.off.areaEnabled", areaOf(dbtnOff).enabled)
    kv("dbtn.on.areaEnabled", areaOf(dbtnOn).enabled)
    kv("dbtn.clicks", dbtnClicks)

    // Card: the padded content host and the click-capture net under it.
    kv("card.color", card.color)
    kv("card.borderW", card.border.width)
    kv("card.borderColor", card.border.color)
    kv("card.clip", card.clip)
    kv("card.radius", card.radius)
    kv("card.contentW", card.contentArea.width)
    kv("card.contentH", card.contentArea.height)
    kv("card.contentInsetEach", (card.width - card.contentArea.width) / 2)
    kv("card.contentInsetExpected", Ui.outerPad)
    kv("card.captureInput", card.captureInput)
    kv("card.netEnabled", childWith(card, "acceptedButtons") !== null)
    kv("card.net.hoverEnabled", childWith(card, "acceptedButtons").hoverEnabled)

    // Divider: a solid rule, not a tint.
    kv("divider.color", divider.color)
    kv("divider.isSolidToken", String(divider.color) === Theme.color("background_3"))
    kv("divider.borderW", divider.border.width)
    kv("divider.radius", divider.radius)

    // BodyText: the markup toggle, and the styledMarkup contract it is
    // documented to pair with.
    kv("body.defaultFormat", btPlainA.textFormat === Text.PlainText)
    kv("body.markupFormat", btPlainB.textFormat === Text.StyledText)
    kv("body.plain.colorAlpha", alphaOf(btPlainA.color))
    kv("body.px", btPlainA.font.pixelSize)
    kv("body.family.matchesToken", btPlainA.font.family === Ui.fontFamily)
    kv("body.lineHeight", btPlainA.lineHeight)
    kv("body.lineHeightMode.fixed", btPlainA.lineHeightMode === Text.FixedHeight)
    kv("body.wrap.word", btPlainA.wrapMode === Text.WordWrap)
    kv("body.su.b", SU.styledMarkup("<b>hi</b>"))
    kv("body.su.i", SU.styledMarkup("<i>hi</i>"))
    kv("body.su.u", SU.styledMarkup("<u>hi</u>"))
    kv("body.su.closer", SU.styledMarkup("</b>"))
    kv("body.su.upperKept", SU.styledMarkup("<B>x</B>"))
    kv("body.su.otherEscaped", SU.styledMarkup("<blink>z</blink>"))
    kv("body.su.imgEscaped", SU.styledMarkup("<img src=x>"))
    kv("body.su.ampEscaped", SU.styledMarkup("a & b"))
    kv("body.su.ltEscaped", SU.styledMarkup("a < b"))
    kv("body.su.nlBecomesBr", SU.styledMarkup("a\nb"))
    kv("body.su.empty", "'" + SU.styledMarkup("") + "'")
    kv("body.su.null", "'" + SU.styledMarkup(null) + "'")
    // Tag-free copy: markup must not change a single pixel of it.
    kv("body.tagFree.plainLineCount", btPlainA.lineCount)
    kv("body.tagFree.markupLineCount", btPlainB.lineCount)
    kv("body.tagFree.sameLineCount", btPlainA.lineCount === btPlainB.lineCount)
    kv("body.tagFree.plainHeight", btPlainA.implicitHeight)
    kv("body.tagFree.markupHeight", btPlainB.implicitHeight)
    kv("body.tagFree.sameHeight", btPlainA.implicitHeight === btPlainB.implicitHeight)
    kv("body.tagFree.lineCount", btPlainA.lineCount)
    // The tag cases, measured rather than described: contentWidth is the
    // laid-out width of the rendered string, so a parsed tag, a literal tag
    // and an escaped tag are three different widths.
    kv("body.markup.boldMarkupWidth", btBoldMarkup.contentWidth)
    kv("body.markup.boldPlainWidth", btBoldPlain.contentWidth)
    kv("body.markup.rawTagWidth", btRawTag.contentWidth)
    kv("body.markup.escapedTagWidth", btEscapedTag.contentWidth)
    kv("body.markup.boldNarrowerThanLiteral", btBoldMarkup.contentWidth < btBoldPlain.contentWidth)
    kv("body.markup.rawTagImplicitWidth", btRawTag.implicitWidth)
    kv("body.markup.escapedTagImplicitWidth", btEscapedTag.implicitWidth)
    kv("body.markup.rawTagIsDropped", btRawTag.implicitWidth < btEscapedTag.implicitWidth)
    kv("body.markup.rawTagRendersOnlyTheText", btRawTag.implicitWidth < 20)
    kv("body.markup.escapedTagIsLiteral", btEscapedTag.implicitWidth > btRawTag.implicitWidth)
    kv("body.markup.noInjection", btRawTag.implicitWidth < btEscapedTag.implicitWidth)
    // Newlines: PlainText breaks on them, StyledText collapses them, and only
    // styledMarkup's <br> brings the break back.
    kv("body.nl.plainLineCount", btNlPlain.lineCount)
    kv("body.nl.rawInMarkupLineCount", btNlRaw.lineCount)
    kv("body.nl.styledLineCount", btNlStyled.lineCount)
    kv("body.nl.styledMatches",
      btNlStyled.lineCount === btNlPlain.lineCount && SU.styledMarkup("a\nb") === "a<br>b")

    // PanelCard: the chrome ladder, the row-height table and the row-set key.
    kv("pc.chrome.withFilter", cardRows.regionChromeH)
    kv("pc.chrome.withFilterExpected", 2 * cardRows.vPad + Ui.filterH + Ui.listTopGap)
    kv("pc.chrome.withoutFilter", cardNarrow.regionChromeH)
    kv("pc.chrome.withoutFilterExpected", 2 * cardNarrow.vPad)
    kv("pc.availRows", cardRows.availListH)
    kv("pc.screenMaxRowsValue", cardRows.screenMaxListH)
    kv("pc.rowRest.null", cardRows.rowRestHeight(null))
    kv("pc.rowRest.separator", cardRows.rowRestHeight({ kind: "separator" }))
    kv("pc.rowRest.delimiter", cardRows.rowRestHeight({ kind: "delimiter" }))
    kv("pc.rowRest.typeSeparator", cardRows.rowRestHeight({ type: "separator" }))
    kv("pc.rowRest.plain", cardRows.rowRestHeight({ label: "x" }))
    kv("pc.rowRest.sub", cardRows.rowRestHeight({ label: "x", sub: "y" }))
    kv("pc.rowRest.subLeft", cardRows.rowRestHeight({ label: "x", subLeft: "y" }))
    kv("pc.rowRest.plainExpected", Math.max(Ui.rowMinH, realLabelLine.implicitHeight + 2 * Ui.rowPadV))
    kv("pc.rowRest.subExpected",
      Math.max(Ui.rowMinH, realLabelLine.implicitHeight + 1 + realSubLine.implicitHeight
        + 2 * Ui.rowPadV))
    // The claim itself: the estimate IS the delegate's own arithmetic, not a
    // probe of some other string. Read against the same turn's line boxes, so
    // a font-scaled run compares like with like.
    kv("pc.rowRest.isRealLineBoxes",
      feq(cardRows.rowRestHeight({ label: "x", sub: "y" }),
        Math.max(Ui.rowMinH, realLabelLine.implicitHeight + 1 + realSubLine.implicitHeight
          + 2 * Ui.rowPadV)))
    kv("pc.rowRest.plainIsRealLineBoxes",
      feq(cardRows.rowRestHeight({ label: "x" }),
        Math.max(Ui.rowMinH, realLabelLine.implicitHeight + 2 * Ui.rowPadV)))
    kv("pc.rowRest.notTheMgProbe",
      Math.abs(cardRows.rowRestHeight({ label: "x", sub: "y" })
        - Math.max(Ui.rowMinH, capMetrics.height + 1 + subMetrics.height + 2 * Ui.rowPadV)) > 0.5)
    kv("pc.model.threeRows", cardRows.modelContentH())
    kv("pc.model.threeRowsExpected", 3 * cardRows.rowRestHeight({ label: "x" }) + 2 * 2)
    kv("pc.model.noLabels", cardNoLabels.modelContentH())
    kv("pc.model.noLabelsExpected", 2 * cardNoLabels.rowRestHeight({ label: "x" }) + 2)
    kv("pc.key.multiRow", String(cardRows._rowSetKeyForRows()))
    kv("pc.key.singlePlain", String(cardOneRow._rowSetKeyForRows()))
    kv("pc.key.singleSub", String(cardOneSub._rowSetKeyForRows()))
    kv("pc.key.hole", String(cardHole._rowSetKeyForRows()))
    kv("pc.empty.listRegionH", cardEmpty.listRegionH)
    kv("pc.empty.listRegionExpected", Math.min(Ui.emptyMinH, cardEmpty.availListH))
    kv("pc.empty.cardHeight", cardEmpty.cardHeight)
    kv("pc.empty.width", cardEmpty.width)
    kv("pc.empty.contentW", cardEmpty.contentW)
    kv("pc.rows.listRegionH", cardRows.listRegionH)
    kv("pc.rows.cardHeight", cardRows.cardHeight)
    kv("pc.rows.height", cardRows.height)
    kv("pc.rows.heightFollowsCardHeight", feq(cardRows.height, cardRows.cardHeight))
    kv("pc.narrow.avail", cardNarrow.availListH)
    kv("pc.narrow.listRegionH", cardNarrow.listRegionH)
    kv("pc.narrow.model", cardNarrow.modelContentH())
    kv("pc.narrow.regionIsModel", feq(cardNarrow.listRegionH, cardNarrow.modelContentH()))
    kv("pc.narrow.regionBelowAvail", cardNarrow.listRegionH < cardNarrow.availListH)
    kv("pc.narrow.cardHeight", cardNarrow.cardHeight)
    kv("pc.narrow.rowLimit", cardNarrow.rowLimit)
    kv("pc.narrow.count", cardNarrow.count)
    kv("pc.narrow.rowsLength", cardNarrow.rows.length)
    kv("pc.narrow.restingBufH", cardNarrow.restingBufH)
    kv("pc.narrow.contentHeight", cardNarrow.contentHeight)
    kv("pc.narrow.fitPending", cardNarrow.fitPending)
    kv("pc.narrow.exactListH", cardNarrow.exactListH)
    kv("pc.narrow.slotRegionH", cardNarrow.slotRegionH)
    kv("pc.narrow.slotOpen", cardNarrow.slotOpen)
    kv("pc.narrow.restingListH", cardNarrow.restingListH)
    kv("pc.narrow.snapped", cardNarrow.snappedListH(cardNarrow.availListH))
    kv("pc.narrow.hasRowLimitFunction", typeof cardNarrow.rowLimitRegion)
    kv("pc.five.rowLimit", cardFive.rowLimit)
    kv("pc.five.rowsLength", cardFive.rows.length)
    kv("pc.five.model", cardFive.modelContentH())
    kv("pc.five.snapped", cardFive.snappedListH(cardFive.availListH))
    kv("pc.five.avail", cardFive.availListH)
    kv("pc.fiveNoCap.listRegionH", cardFiveNoCap.listRegionH)
    kv("pc.fiveNoCap.model", cardFiveNoCap.modelContentH())
    kv("pc.slot.listRegionH", cardSlot.listRegionH)
    kv("pc.slot.claimsRegion", feq(cardSlot.listRegionH, 300))
    kv("pc.slot.reserved", cardSlot.listRegionH === cardSlot.availListH ? "window" : "expansion")
    kv("pc.slot.cardHeight", cardSlot.cardHeight)
    kv("pc.slot.cardHeightExpected", cardSlot.regionChromeH + 300 + cardSlot.bottomReserve)
    kv("pc.shown.gateClosed", cardRows.shown)
    kv("pc.clip", cardRows.clip)
    kv("pc.gateEscape.defaultOff", cardGate.sizeMotionDuringGate)

    // The capped card, with the resting buffer standing in for a measured
    // whole-list extent. The estimate is exact now, so a real measurement
    // carries no surplus over it - which is the point: the two measures then
    // differ ONLY by the cap's composition, and the difference is the
    // separator being charged a full row by a row-count scaling.
    cardClipCap.restingBufH = cardClipCap.modelContentH(0)
    const clipShown = Math.min(cardClipCap.rowLimit, cardClipCap.rows.length)
    const clipPhantom = cardClipCap.restingBufH * clipShown / cardClipCap.rows.length
    kv("pc.clipCap.estCap", cardClipCap.modelContentH())
    kv("pc.clipCap.estAll", cardClipCap.modelContentH(0))
    kv("pc.clipCap.estAllAboveCap", cardClipCap.modelContentH(0) > cardClipCap.modelContentH())
    kv("pc.clipCap.capSmallerThanAll", cardClipCap.modelContentH() * 2
      < cardClipCap.modelContentH(0))
    kv("pc.clipCap.cappedRows", clipShown)
    kv("pc.clipCap.rowCountScale", clipPhantom)
    kv("pc.clipCap.cappedBufH", cardClipCap.cappedBufH)
    kv("pc.clipCap.estCapExpected",
      cardClipCap.restingBufH * cardClipCap.modelContentH() / cardClipCap.modelContentH(0))
    kv("pc.clipCap.estimateIsExact", feq(cardClipCap.cappedBufH, cardClipCap.modelContentH()))
    // The allowance goes between the two measures: above the height the
    // capped rows really occupy, below the height a row-COUNT scaling claims
    // for them. That gap is the launcher's clipboard case.
    cardClipCap.maxHeight = cardClipCap.regionChromeH
      + (cardClipCap.cappedBufH + clipPhantom) / 2
    kv("pc.clipCap.avail", cardClipCap.availListH)
    kv("pc.clipCap.region", cardClipCap.rowLimitRegion(cardClipCap.availListH))
    kv("pc.clipCap.isAvail", feq(cardClipCap.listRegionH, cardClipCap.availListH))
    kv("pc.clipCap.belowRowCountScale", cardClipCap.cappedBufH < clipPhantom)
    kv("pc.clipCap.rowCountScaleExceedsAvail", clipPhantom > cardClipCap.availListH)
    kv("pc.clipCap.availAboveRealCap", cardClipCap.availListH > cardClipCap.cappedBufH)
    // Same rows, a window too small for the cap: the answer has to be the
    // largest whole prefix that fits, never the allowance itself.
    cardClipCap.maxHeight = cardClipCap.regionChromeH + cardClipCap.cappedBufH * 0.5
    kv("pc.clipCap.crampedRegion", cardClipCap.rowLimitRegion(cardClipCap.availListH))
    kv("pc.clipCap.crampedIsAvail", feq(cardClipCap.listRegionH, cardClipCap.availListH))
    kv("pc.clipCap.crampedIsWholePrefix",
      feq(cardClipCap.listRegionH, cardClipCap.snappedListH(cardClipCap.availListH)))
    kv("pc.clipCap.crampedUnderAvail", cardClipCap.listRegionH < cardClipCap.availListH)
    kv("pc.borderW", cardRows.border.width)
    kv("pc.color", cardRows.color)
    kv("pc.anchors", cardRows.anchors.centerIn === cardRows.parent ? "parent" : "elsewhere")

    // GridList: the cell origins as layout, the count === 0 guards, and the
    // MenuPanel column arithmetic the grid is measured against.
    kv("grid.count", grid.count)
    kv("grid.cellW", grid.cellWidth)
    kv("grid.cellH", grid.cellHeight)
    kv("grid.declaredCols", grid.cols)
    kv("grid.viewportW", grid.width)
    kv("grid.viewportCols", Math.floor(grid.width / grid.cellWidth))
    kv("grid.contentHeight", grid.contentHeight)
    kv("grid.contentHeightExpected", Math.ceil(7 / 3) * grid.cellHeight)
    kv("grid.x0", cellX(grid, 0))
    kv("grid.x1", cellX(grid, 1))
    kv("grid.x2", cellX(grid, 2))
    kv("grid.x3", cellX(grid, 3))
    kv("grid.x6", cellX(grid, 6))
    kv("grid.y0", cellY(grid, 0))
    kv("grid.y3", cellY(grid, 3))
    kv("grid.y6", cellY(grid, 6))
    kv("grid.lastColRightEdge", cellX(grid, 2) + grid.cellWidth)
    kv("grid.lastColWithinViewport", cellX(grid, 2) + grid.cellWidth <= grid.width)
    kv("grid.oddRowStartsAtCol0", cellX(grid, 6) === 0)
    kv("grid.cellRowStride", cellY(grid, 3) - cellY(grid, 0))
    kv("grid.prefixX0", Zone.prefixX([100, 100, 100])[0])
    kv("grid.prefixX1", Zone.prefixX([100, 100, 100])[1])
    kv("grid.prefixX2", Zone.prefixX([100, 100, 100])[2])
    kv("grid.prefixXTotal", Zone.prefixX([100, 100, 100])[3])
    kv("grid.totalWidth", Zone.totalWidth([100, 100, 100]))
    kv("grid.totalWidthIsViewport", Zone.totalWidth([100, 100, 100]) === grid.width)
    kv("grid.ten.contentHeight", gridTen.contentHeight)
    kv("grid.ten.contentHeightExpected", Math.ceil(10 / 3) * gridTen.cellHeight)
    kv("grid.ten.x9", cellX(gridTen, 9))
    kv("grid.ten.y9", cellY(gridTen, 9))
    kv("grid.ten.lastRightEdge", cellX(gridTen, 9) + gridTen.cellWidth)
    kv("grid.empty.count", gridEmpty.count)
    kv("grid.empty.contentHeight", gridEmpty.contentHeight)
    kv("grid.empty.currentIndex", gridEmpty.currentIndex)
    kv("grid.empty.gotoCell", gridEmpty.gotoCell(0))
    kv("grid.empty.moveCell", gridEmpty.moveCell(1))
    kv("grid.empty.moveRow", gridEmpty.moveRow(1))
    kv("grid.empty.settle", gridEmpty.settle(0, true))
    kv("grid.empty.sweepToEnd", gridEmpty.sweepToEnd(true))
    kv("grid.empty.reveal", gridEmpty.reveal(0))
    kv("grid.empty.indexAfter", gridEmpty.currentIndex)
    kv("grid.fit.cols", root.fitCols)
    kv("grid.fit.side", root.fitSide)
    kv("grid.fit.formula.cols", menuFit(392, 46).cols)
    kv("grid.fit.formula.side", menuFit(392, 46).side)
    kv("grid.fit.formula.slack", menuFit(392, 46).slack)
    kv("grid.fit.viewportW", gridFit.width)
    kv("grid.fit.viewportCols", Math.floor(gridFit.width / gridFit.cellWidth))
    kv("grid.fit.slack", 392 - root.fitCols * root.fitSide)
    kv("grid.fit.slackUnderOneCell", (392 - root.fitCols * root.fitSide) < root.fitCols)
    kv("grid.fit.neverOverflows", root.fitCols * root.fitSide <= 392)
    kv("grid.fit.raggedNeverOverflows", menuFit(301, 46).cols * menuFit(301, 46).side <= 301)
    kv("grid.fit.raggedSlackUnderOneCell", menuFit(301, 46).slack < menuFit(301, 46).cols)
    kv("grid.fit.tinyNeverZeroCols", menuFit(20, 46).cols)
    kv("grid.fit.tinySide", menuFit(20, 46).side)
    kv("grid.fit.x7", cellX(gridFit, 7))
    kv("grid.fit.lastRightEdge", cellX(gridFit, 7) + gridFit.cellWidth)
    kv("grid.fit.lastRightEdgeWithin", cellX(gridFit, 7) + gridFit.cellWidth <= 392)
    kv("grid.fit.cellMatchesSide", feq(gridFit.cellWidth, root.fitSide))

    // ScrollBar: the wrapper's own policy properties.
    kv("sb.width", barLong.width)
    kv("sb.thickness", barLong.thickness)
    kv("sb.target.isTarget", barLong.target === longFlick)
    kv("sb.visible.scrollable", barLong.visible)
    kv("sb.visible.notScrollable", barShort.visible)
    kv("sb.short.size", controlOf(barShort).size)
    kv("sb.short.size.isOne", controlOf(barShort).size === 1)
    kv("sb.long.opacity.autoHide", barLong.opacity)
    kv("sb.long.opacity.pinned", barPinned.opacity)
    kv("sb.long.minimumSize", controlOf(barLong).minimumSize)
    kv("sb.long.minimumSizeExpected", Math.min(1, barLong.minThumb / barLong.height))
    kv("sb.fat.minimumSize", controlOf(barFat).minimumSize)
    kv("sb.fat.minimumSizeExpected", Math.min(1, 500 / 200))
    kv("sb.zero.height", barZero.height)
    kv("sb.zero.minimumSize", controlOf(barZero).minimumSize)
    kv("sb.zero.minimumSizeIsNumber", typeof controlOf(barZero).minimumSize)
    kv("sb.fat.thickness", barFat.width)
    kv("sb.fat.radius", thumbOf(barFat).radius)
    kv("sb.pinned.radius", thumbOf(barPinned).radius)
    kv("sb.shadow.widthIsTargetWidth", shadowOf(barLong).width)
    kv("sb.shadow.widthIsNotBarWidth", shadowOf(barLong).width !== barLong.width)
    kv("sb.shadow.contentHeight", shadowOf(barLong).contentHeight)
    kv("sb.shadow.height", shadowOf(barLong).height)
    kv("sb.shadow.visible", shadowOf(barLong).visible)
    kv("sb.shadow.interactive", shadowOf(barLong).interactive)
    kv("sb.long.size", controlOf(barLong).size)
    kv("sb.long.thumbW", thumbOf(barLong).width)
    kv("sb.long.thumbH", thumbOf(barLong).height)
    kv("sb.long.thumbY", thumbOf(barLong).y)
    kv("sb.long.thumbAlpha", alphaOf(thumbOf(barLong).color))
    kv("sb.fat.thumbH", thumbOf(barFat).height)
    kv("sb.fat.thumbNeverExceeds", thumbOf(barFat).height <= barFat.height)
    kv("sb.long.minimumSize.isMinThumbFraction",
      feq(controlOf(barLong).minimumSize, Math.min(1, barLong.minThumb / barLong.height)))

    // DropdownSlot at rest: the velocity-paced duration and the per-instance
    // states that must not share anything.
    kv("slotShort.gap", slotShort.gap)
    kv("slotShort.contentHeight", slotShort.children[0].height)
    kv("slotShort.slotMs", slotShort.slotMs)
    kv("slotShort.slotMsExpected",
      Math.max(Ui.fastMs, Math.min(Ui.slowMs,
        Math.round((slotShort.children[0].height + slotShort.gap) / Ui.slotVpx * 1000))))
    kv("slotShort.height", slotShort.height)
    kv("slotShort.opacity", slotShort.opacity)
    kv("slotShort.closing", slotShort.closing)
    kv("slotShort.nested", slotShort.nestedItem === null ? "null" : "obj")
    kv("slotTall.gap", slotTall.gap)
    kv("slotTall.contentHeight", slotTall.children[0].height)
    kv("slotTall.slotMs", slotTall.slotMs)
    kv("slotTall.slotMsExpected",
      Math.max(Ui.fastMs, Math.min(Ui.slowMs,
        Math.round((slotTall.children[0].height + slotTall.gap) / Ui.slotVpx * 1000))))
    kv("slotShort.slotMs.differsFromTall", slotShort.slotMs !== slotTall.slotMs)
    kv("slotTall.slotMs.isSlowCap", slotTall.slotMs === Ui.slowMs)
    kv("slotShort.slotMs.isFastFloor", slotShort.slotMs === Ui.fastMs)
    kv("slotTall.height", slotTall.height)
    kv("slotTall.closing", slotTall.closing)
    kv("slotTall.nested", slotTall.nestedItem === null ? "null" : "obj")
    kv("slotIdle.height", slotIdle.height)
    kv("slotIdle.closing", slotIdle.closing)
    kv("slotIdle.graceArmed", slotIdle.closeGrace.running)
    kv("slotShort.grace", slotShort.closeGrace.interval)
    kv("slotShort.graceExpected", Math.max(slotShort.slotMs, Ui.normalMs) + 20)
    kv("slotTall.grace", slotTall.closeGrace.interval)
    kv("slotTall.graceExpected", Math.max(slotTall.slotMs, Ui.normalMs) + 20)
    kv("slotShort.graceOutlivesHeight", slotShort.closeGrace.interval > slotShort.slotMs)
    kv("slotTall.graceOutlivesHeight", slotTall.closeGrace.interval > slotTall.slotMs)
  }

  // A PanelWindow cannot exist without a compositor. Attempted at runtime so
  // the failure is data instead of a config that never loads: the exact
  // message is the evidence that the type itself resolved out of qs.common
  // and only its base type could not be created.
  function attemptScrimWindow() {
    let made = null
    try {
      made = Qt.createQmlObject(
        "import QtQuick\nimport Quickshell\nimport Quickshell.Wayland\nimport qs.common\n"
        + "ScrimWindow { dim: 0.45 }", root, "runtimeScrim")
    } catch (e) {
      root.scrimError = String(e && e.message ? e.message : e)
    }
    kv("scrim.object", made === null ? "null" : "object")
    kv("scrim.err.typeUnavailable", root.scrimError.indexOf("Type ScrimWindow unavailable") >= 0)
    kv("scrim.err.panelWindowBackend", root.scrimError.indexOf("No PanelWindow backend loaded") >= 0)
    kv("scrim.err.reachedSourceFile", root.scrimError.indexOf("ui/ScrimWindow.qml") >= 0)
    kv("scrim.err.moduleMissing", root.scrimError.indexOf("is not installed") >= 0)
    kv("scrim.err.hasLineNumber", root.scrimError.indexOf("ScrimWindow.qml:11:1") >= 0)
  }

  // ---- turn 1: the icon scan has landed; every tween starts here ------

  function turn1() {
    kv("icon.scan.indexed", Icons.indexedCount)
    kv("icon.scan.ready", Icons.ready)
    kv("icon.url.known.isDataUrl", isDataUrl(baseOf(icPlain).source))
    kv("icon.url.known.length", String(baseOf(icPlain).source).length)
    kv("icon.url.known.prefix", String(baseOf(icPlain).source).slice(0, 22))
    kv("icon.url.known.hasBodyTone", has(baseOf(icPlain).source, enc(Theme.color("foreground_0"))))
    kv("icon.url.known.bodyToneIsForeground0", enc(Theme.color("foreground_0")))
    kv("icon.url.known.paintsRewritten", !has(baseOf(icPlain).source, "currentColor"))
    kv("icon.url.literalColorKey.isDataUrl", isDataUrl(baseOf(icLit).source))
    kv("icon.url.literalColorKey.hasLiteral", has(baseOf(icLit).source, enc("#ff0000")))
    kv("icon.url.literalColorKey.skipsPalette", !has(baseOf(icLit).source, enc(Theme.color("foreground_0"))))
    kv("icon.url.unknown.isDataUrl", isDataUrl(baseOf(icUnknown).source))
    kv("icon.url.unknown.length", String(baseOf(icUnknown).source).length)
    kv("icon.url.unknown.status", baseOf(icUnknown).status)
    kv("icon.url.unknown.ready", icUnknown.ready)
    kv("icon.url.unknown.slotStillReserved", icUnknown.implicitWidth)
    kv("icon.url.unknown.features", icUnknown._feat === null ? "null" : "object")
    kv("icon.url.noName.isDataUrl", isDataUrl(baseOf(icNoName).source))
    kv("icon.url.noName.length", String(baseOf(icNoName).source).length)
    kv("icon.url.noName.features", icNoName._feat === null ? "null" : "object")
    kv("icon.url.noColorKey.isDataUrl", isDataUrl(baseOf(icNoColorKey).source))
    kv("icon.url.badAccent.isDataUrl", isDataUrl(baseOf(icBadAccent).source))
    kv("icon.url.badAccent.paintedWithFallback",
      has(baseOf(icBadAccent).source, enc(Theme.color("not_a_palette_key"))))
    kv("icons.url.unknownName", "'" + Icons.url("definitely_not_an_icon", "foreground_0", "", "", 0) + "'")
    kv("icons.url.emptyName", "'" + Icons.url("", "foreground_0", "", "", 0) + "'")
    kv("icons.url.knownName.length", Icons.url("mic-off", "foreground_0", "", "", 0).length)
    kv("icons.url.sameName.length", Icons.url("clock", "foreground_0", "", "", 0).length)
    kv("icons.url.badAccentKey.length",
      Icons.url("mic-off", "foreground_0", "not_a_palette_key", "", 0).length)
    kv("icons.url.badAccentKey.paintsFallback",
      Icons.url("mic-off", "foreground_0", "not_a_palette_key", "", 0).indexOf(enc(Theme.color("not_a_palette_key"))) >= 0)
    kv("icons.features.indicatorNoBehavior", JSON.stringify(Icons._features["mic-off"]))
    kv("icons.features.blink", JSON.stringify(Icons._features["bluetooth-connected"]))
    kv("icons.features.tiered", JSON.stringify(Icons._features["volume-max"]))
    kv("icons.features.plainAsset", JSON.stringify(Icons._features["clock"]))
    kv("icons.cache.size", Icons.cacheSize())
    // PanelCard.listRegionH read one event-loop turn later. At
    // Component.onCompleted it reads 272 (the whole window) for a
    // row-limited card whose rows are declared in the same object literal,
    // because `rowLimit` is assigned before `rows` and snappedListH() falls
    // back to min(avail, screenMaxListH) when it sums nothing
    // (PanelCard.qml:226). The first turn re-evaluates it correctly.
    kv("pc.narrow.settled.listRegionH", cardNarrow.listRegionH)
    kv("pc.narrow.settled.cardHeight", cardNarrow.cardHeight)
    kv("pc.narrow.settled.height", cardNarrow.height)
    kv("pc.narrow.settled.regionIsModel", feq(cardNarrow.listRegionH, cardNarrow.modelContentH()))
    kv("pc.narrow.settled.regionBelowAvail", cardNarrow.listRegionH < cardNarrow.availListH)
    kv("pc.five.overCap.listRegionH", cardFive.listRegionH)
    kv("pc.five.overCap.regionFn", cardFive.rowLimitRegion(cardFive.availListH))
    kv("pc.five.overCap.isAvail", feq(cardFive.listRegionH, cardFive.availListH))
    // The cap is the card's own measure, so it has to agree with the other
    // capped measure of the same rows instead of answering a different
    // question about them.
    kv("pc.five.overCap.matchesSnapped",
      feq(cardFive.listRegionH, cardFive.snappedListH(cardFive.availListH)))
    kv("pc.fiveNoCap.cardHeight", cardFiveNoCap.cardHeight)
    kv("pc.oneRow.listRegionH", cardOneRowRegion.listRegionH)
    kv("pc.oneRow.cardHeight", cardOneRowRegion.cardHeight)
    kv("pc.oneRow.avail", cardOneRowRegion.availListH)
    kv("pc.oneRow.model", cardOneRowRegion.modelContentH())
    kv("icon.ready.plain", icPlain.ready === (baseOf(icPlain).status === Image.Ready))
    kv("icon.layered.needsAccent", icNoAccent._layered)
    kv("icon.layered.needsActive", icNotActive._layered)
    kv("icon.layered.engaged", icTwo._layered)
    kv("icon.anim.notLayered", "'" + icPlain._anim + "'")
    kv("icon.anim.defaultForNoBehavior", "'" + icTwo._anim + "'")
    kv("icon.anim.explicitBlink", "'" + icBlink._anim + "'")
    kv("icon.anim.unknownOverrideFallsBack", "'" + icJunk._anim + "'")
    kv("icon.anim.motionGate", icTwo._animOn)
    kv("icon.base.hasAccent", has(baseOf(icTwo).source, enc(Theme.color("red"))))
    kv("icon.base.indicatorForcedNone", has(baseOf(icTwo).source, "none"))
    const ind = indicatorOf(icTwo)
    kv("icon.indicator.exists", ind !== null)
    kv("icon.indicator.isDataUrl", ind !== null && isDataUrl(ind.source))
    kv("icon.indicator.hasAccent", ind !== null && has(ind.source, enc(Theme.color("red"))))
    kv("icon.indicator.isIndicatorOnly", ind !== null && has(ind.source, "class%3D%22indicator%22"))
    kv("icon.loader.active", loaderOf(icTwo).active)
    kv("icon.loader.status", loaderOf(icTwo).status)
    kv("icon.loader.ready", loaderOf(icTwo).status === Loader.Ready)
    kv("icon.loader.inactiveWhenNotLayered", loaderOf(icNotActive).active)
    kv("icon.loader.inactiveWhenPlain", loaderOf(icPlain).active)
    kv("icon.staticTwoTone.hasBody", has(baseOf(icStatic).source, enc(Theme.color("foreground_0"))))
    kv("icon.staticTwoTone.hasAccent", has(baseOf(icStatic).source, enc(Theme.color("red"))))
    kv("icon.tier.differsFromFull", String(baseOf(icTier1).source) !== String(baseOf(icTier0).source))
    kv("icon.tier.dimsOuterGroups",
      has(baseOf(icTier1).source, enc(mixHex(Theme.color("foreground_0"), Theme.color("background_0")))))
    kv("icon.tier.fullHasNoGhost",
      !has(baseOf(icTier0).source, enc(mixHex(Theme.color("foreground_0"), Theme.color("background_0")))))
    kv("icon.tier.ghostTone", mixHex(Theme.color("foreground_0"), Theme.color("background_0")))
    kv("icon.size.slotFromToken", icPlain.implicitWidth)
    kv("icon.size.slotIsSquare", icPlain.implicitWidth === icPlain.implicitHeight)
    kv("icon.size.override.implicit", icBig.implicitWidth)
    kv("icon.size.override.ih", icBig.implicitHeight)
    kv("icon.size.override.imageW", baseOf(icBig).width)
    kv("icon.size.override.imageH", baseOf(icBig).height)
    kv("icon.size.override.sourceSize", baseOf(icBig).sourceSize.width)
    kv("icon.size.override.leavesSlotToken", icBig.slotSize)
    kv("icon.size.override.leavesCanvasToken", icBig.canvasSize)
    kv("icon.size.otherInstanceUnaffected", icPlain.implicitWidth)
    kv("icon.size.isolation", icPlain.implicitWidth !== icBig.implicitWidth)
    kv("icon.size.plainSourceSize", baseOf(icPlain).sourceSize.width)
    kv("icon.size.sourceSizeIsCanvasTimesDpr", baseOf(icBig).sourceSize.width === icBig._canvas * icBig._dpr)
    kv("icon.size.raster.dpr", icBig._dpr)

    // Focus is only real after the first turn - at Component.onCompleted
    // forceActiveFocus() is still declined by the engine.
    focusPlain.grabList()
    kv("focus.grabList.mode", focusPlain.mode)
    kv("focus.grabList.focus", focusPlain.keySink.focus)
    kv("focus.grabList.activeFocus", focusPlain.keySink.activeFocus)
    focusOther.grabList()
    kv("focus.isolation.mode", focusOther.mode)
    kv("focus.isolation.otherSinkFocus", focusOther.keySink.focus)
    kv("focus.isolation.sinkDistinct", focusPlain.keySink !== focusOther.keySink)
    focusOther.grabFilter()
    kv("focus.noField.modeUnchanged", focusOther.mode)
    searchField.input.text = "hello"
    focusField.grabFilter()
    kv("focus.grabFilter.mode", focusField.mode)
    kv("focus.grabFilter.probe", JSON.stringify(focusField.probe()))
    kv("focus.grabFilter.cursor", searchField.input.cursorPosition)
    kv("focus.grabFilter.cursorExpected", searchField.input.text.length)
    kv("focus.isolation.fieldMode", focusField2.mode)
    focusField2.grabFilter()
    kv("focus.isolation.secondFieldMode", focusField2.mode)
    kv("focus.isolation.firstUnaffected", focusField.mode)

    // Signal-level drives. A real press needs a compositor, so these exercise
    // the handler chain and the signal, not hit testing.
    confirm.confirmed()
    kv("confirm.confirmed.afterEmit", confirmHits)
    kv("confirm.cancelled.afterEmit", cancelHits)
    dbtnOn.clicked()
    kv("dbtn.clicks.afterEmit", dbtnClicks)
    dbtnOff.clicked()
    kv("dbtn.offClicks.afterEmit", dbtnOffClicks)
    kv("dbtn.offSignalIsUngated", dbtnOffClicks === 1)
    kv("dbtn.enabledGateIsTheArea", areaOf(dbtnOff).enabled)
    zebra0.clicked(null)
    kv("zebra.clicks.afterEmit", zebraClicks)

    // GridList's cursor machine, driven synchronously.
    kv("cursor.gotoCell.belowRange", grid.gotoCell(-5))
    kv("cursor.gotoCell.belowRangeIdx", grid.currentIndex)
    kv("cursor.gotoCell.aboveRange", grid.gotoCell(999))
    kv("cursor.gotoCell.aboveRangeIdx", grid.currentIndex)
    kv("cursor.gotoCell.again", grid.gotoCell(6))
    // The default firstSelectable/lastSelectable are () => -1, so a step off
    // either end clamps to the first cell rather than throwing.
    grid.firstSelectable = () => -1
    grid.lastSelectable = () => -1
    kv("cursor.moveRow.down", grid.moveRow(1))
    kv("cursor.moveRow.downIdx", grid.currentIndex)
    kv("cursor.moveRow.defaultEndIsMinusOne", grid.currentIndex === 0)
    grid.firstSelectable = () => 1
    grid.lastSelectable = () => 5
    grid.currentIndex = 1
    kv("cursor.moveRow.stepDown", grid.moveRow(1))
    kv("cursor.moveRow.stepDownIdx", grid.currentIndex)
    kv("cursor.moveRow.downStep", grid.currentIndex - 1)
    kv("cursor.moveRow.downStepExpected", grid.cols)
    kv("cursor.moveRow.up", grid.moveRow(-1))
    kv("cursor.moveRow.upIdx", grid.currentIndex)
    grid.currentIndex = -1
    kv("cursor.unseated", grid.currentIndex)
    kv("cursor.moveCell.downFromUnseated", grid.moveCell(1))
    kv("cursor.moveCell.downFromUnseatedIdx", grid.currentIndex)
    grid.currentIndex = -1
    grid.moveCell(-1)
    kv("cursor.moveCell.upFromUnseatedIdx", grid.currentIndex)
    kv("cursor.upFromUnseatedIsLast", grid.currentIndex === grid.count - 1)
    grid.isSelectable = i => i !== 4
    grid.currentIndex = 3
    grid.moveCell(1)
    kv("cursor.skipRejected", grid.currentIndex)
    grid.isSelectable = i => i % 2 === 0
    grid.currentIndex = 2
    grid.moveCell(1)
    kv("cursor.skipToAccepted", grid.currentIndex)
    grid.isSelectable = () => false
    grid.firstSelectable = () => -1
    grid.lastSelectable = () => -1
    grid.currentIndex = 0
    grid.moveCell(1)
    kv("cursor.nothingSelectable", grid.currentIndex)
    kv("cursor.nothingSelectableWithDefaultEnds", grid.currentIndex === 0)
    grid.isSelectable = () => false
    grid.firstSelectable = () => 2
    grid.lastSelectable = () => 5
    grid.currentIndex = 0
    grid.moveCell(1)
    kv("cursor.nothingSelectableToLastHelper", grid.currentIndex)
    grid.isSelectable = i => i >= 2
    grid.currentIndex = 6
    grid.moveCell(1)
    kv("cursor.wrapForward", grid.currentIndex)
    grid.currentIndex = 0
    grid.moveCell(-1)
    kv("cursor.wrapBackward", grid.currentIndex)
    grid.isSelectable = i => i >= 2
    grid.settle(0, true)
    kv("cursor.settleSkipsLeading", grid.currentIndex)
    grid.settle(1, true)
    kv("cursor.settleOnRejected", grid.currentIndex)
    grid.reveal(0)
    kv("cursor.revealOutOfRange", grid.currentIndex)
    grid.isSelectable = i => true
    grid.firstSelectable = () => -1
    grid.lastSelectable = () => -1
    kv("cursor.cancelSweep", grid.cancelSweep())
    kv("cursor.sweepingAfterCancel", grid.sweeping)
    kv("cursor.otherGridUntouched", gridTen.currentIndex)

    // Start everything that is sampled in flight.
    glide.restart()
    capsOff.active = true
    barEmpty.value = 100
    sweepGrid.sweepToEnd(true)
    kv("sweep.flagSetAtCall", sweepGrid.sweeping)
    kv("sweep.from", sweepGrid.sweepY0)
    kv("sweep.to", sweepGrid.sweepTo)
    kv("sweep.targetIsMaxY", feq(sweepGrid.sweepTo, Math.max(0, sweepGrid.contentHeight - sweepGrid.height)))
    cancelGrid.sweepToEnd(true)
    kv("cancel.flagSetAtCall", cancelGrid.sweeping)
    cancelGrid.cancelSweep()
    kv("cancel.flagAfterCancel", cancelGrid.sweeping)
    slotShort.open = true
    slotTall.open = true
    slotCycle.open = true
    slotReopen.open = true
    cardPlain.show()

    // The show gate, watched from both sides. cardGate is never shown, so
    // `shown` stays false for the whole run: a resize with the escape clear
    // has to snap, and the same resize with the escape set has to tween.
    // Both are read as a verdict, never as a frame-accurate height.
    cardGate.rows = [{ label: "one" }, { label: "two" }, { label: "three" }]
    kv("pc.gate.gateClosed", cardGate.shown)
    kv("pc.gate.snappedToTarget", feq(cardGate.height, cardGate.cardHeight))
    kv("pc.gate.snappedHeight", cardGate.height)
    cardGate.sizeMotionDuringGate = true
    cardGate.rows = [{ label: "one" }]
    kv("pc.gate.escapeArmed", cardGate.sizeMotionDuringGate)
    root.gateStartH = cardGate.height
    kv("pc.gate.startHeight", cardGate.height)
    kv("pc.gate.targetHeight", cardGate.cardHeight)
    kv("pc.gate.shrinking", cardGate.cardHeight < root.gateStartH)
  }

  // ---- turns 2..8: the tweens, sampled in flight ----------------------

  function turn2() {
    sample(glideV, glideTarget.v)
    sample(capsScaleV, capsOff.scale)
    sample(capsOpacityV, capsOff.opacity)
    sample(barFillV, barEmpty.children[0].width)
    sample(sweepYV, sweepGrid.contentY)
    sample(gateHV, cardGate.height)
    sample(slotShortHV, slotShort.height)
    sample(slotShortOV, slotShort.opacity)
    sample(slotTallHV, slotTall.height)
    sample(slotTallOV, slotTall.opacity)
    kv("glide.v.s1", glideTarget.v)
    kv("glide.midFlight", between(glideTarget.v, 0, 100))
    kv("glide.neverOvershoots", glideTarget.v <= 100)
    kv("caps.scale.s1", capsOff.scale)
    kv("caps.opacity.s1", capsOff.opacity)
    kv("caps.scale.midFlight", between(capsOff.scale, 0.9, 1))
    kv("caps.neverOvershoots", capsOff.scale <= 1)
    kv("bar.fill.s1", barEmpty.children[0].width)
    kv("bar.fill.midFlight", between(barEmpty.children[0].width, 0, 100))
    kv("bar.fill.neverOvershoots", barEmpty.children[0].width <= 100)
    kv("bar.fill.expectedTarget", barEmpty.width * barEmpty.ratio)
    kv("sweep.flagCleared", sweepGrid.sweeping)
    kv("sweep.contentY.s1", sweepGrid.contentY)
    kv("sweep.neverOvershoots", sweepGrid.contentY <= sweepGrid.sweepTo)
    kv("cancel.contentY", cancelGrid.contentY)
    kv("slotShort.height.s1", slotShort.height)
    kv("slotShort.heightTarget", slotShort.children[0].height + slotShort.gap)
    kv("slotShort.opacity.s1", slotShort.opacity)
    kv("slotShort.nestedTurn2", slotShort.nestedItem === null ? "null" : "obj")
    kv("slotTall.height.s1", slotTall.height)
    kv("slotTall.heightTarget", slotTall.children[0].height + slotTall.gap)
    kv("slotTall.nestedTurn2b", slotTall.nestedItem === null ? "null" : "obj")
    kv("slotShort.closingTurn2", slotShort.closing)
    kv("slotIdle.closingTurn2", slotIdle.closing)
  }

  function turn3() {
    sample(glideV, glideTarget.v)
    sample(capsScaleV, capsOff.scale)
    sample(capsOpacityV, capsOff.opacity)
    sample(barFillV, barEmpty.children[0].width)
    sample(sweepYV, sweepGrid.contentY)
    sample(gateHV, cardGate.height)
    sample(slotShortHV, slotShort.height)
    sample(slotShortOV, slotShort.opacity)
    sample(slotTallHV, slotTall.height)
    sample(slotTallOV, slotTall.opacity)
    kv("glide.v.s2", glideTarget.v)
    kv("glide.increased", glideTarget.v > 0)
    kv("caps.scale.s2", capsOff.scale)
    kv("caps.opacity.s2", capsOff.opacity)
    kv("bar.fill.s2", barEmpty.children[0].width)
    kv("sweep.contentY.s2", sweepGrid.contentY)
    kv("sweep.moving", sweepGrid.contentY > 0)
    kv("slotShort.height.s2", slotShort.height)
    kv("slotShort.opacity.s2", slotShort.opacity)
    kv("slotTall.height.s2", slotTall.height)
    kv("confirm.stageText.before", textsIn(confirm)[0].text)
    confirm.stage = 2
    kv("confirm.stageText.after", textsIn(confirm)[0].text)
    kv("confirm.stageText.isArmed", textsIn(confirm)[0].text === confirm.armedText)
    kv("confirm.stageKeepsHeight", feq(confirm.height, confirm.children[0].height + confirm.gap))
  }

  function turn4() {
    sample(glideV, glideTarget.v)
    sample(capsScaleV, capsOff.scale)
    sample(capsOpacityV, capsOff.opacity)
    sample(barFillV, barEmpty.children[0].width)
    sample(sweepYV, sweepGrid.contentY)
    sample(gateHV, cardGate.height)
    sample(slotShortHV, slotShort.height)
    sample(slotShortOV, slotShort.opacity)
    sample(slotTallHV, slotTall.height)
    sample(slotTallOV, slotTall.opacity)
    kv("glide.v.s3", glideTarget.v)
    kv("caps.scale.s3", capsOff.scale)
    kv("caps.opacity.s3", capsOff.opacity)
    kv("bar.fill.s3", barEmpty.children[0].width)
    kv("sweep.contentY.s3", sweepGrid.contentY)
    kv("slotShort.height.s3", slotShort.height)
    kv("slotShort.opacity.s3", slotShort.opacity)
    kv("slotTall.height.s3", slotTall.height)
    kv("slotTall.opacity.s3", slotTall.opacity)
  }

  function turn5() {
    sample(glideV, glideTarget.v)
    sample(capsScaleV, capsOff.scale)
    sample(capsOpacityV, capsOff.opacity)
    sample(barFillV, barEmpty.children[0].width)
    sample(sweepYV, sweepGrid.contentY)
    sample(gateHV, cardGate.height)
    sample(slotShortHV, slotShort.height)
    sample(slotShortOV, slotShort.opacity)
    sample(slotTallHV, slotTall.height)
    sample(slotTallOV, slotTall.opacity)
    kv("glide.v.s4", glideTarget.v)
    kv("caps.scale.s4", capsOff.scale)
    kv("caps.opacity.s4", capsOff.opacity)
    kv("bar.fill.s4", barEmpty.children[0].width)
    kv("sweep.contentY.s4", sweepGrid.contentY)
    kv("slotShort.height.s4", slotShort.height)
    kv("slotShort.opacity.s4", slotShort.opacity)
  }

  function turn6() {
    sample(glideV, glideTarget.v)
    sample(capsScaleV, capsOff.scale)
    sample(capsOpacityV, capsOff.opacity)
    sample(barFillV, barEmpty.children[0].width)
    sample(sweepYV, sweepGrid.contentY)
    sample(gateHV, cardGate.height)
    sample(slotShortHV, slotShort.height)
    sample(slotShortOV, slotShort.opacity)
    sample(slotTallHV, slotTall.height)
    sample(slotTallOV, slotTall.opacity)
    kv("glide.v.s5", glideTarget.v)
    kv("caps.scale.s5", capsOff.scale)
    kv("bar.fill.s5", barEmpty.children[0].width)
    kv("sweep.contentY.s5", sweepGrid.contentY)
    kv("slotShort.height.s5", slotShort.height)
    kv("slotShort.height.shortOfTarget",
      slotShort.height < slotShort.children[0].height + slotShort.gap)
    kv("slotShort.opacity.s5", slotShort.opacity)
    // The two tweens have independent durations: the height rides slotMs
    // (floored at Ui.fastMs) and the opacity the fixed Ui.normalMs. So on a
    // short slot the unfold runs ahead of the fade, and on a tall one - where
    // slotMs is at the slowMs cap and therefore past normalMs - the fade runs
    // ahead of the unfold. That inversion is what the close grace window's
    // max(slotMs, normalMs) exists for.
    kv("slotShort.heightFraction.s5", slotShort.height / (slotShort.children[0].height + slotShort.gap))
    kv("slotTall.heightFraction.s5", slotTall.height / (slotTall.children[0].height + slotTall.gap))
    kv("slotShort.unfoldAheadOfFade",
      slotShort.height / (slotShort.children[0].height + slotShort.gap) > slotShort.opacity)
    kv("slotTall.fadeAheadOfUnfold",
      slotTall.height / (slotTall.children[0].height + slotTall.gap) < slotTall.opacity)
    kv("slotShort.bothInFlight",
      between(slotShort.height / (slotShort.children[0].height + slotShort.gap), 0, 1)
      && between(slotShort.opacity, 0, 1))
    kv("slotShort.nestedParent.isContentHost", slotShort.nestedItem.parent === slotShort.children[0])
    kv("slotShort.nestedX", slotShort.nestedItem.x)
    kv("slotShort.nestedW", slotShort.nestedItem.width)
    kv("slotTall.nestedW", slotTall.nestedItem.width)
    kv("slotShort.closeFinished", closeFinishedShort)
    kv("slotTall.closeFinished", closeFinishedTall)
    kv("confirm.stageText.staysArmed", textsIn(confirm)[0].text)
    kv("confirm.cancelHits.staysZero", cancelHits)
  }

  // ---- later turns: the settled values -------------------------------

  function turn8() {
    kv("trace.glide.samples", sampleCount(glideV))
    kv("trace.glide.rising", rising(glideV))
    kv("trace.glide.neverOvershot", allBelow(glideV, 100))
    kv("trace.glide.firstInFlight", firstBetween(glideV, 20, 45))
    kv("trace.capsScale.samples", sampleCount(capsScaleV))
    kv("trace.capsScale.rising", rising(capsScaleV))
    kv("trace.capsScale.neverOvershot", allBelow(capsScaleV, 1))
    kv("trace.capsScale.firstInFlight", firstBetween(capsScaleV, 0.9, 0.93))
    kv("trace.capsOpacity.samples", sampleCount(capsOpacityV))
    kv("trace.capsOpacity.rising", rising(capsOpacityV))
    kv("trace.capsOpacity.firstInFlight", firstBetween(capsOpacityV, 0.05, 0.16))
    kv("trace.barFill.samples", sampleCount(barFillV))
    kv("trace.barFill.rising", rising(barFillV))
    kv("trace.barFill.neverOvershot", allBelow(barFillV, 100))
    kv("trace.barFill.firstInFlight", firstBetween(barFillV, 15, 35))
    kv("trace.sweepY.samples", sampleCount(sweepYV))
    kv("trace.sweepY.rising", rising(sweepYV))
    kv("trace.sweepY.neverOvershot", allBelow(sweepYV, 120))
    kv("trace.sweepY.firstInFlight", firstBetween(sweepYV, 5, 16))
    kv("trace.slotShortH.samples", sampleCount(slotShortHV))
    kv("trace.slotShortH.rising", rising(slotShortHV))
    kv("trace.slotShortH.neverOvershot", allBelow(slotShortHV, 52))
    kv("trace.slotShortH.firstInFlight", firstBetween(slotShortHV, 12, 25))
    kv("trace.slotShortO.rising", rising(slotShortOV))
    kv("trace.slotShortO.firstInFlight", firstBetween(slotShortOV, 0.15, 0.35))
    kv("trace.slotTallH.rising", rising(slotTallHV))
    kv("trace.slotTallH.neverOvershot", allBelow(slotTallHV, 404))
    kv("trace.slotTallH.firstInFlight", firstBetween(slotTallHV, 40, 100))
    kv("trace.slotTallO.rising", rising(slotTallOV))
    kv("trace.slotTallO.firstInFlight", firstBetween(slotTallOV, 0.15, 0.35))
    kv("trace.gateH.samples", sampleCount(gateHV))
    kv("trace.gateH.moved", gateHV.length > 0 && gateHV[0] > cardGate.cardHeight)
    kv("trace.gateH.firstInFlight", gateHV.length > 0
      && between(gateHV[0], cardGate.cardHeight, gateStartH))
    kv("trace.gateH.neverOvershot", allBelow(gateHV, gateStartH))
    kv("trace.gateH.raw", gateHV.join(" "))
    kv("trace.glide.raw", glideV.join(" "))
    kv("trace.capsScale.raw", capsScaleV.join(" "))
    kv("trace.barFill.raw", barFillV.join(" "))
    kv("trace.sweepY.raw", sweepYV.join(" "))
    kv("trace.slotShortH.raw", slotShortHV.join(" "))
    kv("trace.slotTallH.raw", slotTallHV.join(" "))
    kv("caps.scale.s7", capsOff.scale)
    kv("caps.opacity.s7", capsOff.opacity)
    kv("bar.fill.s7", barEmpty.children[0].width)
    kv("sweep.contentY.s7", sweepGrid.contentY)
    kv("slotTall.height.s7", slotTall.height)
    kv("slotTall.opacity.s7", slotTall.opacity)
    kv("slotTall.heightFraction.s7", slotTall.height / (slotTall.children[0].height + slotTall.gap))
    kv("slotTall.fadeAheadOfUnfold.s7",
      slotTall.height / (slotTall.children[0].height + slotTall.gap) < slotTall.opacity)
    kv("slotTall.bothInFlight.s7",
      between(slotTall.height / (slotTall.children[0].height + slotTall.gap), 0, 1)
      && between(slotTall.opacity, 0, 1))
    kv("slotShort.height.s7", slotShort.height)
    kv("slotShort.opacity.s7", slotShort.opacity)
    kv("slotShort.heightFraction.s7", slotShort.height / (slotShort.children[0].height + slotShort.gap))
  }

  function turn12() {
    kv("glide.v.settled", glideTarget.v)
    kv("glide.landedOnTarget", glideTarget.v === 100)
    kv("glide.targetWhileSettled", glide.target === null ? "null" : "held")
    kv("slotShort.height.landed", slotShort.height)
    kv("slotShort.height.matchesTarget", feq(slotShort.height, slotShort.children[0].height + slotShort.gap))
    kv("slotShort.opacity.midFade", slotShort.opacity)
    // The fade's value on this turn is a frame-clock value - how far the
    // tween has run depends on when the turn landed - so the claim is the
    // shape of it: the fade has all but finished and has not quite
    // finished. The raw value is reported beside it, for a reader.
    kv("slotShort.opacity.midFadeNearlyOver", between(slotShort.opacity, 0.99, 1))
    kv("slotShort.fadeOutlivesHeight", slotShort.height === 52 && slotShort.opacity < 1)
    kv("slotTall.height.s11", slotTall.height)
    // Close the two cycle slots, one left to finish and one reopened inside
    // the grace window.
    slotCycle.open = false
    kv("cycle.closingAtClose", slotCycle.closing)
    kv("cycle.graceRunning", slotCycle.closeGrace.running)
    kv("cycle.nestedHeldDuringClose", slotCycle.nestedItem === null ? "null" : "obj")
    root.cycleBody = slotCycle.nestedItem
    slotReopen.open = false
    kv("reopen.closingAtClose", slotReopen.closing)
    root.reopenBody = slotReopen.nestedItem
    kv("reopen.nestedHeldDuringClose", slotReopen.nestedItem === null ? "null" : "obj")
  }

  function turn14() {
    slotReopen.open = true
    kv("reopen.closingCleared", slotReopen.closing)
    kv("reopen.graceStopped", slotReopen.closeGrace.running)
    kv("reopen.sameBodyInstance", slotReopen.nestedItem === root.reopenBody)
    kv("reopen.closeFinishedDuringGrace", closeFinishedReopen)
  }

  // ScrollBar position: the thumb's travel over the reachable range, and the
  // single-writer round trip.
  function turn16() {
    kv("bar.thumbY.atTop", thumbOf(barLong).y)
    kv("bar.thumbH.atTop", thumbOf(barLong).height)
    longFlick.contentY = 300
    kv("bar.thumbY.mid", thumbOf(barLong).y)
    kv("bar.shadow.mirrorsTarget", shadowOf(barLong).contentY)
    kv("bar.target.atMid", longFlick.contentY)
    kv("bar.write.roundTrip", writeBack(barLong, 300))
    kv("bar.write.shadowFollows", shadowOf(barLong).contentY)
    kv("bar.write.thumbY", thumbOf(barLong).y)
    // A position the target is NOT showing, arriving with no thumb pressed,
    // is the mirror or Qt's own clamp speaking - not a drag. Relaying it
    // is the loop that parked a scrolled list on its first row: the model
    // write dropped the view to the top, the shadow relayed that back, and
    // the relay was written through the list's one writer as though the
    // user had dragged the thumb there. The target keeps its own position.
    kv("bar.write.noDragKeeps", writeBack(barLong, 100))
    kv("bar.write.targetUnmoved", longFlick.contentY)
    // And the bar reports itself as nobody's to write for, which is what
    // makes the gate above a gate on the drag rather than on the number.
    kv("bar.write.notDriving", barLong._thumbDriving)
    longFlick.contentY = 600
    kv("bar.thumbY.atBottom", thumbOf(barLong).y)
    kv("bar.thumbY.atBottomExpected", barLong.height - thumbOf(barLong).height)
    kv("bar.thumbY.atBottom.isExpected", feq(thumbOf(barLong).y, barLong.height - thumbOf(barLong).height))
    kv("bar.thumbH.atBottom", thumbOf(barLong).height)
    kv("bar.thumbBottomAtBottom", feq(thumbOf(barLong).y + thumbOf(barLong).height, barLong.height))
    kv("bar.thumbNeverExceedsTrack",
      thumbOf(barLong).y >= 0 && thumbOf(barLong).y + thumbOf(barLong).height <= barLong.height)
    kv("bar.fat.thumbH.fillsTrack", thumbOf(barFat).height)
    kv("bar.fat.thumbNeverExceeds", thumbOf(barFat).height <= barFat.height)
    kv("bar.fat.minimumSizeIsClamped", controlOf(barFat).minimumSize === 1)
    kv("bar.shadow.contentHeightMirrors", shadowOf(barLong).contentHeight)
    kv("bar.short.minimumSize", controlOf(barShort).minimumSize)
  }

  // PanelCard's width pass: called only now, once the font metrics have
  // settled, because at boot the same label measures 62px narrower.
  function turn20() {
    cardRows.recalcWidth()
    cardNoLabels.recalcWidth()
    kv("pc.width.labelWidth", labelMetrics.width)
    kv("pc.capMetrics.height", capMetrics.height)
    kv("pc.subMetrics.height", subMetrics.height)
    kv("pc.rowRest.plainSettled", cardRows.rowRestHeight({ label: "x" }))
    kv("pc.rowRest.plainExpectedSettled", Math.max(Ui.rowMinH,
      realLabelLine.implicitHeight + 2 * Ui.rowPadV))
    kv("pc.rowRest.plainMatchesSettled", feq(cardRows.rowRestHeight({ label: "x" }),
      Math.max(Ui.rowMinH, realLabelLine.implicitHeight + 2 * Ui.rowPadV)))
    kv("pc.rowRest.subSettled", cardRows.rowRestHeight({ label: "x", sub: "y" }))
    kv("pc.rowRest.subExpectedSettled",
      Math.max(Ui.rowMinH, realLabelLine.implicitHeight + 1 + realSubLine.implicitHeight
        + 2 * Ui.rowPadV))
    kv("pc.rowRest.subMatchesSettled", feq(cardRows.rowRestHeight({ label: "x", sub: "y" }),
      Math.max(Ui.rowMinH, realLabelLine.implicitHeight + 1 + realSubLine.implicitHeight
        + 2 * Ui.rowPadV)))
    // Well past Ui.resizeMs: the escape-driven tween has landed, and it landed
    // on the binding's value rather than short of it.
    kv("pc.gate.landedOnTarget", feq(cardGate.height, cardGate.cardHeight))
  }

  function turn24() {
    kv("pc.contentW.longLabel", cardRows.contentW)
    kv("pc.contentW.expected", Math.max(cardRows.baseWidth,
      Math.min(labelMetrics.width, cardRows._maxLabelW)
      + 2 * Ui.m + cardRows.outerPad * 2 + 10))
    kv("pc.contentW.noLabels", cardNoLabels.contentW)
    kv("pc.contentW.noLabelsIsBase", feq(cardNoLabels.contentW, cardNoLabels.baseWidth))
    kv("pc.width.cappedByParent", cardRows.width)
    kv("pc.width.cap", cardRows.parent.width - 64)
    kv("pc.width.matchesFormula",
      feq(cardRows.width, Math.min(Math.max(cardRows.contentW, cardRows.baseWidth), cardRows.parent.width - 64)))
    kv("pc.slot.height", cardSlot.height)
    kv("pc.slot.heightMatchesCardHeight", feq(cardSlot.height, cardSlot.cardHeight))
    kv("pc.rows.heightLater", cardRows.height)
    kv("pc.rows.heightMatchesCardHeight", feq(cardRows.height, cardRows.cardHeight))
    kv("bar.fill.s23", barEmpty.children[0].width)
    kv("slotTall.height.s23", slotTall.height)
    kv("slotTall.height.matchesTarget", feq(slotTall.height, slotTall.children[0].height + slotTall.gap))
  }

  function turn30() {
    kv("pc.gate.shown", cardPlain.shown)
    kv("glide.target.released", glide.target === null)
    kv("glide.v.final", glideTarget.v)
    kv("caps.scale.final", capsOff.scale)
    kv("caps.opacity.final", capsOff.opacity)
    kv("bar.fill.final", barEmpty.children[0].width)
    kv("bar.fill.matchesTarget", feq(barEmpty.children[0].width, barEmpty.width * barEmpty.ratio))
    kv("bar.otherUnaffected", barHalf.children[0].width)
    kv("slotShort.opacity.settled", slotShort.opacity)
    kv("cycle.closing", slotCycle.closing)
    kv("cycle.height", slotCycle.height)
    kv("cycle.closeFinished", closeFinishedCycle)
    kv("cycle.nestedReleased", slotCycle.nestedItem === null ? "null" : "held")
    kv("cycle.closeFinishedShort", closeFinishedShort)
    kv("reopen.closeFinished", closeFinishedReopen)
    kv("reopen.stillHoldingBody", slotReopen.nestedItem === root.reopenBody)
    kv("reopen.height", slotReopen.height)
    kv("slotIdle.neverArmed", slotIdle.closing)
    kv("icon.ready.plainLater", icPlain.ready)
    kv("icon.ready.twoTone", icTwo.ready)
    kv("icon.ready.notActive", icNotActive.ready)
    kv("icon.ready.unknown", icUnknown.ready)
    kv("icon.state.unknownNotReadyLater", icUnknown.ready)
    kv("icon.state.unknownStatusLater", baseOf(icUnknown).status)
    kv("icon.state.plainSlotUnaffectedByBig", icPlain.slotSize === icBig.slotSize)
    kv("icon.state.plainImplicitUnaffected", icPlain.implicitWidth)
    kv("body.implicitHeight.empty", btEmpty.implicitHeight)
    kv("body.lineCount.empty", btEmpty.lineCount)
    kv("body.stack.lineCount", btStack.lineCount)
    kv("body.stack.implicitHeight", btStack.implicitHeight)
    kv("body.stack.heightIsLinesTimesLineHeight", feq(btStack.implicitHeight, btStack.lineCount * 15))
    kv("body.stack.height", btStack.height)
    kv("body.stack.lineCountExpected", 4)
    kv("focus.probe.afterField", JSON.stringify(focusField.probe()))
    kv("focus.probe.mode", focusField.probe().mode)
    kv("confirm.confirmedHits", confirmHits)
    kv("confirm.cancelledHits", cancelHits)
    kv("zebra.clicks.final", zebraClicks)
  }

  function turn48() {
    kv("sweep.contentY.settled", sweepGrid.contentY)
    kv("sweep.landedOnTarget", feq(sweepGrid.contentY, sweepGrid.sweepTo))
    kv("sweep.target", sweepGrid.sweepTo)
    kv("sweep.neverOvershot", sweepGrid.contentY <= sweepGrid.sweepTo)
    kv("cancel.contentY.final", cancelGrid.contentY)
    kv("cancel.neverMoved", cancelGrid.contentY === 0)
  }

  function finish() {
    kv("probe.completed", true)
    console.log("##DONE##")
  }
}
