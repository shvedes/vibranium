pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
// Aliased: this component is itself called PasswordBox and exports that name
// from qs.common, so an unaliased import would let a bare `TextField` resolve
// back to the wrapper instead of to the Qt control.
import QtQuick.Controls as Ctl
import qs.common
import "../motion/CapsJitter.js" as CapsJitter

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

  // CapsLock state, handed in by the consumer (Keyboard.capsOn). The box
  // itself only reports the key press through capsToggled(); the on/off
  // state lives with the shell's keyboard service. While caps is on every
  // echo glyph jumps on its own random rhythm, so the field is the indicator
  // and no chip has to sit above it.
  property bool capsActive: false

  // Per-glyph jump state for capsActive. A tick is a new random pose; glyph
  // i's pose is derived from the tick and its index, so a tick moves every
  // glyph without touching the model and delegates never rebuild.
  property int capsTick: 0

  // This box is CapsJitter's reference field (44px box, 24px echo), so its
  // share of the reference pose is exactly 1.
  readonly property real _capsScale: 1

  function jitterX(i) {
    if (!MotionPolicy.enabled || !root.capsActive) return 0
    return CapsJitter.offsetX(i, root.capsTick, root._capsScale)
  }

  function jitterY(i) {
    if (!MotionPolicy.enabled || !root.capsActive) return 0
    return CapsJitter.offsetY(i, root.capsTick, root._capsScale)
  }

  // Irregular cadence: a steady metronome reads as a wobble, while the point
  // is a scramble that changes its own rhythm. The effect exists only while
  // the global animation switch is on: with animations off the field stays
  // still rather than jumping in one frame.
  Timer {
    id: capsJitter

    repeat: true
    running: MotionPolicy.enabled && root.capsActive && root.animated
      && passwordInput.text.length > 0
    interval: 110
    onTriggered: {
      root.capsTick += 1
      interval = CapsJitter.nextInterval(root._capsScale)
    }
  }

  // probe hook: capsTimer -> read by textinput.qml for
  // tick sampling; inert in production
  readonly property alias capsTimer: capsJitter

  // Silences border fades and the shake for minimal setups.
  property bool animated: true

  // One clock for the failure-feedback family. The border fade, the glyph
  // row's recentre and every shake leg read this token, so a change to it
  // moves the whole choreography instead of one leg at a time. The fractions
  // keep the original 45/80/60/50 leg shape at Ui.fastMs.
  readonly property int feedbackMs: Ui.fastMs
  readonly property int shakeOutMs: Math.round(feedbackMs * 3 / 8)
  readonly property int shakeBackMs: Math.round(feedbackMs * 2 / 3)
  readonly property int shakeSettleMs: Math.round(feedbackMs / 2)
  readonly property int shakeHomeMs: Math.round(feedbackMs * 5 / 12)

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
  // Every real key press, including modifiers and keys the field swallows.
  signal keyPressed()
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

  // The user-edit path for Ctrl+U / Alt+U. Carries the same contract as
  // onTextEdited so a consumer that mirrors the secret only through edited()
  // learns about the wipe: one edited("") carrying the empty value, with the
  // failure flash ended. clear() stays a silent lifecycle wipe for a fresh
  // prompt, which the polkit dialog relies on.
  function eraseLine() {
    root.clearFailure()
    passwordInput.text = ""
    root.edited("")
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
    id: borderFadeBehavior

    // Both switches gate the fade; neither owns a clock. ColorAnim carries
    // the policy duration and hands its target back on stop, which a raw
    // ColorAnimation would not do.
    enabled: root.animated && MotionPolicy.enabled
    ColorAnim {
      id: borderFadeColorAnim
      duration: MotionPolicy.duration(root.feedbackMs)
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

  // The border now fades on the one feedback clock under both switches.
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
      duration: root.shakeOutMs
    }
    NumberAnimation {
      target: shakeX
      property: "x"
      to: 6
      duration: root.shakeBackMs
    }
    NumberAnimation {
      target: shakeX
      property: "x"
      to: -4
      duration: root.shakeSettleMs
    }
    NumberAnimation {
      target: shakeX
      property: "x"
      to: 0
      duration: root.shakeHomeMs
    }
  }

  Ctl.TextField {
    id: passwordInput

    // Logic-only field: focus, keys, selection and clipboard masking live
    // here while the glyphs themselves render in displayRow below, which
    // can animate each symbol landing - something a text control cannot do.
    anchors.fill: parent
    // Reserve the leading glyph's slot: the echo centers in what remains,
    // so a long secret stops at the icon instead of painting over it.
    anchors.leftMargin: fieldIcon.visible ? Ui.m + fieldIcon.size + 8 : 20
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
    // `busy` names the authentication-in-flight state, so it gates the field
    // it names. Both in-tree consumers also bind `enabled` to the same state,
    // so this is defence in depth rather than a behavior change for them - but
    // a consumer that sets busy alone must not keep taking keystrokes and a
    // submitted() for the secret being authenticated. Root enabled still wins,
    // so an explicitly disabled box stays disabled.
    enabled: root.enabled && !root.busy
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
      root.keyPressed()
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
        root.eraseLine()
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
        enabled: MotionPolicy.enabled
        NumberAnimation {
          id: rowRecenterAnim
          duration: root.feedbackMs
          easing.type: Easing.OutCubic
        }
      }

      // Each new symbol nudges the settled ones aside, and this is that
      // nudge. `glyphRow.x` is a position and carries nothing about what is
      // in the row - not the count, not the glyphs, not the echo.

      Repeater {
        model: glyphModel

        Item {
          id: glyphCell

          required property int index

          // Which face is in front, and the character behind it. A departing
          // glyph's delegate is rebound against the new, shorter text before
          // the model trims it; the guard keeps the frame silent while the
          // row is already on its way out.
          readonly property bool masked: root.hidden && !root.revealed
          readonly property string plainText: index < passwordInput.text.length
            ? passwordInput.text[index] : ""
          // The symbol this cell currently paints, for readers that measure
          // the row instead of sampling its two faces.
          readonly property string glyphChar: masked ? Ui.passwordEcho : plainText

          // The cell takes the width of the face in front, tweened, so the
          // row's eased recentring follows the symbol fading in instead of
          // snapping to its measure.
          width: masked ? maskGlyph.implicitWidth : plainGlyph.implicitWidth
          height: Math.max(maskGlyph.implicitHeight, plainGlyph.implicitHeight)

          Behavior on width {
            enabled: MotionPolicy.enabled && root.animated
            NumberAnimation {
              duration: Ui.fastMs
              easing.type: Easing.OutCubic
            }
          }

          // Caps on: the tick is the only source of the pose. The one shared
          // leg smooths between two poses and deliberately outlives a tick,
          // so consecutive poses blend - the original look. A transform
          // only, so the row's measure and its eased recentring never see the
          // motion.
          property real jx: root.jitterX(glyphCell.index)
          property real jy: root.jitterY(glyphCell.index)

          Behavior on jx {
            enabled: MotionPolicy.enabled && root.animated
            NumberAnimation {
              id: capsJxAnim
              duration: MotionPolicy.duration(CapsJitter.poseMs())
              easing.type: Easing.OutCubic
            }
          }
          Behavior on jy {
            enabled: MotionPolicy.enabled && root.animated
            NumberAnimation {
              id: capsJyAnim
              duration: MotionPolicy.duration(CapsJitter.poseMs())
              easing.type: Easing.OutCubic
            }
          }
          // probe hook: poseDuration -> read by textinput.qml for
          // capsPose.behaviorMs; inert in production
          readonly property int poseDuration: capsJxAnim.duration
          // probe hook: poseDurationY -> read by textinput.qml for
          // capsPose.behaviorYMs; inert in production
          readonly property int poseDurationY: capsJyAnim.duration

          transform: Translate {
            x: glyphCell.jx
            y: glyphCell.jy
          }

          // Two faces in one slot: the mask and the character crossfade on
          // the reveal switch, so a mode change is a fade rather than a
          // frame of different glyphs.
          Text {
            id: maskGlyph

            anchors.centerIn: parent
            text: Ui.passwordEcho
            opacity: glyphCell.masked ? 1 : 0
            color: Theme.color("foreground_0")
            font.pixelSize: 24
            font.family: Ui.fontFamily

            Behavior on opacity {
              enabled: MotionPolicy.enabled && root.animated
              NumberAnimation {
                duration: Ui.fastMs
                easing.type: Easing.OutCubic
              }
            }
          }

          Text {
            id: plainGlyph

            anchors.centerIn: parent
            text: glyphCell.plainText
            opacity: glyphCell.masked ? 0 : 1
            color: Theme.color("foreground_0")
            font.pixelSize: 24
            font.family: Ui.fontFamily

            Behavior on opacity {
              enabled: MotionPolicy.enabled && root.animated
              NumberAnimation {
                duration: Ui.fastMs
                easing.type: Easing.OutCubic
              }
            }
          }
        }
      }
    }
  }

  // probe hook: borderFade -> read by textinput.qml for gate flag; inert in production
  readonly property alias borderFade: borderFadeBehavior
  // probe hook: borderFadeAnim -> read by textinput.qml for
  // feedback borderMs; inert in production
  readonly property alias borderFadeAnim: borderFadeColorAnim
  // probe hook: recenterAnim -> read by textinput.qml for
  // feedback rowMs; inert in production
  readonly property alias recenterAnim: rowRecenterAnim
  // probe hook: shakeXOffset -> read by textinput.qml for
  // feedback shake peak; inert in production
  readonly property alias shakeXOffset: shakeX.x
  // probe hook: glyphRowX -> read by textinput.qml for
  // feedback row motion; inert in production
  readonly property alias glyphRowX: glyphRow.x

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

  // Leading glyph: the field's own mark at the far left of the box, sharing
  // the left chrome slot the menu fields use for their role icon. It never
  // fades out - the echo owns the middle of the box, the glyph owns its left
  // edge, and a long secret may not cover it. A revealed echo trades the
  // mark for the eye through the shared crossfade, so the reveal state is
  // read on the field itself instead of on a badge beside it.
  CrossfadeIcon {
    id: fieldIcon

    anchors.left: parent.left
    anchors.leftMargin: Ui.m
    anchors.verticalCenter: parent.verticalCenter
    size: 16
    name: root.revealed && root.iconName !== "" ? "eye" : root.iconName
    colorKey: root.iconColorKey
    visible: root.iconName !== ""
  }
}
