pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import "../math/FuncLib.js" as FuncLib

// Shared live/static function graph: same grid, axes and curve in the
// AppLauncher dropdown (live, per keystroke) and the Clipboard preview
// pane (static, per selected entry).
//
// The host only sets `funcBody` (the stripped plottable body, e.g. "x^2"
// from "y = x^2"). Sampling + ranging live in FuncLib so both surfaces
// share one numerical truth; this file is pure rendering.
//
// Geometry: optional header ("y = <expr>" + domain) over a framed
// viewport. The plot floats on a mat inside the frame (inset fill +
// hairline border) so it reads as a viewport, not a cutout. X domain is
// fixed [-10, 10] by default; Y auto-fits the 5th/95th percentiles so
// tan-style poles never flatten the curve. Gaps (NaN, out-of-range,
// steep jumps) break the path - asymptotes read as gaps, never as
// vertical streaks.
Item {
  id: root

  property string funcBody: ""
  property real xMin: -10
  property real xMax: 10
  // Fixed plot height (launcher dropdown). Clipboard preview instead sets
  // fillHeight and anchors this item to its full extent - the plot box
  // absorbs the leftover height so the graph fills the pane edge to edge
  // with no top/bottom gaps.
  property real graphH: 150
  property bool fillHeight: false
  property bool showHeader: true

  // In fill mode the box tracks the host height - which falls back to
  // this implicit size before anchors resolve, so reporting the live box
  // height here would close a binding loop (height -> implicitHeight ->
  // height, warned at 143) and latch garbage. Report the resting
  // estimate instead; anchored fill hosts never read implicitHeight
  // anyway. Fixed mode keeps the exact live sum.
  implicitHeight: (root.showHeader ? headerRow.height + Ui.s : 0)
    + (root.fillHeight ? Math.max(80, root.graphH) : graphBox.height)
  implicitWidth: 280

  // Palette-driven repaints: these bindings reschedule the paint when the
  // theme lands at boot or switches live.
  // Frame (mat) + plot fills. The ring of frame color around the plot is
  // what sells the viewport: background_1 mat, background_0 plot, hairline
  // border outside.
  readonly property string _bg: Theme.color("background_1")
  readonly property string _plotBg: Theme.color("background_0")
  readonly property string _border: Theme.color("background_3")
  readonly property string _minor: Ui.tint("background_3", 0.45)
  readonly property string _major: Ui.tint("background_3", 0.95)
  readonly property string _axis: Ui.tint("foreground_1", 0.55)
  readonly property string _curve: Ui.solid("accent")
  readonly property string _label: Ui.tint("foreground_1", 0.55)
  readonly property string _title: Ui.tint("foreground_0", 1)
  // The containing window's DPR (same source as Icon.qml - its own window,
  // so screens with different scales resolve independently). A Canvas
  // never repaints on its own after its buffer changes size, so the DPR
  // handler below makes scale switches actually redraw instead of
  // stranding a stale buffer (a static preview would keep it forever).
  readonly property real _dpr: Window.window ? Window.window.devicePixelRatio : 1

  on_BgChanged: plot.requestPaint()
  on_PlotBgChanged: plot.requestPaint()
  on_BorderChanged: plot.requestPaint()
  on_DprChanged: plot.requestPaint()
  on_MinorChanged: plot.requestPaint()
  on_MajorChanged: plot.requestPaint()
  on_AxisChanged: plot.requestPaint()
  on_CurveChanged: plot.requestPaint()

  // One sample per pixel column (clamped): live typing recompiles a short
  // expression per frame, trivial next to the paint itself.
  readonly property int _sampleN: Math.max(80, Math.min(300, Math.round(graphBox.width || root.width || 240)))
  readonly property var _sample: FuncLib.sampleFunction(root.funcBody, root.xMin, root.xMax, root._sampleN)
  on_SampleChanged: plot.requestPaint()
  // Keystroke debounce: live typing would otherwise recompile + repaint
  // every intermediate prefix. Bursts collapse into one paint per 120ms;
  // range/palette changes below still paint at once.
  onFuncBodyChanged: paintDebounce.restart()
  Timer {
    id: paintDebounce
    interval: 120
    repeat: false
    onTriggered: plot.requestPaint()
  }
  onXMinChanged: plot.requestPaint()
  onXMaxChanged: plot.requestPaint()

  // Nice Y step (1/2/5 * 10^k) for the horizontal grid.
  function _niceStep(span) {
    if (!(span > 0) || !isFinite(span)) return 1
    var raw = span / 6
    var mag = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10))
    var norm = raw / mag
    var nice = norm < 1.5 ? 1 : norm < 3.5 ? 2 : norm < 7.5 ? 5 : 10
    return nice * mag
  }

  // Keep vertical grid density proportional to plot width, not domain size.
  function _xStep(span, width) {
    var maxLines = Math.max(2, Math.floor(width / 12))
    return root._niceStep(span * 6 / maxLines)
  }

  // Header: dim "y = " prefix, bright middle-elided expression, dim
  // domain pinned right. Splitting the prefix keeps long bodies readable
  // (the "y = " never scrolls out of the elision).
  Item {
    id: headerRow
    visible: root.showHeader
    anchors.left: parent.left
    anchors.right: parent.right
    height: visible ? Math.max(ypre.implicitHeight, Math.max(exprText.implicitHeight, domainText.implicitHeight)) : 0

    Text {
      id: ypre
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "y = "
      color: root._label
      font.pixelSize: Ui.fontS
      font.family: Ui.fontFamily
      textFormat: Text.PlainText
    }

    Text {
      id: domainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: "x ∈ [" + root.xMin + ", " + root.xMax + "]"
      color: root._label
      font.pixelSize: Ui.fontXs
      font.family: Ui.fontFamily
      textFormat: Text.PlainText
    }

    Text {
      id: exprText
      anchors.left: ypre.right
      anchors.right: domainText.left
      anchors.rightMargin: Ui.s
      anchors.verticalCenter: parent.verticalCenter
      text: root.funcBody !== "" ? root.funcBody : "–"
      color: root._title
      font.pixelSize: Ui.fontS
      font.family: Ui.fontFamily
      elide: Text.ElideMiddle
      textFormat: Text.PlainText
    }
  }

  Rectangle {
    id: graphBox
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: root.showHeader ? headerRow.bottom : parent.top
    anchors.topMargin: root.showHeader ? Ui.s : 0
    // Fill mode derives from the host-driven height (guarded for the
    // transient zero before first layout); fixed mode keeps graphH.
    height: root.fillHeight
      ? Math.max(80, root.height - headerRow.height - (root.showHeader ? Ui.s : 0))
      : root.graphH
    color: root._bg
    border.width: 1
    border.color: root._border
    clip: true

    // Device-pixel geometry (Timer-gauge pattern): the Canvas item itself is
    // sized in device pixels and scaled back to logical, so the default
    // backing - which follows the item - is already a device-sized buffer
    // that matches the item's on-screen device size exactly. The invariant
    // is that match, not the backing being item-sized: the scene presents a
    // backing 1:1 in device pixels from the item's top-left, so a backing in
    // LOGICAL pixels covers only the top-left 1/DPR of the item and the rest
    // is bare backing. Scaling the item (rather than pinning canvasSize) also
    // means the buffer reallocates on ordinary scene-graph geometry, which
    // always reallocates, instead of trailing an explicit canvasSize that
    // froze at its creation value (Loaders birth this with no window yet, so
    // DPR reads 1) while painting used the live DPR.
    //
    // Do not verify this with grabToImage: it stretches the item into the
    // target buffer, so it renders a wrongly-sized backing as if it were
    // correct. Only the screen shows the difference.
    Item {
      id: plotWrap
      anchors.fill: parent
      anchors.margins: 6

      Canvas {
        id: plot
        width: Math.max(1, Math.round(plotWrap.width * root._dpr))
        height: Math.max(1, Math.round(plotWrap.height * root._dpr))
        // Visual size stays logical regardless of the DPR raster size.
        scale: root._dpr > 0 ? 1 / root._dpr : 1
        anchors.centerIn: parent
        contextType: "2d"
        renderStrategy: Canvas.Immediate

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
          var ctx = plot.getContext("2d")
          if (ctx === null) return
          var W = plotWrap.width, H = plotWrap.height
          if (W <= 0 || H <= 0) return
          ctx.reset()
          // Item px per logical px: == DPR up to rounding, so all drawing
          // below stays in plain logical coordinates and lands texel-crisp.
          var dpx = plot.width / W
          ctx.scale(dpx, dpx)
          ctx.clearRect(0, 0, W, H)
          ctx.fillStyle = root._plotBg
          ctx.fillRect(0, 0, W, H)

          var x0 = root.xMin, x1 = root.xMax
          if (!isFinite(x0) || !isFinite(x1) || !(x1 > x0)) return
          var s = root._sample
          var y0 = s ? s.yMin : -10
          var y1 = s ? s.yMax : 10
          if (!(y1 > y0)) { y0 = -10; y1 = 10 }

          var px = function(x) { return (x - x0) / (x1 - x0) * W }
          var py = function(y) { return H - (y - y0) / (y1 - y0) * H }

          // --- vertical grid (nice X steps, bounded by plot width) ---
          ctx.lineWidth = 1
          var xStep = root._xStep(x1 - x0, W)
          var xk0 = Math.ceil(x0 / xStep), xk1 = Math.floor(x1 / xStep)
          var xk
          for (xk = xk0; xk <= xk1; xk++) {
            var xi = xk * xStep
            var vx = Math.round(px(xi)) + 0.5
            if (xk === 0) {
              ctx.strokeStyle = root._axis
            } else if (xk % 5 === 0) {
              ctx.strokeStyle = root._major
            } else {
              ctx.strokeStyle = root._minor
            }
            ctx.beginPath()
            ctx.moveTo(vx, 0)
            ctx.lineTo(vx, H)
            ctx.stroke()
          }

          // --- horizontal grid (nice Y steps) ---
          var step = root._niceStep(y1 - y0)
          var k0 = Math.ceil(y0 / step), k1 = Math.floor(y1 / step)
          var k
          for (k = k0; k <= k1; k++) {
            var yv = k * step
            if (yv === 0) yv = 0 // normalize -0 so the axis branch holds
            var hy = Math.round(py(yv)) + 0.5
            // k===0 is y=0 exactly (integer loop, no float drift)
            if (k === 0) {
              ctx.strokeStyle = root._axis
            } else if (k % 5 === 0) {
              ctx.strokeStyle = root._major
            } else {
              ctx.strokeStyle = root._minor
            }
            ctx.beginPath()
            ctx.moveTo(0, hy)
            ctx.lineTo(W, hy)
            ctx.stroke()
          }

          // --- range corner labels ---
          ctx.fillStyle = root._label
          ctx.font = Ui.fontXs + "px \"" + Ui.fontFamily + "\""
          ctx.textBaseline = "alphabetic"
          var yTopTxt = (Math.round(y1 * 100) / 100).toString()
          var yBotTxt = (Math.round(y0 * 100) / 100).toString()
          ctx.fillText(yTopTxt, 4, 11)
          ctx.fillText(yBotTxt, 4, H - 4)
          var xL = x0.toString(), xR = x1.toString()
          var wR = ctx.measureText(xR).width
          ctx.fillText(xL, 4, H - 4)
          // bottom-right overlaps y-bottom label: lift it one line
          ctx.fillText(xR, W - wR - 4, H - 4)

          // --- curve ---
          if (!s || !s.ys || s.valid === 0) return
          var ys = s.ys
          var n = ys.length
          var span = y1 - y0
          ctx.strokeStyle = root._curve
          ctx.lineWidth = 2
          ctx.lineJoin = "round"
          ctx.lineCap = "round"
          ctx.beginPath()
          var pen = false
          var prevY = 0
          var hasPrev = false
          var i
          for (i = 0; i < n; i++) {
            var y = ys[i]
            if (typeof y !== "number" || isNaN(y) || y < y0 || y > y1) {
              pen = false
              hasPrev = false
              continue
            }
            // Break across poles: tan/1/x jumps would otherwise streak.
            if (hasPrev && Math.abs(y - prevY) > span * 0.55) {
              pen = false
            }
            var cx = i / (n - 1) * W
            var cy = py(y)
            if (!pen) {
              ctx.moveTo(cx, cy)
              pen = true
            } else {
              ctx.lineTo(cx, cy)
            }
            prevY = y
            hasPrev = true
          }
          ctx.stroke()
        }
      }
    }
  }
}
