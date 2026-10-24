pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.services
// The linter reports the next line as an unused import and it is NOT: removing
// it turns every other module-internal reference in this file into 37
// unresolved-type warnings. The verdict comes from a heuristic that does not
// model a module resolving its own members, so the diagnostic is recorded in
// the suite's Info total rather than obeyed.
//
// Note the wording of the first line, which is load-bearing in a way that cost
// 13 warnings: a comment line STARTING with the tool's name is parsed as a lint
// directive, and every word in it is then read as a category name. Writing
// "The linter" instead is not a style preference here.
import qs.common
import qs.features.lock
import qs.features.polkit
import "PolkitTrace.js" as PolkitTrace

// Fullscreen polkit overlay, modeled on the lockscreen: every screen gets a
// dim layer so nothing stays interactive-looking, and the primary screen
// alone hosts the auth card and grabs exclusive keyboard focus. Field text
// lives in this one input - unlike the lock there is no cross-screen
// mirroring because only the primary surface renders a card.
//
// The vignette over that dim layer is the lockscreen's, at the lockscreen's
// level and with the lockscreen's fade - the level is fixed here rather
// than offered as an option, and the dim follows the lockscreen's own dim
// setting so the two never drift apart.
Variants {
  model: Ui.validScreens

  PanelWindow {
    id: win

    required property ShellScreen modelData
    readonly property bool primary: modelData === Ui.primaryScreen
    // The dim over the desktop. The lockscreen's own dim, in the same
    // units: the prompt paints a flat scrim, which is the case the
    // lockscreen's unblurred dim is for.
    readonly property real dim: Settings.lockscreenDim / 100
    // Vignette darkness at the corners: the lockscreen's medium level,
    // fixed rather than configurable.
    readonly property real vignetteK: 0.45
    // The vignette's animated factor, 0 -> vignetteK. Its own ramp, the
    // lockscreen's: the darkening settles in over a second rather than
    // arriving with the card.
    property real vigK: 0
    property real showK: 0

    // The screen this window IS. A `Variants` over the screens hands each
    // instance its own `modelData` and then does nothing else - without this
    // line every instance is an unplaced window and the compositor decides where
    // they go, which on one output means stacked on top of each other.
    screen: modelData

    // The binding that makes the card's presence mean a request. A PanelWindow
    // defaults to `visible: true`, so without this the prompt is a card on the
    // screen from the moment the Variants instantiates it, whether or not a
    // request exists.
    //
    // The binding is strictly narrower than `Polkit.visible && !Lockscreen.locked`:
    // it adds the "and has something to put on the card" test
    // (`win.wanted`, below) and keeps the `closing` exclusion, both of which
    // that pair got wrong in ways that showed as a bare box on screen.
    visible: win.showRequested

    // ---- the window is the SCREEN. Everything below is why. ---------------
    //
    // The window has to carry the output's geometry itself. A PanelWindow with
    // no geometry of its own auto-sizes to its content, and its content is the
    // 460x280 card: the window would BE the card, the scrim `anchors.fill:
    // parent` would fill 460x280 rather than the output, and there would be no
    // overlay left - just a dialog with a dark edge.
    color: "transparent"
    // An overlay reserves no space and takes no exclusive zone: the bar and the
    // panels underneath must not move because a password dialog appeared.
    exclusionMode: ExclusionMode.Ignore
    exclusiveZone: -1
    // The four anchors are what make the surface fill its output. This is the
    // idiom the rest of the tree uses for a per-screen overlay - see
    // common/ui/ScrimWindow.qml, which is the same six lines.
    anchors.left: true
    anchors.right: true
    anchors.top: true
    anchors.bottom: true

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "vibranium:polkit"
    // Exclusive on the primary alone. A second monitor gets OnDemand, so the
    // keyboard cannot be stolen from the card by a surface the user is not
    // looking at - which is also why `refocus()` below guards on `win.primary`.
    WlrLayershell.keyboardFocus: win.primary
      ? WlrKeyboardFocus.Exclusive
      : WlrKeyboardFocus.OnDemand

    // The primary screen's name, or "" when there is none. Hoisted because
    // three lines below need it and a `Ui.primaryScreen` read is an
    // unqualified access each time.
    readonly property string primaryName: Ui.primaryScreen === null
      || Ui.primaryScreen === undefined ? "" : String(Ui.primaryScreen.name ?? "")

    // Whether there is anything to put ON the card yet.
    //
    // `Polkit.visible` is `active || closing`, and `active` is set the moment
    // the agent accepts a request - which is BEFORE the action id, the
    // identities and the message have been read off the flow. So `visible` goes
    // true a beat early, and a window that obeys `visible` alone puts up a card
    // with nothing in it: the box, with no request named and no text, arriving
    // a frame or two before the real prompt fills it in. The live log showed it
    // as `prompt-shown action=empty reason=none` immediately followed by
    // `auth-request action=org.freedesktop.policykit.exec`.
    //
    // So "a request is pending" is not `Polkit.visible`; it is pending AND has
    // something to say. That is the same idea the suppression function already
    // encodes one step later - a request with nothing to show is the same as no
    // request at all - hoisted to where the window obeys it.
    readonly property bool populated: Polkit.conversationAction !== ""
      || Polkit.message !== "" || Polkit.prompt !== ""
    readonly property bool wanted: Polkit.visible && win.populated

    // The decision that DRIVES the window, kept apart from `state` below
    // because `state` reads the window's visibility and this is what sets it.
    // A single binding cannot do both: `suppression()` ends in
    // `if (c.visible === true) return "shown"`, so feeding its result back into
    // `visible` is a binding reading its own output. QML resolves that to
    // undefined rather than complaining, and the result is a PanelWindow left
    // on its default `visible: true` - a card on screen at boot with no
    // request behind it, which cannot be focused because `Polkit.visible` is
    // correctly false.
    //
    // Both this and `state` are given `win.wanted`, so the behaviour and the
    // diagnostic can never disagree about whether a request is pending.
    readonly property bool showRequested: PolkitTrace.shouldShow({
      requested: win.wanted,
      locked: Lockscreen.locked,
      screens: Ui.validScreens.length,
      primary: win.primaryName !== "",
      closing: Polkit.closing
    })

    // Everything the suppression decision is made from, as one record, and the
    // decision itself. `PolkitTrace` owns the precedence. Diagnostic only -
    // `showRequested` above is what the window obeys.
    readonly property var state: PolkitTrace.suppression({
      requested: win.wanted,
      locked: Lockscreen.locked,
      screens: Ui.validScreens.length,
      primary: win.primaryName !== "",
      closing: Polkit.closing,
      visible: win.visible
    })

    function refocus() {
      if (!win.primary || !win.wanted || Polkit.checking) {
        // Why the keystrokes are not going to the field. The three guards are
        // different failures: a secondary surface that tries to focus is a
        // deliberate no-op, a hidden dialog is the suppression case above, and
        // `checking` is a dialog that is mid-request and would drop the
        // keystroke on the floor.
        //
        // `win.wanted` and not `Polkit.visible`: the two disagree during the beat
        // before a request has any content, and focusing a dialog that is not up
        // is the same no-op the guards above already are.
        return
      }
      authBox.grabFocus()
    }

    // The single animation gate for this overlay: with the global switch
    // off, show/hide snap showK instead of running the tweens. Both
    // triggers below (and only these) call it, so the policy lives once.
    function fade(open) {
      if (MotionPolicy.enabled) {
        if (open) showAnim.restart()
        else hideAnim.restart()
        return
      }
      win.showK = open ? 1 : 0
    }

    // The vignette's entrance, the lockscreen's: the factor ramps from
    // nothing to the level over a second, so the darkening settles in
    // behind the card instead of arriving with it. With the global switch
    // off it snaps, like every other motion here.
    function appearVignette() {
      if (!MotionPolicy.enabled) {
        win.vigK = win.vignetteK
        return
      }
      win.vigK = 0
      vignetteAnim.restart()
    }

    onVisibleChanged: {
      if (!visible) {
        win.showK = 0
        win.vigK = 0
        return
      }
      if (Polkit.closing) return
      // A request reopening inside a previous failure's feedback window
      // must not inherit the red border.
      authBox.clearFailure()
      win.fade(true)
      win.appearVignette()
      win.refocus()
    }

    SequentialAnimation {
      id: showAnim

      NumberAnimation {
        target: win
        property: "showK"
        from: 0
        to: 1
        duration: 200
        easing.type: Easing.OutCubic
      }
    }

    SequentialAnimation {
      id: hideAnim

      NumberAnimation {
        target: win
        property: "showK"
        to: 0
        duration: 170
        easing.type: Easing.InCubic
      }
    }

    Connections {
      target: Polkit

      // Teardown waits in the singleton (closeTimer) so the fade finishes
      // before the window unmaps.
      function onClosingChanged() {
        if (!Polkit.closing) return
        win.fade(false)
      }

      // Fresh prompt after failure or in multi-turn PAM conversations.
      function onResponseRequiredChanged() {
        if (Polkit.responseRequired) win.refocus()
      }

      function onResetTokenChanged() {
        authBox.clear()
        win.refocus()
      }

      function onAttemptsChanged() {
        if (Polkit.attempts > 0 && win.primary) authBox.fail()
      }
    }

    // Flat black scrim over the desktop. The prompt paints a flat layer, so
    // this is the lockscreen's unblurred dim, read from the lockscreen's
    // own setting: the two never drift apart.
    Rectangle {
      anchors.fill: parent
      color: "#000000"
      opacity: win.dim * win.showK
    }

    // The vignette, over the scrim and under the card. Its level is fixed
    // here rather than configurable, but the fade is the lockscreen's: the
    // factor ramps 0 -> level over a second, and the shape scales with it.
    Vignette {
      id: vignette

      anchors.fill: parent
      intensity: win.vignetteK
      progress: win.vignetteK > 0 ? win.vigK / win.vignetteK : 1
    }

    // The vignette's ramp, the lockscreen's: 1000ms, OutCubic, running
    // beside the card's own 200ms entrance so the darkening settles behind
    // the card rather than with it.
    NumberAnimation {
      id: vignetteAnim

      target: win
      property: "vigK"
      from: 0
      to: win.vignetteK
      duration: 1000
      easing.type: Easing.OutCubic
    }

    MouseArea {
      anchors.fill: parent
      onClicked: win.refocus()
    }

    // Card layout: the input box is pinned to the card's exact center and
    // never moves; the heading hangs above it through the caps slot, so the
    // slot's animated height glides the heading alone.
    Item {
      id: panel

      readonly property real k: win.showK

      visible: win.primary
      anchors.centerIn: parent
      width: Math.min(460, win.width - 64)
      height: 280
      opacity: k
      scale: 0.94 + 0.06 * k

      Text {
        id: heading

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: capsSlot.top
        anchors.bottomMargin: 6
        text: "AUTHENTICATION"
        color: Ui.tint("foreground_0", 0.9)
        font.pixelSize: 18
        font.family: Ui.fontFamily
        font.bold: true
        font.letterSpacing: 6
      }

      // CapsLock chip lifted from the lockscreen. The slot collapses to
      // nothing while hidden and expands behind the fading chip when caps
      // engages, so the heading slides up and settles back smoothly.
      // State comes from the shared Keyboard singleton: synced from Hyprland
      // when the request lands, toggled by key presses on the focused field.
      Item {
        id: capsSlot

        width: parent.width
        height: Keyboard.capsOn ? capsChip.height + 24 : 0
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: authBox.top
        anchors.bottomMargin: 12

        Behavior on height {
          enabled: MotionPolicy.enabled
          NumberAnimation {
            duration: 200
            easing.type: Easing.OutCubic
          }
        }

        CapsChip {
          id: capsChip

          active: Keyboard.capsOn
          anchors.centerIn: parent
        }
      }

      PasswordBox {
        id: authBox

        // PAM prompts arrive sentence-case ("Password: "); the shared box
        // speaks uppercase, so they get normalized before display.
        readonly property string promptLabel: {
          const p = Polkit.prompt.replace(/^[\s]+|[\s]+$/g, "").replace(/[:\uFF1A]+$/, "")
          return p !== "" ? p.toUpperCase() : "PASSWORD"
        }
        // The generic word says nothing the leading lock does not already
        // say, so the glyph names the field and the word goes. A prompt
        // that names itself - a PIN, a user - still gets its label.
        readonly property bool promptIsGeneric: promptLabel === "PASSWORD"

        anchors.centerIn: parent

        enabled: Polkit.responseRequired && !Polkit.checking
        busy: Polkit.checking
        // flow.responseVisible means "echo typed characters"; the box wants
        // the opposite default - only an explicit true shows plain text.
        hidden: !Polkit.responseVisible
        // The same lock the password manager puts on its vault rows, in the
        // field's left chrome slot, always visible.
        iconName: "lock"
        placeholder: promptIsGeneric ? "" : promptLabel

        // The only two places in this file where the field's contents are
        // touched, and neither writes one: `text` goes straight to the
        // singleton, which forwards it to the backend, and the cancel signal
        // carries nothing at all.
        onSubmitted: text => Polkit.submitPassword(text)
        onCancelled: Polkit.cancelRequest()
        onCapsToggled: Keyboard.toggleCaps()
      }

      Text {
        id: suppText

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: authBox.bottom
        anchors.topMargin: 14
        width: parent.width
        visible: Polkit.supplementary !== ""
        text: Polkit.supplementary
        color: Polkit.supplementaryIsError || authBox.failure
                                                              ? Theme.color("red")
                                                              : Ui.tint("foreground_1", 0.7)
        font.pixelSize: 14
        font.family: Ui.fontFamily
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
      }

      Text {
        id: hintText

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: authBox.bottom
        anchors.topMargin: 14
        width: parent.width
        visible: Polkit.supplementary === ""
        text: "ENTER AUTHENTICATE \u00B7 ESC CANCEL"
        color: Ui.tint("foreground_1", 0.45)
        font.pixelSize: 11
        font.family: Ui.fontFamily
        font.bold: true
        font.letterSpacing: 3
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
      }

      // Auth reason/description under the hint: normal body text like the
      // lockscreen inhibitor lines, centered and wrapped. Falls back to a
      // generic line when the app provides no message.
      Text {
        id: reasonText

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: Polkit.supplementary !== "" ? suppText.bottom : hintText.bottom
        anchors.topMargin: Ui.m
        width: parent.width
        text: Polkit.message !== "" ? Polkit.message : "This application did not provide a description"
        color: Ui.tint("foreground_1", 0.75)
        font.pixelSize: Ui.fontM
        font.family: Ui.fontFamily
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        maximumLineCount: 4
        elide: Text.ElideRight
      }
    }
  }
}
