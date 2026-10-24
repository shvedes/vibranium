// Probe: PanelFocus's window re-seat against a consumer's own editors,
// headless, in a real Window.
//
// The rule under test is one gate in PanelFocus.qml: an automatic focus
// request is owed only while nothing in the surface holds focus. This
// primitive owns two focus items - the search field and the sink - and every
// other one in a panel surface belongs to the consumer, an editor inside a
// dropdown slot being the ordinary one. The window reports those exactly like
// it reports the panel's own, so a re-seat that runs on every focus change is
// a focus war rather than a heal: the turn an editor takes focus the window
// announces a new focus item and the panel takes it straight back, leaving a
// number picker or a text field that cannot be typed into and cannot be
// clicked into either.
//
// The order is the shape of a real session, and both halves of the rule need
// it. A fresh window sits on Qt's content-item placeholder - the "nobody is
// focused" state, which is what a panel whose focus request the compositor's
// keyboard grant cost it is left in - so the heal runs first and seats the
// sink. The editors open afterwards, and the gate is what stops the fight.
//
// Two windows would stage these halves better but cannot: under offscreen a
// second visible window takes the focus bookkeeping with it and the first
// window's items stop being able to take focus at all (measured, not
// assumed), which would make the whole probe vacuous.
//
// The editors are the shell's own. NumberPicker is read from disk and
// evaluated (see below); the text editor is the real InputField, which is
// what InlineEditor hands focus to. Both are entered through `grabFocus()`,
// the call InlineEditor.takeFocus() makes on either of them.
//
// NumberPicker cannot simply be written out as a type. `qs.features.menu`
// declares `singleton Menu`, and the module pulls in MenuView -> OverlayWindow
// -> ScrimWindow -> a PanelWindow backend that offscreen does not have, so
// importing the module at all fails to load. Two lines are therefore
// rewritten and nothing else:
//
//   * `import qs.features.menu` - the module load above. NumberPicker
//     references no type from it; MenuLib arrives on the next line.
//   * `import "MenuLib.js"` - the rewritten file is evaluated from the
//     config root, so a sibling-relative import no longer resolves.
//
// Both rewrites are reported and asserted, so a NumberPicker that starts
// using a module type turns this suite red instead of quietly testing
// something else. The file's own grabFocus(), TextInput, validator, caret
// clamp and OK button are its own bytes.
//
// Why a Window and not an Item: the bug lives on QQuickWindow, PanelFocus
// watches `Window.window.activeFocusItemChanged`, and `forceActiveFocus()`
// against an item with no window is a no-op - a probe without one would
// assert the absence of a fight that could not have happened. Offscreen
// reports `window.active === true` from the first turn, which is what makes
// the handler reachable at all.
//
// What is NOT covered here, and is not claimed: the InlineEditor's own
// takeFocus() (two lines, dispatching to the two editors under test, and its
// module is the one that cannot load offscreen), anything a keystroke would
// do - there is no compositor and no QTest, so what a focused field does with
// a key is out of reach - and the pre-grant case itself, a focus request made
// while the surface is still inactive, which needs a compositor to stage. All
// three are skips in the driver.
//
// Everything is read on a later event-loop turn: `forceActiveFocus()` only
// takes effect from the first one.

import QtQuick
import Quickshell
import qs.common

