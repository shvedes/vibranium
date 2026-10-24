pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import qs.common
import "ColorMath.js" as ColorMath

// The history list half of the color picker island: a five-row viewport
// over the full stored history with a scrollbar in a dedicated right
// gutter (so it never draws over the action buttons). Each row paints
// the parsed color and picks its foreground with the integer contrast
// formula; copy and delete are always visible, both with hover
// fills (accent for copy, theme red for delete). The copy button copies
// through the island (closing it only after the copy command settled)
// and the delete button drops the record. Split out of the island so
// the unique picker controls below stay plain children of the card.
//
// This is a VIEW over the module's store, and the store owns the history
// lifecycle (add, evict, remove, clear, the startup read and the parse
// failure). What is left here is what the list actually renders.
Item {
  id: root

  // Full history, newest first. Rows show rec.color + rec.alpha and copy
  // through the island's copyColor(rec); entry shape is the shared
  // { color, alpha, timestamp } record.
  property var records: []

  // Normalized "#rrggbb(alpha)" key of the record currently flashing as
  // copied (owned by the island); empty when no copy is in flight.
  property string copiedKey: ""

  // Fired after a copy command has been accepted (the process actually
  // started); the island closes itself here, never on a mere click.
  signal copyRequested(var rec)

  // Fired when the row's delete button is pressed; the island forwards
  // to the module, which owns the store.
  signal deleteRequested(var rec)

  // Row geometry from the UI tokens; the viewport shows exactly five
  // rows and hides the rest under the scrollbar. The height is fixed
  // regardless of content so the island never resizes; the empty state
  // paints a dimmed theme glyph dead center instead.
  readonly property real rowHeight: 28
  readonly property int visibleRows: 5

  // Row array behind the display model: one `{ key, m }` record per
  // colour, keyed by the module's dedupe identity and holding the store's
  // record by reference so a payload is never re-wrapped.
  property var _rows: []

  // Display model: a ScriptModel over `_rows`. Reassigning `values` diffs
  // the row set inside the model instead of resetting it, so a delete and
  // the front-promotion of a re-copy reach the view as remove/move and
  // `displaced` animates the survivors - assigning a fresh model object
  // would reset the view, recreate every delegate and skip transitions.
  // Keys are the module's dedupe identity plus the display format, so the
  // same color copied as hex and as hsl shows as two rows, each in its own
  // format.
  ScriptModel {
    id: displayModel
    values: root._rows
    objectProp: "key"
    // Identity compares the payload by reference, which is what carrying
    // the store's record by reference assumes; the default Structure
    // would compare it by content.
    comparisonMode: ObjectComparison.Identity
  }

  // Identity epoch for the list's height table. The table keys a measured
  // height by row identity, and a row set that swaps identities in place -
  // same count, same first and last identity - is invisible to the count
  // and the endpoints, so the epoch is the only term that sees it. It is a
  // counter rather than the key sequence itself because a sequence returns
  // to an earlier value when rows are reordered back, and the epoch must
  // never repeat an earlier value. `_syncModel` is what advances it.
  property int _epoch: 0
  property var _lastSeq: ""
  readonly property int identityRevision: root._epoch

  // Key on the module's dedupe identity plus the display format;
  // delegated to ColorMath so store and display never disagree.
  function _keyOf(rec) {
    return ColorMath.recordKey(rec)
  }

  // The swatch checkerboard, as an inline SVG tiled across a swatch: a
  // 2x2 cell checkerboard in cell units, so the tile covers 2 columns and
  // 2 rows and the repeat lands on the grid's own 16 x 2 layout at the
  // cell size the caller asks for through sourceSize. A data URL keeps
  // this inside the module - the pattern is two fixed palette tones
  // rather than a recolored glyph, so Icons.url would add a cache and a
  // recolor pass for nothing. Every row asks for the same tile, so the
  // image cache decodes it once for the whole viewport.
  //
  // The two tones are the grid's: an opaque background_2 cell and a
  // foreground_1 cell at the grid's 0.25 alpha, drawn as fill-opacity
  // over that base, so the blend is the same source-over compositing the
  // grid's alpha-over-base cells did and the swatch's Qt.rgba fill on top
  // lands on an identical backdrop. "" while a palette key is unresolved,
  // leaving the swatch's own base as a flat fill.
  function _checkerUrl() {
    const base = String(Theme.color("background_2") || "")
    const ink = String(Theme.color("foreground_1") || "")
    if (base === "" || ink === "") return ""
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2 2">'
      + '<rect width="2" height="2" fill="' + base + '"/>'
      + '<path fill="' + ink + '" fill-opacity="0.25"'
      + ' d="M0 0h1v1H0zM1 1h1v1H1z"/></svg>'
    return "data:image/svg+xml;utf8," + encodeURIComponent(svg)
  }

  // Rebuild the keyed row set. Records are carried by reference by the
  // module (an add keeps every surviving record's identity), so the model
  // sees a promotion as a move plus a set for the one new record, and a
  // delete as a plain remove - the same diff the hand-rolled walk did.
  // `values` is the model's only write and it refuses nothing, so there is
  // no rejected row set to fall back from: the write either lands or the
  // array it was handed was not an array.
  function _syncModel() {
    const rows = []
    const seen = {}
    for (let i = 0; i < root.records.length; i++) {
      const rec = root.records[i]
      const k = root._keyOf(rec)
      if (seen[k]) continue
      seen[k] = true
      rows.push({ key: k, m: rec })
    }
    root._rows = rows
    // Identity epoch: the key sequence decides whether the row set swapped
    // identities, and the counter carries that into the list's height
    // table. Monotone by construction, so reordering back to an earlier
    // sequence cannot repeat an epoch the table has already seen.
    const seq = rows.map(r => r.key).join("\u0000")
    if (seq !== root._lastSeq) {
      root._lastSeq = seq
      root._epoch++
    }
  }

  onRecordsChanged: root._syncModel()
  Component.onCompleted: root._syncModel()

  readonly property real viewportHeight: root.visibleRows * root.rowHeight
  // Right gutter reserved for the scrollbar; rows never paint into it.
  readonly property real scrollGutter: 10

  implicitHeight: root.viewportHeight
  clip: true

  // Empty state: dimmed theme glyph + hint, dead center. Fixed height
  // keeps the island static when this shows.
  Column {
    anchors.centerIn: parent
    visible: root.records.length === 0
    spacing: Ui.s
    opacity: 0.5

    Icon {
      anchors.horizontalCenter: parent.horizontalCenter
      name: "theme"
      colorKey: "foreground_1"
      size: 32
    }

    Title {
      anchors.horizontalCenter: parent.horizontalCenter
      level: 5
      text: "Recent picks will appear here"
    }
  }

  List {
    id: list

    selectionHighlight: false
    anchors.fill: parent
    anchors.rightMargin: root.scrollGutter
    model: displayModel
    // Height table keyed by row identity. A delete and a re-copy's
    // front-promotion both move surviving rows, so index keys would hand a
    // measured height to whichever record slid into that slot. The key is
    // the record's dedupe identity plus its display format - the `key` the
    // row carries, and the `seen` guard in `_syncModel` is what makes it
    // unique. `?? index` is what keeps a row renderable when a record
    // carries no key at all.
    rowIdentity: index => String(displayModel.values[index]?.key ?? index)
    identityRevision: root.identityRevision
    spacing: 0
    interactive: contentHeight > height
    delegate: rowDelegate

    // Survivors glide into the freed slot after a delete - the same
    // reflow the clipboard/notifications lists use, gated by the global
    // animation switch.
    displaced: Transition {
      NumberAnimation {
        property: "y"
        duration: MotionPolicy.enabled ? Ui.normalMs : 0
        easing.type: Easing.OutCubic
      }
    }
  }

  ScrollBar {
    flickable: list
    anchors.right: parent.right
    anchors.top: list.top
    anchors.bottom: list.bottom
    anchors.rightMargin: 1
    thickness: 3
    radius: RoundingPolicy.radius
  }

  Component {
    id: rowDelegate

    Item {
      id: row

      // A ScriptModel exposes one role, `modelData`, holding the whole
      // row record - the record itself rides in `modelData.m` and its
      // dedupe identity in `modelData.key`. The delegate reads the record
      // directly and never scans `records` to find it.
      required property var modelData
      required property int index

      // Defensive: a torn row paints nothing and never reaches the
      // clipboard.
      readonly property var rec: row.modelData ? row.modelData.m : null
      readonly property string hex: row.rec ? String(row.rec.color || "") : ""
      readonly property var parsed: ColorMath.parse(row.hex)
      readonly property real alpha: row.rec && typeof row.rec.alpha === "number"
        ? ColorMath.clampAlpha(row.rec.alpha) : 1
      readonly property string fg: ColorMath.contrastText(row.parsed)
      readonly property string recKey: row.parsed !== null
        ? ColorMath.hex8(row.parsed, row.alpha) : ""
      readonly property bool copied: root.copiedKey !== ""
        && root.copiedKey === row.recKey
      // The entry shows the format it was stored in - a color copied as
      // HSL stays HSL. hex8 is the fallback for records without a
      // stored snapshot.
      readonly property string dispText: {
        if (row.parsed === null) return "(invalid)"
        const f = row.rec && row.rec.formats ? row.rec.formats : null
        const fmt = row.rec && typeof row.rec.fmt === "string"
          ? row.rec.fmt : "hex"
        if (f !== null && typeof f[fmt] === "string" && f[fmt] !== "") return f[fmt]
        return ColorMath.hex8(row.parsed, row.alpha)
      }

      width: ListView.view ? ListView.view.width : 200
      height: root.rowHeight

      // Swatch: checkerboard behind the stored color. Qt.rgba with
      // alpha < 1 composites against the checker, not the card
      // background, so translucent picks are recognizable. The checker
      // mirrors the preview box pattern: an opaque background_2 base
      // with a foreground_1 0.25 / base checker, then the Qt.rgba fill
      // on top. Laid out for a 28px row: 16 cols x 2 rows over
      // ~256px x 26px => ~16px x 13px cells, close to the preview's
      // 12px squares (48px / 4). QML color properties reject CSS rgba()
      // strings (they render black), so the overlay stays Qt.rgba.
      Rectangle {
        id: swatch

        anchors.left: parent.left
        anchors.right: actionsRow.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.rightMargin: Ui.s
        anchors.topMargin: 1
        anchors.bottomMargin: 1
        color: Ui.solid("background_2")
        clip: true

        // Checkerboard behind the color fill: one tiled image, not a grid
        // of cells per row. The tile is a 2x2 checkerboard in cell units
        // and Image.Tile repeats it from the item's top-left corner, so
        // sourceSize below is what puts the 16 columns x 2 rows and their
        // w/16 x h/2 cells back. See _checkerUrl().
        Image {
          anchors.fill: parent
          fillMode: Image.Tile
          smooth: false
          source: root._checkerUrl()
          // Tile size in device-independent pixels: two cells across, one
          // pair of rows down, so the repeat is the grid's own 16 x 2.
          // The item's DPR scales the raster, so the cell edges stay
          // hard on a scaled output instead of being resampled.
          sourceSize: Qt.size(Math.max(1, Math.round(swatch.width / 8)),
            Math.max(1, Math.round(swatch.height)))
        }

        // Color fill with the stored alpha; fully transparent when the
        // record is malformed so the checker shows through.
        Rectangle {
          anchors.fill: parent
          color: row.parsed !== null
            ? Qt.rgba(row.parsed.r, row.parsed.g, row.parsed.b, row.alpha)
            : "transparent"
        }

        Title {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Ui.s
          text: row.dispText
          color: row.parsed !== null ? row.fg : Ui.tint("foreground_1", 0.5)
          level: 3
          font.family: Ui.fontFamily
        }
      }

      // Row actions: copy and delete, both always visible with hover
      // fills - accent for copy, theme red for delete. Two fixed slots
      // keep the swatch geometry stable.
      Row {
        id: actionsRow

        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2

        IconButton {
          id: copyBtn
          animationsEnabled: MotionPolicy.enabled

          // The pointer cursor, without an area laid over the button. A
          // MouseArea over the native button takes the press with it: the
          // press lands on the area, is not accepted, and travels up the
          // item chain - the button underneath is a sibling of the area,
          // not an ancestor, so it never sees the click. A hover handler
          // sets the cursor and leaves the press alone.
          HoverHandler {
            cursorShape: Qt.PointingHandCursor
          }

          anchors.verticalCenter: parent.verticalCenter
          name: "copy"
          colorKey: row.copied ? "accent" : "foreground_0"
          // Same height as the swatch (rowHeight minus its 2x1 margins)
          // so the actions read as full-height row chrome; width grows
          // with it to keep the buttons square.
          width: root.rowHeight - 2
          height: root.rowHeight - 2
          color: row.copied ? Ui.tint("accent", 0.15)
            : copyBtn.pressed ? Ui.tint("accent", 0.2)
            : copyBtn.hovered ? Ui.tint("accent", 0.1) : "transparent"
          onClicked: {
            if (row.rec) root.copyRequested(row.rec)
          }
        }

        IconButton {
          id: deleteBtn
          animationsEnabled: MotionPolicy.enabled

          // The same cursor without the area over the button; see the
          // copy button above for why.
          HoverHandler {
            cursorShape: Qt.PointingHandCursor
          }

          anchors.verticalCenter: parent.verticalCenter
          name: "remove"
          colorKey: "red"
          // Same height as the swatch (rowHeight minus its 2x1 margins)
          // so the actions read as full-height row chrome; width grows
          // with it to keep the buttons square.
          width: root.rowHeight - 2
          height: root.rowHeight - 2
          color: deleteBtn.pressed ? Ui.tint("red", 0.28)
            : deleteBtn.hovered ? Ui.tint("red", 0.14) : "transparent"
          onClicked: {
            if (row.rec) root.deleteRequested(row.rec)
          }
        }
      }

      MouseArea {
        id: rowArea

        anchors.fill: swatch
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          if (row.rec) root.copyRequested(row.rec)
        }
      }
    }
  }
}
