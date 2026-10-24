pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.UPower
import qs.common
import qs.features.bar
import "../../../../common/power/BatteryModel.js" as Model

// Battery module: shows the lowest battery device with a level glyph.
// Appears automatically while at least one UPower device with a battery
// is present - a laptop battery as well as peripherals (mice, keyboards,
// headsets, gamepads...). Left click opens the island with the per-device
// list; the slot collapses entirely while no battery device is around,
// so the bar never keeps a gap (the PowerProfile convention).
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
        label: Model.deviceLabel(d.model, root.typeString(d.type), d.nativePath),
        percentage: Model.normalizePct(d.percentage),
        charging: d.state === UPowerDeviceState.Charging,
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
  readonly property real summaryPct: root.summary ? root.summary.percentage : 100
  readonly property bool summaryCharging: root.summary ? root.summary.charging : false

  readonly property string iconName: Model.batteryIconFor(root.summaryPct, root.summaryCharging)
  readonly property string iconColor: Model.batteryColorFor(root.summaryPct, root.summaryCharging)
  readonly property string iconAccent: Model.batteryAccentFor(root.summaryPct, root.summaryCharging)

  function typeString(type): string {
    try {
      return String(UPowerDeviceType.toString(type))
    } catch (e) {
      return ""
    }
  }

  // One {icon, text} row per device, lowest charge first (same order
  // as the island, from the same projection): the device's class glyph -
  // mice, keyboard, headset, gamepad, monitor - with the level glyph when
  // the class has no shipped asset. Just the name, the glyph and the
  // charge - states live in the island.
  readonly property var tooltipLines: Model.tooltipRows(root.rows)

  // Collapsible slot (see CollapsibleSlot.qml): zero width while no
  // battery device is around so it leaves no gap. User disable is
  // handled one level up: a disabled id never reaches the filtered
  // layout, so this module is not instantiated at all.
  readonly property bool shown: root.hasDevices
  collapseShown: root.shown

  Icon {
    // Pinned to the trailing edge the box grows from (right-anchored
    // zone): the Icon item is slot-sized and paints its glyph centered
    // inside, so a flush-right anchor centers the glyph at rest and holds
    // it screen-fixed while the slot grows (left overflow is clipped).
    // Upright battery: the shipped glyph is horizontal, so the bar (and
    // only the bar - the island keeps the horizontal glyph) paints it
    // rotated a quarter turn, nub on top. A 90-degree turn is a pixel
    // remap, so the raster stays as crisp as the source.
    rotation: -90
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    name: root.iconName
    colorKey: root.iconColor
    accentKey: root.iconAccent
    opacity: root.fade
    visible: opacity > 0
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
