pragma ComponentBehavior: Bound

import QtQuick
// Aliased because this component is itself called Button and exports that
// name from qs.common: an unaliased import would make the bare name resolve
// back to the wrapper, which instantiates the wrapper with none of the native
// behavior and reports no error at all.
import QtQuick.Controls as Ctl
import Quickshell.Widgets
import qs.common

// Push button with three variants:
//   primary - accent fill, high emphasis
//   outline - accent border and label on transparent ground
//   ghost   - no chrome until pressed
//
// The native button owns the interaction: press and hover state, the enabled
// gate, focus, and keyboard activation. This wrapper owns the shell's side of
// it - the variant tokens, the accent, the label ink, the icon/label row, the
// press scale, and the animation kill switch.
Item {
  id: root

  // "primary" | "outline" | "ghost"
  property string variant: "outline"
  property string label: ""
  // Optional theme icon name rendered before the label.
  property string icon: ""
  // Fill/hover/press hue for the "primary" variant. Defaults to the
  // theme accent; consumers opt into a semantic color (green confirm,
  // blue refresh) without leaving the shared primitive.
  property color accentColor: Ui.solid("accent")
  // Label ink for the outline/ghost variants (primary always knocks out
  // in the background color). Defaults to the theme foreground; overlays
  // on a fixed dark scrim pass white so the label survives any theme.
  property color labelColor: Ui.solid("foreground_0")
  // The ground. Declared here rather than read off the native control's
  // background so a consumer that assigns `color:` replaces the shell's fill
  // instead of assigning to a property the wrapper does not declare.
  property color color: {
    if (root.variant === "primary") {
      return root.pressed ? Qt.darker(root.accentColor, 1.2)
        : root.hovered ? Qt.lighter(root.accentColor, 1.08) : root.accentColor
    }
    if (root.pressed) return Ui.tint("accent", 0.12)
    if (root.hovered) return Ui.tint("accent", 0.08)
    return "transparent"
  }
  property real radius: RoundingPolicy.radius
  // Horizontal padding either side of the icon/label row, which is what sets
  // the implicit width. Ui.l is the panel-row answer; a dense surface holding
  // short labels of its own (a notification card's action buttons) lowers it.
  property int padH: Ui.l
  // Kill switch: disables color/scale tweens; the final state still
  // lands instantly. Defaults on for standalone consumers off the menu.
  property bool animationsEnabled: true

  readonly property bool pressed: btn.pressed
  // Qt keeps hovered true over a disabled control, so the shell's ground
  // reads the gated state rather than the raw one.
  readonly property bool hovered: btn.hovered && root.enabled
  readonly property bool _focused: btn.activeFocus

  signal clicked()

  implicitWidth: row.implicitWidth + 2 * root.padH
  implicitHeight: Ui.buttonHeight
  enabled: true
  opacity: root.enabled ? 1 : 0.45

  scale: root.pressed ? 0.97 : 1

  // Linear on purpose - an eased press scale feels laggy.
  Behavior on scale {
    enabled: root.animationsEnabled
    NumberAnimation {
      duration: Ui.fastMs
    }
  }

  // The press scale, per frame. The Behavior above tweens it and the frame
  // loop produces the values, so this is where a press is visible as a curve
  // rather than as two end states.

  // The interaction edges the native control reports. The wrapper already
  // gates its own chrome on them - `hovered` reads through `enabled`, because
  // Qt keeps hovering a disabled control - so these lines are the record of
  // what that gate saw rather than a parallel state machine. The label is
  // shell chrome declared in the source, not anything the user typed.

  on_FocusedChanged: {
  }

  // The wrapper's OWN clicked signal, not the native one: a consumer's
  // handler is attached here, so this is the edge a consumer of the
  // primitive sees. The native edge re-emits into it from `btn` below.

  // The label is the button's width, so a width change IS a label or icon
  // change - the layout pass a consumer of this primitive actually sees.

  Ctl.Button {
    id: btn

    anchors.fill: parent
    // The chrome is full-bleed: the shell's own background and content
    // items replace the style's, so no style padding may sit between them.
    padding: 0
    enabled: root.enabled
    // Panels own Tab for their own row traversal (MenuPanel, PowerMenuPanel,
    // LauncherPanel and ClipboardPanel all route it to a selection move), so
    // the button takes focus but is not a tab stop: a click still focuses it
    // and Space/Enter activate it.
    activeFocusOnTab: false
    onClicked: root.clicked()

    background: Rectangle {
      color: root.color
      radius: root.radius
      border.width: root.variant === "outline" ? 1 : 0
      border.color: !root.enabled || root.variant !== "outline"
        ? "transparent" : (root.hovered ? Ui.tint("accent", 0.7) : Ui.tint("accent", 0.45))

      Behavior on color {
        enabled: root.animationsEnabled
        ColorAnim {}
      }
      Behavior on border.color {
        enabled: root.animationsEnabled
        ColorAnim {}
      }

      // Focus is Qt's, the ring is the shell's: a control that can take
      // focus has to show it, and the ghost variant carries no other chrome
      // that could. Drawn inside the button, so no geometry moves.
      Rectangle {
        anchors.fill: parent
        z: 1
        color: "transparent"
        border.width: root._focused ? 1 : 0
        border.color: Ui.tint("accent", 0.9)

        Behavior on border.color {
          enabled: root.animationsEnabled
          ColorAnim {}
        }
      }
    }

    contentItem: Item {
      Row {
        id: row

        anchors.centerIn: parent
        spacing: Ui.s

        IconImage {
          id: glyph

          visible: root.icon !== ""
          anchors.verticalCenter: parent.verticalCenter
          width: visible ? 14 : 0
          height: visible ? 14 : 0
          source: root.icon
          asynchronous: true
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.label
          visible: root.label !== ""
          color: root.variant === "primary" ? Theme.color("background_0") : root.labelColor
          font.pixelSize: Ui.fontS
          font.family: Ui.fontFamily
          font.bold: root.variant === "primary"
          textFormat: Text.PlainText
        }
      }
    }
  }
}
