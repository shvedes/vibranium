pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// A lunar disc painted from a phase fraction (0 = new, 0.5 = full).
//
// The lit region is a path made of the lit hemisphere's arc and the curved
// terminator: an ellipse whose horizontal radius is r * |cos(theta)|. Qt's
// Canvas 2D has no ellipse(), so the terminator is two cubic Beziers per half
// using the standard 0.55228 quarter-circle control factor. When the curve
// bulges into the lit side the phase is a crescent; into the dark side it is
// gibbous. Filling that path is the point of the widget, so the lit color is
// strong and the dark half nearly disappears into the card.
//
// A Canvas onPaint is a signal, not a binding, so every input that can change
// the picture calls requestPaint() explicitly. canvasSize is bound to the
// item size: the backing store does not follow width/height on its own.
Canvas {
  id: root

  property real phase: 0
  property color litColor: Ui.solid("foreground_0")
  property color darkColor: Ui.tint("foreground_0", 0.09)
  property color rimColor: Ui.tint("foreground_0", 0.22)

  width: 24
  height: 24
  canvasSize: Qt.size(root.width, root.height)
  antialiasing: true

  onPhaseChanged: root.requestPaint()
  onWidthChanged: root.requestPaint()
  onLitColorChanged: root.requestPaint()
  onDarkColorChanged: root.requestPaint()
  onRimColorChanged: root.requestPaint()

  // Traces the terminator back to the arc's start. `fromTop` picks the
  // direction of travel; `right` picks which way the half-ellipse bulges.
  function terminator(ctx, c, a, r, fromTop, right) {
    const k = 0.5522847498
    const s = right ? 1 : -1
    if (fromTop) {
      ctx.bezierCurveTo(c + s * k * a, c - r, c + s * a, c - k * r, c + s * a, c)
      ctx.bezierCurveTo(c + s * a, c + k * r, c + s * k * a, c + r, c, c + r)
    } else {
      ctx.bezierCurveTo(c + s * k * a, c + r, c + s * a, c + k * r, c + s * a, c)
      ctx.bezierCurveTo(c + s * a, c - k * r, c + s * k * a, c - r, c, c - r)
    }
  }

  onPaint: {
    const ctx = root.getContext("2d")
    const n = Math.round(root.width)
    if (n <= 0) return
    const r = n / 2 - 1.5
    if (r <= 0) return
    const c = n / 2

    let f = root.phase % 1
    if (f < 0) f += 1
    const cosTheta = Math.cos(2 * Math.PI * f)
    const a = r * Math.abs(cosTheta)
    const waxing = f < 0.5

    ctx.clearRect(0, 0, n, n)
    ctx.beginPath()
    ctx.arc(c, c, r, 0, 2 * Math.PI)
    ctx.fillStyle = root.darkColor
    ctx.fill()

    // Right side lit for a waxing moon, left side for a waning one. The
    // terminator curves toward the lit side for a crescent and toward the
    // dark side for a gibbous phase.
    ctx.beginPath()
    if (waxing) {
      ctx.arc(c, c, r, -Math.PI / 2, Math.PI / 2, false)
      root.terminator(ctx, c, a, r, false, cosTheta >= 0)
    } else {
      ctx.arc(c, c, r, Math.PI / 2, 3 * Math.PI / 2, false)
      // The waning lit side is the left one, so the curve bulges into it
      // when cos(theta) is positive instead of negative.
      root.terminator(ctx, c, a, r, true, cosTheta < 0)
    }
    ctx.closePath()
    // Brightness tracks coverage: a thin crescent reads dimmer than a full
    // moon even before its shape does. Qt.alpha returns a color string the
    // canvas fillStyle accepts, so the palette stays theme-driven.
    const illumination = (1 - Math.cos(2 * Math.PI * f)) / 2
    ctx.fillStyle = Qt.alpha(root.litColor, 0.45 + 0.55 * illumination)
    ctx.fill()

    ctx.beginPath()
    ctx.arc(c, c, r, 0, 2 * Math.PI)
    ctx.strokeStyle = root.rimColor
    ctx.lineWidth = 1
    ctx.stroke()
  }
}
