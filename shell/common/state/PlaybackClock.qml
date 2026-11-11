pragma Singleton

import QtQuick
import Quickshell

// PlaybackClock - ONE 1 Hz driver for MPRIS position, shared by every surface
// that shows a progress strip.
//
// Quickshell's MprisPlayer pushes position only when a seek lands; a strip that
// moves with the track needs a repeating nudge. The bar island, the fullscreen
// lyric sheet and the lock pill each kept a private 1 Hz timer, so an open
// island beside a playing track advanced the same second twice, and a locked
// screen with the island open did it three times.
//
// The clock is a reference count, not a policy: a surface acquires it while it
// is showing a position and releases it when it stops, and the last release
// stops the tick. Nothing wakes while no surface is showing playback, so the
// count is the whole idle gate.
//
// Consumers ask their own player to re-read its position and let the player's
// positionChanged notify do the rest; the clock never touches a player, which
// keeps the pinned-client rule with the surface that pinned it.
Singleton {
  id: root

  readonly property int tickMs: 1000

  property int _holders: 0

  readonly property int holders: root._holders
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
    triggeredOnStart: true
    onTriggered: root.tick()
  }
}
