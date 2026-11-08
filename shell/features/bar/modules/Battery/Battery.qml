pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.UPower
import qs.common
import qs.features.bar
import "../../../../common/power/BatteryModel.js" as Model

// Battery module: shows a battery device with a level glyph. The device is
// the machine's own battery pack unless the wheel has picked another one;
// scrolling over the module steps through the tracked devices and remembers
// the pick across boots. Appears automatically while at least one UPower
// device with a battery is present - a laptop battery as well as
// peripherals (mice, keyboards, headsets, gamepads...). Left click opens the
// island with the per-device list; the slot collapses entirely while no
// battery device is around, so the bar never keeps a gap (the PowerProfile
// convention).
CollapsibleSlot {
  id: root

  // --- live UPower state (Quickshell.Services.UPower) ---

  readonly property var allDevices: UPower.devices ? UPower.devices.values : []

  // The one walk of the device set, and the one snapshot: every device
  // worth showing becomes a plain row with its label and normalized
  // percentage already resolved, lowest charge first. One walk because
  // the type test, the label resolution and the slice+sort are all
  // per-device costs, and they are paid here once rather than by each
  // consumer over its own filtered copy of the array.
  //
  // Devices worth showing: every type except the AC adapter and Unknown
  // (see Model.isTrackedType), skipping anything explicitly marked
  // absent. isPresent is only meaningful for Battery-typed devices, so
  // anything but an explicit false counts as present.
  //
  // UPowerDevice.percentage arrives as a 0..1 fraction (probed live) -
  // Model.normalizePct turns it into real percent, here once, so the
  // thresholds below all read the same number. `order` is the position in
  // the UPower enumeration, kept so the summary's tie-break below has the
  // device it has always picked rather than the one the sort happens to
  // land on (the sort breaks a tie by label). Nothing here holds a live
  // UPowerDevice: every field a consumer needs is a snapshot value.
  readonly property var rows: {
    var out = []
    for (var i = 0; i < root.allDevices.length; i++) {
      var d = root.allDevices[i]
      if (!d) continue
      if (!Model.isTrackedType(d.type, UPowerDeviceType.LinePower, UPowerDeviceType.Unknown)) continue
      if (d.isPresent === false) continue
      out.push({
        order: out.length,
        // The identity the wheel pick is stored under (Model.deviceKey):
        // native path first, then the lowercased type string.
        key: Model.deviceKey(d.nativePath, root.typeString(d.type)),
        label: Model.deviceLabel(d.model, root.typeString(d.type), d.nativePath),
        percentage: Model.normalizePct(d.percentage),
        charging: d.state === UPowerDeviceState.Charging,
        // Feeds the tooltip's "charging" + "time to full" fragments.
        timeToFull: Number(d.timeToFull),
        laptopBattery: d.isLaptopBattery === true,
        typeString: root.typeString(d.type)
      })
    }
    return Model.sortRows(out)
  }

  readonly property bool hasDevices: root.rows.length > 0

  // The summary row: lowest charge, so the bar always surfaces the
  // critical device when several peripherals are connected. rows[0] holds
  // the minimum, and the rows at that charge are a prefix, so an exact
  // tie takes the one earliest in the UPower enumeration - which is what
  // the glyph and the charging accent have always read.
  readonly property var summary: {
    if (root.rows.length === 0) return null
    var min = root.rows[0].percentage
    var best = root.rows[0]
    for (var i = 1; i < root.rows.length; i++) {
      var r = root.rows[i]
      if (r.percentage !== min) break
      if (r.order < best.order) best = r
    }
    return best
  }

  // The machine's own battery pack, as opposed to a peripheral. rows is
  // sorted lowest first, so the first laptop battery is the lowest one.
  readonly property var builtinSummary: {
    for (var i = 0; i < root.rows.length; i++) {
      if (root.rows[i].laptopBattery) return root.rows[i]
    }
    return null
  }

  // The remembered device: the key the last wheel pick left in
  // shell.battery.device. A raw section outside the schema, like the
  // ColorPicker's format - one opaque selection name, not a catalog option,
  // so it needs no settings row. rawSection() reads the live store, so a
  // write here re-evaluates every reader.
  readonly property string storedDeviceKey: {
    const sec = Settings.rawSection("battery")
    return sec && typeof sec.device === "string" ? String(sec.device) : ""
  }
  readonly property var storedRow: Model.rowForKey(root.rows, root.storedDeviceKey)

  // Percentage readout (shell.statusbar.batteryPercent, default off): it
  // prints one device and keeps the pill at icon width otherwise, so a
  // remembered peripheral is the only device it ever grows for. Any tracked
  // device can be printed; the setting does nothing while none is around.
  readonly property bool showPercentage: Settings.value("shell.statusbar.batteryPercent") === true
    && root.rows.length > 0

  // The row the readout prefers: the remembered device while it is present,
  // else the machine's own battery pack, else the lowest device (the summary
  // the icon-only module has always shown).
  readonly property var preferredRow: root.storedRow !== null
    ? root.storedRow
    : (root.builtinSummary !== null ? root.builtinSummary : root.summary)

  // The readout keeps its device and its text through the whole fade-out:
  // percentageSlide stays above 0 until the reverse slide lands, so icon and
  // number agree for its duration. percentageText is deliberately independent
  // of showPercentage - clearing it on the first closing frame would drop the
  // text width and collapse the pill instead of sliding it back.
  readonly property var displayRow: (root.showPercentage
    || (root.percentageSlide > 0 && root.preferredRow !== null))
    ? root.preferredRow : root.summary

  // The row the pill actually paints. It follows displayRow, except while a
  // wheel cycle is in flight: the outgoing row is what slides away, and the
  // swap to the incoming one happens at the animation's midpoint
  // (_landCycle), so no phase draws two devices at once.
  property var paintRow: null
  onDisplayRowChanged: if (!cycleAnim.running) root.paintRow = root.displayRow
  Component.onCompleted: root.paintRow = root.displayRow

  readonly property var shownRow: root.paintRow !== null ? root.paintRow : root.displayRow
  readonly property real displayPct: root.shownRow ? root.shownRow.percentage : 100
  readonly property bool displayCharging: root.shownRow ? root.shownRow.charging : false
  readonly property string percentageText: root.shownRow
    ? Math.round(root.shownRow.percentage) + "%" : ""

  readonly property string iconName: Model.batteryIconFor(root.displayPct, root.displayCharging)
  readonly property string iconColor: Model.batteryColorFor(root.displayPct, root.displayCharging)
  readonly property string iconAccent: Model.batteryAccentFor(root.displayPct, root.displayCharging)

  function typeString(type): string {
    try {
      return String(UPowerDeviceType.toString(type))
    } catch (e) {
      return ""
    }
  }

  // --- wheel cycling ---
  //
  // One notch steps the readout to the next or previous tracked device and
  // remembers it in shell.battery.device, so the same device is back on the
  // next boot. The pick is written when the cycle lands, not when the wheel
  // turns, so a fast spin across four devices writes once.
  property string _cycleKey: ""
  property int _cycleStep: 0

  function cycleDevice(step): bool {
    if (!root.showPercentage) return false
    const key = Model.cycleKey(root.rows, root.paintRow ? root.paintRow.key : "", step)
    if (key === "") return false
    if (root.paintRow !== null && String(root.paintRow.key || "") === key) return false
    root._cycleKey = key
    root._cycleStep = step > 0 ? 1 : -1
    if (!MotionPolicy.enabled) root._landCycle()
    else cycleAnim.restart()
    return true
  }

  function _landCycle() {
    const key = root._cycleKey
    root._cycleKey = ""
    if (key === "") return
    const row = Model.rowForKey(root.rows, key)
    root.paintRow = row !== null ? row : root.displayRow
    Settings.setRawSection("battery", "device", key)
  }

  // The cycle slidefade: the outgoing content leaves through the top on a
  // forward step and through the bottom on a backward one, and the incoming
  // content enters from the opposite edge. Each half travels one pill height
  // so the change reads as a roll rather than a nudge, and the two halves
  // together last the same Ui.fastMs as the pill's width. With motion off
  // cycleDevice lands the pick directly instead of running this.
  readonly property int cycleMs: Math.max(1, Math.round(Ui.fastMs / 2))
  SequentialAnimation {
    id: cycleAnim

    ParallelAnimation {
      NumberAnimation {
        target: cycleContent
        property: "y"
        to: -root._cycleStep * pill.height
        duration: root.cycleMs
        easing.type: Easing.InCubic
      }
      NumberAnimation {
        target: cycleContent
        property: "opacity"
        to: 0
        duration: root.cycleMs
      }
    }
    ScriptAction {
      script: {
        root._landCycle()
        cycleContent.y = root._cycleStep * pill.height
      }
    }
    ParallelAnimation {
      NumberAnimation {
        target: cycleContent
        property: "y"
        to: 0
        duration: root.cycleMs
        easing.type: Easing.OutCubic
      }
      NumberAnimation {
        target: cycleContent
        property: "opacity"
        to: 1
        duration: root.cycleMs
      }
    }
  }

  // One {icon, text} row per device, lowest charge first (same order
  // as the island, from the same projection): the device's class glyph -
  // mice, keyboard, headset, gamepad, monitor - with the level glyph when
  // the class has no shipped asset. The text carries the name, the charge,
  // and when the device charges also the direction and the time to full;
  // the rest of the telemetry lives in the island.
  readonly property var tooltipLines: Model.tooltipRows(root.rows)

  // Collapsible slot (see CollapsibleSlot.qml): zero width while no
  // battery device is around so it leaves no gap. User disable is
  // handled one level up: a disabled id never reaches the filtered
  // layout, so this module is not instantiated at all.
  readonly property bool shown: root.hasDevices
  collapseShown: root.shown

  // Percentage reveal (second axis, local): 1 while the readout is up, 0
  // icon-only. The slide drives the pill width, so both rest states land
  // exact and the icon stays flush right when no text is shown.
  property real percentageSlide: root.showPercentage ? 1 : 0
  Behavior on percentageSlide {
    Glide { duration: Ui.slowMs }
  }
  collapseFull: pill.width

  // The battery glyph is horizontal in a 24x24 box and paints only the
  // middle band, so the quarter turn leaves its ink about half the canvas
  // wide, centered. Its painted right edge sits near iconSlot/2 +
  // iconCanvas/4, leaving the right half of the icon slot empty. The text
  // starts 8px past that painted edge, so the visible padding is the 8px
  // below rather than the much larger transparent air of the icon slot.
  readonly property real textGap: 8 - (Bar.iconSlot / 2 - Bar.iconCanvas / 4)

  // Icon + percentage pill. The right zone grows leftward, so the pill is
  // trailing-anchored: the percentage sits at the trailing edge with the
  // icon ahead of it, exactly the requested icon-then-text order. The text
  // carries Bar.slotInset on its right edge, matching the air an icon-only
  // slot has against its neighbor.
  Item {
    id: pill

    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: Math.round(Bar.iconSlot + root.percentageSlide * (percentageText.implicitWidth + root.textGap + Bar.slotInset))
    height: root.height
    clip: true
    Behavior on width {
      enabled: root.percentageSlide === 1
      Glide { duration: Ui.fastMs }
    }

    // The pill's paint layer. The cycle slidefade travels this box without
    // touching the pill's own geometry, so the width behavior keeps its rest
    // states while the content rolls inside the clip.
    Item {
      id: cycleContent

      width: pill.width
      height: pill.height

      Icon {
        // Docked ahead of the readout; at rest with no text the pill is one
        // slot wide and the glyph sits flush right as before. Upright
        // battery: the shipped glyph is horizontal, so the bar (and only
        // the bar - the island keeps the horizontal glyph) paints it
        // rotated a quarter turn, nub on top. A 90-degree turn is a pixel
        // remap, so the raster stays as crisp as the source.
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        rotation: -90
        name: root.iconName
        colorKey: root.iconColor
        accentKey: root.iconAccent
        opacity: root.fade
        visible: opacity > 0
      }

      Title {
        id: percentageText

        anchors.right: parent.right
        anchors.rightMargin: Bar.slotInset
        anchors.verticalCenter: parent.verticalCenter
        visible: root.percentageSlide > 0
        opacity: root.percentageSlide
        level: 3
        font.pixelSize: Math.round(Ui.fontM * 0.95 * root.textScale)
        color: Ui.solid(root.iconColor)
        text: root.percentageText
      }
    }
  }

  // Wheel over the module: down steps to the next device, up to the
  // previous. A wheel notch with no readout on screen has nothing to cycle,
  // so the icon keeps its summary choice until the percentage is shown.
  WheelHandler {
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: event => {
      if (event.angleDelta.y === 0) return
      root.cycleDevice(event.angleDelta.y > 0 ? -1 : 1)
    }
  }

  fillButtons: Qt.LeftButton
  onClicked: root.openIsland()

  ToolTipBind {
    active: root.shown && root.hovered
    lines: root.tooltipLines
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }

  Component {
    id: islandComp

    BatteryIsland {}
  }

  // The island this module opens, declared on the base so openIsland()
  // below is the single call every click handler makes.
  islandComponent: islandComp
}
