pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import qs.features.menu
import qs.services as Core
import "../../common/text/Format.js" as Format

// Expansion editor shell for range/number/text rows: the validating
// NumberPicker for numeric types, a free-form InputField for text. Enter is
// the only commit gesture - a menu is keyboard driven, so a click button
// would duplicate the key without adding anything. Commit/validation/escape
// route OUT through signals - state ownership stays with the entry row and
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
  // Masked, revealable secret entry. The shared field keeps the echo and the
  // eye; this shell only forwards the one flag a flow stage declares.
  property bool sensitive: false
  property string placeholder: ""
  // Seed applied once at creation; later edits flow through signals.
  property string initialText: ""
  // Holds the engaged border while the hosting slot folds: the field drops
  // keyboard focus on collapse, but its accent must not blink out mid-close.
  property bool keepFocusAccent: false
  property real numericValue: 0
  property int decimals: 0
  property real minimum: 0
  property real maximum: 100
  property real stepSize: 1
  property string unitSuffix: ""

  // Raw field text on Enter; the row parses and clamps.
  signal commit(string text)
  signal invalid(string message)
  signal recovered()
  signal escaped()
  // Live numeric step from the picker (see NumberPicker.stepped): the row
  // persists it without firing onChange, so setting-bound previews update
  // while the editor is open.
  signal stepped(real value)

  // The field and the commit button are one control strip: both take the
  // shared button height, so neither edge overhangs the other.
  implicitHeight: Ui.buttonHeight

  // Enter routed through the panel (rather than straight into the field)
  // still commits the value the user sees, so a key hold or a click on the
  // row never folds the editor as if Escape had been pressed.
  function commitNow() {
    root.commit(root.isText ? editorField.text : picker.text)
  }

  function takeFocus() {
    if (root.isText) {
      if (editorField.focused) return
      editorField.grabFocus()
      editorField.input.selectAll()
    } else {
      picker.grabFocus()
    }
  }

  // The editor field is the one input that lives inside an entry dropdown,
  // so it takes the same elevation as the dropdown cursors and notices. Menu
  // search fields and island inputs stay flat - they opt in nowhere. An
  // inactive row never opens an editor, so no separate gate is needed here.
  SoftShadow { host: editorField }

  InputField {
    id: editorField

    visible: root.isText
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Ui.m
    anchors.rightMargin: Ui.m
    anchors.verticalCenter: parent.verticalCenter
    height: Ui.buttonHeight
    placeholder: root.placeholder
    sensitive: root.sensitive
    revealable: root.sensitive
    clearable: !root.sensitive
    // The network island's caps contract, narrowed to secret fields: the
    // shared field animates its echo from capsOn and reports a press back.
    capsActive: root.sensitive && Core.Keyboard.capsOn
    onCapsToggled: if (root.sensitive) Core.Keyboard.toggleCaps()
    // Tab and the caret keys are accepted here. With navigation left to Qt,
    // Tab moves focus to the menu's search field and the editor stays open
    // but unreachable by arrow or Enter.
    forwardNavigation: true
    engaged: root.keepFocusAccent
    onFocusedChanged: if (Menu.traceEnabled) Menu.trace("editor.focus", {
      focused: editorField.focused, engaged: editorField.engaged,
      keep: root.keepFocusAccent
    })
    onEngagedChanged: if (Menu.traceEnabled) Menu.trace("editor.engaged", {
      focused: editorField.focused, engaged: editorField.engaged,
      keep: root.keepFocusAccent
    })

    Component.onCompleted: {
      if (!root.isText || root.initialText === "") return
      text = root.initialText
    }
    // InputField emits accepted()/escaped() on the next turn, so this commit
    // never folds the slot while Enter/Escape is still being delivered (which
    // would re-fire the key on the list and re-open the row just committed).
    onAccepted: text => root.commit(text)
    onEscaped: root.escaped()
  }

  NumberPicker {
    id: picker

    visible: !root.isText
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Ui.m
    anchors.rightMargin: Ui.m
    anchors.verticalCenter: parent.verticalCenter
    height: Ui.buttonHeight
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
      text = Format.fixed(root.numericValue, root.decimals)
    }
    // NumberPicker defers its own key signals; see NumberPicker.qml.
    onAccepted: value => root.commit(String(value))
    onInvalid: msg => root.invalid(msg)
    onRecovered: root.recovered()
    onEscaped: root.escaped()
    onStepped: value => root.stepped(value)
  }

}
