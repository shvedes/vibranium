pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Live level meter: the shell's one peak bar. The volume island's two inline
// meters and the audio mixer's row meters are this same type, so their
// smoothing, clip threshold and paint cannot drift apart into two languages
// for the same signal.
//
// Sized to sit inline in a section title row or under a mixer fader: a 4px
// horizontal track with the fill filling from the left, no label and no
// controls. A consumer scales a pre-volume node peak by its own gain and hands
// the product in as `peak`, so a 20% volume never paints full scale.
Rectangle {
  id: meter

  // Optional peak handle (PipeWireState) and gain. When a handle is given the
  // meter computes its own level from it (scaled by gain); otherwise `peak`
  // is used directly. This lets the audio mixer use the shared meter without
  // a feature-local wrapper.
  property var peakHandle: null
  property real gain: 1
  property real peak: 0
  property bool muted: false

  readonly property real _peak: {
    const h = meter.peakHandle
    if (h !== null && h !== undefined) {
      if (h.active !== true) return 0
      const p = Number(h.peak)
      if (!isFinite(p)) return 0
      return Math.max(0, Math.min(1, p * meter.gain))
    }
    return meter.peak
  }

  // Smooth the spiky raw Pipewire peak with the default house tween -
  // the continuously retargeted glide reads as a calm level wave. Both
  // the fill and the clip color read this instead of `peak`: one Glide
  // on the value is what keeps the bar calm, and the red state then
  // cannot flicker on a single loud sample the way a raw-peak color
  // would.
  property real level: meter._peak
  Behavior on level { Glide {} }

  // Clip state. 0.90 rather than 1.0: the peak is a raw per-channel
  // maximum that only lands exactly on full scale once the signal is
  // already distorting, so the bar would flag nothing until it was too
  // late to be a warning.
  readonly property bool peaking: meter.level >= 0.90

  implicitHeight: 4
  radius: RoundingPolicy.radius
  color: Ui.tint("background_3", 0.6)
  clip: true

  Rectangle {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: parent.width * (meter.muted ? 0 : Math.max(0, Math.min(1, meter.level)))
    // The fill is the level, so the clip state rides the fill: the
    // track stays the neutral trough behind it and the bar reads as
    // loud-then-clipping rather than fully red at any level.
    color: meter.peaking ? Ui.solid("red") : Ui.tint("accent", 0.7)
    Behavior on color { ColorAnim {} }
  }
}
