pragma ComponentBehavior: Bound

import QtQuick

// The one blink clock the bar glyphs share. Bluetooth and Network hold a name
// pill out while their reveal window runs and blink the glyph green; the
// downloader blinks its glyph red a fixed number of times when a job fails
// with the island closed. Both are the same clock with a different gate.
//
// The colours and the interval are caller-supplied rather than read from Ui,
// so the state machine stays a plain QtObject with no singleton behind it and
// constructs headlessly. The consumer keeps its own `revealed`/`islandReveal`
// conditions (they read different link state) and its own Behavior on the
// animated slide: a Behavior belongs to the property it animates, so it stays
// where the property is declared.
QtObject {
  id: root

  // The transient name window, and the island's own hold on the pill.
  property bool revealed: false
  property bool islandReveal: false

  // The gate the caller supplies and the shape of the blink. A continuous
  // glyph (count 0) blinks while revealed holds. A counted glyph is started
  // with pulse() and stops after count ticks; the downloader passes 5 and
  // gates it on the island being closed.
  property bool active: true
  property int count: 0

  // The glyph's two endpoints, and the travel time the caller's token gives.
  property color greenColor: "transparent"
  property color restingColor: "transparent"
  property int blinkMs: 0

  // The phase lives on the timer and is written only by its tick handler.
  // Consumers read greenPhase/glyphColor and never set the phase themselves,
  // so a reveal edge cannot publish a colour frame out of step with the clock.
  property bool phase: true
  // Counted-blink bookkeeping, armed by the timer's running edge and consumed
  // by its tick. Not the phase: it never reaches a consumer.
  property int left: 0

  // The clock runs while a reveal holds it open or a pulse is outstanding.
  // Both cases stop it, so its running state is the colour gate - the same as
  // `revealed && phase` for a continuous glyph, and dark once a counted run
  // finishes. `active` is kept in the expression so a closed gate is dark on
  // the same frame it stops the timer.
  readonly property bool greenPhase: root.active && blinkTimer.running
    && root.phase
  readonly property color glyphColor: root.greenPhase ? root.greenColor
    : root.restingColor

  // `revealed` only starts and stops the clock; it never writes the phase.
  onRevealedChanged: {
    if (root.revealed) blinkTimer.restart()
    else blinkTimer.stop()
  }
  onActiveChanged: {
    if (!root.active) blinkTimer.stop()
    else if (root.count === 0 && root.revealed) blinkTimer.restart()
  }

  // Start a counted blink. Going through stop/start re-arms the running edge
  // even when a previous sequence is still in flight, so a new failure gets
  // its full count instead of inheriting the tail of the old one.
  function pulse() {
    if (!root.active) return
    blinkTimer.stop()
    blinkTimer.start()
  }

  property Timer blinkTimer: Timer {
    interval: root.blinkMs
    repeat: true
    running: false
    onRunningChanged: if (running) root.left = root.count
    onTriggered: {
      root.phase = !root.phase
      if (root.count > 0) {
        root.left--
        if (root.left <= 0) {
          stop()
          root.phase = true
        }
      }
    }
  }
}
