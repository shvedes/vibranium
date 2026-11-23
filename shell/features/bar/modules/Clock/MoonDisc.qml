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

  // A soft-edged patch: a radial gradient fading to transparent, squashed
  // into an ellipse. Hard-edged circles read as stickers on the disc; the
  // real maria have diffuse borders and uneven tone.
  function patch(ctx, x, y, rx, ry, rotation, color, alpha) {
    ctx.save()
    ctx.translate(x, y)
    ctx.rotate(rotation)
    ctx.scale(Math.max(0.01, rx), Math.max(0.01, ry))
    const g = ctx.createRadialGradient(0, 0, 0, 0, 0, 1)
    g.addColorStop(0, Qt.alpha(color, alpha))
    g.addColorStop(0.55, Qt.alpha(color, alpha * 0.45))
    g.addColorStop(1, Qt.alpha(color, 0))
    ctx.fillStyle = g
    ctx.beginPath()
    ctx.arc(0, 0, 1, 0, 2 * Math.PI)
    ctx.fill()
    ctx.restore()
  }

  // Faint ejecta rays fade out along their length. Using a gradient rather
  // than a flat stroke keeps them from reading as drawn lines on the disc.
  function ray(ctx, x, y, length, angle, alpha) {
    const ex = x + Math.cos(angle) * length
    const ey = y + Math.sin(angle) * length
    const g = ctx.createLinearGradient(x, y, ex, ey)
    g.addColorStop(0, Qt.alpha("#ffffff", alpha))
    g.addColorStop(1, Qt.alpha("#ffffff", 0))
    ctx.beginPath()
    ctx.moveTo(x, y)
    ctx.lineTo(ex, ey)
    ctx.strokeStyle = g
    ctx.lineWidth = 0.7
    ctx.stroke()
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
    ctx.save()
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

    // Near-side albedo features: Oceanus Procellarum and the big maria are
    // broad and soft, the craters small and faint. Everything is clipped to
    // the lit path, so the surface turns with the phase. The last pass adds
    // limb darkening so the disc reads as a sphere, not a flat sticker.
    if (n >= 40) {
      ctx.clip()
      // Near side, north up, east right. The dark plains form connected
      // seas in the north and along the western limb; the southern half is
      // bright highland, which is why no maria sit near y = +0.5.
      const maria = [
        [-0.56, -0.06, 0.34, 0.56, 0.05, 0.26], // Oceanus Procellarum
        [-0.20, -0.38, 0.28, 0.24, -0.20, 0.26], // Mare Imbrium
        [0.18, -0.38, 0.22, 0.18, 0.15, 0.24],   // Mare Serenitatis
        [0.31, -0.06, 0.22, 0.16, -0.25, 0.23],  // Mare Tranquillitatis
        [0.49, 0.20, 0.18, 0.14, 0.30, 0.20],    // Mare Fecunditatis
        [0.63, -0.20, 0.13, 0.09, -0.10, 0.23],  // Mare Crisium
        [-0.24, 0.26, 0.20, 0.14, 0.20, 0.20],   // Mare Nubium
        [-0.47, 0.25, 0.14, 0.12, -0.15, 0.18]   // Mare Humorum
      ]
      for (let i = 0; i < maria.length; i++) {
        const m = maria[i]
        root.patch(ctx, c + m[0] * r, c + m[1] * r,
          m[2] * r, m[3] * r, m[4], "#1b2430", m[5])
      }
      // Only the named ray craters show at this size; scattering more
      // would read as noise rather than lunar surface.
      const craters = [
        [-0.16, -0.18, 0.035], // Copernicus, south of Imbrium
        [-0.40, -0.32, 0.03],  // Kepler
        [-0.54, -0.26, 0.03],  // Aristarchus
        [0.06, 0.60, 0.035]    // Tycho, southern highlands
      ]
      for (let i = 0; i < craters.length; i++) {
        const k = craters[i]
        root.patch(ctx, c + k[0] * r, c + k[1] * r,
          k[2] * r, k[2] * r, 0, "#1b2430", 0.22)
      }

      // Tycho's rays cross most of the near side; Copernicus has a shorter,
      // tighter system. Angles are fixed so the pattern stays the same disc
      // after disc instead of being regenerated at random.
      const tychoX = c + 0.06 * r
      const tychoY = c + 0.60 * r
      const tychoAngles = [-1.72, -1.40, -1.10, -0.82, -2.05, -0.55, -2.35, 3.05]
      for (let i = 0; i < tychoAngles.length; i++)
        root.ray(ctx, tychoX, tychoY, (0.75 + (i % 3) * 0.12) * r,
          tychoAngles[i], 0.16)
      const copX = c - 0.16 * r
      const copY = c - 0.18 * r
      const copAngles = [-2.30, -1.85, -1.35, -0.95, -2.75]
      for (let i = 0; i < copAngles.length; i++)
        root.ray(ctx, copX, copY, (0.34 + (i % 2) * 0.10) * r,
          copAngles[i], 0.13)

      // Highland pitting is densest in the south and thins out over the
      // maria, matching the uneven surface the full Moon actually shows.
      const highlands = [
        [-0.60, -0.55, 0.022], [-0.30, -0.62, 0.018], [0.05, -0.66, 0.02],
        [0.40, -0.55, 0.018], [0.62, -0.45, 0.02], [-0.66, -0.10, 0.02],
        [-0.60, 0.20, 0.018], [-0.42, 0.52, 0.028], [-0.20, 0.62, 0.022],
        [0.02, 0.72, 0.03], [0.22, 0.58, 0.024], [0.40, 0.66, 0.026],
        [0.58, 0.48, 0.02], [0.30, 0.32, 0.018], [-0.10, 0.42, 0.016]
      ]
      for (let i = 0; i < highlands.length; i++) {
        const k = highlands[i]
        const x = c + k[0] * r
        const y = c + k[1] * r
        const rad = k[2] * r
        root.patch(ctx, x, y, rad, rad, 0, "#1b2430", 0.17)
        if (k[2] >= 0.026) {
          ctx.beginPath()
          ctx.arc(x, y, rad, 0, 2 * Math.PI)
          ctx.strokeStyle = Qt.alpha("#ffffff", 0.16)
          ctx.lineWidth = 0.6
          ctx.stroke()
        }
      }

      const limb = ctx.createRadialGradient(c, c, r * 0.55, c, c, r)
      limb.addColorStop(0, Qt.alpha("#0b1018", 0))
      limb.addColorStop(1, Qt.alpha("#0b1018", 0.24))
      ctx.fillStyle = limb
      ctx.beginPath()
      ctx.arc(c, c, r, 0, 2 * Math.PI)
      ctx.fill()
    }
    ctx.restore()

    ctx.beginPath()
    ctx.arc(c, c, r, 0, 2 * Math.PI)
    ctx.strokeStyle = root.rimColor
    ctx.lineWidth = 1
    ctx.stroke()
  }
}
