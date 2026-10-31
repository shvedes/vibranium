pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import qs.features.menu
import "MenuLib.js" as MenuLib

// Numeric-only editor box: [-] validated field [+] living inside a
// bordered input-height rectangle. The validator rejects any non-numeric
// keystroke; commit clamps to [minimum, maximum]. The unit suffix is
// painted beside the value and is not part of the field's text, which is
// what keeps the caret out of it by construction and the filter alive:
//
//   A QValidator only applies while the text ALREADY in the field passes it.
//   Seed a DoubleValidator field with "5min" and it accepts every keystroke
//   - letters, dots, all of it - because the string it is validating is one
//   the validator rejects; seed the same field with "5" and it refuses a
//   letter. A read-only unit living inside the text therefore switches the
//   numeric filter off for the entire edit, silently, on every row that
//   declares a unit. The unit is chrome here so the field only ever holds a
//   value, and "numeric only" is the validator's ordinary job.
Rectangle {
  id: root

  property real value: 0
  property int decimals: 0
  property real minimum: 0
  property real maximum: 100
  property real stepSize: 1
  // Unit shown inside the field, right of the value ("60 fps"). Drawn, never
  // typed: the field's text is the value alone.
  property string unitSuffix: ""

  signal accepted(real value)
  signal escaped()
  // Raised on empty/invalid commits - the row shows a fading error.
  signal invalid(string message)
  // Live step: the picker stepped via +/- keys or buttons but has not
  // committed yet. The row writes it through to the store immediately (no
  // onChange - that fires once on commit), so live previews bound to the
  // setting (OSD offset, Media OSD offset) fire while the dropdown is open,
  // exactly as they do when stepping the closed row.
  signal stepped(real value)

  property alias text: input.text

  function grabFocus() {
    // Guarded: the watchdog re-asserts focus periodically, and a blind
    // selectAll here kept wiping whatever the user had typed.
    if (input.activeFocus) return
    input.forceActiveFocus()
    // The field holds the value and nothing else, so all of it is user data.
    input.selectAll()
  }

  function formatted(v) {
    return v.toFixed(decimals)
  }

  function step(direction) {
    let next = MenuLib.quantize(MenuLib.clamp(value + direction * stepSize,
      minimum, maximum))
    if (next === value) return
    value = next
    // The caret cannot outrun the text it lives in - the number is the whole
    // text - so its position comes back as a plain offset.
    const pos = Math.min(input.cursorPosition, input.text.length)
    const before = input.text
    input.text = formatted(next)
    input.cursorPosition = Math.min(pos, input.text.length)
    // Writing the text already emits recovered() through onTextChanged, which
    // is why this is not unconditional: an unconditional call fired the signal
    // twice on every step. It is still needed in the one case where nothing
    // fires - a quantised step that renders to the text the field already
    // held - or a stale "not a number" message would outlive the fix.
    if (input.text === before) recovered()
    root.stepped(next)
  }

  // A valid body after an invalid one clears the message.
  signal recovered()

  function bodyValid() {
    return MenuLib.leadingNumber(String(input.text).trim()) !== null
  }

  function commit() {
    const body = String(input.text).trim()
    // Empty means the user erased everything: silently discard and close.
    if (body === "") {
      escaped()
      return
    }
    // Leading-number parse tolerates trailing junk after the digits.
    const typed = MenuLib.leadingNumber(body)
    if (typed === null) {
      // Unsupported data: surface the error AND restore the actual
      // value so the field is never left holding garbage.
      invalid("That is not a number. Use digits with an optional decimal "
        + "point, like 0.05 - or press Esc to cancel.")
      input.text = formatted(value)
      input.cursorPosition = input.text.length
      return
    }
    let next = MenuLib.quantize(MenuLib.clamp(typed, minimum, maximum))
    accepted(next)
  }

  height: Ui.inputHeight
  radius: RoundingPolicy.radius
  color: Theme.color("background_1")
  border.width: input.activeFocus ? 1 : 0
  border.color: Theme.color("accent")

  Behavior on border.width {
    Glide {}
  }

  IconButton {
    id: minus

    x: Ui.s
    anchors.verticalCenter: parent.verticalCenter
    glyph: "-"
    onClicked: root.step(-1)
  }

  TextInput {
    id: input

    anchors.left: minus.right
    anchors.right: plus.left
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Ui.s
    anchors.rightMargin: Ui.s
    verticalAlignment: TextInput.AlignVCenter
    horizontalAlignment: TextInput.AlignHCenter
    clip: true
    color: Theme.color("foreground_0")
    selectionColor: Theme.color("accent")
    selectedTextColor: Theme.color("background_0")
    font.pixelSize: Ui.fontM
    font.family: Ui.fontFamily
    // The unit's share of the pair's centring. The input centres its own text
    // inside what is left of the box once this is taken off the right, so the
    // number and the unit read as the one centred run they read as when the
    // unit was part of the text - rather than the number sitting dead centre
    // with the unit hanging off it.
    rightPadding: root.unitSuffix !== "" ? suffixText.width : 0
    validator: DoubleValidator {
      locale: "C"
      notation: DoubleValidator.StandardNotation
      decimals: root.decimals > 0 ? root.decimals : 4
    }

    onTextChanged: {
      if (root.bodyValid()) root.recovered()
    }

    // +/- never reach the validator as text - use them to step.
    Keys.onPressed: event => {
      switch (event.key) {
        case Qt.Key_Plus:
        case Qt.Key_Equal:
          event.accepted = true
          root.step(1)
          return
        case Qt.Key_Minus:
        case Qt.Key_Underscore:
          event.accepted = true
          root.step(-1)
          return
      }
    }
    Keys.onReturnPressed: event => {
      event.accepted = true
      root.commit()
    }
    Keys.onEnterPressed: event => {
      event.accepted = true
      root.commit()
    }
    Keys.onEscapePressed: event => {
      event.accepted = true
      root.escaped()
    }
  }

  // The unit, drawn rather than typed. Same face and tone as the value it
  // follows, and placed immediately behind the digits so the two read as the
  // one centred run they read as when the unit was part of the text - which
  // is also why the value's own width has to be measured: the input does not
  // publish it, and the unit's position is a function of it.
  TextMetrics {
    id: valueWidth

    font: input.font
    text: input.text
  }

  Text {
    id: suffixText

    // Placed, not anchored: where the unit lands is the number's own left
    // edge plus its width, and the input's own centring is what puts the
    // number there - so this follows the digits instead of guessing at them.
    // Clamped to the field's own span so a value too wide for the box cannot
    // push the unit out over the stepper.
    x: Math.min(
      input.x + (input.width - input.rightPadding - valueWidth.width) / 2 + valueWidth.width,
      input.x + input.width - suffixText.width)
    anchors.verticalCenter: parent.verticalCenter
    visible: root.unitSuffix !== "" && width > 0
    text: root.unitSuffix
    color: Theme.color("foreground_0")
    font.pixelSize: Ui.fontM
    font.family: Ui.fontFamily
  }

  IconButton {
    id: plus

    anchors.right: parent.right
    anchors.rightMargin: Ui.s
    anchors.verticalCenter: parent.verticalCenter
    glyph: "+"
    onClicked: root.step(1)
  }
}
