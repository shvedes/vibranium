pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import qs.services as Core

// The mixer's volume slider: the bar volume island's `VSlider` idiom - the
// shared `ProgressBar` track, the 100% unity mark, clicks gliding to the point
// and sustained drags snapping past 6px - plus the keyboard the island's
// slider does not have.
//
// The island's slider is a pointer control inside an island that is itself
// keyboard-driven, so arrows there belong to the island. A mixer row is a
// control inside a real window, and a control a keyboard cannot move is not a
// control: Left/Right step by the shell's own volume step, Up/Down do the
// same, Home and End go to the ends, and PageUp/PageDown take ten steps. The
// value is only ever WRITTEN through `moved()` - never assigned here - so the
// owner keeps its binding and this component stays stateless, which is what
// makes the same instance reusable for a device row, a stream row and a
// per-channel row.
//
// The track is the shell's own `ProgressBar` rather than a private rounded
// rect, which is what makes a mixer row look like the bar, the OSD and every
// other level surface. `ratio` is the one number the fill, the unity mark and
// the drag all read, so they cannot disagree about where the value sits; the
// primitive takes a 0..100 percentage and the ratio is scaled into it.
Item {
  id: slider

  required property real value
  required property real maximum
  property bool muted: false
  // One step per keypress and per wheel notch, from the shell's own volume
  // step - the same number the bar's island steps by, so a keyboard move here
  // and a wheel move there land on the same level. A caller with a different
  // step sets it here.
  property real step: Core.Audio.step
  property bool interactive: true

  signal moved(real v)

  // The value as a fraction of this slider's own cap, and the only place the
  // fraction is computed: a muted row reads zero, a caller with a zero cap
  // does not divide by it, and the fill, the unity mark and the drag all
  // follow the one number.
  readonly property real ratio: slider.muted || !(slider.maximum > 0) ? 0
    : Math.max(0, Math.min(1, slider.value / slider.maximum))

  // There is no thumb, and that is a decision rather than an omission: a 6px
  // track with a 12px knob on it is read as a handle that has to be grabbed,
  // and in a mixer that handle is a lie - the whole bar is the target, the fill
  // already ends exactly where the value is, and a drag starts anywhere on the
  // track rather than on the knob.
  //
  // What still carries the affordance, in the order a user meets it: the FILL,
  // whose leading edge is the value and moves under the pointer while dragging;
  // the percentage READOUT beside the track, which names the value to the digit;
  // and the DRAG itself, which takes a press anywhere on the track and glides
  // to that point. The keyboard never depended on the thumb - every key calls
  // `moved()` directly through `_stepBy` - so what it needs instead is the
  // `Accessible` block at the bottom, which is the one thing here that still
  // names the value and offers the two actions.
  //
  // Nothing else is load-bearing in it: no geometry of this component read the
  // thumb, and the track's implicit size was never derived from it.

  implicitHeight: 6
  height: 6
  // The one fader length for the whole mixer, hardcoded: every slider in the
  // app is this wide, whatever the window is doing. A fader that grew with the
  // row is what stopped the meters lining up - "as wide as the fader above it"
  // inherits whatever the fader decided to be - and a level column that
  // stretches from 200px to 1000px across two window sizes makes the whole list
  // unreadable. The name column takes the slack instead, so a wider window buys
  // longer device names rather than longer bars.
  implicitWidth: 200
  // Reachable with Tab rather than focused on construction: a window full of
  // rows that all grab focus at once has no focus at all.
  activeFocusOnTab: slider.interactive

  // The track: the shell's own primitive, at 6px, with the fill riding the
  // island's accent and the glide the island glides with. `dimWhenEmpty` off
  // because a volume track is always drawn - a silent row has to show an empty
  // track, not a faded one - and `animationsEnabled` off for the duration of a
  // drag so the fill follows the pointer rather than easing behind it.
  ProgressBar {
    anchors.fill: parent
    value: slider.ratio * 100
    dimWhenEmpty: false
    animationsEnabled: !slider.dragging && MotionPolicy.enabled
  }

  // The unity mark. A track that runs past unity has to say where unity sits:
  // the midpoint of a boosted output track, two thirds across a stream row's
  // 150% cap. The gate is the track itself, not the boost setting - a 1.0
  // maximum has nothing beyond 100% to mark.
  //
  // 3px, not a hairline: this is the one mark on a 6px track that has to be
  // found at a glance rather than read, and a 1px stroke on a track this thin
  // is a rounding artifact at fractional widths.
  Rectangle {
    visible: slider.maximum > 1
    width: 3
    height: slider.height
    // Half-width offset so the mark straddles the exact unity point instead of
    // sitting entirely to its right.
    x: slider.width / slider.maximum - width / 2
    color: Ui.solid("red")
  }

  property bool dragging: false
  property real pressX: 0

  MouseArea {
    id: grab

    anchors.fill: parent
    anchors.topMargin: -8
    anchors.bottomMargin: -8
    // No `hoverEnabled`: the only reader of `containsMouse` was the thumb, and
    // a hover the component does not act on is a notification per pointer move
    // for every slider in the list.
    enabled: slider.interactive
    cursorShape: slider.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
    acceptedButtons: Qt.LeftButton

    function update(x) {
      const r = Math.max(0, Math.min(1, x / slider.width))
      slider.moved(r * slider.maximum)
    }

    onPressed: function(mouse) {
      slider.pressX = mouse.x
    }
    onPositionChanged: function(mouse) {
      if (!pressed) return
      if (Math.abs(mouse.x - slider.pressX) > 6) {
        slider.dragging = true
        update(mouse.x)
      }
    }
    onReleased: function(mouse) {
      update(mouse.x)
      slider.dragging = false
    }
    // An interrupted drag must never leave `dragging` on, or the fill glide
    // stays dead for the rest of the row's life.
    onCanceled: slider.dragging = false
  }

  WheelHandler {
    id: wheel
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    enabled: slider.interactive
    onWheel: function(event) {
      const d = event.angleDelta.y > 0 ? slider.step : (event.angleDelta.y < 0 ? -slider.step : 0)
      if (d === 0) return
      slider.moved(Math.max(0, Math.min(slider.maximum, slider.value + d)))
    }
  }

  function _stepBy(delta) {
    slider.moved(Math.max(0, Math.min(slider.maximum, slider.value + delta)))
  }

  Keys.onPressed: function(event) {
    const s = slider.step
    const page = s * 10
    if (event.key === Qt.Key_Left || event.key === Qt.Key_Down) {
      event.accepted = true
      slider._stepBy(-s)
      return
    }
    if (event.key === Qt.Key_Right || event.key === Qt.Key_Up) {
      event.accepted = true
      slider._stepBy(s)
      return
    }
    if (event.key === Qt.Key_PageDown) {
      event.accepted = true
      slider._stepBy(-page)
      return
    }
    if (event.key === Qt.Key_PageUp) {
      event.accepted = true
      slider._stepBy(page)
      return
    }
    if (event.key === Qt.Key_Home) {
      event.accepted = true
      slider.moved(0)
      return
    }
    if (event.key === Qt.Key_End) {
      event.accepted = true
      slider.moved(slider.maximum)
    }
  }

  Accessible.role: Accessible.Slider
  Accessible.name: "Volume"
  // The value rides the accessible description rather than Accessible.value:
  // this Qt's Accessible attached object has no value/minimum/maximum members
  // (they are proposed, not implemented), so a bound one would be a property
  // that does not exist rather than a value a screen reader could read.
  Accessible.description: Math.round(slider.value * 100) + "%"
  Accessible.onIncreaseAction: slider._stepBy(slider.step)
  Accessible.onDecreaseAction: slider._stepBy(-slider.step)
}