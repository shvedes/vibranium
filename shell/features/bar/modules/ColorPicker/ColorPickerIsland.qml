pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import "ColorMath.js" as ColorMath

// Color picker island: the history section (five fixed rows, overflow
// under the scrollbar, a red clear-all button below) and the picker
// section - a large saturation/value field with a circular thumb, a hue
// (rainbow) slider and an opacity slider over the conventional
// checkerboard.
//
// Every part of the card has a fixed height, so the island size is
// static: it never resizes when the history fills or empties.
//
// Picker edits are copy-on-write: the preview updates live but nothing
// lands in the persisted history until the user confirms through Copy or
// Add. Copy puts the requested format on the clipboard and closes the
// island only after the copy command was accepted; Add lands the color
// and keeps the island open.
//
// The sv field, the hue slider and the alpha slider all write `picked`
// on every pointer move while dragging, and nothing persists until the
// user confirms through Copy or Add: a colour that is never committed is
// a colour the user changed their mind about.
Item {
  id: root

  property int islandContentWidth: 320
  // The card's padded body holds the content: add the outer padding to
  // the content's implicit height so nothing clips. Read off the live
  // body while the host shows this island; the host freezes the last
  // live footprint for the closed window.
  property int islandContentHeight: Math.ceil(body.implicitHeight) + 2 * Ui.outerPad
  property bool islandSelfAnimating: false
  property var islandHost: null

  // History records passed down from the module; the module owns the
  // store, the island never writes it directly.
  property var records: []
  // Set from the module: add a normalized record and persist.
  property var addRecord: null
  // Set from the module: delete one record (by reference) and persist.
  property var removeRecord: null
  // Set from the module: drop the whole history and persist.
  property var clearAll: null
  // Set from the module: put one serialized string on the clipboard and
  // report back through onCopyDone(ok) once the copy command settled.
  property var copyColor: null
  // Set from the module: move an existing entry (by key) to the front
  // without re-adding it.
  property var promoteRecord: null
  // Set from the module: the remembered preview colour + hue, or null on a
  // first run. Read once, on open.
  property var workingState: null
  // Set from the module: report the live preview so it survives the session.
  property var reportWorking: null

  // Stand the shared key router down while the code field holds the
  // keyboard. The router runs its key map with Keys.BeforeItem priority,
  // so without this the arrows would walk the island instead of moving
  // the caret, and Escape would close the island instead of ending the
  // edit the field is in the middle of.
  readonly property bool blockedNavKeys: codeField.focused === true

  // The working picker color, copy-on-write: channels + alpha here are
  // the preview state only.
  property var picked: ({ r: 1, g: 1, b: 1, a: 1 })
  // Hue is picker state of its own, not a derivation of the color: gray
  // colors (s = 0) carry no hue, so deriving it back from the color
  // would snap the hue thumb to 0 and make the rainbow slider inert on
  // white/black. Seeded from arriving colors in pickRecord().
  // Clamped to 0..360, not wrapped: the rainbow's two ends are both pure
  // red, so the far right is a real position and has to be able to hold it.
  // ColorMath.hsvToRgb wraps whatever it is given, so 360 paints as red
  // either way - the range only has to stop the thumb teleporting.
  property real hue: 0
  // Active serialization format (ColorMath.FORMATS member). Persisted
  // as shell.colorPicker.fmt in the raw settings section (not a schema
  // option): restored at boot, rewritten on every chip click.
  property string fmt: "hex"
  // Normalized record key (#rrggbb + alpha byte) of the last accepted
  // copy, driving the history rows' copied flash; cleared when the
  // flight ends. Keyed like the rows themselves so the flash fires no
  // matter which chip format was copied.
  property string copiedKey: ""

  readonly property var hsv: ColorMath.rgbToHsv(root.picked.r, root.picked.g, root.picked.b)

  // Report every preview change to the module, which holds it and flushes
  // on a debounce. The alpha slider reports per pointer move, so this is
  // the hottest writer in the module; the module's timer is what makes it
  // one file write per settle rather than one per frame.
  function _reportPreview() {
    if (root._restoringWorking) return
    root.reportWorking(root.picked, root.hue)
  }

  onPickedChanged: {
    root._reportPreview()
    root._syncCode()
  }
  onHueChanged: root._reportPreview()
  // The format chip is a format of the same color, so the code in the
  // field is the same color written the other way.
  onFmtChanged: root._syncCode()
  // True only while restoreWorking applies the remembered pair.
  property bool _restoringWorking: false

  // A drag on the sv field, the hue slider, the alpha slider or a history
  // row takes the field over: whatever was half-typed is abandoned and the
  // canonical code follows the preview live, even while the field holds
  // focus. Typing sets _codeEditing so the field is not rewritten under
  // the caret mid-keystroke; a drag is the opposite intent - an explicit
  // new color - so it clears the flag before moving picked, and the
  // onPickedChanged sync writes the new code straight through.
  function _pickerTookOver() {
    root._codeEditing = false
  }

  function setSv(s, v) {
    const c = ColorMath.hsvToRgb(root.hue, s, v)
    if (c === null) return
    root._pickerTookOver()
    root.picked = { r: c.r, g: c.g, b: c.b, a: root.picked.a }
  }

  // Hue keeps the current saturation/value so the sv thumb stays put.
  // An achromatic current color (s = 0) would swallow the drag and leave
  // the preview untouched, so it seeds full saturation/value instead:
  // dragging the rainbow off white/black always lands on the hue.
  //
  // CLAMPED, not wrapped. 360 is a real position on this bar - the gradient
  // ends on the same red it starts with, so the far right is pure red and
  // the far left is pure red - and wrapping sent `360` back to `0`, which
  // threw the thumb from one end to the other under the cursor. A drag
  // aimed at "as red as it goes" then fought itself: every position at the
  // right edge resolved to the left edge, and the next pointer event mapped
  // back from there. ColourMath.hsvToRgb treats 360 as red, so nothing
  // downstream needed the wrap; only the thumb's position did, and it is
  // the thumb that has to stay under the pointer.
  function setHue(h) {
    root.hue = Math.min(360, Math.max(0, h))
    const s = root.hsv.s <= 0 ? 1 : root.hsv.s
    const v = root.hsv.v <= 0 ? 1 : root.hsv.v
    const c = ColorMath.hsvToRgb(root.hue, s, v)
    if (c === null) return
    root._pickerTookOver()
    root.picked = { r: c.r, g: c.g, b: c.b, a: root.picked.a }
  }

  function setAlpha(a) {
    root._pickerTookOver()
    root.picked = {
      r: root.picked.r, g: root.picked.g, b: root.picked.b,
      a: ColorMath.clampAlpha(a)
    }
  }

  function pickRecord(rec) {
    if (!rec) return
    const c = ColorMath.parse(String(rec.color || ""))
    if (c === null) return
    root._pickerTookOver()
    root.hue = ColorMath.rgbToHsv(c.r, c.g, c.b).h
    root.picked = { r: c.r, g: c.g, b: c.b, a: ColorMath.clampAlpha(rec.alpha) }
    // A colour is the one value in this feature that is safe to print: it is
    // four numbers the user just dragged, it carries nothing about the machine
    // or the account, and a reader diagnosing "why is my accent wrong" needs it.
    Log.info("picked color " + ColorMath.format(root.picked, "hex", 1))
    // The hex above is rendered with a literal `false` for alpha, and
    // `clampAlpha` reads a non-null `false` as `Number(false)` rather than as
    // "leave the alpha out", so the line ends in `00` for every record whatever
    // transparency it holds. The alpha is therefore precisely what this pair
    // cannot leave implicit, and it is rendered through `hex8` with the
    // record's own alpha so the two lines differ only where the record does:
    // `#3b7dd800` beside `#3b7dd866` is the whole diagnosis, and restating the
    // INFO's rendering instead would reproduce the defect rather than expose it.
    //
    // The record's display format is the second half. The INFO passes the
    // literal `"hex"`, so it names the renderer and not the record, and those
    // are different questions - `rec.fmt` is what a re-copy of this row puts on
    // the clipboard (`copyRecord` reads it), so a row stored as `rgba` and
    // previewed as `#3b7dd8` is not a contradiction. It also arrives in the
    // store document rather than from a drag, so it goes through `summarize`.
    // The gate wraps the serializer and the arithmetic, which a suppressed line
    // must not pay for.
    const d = Log.at()
    if (d.allows("debug")) {
      d.debug("picked color " + String(ColorMath.hex8(root.picked, root.picked.a))
        + ": alpha " + Math.round(root.picked.a * 255) + "/255, record format "
        + Log.summarize(typeof rec.fmt === "string" ? rec.fmt : "hex"))
    }
  }

  // The serialized string that Copy/Add put on the clipboard.
  function outputString(): string {
    const s = ColorMath.format(root.picked, root.fmt, root.picked.a)
    return s === null ? "" : s
  }

  // --- the code field ---
  //
  // The code next to the preview rectangle is an input field: the color
  // can be typed instead of dialled. A code that parses becomes the
  // preview color - channels, alpha and hue - and the preview follows
  // it live.
  //
  // A code that is not a color stays in the field while it is written:
  // the field does not fight the user mid-keystroke, and a snap-back on
  // every wrong character is both confusing and annoying. It is
  // discarded when the edit settles - Enter, or the caret leaving the
  // field - and the field falls back to the canonical code for the color
  // the preview holds, without a word about it.

  // True while the user owns the field: their text is the one in it, and
  // the canonical code does not overwrite it under the caret.
  property bool _codeEditing: false

  // Put the canonical code into the field.
  //
  // The canonical code is READ, not bound: a QML binding is re-evaluated
  // lazily, so a bound property read from inside a change handler still
  // holds the value from before the change - and this is exactly where
  // the code is written back, right after the color or the format moved.
  function _writeCode() {
    const s = root.outputString()
    if (codeField.text !== s) codeField.text = s
    // A drag rewrites the code while the field holds focus: reselect so
    // the next keystroke still replaces the code instead of appending to
    // it, the same readiness _settleCode leaves behind.
    if (codeField.focused) codeField.input.selectAll()
  }

  // The canonical code follows the color - but not while the user is
  // typing in the field: overwriting the text under the caret would move
  // the caret out from under them.
  function _syncCode() {
    if (root._codeEditing) return
    root._writeCode()
  }

  // A code the user typed.
  function _codeEdited(text) {
    const t = String(text === undefined || text === null ? "" : text)
    root._codeEditing = true
    const c = ColorMath.parse(t)
    // A code that is not a color is not an error here: it stays in the
    // field, and the settle discards it.
    if (c === null) return
    root._applyCode(c)
    // The code is written in some format, and the picker speaks that
    // format from now on: the chip follows the code the user typed,
    // so the field, the chip and the copy button agree on one
    // spelling. The color is the same either way - only the way it
    // is written changes.
    root._adoptFormat(t)
  }

  // Follow the format of a code the user typed. A code that is written
  // in another format is still a color, and the picker's format is a
  // spelling of the color rather than the color itself - so the chip
  // moves to the spelling the user chose and the choice is persisted
  // like a chip click, because it is the same choice.
  function _adoptFormat(text) {
    const f = ColorMath.detectFormat(text)
    if (f === null) return
    root.setFmt(f)
  }

  // The typed code becomes the preview color: channels, alpha and hue, so
  // the sliders and the field agree on one color.
  function _applyCode(c) {
    root.hue = ColorMath.rgbToHsv(c.r, c.g, c.b).h
    root.picked = {
      r: c.r, g: c.g, b: c.b,
      a: ColorMath.clampAlpha(c.a)
    }
  }

  // The code settled: the caret left the field, the user confirmed it, or
  // Escape ended the edit. Whatever was half-typed - a color or not -
  // goes, and the canonical code for the current color takes the field.
  function _settleCode() {
    root._codeEditing = false
    root._writeCode()
    // The caret stays ready for the next code: the settled text is
    // selected, so the next keystroke replaces it.
    if (codeField.focused) codeField.input.selectAll()
  }

  // Copy through the module's clipboard helper. The island closes only
  // from onCopyDone, which the module fires after the copy command was
  // accepted - a failed spawn leaves the island open.
  function copyPicked() {
    const s = root.outputString()
    if (s === "" || typeof root.copyColor !== "function") return
    root.copiedKey = ColorMath.hex8(root.picked, root.picked.a)
    root.copyColor(s)
  }

  // The history-row copy in flight; non-null marks onCopyDone as a
  // promote (entry moves to the top, never re-added - re-adding minted
  // same-color duplicates under the island's current chip format).
  property var promoteRec: null

  // Copy one history entry: its stored text, verbatim.
  function copyRecord(rec) {
    if (!rec) return
    const f = rec.formats && typeof rec.formats === "object" ? rec.formats : null
    const fmt = typeof rec.fmt === "string" ? rec.fmt : "hex"
    let s = f && typeof f[fmt] === "string" ? f[fmt] : ""
    if (s === "") {
      const c = ColorMath.parse(String(rec.color || ""))
      s = c === null ? "" : ColorMath.hex8(c, ColorMath.clampAlpha(rec.alpha))
    }
    if (s === "" || typeof root.copyColor !== "function") return
    root.promoteRec = rec
    root.copiedKey = ColorMath.hex8(ColorMath.parse(rec.color), ColorMath.clampAlpha(rec.alpha))
    root.copyColor(s)
  }

  // Module -> island: copy command settled. Accepted copies land the picked
  // color in the history and close the island; refusals keep it open with the
  // copied flash cleared, so the user's colour is not on the clipboard and the
  // island says so by staying there. A history-row copy only promotes its
  // existing entry to the front - never re-adds.
  function onCopyDone(ok) {
    if (ok === true) {
      if (root.promoteRec !== null && typeof root.promoteRecord === "function") {
        root.promoteRecord(root.promoteRec)
      } else {
        root.addPicked()
        root.islandHost.close()
      }
    }
    root.promoteRec = null
    root.copiedKey = ""
  }

  // Add the current picker state to the history without copying, stamped
  // with the active chip format and a full serialization snapshot.
  function addPicked() {
    const s = ColorMath.hex6(root.picked)
    if (s === "" || typeof root.addRecord !== "function") return
    // The sv field, the hue slider and the alpha slider edit `picked`
    // continuously without persisting anything, so the commit point is
    // this button and the hex is read here rather than per mousemove.
    root.addRecord(s, root.picked.a, {
      fmt: root.fmt,
      formats: ColorMath.allFormats(root.picked, root.picked.a)
    })
  }

  // Delete one history row straight from the list; the module persists.
  // The module is the writer and it knows whether the store took it.
  function deleteRecord(rec) {
    if (typeof root.removeRecord !== "function") return
    root.removeRecord(rec)
  }

  // Clear the whole history through the module; the module persists.
  function clearHistory() {
    if (typeof root.clearAll !== "function") return
    root.clearAll()
  }

  // --- content lent to the shared host ---
  // Incubated on show, destroyed after the close fade. The card sizes
  // from body.implicitHeight through islandContentHeight above.
    Item {
      anchors.fill: parent

  Column {
    id: body

    width: parent.width
    spacing: Ui.s

    // History section: five fixed rows, the rest under the scrollbar.
    // Title row mirrors the network island's section headers: small
    // foreground_1 glyph at 70% before the caps title.
    Row {
      spacing: Ui.s

      Icon {
        anchors.verticalCenter: parent.verticalCenter
        name: "list"
        colorKey: "foreground_1"
        size: 14
        opacity: 0.7
      }

      Title {
        level: 2
        anchors.verticalCenter: parent.verticalCenter
        text: "HISTORY"
      }
    }

    ColorPickerHistory {
      id: history

      width: parent.width
      records: root.records
      copiedKey: root.copiedKey
      onCopyRequested: rec => {
        root.copyRecord(rec)
      }
      onDeleteRequested: rec => root.deleteRecord(rec)
    }

    // Clear-all: themed red, hover-deepened; wipes the whole history
    // through the module (which persists the empty file). Inert while
    // the history is empty: dimmed, no hover/cursor, taps refused.
    Rectangle {
      id: clearBtn

      readonly property bool hov: clearHover.hovered
      readonly property bool press: clearTap.pressed
      // hasEntries, not "enabled": QQuickItem.enabled is a real
      // control property and shadowing it trips qmllint and can confuse
      // parent-driven enable inheritance.
      readonly property bool hasEntries: root.records.length > 0

      width: parent.width
      height: Ui.buttonHeight
      opacity: clearBtn.hasEntries ? 1 : 0.45
      color: press && clearBtn.hasEntries ? Ui.tint("red", 0.3)
        : hov && clearBtn.hasEntries ? Ui.tint("red", 0.18) : Ui.tint("red", 0.08)
      border.width: 1
      border.color: hov && clearBtn.hasEntries ? Ui.solid("red") : Ui.tint("red", 0.55)

      Behavior on color {
        ColorAnim {}
      }
      Behavior on border.color {
        ColorAnim {}
      }

      Text {
        anchors.centerIn: parent
        text: "Clear history"
        color: Ui.solid("red")
        font.pixelSize: Ui.fontS
        font.family: Ui.fontFamily
        textFormat: Text.PlainText
      }

      HoverHandler {
        id: clearHover

        cursorShape: clearBtn.hasEntries ? Qt.PointingHandCursor : Qt.ArrowCursor
      }

      TapHandler {
        id: clearTap

        onTapped: {
          if (!clearBtn.hasEntries) return
          root.clearHistory()
        }
      }
    }

    // Picker section. The Column's Ui.s spacing separates the title
    // from the clear button above and the field below.
    Row {
      spacing: Ui.s

      Icon {
        anchors.verticalCenter: parent.verticalCenter
        name: "pipette"
        colorKey: "foreground_1"
        size: 14
        opacity: 0.7
      }

      Title {
        level: 2
        anchors.verticalCenter: parent.verticalCenter
        text: "PICKER"
      }
    }

    // Large saturation/value field: hue fixed, S left-to-right, V
    // bottom-to-top. Click or drag moves the circular thumb.
    Item {
      id: svField

      width: parent.width
      height: 120

      // Pure hue base, from the island's own hue state.
      Rectangle {
        anchors.fill: parent
        color: ColorMath.hsvToRgb(root.hue, 1, 1)

        // White overlay fading right: full saturation at the right edge.
        Rectangle {
          anchors.fill: parent
          gradient: Gradient {
            orientation: Gradient.Horizontal

            GradientStop { position: 0; color: "#ffffff" }
            GradientStop { position: 1; color: "transparent" }
          }
        }

        // Black overlay fading up: full value at the top edge.
        Rectangle {
          anchors.fill: parent
          gradient: Gradient {
            GradientStop { position: 0; color: "transparent" }
            GradientStop { position: 1; color: "#000000" }
          }
        }

        // Click/drag surface over the field.
        MouseArea {
          id: svArea

          anchors.fill: parent
          cursorShape: Qt.CrossCursor

          function update(x, y) {
            const s = Math.max(0, Math.min(1, x / width))
            const v = 1 - Math.max(0, Math.min(1, y / height))
            root.setSv(s, v)
          }

          onPressed: mouse => update(mouse.x, mouse.y)
          onPositionChanged: mouse => {
            if (pressed) update(mouse.x, mouse.y)
          }
        }

        // Circular thumb; a mid-value ring keeps it visible on any field
        // color (the painted color sits under it).
        Rectangle {
          x: parent.width * root.hsv.s - width / 2
          y: parent.height * (1 - root.hsv.v) - height / 2
          width: 14
          height: 14
          radius: RoundingPolicy.radius
          color: ColorMath.hex6(root.picked)
          border.width: 2
          border.color: (root.hsv.v > 0.6 && root.hsv.s < 0.6)
            ? "#000000" : "#ffffff"
        }
      }
    }

    // Hue slider: full rainbow, red wrapping back to red.
    Item {
      id: hueSlider

      width: parent.width
      height: 14

      readonly property real hueFrac: root.hue / 360

      Rectangle {
        anchors.fill: parent
        radius: RoundingPolicy.radius
        gradient: Gradient {
          orientation: Gradient.Horizontal

          GradientStop { position: 0.000; color: "#ff0000" }
          GradientStop { position: 0.167; color: "#ffff00" }
          GradientStop { position: 0.333; color: "#00ff00" }
          GradientStop { position: 0.500; color: "#00ffff" }
          GradientStop { position: 0.667; color: "#0000ff" }
          GradientStop { position: 0.833; color: "#ff00ff" }
          GradientStop { position: 1.000; color: "#ff0000" }
        }

        MouseArea {
          anchors.fill: parent
          anchors.topMargin: -6
          anchors.bottomMargin: -6
          cursorShape: Qt.PointingHandCursor

          function update(x) {
            root.setHue(x / Math.max(1, width) * 360)
          }

          onPressed: mouse => update(mouse.x)
          onPositionChanged: mouse => {
            if (pressed) update(mouse.x)
          }
        }

        // Scroll steps the hue in 3-degree ticks.
        WheelHandler {
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          onWheel: event => {
            const d = event.angleDelta.y > 0 ? 3 : (event.angleDelta.y < 0 ? -3 : 0)
            if (d !== 0) root.setHue(hueSlider.hueFrac * 360 + d)
            // Scrolling past either end holds there. `setHue` clamps rather
            // than wraps - a wrap would make one notch at the top of the
            // range jump to the bottom, which is the same teleport the drag
            // had, reached from the wheel.
          }
        }
      }

      Rectangle {
        x: parent.width * root.hue / 360 - width / 2
        anchors.verticalCenter: parent.verticalCenter
        width: 4
        height: parent.height + 4
        color: "transparent"
        border.width: 2
        border.color: Ui.solid("foreground_0")
      }
    }

    // Opacity slider over the conventional png-style transparency
    // checkerboard: black ramp left (fully transparent) to the picked
    // color right (fully opaque).
    Item {
      id: alphaSlider

      width: parent.width
      height: 14

      // Checkerboard: two alternating squares per row, drawn once.
      Grid {
        anchors.fill: parent
        columns: 16
        rows: 2
        visible: true

        Repeater {
          model: 32

          Rectangle {
            required property int index

            width: alphaSlider.width / 16
            height: alphaSlider.height / 2
            color: (index % 2 === 0) !== (Math.floor(index / 16) % 2 === 0)
              ? Ui.tint("foreground_1", 0.3) : Ui.tint("background_1", 0.6)
          }
        }
      }

      // Ramp: transparent on the left over the checkerboard, the picked
      // color fully opaque on the right.
      Rectangle {
        anchors.fill: parent
        gradient: Gradient {
          orientation: Gradient.Horizontal

          GradientStop { position: 0; color: Qt.alpha(ColorMath.hsvToRgb(root.hue, 1, 1), 0) }
          GradientStop { position: 1; color: ColorMath.hsvToRgb(root.hue, 1, 1) }
        }
      }

      MouseArea {
        anchors.fill: parent
        anchors.topMargin: -6
        anchors.bottomMargin: -6
        cursorShape: Qt.PointingHandCursor

        function update(x) {
          root.setAlpha(x / Math.max(1, width))
        }

        onPressed: mouse => update(mouse.x)
        onPositionChanged: mouse => {
          if (pressed) update(mouse.x)
        }
      }

      // Scroll steps alpha in 2% ticks.
      WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: event => {
          const d = event.angleDelta.y > 0 ? 0.02 : (event.angleDelta.y < 0 ? -0.02 : 0)
          if (d !== 0) root.setAlpha(root.picked.a + d)
        }
      }

      Rectangle {
        x: parent.width * root.picked.a - width / 2
        anchors.verticalCenter: parent.verticalCenter
        width: 4
        height: parent.height + 4
        color: "transparent"
        border.width: 2
        border.color: Ui.solid("foreground_0")
      }
    }

    // Preview + value + format chips. The chips row shares the preview
    // box's bottom edge and the value sits on its top edge, so the full
    // box height is usable and the value gets the larger font.
    Row {
      width: parent.width
      spacing: Ui.s

      // Live preview. The overlay is Qt.rgba with the working alpha -
      // QML color properties reject CSS rgba() strings (they render
      // black), so the checkerboard shows through exactly as far as the
      // alpha allows at every slider position.
      Rectangle {
        id: preview

        width: 48
        height: 48
        color: Ui.solid("background_2")

        // Transparency checkerboard; a fully opaque overlay covers it.
        Grid {
          anchors.fill: parent
          columns: 4
          rows: 4

          Repeater {
            model: 16

            Rectangle {
              required property int index

              width: preview.width / 4
              height: preview.height / 4
              color: (index + Math.floor(index / 4)) % 2 === 0
                ? Ui.tint("foreground_1", 0.25) : "transparent"
            }
          }
        }

        Rectangle {
          anchors.fill: parent
          color: Qt.rgba(root.picked.r, root.picked.g, root.picked.b, root.picked.a)
        }
      }

      // Right side spans the box height: the code field on the top edge,
      // format chips on the bottom edge.
      Item {
        width: parent.width - preview.width - parent.spacing
        height: preview.height

        // The code, as an input field: the color can be typed instead of
        // dialled. The field owns the caret while it is focused, so the
        // island's key router stands down (blockedNavKeys above).
        InputField {
          id: codeField

          // The test hook: a probe reaches the field through the name
          // rather than through the tree it sits in.
          objectName: "codeField"

          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: Ui.buttonHeight
          // The xmark in the field's right edge empties it, the way the
          // eye in the wifi passphrase field reveals it.
          clearable: true
          clearGlyph: "xmark"
          fontSize: Ui.fontM
          placeholder: "Type a color code"
          onEdited: text => root._codeEdited(text)
          // Enter confirms the code: the canonical spelling of the color
          // takes the field, and the caret stays in it for the next code.
          onAccepted: root._settleCode()
          // Escape ends the edit rather than the island: the half-typed
          // code is discarded, the field lets go of the keyboard, and the
          // island stays open. That is the escape ladder's first rung -
          // the next Escape closes the island.
          onEscaped: {
            root._settleCode()
            codeField.releaseFocus()
          }
          onFocusedChanged: {
            if (codeField.focused) {
              // The caret lands in a value field: the whole code is
              // selected, so the first keystroke replaces the code
              // instead of appending to it.
              codeField.input.selectAll()
              return
            }
            // The caret left: whatever was half-typed goes and the
            // canonical code takes the field back.
            root._settleCode()
          }
        }

        Row {
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          spacing: 4

          Repeater {
            model: ColorMath.FORMATS

            Rectangle {
              id: chip

              required property var modelData
              required property int index

              readonly property bool active: root.fmt === chip.modelData

              width: chipText.implicitWidth + 10
              height: 18
              radius: RoundingPolicy.radius
              color: chip.active ? Ui.solid("accent") : Ui.tint("foreground_1", 0.08)

              Text {
                id: chipText

                anchors.centerIn: parent
                text: chip.modelData
                color: chip.active ? Ui.solid("background_0") : Ui.solid("foreground_1")
                font.pixelSize: Ui.fontXs
                font.family: Ui.fontFamily
                textFormat: Text.PlainText
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setFmt(chip.modelData)
              }
            }
          }
        }
      }
    }

    Row {
      width: parent.width
      spacing: Ui.s

      Button {
        width: (parent.width - parent.spacing) / 2
        label: "Copy"
        variant: "primary"
        onClicked: root.copyPicked()
      }

      Button {
        width: (parent.width - parent.spacing) / 2
        label: "Add"
        variant: "outline"
        // Add lands the color and keeps the island open.
        onClicked: root.addPicked()
      }
    }
  }
  }

  // Seed on every show: the content is incubated fresh, so creation is
  // open - clear the copied flash, restore the persisted format, and
  // preview the newest history entry.
  Component.onCompleted: {
    root.copiedKey = ""
    root.restoreFmt()
    if (root.records.length > 0) root.pickRecord(root.records[0])
    // The remembered preview is applied OVER the history's top record,
    // not under it: the history only knows committed picks, so it has no
    // transparency to restore and no uncommitted colour at all. Reading
    // it first would mean a picker whose alpha was dialled to 0.4 and
    // never committed came back opaque on the next open.
    root.restoreWorking()
    // The code field opens on the code of the color the preview holds,
    // written last so it shows the color the island actually came up
    // with - the remembered one, the history's newest, or the default.
    root._syncCode()
  }

  // Apply the remembered colour and hue. Both move together and neither is
  // derived from the other: a gray carries no hue, so restoring the
  // colour alone would leave the rainbow thumb at 0 and make the hue
  // slider inert on white/black.
  //
  // `picked` and `hue` are written directly rather than through setHue,
  // which would rebuild the colour from the restored hue and discard the
  // saturation and value that came with it.
  function restoreWorking() {
    const w = root.workingState
    if (w === null || typeof w !== "object" || w.picked === undefined) return
    // Applying these writes them through onPickedChanged/onHueChanged, so
    // the report is suppressed for the duration: an open that changes
    // nothing must not schedule a flush, and a hand-edited cache value is
    // normalized on the next real edit rather than by reopening the picker.
    root._restoringWorking = true
    root.picked = {
      r: w.picked.r, g: w.picked.g, b: w.picked.b, a: w.picked.a
    }
    root.hue = w.hue
    root._restoringWorking = false
  }

  // The active format, persisted so the next open starts where this one
  // left off. A chip click and a typed code both go through here: the
  // chip IS the format preference, so every way of moving it writes it.
  function setFmt(f) {
    if (ColorMath.FORMATS.indexOf(f) < 0) return
    if (root.fmt === f) return
    root.fmt = f
    Settings.setRawSection("colorPicker", "fmt", f)
  }

  // Restore the persisted format preference (shell.colorPicker.fmt raw
  // section); chip clicks keep it written. Run at boot and on every
  // open, so an external settings edit is picked up too.
  //
  // A stored value that is not a known format - a hand-edited settings file,
  // or a format ColorMath.FORMATS does not name - is silently ignored, so the
  // island copies in hex while the user's settings file says otherwise.
  function restoreFmt() {
    const sec = Settings.rawSection("colorPicker")
    const v = sec && typeof sec.fmt === "string" ? sec.fmt : ""
    if (ColorMath.FORMATS.indexOf(v) >= 0) root.fmt = v
  }
}
