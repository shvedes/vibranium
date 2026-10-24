// Probe: InputField and PasswordBox, headless, with a real event loop.
//
// Both components own their own text, focus, visibility and key handling, and
// PasswordBox is the unlock surface for the whole session, so what is under
// test here is a security surface: the echo mode, the reveal state, the
// failure window and the signals a consumer binds to.
//
// Why a pump rather than a snapshot. Four things in these two components are
// only correct after an event-loop turn, and each of them reads as a plausible
// wrong answer if sampled immediately:
//
//   * the mode chip and the reveal badge fade through `Behavior on opacity`,
//     so `opacity` is mid-flight on the first turn and 1 on a later one;
//   * the failure border cross-fades over 150ms through `Behavior on
//     border.color`, so mid-flash its value is a blend of the two ends;
//   * `PasswordBox.failure` is `failureTimer.running` and the window is
//     1400ms, so "still failing" and "expired" are 1400ms apart and the
//     driver samples both ends of that range;
//   * the theme palette lands milliseconds after boot, so the border
//     assertions read `Theme.color()` in the same turn as the colour they
//     compare against, and no assertion anywhere depends on a literal colour.
//
// What is NOT reachable, and is not claimed: anything a key press would do.
// There is no compositor and no QTest, so `accepted`, `escaped` and
// `backspaceEmpty` (InputField) and `submitted`, `edited`, `cancelled`,
// `capsToggled` and `navigate` (PasswordBox) cannot be emitted from here. What
// is asserted instead is the routing property each one reads, and the negative
// contract that nothing else emits them.
//
// The root is a Window rather than an Item: `forceActiveFocus()` on an item
// with no window is a no-op, and focus is half of what these components own.

import QtQuick
import Quickshell
import qs.common

