pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// One rotating busy glyph, shared by every bar island that shows a live
// "working" state. It owns only the animation mechanics: the caller
// supplies `running`, so each site keeps its own motion-policy gate (or
// its documented exemption for a genuine busy indicator) right where the
// decision is made. Everything else - color, size, opacity, placement -
// is the caller's too; just set the usual Icon properties on this type.
Icon {
  id: root

  // Drives the loop. Callers pass the busy predicate, optionally &&ed with
  // MotionPolicy.enabled when the glyph is decoration rather than status.
  property bool running: false

  // Islands ask for the update glyph almost everywhere; a caller may still
  // override it (printers' job rows swap in check/xmark for finished work).
  name: "update"
  transformOrigin: Item.Center

  RotationAnimation on rotation {
    from: 0
    to: 360
    duration: 1000
    loops: Animation.Infinite
    running: root.running
    onRunningChanged: if (!running) root.rotation = 0
  }
}
