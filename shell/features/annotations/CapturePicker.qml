pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type signal-handler-parameters
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.common

// Unified capture picker: one shortcut opens this modal overlay, two
// standalone icon buttons choose region or screen. No panel
// chrome - the buttons float centered over the dim veil, with the same
// hover language as the annotation toolbar. Keyboard: arrows/TAB move,
// Enter/Space picks, Esc/right-click backs out.
PanelWindow {
  id: picker

  signal chosen(string mode)
  signal cancelled()

  readonly property var modes: ["region", "screen"]
  readonly property var modeIcons: ({ region: "selection", screen: "monitor" })
  property int focusIndex: 0

  // Whether this surface moves at all: MotionPolicy.enabled, the one
  // shared compositor-wide switch (Hyprland Appearance -> Animations), so
  // the hover fades read the same answer as the rest of the shell instead
  // of a local copy of the key. The gate is `=== true`, which fails
  // closed: a build without the setting, or a settings backend that has
  // not answered yet, reads as "no motion" rather than "all motion".
  readonly property bool animOn: MotionPolicy.enabled

   function _activate(i) {
     picker.focusIndex = i
     picker.chosen(picker.modes[i])
   }

   function dismiss() {
     picker.visible = false
     veil.opacity = 0
     pickRow.visible = false
   }

   color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  anchors.left: true
  anchors.right: true
  anchors.top: true
  anchors.bottom: true

  WlrLayershell.namespace: "vibranium:screenshot-picker"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

  Rectangle {
    id: veil

    anchors.fill: parent
    color: "#000000"
    opacity: 0.55
  }

  Row {
    id: pickRow

        anchors.centerIn: parent
        spacing: 24

    Repeater {
      model: picker.modes

      delegate: Item {
        id: delegate

        required property string modelData
        required property int index

        property bool hovered: false
        property bool focused: picker.focusIndex === delegate.index
        activeFocusOnTab: true

        Accessible.role: Accessible.Button
        Accessible.name: delegate.modelData === "region" ? "Region capture" : "Screen capture"
        Accessible.onPressAction: picker._activate(delegate.index)

        width: 112
        height: 112

        Rectangle {
          anchors.fill: parent
          color: Ui.solid("background_1")
          border.color: delegate.focused ? Ui.solid("accent")
            : Ui.tint("foreground_1", delegate.hovered ? 0.7 : 0.35)
          border.width: delegate.focused ? 2 : 1
          Behavior on border.color {
            enabled: picker.animOn
            ColorAnim {}
          }
        }

        Icon {
          anchors.centerIn: parent
          name: picker.modeIcons[delegate.modelData]
          size: 56
        }

        HoverHandler {
          id: pickerHover
          onHoveredChanged: delegate.hovered = pickerHover.hovered
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: mouse => {
            if (mouse.button === Qt.RightButton) {
              picker.cancelled()
              return
            }
             picker._activate(delegate.index)
          }
        }
      }
    }
  }

  FocusScope {
    anchors.fill: parent
    focus: picker.visible
    onVisibleChanged: {
      if (visible) forceActiveFocus()
    }

    Keys.onEscapePressed: event => {
      picker.cancelled()
      event.accepted = true
    }
    Keys.onReturnPressed: event => {
      picker._activate(picker.focusIndex)
      event.accepted = true
    }
    Keys.onEnterPressed: event => {
      picker._activate(picker.focusIndex)
      event.accepted = true
    }
    Keys.onSpacePressed: event => {
      picker._activate(picker.focusIndex)
      event.accepted = true
    }
    Keys.onPressed: event => {
      const back = event.key === Qt.Key_Left
        || (event.key === Qt.Key_Backtab)
        || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))
      const fwd = event.key === Qt.Key_Right
        || (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier))
      if (fwd) {
        picker.focusIndex = (picker.focusIndex + 1) % picker.modes.length
        event.accepted = true
      } else if (back) {
        picker.focusIndex = (picker.focusIndex + picker.modes.length - 1) % picker.modes.length
        event.accepted = true
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.RightButton
    z: -1
    onClicked: picker.cancelled()
  }
}
