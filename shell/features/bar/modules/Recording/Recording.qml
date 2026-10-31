pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import qs.common
import qs.features.bar
import "../../../../common/text/Format.js" as Format
// Recording indicator. Owned slot that appears only while a screen
// recording is ongoing: it paints the red recording-ongoing icon with a
// tooltip and stops the recording on left click. The module owns no
// logic - it mirrors the `recording.bus` bus topic published by the
// Recording service (Bus.latest replays the last payload, so a module
// enabled after a publish is correct on frame one) and never imports the
// service.
CollapsibleSlot {
  id: root

  // Last payload from the recording service's topic; null before the
  // first publish (the module stays hidden until the service says so).
  readonly property var state: Bus.latest("recording.bus")

  // Mirrors the service's live state; hidden state takes no space (the
  // collapse matches the owned-indicator convention).
  readonly property bool active: root.state?.ongoing ?? false
  // GNOME-style pill (shell.statusbar.recordingElapsed, default off):
  // red dot plus live elapsed instead of the plain dot.
  readonly property bool elapsedPill: Settings.value("shell.statusbar.recordingElapsed") === true
  // Payload stamp, falling back to first-seen-active for payloads
  // that predate it.
  property double _seenSince: 0
  readonly property double startedAt: (root.state?.startedAt ?? 0) > 0
    ? root.state.startedAt : root._seenSince
  property double nowMs: 0
  readonly property int elapsedSec: root.startedAt > 0 && root.nowMs >= root.startedAt
    ? Math.floor((root.nowMs - root.startedAt) / 1000) : 0
  // m:ss, h:mm:ss past the hour.
  readonly property string elapsed: {
    const s = root.elapsedSec
    const h = Math.floor(s / 3600)
    const m = Math.floor((s % 3600) / 60)
    const r = s % 60
    const mm = h > 0 ? Format.pad2(m) : String(m)
    return (h > 0 ? h + ":" : "") + mm + ":" + Format.pad2(r)  }

  // Collapsible slot (see CollapsibleSlot.qml): zero width while idle
  // so it leaves no gap.
  collapseShown: root.active
  collapseFull: (root.elapsedPill && root.active)
    ? (Bar.slotInset + pill.width + Bar.slotInset)
    : Bar.iconSlot

  Icon {
    // Pinned to the trailing edge the box grows from (right-anchored zone):
    // the Icon item is slot-sized and paints its glyph centered inside, so
    // a flush-right anchor centers the glyph at rest and holds it
    // screen-fixed while the slot grows (left overflow is clipped).
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    name: "recording-ongoing"
    colorKey: "red"
    opacity: root.fade
    visible: opacity > 0 && !(root.elapsedPill && root.active)
  }

  // 1 s ticker while recording; also seeds the fallback stamp and
  // the first paint so the pill never flashes 0:00. SystemClock fires on
  // second boundaries; activation and birth-while-active seed directly.
  SystemClock {
    id: secClock

    precision: SystemClock.Seconds
    enabled: root.active
    onDateChanged: {
      if (root._seenSince <= 0) root._seenSince = Date.now()
      root.nowMs = Date.now()
    }
  }
  Component.onCompleted: {
    if (root.active) {
      if (root._seenSince <= 0) root._seenSince = Date.now()
      root.nowMs = Date.now()
    }
  }
  onActiveChanged: {
    if (root.active) {
      if (root._seenSince <= 0) root._seenSince = Date.now()
      root.nowMs = Date.now()
    } else {
      root._seenSince = 0
      root.nowMs = 0
    }
  }

  // GNOME-style pill: solid red oblong with the black elapsed time.
  // No MouseArea here: the module fill covers the whole slot, so a
  // left-click anywhere on the pill stops the recording through
  // onClicked below.
  Rectangle {
    id: pill

    // Left air mirrors the right inset: the zone row has zero gap and
    // icon-only neighbors center their glyphs, so a flush box would
    // ride half a gap closer to the left module.
    anchors.left: parent.left
    anchors.leftMargin: Bar.slotInset
    anchors.verticalCenter: parent.verticalCenter
    width: timeText.implicitWidth + 8
    height: timeText.implicitHeight
    radius: RoundingPolicy.radius
    color: Ui.solid("red")
    visible: root.elapsedPill && root.active && root.slide > 0

    Title {
      id: timeText

      anchors.centerIn: parent
      level: 3
      font.pixelSize: Math.round(Ui.fontM * 0.95 * root.textScale)
      color: "black"
      text: root.elapsed
    }
  }

  // Left click stops the recording through the bus request path; middle
  // and right clicks are rejected at the surface level (fillButtons), so
  // they pass through and do nothing.
  fillButtons: Qt.LeftButton
  onClicked: mouse => Registry.call("recording", "stop")

  // Shown only while recording and hovered; the hidden state keeps no
  // tooltip surface alive.
  ToolTipBind {
    active: root.active && root.hovered
    text: root.elapsedPill ? "Screen recording is active" : "Recording " + root.elapsed
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }
}
