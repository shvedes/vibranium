pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
// Aliased: this component is itself called PasswordBox and exports that name
// from qs.common, so an unaliased import would let a bare `TextField` resolve
// back to the wrapper instead of to the Qt control.
import QtQuick.Controls as Ctl
import qs.common

// Shared authentication field backing the lockscreen and the polkit dialog.
// A flat 320x44 box whose border tells the state story (accent focused,
// yellow busy, red failure) wrapped around a centered asterisk-spaced input.
// The box owns every visual - echo sizing, placeholder typography, shake,
// focus - while consumers wire behavior through the signals.
Rectangle {
  id: root

  // Border state drivers; failure wins over busy wins over focus.
  property bool busy: false

  // Whether typed characters render masked (Ui.passwordEcho).
  property bool hidden: true

  // Ctrl+H toggle layered over `hidden`: echo stays masked until both say
  // so, so consumer bindings keep working untouched. clear() drops it -
  // fresh prompts never inherit plain text.
  property bool revealed: false

  // Silences border fades and the shake for minimal setups.
  property bool animated: true

  // Shown while empty; failureText replaces it while failure lasts.
  property string placeholder: "PASSWORD"
  property string failureText: "Wrong password!"

  // Optional themed glyph in the far-left chrome slot of the box - the
  // slot the menu fields give their role icon. It names the field, so it
  // stays put instead of yielding to the text like a placeholder does:
  // an empty name draws no glyph and the box is unchanged.
  property string iconName: ""
  // Palette key the glyph is recolored with.
  property string iconColorKey: "foreground_1"

  // Failure feedback window, shared so every consumer flashes for the same
  // duration; fail() arms it, typing or clearFailure() ends the flash early.
  property int failureMs: 1400
  readonly property bool failure: failureTimer.running

  // Light the red border, show failureText in place of the placeholder and
  // shake. Multi-screen consumers call this on every surface's box.
  function fail() {
    root.revealed = false
    root.shake()
    failureTimer.restart()
  }

  function clearFailure() {
    failureTimer.stop()
  }

  // Ctrl+H flips the echo between masked and plain characters.
  function toggleReveal() {
    root.revealed = !root.revealed
  }

  Timer {
    id: failureTimer

    interval: root.failureMs
  }

  property alias text: passwordInput.text
  readonly property alias input: passwordInput
  readonly property bool focused: passwordInput.activeFocus

  // Enter with content in the field.
  signal submitted(string text)
  // Real keystrokes only - programmatic text syncs never fire this.
  signal edited(string text)
  // Escape; consumers decide whether that means wipe or cancel.
  signal cancelled()
  // CapsLock pressed; consumers without a caps indicator ignore it.
  signal capsToggled()
  // Left/Right arrows, forwarded only when the consumer opted in via
  // arrowNavigation; otherwise the caret-swallow switch eats them (spec 19).
  property bool arrowNavigation: false
  signal navigate(int dir)

  function clear() {
    passwordInput.text = ""
    root.revealed = false
  }

  function grabFocus() {
    passwordInput.forceActiveFocus()
  }

  function shake() {
    if (!root.animated) return
    shakeAnim.restart()
  }

  width: 320
  height: 44
  radius: RoundingPolicy.radius
  color: Ui.tint("background_1", 0.82)
  border.width: 1
  border.color: root.failure ? Theme.color("red")
                             : (root.busy ? Theme.color("yellow")
                                          : (passwordInput.activeFocus ? Theme.color("accent")
                                                                       : Theme.color("background_3")))

  Behavior on border.color {
    enabled: root.animated
    ColorAnimation {
      duration: 150
    }
  }

  // ---- DEBUG: geometry and focus only. ----
  //
  // This is the secret field. `text` is a password, and no field on this
  // object may ever be a string that came out of it - not the echo, not the
  // glyph count, not the failure text, not the length of any of them. What
  // is left is the box itself: where it is, how big it is, whether it holds
  // focus, whether the echo is masked, and whether it is being asked to
  // fail. Every one of those is a layout or a lifecycle fact, and every one
  // of them is what a reader needs to tell "the prompt is on the wrong
  // screen" from "the prompt is the wrong size".

  // The border and the echo both move on a 150ms colour tween that reads
  // neither the global motion policy nor the field's own `animated` switch.
  // `border.color` is a grouped property with no change signal of its own, so
  // the tween it runs is not observable per frame from here; the shake
  // translation below and the glyph row's recentring are, and they are what
  // a typing session actually looks like.
  transform: Translate {
    id: shakeX

    // The shake itself, per frame. A translation carries no content of any
    // kind, which is what makes it safe to report from a field whose other
    // moving part is a password.
  }

  SequentialAnimation {
    id: shakeAnim

    NumberAnimation {
      target: shakeX
      property: "x"
      to: -6
      duration: 45
    }
    NumberAnimation {
      target: shakeX
      property: "x"
      to: 6
      duration: 80
    }
    NumberAnimation {
      target: shakeX
      property: "x"
      to: -4
      duration: 60
    }
    NumberAnimation {
      target: shakeX
      property: "x"
      to: 0
      duration: 50
    }
  }

  Ctl.TextField {
    id: passwordInput

    // Logic-only field: focus, keys, selection and clipboard masking live
    // here while the glyphs themselves render in displayRow below, which
    // can animate each symbol landing - something a text control cannot do.
    anchors.fill: parent
    anchors.leftMargin: 20
    anchors.rightMargin: 20
    // Nothing of the control is seen, so its chrome is switched off rather
    // than painted over the box: the shell draws every visible pixel, and the
    // only thing the control contributes here is the text it will not show.
    background: null
    padding: 0
    leftPadding: 0
    rightPadding: 0
    topPadding: 0
    bottomPadding: 0
    verticalAlignment: TextInput.AlignVCenter
    horizontalAlignment: TextInput.AlignHCenter
    clip: true
    focus: true
    // Kept for its clipboard-masking semantics; rendering ignores it.
    echoMode: (root.hidden && !root.revealed) ? TextInput.Password : TextInput.Normal
    // The style installs an editing context menu whose Cut and Copy write the
    // secret to the clipboard directly, outside the shell's clipboard policy,
    // and whose Paste would inject into a field the shell is about to
    // authenticate against. A field whose whole purpose is that the secret
    // does not leave keeps the keyboard path and loses the menu. InputField
    // keeps the menu, because its text is the user's own and is expected to be
    // pasted and copied.
    Ctl.ContextMenu.menu: null
    // Qt re-enables cursorVisible on focus/edit events, so hiding the
    // caret needs a zero-size delegate rather than the property alone.
    cursorDelegate: Item {}
    inputMethodHints: Qt.ImhSensitiveData
    color: "transparent"
    selectionColor: Theme.color("accent")

    onTextEdited: {
      root.clearFailure()
      root.edited(text)
    }

    onAccepted: root.submitted(text)

    Keys.onPressed: event => {
      // No caret exists here (cursorDelegate is empty), so caret-motion
      // keys would only move the invisible insertion point and corrupt
      // later typing. Swallow them with their modifiers - unless the
      // consumer opted into arrow navigation, which claims Left/Right
      // (and no other key) for itself.
      if (root.arrowNavigation && event.key === Qt.Key_Left) {
        root.navigate(-1)
        event.accepted = true
        return
      }
      if (root.arrowNavigation && event.key === Qt.Key_Right) {
        root.navigate(1)
        event.accepted = true
        return
      }
      switch (event.key) {
        case Qt.Key_Left:
        case Qt.Key_Right:
        case Qt.Key_Home:
        case Qt.Key_End:
        case Qt.Key_Up:
        case Qt.Key_Down:
          event.accepted = true
          return
      }
      if (event.key === Qt.Key_CapsLock && !event.isAutoRepeat) {
        root.capsToggled()
      } else if (event.key === Qt.Key_Escape) {
        root.cancelled()
        event.accepted = true
      } else if (event.key === Qt.Key_U && ((event.modifiers & Qt.ControlModifier) || (event.modifiers & Qt.AltModifier))) {
        passwordInput.text = ""
        event.accepted = true
      } else if (event.key === Qt.Key_H && (event.modifiers & Qt.ControlModifier)) {
        root.toggleReveal()
        event.accepted = true
      }
    }
  }

  // Per-glyph display mirroring passwordInput.text. The count lives in a
  // ListModel so typing mutates it incrementally - a plain integer Repeater
  // model would tear the whole row down on every press. Glyphs render
  // statically; only their movement animates, through the row's eased
  // recentring below.
  Item {
    id: displayRow

    anchors.fill: passwordInput
    clip: true

    function syncModel() {
      const len = passwordInput.text.length
      while (glyphModel.count > len) glyphModel.remove(glyphModel.count - 1)
      while (glyphModel.count < len) glyphModel.append({})
    }

    Component.onCompleted: syncModel()

    ListModel {
      id: glyphModel
    }

    Connections {
      target: passwordInput

      function onTextChanged() {
        displayRow.syncModel()
      }
    }

    Row {
      id: glyphRow

      // Manual centring instead of anchors.centerIn so the recentering
      // shift is a plain property: each new symbol nudges the settled ones
      // aside in one eased glide, while the glyphs themselves render still.
      x: (parent.width - width) / 2
      anchors.verticalCenter: parent.verticalCenter
      spacing: 6

      Behavior on x {
        NumberAnimation {
          duration: 150
          easing.type: Easing.OutCubic
        }
      }

      // Each new symbol nudges the settled ones aside, and this is that
      // nudge. `glyphRow.x` is a position and carries nothing about what is
      // in the row - not the count, not the glyphs, not the echo.

      Repeater {
        model: glyphModel

        Text {
          required property int index

          text: (root.hidden && !root.revealed) ? Ui.passwordEcho : passwordInput.text[index]
          color: Theme.color("foreground_0")
          font.pixelSize: 24
          font.family: Ui.fontFamily
        }
      }
    }
  }

  Text {
    anchors.fill: passwordInput
    visible: passwordInput.text.length === 0
    verticalAlignment: TextInput.AlignVCenter
    horizontalAlignment: TextInput.AlignHCenter
    elide: Text.ElideRight
    text: root.failure ? root.failureText : root.placeholder
    color: Ui.tint("foreground_1", 0.5)
    font.pixelSize: root.failure ? 14 : 12
    font.family: Ui.fontFamily
    font.bold: !root.failure
    font.letterSpacing: root.failure ? 0 : 6
  }

  // Leading glyph: the field's own mark, at the far left of the box. It
  // shares the left chrome slot the menu fields use for their role icon,
  // and it never fades out - the echo owns the middle of the box, the
  // glyph owns its left edge, and a long secret may not cover it.
  Icon {
    id: fieldIcon

    anchors.left: parent.left
    anchors.leftMargin: Ui.m
    anchors.verticalCenter: parent.verticalCenter
    size: 16
    name: root.iconName
    colorKey: root.iconColorKey
    visible: root.iconName !== ""
  }

  // Reveal badge: floats off the box's left edge while Ctrl+H has flipped
  // the echo to plain text. Eye glyph is bare rectangles: the lens is a
  // rounded square rotated 45deg then stretched horizontally, with a solid
  // round pupil.
  Rectangle {
    id: revealBadge

    anchors.right: root.left
    anchors.rightMargin: 12
    anchors.verticalCenter: root.verticalCenter
    height: root.height
    width: eyeGlyph.width + 24
    radius: RoundingPolicy.radius
    color: Ui.tint("purple", 0.08)
    border.width: 1
    border.color: Ui.tint("purple", 0.45)
    opacity: root.revealed ? 1 : 0

    transform: Translate {
      id: badgeRise

      // Hidden state sits pushed toward the box; revealing slides the
      // badge up into place instead of popping it.
      y: root.revealed ? 0 : 8

      Behavior on y {
        NumberAnimation {
          duration: 150
        }
      }
    }

    Behavior on opacity {
      NumberAnimation {
        duration: 150
      }
    }
    Behavior on anchors.bottomMargin {
      NumberAnimation {
        duration: 150
      }
    }

    Item {
      id: eyeGlyph

      anchors.centerIn: parent
      width: 21
      height: 13

      Rectangle {
        id: lens

        anchors.centerIn: parent
        width: 9
        height: 9
        radius: RoundingPolicy.radius
        antialiasing: true
        color: "transparent"
        border.width: 1
        border.color: Theme.color("purple")
        transform: [
          Rotation { origin.x: 4.5; origin.y: 4.5; angle: 45 },
          Scale { origin.x: 4.5; origin.y: 4.5; xScale: 1.65 }
        ]
      }

      Rectangle {
        anchors.centerIn: parent
        width: 5
        height: 5
        radius: RoundingPolicy.radius
        antialiasing: true
        color: Theme.color("purple")
      }
    }
  }
}
