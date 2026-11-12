pragma ComponentBehavior: Bound

import QtQuick

// The name-reveal state the signal modules share: Bluetooth and Network both
// flash a name pill when a link comes up, blink the glyph green while the
// window is open, and hold the pill out for the island's lifespan without the
// colour. The cadence lives here once so the two modules cannot drift apart.
//
// The colours and durations are caller-supplied rather than read from Ui, so
// the state machine stays a plain QtObject with no singleton behind it and
// constructs headlessly. The consumer keeps its own `revealed`/`islandReveal`
// conditions (they read different link state) and its own Behaviors on the two
// animated properties: a Behavior belongs to the property it animates, so it
// stays where the property is declared.
QtObject {
  id: root

  // The transient name window, and the island's own hold on the pill.
  property bool revealed: false
  property bool islandReveal: false
  // The glyph's two endpoints, and the travel times the caller's tokens give.
  property color greenColor: "transparent"
  property color restingColor: "transparent"
  property int slowMs: 0
  property int blinkMs: 0

  // Green-normal blink, independent of the global motion setting.
  readonly property bool greenPhase: root.revealed && root._flashTick
  property bool _flashTick: false

  // 1 while either reveal holds the pill out, 0 at rest.
  readonly property real nameSlide: (root.revealed || root.islandReveal) ? 1 : 0

  // The way in matches the pill's glide; the way home lasts a blink. A
  // Behavior carries one duration, so it is read per travel.
  readonly property int colorMs: root.revealed ? root.slowMs : root.blinkMs
  readonly property color glyphColor: root.greenPhase ? root.greenColor : root.restingColor

  onRevealedChanged: root._flashTick = root.revealed

  property Timer blinkTimer: Timer {
    interval: root.blinkMs
    running: root.revealed
    repeat: true
    onTriggered: root._flashTick = !root._flashTick
  }
}
