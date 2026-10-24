pragma ComponentBehavior: Bound
// qmllint disable uncreatable-type
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.common

// ToolTipHost: the single shared tooltip window per BarView (per screen).
// Modules stop owning tooltip windows; a tiny ToolTipBind per module
// keeps the same bindings and pushes snapshots here. The host owns the
// window, the bubble chrome, measuring, positioning, the hover delay and
// drag cancellation. Only one tooltip is ever visible per screen
// (exclusive by construction).
//
// Built on a full-screen PanelWindow (layer-shell) rather than a
// PopupWindow: xdg_popup cannot attach to a layer surface, so a popup
// anchored to the bar dies with a fatal Wayland protocol error. Instead
// the host is a transparent overlay on the bar's screen with the bubble
// parked at a fixed spot relative to the served module - it cannot move
// freely, but it never takes focus or input (empty mask region).
//
// Requests: declarative ToolTipBind objects push snapshots
// {anchor, barWindow, text, lines, markup, maxWidth} on every relevant
// change; the tray pushes imperatively through show/hide/cancel. Highest
// activation serial wins. Hidden always pays the hover delay; a winner
// change while shown swaps instantly with no re-delay.
PanelWindow {
  id: root

  // Where the bar sits: "top" parks the bubble below it, "bottom" above.
  property string barPosition: "top"
  // Gap between the bar edge and the bubble (the spacing token).
  property int gap: 6
  // Hover delay: a newly served request shows only after the cursor has
  // rested this long. Shared by all requests; no consumer overrides it.
  property int delay: 300
  property bool _show: false

  // The served snapshot {bind, rev, anchor, barWindow, text, lines,
  // markup, maxWidth}, or null while nothing is served.
  property var _req: null
  // Active snapshots, at most one per bind plus the "tray" token.
  property var _reqs: []
  // The bind token the delay was last armed for. The delay restarts only
  // when the winner changes, never on snapshot updates, or a live text
  // feed (battery, weather) would hold the timer shut while pending.
  property var _winner: null
  // Activation serial; highest rev wins.
  property int _rev: 0

  // Bumped on every row add/remove so the measures below re-run. They
  // intentionally do NOT read the column's implicit size: a positioner
  // does not refresh implicitWidth/Height for children a Repeater adds
  // after creation (stale 0 = an empty sliver). Instead they walk the
  // live delegates, whose own metrics are always current.
  property int _linesRev: 0

  // Row geometry shared by the measure passes and the delegates: 14px
  // glyph (Icon size below) plus the gap ahead of the text.
  readonly property real _lineIconSize: 14
  readonly property real _lineGap: 6

  // Widest lead name across two-column rows, so their verbs align on it.
  // Same staleness contract as _linesW below: refreshed on row add/remove,
  // which is the only way row content arrives.
  readonly property real _verbX: {
    root._linesRev
    let w = 0
    const n = linesRep.count
    for (let i = 0; i < n; i++) {
      const it = linesRep.itemAt(i)
      if (it && it.nameW > w) w = it.nameW
    }
    return Math.ceil(w)
  }

  // Reserved space for the widest value the throughput form can ever
  // produce, so the bubble never widens as a counter moves between units.
  TextMetrics {
    id: metricWideProbe
    font.family: Ui.fontFamily
    font.pixelSize: Ui.fontS
    text: "9999.99 GB/s"
  }
  readonly property real _metricReservedW: metricWideProbe.width

  // Widest value in each column of a two-icon metric row: both value
  // columns stay at least this wide, so a changing number or unit never
  // narrows the next column's start.
  readonly property real _metricCol1W: {
    root._linesRev
    let w = 0
    const n = linesRep.count
    for (let i = 0; i < n; i++) {
      const it = linesRep.itemAt(i)
      if (it && it.metricRow && it.metric1W > w) w = it.metric1W
    }
    return Math.ceil(w)
  }
  readonly property real _metricCol2W: {
    root._linesRev
    let w = 0
    const n = linesRep.count
    for (let i = 0; i < n; i++) {
      const it = linesRep.itemAt(i)
      if (it && it.metricRow && it.metric2W > w) w = it.metric2W
    }
    return Math.ceil(w)
  }

  // Widest row (glyph + gap + natural text width). The bubble sizes
  // from this, never from the rows' laid-out widths: each row stretches
  // to the column so overlong lines elide, and sizing the bubble from
  // content that sizes from the bubble settles at zero.
  readonly property real _linesW: {
    root._linesRev
    let w = 0
    const n = linesRep.count
    for (let i = 0; i < n; i++) {
      const it = linesRep.itemAt(i)
      if (it && it.implicitWidth > w) w = it.implicitWidth
    }
    return Math.ceil(w)
  }

  // Exact rendered height: row heights plus the column spacing.
  readonly property real _linesH: {
    root._linesRev
    let h = 0
    const n = linesRep.count
    for (let i = 0; i < n; i++) {
      const it = linesRep.itemAt(i)
      if (it) h += it.height
    }
    return n > 0 ? h + (n - 1) * linesCol.spacing : 0
  }

  // Store-or-replace the snapshot for bind (identity match, so no key
  // management), assigning a fresh rev on first activation only.
  function _serve(bind, snap) {
    const next = []
    let seen = false
    for (let i = 0; i < root._reqs.length; i++) {
      const r = root._reqs[i]
      if (r.bind === bind) {
        next.push({
          bind: bind, rev: r.rev, anchor: snap.anchor, barWindow: snap.barWindow,
          text: snap.text, lines: snap.lines, markup: snap.markup, maxWidth: snap.maxWidth
        })
        seen = true
      } else {
        next.push(r)
      }
    }
    if (!seen) {
      root._rev++
      next.push({
        bind: bind, rev: root._rev, anchor: snap.anchor, barWindow: snap.barWindow,
        text: snap.text, lines: snap.lines, markup: snap.markup, maxWidth: snap.maxWidth
      })
    }
    root._reqs = next
    root._elect()
  }

  function _retire(bind) {
    root._reqs = root._reqs.filter(r => r.bind !== bind)
    root._elect()
  }

  // Serve the highest-rev snapshot with a usable anchor and window.
  function _elect() {
    let best = null
    for (let i = 0; i < root._reqs.length; i++) {
      const r = root._reqs[i]
      if (!r.anchor || !r.barWindow) continue
      if (!best || r.rev > best.rev) best = r
    }
    const winner = best ? best.bind : null
    const changed = winner !== root._winner
    root._winner = winner
    root._req = best
    if (!best) {
      showTimer.stop()
      root._show = false
      return
    }
    // Hidden or still delay-pending: a new winner pays the full delay
    // (each bubble paid its own under per-module windows). Shown: swap
    // instantly. Same winner updating: touch nothing.
    if (changed && !root._show) showTimer.restart()
  }

  // Imperative path for the tray (its tooltip is driven by item hover
  // signals, not bindings): shares the delay path, so timing matches.
  function show(anchor, text, barWindow) {
    root._serve("tray", {
      anchor: anchor, barWindow: barWindow, text: text,
      lines: [], markup: false, maxWidth: 260
    })
  }
  function hide() {
    root._reqs = []
    root._winner = null
    root._req = null
    showTimer.stop()
    root._show = false
  }
  // Conditional release: only the served anchor may dismiss.
  function cancel(anchor) {
    if (root._req && root._req.anchor === anchor) root._retire(root._req.bind)
  }
  // Unconditional tray release: the tray can collapse without a leave when
  // its anchor is destroyed (item removed) - retire the "tray" token outright
  // so a bubble cannot outlive the closed tray. Targeted (not hide()) so
  // other modules' declarative binds survive.
  function cancelTray() {
    root._retire("tray")
  }

  Timer {
    id: showTimer

    interval: root.delay
    onTriggered: {
      // Revalidate: the winner may have retired while waiting.
      if (!root._req) return
      root._show = true
    }
  }

  // While a slot-reorder drag is live on the served bar window no bubble
  // may spawn: a tooltip popping over a module mid-drag would sit between
  // the cursor and the item it's hovering. Read through a dying window
  // mid-reload yields undefined -> the bool binding warns, so guarded.
  function slotDragActive(): bool {
    try {
      const r = root._req
      const w = r ? r.barWindow : null
      return w ? w.slotDragActive === true : false
    } catch (e) { return false }
  }
  readonly property bool dragModeActive: root.slotDragActive()

  function hostScreen(): var {
    try {
      const r = root._req
      const w = r ? r.barWindow : null
      return w ? w.screen : null
    } catch (e) { return null }
  }

  // Full-screen transparent overlay on the served bar's screen. Only
  // mapped while a bubble is wanted so it never intercepts input.
  screen: root.hostScreen()
  visible: root._show && root._req !== null
    && (root._req.text !== "" || (root._req.lines && root._req.lines.length > 0))
    && !root.dragModeActive
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  anchors.left: true
  anchors.right: true
  anchors.top: true
  anchors.bottom: true

  // A passive bubble must never eat input: the window is full-screen
  // transparent, so without a mask its default clickable region would be
  // the whole screen - freezing the bar (and the hover state that would
  // dismiss this bubble) while any tooltip is visible. An empty region
  // makes every click pass through to the window beneath.
  mask: Region { width: 0; height: 0 }

  WlrLayershell.namespace: "vibranium:tooltip"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  Rectangle {
    id: bubble

    readonly property bool hasLines: root._req !== null && root._req.lines && root._req.lines.length > 0

    color: Ui.solid("background_0")
    border.width: Ui.cardBorder
    border.color: Ui.solid("background_3")
    radius: RoundingPolicy.radius
    width: {
      const natural = (bubble.hasLines ? root._linesW : label.implicitWidth) + 2 * Ui.m
      const cap = root._req ? root._req.maxWidth : 260
      return (cap > 0) ? Math.min(natural, cap) : natural
    }
    height: (bubble.hasLines ? root._linesH : label.implicitHeight) + 2 * Ui.s

    Title {
      id: label
      level: 5
      visible: !bubble.hasLines
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Ui.m
      anchors.rightMargin: Ui.m
      text: root._req ? root._req.text : ""
      textFormat: (root._req && root._req.markup) ? Text.RichText : Text.PlainText
      color: Ui.solid("foreground_0")
      wrapMode: Text.WordWrap
      elide: Text.ElideRight
    }

    // Icon-led rows: one small glyph plus its labeled line, left
    // aligned. Row width stretches to the column so overlong lines
    // elide once the bubble caps at maxWidth. implicitWidth is the
    // natural content width the _linesW measure reads - it never feeds
    // layout, so the bubble/row sizing stays one-directional.
    Column {
      id: linesCol
      visible: bubble.hasLines
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Ui.m
      anchors.rightMargin: Ui.m
      anchors.verticalCenter: parent.verticalCenter
      spacing: 3

      Repeater {
        id: linesRep

        model: root._req ? root._req.lines : []
        onItemAdded: root._linesRev++
        onItemRemoved: root._linesRev++

        Item {
          id: lineRow
          required property var modelData
          // Optional second column: rows carrying `verb` render `name` +
          // `verb` with every verb starting on the widest name, so app
          // verbs read as a table. Rows without `verb` render exactly as
          // before - one icon-led line.
          readonly property bool twoCol: lineRow.modelData.verb !== undefined
            && lineRow.modelData.verb !== null && String(lineRow.modelData.verb) !== ""
          // Two-icon metric row: one line carrying a download + upload
          // value, each pinned to its own statically sized column so a
          // changing number or unit never shifts the trailing column.
          readonly property bool metricRow: lineRow.modelData.icon2 !== undefined
            && lineRow.modelData.icon2 !== null && String(lineRow.modelData.icon2) !== ""
          readonly property real nameW: lineRow.twoCol ? nameText.implicitWidth : 0
          readonly property real metric1W: lineRow.metricRow ? metricText1.implicitWidth : 0
          readonly property real metric2W: lineRow.metricRow ? metricText2.implicitWidth : 0
          width: linesCol.width
          implicitWidth: lineRow.metricRow
            ? metricRowItem.implicitWidth
            : (lineIcon.implicitWidth + root._lineGap
                + (lineRow.twoCol ? root._verbX + root._lineGap + verbText.implicitWidth : lineText.implicitWidth))
          height: Math.max(lineIcon.implicitHeight, lineRow.twoCol
            ? Math.max(nameText.implicitHeight, verbText.implicitHeight)
            : (lineRow.metricRow
                ? Math.max(metricText1.implicitHeight, metricText2.implicitHeight, root._lineIconSize)
                : lineText.implicitHeight))

          Icon {
            id: lineIcon
            visible: !lineRow.metricRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            name: String(lineRow.modelData.icon ?? "")
            colorKey: String(lineRow.modelData.iconColor ?? (lineRow.modelData.colorKey ?? "foreground_0"))
            // Optional per-row accent for the glyph's indicator elements
            // (class="indicator" - the volume/mic muted marks): the row
            // mirrors its module icon, so a muted mark paints red here
            // exactly as it does in the bar. Empty (default) keeps the
            // single-tone foreground render.
            accentKey: String(lineRow.modelData.accentKey ?? "")
            size: root._lineIconSize
            // Optional per-row tier count for a tiered glyph (the volume
            // level row hands the bar's own dimTiers through), and an
            // optional per-row label tone: a module flags one row without
            // re-coloring the bubble. Defaults keep every existing row
            // byte-identical - foreground glyph, foreground label.
            dimTiers: Number(lineRow.modelData.dimTiers ?? 0)
          }

          Title {
            id: lineText
            level: 5
            visible: !lineRow.twoCol && !lineRow.metricRow
            anchors.left: lineIcon.right
            anchors.leftMargin: root._lineGap
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: String(lineRow.modelData.text ?? "")
            // Opt-in rich text for rows that tint part of their line (the
            // privacy tooltip colors the app name and not the verb).
            // PlainText by default, so every existing row measures and
            // paints exactly as before.
            textFormat: lineRow.modelData.markup === true ? Text.RichText : Text.PlainText
            color: Ui.solid(String(lineRow.modelData.colorKey ?? "foreground_0"))
            elide: Text.ElideRight
          }

          // Two-icon metric row content: each value is pinned to a shared
          // column width so changing values/units cannot shift the next.
          Row {
            id: metricRowItem
            visible: lineRow.metricRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: root._lineGap

            Icon {
              id: metricIcon1
              anchors.verticalCenter: parent.verticalCenter
              name: String(lineRow.modelData.icon ?? "")
              colorKey: String(lineRow.modelData.iconColor ?? "foreground_0")
              size: root._lineIconSize
              opacity: Number(lineRow.modelData.iconOpacity ?? 1)
            }
            Title {
              id: metricText1
              level: 5
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(48, root._metricCol1W, root._metricReservedW)
              horizontalAlignment: Text.AlignRight
              text: String(lineRow.modelData.text ?? "")
              color: Ui.solid(String(lineRow.modelData.colorKey ?? "foreground_0"))
              onTextChanged: root._linesRev++
            }
            Item { width: root._lineGap; height: 1 }
            Icon {
              id: metricIcon2
              anchors.verticalCenter: parent.verticalCenter
              name: String(lineRow.modelData.icon2 ?? "")
              colorKey: String(lineRow.modelData.iconColor2 ?? "foreground_0")
              size: root._lineIconSize
              opacity: Number(lineRow.modelData.iconOpacity2 ?? 1)
            }
            Title {
              id: metricText2
              level: 5
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(48, root._metricCol2W, root._metricReservedW)
              horizontalAlignment: Text.AlignRight
              text: String(lineRow.modelData.text2 ?? "")
              color: Ui.solid(String(lineRow.modelData.colorKey ?? "foreground_0"))
              onTextChanged: root._linesRev++
            }
          }

          // Lead column of a two-column row: fixed to the shared verb
          // origin, so shorter names leave trailing space and every verb
          // starts aligned. Never elides - its width is at least its own
          // natural width by construction of _verbX.
          Title {
            id: nameText
            level: 5
            visible: lineRow.twoCol
            anchors.left: lineIcon.right
            anchors.leftMargin: root._lineGap
            anchors.verticalCenter: parent.verticalCenter
            width: root._verbX
            text: String(lineRow.modelData.name ?? "")
            textFormat: lineRow.modelData.markup === true ? Text.RichText : Text.PlainText
            color: Ui.solid("foreground_0")
          }

          Title {
            id: verbText
            level: 5
            visible: lineRow.twoCol
            anchors.left: lineIcon.right
            anchors.leftMargin: root._lineGap + root._verbX + root._lineGap
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: String(lineRow.modelData.verb ?? "")
            color: Ui.solid("foreground_0")
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // Park the bubble next to the served module on every appearance and
  // when the surface maps/configures (the first pass runs pre-configure,
  // so the same settle hooks as the island re-run it at real
  // coordinates).
  function place() {
    if (!root._req || !root._req.anchor || !root._req.barWindow) return
    const w = bubble.width
    const h = bubble.height
    const barH = root._req.barWindow.height
    const anchorX = root._req.anchor.mapToItem(root._req.barWindow.contentItem, 0, 0).x
    let x = anchorX + root._req.anchor.width / 2 - w / 2
    let y = root.barPosition === "bottom" ? root.height - barH - h - root.gap : barH + root.gap
    x = Math.max(root.gap, Math.min(x, root.width - w - root.gap))
    bubble.x = Math.round(x)
    bubble.y = Math.round(y)
  }

  // A slot-reorder drag cancels a pending or shown bubble instantly; when
  // it ends with the cursor still on the module, restart the hover delay.
  onDragModeActiveChanged: {
    if (root.dragModeActive) {
      showTimer.stop()
      root._show = false
    } else if (root._req) {
      showTimer.restart()
    }
  }
  on_ReqChanged: if (root.visible) Qt.callLater(root.place)
  onVisibleChanged: if (root.visible) Qt.callLater(root.place)
  onBackingWindowVisibleChanged: if (root.backingWindowVisible) Qt.callLater(root.place)
  // `100` is the surface's placeholder size, not a threshold about the bubble:
  // an anchored PanelWindow carries no real geometry until the compositor
  // configures it, so a width at or below it means this is a pre-configure
  // pass. `place` clamps against `root.width` and maps the anchor across into
  // the bar window, and neither answer is real at that size. The other settle
  // hooks re-run `place` once the surface has one. Same shape and same number
  // as the island host's re-park.
  onWidthChanged: if (root.width > 100) Qt.callLater(root.place)
}
