// Probe: the number picker's numeric filter, headless, against the shell's own
// bytes.
//
// The bug this exists for is a Qt rule, not a shell rule, and the rule is
// this: a QValidator applies to a field only while the text ALREADY in it is
// one the validator accepts. Measured on this Qt (6.12.0) with real
// synthesised key events, through qmltestrunner on a bare TextInput carrying
// the same DoubleValidator:
//
//   seeded "5"     + key "a"     ->  "5"        the letter is refused
//   seeded "5min"  + key "a"     ->  "5mina"    the letter lands
//   seeded "5min"  + keys "b.c"  ->  "5minab.c" everything lands
//
// The picker used to seed its field with the value PLUS the read-only unit
// ("5 min") - a string its own validator can never accept - so on every
// number row that declares a unit the numeric filter was silently off and the
// field took letters. The unit is chrome the picker paints now, and the field
// holds the value alone, which is the whole condition the Qt rule makes
// load-bearing: what is asserted here is that the field never holds anything
// its own validator would refuse, and that the unit is on screen beside it
// rather than inside it.
//
// The picker's own source is read from disk and evaluated, because a stand-in
// TextInput would not have the seed, the unit chrome or the commit wiring that
// produced the bug. Two import lines are rewritten - the module that reaches
// Menu -> MenuView -> a PanelWindow backend offscreen does not have, and the
// sibling MenuLib path - and both counts are reported and asserted, so a
// picker that starts using a module type turns this suite red instead of
// quietly testing something else. The seed itself lives one file up, in
// InlineEditor, so the driver asserts it there by reading the file: the
// feature layer is not constructible headlessly and a wrong claim about it
// from a probe would be worth nothing.
//
// What is NOT covered here, and is not claimed: the keystrokes themselves. `qs`
// offers no way to post a key event, and the real component cannot be loaded
// into qmltestrunner (its module reaches the PanelWindow backend). The Qt rule
// is quoted above with the harness that measured it; the shell-side condition
// it makes load-bearing is what this suite asserts.

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
  property var input: null
  property var suffix: null

  property int acceptedCount: 0
  property string acceptedLast: "none"
  property int escapedCount: 0
  property int invalidCount: 0
  property string invalidLast: "none"

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  // Reached by what an item is, not by an id the component does not export:
  // the field is the one carrying a validator, the unit is the one painting
  // the suffix string.
  function findByPredicate(item, test) {
    if (item === null) return null
    if (test(item)) return item
    const kids = item.children
    for (let i = 0; i < kids.length; i++) {
      const hit = findByPredicate(kids[i], test)
      if (hit !== null) return hit
    }
    return null
  }

  function resolveParts() {
    root.input = findByPredicate(root.picker, i => i.validator !== undefined && i.insert !== undefined)
    root.suffix = findByPredicate(root.picker, i => typeof i.text === "string"
      && i.text === root.picker.unitSuffix)
  }

  // ---- the shell's own picker ----------------------------------------------

  function readPicker() {
    const xhr = new XMLHttpRequest()
    xhr.open("GET", "features/menu/NumberPicker.qml", false)
    xhr.send()
    root.pickerSourceStatus = xhr.status
    root.pickerSource = xhr.responseText || ""
  }

  function buildPicker() {
    const kept = []
    root.moduleImportDropped = 0
    for (const l of root.pickerSource.split("\n")) {
      if (/^import qs\.features\.menu$/.test(l)) {
        root.moduleImportDropped++
        continue
      }
      kept.push(l)
    }
    const stripped = kept.join("\n")
    const rerooted = stripped.replace('import "MenuLib.js" as MenuLib',
      'import "features/menu/MenuLib.js" as MenuLib')
    root.siblingImportRerooted = rerooted === stripped ? 0 : 1
    root.picker = Qt.createQmlObject(rerooted, root, "headless_number_picker.qml")
    root.pickerMade = 1
  }

  // The shipped Timer row, verbatim from the utilities page in shell/common/settings/catalog.jsonc:
  // type number, min 1, max 180, step 1, value 5, unit "min".
  function seedFromTheRow() {
    root.picker.width = 240
    root.picker.value = 5
    root.picker.decimals = 0
    root.picker.minimum = 1
    root.picker.maximum = 180
    root.picker.stepSize = 1
    root.picker.unitSuffix = "min"
    // What InlineEditor does on its own completion: the value, nothing else.
    root.picker.text = root.picker.formatted(root.picker.value)
    resolveParts()
  }

  // Where the input actually draws its own digits: the field centres them
  // inside the box its right padding leaves, and the padding is the unit's
  // share of the pair. Read here rather than assumed, so the geometry the
  // suite asserts is measured against the component's real arrangement.
  function digitsLeft() {
    return input.x + (input.width - input.rightPadding - digits.width) / 2
  }

  // The value's own width, measured the same way the component measures it,
  // so the unit's position can be checked against where it belongs rather
  // than against a literal.
  TextMetrics {
    id: digits

    font: input.font
    text: input.text
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
      else if (root.phase === 6) finish()
    }
  }

  // 1: what the field holds on a row that declares a unit. This is the whole
  // bug: a field whose text its own validator refuses has no filter at all.
  function onFirstTurn() {
    kv("np.seed.text", JSON.stringify(root.picker.text))
    kv("np.seed.value", root.picker.value)
    kv("np.seed.unit", root.picker.unitSuffix)
    kv("np.seed.hasUnitInText", root.picker.text.indexOf(root.picker.unitSuffix) >= 0)
    kv("np.seed.isValueAlone", root.picker.text === root.picker.formatted(root.picker.value))
    kv("np.field.text", JSON.stringify(root.input.text))
    kv("np.field.hasValidator", root.input.validator !== null)
    kv("np.suffix.text", root.suffix === null ? "none" : root.suffix.text)
    kv("np.suffix.visible", root.suffix !== null && root.suffix.visible)
    // Where the unit sits relative to the digits it follows, and to the field
    // it lives in. The input centres its own text inside the box its right
    // padding leaves, so that is where the digits start - and the gap behind
    // the last digit is the gap the user sees.
    kv("np.suffix.digitsLeft", digitsLeft().toFixed(2))
    kv("np.suffix.gap", root.suffix === null ? "none"
      : (root.suffix.x - (digitsLeft() + digits.width)).toFixed(2))
    kv("np.suffix.roomAtRight", root.suffix === null ? "none"
      : ((root.input.x + root.input.width) - (root.suffix.x + root.suffix.width)).toFixed(2))
    kv("np.suffix.roomAtLeft", root.suffix === null ? "none"
      : ((digitsLeft() - root.input.x)).toFixed(2))
  }

  // 2: focus through the component's own entry point, and what it selects.
  function onSecondTurn() {
    root.picker.grabFocus()
    kv("np.focus.owner", root.input.activeFocus ? "field" : "other")
    kv("np.focus.selected", JSON.stringify(root.input.selectedText))
    kv("np.focus.allSelected", root.input.selectedText === root.input.text)
  }

  // 3: the two writes the component makes into its own field, both of which
  // used to carry the unit, and the commit that reads it back out.
  function onThirdTurn() {
    root.picker.step(1)
    kv("np.step.text", JSON.stringify(root.picker.text))
    kv("np.step.value", root.picker.value)
    kv("np.step.hasUnitInText", root.picker.text.indexOf(root.picker.unitSuffix) >= 0)
    root.picker.commit()
    kv("np.commit.count", root.acceptedCount)
    kv("np.commit.value", root.acceptedLast)

    root.input.text = ""
    root.picker.commit()
    kv("np.empty.escaped", root.escapedCount)
    kv("np.empty.accepted", root.acceptedCount)

    root.input.text = "abc"
    root.picker.commit()
    kv("np.garbage.invalid", root.invalidCount)
    kv("np.garbage.restored", JSON.stringify(root.picker.text))
    kv("np.garbage.error", root.invalidLast)
    kv("np.legacy.valueEnd", typeof root.picker.valueEnd)
    kv("np.legacy.clampCursor", typeof root.picker.clampCursor)
    kv("np.height", root.picker.height)
  }

  // 4: a longer unit than the shipped row's. The unit's width is the input's
  // right padding and half the pair's centring, so a longer one is where a
  // placement that only worked for "min" would come apart.
  function onFourthTurn() {
    root.picker.unitSuffix = "pixels"
    kv("np.long.unit", root.picker.unitSuffix)
    kv("np.long.gap", (root.suffix.x - (digitsLeft() + digits.width)).toFixed(2))
    kv("np.long.roomAtRight", ((root.input.x + root.input.width)
      - (root.suffix.x + root.suffix.width)).toFixed(2))
    kv("np.long.roomAtLeft", (digitsLeft() - root.input.x).toFixed(2))
    kv("np.long.insideField", root.suffix.x + root.suffix.width
      <= root.input.x + root.input.width)
    kv("np.long.textStillBare", JSON.stringify(root.picker.text))
  }

  // 5: and back to the shipped row's unit, to show the arrangement is a
  // function of the unit rather than a one-off placement.
  function onFifthTurn() {
    root.picker.unitSuffix = "min"
    kv("np.back.unit", root.picker.unitSuffix)
    kv("np.back.gap", (root.suffix.x - (digitsLeft() + digits.width)).toFixed(2))
    kv("np.back.roomAtRight", ((root.input.x + root.input.width)
      - (root.suffix.x + root.suffix.width)).toFixed(2))
  }

  function finish() {
    pump.stop()
    console.log("##DONE##")
  }
  Component.onCompleted: {
    kv("np.error", "none")
    try {
      readPicker()
      buildPicker()
      kv("np.status", root.pickerSourceStatus)
      kv("np.len", root.pickerSource.length)
      kv("np.moduleDropped", root.moduleImportDropped)
      kv("np.siblingRerooted", root.siblingImportRerooted)
      kv("np.made", root.pickerMade)
      root.picker.accepted.connect(v => { root.acceptedCount++; root.acceptedLast = String(v) })
      root.picker.escaped.connect(() => { root.escapedCount++ })
      root.picker.invalid.connect(msg => { root.invalidCount++; root.invalidLast = msg })
      seedFromTheRow()
      kv("np.field.found", root.input !== null)
      kv("np.suffix.found", root.suffix !== null)
    } catch (e) {
      kv("np.error", "" + (e && e.message ? e.message : e))
      console.log("##DONE##")
    }
  }
}
