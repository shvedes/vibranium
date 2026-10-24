pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common

// Switch control: track with a sliding thumb - corners follow RoundingPolicy.
// The switch is state-externalized:
// `checked` is only ever READ here; clicks and toggle() emit toggled()
// with the requested state and the owner writes it back through its
// binding (service-backed rows keep their binding alive that way).
// `dimmed` fades the control for guard-disabled rows without breaking
// the visual link to the real state.
//
// The interaction stays here because the state does. A native Switch
// cannot hold state the owner owns: a click writes the control's own
// `checked`, and that write ends the binding which tracked the owner, so
// an owner which refuses or defers the write - an adapter that will not
// disable, a profile write that has not landed - leaves the control
// showing the request instead of the state, and the QML write which puts
// the binding back has to rebuild it on every click. Measured on a native
// Switch with `checked` bound to an owner holding false: one click, and
// the control reads true and stays there.
//
// Keys are owned a level up as well. The menu dispatches Space and Enter
// through one key sink and re-asserts focus to it on every path, so a
// focusable switch inside a row would take keys the panel routes to the
// current row, and no Toggle in the tree is a focus scope. Press and
// hover are unreached the same way: this control has no hover state to
// fill, and every consumer is a pointer-driven island or a menu row.
// Which is also why `checked` stays read-only here, `enabled_` keeps its
// name, and toggled(bool) carries the requested state in place of a
// native signal with no argument.
Rectangle {
  id: root

  property bool checked: false
  // When false, interaction does nothing; visuals keep following `checked`.
  property bool enabled_: true
  // Same as enabled_ but renders faded.
  property bool dimmed: false
  // Kill switch: disables the thumb/color tweens; state still lands
  // instantly. Defaults on for standalone consumers off the menu.
  property bool animationsEnabled: true

  signal toggled(bool checked)

  function toggle() {
    if (!root.enabled_ || root.dimmed) return
    root.toggled(!root.checked)
  }

  // Ui.toggleW, not a literal: a card that sizes a row from the model has to
  // reserve this pill's width before any row exists, and it reserves it
  // from the same token this widget draws itself from.
  implicitWidth: Ui.toggleW
  implicitHeight: 16
  radius: RoundingPolicy.radius
  color: root.checked ? Theme.color("accent") : Theme.color("background_3")
  opacity: root.dimmed ? 0.45 : 1

  Behavior on color {
    enabled: root.animationsEnabled
    ColorAnim {}
  }

  Rectangle {
    id: thumb

    x: root.checked ? root.width - width - 2 : 2
    anchors.verticalCenter: parent.verticalCenter
    width: 12
    height: 12
    radius: RoundingPolicy.radius
    color: root.checked ? Theme.color("background_0")
      : Ui.tint("foreground_1", 0.6)

    Behavior on x {
      enabled: root.animationsEnabled
      Glide { duration: Ui.fastMs }
    }
    Behavior on color {
      enabled: root.animationsEnabled
      ColorAnim {}
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.enabled_ && !root.dimmed
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      root.toggle()
    }
  }
}