Window {
  id: root

  width: 900
  height: 1800
  visible: true

  property int phase: 0

  // Signal bookkeeping. `edited` is the one InputField signal a caller can
  // reach without a key event, and the property worth asserting is the count:
  // one action, one signal, carrying the post-change value.
  property int ifEditedCount: 0
  property string ifEditedLast: "none"
  property int ifAcceptedCount: 0
  property int ifEscapedCount: 0
  property int ifBackspaceCount: 0
  property int ifPrefixCount: 0
  property string ifPrefixLast: "none"
  property int prefixEditedCount: 0
  property int emacsEditedCount: 0
  property string emacsEditedLast: "none"

  property int pwEditedCount: 0
  property string pwEditedLast: "none"
  property int pwSubmittedCount: 0
  property int pwCancelledCount: 0
  property int pwCapsCount: 0
  property int pwNavCount: 0
  property int pwNavDir: 99

  property string lateQuietPre: "unset"
  property string lateStillPre: "unset"

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  // ---- the components under test -------------------------------------

  // Text, placeholder, the clear affordance and the counter.
  InputField { id: plain; y: 0; placeholder: "Type here" }
  InputField { id: ghost; y: 40; placeholder: "Type here" }
  InputField { id: noGhost; y: 80; placeholder: "Type here"; ghostWhileFocused: false }
  InputField { id: noGhostText; y: 120; placeholder: "Type here"; ghostWhileFocused: false; text: "already" }
  InputField { id: noClear; y: 160; placeholder: "Type here"; clearable: false }
  InputField { id: big; y: 200; fontSize: 24 }
  InputField { id: counter; y: 240; counterVisible: true; counterMatched: 3; counterTotal: 7 }
  InputField { id: twin; y: 280; x: 320; placeholder: "Twin" }

  // The masking surface.
  InputField { id: masked; y: 320; sensitive: true }
  InputField { id: eyeOn; y: 360; sensitive: true; revealable: true }
  InputField { id: locked; y: 400; sensitive: true; revealable: false }
  InputField { id: echoNo; y: 440; echoMode: TextInput.NoEcho }
  InputField { id: echoNoMasked; y: 480; echoMode: TextInput.NoEcho; sensitive: true }
  InputField { id: customChar; y: 520; passwordCharacter: "#" }

  // Chip chrome, and the input role that stands in for one. `chipFader` is the
  // one whose chip is switched on during construction and left on, so the
  // driver can read the fade in flight on the first event-loop turn.
  InputField { id: chipper; y: 560; chipText: "Web" }
  InputField { id: chipFader; y: 1700; chipText: "Web" }
  InputField { id: chipIconField; y: 600; chipText: "Web"; chipIcon: "globe"; chipActive: true }
  InputField { id: searchRole; y: 640; inputRole: "search" }
  InputField { id: filterRole; y: 680; inputRole: "filter" }
  InputField { id: roleChip; y: 720; inputRole: "search"; chipText: "X" }
  // Ghost slide sampling: flipped once up front so the driver reads the
  // cross-slidefade mid-flight on the first turn and landed at settle.
  InputField { id: swapper; y: 1740; placeholder: "Search..." }

  // The prefix pipeline and the readline helpers.
  InputField { id: prefixed; y: 760; prefixes: [">", "#"] }
  InputField { id: prefixInMode; y: 800; prefixes: [">"]; chipActive: true }
  InputField { id: emacs; y: 840 }
  InputField { id: unicodeField; y: 880 }

  // One box per echo state, so a display row is only ever read in a state it
  // has been sitting in since construction.
  PasswordBox { id: pwMask; y: 920 }
  PasswordBox { id: pwRevealed; y: 980 }
  PasswordBox { id: pwPlainEcho; y: 1040; hidden: false }
  PasswordBox { id: pwWiped; y: 1100 }
  PasswordBox { id: pwWindow; y: 1160 }
  PasswordBox { id: pwShort; y: 1220; failureMs: 300 }
  PasswordBox { id: pwDouble; y: 1280 }
  PasswordBox { id: pwQuiet; y: 1340 }
  PasswordBox { id: pwFailedRevealed; y: 1400 }
  PasswordBox { id: lateQuiet; y: 1460 }
  PasswordBox { id: lateStill; y: 1520; animated: false }
  PasswordBox { id: pwFocus; y: 1580 }
  PasswordBox { id: pwFocusTwin; y: 1640; x: 320 }

  // ---- the event loop -------------------------------------------------

  Timer {
    id: pump
    interval: 40
    repeat: true
    running: true
    onTriggered: {
      root.phase++
      if (root.phase === 1) onFirstTick()
      else if (root.phase === 2) onSecondTick()
      else if (root.phase === 8) onEighthTick()
    }
  }

  // 600ms: the palette has landed and every tween has finished, so this is
  // the first moment a border colour means what it says.
  Timer { id: settle; interval: 600; onTriggered: onSettle() }
  // 120ms into a 150ms cross-fade.
  Timer { id: mid; interval: 720; onTriggered: onMid() }
  // 500ms into that cross-fade: landed.
  Timer { id: land; interval: 1100; onTriggered: onLand() }
  // Past the 1400ms window armed at construction, short of the one re-armed
  // at 600ms.
  Timer { id: half; interval: 1500; onTriggered: onHalf() }
  // Past 600 + 1400, which is where a restarted window lands.
  Timer { id: rest; interval: 2100; onTriggered: onRest() }

  Component.onCompleted: {
    kv("textinput.error", "none")
    try {
      reportSync()
      settle.start()
      mid.start()
      land.start()
      half.start()
      rest.start()
    } catch (e) {
      kv("textinput.error", "" + (e && e.message ? e.message : e))
      console.log("##DONE##")
    }
  }

  function reportSync() {
    reportText()
    reportFocus()
    reportMasking()
    reportChips()
    reportPrefixes()
    reportEmacs()
    reportAffordances()
    reportPasswordBox()
  }

  // ---- InputField: text, placeholder ----------------------------------

  function reportText() {
    kv("probe.motion.enabled", MotionPolicy.enabled)
    kv("probe.ui.inputHeight", Ui.inputHeight)
    kv("probe.ui.fontM", Ui.fontM)
    kv("probe.ui.s", Ui.s)
    kv("probe.ui.passwordEcho", Ui.passwordEcho)
    kv("probe.ui.fastMs", Ui.fastMs)

    kv("if.defaultPlaceholder", plain.placeholder)
    kv("if.defaultFontSize", plain.fontSize)
    kv("if.fontSize.isUiFontM", plain.fontSize === Ui.fontM)
    kv("if.defaultText", plain.text)
    kv("if.defaultEmacsKeys", plain.emacsKeys)
    kv("if.defaultSensitive", plain.sensitive)
    kv("if.defaultRevealable", plain.revealable)
    kv("if.defaultRevealed", plain.revealed)
    kv("if.defaultClearable", plain.clearable)
    kv("if.defaultGhost", plain.ghostWhileFocused)
    kv("if.defaultEchoMode", plain.echoMode)
    kv("if.echoMode.isNormal", plain.echoMode === TextInput.Normal)
    kv("if.defaultPrefixesLength", plain.prefixes.length)
    kv("if.defaultActivePrefix", plain.activePrefix)
    kv("if.defaultChipActive", plain.chipActive)
    kv("if.defaultChipText", plain.chipText)
    kv("if.defaultChipIcon", plain.chipIcon)

    // `text` is an alias onto the inner control, so a write has to land on
    // the string the control holds rather than on a copy.
    plain.text = "hello"
    kv("if.text.roundtrip", plain.text)
    kv("if.text.aliasIsInputText", plain.text === plain.input.text)
    plain.text = ""
    kv("if.text.empty.roundtrip", plain.text)
    kv("if.text.empty.isEmpty", plain.text === "")

    const long = "the quick brown fox jumps over the lazy dog, repeatedly, at length"
    plain.text = long
    kv("if.text.long.roundtrip", plain.text)
    kv("if.text.long.length", plain.text.length)
    kv("if.text.long.isExact", plain.text === long)

    plain.text = "héllo-ẞ-🎉"
    kv("if.text.unicode.roundtrip", plain.text)
    kv("if.text.unicode.length", plain.text.length)
    kv("if.text.unicode.isAstralPair", plain.text.length === 10)
    kv("if.text.unicode.alias", plain.text === plain.input.text)
    plain.text = ""
    kv("if.text.unicode.cleared", plain.text)

    // The painted placeholder. The shell paints the ghost itself (the
    // overlay owns the string and the show rule alike), so both halves
    // are read off it rather than inferred.
    kv("ph.ghost.unfocused.text", ghostItem(ghost).text)
    kv("ph.ghost.unfocused.visible", ghostItem(ghost).shown)
    kv("ph.ghost.unfocused.paints", paints(ghost))
    ghost.grabFocus()
    kv("ph.ghost.focused.text", ghostItem(ghost).text)
    kv("ph.ghost.focused.visible", ghostItem(ghost).shown)
    kv("ph.ghost.focused.paints", paints(ghost))
    kv("ph.ghost.focused.flag", ghost.ghostWhileFocused)
    ghost.releaseFocus()
    kv("ph.ghost.released.paints", paints(ghost))

    ghost.text = "abc"
    kv("ph.ghost.withText.visible", ghostItem(ghost).shown)
    kv("ph.ghost.withText.paints", paints(ghost))
    kv("ph.ghost.withText.textStillBound", ghostItem(ghost).text)
    ghost.text = ""

    kv("ph.noGhost.flag", noGhost.ghostWhileFocused)
    kv("ph.noGhost.unfocused.paints", paints(noGhost))
    noGhost.grabFocus()
    kv("ph.noGhost.focused.text", ghostItem(noGhost).text)
    kv("ph.noGhost.focused.visible", ghostItem(noGhost).shown)
    kv("ph.noGhost.focused.paints", paints(noGhost))
    noGhost.releaseFocus()
    kv("ph.noGhost.released.paints", paints(noGhost))
    kv("ph.noGhost.withText.paints", paints(noGhostText))

    // The ghost cross-slidefade. Staging is synchronous (an idle
    // layer takes the string and the front index trades in the same
    // turn); the rise/opacity travel over Ui.fastMs.
    swapper.placeholder = "Filter..."
    const sgl = ghostLayers(swapper)
    const swp = ghostSwap(swapper)
    kv("ghost.swap.layers", sgl.length)
    kv("ghost.swap.staged", swp && swp._front >= 0 ? sgl[swp._front].text : "missing")
    kv("ghost.swap.front", ghostItem(swapper) ? ghostItem(swapper).text : "missing")
    kv("ghost.swap.frontIndex", swp ? swp._front : "missing")
  }

  // Focus is part of the contract, not a decoration: `focused` is the
  // control's own `activeFocus`, so there is no second flag to disagree.
  function reportFocus() {
    kv("focus.plain.before", plain.focused)
    kv("focus.plain.isInputActiveFocus", plain.focused === plain.input.activeFocus)
    plain.grabFocus()
    kv("focus.plain.afterGrab", plain.focused)
    kv("focus.plain.inputFocusProperty", plain.input.focus)
    twin.grabFocus()
    kv("focus.plain.afterTwinGrab", plain.focused)
    kv("focus.twin.afterGrab", twin.focused)
    plain.releaseFocus()
    kv("focus.plain.afterRelease", plain.focused)
    kv("focus.twin.stillFocused", twin.focused)
    twin.releaseFocus()
    kv("focus.twin.afterRelease", twin.focused)
    kv("focus.anyLeft", plain.focused || twin.focused)
  }

  // ---- InputField: the masking surface --------------------------------

  function reportMasking() {
    kv("echo.normal", TextInput.Normal)
    kv("echo.noEcho", TextInput.NoEcho)
    kv("echo.password", TextInput.Password)

    // The truth table of InputField.qml:237-238. `revealed` is tested first,
    // `sensitive` second, and the consumer's own `echoMode` only if neither.
    kv("echo.table.plain", plain.input.echoMode)
    kv("echo.table.plainIsNormal", plain.input.echoMode === TextInput.Normal)
    kv("echo.table.sensitive", masked.input.echoMode)
    kv("echo.table.sensitiveIsPassword", masked.input.echoMode === TextInput.Password)
    kv("echo.table.noEcho", echoNo.input.echoMode)
    kv("echo.table.noEchoIsNoEcho", echoNo.input.echoMode === TextInput.NoEcho)
    kv("echo.table.noEchoAndSensitive", echoNoMasked.input.echoMode)
    kv("echo.table.sensitiveBeatsEchoMode", echoNoMasked.input.echoMode === TextInput.Password)
    echoNoMasked.revealed = true
    kv("echo.table.revealedBeatsSensitive", echoNoMasked.input.echoMode)
    kv("echo.table.revealedIsPlain", echoNoMasked.input.echoMode === TextInput.Normal)
    echoNoMasked.revealed = false
    kv("echo.table.remasked", echoNoMasked.input.echoMode)
    kv("echo.table.remaskedIsPassword", echoNoMasked.input.echoMode === TextInput.Password)

    // The eye affordance: a revealable field unmasks on request, and only
    // revealable or sensitive fields are ever masked to begin with.
    kv("echo.eye.revealable", eyeOn.revealable)
    kv("echo.eye.maskedBefore", eyeOn.input.echoMode === TextInput.Password)
    eyeOn.revealed = true
    kv("echo.eye.afterReveal", eyeOn.input.echoMode === TextInput.Normal)
    eyeOn.revealed = false
    kv("echo.eye.afterHide", eyeOn.input.echoMode === TextInput.Password)
    eyeOn.toggleReveal()
    kv("echo.eye.afterToggle", eyeOn.revealed)
    kv("echo.eye.afterToggleEcho", eyeOn.input.echoMode === TextInput.Normal)
    eyeOn.toggleReveal()
    kv("echo.eye.afterSecondToggle", eyeOn.revealed)
    kv("echo.eye.afterSecondToggleEcho", eyeOn.input.echoMode === TextInput.Password)

    // The claim under test: `revealed` driven directly on a field that is
    // sensitive but NOT revealable. Recorded either way; the driver carries a
    // note about which one this is.
    kv("echo.locked.revealable", locked.revealable)
    kv("echo.locked.sensitive", locked.sensitive)
    kv("echo.locked.echoBefore", locked.input.echoMode === TextInput.Password)
    locked.revealed = true
    kv("echo.locked.revealedAccepted", locked.revealed)
    kv("echo.locked.echoAfter", locked.input.echoMode)
    kv("echo.locked.stillMasked", locked.input.echoMode === TextInput.Password)
    kv("echo.locked.ligaturesFrozen", featureCount(locked) === 5)
    locked.revealed = false
    kv("echo.locked.echoRestored", locked.input.echoMode === TextInput.Password)

    // The mask glyph token, and a per-instance override.
    kv("echo.char.default", plain.input.passwordCharacter)
    kv("echo.char.defaultIsToken", plain.passwordCharacter === Ui.passwordEcho)
    kv("echo.char.override", customChar.input.passwordCharacter)
    customChar.sensitive = true
    kv("echo.char.overrideWhenSensitive", customChar.input.passwordCharacter)
    kv("echo.char.sensitiveUsesOverride", customChar.input.echoMode === TextInput.Password)

    // The sensitive input-method hint: the flag that keeps a masked field out
    // of an input method's learning dictionary.
    kv("imh.none", Qt.ImhNone)
    kv("imh.sensitive", Qt.ImhSensitiveData)
    kv("imh.plain", plain.input.inputMethodHints)
    kv("imh.plainIsNone", plain.input.inputMethodHints === Qt.ImhNone)
    kv("imh.masked", masked.input.inputMethodHints)
    kv("imh.maskedIsSensitive", masked.input.inputMethodHints === Qt.ImhSensitiveData)
    kv("imh.maskedDiffersFromPlain", masked.input.inputMethodHints !== plain.input.inputMethodHints)
    kv("imh.revealedKeepsHint", eyeOn.input.inputMethodHints === Qt.ImhSensitiveData)
    customChar.text = "shh"
    kv("imh.textWithSensitiveHint", customChar.input.inputMethodHints === Qt.ImhSensitiveData)
    customChar.text = ""
    kv("imh.plainRevealedHasNoHint", echoNo.input.inputMethodHints === Qt.ImhNone)

    // The ligature freeze. A programming font substitutes a raised alternate
    // for a run of asterisks, so a masked field turns every ligature off and
    // an unmasked one gets the font's defaults back.
    kv("liga.plain.keyCount", featureCount(plain))
    kv("liga.masked.keyCount", featureCount(masked))
    kv("liga.masked.keys", featureKeys(masked))
    kv("liga.masked.calt", masked.input.font.features.calt)
    kv("liga.masked.liga", masked.input.font.features.liga)
    eyeOn.revealed = true
    kv("liga.revealed.keyCount", featureCount(eyeOn))
    eyeOn.revealed = false
    kv("liga.remasked.keyCount", featureCount(eyeOn))
    kv("liga.tiedToEcho.plain", tieToEcho(plain))
    kv("liga.tiedToEcho.masked", tieToEcho(masked))
    kv("liga.tiedToEcho.revealed", tieToEcho(eyeOn))

    // `sensitive` masks the display, not the owner's copy: the consumer has
    // to be able to submit the value.
    masked.text = "s3cret"
    kv("text.sensitive.readback", masked.text)
    kv("text.sensitive.stillMasked", masked.input.echoMode === TextInput.Password)
    kv("text.sensitive.twinUnmasked", twin.input.echoMode === TextInput.Normal)
    masked.text = ""
  }

  // ---- InputField: chip chrome ----------------------------------------

  function reportChips() {
    kv("chip.inactive.text", chipOf(chipper) ? chipOf(chipper).text : "missing")
    kv("chip.inactive.opacity", chipOf(chipper) ? chipOf(chipper).opacity : "missing")
    kv("chip.inactive.visible", chipOf(chipper) ? chipOf(chipper).visible : "missing")
    kv("chip.inactive.effectiveChipActive", chipper.effectiveChipActive)
    kv("chip.inactive.leadInset", chipper.leadInset)
    kv("chip.inactive.leadInsetIsBasePadding", chipper.leadInset === chipper.basePadding)
    chipper.chipActive = true
    kv("chip.active.effectiveChipActive", chipper.effectiveChipActive)
    kv("chip.active.leadInsetGrew", chipper.leadInset > chipper.basePadding)
    kv("chip.active.leadInsetIsChipPlusGaps", chipper.leadInset === 2 * Ui.s + chipOf(chipper).width)
    chipper.chipActive = false
    kv("chip.inactiveAgain.effectiveChipActive", chipper.effectiveChipActive)
    // Left on from here, so the fade is still in flight on the first turn.
    chipFader.chipActive = true
    kv("chip.fader.effectiveChipActive", chipFader.effectiveChipActive)
    kv("chip.fader.leadInset", chipFader.leadInset)

    kv("chip.icon.text", chipOf(chipIconField) ? chipOf(chipIconField).text : "missing")
    kv("chip.icon.name", chipOf(chipIconField) ? chipOf(chipIconField).iconName : "missing")
    kv("chip.icon.effectiveIcon", chipIconField.effectiveChipIcon)
    kv("chip.icon.chipIcon", chipIconField.chipIcon)
    kv("chip.icon.boxed", chipOf(chipIconField) ? chipOf(chipIconField).boxed : "missing")
    chipIconField.chipIcon = ""
    kv("chip.icon.emptyWhenCleared", chipIconField.effectiveChipIcon)
    chipIconField.chipIcon = "globe"

    kv("role.search.icon", searchRole.roleIcon)
    kv("role.filter.icon", filterRole.roleIcon)
    kv("role.none.icon", plain.roleIcon)
    kv("role.none.active", plain.roleActive)
    kv("role.search.searchIconAlways", searchRole.searchIconAlways)
    kv("role.search.activeUnfocused", searchRole.roleActive)
    kv("role.filter.filterIconAlways", filterRole.filterIconAlways)
    kv("role.filter.activeUnfocused", filterRole.roleActive)
    filterRole.grabFocus()
    kv("role.filter.activeFocused", filterRole.roleActive)
    filterRole.releaseFocus()
    kv("role.filter.activeReleased", filterRole.roleActive)
    filterRole.filterIconAlways = true
    kv("role.filter.activeWhenAlways", filterRole.roleActive)
    filterRole.filterIconAlways = false
    kv("role.ownsChip.search", searchRole.roleOwnsChip)
    kv("role.ownsChip.withText", roleChip.roleOwnsChip)
    kv("role.ownsChip.unboxed", chipOf(searchRole) ? chipOf(searchRole).boxed : "missing")
    kv("role.ownsChip.boxedWithText", chipOf(roleChip) ? chipOf(roleChip).boxed : "missing")
    kv("role.effectiveIcon.search", searchRole.effectiveChipIcon)
    kv("role.effectiveIcon.fallsBackToRole", roleChip.effectiveChipIcon)
    searchRole.chipIcon = "star"
    kv("role.effectiveIcon.explicitWins", searchRole.effectiveChipIcon)
    searchRole.chipIcon = ""
    kv("role.effectiveChipActive.search", searchRole.effectiveChipActive)
    plain.chipActive = true
    kv("role.effectiveChipActive.explicit", plain.effectiveChipActive)
    plain.chipActive = false
    kv("role.effectiveChipActive.explicitOff", plain.effectiveChipActive)
    plain.chipText = "Mode"
    plain.chipIcon = "search"
    kv("chip.chipTextSet", plain.chipText)
    kv("chip.chipIconSet", plain.chipIcon)
    kv("chip.effectiveIconOverride", plain.effectiveChipIcon)
    plain.chipText = ""
    plain.chipIcon = ""
  }

  // ---- InputField: the prefix pipeline --------------------------------

  function reportPrefixes() {
    plain.edited.connect(t => {
      ifEditedCount++
      ifEditedLast = t
    })
    plain.accepted.connect(() => {
      ifAcceptedCount++
    })
    plain.escaped.connect(() => {
      ifEscapedCount++
    })
    plain.backspaceEmpty.connect(() => {
      ifBackspaceCount++
    })
    prefixed.prefixEntered.connect((p, payload) => {
      ifPrefixCount++
      ifPrefixLast = p + "|" + payload
    })
    prefixed.edited.connect(() => {
      prefixEditedCount++
    })
    emacs.edited.connect(t => {
      emacsEditedCount++
      emacsEditedLast = t
    })

    // `type()` is the single write path every consumer funnels through, so
    // one call has to mean one `edited` carrying the post-change value.
    plain.text = "abc"
    plain.type("xyz")
    kv("type.edited.count", ifEditedCount)
    kv("type.edited.payload", ifEditedLast)
    kv("type.text.landed", plain.text)
    plain.text = "abc"
    plain.type("abc")
    kv("type.same.count", ifEditedCount)
    kv("type.same.payload", ifEditedLast)
    plain.text = ""
    plain.type("")
    kv("type.empty.count", ifEditedCount)
    kv("type.empty.payload", ifEditedLast)
    kv("type.empty.text", plain.text)

    // The clear affordance emits `edited("")`; `clear()` does not. The silent
    // half is measured here; the button's click is not reachable without a
    // pointer event, so its half is pinned from the source.
    ifEditedCount = 0
    const affordance = clearAffordance(plain)
    plain.text = "typed"
    kv("clear.affordance.found", affordance !== null)
    kv("clear.affordance.visibleWithText", affordance ? affordance.visible : "missing")
    plain.clear()
    kv("clear.text", plain.text)
    kv("clear.edited.count", ifEditedCount)
    kv("clear.affordance.visibleAfterClear", affordance ? affordance.visible : "missing")
    plain.text = ""
    kv("clear.affordance.visibleEmpty", affordance ? affordance.visible : "missing")

    // Prefixes: an empty list is inert, a match flips into chip mode, a
    // non-match is a query, and a list set after construction counts.
    kv("prefix.length", prefixed.prefixes.length)
    kv("prefix.first", prefixed.prefixes[0])
    kv("prefix.second", prefixed.prefixes[1])
    prefixed.text = ""
    ifPrefixCount = 0
    prefixEditedCount = 0
    prefixed.type("> hello")
    kv("prefix.match.text", prefixed.text)
    kv("prefix.match.signalCount", ifPrefixCount)
    kv("prefix.match.last", ifPrefixLast)
    kv("prefix.match.editedCount", prefixEditedCount)
    ifPrefixCount = 0
    prefixed.type("#tag rest")
    kv("prefix.match2.text", prefixed.text)
    kv("prefix.match2.signalCount", ifPrefixCount)
    kv("prefix.match2.last", ifPrefixLast)
    ifPrefixCount = 0
    prefixEditedCount = 0
    prefixed.type("plain query")
    kv("prefix.nomatch.text", prefixed.text)
    kv("prefix.nomatch.signalCount", ifPrefixCount)
    kv("prefix.nomatch.editedCount", prefixEditedCount)
    prefixed.text = ""
    prefixed.prefixes = []
    kv("prefix.emptied.length", prefixed.prefixes.length)
    prefixed.type(">x")
    kv("prefix.emptied.text", prefixed.text)
    kv("prefix.emptied.signalCount", ifPrefixCount)
    prefixed.prefixes = ["@"]
    ifPrefixCount = 0
    prefixed.type("@late")
    kv("prefix.setAfterConstruction.text", prefixed.text)
    kv("prefix.setAfterConstruction.signalCount", ifPrefixCount)
    kv("prefix.setAfterConstruction.last", ifPrefixLast)
    prefixed.prefixes = [">", "#"]

    // In mode the prefix is literal text: the chip already owns the mode.
    prefixInMode.text = ""
    prefixInMode.activePrefix = ">"
    kv("prefix.inMode.activePrefix", prefixInMode.activePrefix)
    kv("prefix.inMode.chipActive", prefixInMode.chipActive)
    prefixInMode.type(">x")
    kv("prefix.inMode.text", prefixInMode.text)
    prefixInMode.text = ""
    prefixed.activePrefix = ">"
    kv("prefix.activePrefix.roundtrip", prefixed.activePrefix)
    kv("prefix.activePrefix.textUntouched", prefixed.text)
    prefixed.prefixes = [">", "#"]
  }

  // ---- InputField: the readline handlers ------------------------------

  // `emacsKeys` is only read inside `Keys.onPressed`, which no key event can
  // reach here. What is assertable is the flag's default and the handlers it
  // routes to, which are public functions.
  function reportEmacs() {
    emacs.text = "alpha beta gamma"
    emacs.input.cursorPosition = 16
    kv("emacs.flag.default", emacs.emacsKeys)
    emacs.emacsKeys = false
    kv("emacs.flag.whenOff", emacs.emacsKeys)
    emacs.emacsKeys = true
    kv("emacs.flag.whenBackOn", emacs.emacsKeys)
    kv("emacs.handler.eraseWord", typeof emacs.eraseWord)
    kv("emacs.handler.wordForward", typeof emacs.wordForward)
    kv("emacs.handler.wordBackward", typeof emacs.wordBackward)
    kv("emacs.cursor.start", emacs.input.cursorPosition)

    emacsEditedCount = 0
    kv("emacs.eraseWord.ret1", emacs.eraseWord())
    kv("emacs.eraseWord.text1", emacs.text)
    kv("emacs.eraseWord.cursor1", emacs.input.cursorPosition)
    kv("emacs.eraseWord.edited1", emacsEditedCount)
    kv("emacs.eraseWord.ret2", emacs.eraseWord())
    kv("emacs.eraseWord.text2", emacs.text)
    kv("emacs.eraseWord.cursor2", emacs.input.cursorPosition)
    kv("emacs.eraseWord.ret3", emacs.eraseWord())
    kv("emacs.eraseWord.text3", emacs.text)
    kv("emacs.eraseWord.cursor3", emacs.input.cursorPosition)
    kv("emacs.eraseWord.edited3", emacsEditedCount)
    kv("emacs.eraseWord.ret4", emacs.eraseWord())
    kv("emacs.eraseWord.text4", emacs.text)
    kv("emacs.eraseWord.noopEmitsNothing", emacsEditedCount)

    emacs.text = "one two three"
    emacs.input.cursorPosition = 0
    emacs.wordForward()
    kv("emacs.wordForward.from0", emacs.input.cursorPosition)
    emacs.wordForward()
    kv("emacs.wordForward.again", emacs.input.cursorPosition)
    emacs.wordBackward()
    kv("emacs.wordBackward", emacs.input.cursorPosition)
    emacs.wordBackward()
    kv("emacs.wordBackward.again", emacs.input.cursorPosition)
    kv("emacs.wordMoves.textUntouched", emacs.text)
    emacs.text = ""
    emacs.input.cursorPosition = 0

    // A cursor sitting just past a space erases the word and the space with
    // it, which is what readline does and what boundaryBackward implements.
    emacs.text = "ab cd"
    emacs.input.cursorPosition = 3
    kv("emacs.afterSpace.ret", emacs.eraseWord())
    kv("emacs.afterSpace.text", emacs.text)
    kv("emacs.afterSpace.cursor", emacs.input.cursorPosition)
    emacs.text = ""
    emacs.input.cursorPosition = 0

    // Unicode: a word boundary is a whitespace test, so a multi-byte run has
    // to erase as one unit.
    unicodeField.text = "café naïve"
    unicodeField.input.cursorPosition = unicodeField.text.length
    kv("emacs.unicode.ret", unicodeField.eraseWord())
    kv("emacs.unicode.text", unicodeField.text)
    unicodeField.input.cursorPosition = unicodeField.text.length
    kv("emacs.unicode.ret2", unicodeField.eraseWord())
    kv("emacs.unicode.text2", unicodeField.text)
    unicodeField.text = ""
    unicodeField.input.cursorPosition = 0
  }

  // ---- InputField: right chrome and layout ----------------------------

  function reportAffordances() {
    const affordance = clearAffordance(plain)
    kv("slot.basePadding", plain.basePadding)
    kv("slot.basePaddingIsUiS", plain.basePadding === Ui.s)
    plain.text = ""
    kv("slot.empty.eyeSlot", plain.eyeSlot)
    kv("slot.empty.clearSlot", plain.clearSlot)
    kv("slot.empty.rightInset", plain.rightInset)
    plain.text = "abcd"
    kv("slot.text.clearSlot", plain.clearSlot)
    kv("slot.text.clearSlotIsButtonPlusGap", plain.clearSlot === 16 + Ui.s)
    kv("slot.text.rightInset", plain.rightInset)
    plain.revealable = true
    kv("slot.revealable.eyeSlotWithNoText", plain.eyeSlot)
    kv("slot.revealable.eyeSlotIsButtonPlusGap", plain.eyeSlot === 16 + Ui.s)
    plain.text = ""
    kv("slot.revealable.clearSlotStillEmpty", plain.clearSlot)
    kv("slot.revealable.rightInsetJustEye", plain.rightInset)
    plain.text = "abcd"
    kv("slot.revealable.clearSlotWithText", plain.clearSlot)
    kv("slot.revealable.bothSlots", plain.rightInset)
    kv("slot.revealable.eyeStillReserved", plain.rightInset >= plain.eyeSlot)
    plain.revealable = false
    kv("slot.plain.rightInset", plain.rightInset)
    plain.text = ""

    // The clear affordance itself, not just the slot it reserves.
    plain.text = "abcd"
    kv("clear.item.visibleWithText", affordance ? affordance.visible : "missing")
    plain.clearable = false
    kv("clear.item.visibleNotClearable", affordance ? affordance.visible : "missing")
    kv("clear.slot.notClearable", plain.clearSlot)
    plain.clearable = true
    plain.text = ""
    kv("clear.item.visibleEmpty", affordance ? affordance.visible : "missing")
    plain.clearable = false
    plain.text = "abcd"
    kv("clear.item.visibleClearableOff", affordance ? affordance.visible : "missing")
    plain.clearable = true
    plain.text = ""
    noClear.text = "abcd"
    kv("clear.item.visibleNeverClearable", clearAffordance(noClear) ? clearAffordance(noClear).visible : "missing")
    noClear.text = ""

    // The counter owns the right slot instead of the clear affordance.
    kv("counter.row.found", counterRowOf(counter) !== null)
    kv("counter.row.visible", counterRowOf(counter) ? counterRowOf(counter).visible : "missing")
    kv("counter.text", counterText(counter))
    counter.text = "query"
    kv("counter.textWithQuery", counterText(counter))
    kv("counter.rightInset", counter.rightInset)
    kv("counter.clearSlotSuppressed", counter.clearSlot)
    kv("counter.item.visible", clearAffordance(counter) ? clearAffordance(counter).visible : "missing")
    counter.text = ""

    // The eye affordance's visibility follows `revealable`, and its glyph
    // follows `revealed`.
    const eye = eyeAffordance(plain)
    kv("eye.item.found", eye !== null)
    kv("eye.item.visibleNotRevealable", eye ? eye.visible : "missing")
    plain.revealable = true
    kv("eye.item.visibleRevealable", eye ? eye.visible : "missing")
    kv("eye.item.glyphHidden", eye ? eyeGlyphName(eye) : "missing")
    plain.revealed = true
    kv("eye.item.glyphRevealed", eye ? eyeGlyphName(eye) : "missing")
    plain.revealed = false
    kv("eye.item.glyphHiddenAgain", eye ? eyeGlyphName(eye) : "missing")
    plain.revealable = false
    plain.text = ""

    // Layout. The box height is the input token and nothing else: `fontSize`
    // moves the type, not the box.
    kv("layout.implicitWidth", plain.implicitWidth)
    kv("layout.implicitHeight", plain.implicitHeight)
    kv("layout.height", plain.height)
    kv("layout.heightIsInputToken", plain.implicitHeight === Ui.inputHeight)
    kv("layout.input.height", plain.input.height)
    kv("layout.inputHeightMatchesBox", plain.input.height === plain.implicitHeight)
    kv("layout.fontSize", plain.fontSize)
    kv("layout.inputFontSize", plain.input.font.pixelSize)
    kv("layout.fontSizeIsFontM", plain.fontSize === Ui.fontM)
    kv("layout.inputFontSizeIsFontM", plain.input.font.pixelSize === Ui.fontM)
    kv("layout.big.fontSize", big.fontSize)
    kv("layout.big.inputFontSize", big.input.font.pixelSize)
    kv("layout.big.implicitHeight", big.implicitHeight)
    kv("layout.big.heightUnchanged", big.implicitHeight === plain.implicitHeight)
    big.fontSize = 12
    kv("layout.big.backToFontM", big.input.font.pixelSize)
    kv("layout.big.heightStillToken", big.implicitHeight === Ui.inputHeight)

    // The text never runs under the chrome.
    plain.text = "abcd"
    kv("layout.text.x", plain.input.x)
    kv("layout.text.xIsLeadInset", plain.input.x === plain.leadInset)
    kv("layout.text.rightEdge", plain.input.x + plain.input.width)
    kv("layout.text.fitsInBox", plain.input.x + plain.input.width <= plain.width)
    plain.text = ""
  }

  // ---- PasswordBox -----------------------------------------------------

  function reportPasswordBox() {
    pwMask.edited.connect(t => {
      pwEditedCount++
      pwEditedLast = t
    })
    pwMask.submitted.connect(() => {
      pwSubmittedCount++
    })
    pwMask.cancelled.connect(() => {
      pwCancelledCount++
    })
    pwMask.capsToggled.connect(() => {
      pwCapsCount++
    })
    pwMask.navigate.connect(d => {
      pwNavCount++
      pwNavDir = d
    })

    kv("pw.default.width", pwMask.width)
    kv("pw.default.height", pwMask.height)
    kv("pw.default.hidden", pwMask.hidden)
    kv("pw.default.revealed", pwMask.revealed)
    kv("pw.default.busy", pwMask.busy)
    kv("pw.default.animated", pwMask.animated)
    kv("pw.default.arrowNavigation", pwMask.arrowNavigation)
    kv("pw.default.placeholder", pwMask.placeholder)
    kv("pw.default.failureText", pwMask.failureText)
    kv("pw.default.failureMs", pwMask.failureMs)
    kv("pw.default.failure", pwMask.failure)
    kv("pw.default.focused", pwMask.focused)
    kv("pw.default.text", pwMask.text)
    kv("pw.default.echoMode", pwMask.input.echoMode)
    kv("pw.default.echoIsPassword", pwMask.input.echoMode === TextInput.Password)
    kv("pw.default.imh", pwMask.input.inputMethodHints)
    kv("pw.default.imhIsSensitive", pwMask.input.inputMethodHints === Qt.ImhSensitiveData)
    kv("pw.default.borderWidth", pwMask.border.width)
    kv("pw.default.radius", pwMask.radius)
    kv("pw.default.prompt.text", promptOf(pwMask) ? promptOf(pwMask).text : "missing")
    kv("pw.default.prompt.visible", promptOf(pwMask) ? promptOf(pwMask).visible : "missing")
    kv("pw.default.prompt.px", promptOf(pwMask) ? promptOf(pwMask).font.pixelSize : "missing")
    kv("pw.default.prompt.bold", promptOf(pwMask) ? promptOf(pwMask).font.bold : "missing")
    kv("pw.default.prompt.spacing", promptOf(pwMask) ? promptOf(pwMask).font.letterSpacing : "missing")

    // No key event exists here, so every key-driven signal must still be at
    // zero after a full round of programmatic text and failure churn.
    kv("pw.signal.edited", pwEditedCount)
    kv("pw.signal.submitted", pwSubmittedCount)
    kv("pw.signal.cancelled", pwCancelledCount)
    kv("pw.signal.capsToggled", pwCapsCount)
    kv("pw.signal.navigate", pwNavCount)
    kv("pw.signal.navigateDir", pwNavDir)
    kv("pw.capsState.notAPropertyOfTheBox", typeof pwMask.capsOn)

    pwMask.text = "s3cret"
    pwRevealed.text = "s3cret"
    pwRevealed.revealed = true
    pwPlainEcho.text = "s3cret"
    pwWiped.text = "s3cret"
    pwFailedRevealed.text = "s3cret"
    pwFailedRevealed.revealed = true
    pwFailedRevealed.fail()

    // Reveal, and the mask it is layered over.
    kv("pw.reveal.hidden", pwRevealed.hidden)
    kv("pw.reveal.revealedBeforeToggle", pwRevealed.revealed)
    pwRevealed.toggleReveal()
    kv("pw.reveal.afterToggle", pwRevealed.revealed)
    pwRevealed.toggleReveal()
    kv("pw.reveal.afterSecondToggle", pwRevealed.revealed)
    pwRevealed.revealed = true
    pwRevealed.toggleReveal()
    kv("pw.reveal.afterThirdToggle", pwRevealed.revealed)
    pwRevealed.revealed = true

    // `hidden: false` is the polkit "echo typed characters" case: plain text
    // regardless of `revealed`.
    kv("pw.plainEcho.hidden", pwPlainEcho.hidden)
    kv("pw.plainEcho.echoMode", pwPlainEcho.input.echoMode)
    kv("pw.plainEcho.isPlain", pwPlainEcho.input.echoMode === TextInput.Normal)
    pwPlainEcho.revealed = true
    kv("pw.plainEcho.stillPlain", pwPlainEcho.input.echoMode === TextInput.Normal)
    pwPlainEcho.hidden = true
    kv("pw.plainEcho.revealedUnmasksHidden", pwPlainEcho.input.echoMode === TextInput.Normal)
    pwPlainEcho.revealed = false
    kv("pw.plainEcho.remasked", pwPlainEcho.input.echoMode === TextInput.Password)
    kv("pw.plainEcho.revealedAloneDoesNotUnmaskHidden", pwPlainEcho.input.echoMode === TextInput.Password)
    pwPlainEcho.hidden = false

    // A failure over a box that has text: the flash shows, the prompt does
    // not, because the prompt only paints while the field is empty.
    kv("pw.failedWithText.failure", pwFailedRevealed.failure)
    kv("pw.failedWithText.text", pwFailedRevealed.text)
    kv("pw.failedWithText.revealed", pwFailedRevealed.revealed)
    kv("pw.failedWithText.promptVisible", promptOf(pwFailedRevealed) ? promptOf(pwFailedRevealed).visible : "missing")
    kv("pw.failedWithText.promptText", promptOf(pwFailedRevealed) ? promptOf(pwFailedRevealed).text : "missing")

    // The failure window, armed at construction so the driver can sample it
    // at both ends of its 1400ms.
    pwWindow.fail()
    kv("pw.window.failure", pwWindow.failure)
    kv("pw.window.failureMs", pwWindow.failureMs)
    kv("pw.window.promptText", promptOf(pwWindow) ? promptOf(pwWindow).text : "missing")
    kv("pw.window.promptVisible", promptOf(pwWindow) ? promptOf(pwWindow).visible : "missing")
    pwShort.fail()
    kv("pw.short.failureMs", pwShort.failureMs)
    kv("pw.short.failure", pwShort.failure)
    pwDouble.fail()
    kv("pw.double.failure", pwDouble.failure)

    // `clearFailure()` on a box that is not failing is a no-op, not a throw.
    kv("pw.quiet.before", pwQuiet.failure)
    pwQuiet.clearFailure()
    kv("pw.quiet.afterNoOpClear", pwQuiet.failure)
    kv("pw.quiet.text", pwQuiet.text)

    // `busy` is a border driver. Whether the field is gated at all is the
    // consumer's `enabled:` binding, so both are read.
    kv("pw.busy.before", pwMask.busy)
    pwMask.busy = true
    kv("pw.busy.set", pwMask.busy)
    kv("pw.busy.enabledUnchanged", pwMask.enabled)
    kv("pw.busy.inputEnabled", pwMask.input.enabled)
    kv("pw.busy.inputReadOnly", pwMask.input.readOnly)
    pwMask.busy = false
    kv("pw.busy.cleared", pwMask.busy)

    // Focus: one box in the window holds it.
    kv("pw.focus.before", pwFocus.focused)
    pwFocus.grabFocus()
    kv("pw.focus.afterGrab", pwFocus.focused)
    kv("pw.focus.isInputActiveFocus", pwFocus.focused === pwFocus.input.activeFocus)
    pwFocusTwin.grabFocus()
    kv("pw.focus.afterTwinGrab", pwFocus.focused)
    kv("pw.focus.twin", pwFocusTwin.focused)
    root.releaseFocusForTest()

    // A password the consumer can read is the point; the mask is for the
    // screen.
    kv("pw.ownerReadback", pwMask.text)
    kv("pw.ownerReadback.isSecret", pwMask.text === "s3cret")

    // The negative contract again, now that every box has been written to,
    // revealed, failed and cleared: still nothing key-driven fired.
    kv("pw.signalAfter.edited", pwEditedCount)
    kv("pw.signalAfter.submitted", pwSubmittedCount)
    kv("pw.signalAfter.cancelled", pwCancelledCount)
    kv("pw.signalAfter.capsToggled", pwCapsCount)
    kv("pw.signalAfter.navigate", pwNavCount)
  }

  // PasswordBox has no releaseFocus(), so the probe hands focus back to a
  // field that has one and the rest of the run starts unfocused.
  function releaseFocusForTest() {
    plain.grabFocus()
  }

  // ---- the event-loop turns -------------------------------------------

  // 40ms in. The chip and the badge are mid-fade, the failure window is still
  // open, and the display rows have settled on their text.
  function onFirstTick() {
    const chip = chipOf(chipFader)
    const badge = badgeOf(pwRevealed)
    kv("anim.eventLoopRan", true)
    kv("anim.chip.opacity", chip ? chip.opacity : "missing")
    kv("anim.chip.opacity.gtZero", chip ? chip.opacity > 0 : false)
    kv("anim.chip.opacity.leOne", chip ? chip.opacity <= 1 : false)
    kv("anim.chip.opacity.inFlight", chip ? (chip.opacity > 0 && chip.opacity < 1) : false)
    kv("anim.chip.visible", chip ? chip.visible : "missing")
    kv("anim.chip.x", chip ? chip.x : "missing")
    kv("anim.chip.leadInset", chipFader.leadInset)
    kv("anim.badge.opacity", badge ? badge.opacity : "missing")
    kv("anim.badge.opacity.inFlight", badge ? (badge.opacity > 0 && badge.opacity < 1) : false)
    kv("anim.badge.width", badge ? badge.width : "missing")

    kv("tick1.fail.window", pwWindow.failure)
    kv("tick1.fail.short", pwShort.failure)
    kv("tick1.fail.quiet", pwQuiet.failure)
    kv("tick1.fail.borderDiffersFromIdle", String(pwWindow.border.color) !== String(pwQuiet.border.color))
    kv("tick1.fail.prompt.text", promptOf(pwWindow) ? promptOf(pwWindow).text : "missing")
    kv("tick1.fail.prompt.px", promptOf(pwWindow) ? promptOf(pwWindow).font.pixelSize : "missing")
    kv("tick1.fail.prompt.bold", promptOf(pwWindow) ? promptOf(pwWindow).font.bold : "missing")
    kv("tick1.fail.prompt.spacing", promptOf(pwWindow) ? promptOf(pwWindow).font.letterSpacing : "missing")
    kv("tick1.fail.prompt.colourIsArgb", /^#[0-9a-fA-F]{8}$/.test(String(promptOf(pwWindow).color)))

    // The display row, one box per echo state.
    kv("glyph.masked.count", glyphCount(pwMask))
    kv("glyph.masked.text", glyphText(pwMask))
    kv("glyph.masked.isAllEcho", isAllEcho(pwMask))
    kv("glyph.masked.matchesTextLength", glyphCount(pwMask) === pwMask.text.length)
    kv("glyph.masked.echoMode", pwMask.input.echoMode)
    kv("glyph.revealed.count", glyphCount(pwRevealed))
    kv("glyph.revealed.text", glyphText(pwRevealed))
    kv("glyph.revealed.isPlaintext", glyphText(pwRevealed) === pwRevealed.text)
    kv("glyph.revealed.echoMode", pwRevealed.input.echoMode)
    kv("glyph.plainEcho.count", glyphCount(pwPlainEcho))
    kv("glyph.plainEcho.text", glyphText(pwPlainEcho))
    kv("glyph.plainEcho.isPlaintext", glyphText(pwPlainEcho) === pwPlainEcho.text)
    kv("glyph.wipedBeforeClear.count", glyphCount(pwWiped))
    kv("glyph.wipedBeforeClear.text", glyphText(pwWiped))
    kv("glyph.wipedBeforeClear.isAllEcho", isAllEcho(pwWiped))
    kv("glyph.wipedBeforeClear.revealed", pwWiped.revealed)

    // A failed authentication re-masks without discarding the retry text.
    kv("fail.revealed.stillRevealed", pwFailedRevealed.revealed)
    kv("fail.revealed.glyphText", glyphText(pwFailedRevealed))
    kv("fail.revealed.isPlaintext", glyphText(pwFailedRevealed) === pwFailedRevealed.text)
    kv("fail.revealed.failureStillOn", pwFailedRevealed.failure)
    kv("fail.revealed.echoMode", pwFailedRevealed.input.echoMode)

    // `clear()` takes the text and the reveal state together.
    pwWiped.text = "typed"
    pwWiped.revealed = true
    pwWiped.clear()
    kv("clear.text", pwWiped.text)
    kv("clear.revealed", pwWiped.revealed)
    pwWiped.revealed = true
    pwWiped.clear()
    kv("clear.revealedAgain", pwWiped.revealed)
    pwWiped.toggleReveal()
    kv("clear.revealedAfterToggle", pwWiped.revealed)
    pwWiped.clear()
    kv("clear.revealedAfterClear", pwWiped.revealed)
    plain.grabFocus()
  }

  // 80ms in. The wiped box's display row has had a turn to catch up with the
  // clear, and the failed box loses its text so the failure text can take
  // the prompt slot. The ghost flip is also sampled here rather than on
  // the first turn: the enter fade holds a short pause, so at 40ms the
  // incoming layer is still at zero while at 80ms both layers are
  // strictly mid-flight (rise and opacity alike).
  function onSecondTick() {
    const gl = ghostLayers(swapper)
    kv("anim.ghost.layers", gl.length)
    if (gl.length === 3) {
      kv("anim.ghost.A.rise", gl[0].rise)
      kv("anim.ghost.A.opacity", gl[0].opacity)
      kv("anim.ghost.B.rise", gl[1].rise)
      kv("anim.ghost.B.opacity", gl[1].opacity)
      kv("anim.ghost.A.exiting", gl[0].rise < 0 && gl[0].rise > -Ui.s && gl[0].opacity > 0 && gl[0].opacity < 1)
      kv("anim.ghost.B.entering", gl[1].rise > 0 && gl[1].rise < Ui.s && gl[1].opacity > 0 && gl[1].opacity < 1)
      kv("anim.ghost.dip", gl[0].opacity + gl[1].opacity < 1)
    }
    kv("tick2.glyph.wiped.count", glyphCount(pwWiped))
    kv("tick2.glyph.wiped.text", glyphText(pwWiped))
    kv("tick2.glyph.wiped.matchesTextLength", glyphCount(pwWiped) === pwWiped.text.length)
    kv("tick2.glyph.masked.matchesTextLength", glyphCount(pwMask) === pwMask.text.length)
    kv("tick2.glyph.plainEcho.matchesTextLength", glyphCount(pwPlainEcho) === pwPlainEcho.text.length)
    kv("tick2.glyph.modelFollowsText", glyphCount(pwWiped) === 0)

    pwFailedRevealed.clear()
    kv("tick2.fail.withText.textCleared", pwFailedRevealed.text)
    kv("tick2.fail.withText.failureSurvivedClear", pwFailedRevealed.failure)
    kv("tick2.fail.withText.revealedAfterClear", pwFailedRevealed.revealed)
  }

  // 320ms in: the 300ms window has closed, the 1400ms one has not.
  function onEighthTick() {
    kv("tick8.fail.shortExpired", pwShort.failure)
    kv("tick8.fail.windowStillOn", pwWindow.failure)
    kv("tick8.fail.doubleStillOn", pwDouble.failure)
    kv("tick8.fail.quietStillOff", pwQuiet.failure)
    kv("tick8.fail.shortPrompt", promptOf(pwShort) ? promptOf(pwShort).text : "missing")
    kv("tick8.fail.windowPrompt", promptOf(pwWindow) ? promptOf(pwWindow).text : "missing")
    kv("tick8.fail.withText.promptText", promptOf(pwFailedRevealed)
      ? promptOf(pwFailedRevealed).text : "missing")
    kv("tick8.fail.withText.promptVisible", promptOf(pwFailedRevealed)
      ? promptOf(pwFailedRevealed).visible : "missing")
    kv("tick8.fail.withText.promptPx", promptOf(pwFailedRevealed)
      ? promptOf(pwFailedRevealed).font.pixelSize : "missing")
    kv("tick8.fail.withText.promptBold", promptOf(pwFailedRevealed)
      ? promptOf(pwFailedRevealed).font.bold : "missing")
    plain.releaseFocus()
  }

  // 600ms. The palette has landed and every tween has finished, so this is
  // the first moment a border colour means what it says.
  function onSettle() {
    kv("settle.motion.duration100", MotionPolicy.duration(100))
    kv("settle.chip.opacity", chipOf(chipFader) ? chipOf(chipFader).opacity : "missing")
    kv("settle.chip.visible", chipOf(chipFader) ? chipOf(chipFader).visible : "missing")
    kv("settle.chip.x", chipOf(chipFader) ? chipOf(chipFader).x : "missing")
    kv("settle.chip.leadInset", chipFader.leadInset)
    kv("settle.chip.leadInsetIsChipPlusGaps", chipFader.leadInset === 2 * Ui.s + chipOf(chipFader).width)
    kv("settle.badge.opacity", badgeOf(pwRevealed) ? badgeOf(pwRevealed).opacity : "missing")

    // The flip landed and the retire timer ran: the outgoing layer
    // rests invisible back in the staging slot below (+8), the
    // incoming one sits at rest (0, opaque), the third never moved -
    // still staged below and invisible. The overlay reads the new
    // string and still shows (empty field, unfocused).
    const gl2 = ghostLayers(swapper)
    kv("settle.ghost.layers", gl2.length)
    if (gl2.length === 3) {
      kv("settle.ghost.A.rise", gl2[0].rise)
      kv("settle.ghost.A.opacity", gl2[0].opacity)
      kv("settle.ghost.B.rise", gl2[1].rise)
      kv("settle.ghost.B.opacity", gl2[1].opacity)
      kv("settle.ghost.C.rise", gl2[2].rise)
      kv("settle.ghost.C.opacity", gl2[2].opacity)
    }
    kv("settle.ghost.text", ghostItem(swapper) ? ghostItem(swapper).text : "missing")
    kv("settle.ghost.shown", ghostItem(swapper) ? ghostItem(swapper).shown : "missing")

    lateQuietPre = String(lateQuiet.border.color)
    lateStillPre = String(lateStill.border.color)
    kv("settle.border.preFail.quiet", lateQuietPre)
    kv("settle.border.preFail.still", lateStillPre)
    kv("settle.border.preFail.equal", lateQuietPre === lateStillPre)
    kv("settle.border.preFail.isBackground3", lateQuietPre === Theme.color("background_3"))
    kv("settle.theme.red", Theme.color("red"))

    // The second fail on the same box: a restart moves the deadline to
    // 600 + 1400, a double-extend would put it at 1400 + 1400. The driver
    // samples at 2100ms, which separates the two.
    pwDouble.fail()
    kv("settle.double.failureAfterSecondFail", pwDouble.failure)
    lateQuiet.fail()
    lateStill.fail()
    kv("settle.late.quiet.failure", lateQuiet.failure)
    kv("settle.late.still.failure", lateStill.failure)
  }

  // 120ms into a 150ms cross-fade.
  function onMid() {
    kv("mid.late.quiet.border", String(lateQuiet.border.color))
    kv("mid.late.still.border", String(lateStill.border.color))
    kv("mid.late.quiet.landed", String(lateQuiet.border.color) === Theme.color("red"))
    kv("mid.late.quiet.movedOffPre", String(lateQuiet.border.color) !== lateQuietPre)
    kv("mid.late.still.landed", String(lateStill.border.color) === Theme.color("red"))
  }

  // 500ms into that cross-fade: landed.
  function onLand() {
    kv("land.late.quiet.border", String(lateQuiet.border.color))
    kv("land.late.quiet.onRed", String(lateQuiet.border.color) === Theme.color("red"))
    kv("land.late.still.onRed", String(lateStill.border.color) === Theme.color("red"))
    kv("land.window.stillFailing", pwWindow.failure)
    kv("land.window.prompt", promptOf(pwWindow) ? promptOf(pwWindow).text : "missing")
    kv("land.window.promptBold", promptOf(pwWindow) ? promptOf(pwWindow).font.bold : "missing")
  }

  // Past 1400ms from construction, short of the 600 + 1400 deadline. The
  // border is still cross-fading back here (100ms into 150ms), so its colour
  // is read once everything has settled, in onRest.
  function onHalf() {
    kv("half.window.expired", pwWindow.failure)
    kv("half.double.stillOn", pwDouble.failure)
    kv("half.short.expired", pwShort.failure)
    kv("half.window.prompt", promptOf(pwWindow) ? promptOf(pwWindow).text : "missing")
    kv("half.window.promptPx", promptOf(pwWindow) ? promptOf(pwWindow).font.pixelSize : "missing")
    kv("half.window.promptBold", promptOf(pwWindow) ? promptOf(pwWindow).font.bold : "missing")
    kv("half.window.promptSpacing", promptOf(pwWindow) ? promptOf(pwWindow).font.letterSpacing : "missing")
    kv("half.window.border", String(pwWindow.border.color))
    kv("half.theme.background3", Theme.color("background_3"))
    kv("half.window.borderStillFading", String(pwWindow.border.color) !== Theme.color("background_3"))
  }

  // Past 600 + 1400: the second fail restarted the window rather than
  // extending it by another full interval.
  function onRest() {
    kv("rest.double.expired", pwDouble.failure)
    kv("rest.window.expired", pwWindow.failure)
    kv("rest.short.expired", pwShort.failure)
    kv("rest.quiet.neverFailed", pwQuiet.failure)
    kv("rest.text", pwMask.text)
    kv("rest.glyph.masked.stillMasked", isAllEcho(pwMask))
    kv("rest.glyph.revealed.stillPlain", glyphText(pwRevealed) === pwRevealed.text)
    kv("rest.masked.stillMasked", pwMask.input.echoMode === TextInput.Password)
    kv("rest.promptBack", promptOf(pwMask) ? promptOf(pwMask).text : "missing")
    kv("rest.imh.stillSensitive", pwMask.input.inputMethodHints === Qt.ImhSensitiveData)
    // 700ms after the 1400ms window closed, so the border has landed on the
    // idle colour again.
    kv("rest.window.border", String(pwWindow.border.color))
    kv("rest.window.borderBackToIdle", String(pwWindow.border.color) === Theme.color("background_3"))
    kv("rest.short.borderBackToIdle", String(pwShort.border.color) === Theme.color("background_3"))
    kv("rest.done", true)
    console.log("##DONE##")
  }

  // ---- readback helpers ------------------------------------------------

  // The shell-painted ghost overlay (InputField's ghostBox, objectName
  // "ghost"). Qt's native placeholder item stays blank - it can only
  // snap - so every placeholder assertion reads the overlay: `text`
  // is the string fading (or faded) in, `shown` the synchronous show
  // rule underneath the animated box opacity.
  function ghostItem(p) {
    const kids = p.children || []
    for (let i = 0; i < kids.length; i++) {
      const n = kids[i]
      if (n && n.objectName === "ghost") return n
    }
    return null
  }

  // The library SlideSwap inside the ghost overlay: the box owns
  // the show rule, the swap owns the travel.
  function ghostSwap(p) {
    const o = ghostItem(p)
    const kids = o ? (o.children || []) : []
    return kids.length > 0 ? kids[0] : null
  }

  // The three slide layers, in declaration order (A first), exposed
  // through the library SlideSwap. Rise is 0 at rest, +Ui.s staged
  // below, -Ui.s exiting above.
  function ghostLayers(p) {
    const o = ghostItem(p)
    const slides = o ? o.slides : []
    return slides || []
  }

  // The painted ghost needs a shown overlay and a non-empty string.
  // Unlike Qt's old item (which stayed visible and emptied its string
  // when ghostWhileFocused hid it), the overlay keeps its string and
  // hides through opacity, so `shown` is the whole answer.
  function paints(p) {
    const it = ghostItem(p)
    if (!it) return "missing"
    return it.shown && it.text !== "" ? "true" : "false"
  }

  // PasswordBox draws its own prompt, as a direct child of the box.
  function promptOf(p) {
    const kids = p.children || []
    for (let i = 0; i < kids.length; i++) {
      const n = kids[i]
      if (!n || n === p.input) continue
      if (n.text !== undefined && n.elide !== undefined && typeof n.wrapMode === "number") return n
    }
    return null
  }

  function chipOf(p) {
    const kids = p.children || []
    for (let i = 0; i < kids.length; i++) {
      const n = kids[i]
      if (n && n.boxed !== undefined && n.radius !== undefined && n.text !== undefined) return n
    }
    return null
  }

  // The two 9x1.5 bars at +-45 degrees are the clear affordance; the
  // MouseArea plus Icon pair is the eye. Both sit among three children, so the
  // rotated rectangles are looked for rather than counted.
  function clearAffordance(p) {
    const kids = p.children || []
    for (let i = 0; i < kids.length; i++) {
      const n = kids[i]
      if (!n) continue
      const inner = n.children || []
      let plus = false
      let minus = false
      for (let j = 0; j < inner.length; j++) {
        if (inner[j].rotation === 45) plus = true
        if (inner[j].rotation === -45) minus = true
      }
      if (plus && minus) return n
    }
    return null
  }

  function eyeAffordance(p) {
    const kids = p.children || []
    for (let i = 0; i < kids.length; i++) {
      const n = kids[i]
      if (!n) continue
      const inner = n.children || []
      if (inner.length === 2 && typeof inner[1].name === "string") return n
    }
    return null
  }

  function eyeGlyphName(eye) {
    const inner = eye.children || []
    return inner.length === 2 ? inner[1].name : "missing"
  }

  function counterRowOf(p) {
    const kids = p.children || []
    for (let i = 0; i < kids.length; i++) {
      const n = kids[i]
      if (n && n.spacing !== undefined && n.text === undefined) return n
    }
    return null
  }

  function counterText(p) {
    const row = counterRowOf(p)
    if (!row) return "missing"
    const kids = row.children || []
    let out = ""
    for (let i = 0; i < kids.length; i++) {
      if (kids[i].text !== undefined) out += kids[i].text
    }
    return out
  }

  // The widest descendant rectangle of the box is the reveal badge; the two
  // nested ones are its lens and pupil.
  function badgeOf(p) {
    const all = descendants(p, [])
    let best = null
    for (let i = 0; i < all.length; i++) {
      const n = all[i]
      if (!n || n === p || n.border === undefined || n.radius === undefined) continue
      if (n.text !== undefined) continue
      if (!best || n.width > best.width) best = n
    }
    return best
  }

  function descendants(o, out) {
    const kids = o.children || []
    for (let i = 0; i < kids.length; i++) {
      out.push(kids[i])
      descendants(kids[i], out)
    }
    return out
  }

  // The per-glyph display row. Reading it reaches into the Repeater's
  // delegates, so this is only ever called on a box whose text has been
  // stable for at least one event-loop turn.
  function repeaterOf(p) {
    const all = descendants(p, [])
    for (let i = 0; i < all.length; i++) {
      const n = all[i]
      if (n && typeof n.count === "number" && typeof n.itemAt === "function") return n
    }
    return null
  }

  function glyphCount(p) {
    const r = repeaterOf(p)
    return r ? r.count : -1
  }

  function glyphText(p) {
    const r = repeaterOf(p)
    if (!r) return "missing"
    let out = ""
    for (let i = 0; i < r.count; i++) {
      const it = r.itemAt(i)
      if (it && it.text !== undefined) out += it.text
    }
    return out
  }

  function isAllEcho(p) {
    const n = p.text.length
    if (n === 0) return "empty"
    const t = glyphText(p)
    return t.length === n && t === Ui.passwordEcho.repeat(n) ? "true" : "false"
  }

  function featureCount(p) {
    return Object.keys(p.input.font.features).length
  }

  function featureKeys(p) {
    return Object.keys(p.input.font.features).sort().join(",")
  }

  // The ligature freeze is bound to the echo mode, not to the sensitive flag.
  function tieToEcho(p) {
    const frozen = featureCount(p) === 5
    return (p.input.echoMode === TextInput.Password) === frozen ? "tied" : "untied"
  }
}
