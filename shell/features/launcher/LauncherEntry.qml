pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import qs.features.menu
import "LauncherLib.js" as LauncherLib

// One launcher result row. Visual twin of menu/Entry's plain-action look -
// instant selection fill, 16px icon, label + optional sub - because the
// launcher must read as the same family of surfaces. Only the row shapes
// differ: no toggles or steppers live here.
//
// The ctrl-I description slot is a port of Entry's: hairline over a body
// text block that eases open under the row and scrolls under the list
// region. Open/close state is owned by the panel (one open at a time).
// mainLine stays top-pinned like Entry so open slots grow downward and the
// label never sinks.
Item {
  id: row

  // The record rides whole in the one role a ScriptModel exposes,
  // `modelData`: under it this IS the row record, not a context object
  // wrapping one, so the body reads modelData.<field> and there is no second
  // role to unwrap.
  required property var modelData
  required property int index

  property bool infoOpen: false

  readonly property string descText: String(modelData?.desc ?? "")
  readonly property string subText: modelData ? String(modelData.sub ?? "") : ""
  // Separator rows (clipboard-suggestion divider) collapse to a slim
  // centered hairline - menu-family look, but slimmer than the menu's.
  readonly property bool isSep: modelData ? String(modelData.kind ?? "") === "separator" : false
  readonly property string iconSource: {
    const name = modelData ? String(modelData.icon ?? "") : ""
    return name !== "" ? Menu.resolveAppIcon(name) : ""
  }

  // A color row paints the color instead of naming an icon: the engine has six
  // readings of ONE color, and a palette glyph would label all six identically
  // without ever showing which color they are. `swatch` fills the dot and
  // `swatchEdge` is the border that keeps it readable on any theme - the engine
  // ships both, so the luminance rule behind the choice stays in the color
  // library rather than in a row that only reads a string.
  // A half-typed code (kind "color" + incomplete) has no color to paint yet,
  // so the dot paints the picker's own hue wheel instead - the rainbow swept
  // around the center, the same stops as the ColorPicker hue slider - as the
  // "keep typing" state.
  readonly property string swatchFill: modelData ? String(modelData.swatch ?? "") : ""
  readonly property string swatchEdge: modelData ? String(modelData.swatchEdge ?? "") : ""
  readonly property bool isColorHint: modelData
    ? String(modelData.kind ?? "") === "color" && modelData.incomplete === true : false

  // Row icon geometry: the painted square the glyph occupies. The badge
  // beside it is 16 (Icon's own size override), so this is the only place
  // the row's leading icon is dimensioned.
  readonly property real iconSize: 20

  // The launcher's own window DPR. Quickshell's PanelWindow reports the
  // scale factor of the screen the window is on and re-emits when it
  // changes, so a scale switch re-rasterizes the row icons below instead
  // of stretching whatever texture was decoded at the previous factor.
  readonly property real _dpr: {
    const w = Window.window
    const dpr = w ? w.devicePixelRatio : 0
    return typeof dpr === "number" && isFinite(dpr) && dpr > 0 ? dpr : 1
  }

  // Sub-line metrics for the resting line height below (fontXs). Native
  // Text.elide truncates the sub line -> no advanceWidth measuring here.
  FontMetrics {
    id: clipFontMetrics
    font.pixelSize: Ui.fontXs
    font.family: Ui.fontFamily
  }
  // Right-side managed-entry marker ("webapp" | "tui"), recolored from
  // the shell's own assets/icons set - dimmed to trail-chrome prominence.
  readonly property string badgeName: modelData ? String(modelData.badge ?? "") : ""

  // Live line metrics for the resting line heights below. clipFontMetrics
  // already measures the sub size; the title needs its own (fontL).
  FontMetrics {
    id: titleFontMetrics
    font.pixelSize: Ui.fontL
    font.family: Ui.fontFamily
  }

  // Resting line heights from the RECORD (sub presence) and the font
  // metrics, rounded up to the Text line box. A newborn delegate has not
  // polished yet, so its Texts report no implicit height and a
  // Text-driven column measures 0; the row then grew by a couple of
  // pixels right after every rebuild. That growth is two symptoms at
  // once: the selection bar tracks the cursor row's height, so it jumped
  // on every keystroke, and a list fit latched inside that window kept
  // the card's region short by the same amount for the rest of the
  // session - a two-row result list rendered ~7px shorter than its
  // content, which made the viewport scrollable and left the second row
  // clipped.
  // These are the column's FLOOR, not its height: labelCol still grows to
  // the real line box at rest, so a font whose Text box exceeds the metric
  // is never clipped.
  readonly property real titleLineH: Math.ceil(titleFontMetrics.height)
  readonly property real subLineH: Math.ceil(clipFontMetrics.height)
  readonly property real linesH: titleLineH
    + (row.subText !== "" ? 1 + subLineH : 0)

  // Ids can resolve to null while a delegate is being torn down and its
  // bindings re-evaluate once more - guard instead of throwing.
  readonly property real descSlotH: descSlot ? descSlot.height : 0
  readonly property real deleteSlotH: deleteSlot ? deleteSlot.height : 0
  readonly property real slotMotionMs: Math.max(
    descSlot && (descSlot.open || descSlot.closing) ? descSlot.slotMs : 0,
    deleteSlot && (deleteSlot.open || deleteSlot.closing) ? deleteSlot.slotMs : 0)

  signal activated()
  signal deleteConfirm()

  width: ListView.view ? ListView.view.width : 240
  // The row tracks each slot's height animation 1:1 - every slot owns its
  // top padding inside its own height (DropdownSlot.topGap), so the sum is
  // the whole unfolded geometry with no extra margin to snap. Delete stacks
  // under desc with no top gap of its own.
  // Separator rows collapse to a centered hairline with generous
  // breathing room (the menu's separator row is 10px); no slots, no
  // chrome. Otherwise the row never reports below the rowMinH floor -
  // mainLine is the label column, which owns its own resting height (see
  // linesH), so this is the same number at delegate birth and at rest, and
  // only open slots grow past it.
  height: isSep ? 12
    : Math.max(Ui.rowMinH,
        mainLine.height + 2 * Ui.rowPadV)      + descSlotH + deleteSlotH


  Rectangle {
    id: bg

    anchors.fill: parent
    // Always transparent: the List sliding highlight bar paints the
    // selection behind the rows (see common/ui/List). Same as menu Entry.
    visible: !row.isSep
    color: "transparent"
  }

  // Separator rows: centered hairline with the menu's side insets.
  Divider {
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Ui.m + 2
    anchors.rightMargin: Ui.m + 2
    visible: row.isSep
  }

  MouseArea {
    id: clickArea

    anchors.fill: parent
    enabled: !row.isSep
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: mouse => {
      if (mouse.button === Qt.RightButton) {
        AppLauncher.close()
        return
      }
      const view = row.ListView.view
      if (view && view.currentIndex !== row.index) view.seat(row.index, "click")
      row.activated()
    }
  }

  Item {
    id: mainLine

    visible: !row.isSep
    anchors.left: parent.left
    anchors.right: parent.right
    // Top-pinned like menu/Entry: slots grow downward and the label never
    // sinks. Single-line rows ride ~2px high of dead-center; invisible, same
    // as the menu.
    anchors.top: parent.top
    anchors.topMargin: Ui.rowPadV
    anchors.leftMargin: Ui.m
    anchors.rightMargin: Ui.m
    height: labelCol.height

    // Leading slot: the resolved icon OR a fabricated dot, never both, and
    // nothing at all for the rows that carry neither. One item owns the
    // geometry, so the label column has a single left edge to anchor to
    // whichever of the two is painting.
    Item {
      id: leadSlot

      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: row.iconSize
      height: row.iconSize
      visible: row.iconSource !== "" || row.swatchFill !== "" || row.isColorHint

      // A resolved icon URL (Menu.resolveAppIcon: the shell's own themed
      // asset, else the platform path), not a shell asset name, so this is a
      // plain Image rather than the Icon primitive - Icon recolors and
      // resolves names, and an app or file icon must keep its own colors.
      //
      // Image (not IconImage) so sourceSize can be set: Qt rasterizes into
      // sourceSize pixels and then maps that texture onto the item's logical
      // size, so without it the icon decodes once at 1x and every later
      // display-scale change stretches a stale raster - visibly wrong on the
      // shell's own SVGs (the clipboard suggestion's "clipboard" glyph, a
      // path/folder glyph) while the rest of the shell re-rasterizes.
      // Rasterizing at iconSize * window DPR keeps every texel on a physical
      // pixel at any scale factor. IconImage has no sourceSize, the same
      // reason TrayItem.qml renders through Image.
      Image {
        id: iconImg

        visible: row.iconSource !== ""
        anchors.fill: parent
        source: row.iconSource
        fillMode: Image.PreserveAspectFit
        smooth: true
        // Async on purpose: the idle list builds ~54 delegates at open and the
        // panel patches rows in place, so a synchronous decode of a platform
        // PNG per row would stall the open frame.
        asynchronous: true
        // ...but the last raster stays painted through a reload. A display
        // scale change flips sourceSize on every row at once, and without
        // this the whole wall blanks while it re-rasterizes and refills frame
        // by frame - the one thing the bar never does, because Icon.qml
        // decodes synchronously and gets the same guarantee this line buys
        // here (see common/ui/Icon.qml and NowPlayingIsland's art image).
        retainWhileLoading: true
        sourceSize: Qt.size(Math.ceil(row.iconSize * row._dpr), Math.ceil(row.iconSize * row._dpr))
      }

      // The dot, at the icon's own size so neither lead slot can shift the
      // label. The engine paints it opaque even for a translucent code: the
      // transparency lives in the rgba/hsla/hsva readings, and a see-through
      // dot on a themed surface reads as a broken theme rather than a color.
      Rectangle {
        id: swatchDot

        visible: row.swatchFill !== ""
        anchors.fill: parent
        radius: width / 2
        // "transparent" rather than "" for a row that carries no swatch: an
        // unparseable color is a runtime warning on every such row.
        color: row.swatchFill !== "" ? row.swatchFill : "transparent"
        border.width: 2
        border.color: row.swatchEdge !== "" ? row.swatchEdge : "transparent"
      }

      // The waiting state of the same dot: a half-typed code has no color
      // yet, so the circle paints the hue WHEEL - the picker's rainbow swept
      // around the center, red wrapping back to red - instead of staying
      // empty. A static Canvas paints it, deliberately not a shader: every
      // delegate is destroyed against the hidden layer surface when the
      // controller tears down after close, and per-delegate Qt5Compat
      // effects (a ConicalGradient + OpacityMask pair) take
      // that teardown down with them - deferred deletes landing in
      // QQuickItemPrivate::derefWindow on the torn-down surface (SIGSEGV on
      // every close). A Canvas holds no such scene-graph node.
      // Static art, so it paints once at 2x and never again: crisp on
      // fractional scales with no DPR binding and no repaint after birth.
      Canvas {
        visible: row.isColorHint
        anchors.fill: parent
        canvasSize: Qt.size(Math.max(1, width * 2), Math.max(1, height * 2))
        contextType: "2d"
        renderStrategy: Canvas.Immediate
        // A delegate born for another kind stays blank while hidden: an
        // invisible Canvas never paints, so a payload-in-place flip onto
        // the hint repaints instead of showing an empty disc.
        onVisibleChanged: if (visible) requestPaint()
        onPaint: {
          const ctx = getContext("2d")
          if (!ctx) return
          const w = ctx.canvas.width
          const h = ctx.canvas.height
          const cx = w / 2
          const cy = h / 2
          const r = Math.min(w, h) / 2
          const hues = ["#ff0000", "#ff8000", "#ffff00", "#80ff00",
                        "#00ff00", "#00ff80", "#00ffff", "#0080ff",
                        "#0000ff", "#8000ff", "#ff00ff", "#ff0080"]
          ctx.reset()
          ctx.clearRect(0, 0, w, h)
          for (let i = 0; i < hues.length; i++) {
            const a0 = (i / hues.length) * 2 * Math.PI
            const a1 = ((i + 1) / hues.length) * 2 * Math.PI
            ctx.beginPath()
            ctx.moveTo(cx, cy)
            ctx.arc(cx, cy, r, a0, a1)
            ctx.closePath()
            ctx.fillStyle = hues[i]
            ctx.fill()
          }
        }
        Component.onCompleted: requestPaint()
      }
    }

    // Managed-entry badge, mirroring the menu's right-side trail chrome
    // (chevrons/toggles). Pure indicator - no interaction; hidden when the
    // setting is off (empty source) or the entry is not managed.
    Icon {
      id: badgeImg

      visible: row.badgeName !== ""
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      size: 16
      name: row.badgeName
      colorKey: "foreground_1"
      opacity: 0.7
    }

    Column {
      id: labelCol

      // The column's resting height, from the record and the font metrics
      // (see linesH), so it reads the same before and after the delegate
      // polishes. implicitHeight is kept as the floor's other side: it is
      // the live line box, 0 until the polish, and it stays the authority
      // for a font whose metrics understate it.
      height: Math.max(implicitHeight, row.linesH)
      anchors.left: leadSlot.visible ? leadSlot.right : parent.left
      anchors.leftMargin: leadSlot.visible ? 8 : 0
      anchors.right: badgeImg.visible ? badgeImg.left : parent.right
      anchors.rightMargin: badgeImg.visible ? 6 : 10
      anchors.verticalCenter: parent.verticalCenter
      spacing: 1

      // Title row: the row label.
      // Hiding via `visible` alone (no explicit height): the Column's
      // implicit height already skips invisible children, and binding
      // height to implicitHeight on a Text self-loops.
      Text {
        width: parent.width
        text: row.modelData ? String(row.modelData.label ?? "") : ""
        color: Ui.tint("foreground_0", 1)
        font.pixelSize: Ui.fontL
        font.family: Ui.fontFamily
        // Plain rows must never shape: the system font is often a
        // programming face whose `calt`/`liga` turns `->` into an arrow.
        // A launcher row shows literal text, so freeze the glyphs.
        font.features: ({ "calt": 0, "liga": 0, "clig": 0, "dlig": 0, "hlig": 0 })
        // Middle-elide for the engines whose label is a whole equation
        // wrapped around a value ("100 USD = 87.84 EUR"): the ends carry
        // the operands, and either end alone is unreadable.
        elide: (row.modelData && (row.modelData.kind === "calc" || row.modelData.kind === "unit" || row.modelData.kind === "fx")) ? Text.ElideMiddle : Text.ElideRight
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        // Subtitle ownership lives in the row data: the service decides
        // what (if anything) the sub line shows - an app description in
        // inline mode, its placeholder for apps without one, or nothing
        // at all when descriptions are off. Rows with no sub collapse to
        // a single title line; positioners skip invisible children, so
        // the height simply folds away.
        visible: row.subText !== ""
        text: row.subText
        // Alert rows (an offline fx row) paint the sub red. PlainText by
        // design, so the color rides a row flag rather than markup in the
        // string - a description must never inject its own styling.
        color: (row.modelData && row.modelData.alert === true) ? Theme.color("red") : Ui.tint("foreground_1", 0.55)
        font.pixelSize: Ui.fontXs
        font.family: Ui.fontFamily
        // Same ligature freeze as the title: `->` in a row must read as
        // two characters, never as the font's arrow substitute.
        font.features: ({ "calt": 0, "liga": 0, "clig": 0, "dlig": 0, "hlig": 0 })
        // Calc sub is "Copy <large> to clipboard", fx and unit sub are the
        // conversion as a sentence ("100 US Dollars is 2,543,000.00 Vietnamese
        // Dong") - middle-elide keeps the source and the tail of a very long
        // amount on screen, which are the two ends a reader needs.
        // Clipboard suggestions elide natively: Text.ElideRight on this same
        // Text, so ElideNone becomes ElideRight and text reads subText direct.
        // Truncation stays right-anchored on one line and ends in the font
        // ellipsis.
        elide: ((row.modelData && (row.modelData.kind === "calc" || row.modelData.kind === "unit" || row.modelData.kind === "fx") && !row.modelData.incomplete) ? Text.ElideMiddle : Text.ElideRight)
        wrapMode: Text.NoWrap
        textFormat: Text.PlainText
      }
    }
  }

  // --- ctrl+i description dropdown ---
  // Port of Entry's slot: eases under the row line, hairline first, and
  // claims in-flow height so the card grows to fit (see LauncherPanel).
  DropdownSlot {
    id: descSlot

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: mainLine.bottom
    topGap: Ui.m
    open: row.infoOpen && row.descText !== ""

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
        markup: true
        text: LauncherLib.styledMarkup(row.descText)
      }
    }
  }

  // Delete confirmation: three-step flow (hint -> armed -> confirm).
  // Stage 1: hint text + outlined Delete button.
  // Stage 2: button fills red (armed), key/click confirms.
  property bool deleteOpen: false
  property int deleteStage: 0

  ConfirmSlot {
    id: deleteSlot

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: descSlot.bottom
    // Stacked below descSlot: no top gap while desc is live (open or
    // easing shut) since that slot already ends in its own gap, but the
    // full top padding when desc is shut - otherwise a delete opened alone
    // touches the row line with no breathing room. The switch rides the
    // height tween, so the rare toggle-desc-while-delete-open case glides
    // instead of snapping.
    topGap: (descSlot.open || descSlot.closing) ? 0 : Ui.m
    open: row.deleteOpen
    gap: Ui.m
    stage: row.deleteStage
    hintText: "Press Delete to remove this app"
    armedText: "<b><u>Press again to confirm deletion</u></b>"
    onConfirmed: row.deleteConfirm()
  }
}
