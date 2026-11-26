pragma Singleton

import QtQuick
import Quickshell

// PlaybackClock - ONE driver for MPRIS position, shared by every surface that
// shows a moving position.
//
// Quickshell's MprisPlayer interpolates `position` from the last DBus update but
// emits `positionChanged` only on a nonlinear change, so a consumer that wants
// live values must emit the signal itself. The bar island, the fullscreen lyric
// sheet and the lock pill would each run a driver to do that, so an open island
// beside a playing track nudged the same player twice, and a locked screen with
// the island open did it three times.
//
// The clock is a reference count, not a policy: a surface acquires it while it
// is showing a position and releases it when it stops, and the last release
// stops the tick. Nothing wakes while no surface is showing playback, so the
// count is the whole idle gate.
//
// A Timer, not a FrameAnimation: an interpolated DBus value has to advance even
// when nothing else is rendering. A frame-driven animation only triggers while
// a window is producing frames, so a static surface showed the position from
// its opening frame and never refreshed it. One 100 ms cadence keeps a
// centisecond-stamped lyric cue inside a tenth of a second without giving each
// surface its own driver. No readiness is guessed and no duration is copied.
//
// Consumers emit their own player's `positionChanged` on the tick and read the
// live position in a binding; the clock never touches a player, which keeps the
// pinned-client rule with the surface that pinned it.
Singleton {
  id: root

  readonly property int tickMs: 100

  property int _holders: 0

  readonly property bool ticking: root._holders > 0

  // One tick for every holder. A holder that also needs to know which surface
  // caused it must not care: the tick is a clock, not an event source.
  signal tick()

  function acquire(): bool {
    root._holders++
    return true
  }

  // An unmatched release is refused rather than letting the count go negative,
  // which would keep the tick armed with nobody listening.
  function release(): bool {
    if (root._holders <= 0) return false
    root._holders--
    return true
  }

  Timer {
    interval: root.tickMs
    repeat: true
    running: root.ticking
    // A surface that re-acquires the clock after a transport edge gets a read
    // at once, not one interval later.
    triggeredOnStart: true
    onTriggered: root.tick()
  }
}