Window {
  id: root

  width: 700
  height: 520
  visible: true

  property int phase: 0

  property string pickerSource: ""
  property int pickerSourceStatus: 0
  property int moduleImportDropped: 0
  property int siblingImportRerooted: 0
  property int pickerMade: 0
  property var picker: null

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function who(item) {
    if (item === null) return "none"
    if (item === root.contentItem) return "content"
    if (item === focusCtrl.keySink) return "sink"
    if (item === searchField.input) return "search"
    if (item === textField.input) return "editor-text"
    return "editor"
  }

  // The text of the item that currently owns focus. Both editors' fields
  // carry `text`; a key sink carries none. So this answers "is the field the
  // user types into the active focus item", and it names the number picker's
  // own TextInput by the seeded display value rather than by an id the
  // component does not export.
  function ownerText() {
    const it = root.activeFocusItem
    if (it === null) return "none"
    if (it.text === undefined) return "untyped"
    return String(it.text)
  }

  // ---- the panel under test ------------------------------------------------

  InputField { id: searchField; x: 0; y: 0; width: 240 }

  PanelFocus {
    id: focusCtrl

    searchField: searchField
    serviceVisible: true
  }

  // The text editor of an expanded row: the field InlineEditor shows for a
  // text or prompt row, where a dropdown's body would put it - beside the
  // panel's own chrome, in the same window.
  InputField { id: textField; x: 0; y: 80; width: 240; text: "hello" }

  // ---- the number picker, from the shell's own bytes -----------------------

  function readPicker() {
    const xhr = new XMLHttpRequest()
    xhr.open("GET", "features/menu/NumberPicker.qml", false)
    xhr.send()
    root.pickerSourceStatus = xhr.status
    root.pickerSource = xhr.responseText || ""
  }

  function buildPicker() {
    const src = root.pickerSource
    // The module import: dropped whole lines, counted, and asserted.
    const lines = src.split("\n")
    const kept = []
    root.moduleImportDropped = 0
    for (let i = 0; i < lines.length; i++) {
      if (/^import qs\.features\.menu$/.test(lines[i])) {
        root.moduleImportDropped++
        continue
      }
      kept.push(lines[i])
    }
    const stripped = kept.join("\n")
    // The sibling import: re-rooted at the config root, because that is where
    // the rewritten text is evaluated from.
    const rerooted = stripped.replace('import "MenuLib.js" as MenuLib',
      'import "features/menu/MenuLib.js" as MenuLib')
    root.siblingImportRerooted = rerooted === stripped ? 0 : 1
    root.picker = Qt.createQmlObject(rerooted, root, "headless_number_picker.qml")
    root.picker.x = 0
    root.picker.y = 160
    root.picker.width = 240
    root.picker.text = "42"
    root.pickerMade = 1
  }

  // ---- the event loop ------------------------------------------------------

  Timer {
    id: pump

    interval: 40
    repeat: true
    running: true
    onTriggered: {
      root.phase++
      if (root.phase === 1) onFirstTurn()
      else if (root.phase === 2) onSecondTurn()
      else if (root.phase === 3) onThirdTurn()
      else if (root.phase === 4) onFourthTurn()
      else if (root.phase === 5) onFifthTurn()
      else if (root.phase === 6) onSixthTurn()
      else if (root.phase === 7) onSeventhTurn()
      else if (root.phase === 8) onEighthTurn()
      else if (root.phase === 9) onNinthTurn()
      else if (root.phase === 10) onTenthTurn()
      else if (root.phase === 11) onEleventhTurn()
      else if (root.phase === 12) finish()
    }
  }

  // 1: a fresh window, before anything has been focused. The content item
  // holds Qt's placeholder focus, the gate reads that as unowned, and the
  // re-seat runs - the panel whose focus request the keyboard grant cost it.
  // Nothing here calls the gate by name, so this turn also measures the heal
  // against a primitive that has no such function.
  function onFirstTurn() {
    kv("focus.window.active", root.active)
    kv("focus.turn1.owner", who(root.activeFocusItem))
    kv("focus.turn1.sink", focusCtrl.keySink.activeFocus)
    focusCtrl.reseat()
  }

  function onSecondTurn() {
    kv("focus.turn2.sink", focusCtrl.keySink.activeFocus)
    kv("focus.turn2.unowned", focusCtrl.unowned())
    focusCtrl.grabList()
  }

  // 3: a number row opens its editor. grabFocus() is the call
  // InlineEditor.takeFocus() makes on the picker.
  function onThirdTurn() {
    kv("focus.turn3.sink", focusCtrl.keySink.activeFocus)
    root.picker.grabFocus()
  }

  // 4: the turn the window reports the new focus item - the turn a re-seat
  // on every focus change answers by taking it straight back.
  function onFourthTurn() {
    kv("focus.turn4.owner", who(root.activeFocusItem))
    kv("focus.turn4.text", ownerText())
    kv("focus.turn4.mode", focusCtrl.mode)
    kv("focus.turn4.probe", JSON.stringify(focusCtrl.probe()))
  }

  function onFifthTurn() {
    kv("focus.turn5.owner", who(root.activeFocusItem))
    kv("focus.turn5.text", ownerText())
    kv("focus.turn5.sink", focusCtrl.keySink.activeFocus)
  }

  // 6: filter mode, the state a row is reached in after a query: the panel's
  // own field is now what a re-seat would hand focus to.
  function onSixthTurn() {
    focusCtrl.grabFilter()
    kv("focus.turn6.mode", focusCtrl.mode)
    kv("focus.turn6.owner", who(root.activeFocusItem))
  }

  // 7: a text row opens its editor, over the field that is now the panel's.
  function onSeventhTurn() {
    textField.grabFocus()
    kv("focus.turn7.owner", who(root.activeFocusItem))
    kv("focus.turn7.text", ownerText())
  }

  // 8: the field auto-watch is the other half of the gate. A field that lost
  // focus to an editor in its own surface is not healed.
  function onEighthTurn() {
    kv("focus.turn8.owner", who(root.activeFocusItem))
    kv("focus.turn8.text", ownerText())
    kv("focus.turn8.mode", focusCtrl.mode)
  }

  // 9: the gate itself, called directly with an editor holding focus. It owes
  // nothing, so it must move nothing.
  function onNinthTurn() {
    kv("focus.turn9.unowned", focusCtrl.unowned())
    focusCtrl.reseat()
  }

  function onTenthTurn() {
    kv("focus.turn10.owner", who(root.activeFocusItem))
    kv("focus.turn10.text", ownerText())
    // The consumer's own lever, for contrast. reassert() is an explicit
    // request and answers it: in filter mode it takes the field back, which is
    // why MenuPanel has its own editor-aware reassertFocus rather than
    // delegating. Recorded, not asserted - the automatic paths are the claim.
    focusCtrl.reassert()
  }

  function onEleventhTurn() {
    kv("focus.turn11.owner", who(root.activeFocusItem))
    kv("focus.turn11.text", ownerText())
  }

  function finish() {
    pump.stop()
    console.log("##DONE##")
  }

  Component.onCompleted: {
    kv("focus.error", "none")
    try {
      readPicker()
      buildPicker()
      kv("focus.picker.status", root.pickerSourceStatus)
      kv("focus.picker.len", root.pickerSource.length)
      kv("focus.picker.moduleImportsDropped", root.moduleImportDropped)
      kv("focus.picker.siblingRerooted", root.siblingImportRerooted)
      kv("focus.picker.height", root.picker.height)
      // Before anything has asked for focus: Qt hands the window's content
      // item its placeholder focus at creation. The probe has asked for
      // nothing at this point, so the panel holding its sink on turn 1 is the
      // re-seat, not an ask.
      kv("focus.pre.owner", who(root.activeFocusItem))
      kv("focus.pre.sink", focusCtrl.keySink.activeFocus)
    } catch (e) {
      kv("focus.error", "" + (e && e.message ? e.message : e))
      console.log("##DONE##")
    }
  }
}
