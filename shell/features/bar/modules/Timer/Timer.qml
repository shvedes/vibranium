pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import qs.features.bar

// Timer indicator. Owned slot that appears while the native timer service
// counts down or has expired. Static timer glyph on the left plus a
// countdown pill on the right (the caffeine finite-pill shape, text only -
// no icon inside). Expired keeps the same pill with a red fill and the
// "Time's up!" copy. Left click stops the countdown or
// dismisses the expired alarm through the bus request path; middle and
// right clicks are rejected at the surface level (fillButtons). The
// module owns no logic - it mirrors the `timer.bus` topic published by
// the Timer service (Bus.latest replays the last payload, so a module
// enabled after a publish is correct on frame one) and never imports
// the service.
CollapsibleSlot {
  id: root

  // Last payload from the timer service's topic; null before the first
  // publish (the module stays hidden until the service says otherwise).
  readonly property var state: Bus.latest("timer.bus")

  // Mirrors the timer service's live state; hidden state takes no space
  // (the collapse matches the owned-indicator convention). `shown` is
  // read on every zone layout pass, so the slot keeps its position in
  // the persisted order while collapsed.
  readonly property bool shown: (root.state?.active ?? false)
    || (root.state?.expired ?? false)
  readonly property bool expired: root.state?.expired ?? false
  readonly property string formatted: root.state?.formatted ?? ""

  // Collapsible slot (see CollapsibleSlot.qml): static glyph plus
  // countdown pill (the caffeine finite-pill shape). Zero width while
  // idle so it leaves no gap.
  collapseShown: root.shown
  collapseFull: Bar.iconSlot + pill.width + Bar.slotInset

  // Static timer glyph on the left, docked like the caffeine glyph.
  Icon {
    id: glyph

    anchors.left: parent.left
    anchors.leftMargin: (Bar.iconSlot - 15) / 2
    anchors.verticalCenter: parent.verticalCenter
    name: "timer"
    colorKey: "foreground_0"
    size: 15
    opacity: root.fade
    visible: opacity > 0
  }

  // Countdown pill on the right: theme background with foreground text
  // (red fill once expired), text only - no icon inside.
  Rectangle {
    id: pill

    // Right air mirrors the left inset: the zone row has zero gap and
    // icon-only neighbors center their glyphs, so a flush box would
    // ride half a gap closer to the right module.
    anchors.right: parent.right
    anchors.rightMargin: Bar.slotInset
    anchors.verticalCenter: parent.verticalCenter
    width: timeText.implicitWidth + 8
    height: timeText.implicitHeight
    radius: RoundingPolicy.radius
    color: root.expired ? Ui.solid("red") : Ui.solid("background_2")
    visible: root.shown && root.slide > 0
    // Countdown text narrows as digits drop: glide the width so the
    // pill breathes instead of snapping every tick.
    Behavior on width {
      enabled: MotionPolicy.enabled
      Glide { duration: Ui.slowMs }
    }

    Title {
      id: timeText

      anchors.centerIn: parent
      level: 3
      font.pixelSize: Math.round(Ui.fontM * 0.95 * root.textScale)
      color: Ui.solid("foreground_0")
      text: root.formatted
    }
  }

  // The remaining time, live: the text re-evaluates on every tick. The
  // expired state drops the "remaining" suffix - there is nothing left.
  readonly property string tooltipText: root.state?.expired ?? false
    ? "Timer: Time's up!"
    : "Timer: " + (root.state?.formatted ?? "") + " remaining"

  ToolTipBind {
    active: root.shown && root.hovered
    text: root.tooltipText
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }

  // Left click stops the countdown or dismisses the expired alarm (the
  // same confirmation the menu owns stays untouched); middle and right
  // clicks pass through and do nothing.
  fillButtons: Qt.LeftButton
  onClicked: mouse => Registry.call("timer", "stop")
}
