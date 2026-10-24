pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.features.menu
import qs.common

// Expansion editor shell for range/number/text rows: the validating
// NumberPicker for numeric types, a free-form InputField for text, and
// the OK commit button beside either. Commit/validation/escape route
// OUT through signals - state ownership stays with the entry row and
// the Menu service.
//
// Focus asserts are no-ops once a field owns focus - re-selecting all
// on every watchdog tick made typing erase itself.
Item {
  id: root

  // Stage dispatch lives in Entry.qml (editorComp): isText and the numeric
  // bounds arrive per-stage for flow rows, per-item otherwise. This shell
  // renders whatever it is given and stays stage-agnostic.
  property bool isText: false
  property string placeholder: ""
  // Seed applied once at creation; later edits flow through signals.
  property string initialText: ""
  property real numericValue: 0
  property int decimals: 0
  property real minimum: 0
  property real maximum: 100
  property real stepSize: 1
  property string unitSuffix: ""

  // Raw field text on OK/Enter; the row parses and clamps.
  signal commit(string text)
  signal invalid(string message)
  signal recovered()
  signal escaped()
  // Live numeric step from the picker (see NumberPicker.stepped): the row
  // persists it without firing onChange, so setting-bound previews update
  // while the editor is open.
  signal stepped(real value)

  implicitHeight: Math.max(root.isText ? editorField.implicitHeight : picker.height,
    okButton.height)

  function takeFocus() {
    if (root.isText) {
      if (editorField.focused) return
      editorField.grabFocus()
      editorField.input.selectAll()
    } else {
      picker.grabFocus()
    }
  }

  InputField {
    id: editorField

    visible: root.isText
    anchors.left: parent.left
    anchors.right: okButton.left
    anchors.leftMargin: Ui.m
    anchors.rightMargin: Ui.s
    anchors.verticalCenter: parent.verticalCenter
    placeholder: root.placeholder

    Component.onCompleted: {
      if (!root.isText || root.initialText === "") return
      text = root.initialText
    }
    onAccepted: text => root.commit(text)
    onEscaped: root.escaped()
  }

  NumberPicker {
    id: picker

    visible: !root.isText
    anchors.left: parent.left
    anchors.right: okButton.left
    anchors.leftMargin: Ui.m
    anchors.rightMargin: Ui.s
    anchors.verticalCenter: parent.verticalCenter
    value: root.numericValue
    decimals: root.decimals
    minimum: root.minimum
    maximum: root.maximum
    stepSize: root.stepSize
    unitSuffix: root.unitSuffix

    Component.onCompleted: {
      // The value, and nothing but the value: the unit is chrome the picker
      // draws, so a field seeded with "5 min" would be holding a string its
      // own validator rejects - and a QValidator stops applying to a field
      // whose text it already refuses, which is the whole numeric filter.
      text = root.numericValue.toFixed(root.decimals)
    }
    onAccepted: value => root.commit(String(value))
    onInvalid: msg => root.invalid(msg)
    onRecovered: root.recovered()
    onEscaped: root.escaped()
    onStepped: value => root.stepped(value)
  }

  Button {
    id: okButton

    anchors.right: parent.right
    anchors.rightMargin: Ui.m
    anchors.verticalCenter: parent.verticalCenter
    variant: "primary"
    label: "OK"
    onClicked: root.commit(root.isText ? editorField.text : picker.text)
  }
}
