pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import qs.features.bar
import qs.services as Core

// Weather module. Static right-zone module showing a condition SVG +
// temperature; left click opens the forecast island, middle refreshes.
// Right click is not accepted, so it passes through and does nothing.
//
// Thin view: all state and fetching live in the Weather service
// (qs.services.weather) - shared and always warm, so a delegate rebuilt
// by any zone toggle binds last-good data instantly instead of flashing
// through loading -> wttr -> open-meteo per window. See the service for
// the data strategy.
BarModule {
  id: root

  // Temperature flash (shell.statusbar.weatherFlash, default on): when
  // "Show temperature" is off, the temperature is briefly revealed on
  // each data update. Mirrors the Now Playing track-name flash.
  readonly property bool flashEnabled: Settings.value("shell.statusbar.weatherFlash") !== false
  property bool flashActive: false
  property real tempSlide: (Core.Weather.showTemp || root.flashActive) ? 1 : 0
  Behavior on tempSlide {
    Glide { duration: Ui.slowMs }
  }
  Timer {
    id: flashTimer

    interval: 3000
    repeat: false
    onTriggered: root._stopFlash()
  }
  property bool _seeded: false
  property bool _observeQueued: false

  function _queueObserve() {
    if (root._observeQueued) return
    root._observeQueued = true
    Qt.callLater(root._observeData)
  }

  function _observeData() {
    root._observeQueued = false
    if (!Core.Weather.current) {
      root._seeded = false
      root._stopFlash()
      return
    }
    if (!root._seeded) {
      root._seeded = true
      // The first data to arrive (typically the boot fetch) is a real
      // update too, so it flashes rather than being swallowed as a seed.
      if (root.flashEnabled && !Core.Weather.showTemp) root._startFlash()
      return
    }
    if (root.flashEnabled && !Core.Weather.showTemp) root._startFlash()
  }

  function _startFlash() {
    if (!root.flashEnabled || Core.Weather.showTemp) return
    if (!Core.Weather.current) return
    root.flashActive = true
    flashTimer.restart()
  }

  function _stopFlash() {
    flashTimer.stop()
    root.flashActive = false
  }

  Connections {
    target: Core.Weather

    function onCurrentChanged() { root._queueObserve() }
    function onShowTempChanged() {
      if (Core.Weather.showTemp) root._stopFlash()
    }
  }

  onFlashEnabledChanged: {
    if (!root.flashEnabled) root._stopFlash()
  }

  Component.onCompleted: {
    if (Core.Weather.current) root._seeded = true
  }

  // --- bar visuals: SVG icon + temperature (anchor-laid, no positioner) ---

  // NOTE: Icon/Text expose their painted size as implicitWidth/Height
  // (width stays 0 - children paint past it when unclipped), so every
  // size computation below reads implicit* properties. The text side boxes
  // itself with Bar.slotInset: the zone row has zero gap and an icon-only
  // slot keeps (slot - canvas) / 2 of air at each edge, so the label must
  // carry the same inset or it rides flush against the next module.
  // Icon-only (showTemp off) boxes to the full icon slot with the glyph
  // centered, exactly like every icon-only module.
  implicitWidth: Math.round(Bar.iconSlot + root.tempSlide * ((weatherIcon.implicitWidth + labelText.implicitWidth + 4 + Bar.slotInset) - Bar.iconSlot))

  Item {
    id: pill
    // Flush left: the Icon's slot already carries (slot - canvas) / 2 of
    // internal air, so the module's own Bar.slotInset all lands on the
    // trailing text edge - exactly the optical inset an icon-only module
    // has on each side. Centering the pill would split the inset half/half
    // and double-pad the icon edge while starving the text edge.
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: Math.round(Bar.iconSlot + root.tempSlide * ((weatherIcon.implicitWidth + labelText.implicitWidth + 4) - Bar.iconSlot))
    height: root.height

    CrossfadeIcon {
      id: weatherIcon
      anchors.verticalCenter: parent.verticalCenter
      // Centered in the slot when icon-only; docked left ahead of the
      // label otherwise (assigned at runtime so the analyzer never sees
      // an illegal left+horizontalCenter combination).
      anchors.left: root.tempSlide > 0 ? parent.left : undefined
      anchors.horizontalCenter: root.tempSlide > 0 ? undefined : parent.horizontalCenter
      name: Core.Weather.conditionIcon !== "" ? Core.Weather.conditionIcon : (Core.Weather.current ? "weather-overcast" : "cloud-off")
      colorKey: "foreground_0"
      // cloud-off carries its crossing slash as class="indicator", so it
      // paints red while the cloud body keeps the bar foreground tone.
      accentKey: Core.Weather.current ? "" : "red"
      opacity: 1
      Behavior on opacity { enabled: MotionPolicy.enabled; NumberAnimation { duration: Ui.fastMs } }
    }

    Title {
      id: labelText
      anchors.left: weatherIcon.right
      anchors.leftMargin: 4
      anchors.verticalCenter: parent.verticalCenter
      visible: root.tempSlide > 0
      level: 3
      font.pixelSize: Math.round(Ui.fontM * 0.95 * root.textScale)
      text: Core.Weather.reportTempNum !== "" ? Core.Weather.reportTempNum + Core.Weather.tempUnit : "—"
    }
  }

  fillButtons: Qt.LeftButton | Qt.MiddleButton
  onClicked: mouse => {
    if (mouse.button === Qt.MiddleButton) {
      if (root.clickCommand("middleClick")) return
      Core.Weather.refresh()
      return
    }
    root.openIsland()
  }

  ToolTipBind {
    active: root.hovered && !root.barWindow.islandHost.isOpenFor(root)
    text: Core.Weather.tooltipText
    lines: Core.Weather.tooltipLines
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }

  Component {
    id: islandComp

    WeatherIsland {
      weather: Core.Weather
    }
  }

  // The island this module opens, declared on the base so openIsland()
  // below is the single call every click handler makes.
  islandComponent: islandComp
}
