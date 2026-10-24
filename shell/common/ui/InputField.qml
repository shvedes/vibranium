pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
// Aliased: this component is itself called InputField and exports that name
// from qs.common, so an unaliased import would let a bare `TextField` resolve
// back to the wrapper instead of to the Qt control.
import QtQuick.Controls as Ctl
import qs.common
import "../text/EditUtils.js" as EditUtils

// Single-line text field: bordered box, placeholder, built-in clear
// affordance, an opt-in password reveal eye plus optional launcher-style
// chrome (prefix chip + counter).
// Consumers compose it freely (e.g. in a Row with a Button); behavior is
// wired through signals. The extra chrome is opt-in so the menu and
// launcher cards share one search-bar implementation.
//
// Tuning knobs for embedding contexts (chat replies, themed surfaces):
// focusColor recolors the engaged border, clearable drops the clear
// affordance, ghostWhileFocused hides the placeholder once the field
// owns focus, fontSize scales the type. Defaults match the menu look.
// Prefix/chip/counter props enable the launcher's mode-chip architecture
// directly on this shared field.
//
// The box and its chrome are the shell's; the editing inside it is the
// native control's. The control owns selection, the cursor, placeholder
// state, the context menu and input-method delivery; this wrapper owns the
// readline keys, the mode chip, the clear/reveal affordances, the insets
// they imply, and the signal vocabulary every consumer binds to.
Rectangle {
  id: root

  property string placeholder: ""
  // Rendered text; alias to the inner input for full control.
  property alias text: input.text
  readonly property alias input: input
  readonly property bool focused: input.activeFocus
  // Border hue while the field owns focus.
  property color focusColor: Theme.color("accent")
  // Clear affordance on the right; embedders with tight space turn it
  // off and regain symmetric text insets.
  property bool clearable: true
  // The glyph the clear affordance wears. Empty (default) keeps the
  // crossed bars this primitive has always drawn; a name paints the
  // shipped icon instead - the color picker's code field wears an
  // xmark, the same shape the eye affordance next to it is built from.
  // Either way the affordance sits in the same reserved right slot.
  property string clearGlyph: ""
  // Keep the ghost hint visible while focused - it describes the field,
  // not the editing state. Chat-style fields hide it instead.
  property bool ghostWhileFocused: true
  property int fontSize: Ui.fontM
  // Password masking - "Normal" (plain text) is the default; pass
  // "Password" to mask the echo (e.g. the wifi passphrase dropdown).
  // The mask glyph comes from the shared Ui.passwordEcho token; override
  // per-instance only for a deliberate one-off.
  property int echoMode: TextInput.Normal
  property string passwordCharacter: Ui.passwordEcho
  // Masked secret entry (passwords, tokens): forces the password echo
  // plus a sensitive input method on top of echoMode. Same field, no
  // separate component - consumers flip one bool.
  property bool sensitive: false
  // Password reveal affordance: an eye button in the right chrome slot
  // that flips the echo to plain text while revealed (and swaps its glyph
  // to eye-closed). Meant for masked fields (echoMode Password or
  // sensitive); with plain fields it is a harmless no-op.
  property bool revealable: false
  // Live reveal state. The eye button flips it; consumers may drive it
  // themselves (a policy reset on submit/cancel is theirs to own).
  property bool revealed: false

  // Emacs readline keys (Ctrl-W erase word, Alt-F/B word
  // jump). On by default - the menu and launcher rely on them.
  property bool emacsKeys: true
  // Destructive row keys: with this on, Delete and Ctrl-D are consumed ahead
  // of the native control's text editing and surface through
  // deleteRequested(). Consumers that own a removable row enable it only while
  // that row is under the cursor, so ordinary editing keeps Delete.
  property bool deleteKeys: false

  // Launcher-style extensions (opt-in). When `prefixes` is non-empty the
  // field watches the first characters for a mode switch and surfaces the
  // active mode as a chip inside the field.
  property var prefixes: []
  // The active mode's own prefix ("" when none). With an empty field,
  // repeating it (held-key auto-repeat during a heavy mode entry) must
  // not become a query - it would filter the fresh listing down to
  // nothing. Opt-in so consumers without modes (menu, clipboard) keep
  // literal typing untouched.
  property string activePrefix: ""
  property bool chipActive: false
  property string chipText: ""
  // Optional themed icon for the chip (name in assets/icons); replaces or
  // accompanies chipText (e.g. the web-search mode's webapp glyph instead
  // of "Web:"). chipColorKey is the palette key to recolor it with.
  property string chipIcon: ""
  property string chipColorKey: "foreground_1"
  // Pill chrome toggle for the chip; unboxed renders bare inline content.
  property bool chipBoxed: true
  property bool counterVisible: false
  property int counterMatched: 0
  property int counterTotal: 0
  property string inputRole: "none"
  property bool searchIconAlways: true
  property bool filterIconAlways: false
  readonly property string roleIcon: root.inputRole === "search" ? "search"
    : root.inputRole === "filter" ? "filter" : ""
  readonly property bool roleActive: root.roleIcon !== ""
    && (root.inputRole === "search" ? root.searchIconAlways || root.focused
      : root.filterIconAlways || root.focused)
  readonly property bool roleOwnsChip: root.roleIcon !== "" && root.chipIcon === "" && root.chipText === ""
  readonly property bool effectiveChipActive: root.chipActive || root.roleActive
  readonly property string effectiveChipIcon: root.chipIcon !== "" ? root.chipIcon : root.roleIcon
  // Base horizontal padding when chip is hidden; menu uses Ui.s (8),
  // launcher historically used Ui.l (16).
  property int basePadding: Ui.s

  // The ghost show rule replicates the native placeholder item exactly
  // (empty text, no composition, plus the ghostWhileFocused
  // contract); the native item itself stays blank because Qt owns it
  // and it can only snap - the library SlideSwap in ghostBox below
  // does the painting.
  readonly property bool _ghostShown: input.text === "" && input.preeditText === ""
    && (root.ghostWhileFocused || !input.activeFocus)

  signal accepted(string text)
  signal edited(string text)
  // Escape is consumed here and handed to the consumer as a signal so
  // focus position never decides who handles it.
  signal escaped()
  signal prefixEntered(string prefix, string payload)
  signal backspaceEmpty()
  // Delete/Ctrl-D while `deleteKeys` is on, taken ahead of text editing.
  signal deleteRequested()

  function clear() {
    input.text = ""
  }

  // Flip the echo between masked and plain characters (eye click, Ctrl+H).
  function toggleReveal() {
    root.revealed = !root.revealed
  }

  function grabFocus() {
    // A disabled field can never hold focus, and attempting the grab
    // anyway risks dislodging the focus the surface already holds -
    // leaving it deaf to keys. Refuse up front; every grab path
    // funnels through here.
    if (!root.enabled) return
    input.forceActiveFocus()
  }

  function releaseFocus() {
    input.focus = false
  }

  // Unified text pipeline. When chip prefixes are configured, leading
  // prefix characters never become text - they flip into chip mode via
  // prefixEntered(); pasted batches like "> query" are stripped the same
  // way so a launcher mode switch survives wholesale text assignment.
  function type(text) {
    if (!root.chipActive && root.prefixes.length > 0) {
      const pref = root.prefixes
      for (let i = 0; i < pref.length; i++) {
        if (text.startsWith(pref[i])) {
          const rest = text.substring(pref[i].length)
          if (input.text !== rest) input.text = rest
          root.prefixEntered(pref[i], rest)
          return
        }
      }
    }
    // Idempotent assign: onTextEdited already holds the new text, so a
    // redundant write would only risk a second emission path. One call,
    // one edited() signal.
    if (input.text !== text) input.text = text
    root.edited(text)
  }

  // Readline helpers live inside the field so panels don't duplicate
  // Ctrl-W / Alt-F / Alt-B. Panels simply listen to edited().
  function eraseWord() {
    const res = EditUtils.eraseWord(input.text, input.cursorPosition)
    if (res.pos === input.cursorPosition) return false
    input.text = res.text
    input.cursorPosition = res.pos
    root.edited(input.text)
    return true
  }

  function wordForward() {
    input.cursorPosition = EditUtils.boundaryForward(input.text, input.cursorPosition)
  }

  function wordBackward() {
    input.cursorPosition = EditUtils.boundaryBackward(input.text, input.cursorPosition)
  }

  implicitWidth: 200
  implicitHeight: Ui.inputHeight
  radius: RoundingPolicy.radius
  color: Theme.color("background_1")
  border.width: 1
  border.color: input.activeFocus ? root.focusColor : Theme.color("background_3")

  Behavior on border.color {
    ColorAnim {}
  }

  // The two insets the text yields to, and the chrome that decides them.
  // Both are layout passes the field runs on every keystroke a chip or a
  // counter turns on and off, and a caret that jumps is a wrong value here
  // rather than a mystery at the call site. The TEXT is never a field: this
  // primitive is the wifi passphrase field as well as the menu search, and
  // one line of geometry is all the two have in common.

  // The reveal eye. A masked field that shows its content is a security
  // fact, and which of the two gates opened it - the eye, or the consumer
  // driving `revealed` itself - is the difference between the two.

  TapHandler {
    onTapped: root.grabFocus()
  }

  // Insets the text yields to the chip (left) and counter/clear/eye (right).
  // Chip and text Glide together so the caret never overlaps the traveling chip.
  readonly property real leadInset: root.effectiveChipActive ? Ui.s + chip.width + Ui.s : root.basePadding
  // Right chrome slot widths: the reveal eye reserves its slot whenever the
  // field is revealable - with or without text, so the caret never shifts
  // as typing starts; the clear affordance only while there is something
  // to clear. A visible counter takes the right slot instead, and the eye
  // slot stays reserved beside it.
  readonly property real eyeSlot: root.revealable ? eyeButton.width + Ui.s : 0
  readonly property real clearSlot: root.clearable && !root.counterVisible && input.text !== ""
    ? clearButton.width + Ui.s : 0
  readonly property real rightInset: root.counterVisible ? counterRow.width + Ui.s + eyeSlot
    : Math.max(root.basePadding, root.clearSlot + eyeSlot)

  // Mode chip - launcher-style, rendered by the shared ui/Chip component.
  Chip {
    id: chip
    text: root.chipText
    iconName: root.effectiveChipIcon
    iconColorKey: root.chipColorKey
    boxed: root.roleOwnsChip ? false : root.chipBoxed
    // The chip is never selected, so the selected state is pinned off.
    selected: false
    width: implicitWidth
    anchors.verticalCenter: parent.verticalCenter
    x: root.effectiveChipActive ? Ui.s : Math.max(Ui.s, (parent.width - width) / 2)
    opacity: root.effectiveChipActive ? 1 : 0
    visible: opacity > 0.01
    Behavior on x { Glide {} }
    Behavior on opacity { NumberAnimation { duration: Ui.fastMs } }

    // The chip traveling into and out of the field, per frame. The caret
    // yields to it, so a chip that slides at a different speed from the text
    // it displaces is visible here.
  }

  // Ghost overlay: the placeholder paint, riding the same insets as the
  // text (and gliding with them) so the hint sits exactly where typing
  // will land. The swap itself is the library SlideSwap - a
  // bottom-to-top cross-slidefade over Ui.fastMs OutCubic. Show/hide
  // (focus moves, first keystroke) rides the box opacity on the same
  // duration. MotionPolicy gates every tween, like the rest.
  Item {
    id: ghostBox
    objectName: "ghost"
    x: root.leadInset
    width: parent.width - root.leadInset - root.rightInset
    height: parent.height
    clip: true
    visible: opacity > 0.01
    opacity: root._ghostShown ? 1 : 0

    // The synchronous show state underneath the animated paint above,
    // for tests and readers that must not sample a tween mid-flight.
    readonly property bool shown: root._ghostShown
    // The string currently fading (or faded) in, for the same readers.
    readonly property string text: swap.currentText
    // The three slide layers, A first (see SlideSwap.slides).
    readonly property var slides: swap.slides

    Behavior on x { Glide {} }
    Behavior on width { Glide {} }
    Behavior on opacity {
      enabled: MotionPolicy.enabled
      NumberAnimation { duration: Ui.fastMs }
    }

    SlideSwap {
      id: swap
      anchors.fill: parent
      text: root.placeholder
      color: Ui.tint("foreground_1", 0.4)
      fontSize: root.fontSize
      fontFamily: Ui.fontFamily
    }
  }

  Ctl.TextField {
    id: input

    x: root.leadInset
    width: parent.width - root.leadInset - root.rightInset
    // The box above is the chrome: the style's own background and its
    // padding would draw a second field inside this one. The control keeps
    // everything that is not paint.
    background: null
    padding: 0
    leftPadding: 0
    rightPadding: 0
    topPadding: 0
    bottomPadding: 0
    // Revealed unmasks whatever masked mode the field carries; while
    // masked, the ligature freeze below keeps the echo glyphs stable.
    echoMode: root.revealed ? TextInput.Normal
      : (root.sensitive ? TextInput.Password : root.echoMode)
    passwordCharacter: root.passwordCharacter
    inputMethodHints: root.sensitive ? Qt.ImhSensitiveData : Qt.ImhNone
    // The ghost is shell-painted (ghostBox above owns the placeholder
    // paint): Qt's own placeholder item can only snap, so it stays
    // blank and the overlay cross-slidefades placeholder flips on the
    // shell's terms. The empty-text / no-preedit / ghostWhileFocused
    // show rule lives in root._ghostShown; the hint color below is a shell
    // token, because the native placeholder item never paints.
    placeholderText: ""
    // Masked echo must never shape: the shell follows the system font,
    // often a programming face whose `calt` substitutes asterisk runs
    // (the middle star of `***` jumps to a raised alternate and back as
    // the run grows). Masked text has no legitimate ligatures, so freeze
    // the echo glyphs exactly as designed. Search fields keep defaults.
    font.features: input.echoMode === TextInput.Password
      ? ({ "calt": 0, "liga": 0, "clig": 0, "dlig": 0, "hlig": 0 }) : ({})
    height: parent.height
    verticalAlignment: TextInput.AlignVCenter
    clip: true
    color: Theme.color("foreground_0")
    selectionColor: Theme.color("accent")
    selectedTextColor: Theme.color("background_0")
    font.pixelSize: root.fontSize
    font.family: Ui.fontFamily

    Behavior on x { Glide {} }
    Behavior on width { Glide {} }

    // The text field riding its own insets, per frame. Both edges move on the
    // same curve so the caret never overlaps the traveling chip, and this is
    // where that claim is checkable.

    Keys.onEscapePressed: event => {
      event.accepted = true
      root.escaped()
    }

    // BeforeItem: the native control accepts Delete/Ctrl-D as editing keys and
    // would keep the destructive-key branch from ever seeing them.
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: event => {
      if (event.matches(StandardKey.SelectAll)) {
        input.selectAll()
        event.accepted = true
        return
      }
      const ctrl = event.modifiers & Qt.ControlModifier
      const alt = event.modifiers & Qt.AltModifier
      if (root.deleteKeys && ((event.key === Qt.Key_D && ctrl) || event.key === Qt.Key_Delete)) {
        event.accepted = true
        root.deleteRequested()
        return
      }
      if (event.key === Qt.Key_W && ctrl && root.emacsKeys) {
        if (root.eraseWord()) event.accepted = true
        return
      }
      if (event.key === Qt.Key_H && ctrl && root.revealable) {
        root.toggleReveal()
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_F && alt && root.emacsKeys) {
        root.wordForward()
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_B && alt && root.emacsKeys) {
        root.wordBackward()
        event.accepted = true
        return
      }
      if (!root.chipActive && root.prefixes.length > 0 && event.text.length === 1) {
        const pref = root.prefixes
        for (let i = 0; i < pref.length; i++) {
          if (event.text === pref[i]) {
            event.accepted = true
            root.prefixEntered(pref[i], text)
            return
          }
        }
      }
      // In-mode echo guard (see activePrefix): swallow the repeat.
      if (root.chipActive && root.activePrefix !== "" && text === ""
        && event.text.length === 1 && event.text === root.activePrefix) {
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Backspace && text === "") {
        event.accepted = true
        root.backspaceEmpty()
      }
    }

    onAccepted: root.accepted(text)
    onTextEdited: root.type(input.text)
  }

  // Matched/total counter - bare text ahead of the clear affordance slot.
  Row {
    id: counterRow
    anchors.right: parent.right
    // Slides ahead of the reveal eye (shared Ui.s gap) when it shows.
    anchors.rightMargin: root.revealable ? Ui.s + eyeButton.width + Ui.s : Ui.s
    anchors.verticalCenter: parent.verticalCenter
    visible: root.counterVisible
    spacing: 0
    Text {
      text: String(root.counterMatched)
      color: root.counterMatched === root.counterTotal
        ? Ui.tint("foreground_1", 0.5) : Ui.tint("accent", 1)
      font.pixelSize: Ui.fontS
      font.family: Ui.fontFamily
      textFormat: Text.PlainText
    }
    Text {
      text: "/" + root.counterTotal
      color: Ui.tint("foreground_1", 0.5)
      font.pixelSize: Ui.fontS
      font.family: Ui.fontFamily
      textFormat: Text.PlainText
    }
  }

  // Clear affordance: crossed bars, shown only when there is something to
  // clear and the counter is not occupying the right slot.
  Item {
    id: clearButton

    anchors.right: parent.right
    // Slide ahead of the reveal eye (shared Ui.s gap) when both show.
    anchors.rightMargin: root.revealable ? Ui.s + eyeButton.width + Ui.s : Ui.s
    anchors.verticalCenter: parent.verticalCenter
    width: 16
    height: 16
    visible: root.clearable && !root.counterVisible && input.text !== ""

    opacity: area.containsPress ? 1 : 0.5

    MouseArea {
      id: area

      anchors.fill: parent
      onClicked: {
        input.text = ""
        root.edited("")
        root.grabFocus()
      }
    }

    // The glyph: the shipped icon when one is named, the crossed bars
    // otherwise.
    Icon {
      anchors.centerIn: parent
      visible: root.clearGlyph !== ""
      name: root.clearGlyph
      colorKey: "foreground_1"
      size: 12
    }

    Rectangle {
      anchors.centerIn: parent
      visible: root.clearGlyph === ""
      width: 9
      height: 1.5
      rotation: 45
      color: Theme.color("foreground_1")
    }

    Rectangle {
      anchors.centerIn: parent
      visible: root.clearGlyph === ""
      width: 9
      height: 1.5
      rotation: -45
      color: Theme.color("foreground_1")
    }
  }

  // Reveal affordance (masked fields): the eye sits in the right chrome
  // slot and flips echo to plain text while revealed (eye-closed glyph).
  // Clear slides ahead of it when both show; the rightInset above reserves
  // the slot so typed text and the ghost never run under either.
  Item {
    id: eyeButton

    anchors.right: parent.right
    anchors.rightMargin: Ui.s
    anchors.verticalCenter: parent.verticalCenter
    width: 16
    height: 16
    visible: root.revealable

    // Same idle tone as the clear affordance; hovering or an actively
    // revealed echo lifts it, pressing lights it fully.
    opacity: eyeArea.containsPress ? 1
      : (eyeArea.containsMouse || root.revealed) ? 0.85 : 0.5

    MouseArea {
      id: eyeArea

      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.toggleReveal()
        root.grabFocus()
      }
    }

    Icon {
      anchors.centerIn: parent
      name: root.revealed ? "eye-closed" : "eye"
      colorKey: "foreground_1"
      size: 14
    }
  }
}
