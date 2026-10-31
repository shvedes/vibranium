pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import qs.features.bar

// Caffeine indicator. Owned slot that appears while an inhibit is
// active: a caffeine icon on the left plus a countdown pill on the right
// while a finite inhibit runs, the pill showing the remaining m:ss. The
// infinite tail shows no pill; the steam turns red while the mug keeps
// the theme foreground (two-tone, like the NightLight moon). The module
// owns no logic - it mirrors the `inhibitor.bus` bus topic published by
// the Inhibitor service (Bus.latest replays the last payload, so a module
// enabled after a publish is correct on frame one) and never imports the
// service.
CollapsibleSlot {
  id: root

  // Last payload from the inhibitor service's topic; null before the first
  // publish (the module stays hidden until the service says otherwise).
  readonly property var state: Bus.latest("inhibitor.bus")

  // Live countdown mirrors with null-safe fallbacks.
  readonly property bool active: root.state?.active ?? false
  readonly property bool infinite: root.state?.infinite ?? false
  readonly property string formatted: root.state?.formatted ?? ""

  // Finite pill shows only while a finite inhibit holds. The infinite
  // tail shows no pill; the steam turns red instead.
  readonly property bool finiteShown: root.active && !root.infinite

  // Collapsible slot (see CollapsibleSlot.qml): `slide` carries the
  // glyph in and out, while `pillSlide` (second axis, local) slides only
  // the pill extension, so an infinite inhibit settles at one icon slot.
  // Idle takes no space; the infinite tail is exactly one slot; finite
  // adds the pill plus one inset.
  collapseShown: root.active
  collapseFull: Bar.iconSlot + root.pillSlide * (pill.width + Bar.slotInset)
  property real pillSlide: root.finiteShown ? 1 : 0
  Behavior on pillSlide {
    enabled: MotionPolicy.enabled
    Glide { duration: Ui.slowMs }
  }

  // Countdown pill (the Recording module shape, recolored): theme
  // background with foreground text instead of the red alert pill.
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
    color: Ui.solid("background_2")
    visible: root.finiteShown && root.pillSlide > 0
    // Countdown text narrows as digits drop (10:00 -> 9:59): glide the
    // width so the pill breathes instead of snapping every tick.
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

  Icon {
    // Docked left ahead of the pill: the slot grows rightward from the
    // glyph, so the glyph rides left while the pill holds the right edge.
    anchors.left: parent.left
    anchors.leftMargin: (Bar.iconSlot - 15) / 2
    anchors.verticalCenter: parent.verticalCenter
    name: "caffeine"
    // Mug stays in theme foreground in every state; the steam (the only
    // class="indicator" element in the asset) carries the state color:
    // red while the inhibit is infinite (sleep is fully blocked), yellow
    // while a finite countdown runs.
    colorKey: "foreground_0"
    accentKey: root.infinite ? "red" : (root.finiteShown ? "yellow" : "")
    size: 15
    opacity: root.fade
    visible: opacity > 0
  }

  // Left click steps forward through the durations, right click steps
  // backward, middle click releases the inhibit - each pick restarts the
  // countdown immediately from the new target.
  fillButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
  onClicked: mouse => {
    if (mouse.button === Qt.LeftButton) Registry.call("inhibitor", "cycleForward")
    else if (mouse.button === Qt.RightButton) Registry.call("inhibitor", "cycleBackward")
    else if (mouse.button === Qt.MiddleButton) Registry.call("inhibitor", "stop")
  }

  // Active explains the control; a finite inhibit adds the live
  // countdown. Infinite stays generic with no suffix.
  ToolTipBind {
    active: root.active && root.hovered
    text: root.infinite ? "Inhibiting sleep"
      : "Inhibiting sleep for " + root.formatted
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }
}
