pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Accent wave overlay for the downloader bar icon. A thin accent-colored
// slice of the same glyph scrolls from top to bottom while a job is active.
// Uses only Item/Image/clip: the shell deliberately keeps effect nodes out of
// bar surfaces (see LauncherEntry.qml on the Qt5Compat teardown crash).
Item {
  id: root

  property string iconName: "download-alt"
  property real canvas: 16
  property bool active: false

  readonly property real dpr: {
    const w = Window.window
    const d = w ? w.devicePixelRatio : 0
    return typeof d === "number" && isFinite(d) && d > 0 ? d : 1
  }
  // This sweep is the only busy indicator the bar has. It is deliberately
  // outside MotionPolicy: disabling global animations must not turn a running
  // download into a static accent glyph.
  readonly property bool animOn: true
  readonly property real bandH: Math.max(2, root.canvas * 0.3)
  // Discrete cadence: ~3 frames per second instead of a per-frame tween.
  // A tiny bar glyph does not need smooth motion, and the stepped phase keeps
  // the scene-graph work to a handful of updates per second.
  readonly property int steps: 7
  readonly property int frameMs: 350
  property int step: 0
  readonly property real phase: -root.bandH
    + root.step * ((root.canvas + root.bandH) / root.steps)

  width: root.canvas
  height: root.canvas
  visible: root.active

  // Core band and two soft edges. Each slice clips a full-size accent glyph;
  // the child is offset by the negative of the slice y so the glyph stays
  // registered with the base icon painted underneath.
  Item {
    x: 0
    y: root.phase - root.bandH * 0.5
    width: root.canvas
    height: root.bandH * 0.5
    clip: true
    Image {
      source: Icons.url(root.iconName, "accent")
      width: root.canvas
      height: root.canvas
      y: -(parent.y)
      asynchronous: true
      retainWhileLoading: true
      sourceSize: Qt.size(root.canvas * root.dpr, root.canvas * root.dpr)
      opacity: 0.25
    }
  }

  Item {
    x: 0
    y: root.phase
    width: root.canvas
    height: root.bandH
    clip: true
    Image {
      source: Icons.url(root.iconName, "accent")
      width: root.canvas
      height: root.canvas
      y: -(parent.y)
      asynchronous: true
      retainWhileLoading: true
      sourceSize: Qt.size(root.canvas * root.dpr, root.canvas * root.dpr)
      opacity: 0.9
    }
  }

  Item {
    x: 0
    y: root.phase + root.bandH
    width: root.canvas
    height: root.bandH * 0.6
    clip: true
    Image {
      source: Icons.url(root.iconName, "accent")
      width: root.canvas
      height: root.canvas
      y: -(parent.y)
      asynchronous: true
      retainWhileLoading: true
      sourceSize: Qt.size(root.canvas * root.dpr, root.canvas * root.dpr)
      opacity: 0.35
    }
  }

  Timer {
    interval: root.frameMs
    repeat: true
    running: root.active
    onTriggered: root.step = (root.step + 1) % (root.steps + 1)
    // Park at the top when the job ends, so the next download starts from the
    // first frame rather than mid-sweep.
    onRunningChanged: if (!running) root.step = 0
  }
}
