pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type signal-handler-parameters
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.common
import "../../../../common/capture/ShotLib.js" as ShotLib

// Full-screen still frame of one screen for the native color pick: the
// captured frame renders through ScreencopyView (same backend as the
// lockscreen), a click surface samples the position, right click or Esc
// cancels. The magnifier is the cursor: a circular lens centered on the
// pointer (the real cursor is blanked) shows literal pixels - the frame
// itself, scaled up about the pointer and cropped to the lens, one
// magScale block per source pixel - and a cross marks the exact pixel
// the click samples. Near screen
// edges the circle flattens into a rectangle that fits the remaining
// space (always animated); a non-directional drop shadow follows the
// shape. The module grabs captureItem and reads the pixel in-process.
//
// The lens is an Image, not a Canvas, and that is load-bearing twice over.
// Qt's Context2D has no imageSmoothingEnabled state - the assignment is
// accepted and ignored, and the painter's transform hint behind it is not
// reachable from QML - so a Canvas drawImage always interpolates and the lens
// would show a blend of up to four frame pixels where the cross sits, a
// colour no probe ever copies. And drawImage on an Image argument does not
// use the item's texture either: it resolves to a pixmap Qt loads itself,
// asynchronously, from the source URL, so every paint before that load lands
// draws nothing and the lens is a black box until the pointer happens to move
// again. An Image with smooth: false sidesteps both: it samples the texture
// nearest, and it loads the URL the ordinary way.
//
PanelWindow {
  id: overlay

  signal pickedAt(real x, real y)
  // The pick is being abandoned: Escape and right-click today, and the module
  // abandons on its own for a screen that went away or a bar that was disabled.
  signal cancelled()

  // Cursor position in window coordinates, maintained by the click
  // surface; the magnifier is centered on it.
  property real cursorX: -1
  property real cursorY: -1

  // Magnifier scale in integer steps (source px -> lens px). Every step
  // draws a hard-edged block per source pixel on the Canvas.
  property int magScale: 10

  // The window's own effective device pixel ratio: the ratio Qt rasterizes
  // the lens backing and a grabToImage target at, read off the window that
  // owns them, so a pick on one output never carries another output's ratio
  // into the arithmetic. Screen.devicePixelRatio is a different number
  // whenever Qt's ratio is already folded into the window's logical size
  // (this window is 1600x900 over a 1920x1080 frame: 2 there, 1.2 here),
  // so it is only the fallback for a window that has no ratio of its own.
  readonly property real dpr: devicePixelRatio > 0
    ? devicePixelRatio
    : ShotLib.qtDpr(Screen.devicePixelRatio)

  // The grabbed frame the lens magnifies, empty between picks.
  property string frameUrl: ""

  // Frame pixels per window-logical pixel, measured off the frame the capture
  // delivered. This is the ratio the lens magnifies by and the ratio the
  // module's probe has to read a click's pixel with, so it is one number for
  // both: a probe that maps the same click through a second ratio returns a
  // real colour from the wrong place.
  readonly property real frameRatio: view.sourceSize.width > 0 && view.width > 0
    ? view.sourceSize.width / Math.max(1, view.width)
    : 0

  // The rendered frame view; the module grabs this for the pixel read.
  property alias captureItem: view
  readonly property bool frameReady: view.hasContent

  // Wall clock of the map that started the capture cycle, 0 while the
  // overlay is closed. The frame's arrival is the one piece of timing a
  // user feels as lag in this component (the overlay is up and blank until
  // it lands), so the capture line carries it.
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  anchors.left: true
  anchors.right: true
  anchors.top: true
  anchors.bottom: true

  WlrLayershell.namespace: "vibranium:color-pick"
  WlrLayershell.layer: WlrLayer.Overlay
  // Exclusive, never OnDemand: the pick is a modal surface that owns the
  // screen for as long as it is up, and an OnDemand surface only takes the
  // keyboard when the compositor hands it over. Another overlay that already
  // holds the input - an open menu, the tray menu, an island with its focus
  // grab - keeps it, and the pick then sees no pointer at all: the lens stops
  // following the cursor and the right click that should cancel never
  // arrives. Exclusive is what every other full-screen pick surface in the
  // shell asks for (the capture picker, the annotation overlay, the QR
  // overlay), and it is released on close with the surface.
  WlrLayershell.keyboardFocus: overlay.visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  // One still frame of the source screen. Captures only ever run while
  // the overlay is mapped: at boot the capture backend has no recording
  // context yet and every premature request just warns.
  ScreencopyView {
    id: view

    property int attempts: 0

    anchors.fill: parent
    captureSource: overlay.visible ? overlay.screen : null
    live: false
    paintCursor: false
    visible: true
    // Rendered from the first frame, shown only once a frame exists:
    // grabToImage() reads the scene graph, and an item the scene graph
    // never rendered (visible: false) hands back a near-empty node - the
    // "smaller than needed, pinned top left, black borders on the
    // right/bottom" result, which is a broken grab and not a scaled one.
    // Opacity carries the show/hide so the node exists for the grab below.
    opacity: hasContent ? 1 : 0
    onStopped: {
      // Re-request only while the frame is still missing; a stop after
      // a good capture must not loop.
      if (overlay.visible && !view.hasContent) view.captureFrame()
    }
    onHasContentChanged: {
      // Frame landed: decode it once for the lens Canvas. The grab is
      // stable - the view is live:false, nothing moves under the lens.
      if (!hasContent) return
      // The target is explicit, derived from the frame that actually landed
      // and this window's own ratio, so the size the lens maps through comes
      // from the frame instead of from the item. Qt's implicit "grab at item
      // size" default rounds the item size independently of the surface it
      // backs, which is how a 1920x1080 frame comes back a few percent short
      // of itself. Qt still rounds the file it writes, so the result can sit
      // a device pixel off the frame (1921x1080 at a window ratio of 1.32);
      // the lens absorbs that, because it derives its own ratio from the file
      // it draws rather than assuming the frame's size.
      // ShotLib.grabTargetSize is the shared form of that arithmetic.
      const frame = ShotLib.grabSourceSize(view.width, view.height, overlay.dpr,
        view.sourceSize.width, view.sourceSize.height)
      const target = ShotLib.grabTargetSize(frame.width, frame.height, overlay.dpr)
      view.grabToImage(r => {
        const url = r && r.url !== undefined ? String(r.url) : ""
        // The lens has no frame to magnify. The pick itself is unaffected -
        // the module grabs its own.
        if (url === "") return
        overlay.frameUrl = url
      }, Qt.size(target.width, target.height))
    }
  }

  // Arm on map, reset the cursor so the magnifier only appears after the
  // first real move of this pick, and start the capture cycle: no
  // immediate captureFrame (the layer surface is not committed yet on
  // the map event and the compositor refuses with "no recording
  // context"); first attempt 120 ms in, retries at 250 ms, bounded at
  // eight attempts.
  onVisibleChanged: {
    overlay.cursorX = -1
    overlay.cursorY = -1
    overlay.frameUrl = ""
    if (visible) {
      view.attempts = 0
      capTimer.interval = 120
      capTimer.restart()
    } else {
      capTimer.stop()
    }
  }

  Timer {
    id: capTimer

    interval: 120
    repeat: true
    running: false
    onTriggered: {
      if (!overlay.visible || view.hasContent || view.attempts >= 8) {
        capTimer.stop()
        return
      }
      view.attempts++
      view.captureFrame()
      capTimer.interval = 250
    }
  }

  // The lens is the cursor: centered on the pointer (the real cursor is
  // blanked while the lens is up). Away from edges it is a circle; near
  // an edge it flattens into a rectangle that fills the space up to the
  // edge, animated through its corner radius. The magnified frame is
  // clipped by a MultiEffect layer mask; nothing else draws on top. The
  // magnifier never takes buttons so clicks fall through
  // to the sampling surface.
  Item {
    id: magnifier

    readonly property bool shown: view.hasContent && overlay.cursorX >= 0
    readonly property real size: 150
    readonly property real half: size / 2
    // Logical pixels per frame pixel: what magScale asks for, expressed in
    // the frame's own grid. The magnified Image below is scaled by exactly
    // this, which is what puts one frame pixel under magScale logical pixels.
    readonly property real magStep: overlay.frameRatio > 0
      ? overlay.magScale / overlay.frameRatio
      : 1
    // Pointer point in box-local coordinates. It drives the shape only: the
    // cross below is read back off the magnified view's own transform.
    readonly property real lensX: overlay.cursorX - x
    readonly property real lensY: overlay.cursorY - y
    // Corner radius fraction 1..0: 1 = circle, 0 = sharp rectangle.
    // Driven by the pointer's distance to the nearest box edge, so the
    // lens flattens exactly as far as the screen forces it to. This one
    // is instant and functional: the mask and the shadow shape must match
    // the current box, never a lagging value.
    readonly property real rf: {
      const room = Math.min(lensX, width - lensX, lensY, height - lensY)
      return Math.max(0, Math.min(1, room / half))
    }
    // Visual radius fraction: rf smoothed for the mask and shadow shape
    // only. Functional math never reads this - a radius that lags the box
    // lets the cross ride outside it and snap back when the animation
    // reaches it ("jumps and pins to an edge"). This is the shape's
    // response to pointer motion, not a state change, so the gate below
    // drops the easing only: the value still lands in the tick it starts.
    property real rfVis: rf

    Behavior on rfVis {
      enabled: MotionPolicy.enabled
      NumberAnimation {
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }
    }

    // Box around the pointer: full circle extent where the screen
    // allows it, flush against each edge otherwise.
    x: overlay.cursorX - Math.min(half, overlay.cursorX)
    y: overlay.cursorY - Math.min(half, overlay.cursorY)
    width: Math.min(half, overlay.cursorX)
      + Math.min(half, overlay.width - overlay.cursorX)
    height: Math.min(half, overlay.cursorY)
      + Math.min(half, overlay.height - overlay.cursorY)
    visible: shown

    // Where the magnified view sits: the pointer's frame pixel at the box
    // centre, then kept inside the frame, so a box flush against a screen
    // edge never magnifies past the frame's border. Two named values because
    // the cross reads the same numbers back rather than repeating them.
    readonly property real lensViewX: Math.max(width - overlay.width * magStep,
      Math.min(0, width / 2 - overlay.cursorX * magStep))
    readonly property real lensViewY: Math.max(height - overlay.height * magStep,
      Math.min(0, height / 2 - overlay.cursorY * magStep))
    // The cross marks the pixel a click samples: exactly where that magnified
    // view renders the pointer, inset by 7px so the 13px bars stay inside the
    // shape. Reading the position off the view's own transform is the whole
    // point - a cross placed by its own separate formula is how the marked
    // pixel and the sampled one drift apart. Where the view was shifted to
    // stay inside the frame the cross follows it, so near a screen edge it
    // marks the sampled pixel rather than sitting under the pointer.
    readonly property real crossX: Math.max(7,
      Math.min(width - 7, lensViewX + overlay.cursorX * magStep))
    readonly property real crossY: Math.max(7,
      Math.min(height - 7, lensViewY + overlay.cursorY * magStep))

    // Drop shadow under the lens, painted before lensClip so the lens
    // covers it. Its source is a dedicated hidden rounded rectangle -
    // NOT lensClip: that item's layer texture is the pre-mask content,
    // so shadowing it cast a big square slab past the shape. A plain
    // shape keeps the shadow glued to the circle-rectangle morph.
    Rectangle {
      id: shadowShape

      anchors.fill: parent
      radius: Math.min(magnifier.rfVis * Math.min(width, height) / 2,
        Math.min(width, height) / 2)
      visible: false
      color: "#000000"
    }

    MultiEffect {
      anchors.fill: shadowShape
      source: shadowShape
      shadowEnabled: true
      shadowBlur: 1.0
      shadowColor: "#b3000000"
    }

    // Masked clip: the magnified frame is cropped to the box and the
    // MultiEffect mask keeps only the disc of it.
    Item {
      id: lensClip

      anchors.fill: parent
      clip: true
      layer.enabled: true
      layer.smooth: true
      layer.samples: 4
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: lensMask
        maskThresholdMin: 0.5
        // Max spread for softest rim: 0.05 was jagged, 0.3 moderate,
        // 0.85 ~1.3px, 1.0 ~1.8px logical feather while 0.5 keeps the
        // radius at 75px logical. Full 1.0 is the MultiEffect max.
        maskSpreadAtMin: 1.0
      }

      // The magnified frame, as an Image scaled about the pointer and
      // cropped by the box. An Image is the only magnifier this component can
      // use: Qt's Context2D has no imageSmoothingEnabled state at all - the
      // assignment is accepted and ignored, and the painter's transform hint
      // is not reachable from QML - so a Canvas drawImage always interpolates.
      // A Canvas lens therefore shows a blend of up to four frame pixels where
      // the cross sits, a colour no probe ever copies, while smooth: false
      // keeps every block hard-edged at any ratio.
      //
      // The Image carries the whole mapping: at window size it is one frame
      // pixel per 1/frameRatio logical pixels, scaled by magStep, with the
      // pointer's frame pixel put at the box centre. The cross is read back
      // off that transform (magnifier.crossX), so what it marks and what a
      // click samples are the same number by construction.
      Image {
        id: lens

        width: overlay.width
        height: overlay.height
        transformOrigin: Item.TopLeft
        scale: magnifier.magStep
        x: magnifier.lensViewX
        y: magnifier.lensViewY
        source: overlay.frameUrl
        fillMode: Image.Stretch
        smooth: false
        cache: false
      }
    }

    // Mask shape for the rounded clip; only its layer texture is read.
    // Radius from the smoothed rfVis, capped to the geometry so a
    // mid-animation value can never exceed the box.
    Rectangle {
      id: lensMask

      anchors.fill: parent
      radius: Math.min(magnifier.rfVis * Math.min(width, height) / 2,
        Math.min(width, height) / 2)
      visible: false
      layer.enabled: true
      layer.smooth: true
      layer.samples: 4
    }

    // Cross over the sampled pixel (at crossX/crossY in lens coords): a
    // black shadow cross under a white one stays visible on any
    // background. Zero-size anchor item so the bars center on the
    // point, wherever rim clamping pushed it.
    Item {
      x: magnifier.crossX
      y: magnifier.crossY

      Rectangle {
        anchors.centerIn: parent
        width: 1
        height: 13
        color: "#000000"
        opacity: 0.9
      }
      Rectangle {
        anchors.centerIn: parent
        width: 13
        height: 1
        color: "#000000"
        opacity: 0.9
      }
      Rectangle {
        anchors.centerIn: parent
        width: 1
        height: 13
        color: "#ffffff"
      }
      Rectangle {
        anchors.centerIn: parent
        width: 13
        height: 1
        color: "#ffffff"
      }
    }
  }

  FocusScope {
    anchors.fill: parent
    focus: overlay.visible

    Keys.onEscapePressed: event => {
      overlay.cancelled()
      event.accepted = true
    }
  }

  MouseArea {
    id: pickArea

    anchors.fill: parent
    // Both buttons explicitly: the default is left-only, which silently
    // swallowed right clicks instead of cancelling.
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    hoverEnabled: true
    // The lens replaces the cursor while it is up; a cross cursor covers
    // the gap before the frame (or the first move) lands.
    cursorShape: magnifier.shown ? Qt.BlankCursor : Qt.CrossCursor
    onClicked: mouse => {
      // Left picks; right cancels like Esc.
      if (mouse.button === Qt.RightButton) {
        overlay.cancelled()
        return
      }
      // A click that landed outside this surface has no pixel to sample.
      // The exclusive surface keeps the pointer even when the cursor is on
      // another output, and the sampler clamps an out-of-frame coordinate to
      // the frame's edge - a real colour from the wrong place.
      if (mouse.x < 0 || mouse.y < 0
        || mouse.x > overlay.width || mouse.y > overlay.height) return
      overlay.pickedAt(mouse.x, mouse.y)
    }
    onPositionChanged: mouse => {
      overlay.cursorX = mouse.x
      overlay.cursorY = mouse.y
    }
    onWheel: wheel => {
      // One notch per 120 delta; integer scale keeps pixels crisp.
      overlay.magScale = Math.max(2, Math.min(20,
        overlay.magScale + (wheel.angleDelta.y > 0 ? 1 : -1)))
      wheel.accepted = true
    }
  }
}
