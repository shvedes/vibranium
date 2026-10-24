pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type signal-handler-parameters
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.common
import "AnnotationTools.js" as AnnotationTools
import "../../common/capture/RectMath.js" as RectMath
import "../../common/capture/ShotLib.js" as ShotLib

// Native region selector: a frozen still frame of one screen with a drag
// rectangle, size badge and magnifier lens. Multi-monitor crossing is out
// of scope - one overlay per focused screen. Coordinates emitted in
// window-logical pixels; the service scales them to frame pixels.
PanelWindow {
  id: overlay

  property int _uid: -1
  signal accepted(real x, real y, real w, real h)
  signal cancelled()
  signal failed(string reason)

  // Freeze-first seed: a file:// URL of a pre-grabbed fullscreen frame.
  // When set, the overlay shows it instead of capturing its own (the
  // seed predates the overlay map, so transient UI is still alive in
  // it). Empty means self-capture.
  property string seedUrl: ""
  property int seedFrameW: 0
  property int seedFrameH: 0
  readonly property bool seeded: overlay.seedUrl !== ""
  property bool immediate: false
  property int grabFrameW: 0
  property int grabFrameH: 0

  // Live selection in window-logical coordinates (empty until dragged).
  property real selX: 0
  property real selY: 0
  property real selW: 0
  property real selH: 0
  readonly property bool hasSelection: overlay.selW > 1 && overlay.selH > 1
  // hasSelection needs BOTH axes past 1px, so a drag that starts out
  // mostly horizontal or mostly vertical (extremely common - nobody
  // drags a perfect diagonal) sits at hasSelection=false for many
  // frames, sometimes the whole drag if the final rect is a thin strip.
  // Veil visibility must not wait for that: any active "new" drag shows
  // the cutout immediately, even at 0 size, or the interior stays under
  // the full 0.35 veil instead of going fully clear - the "still dimmed"
  // bug. Resize/move never need this since a real rect already exists.
  readonly property bool showCutout: overlay.hasSelection || overlay.dragMode === "new"

  // Cursor position for the lens; magnifier scale in integer steps.
  property real cursorX: -1
  property real cursorY: -1
  property var keyboardAnchor: null
  property bool keyboardMode: false
  property int magScale: 10
  // Rectangle lens shows only while SHIFT is held.
  property bool shiftDown: false

  // Where the lens box sits: on the pointer while nothing blocks it, off
  // the live rect while a cutout is up. A zero-area rect - a fresh drag
  // before its first move - has no interior to cover, so it does not
  // count. The lens content is sampled around the pointer regardless, so
  // this moves the box, never the magnification.
  readonly property bool lensDodges: overlay.showCutout
    && (overlay.selW > 0 || overlay.selH > 0)
  readonly property int lensGap: 4
  readonly property var lensOrigin: RectMath.placeBox(overlay.cursorX,
    overlay.cursorY, lensBox.size, lensDodges ? {
      x: overlay.selX, y: overlay.selY, w: overlay.selW, h: overlay.selH
    } : null, overlay.width, overlay.height, lensGap)

  // Drag state: "new" draws a fresh rect, "move" shifts the finished one,
  // "resize-<i>" drags handle i, "" idles.
  property string dragMode: ""
  property real dragStartX: 0
  property real dragStartY: 0
  property real origX: 0
  property real origY: 0
  property real origW: 0
  property real origH: 0
   property int dragHandle: -1
   property bool resizeMoved: false

  // The window's own effective DPR: the ratio Qt renders a grabToImage target
  // and a Canvas backing at, read off the object that owns the property, so a
  // selector that follows this window onto an output of another scale
  // re-derives its target instead of keeping the ratio it mapped with.
  // Screen.devicePixelRatio is a different number whenever Qt's ratio is
  // already folded into the window's logical size (a 1600x900 surface over a
  // 1920x1080 frame reports 2 there and 1.2 here), so it stays the fallback
  // for a window that has not reported a usable one of its own.
  readonly property real reportedDpr: overlay.devicePixelRatio > 0
    ? overlay.devicePixelRatio
    : ShotLib.qtDpr(Screen.devicePixelRatio)

  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  anchors.left: true
  anchors.right: true
  anchors.top: true
  anchors.bottom: true

  WlrLayershell.namespace: "vibranium:screenshot-region"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: overlay.visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  // One still frame of the source screen. Seeded selectors use the frozen
  // seed; immediate selectors start their self-capture on the next turn and
  // keep the same retry watchdog.
  ScreencopyView {
    id: view

    property int attempts: 0
    // The compositor's scale for this monitor: how a frame pixel relates to
    // a surface pixel. It is NOT the ratio that maps this window's logical
    // pixels onto the frame - the window's logical size already carries
    // Qt's own ratio - so nothing may scale a selection by it. The frame
    // ratio is measured from the frame and the item instead (see
    // frameScale), and the crop scale from the saved image
    // (ShotLib.grabRectScale). Needed explicitly because grabToImage's
    // implicit "grab at item size" default is NOT reliable under
    // fractional scale (1.25/1.5/etc) - it rounds itemSize
    // independently of whatever the compositor actually backs the
    // surface with, so the grabbed PNG ends up a few percent smaller
    // than the real frame. Passed as an explicit targetSize below
    // instead of trusting the default.
     property int grabAttempt: 0
    // The compositor's scale for this monitor: how a frame pixel relates to
    // a surface pixel. It is NOT the ratio that maps this window's logical
    // pixels onto the frame - the window's logical size already carries
    // Qt's own ratio - so nothing may scale a selection by it. The frame
    // ratio is measured from the frame and the item instead (see
    // frameScale), and the crop scale from the saved image
    // (ShotLib.grabRectScale). Needed explicitly because grabToImage's
    // implicit "grab at item size" default is NOT reliable under
    // fractional scale (1.25/1.5/etc) - it rounds itemSize
    // independently of whatever the compositor actually backs the
    // surface with, so the grabbed PNG ends up a few percent smaller
    // than the real frame. Passed as an explicit targetSize below
    // instead of trusting the default.
     readonly property real dpr: {
       let scale = 0
       try {
         const m = overlay.screen !== null && overlay.screen !== undefined
           ? Hyprland.monitorFor(overlay.screen) : null
         scale = m !== null && m !== undefined ? m.scale : 0
       } catch (e) { scale = 0 }
       return ShotLib.compositorScale(scale, Screen.devicePixelRatio)
     }

    anchors.fill: parent
    captureSource: overlay.visible && !overlay.seeded ? overlay.screen : null
    live: false
    paintCursor: false
    // NOT visible: false. An invisible item is skipped by the scene
    // graph entirely on most Qt versions, so grabToImage() on it grabs
    // nothing (or whatever stale/default-sized buffer happens to be
    // lying around) - that is the "smaller than needed, pinned top
    // left, black borders on the right/bottom" bug: it's not being
    // scaled wrong, it's grabbing a near-empty node and stretching
    // garbage. opacity: 0 still renders it (so the grab has real
    // content) while keeping it invisible to the user, same as before.
    visible: true
    opacity: 0
     onHasContentChanged: {
       if (!hasContent) return
       // The grab below already runs off this signal, so capTimer is only
       // the backstop behind it - but its own act on a landed frame is to
       // notice and stop, and left alone it notices at the end of the
       // interval it is part-way through, up to 250ms later, while the
       // view stays armed. Collapse the interval so it stops on the next
       // tick. 1ms, not 0: a QML Timer given a runtime-assigned interval
       // of 0 keeps reporting running and never fires again. `running` is
       // the guard because the immediate path arms the timer inside
       // Qt.callLater, and a frame landing before it is armed must not
       // restart a timer that is not polling for it.
       if (capTimer.running) {
         capTimer.interval = 1
         capTimer.restart()
       }
       if (overlay.seeded) {
         grabWatchdog.stop()
         overlay._grabPending = false
         return
       }
       const attempt = ++view.grabAttempt
       const source = ShotLib.grabSourceSize(view.width, view.height, view.dpr,
         view.sourceSize.width, view.sourceSize.height)
       const target = ShotLib.grabTargetSize(source.width, source.height, overlay.reportedDpr)
       // The frame the pipeline cuts in is the SAVED IMAGE, not the target:
       // Qt writes the target scaled by the window own DPR, and the two
       // differ by exactly that ratio. Both the selection mapping below and
       // the service clamp work in this grid, so publishing the target put
       // them on a smaller one than the file they address - a selection
       // landed anchored top-left and short of what the pointer drew.
       const saved = ShotLib.grabResultSize(target.width, target.height, overlay.reportedDpr)
       overlay.grabFrameW = saved.width
       overlay.grabFrameH = saved.height
        overlay._grabPending = true
        grabWatchdog.restart()
        const grabbed = view.grabToImage(r => {
          if (attempt !== view.grabAttempt || overlay.seeded || !overlay.visible) return
          grabWatchdog.stop()
          overlay._grabPending = false
          const url = r && r.url !== undefined ? String(r.url) : ""
          if (url === "") {
            overlay.failed("region preview capture failed")
            return
          }
          overlay._grabResult = r
          frameImg.source = url
        }, Qt.size(target.width, target.height))
        if (!grabbed) {
          grabWatchdog.stop()
          overlay._grabPending = false
          overlay.failed("region preview capture failed")
        }
     }

    // The compositor ended the stream, which is a reason no frame is coming
    // rather than a reason to wait out the next 250ms interval. `visible` is
    // the liveness gate, and it is what bounds this: capTimer keeps polling
    // alongside, fails the overlay at the eighth attempt and onVisibleChanged
    // closes it, so a stream that ends without content ends the capture
    // rather than re-arming forever. The re-request spends no attempt of its
    // own, so capTimer's count keeps its meaning for the failure message.
    onStopped: {
      if (overlay.visible && !view.hasContent) view.captureFrame()
    }
  }

  property var _grabResult: null
  property bool _grabPending: false

  Timer {
    id: grabWatchdog

    interval: 2500
    onTriggered: {
      if (!overlay._grabPending || overlay.seeded || !overlay.visible) return
      overlay._grabPending = false
      overlay.failed("region preview capture timed out")
    }
  }

  // Decoded frozen frame feeding the backdrop and the lens.
  Image {
    id: frameImg

    anchors.fill: parent
    visible: status === Image.Ready
    cache: false
    source: ""
    fillMode: Image.Stretch
    onStatusChanged: {
      if (status === Image.Error) overlay.failed("region preview decode failed")
    }
  }

    onVisibleChanged: {
      view.grabAttempt++
      grabWatchdog.stop()
      overlay._grabPending = false
      overlay.cursorX = overlay.visible && overlay.width > 0 ? overlay.width / 2 : -1
    overlay.cursorY = overlay.visible && overlay.height > 0 ? overlay.height / 2 : -1
    overlay.keyboardAnchor = null
    overlay.keyboardMode = false
    overlay.shiftDown = false
    overlay._grabResult = null
    frameImg.source = overlay.seeded ? overlay.seedUrl : ""
    overlay._clearSelection()
     if (visible && !overlay.seeded) {
       view.attempts = 0
       if (overlay.immediate) {
         capTimer.stop()
         Qt.callLater(() => {
           if (!overlay.visible || overlay.seeded) return
           view.captureFrame()
           capTimer.interval = 250
           capTimer.restart()
         })
       } else {
         capTimer.interval = 120
         capTimer.restart()
       }
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
      if (!overlay.visible || view.hasContent) {
        capTimer.stop()
        return
      }
      if (view.attempts >= 8) {
        capTimer.stop()
        overlay.failed("region preview capture failed")
        return
      }
      view.attempts++
      view.captureFrame()
      capTimer.interval = 250
    }
  }

  function _clearSelection() {
    overlay.selX = 0
    overlay.selY = 0
    overlay.selW = 0
    overlay.selH = 0
    overlay.dragMode = ""
    overlay.dragHandle = -1
    overlay.keyboardAnchor = null
  }

  function _keyboardMove(dx, dy) {
    if (overlay.cursorX < 0 || overlay.cursorY < 0) {
      overlay.cursorX = overlay.width / 2
      overlay.cursorY = overlay.height / 2
    }
    overlay.cursorX = Math.max(0, Math.min(overlay.width, overlay.cursorX + dx))
    overlay.cursorY = Math.max(0, Math.min(overlay.height, overlay.cursorY + dy))
    overlay.keyboardMode = true
    if (overlay.keyboardAnchor !== null) {
      const r = AnnotationTools.normRect(overlay.keyboardAnchor.x,
        overlay.keyboardAnchor.y, overlay.cursorX, overlay.cursorY)
      overlay.selX = r.x
      overlay.selY = r.y
      overlay.selW = r.w
      overlay.selH = r.h
      overlay._clampSelection()
    }
  }

  // Current selection in screen-logical pixels. The overlay is
  // fullscreen, so normally the identity - but a fresh window races
  // its first configure, and a drag in a still-growing window lives in
  // proportionally smaller coordinates. Unscaled, those crop a
  // shifted, zoomed sub-region (e.g. the middle instead of the
  // selected right quarter). Scaling by the window-to-screen ratio is
  // exact in both states.
  function _screenSelection() {
    // The grid is the saved frame's, on both paths. A seeded overlay is
    // handed the frame the service already cut from; a live one measures
    // the frame it just grabbed. The screen's own size is the fallback for
    // the window of an accept that lands before any frame exists - it is
    // the screen's LOGICAL size, which is a different grid again under a
    // fractional scale, so it is never preferred over a measured frame.
    const frameW = overlay.seeded && overlay.seedFrameW > 0
      ? overlay.seedFrameW : overlay.grabFrameW > 0
      ? overlay.grabFrameW : overlay.screen !== null && overlay.screen !== undefined
      ? overlay.screen.width : overlay.width
    const frameH = overlay.seeded && overlay.seedFrameH > 0
      ? overlay.seedFrameH : overlay.grabFrameH > 0
      ? overlay.grabFrameH : overlay.screen !== null && overlay.screen !== undefined
      ? overlay.screen.height : overlay.height
    return AnnotationTools.mapRectToFrame({
      x: overlay.selX, y: overlay.selY, w: overlay.selW, h: overlay.selH
    }, frameW, frameH, overlay.width, overlay.height)
  }

  function _emitSelection() {
    const r = overlay._screenSelection()
    overlay.accepted(r.x, r.y, r.w, r.h)
  }

  // A fresh overlay window configures fullscreen asynchronously: a
  // grab taken while still small freezes a soft frame, and the
  // selection mapping above keeps it positionally correct regardless.
  // Re-grab for sharpness while no frame is ready yet and nothing is
  // selected - never disturb a finished selection.
   function _reframe() {
     if (!overlay.visible || overlay.seeded || overlay.hasSelection) return
     const expected = ShotLib.grabItemSize(overlay.width, overlay.height, view.dpr)
     if (view.sourceSize.width > 0 && view.sourceSize.height > 0
       && !ShotLib.sourceSizeMatches(expected.width, expected.height,
         view.sourceSize.width, view.sourceSize.height, 1)) {
       view.grabAttempt++
       frameImg.source = ""
      overlay._grabResult = null
      view.destroyContextWithUpdate()
    }
     view.attempts = 0
     // 1ms, not 0: a QML Timer given a runtime-assigned interval of 0 keeps
     // reporting running and never fires again, and says nothing when it
     // stops - so an immediate-mode re-grab would leave capTimer armed but
     // mute, `attempts` frozen, and the ladder's give-up unreachable, with
     // grabWatchdog the only thing left able to end this grab. 1ms is the
     // finest a Timer carries and polls on the next tick.
     capTimer.interval = overlay.immediate ? 1 : 120
     capTimer.restart()
  }

  onWidthChanged: overlay._reframe()
  onHeightChanged: overlay._reframe()

  // Whether a compositor frame of this output is being taken at this
  // moment. The preview IS that frame, and a compositor captures an output
  // as it composites it - every layer surface it already holds included -
  // so a dim layer of this overlay painted while a request is in flight is
  // baked into the image it is dimming, at its own opacity, permanently.
  // That is the invariant every dim rectangle below obeys: no dim layer is
  // painted while this overlay is capturing.
  //
  // hasContent is the one signal that names the window exactly. It turns
  // true the moment the compositor's frame lands, and
  // destroyContextWithUpdate() turns it back to false, which is the path
  // both an output retarget and a _reframe re-grab take - so the gate
  // covers the opening request, every capTimer retry and every re-grab
  // alike, and a re-grab dims nothing while it is in flight either.
  //
  // A seeded selector is exempt for a reason of its own: its preview is a
  // frame the service grabbed before this surface existed, so there is no
  // request to be inside of, and it dims from the moment its seed decodes.
  readonly property bool capturing: overlay.visible && !overlay.seeded && !view.hasContent

  // Dim everything outside the selection with four plain rectangles - no
  // shader, no layer mask - and, while no rect is up, with a fifth
  // fullscreen veil, so region mode is dimmed rather than left as a bare
  // live desktop with a crosshair on it.
  //
  // All five are gated on !capturing, for the reason above: a dim layer must
  // never be one of the pixels the preview frame is made of. Past that gate
  // the dimming is presentation only - the image the pipeline cuts is
  // grabbed from view, a sibling of every dim layer here, so nothing painted
  // after the frame lands can reach that file.
  //
  // The fifth hides once a rect is being drawn: it covers the selection
  // INTERIOR too, and a live drag must show that area completely untouched
  // (the four side veils keep the outside dimmed; the interior itself
  // carries no veil at all).
  Rectangle {
    x: 0
    y: 0
    width: overlay.width
    height: overlay.height
     visible: !overlay.capturing && (overlay.immediate || frameImg.status === Image.Ready)
      && !overlay.showCutout
    color: "#000000"
    opacity: 0.35
  }
  Rectangle {
    x: 0
    y: 0
    width: overlay.width
    height: overlay.selY
    visible: overlay.showCutout && !overlay.capturing
    color: "#000000"
    opacity: 0.35
  }
  Rectangle {
    x: 0
    y: overlay.selY + overlay.selH
    width: overlay.width
    height: overlay.height - overlay.selY - overlay.selH
    visible: overlay.showCutout && !overlay.capturing
    color: "#000000"
    opacity: 0.35
  }
  Rectangle {
    x: 0
    y: overlay.selY
    width: overlay.selX
    height: overlay.selH
    visible: overlay.showCutout && !overlay.capturing
    color: "#000000"
    opacity: 0.35
  }
  Rectangle {
    x: overlay.selX + overlay.selW
    y: overlay.selY
    width: overlay.width - overlay.selX - overlay.selW
    height: overlay.selH
    visible: overlay.showCutout && !overlay.capturing
    color: "#000000"
    opacity: 0.35
  }

  // Accent-bordered selection rect plus the W x H badge in real pixels.
  Rectangle {
    x: overlay.selX
    y: overlay.selY
    width: overlay.selW
    height: overlay.selH
    visible: overlay.showCutout
    color: "transparent"
    border.color: Ui.solid("accent")
    border.width: 1
  }

  Rectangle {
    id: sizeBadge

    // Real pixels: the true scale, not a possibly rounded window DPR.
    readonly property real dprX: overlay.seeded && overlay.seedFrameW > 0 && overlay.width > 0
      ? overlay.seedFrameW / overlay.width : view.dpr
    readonly property real dprY: overlay.seeded && overlay.seedFrameH > 0 && overlay.height > 0
      ? overlay.seedFrameH / overlay.height : view.dpr
    readonly property string label: Math.round(overlay.selW * dprX) + " x " + Math.round(overlay.selH * dprY)

    x: Math.max(0, Math.min(overlay.width - width, overlay.selX))
    y: Math.max(0, overlay.selY - height - 4)
    width: badgeText.width + 12
    height: 20
    visible: overlay.hasSelection
    color: Ui.solid("background_1")
    border.color: Ui.solid("accent")
    border.width: 1

    Text {
      id: badgeText

      anchors.centerIn: parent
      text: sizeBadge.label
      font.pixelSize: Ui.fontS
      font.family: Ui.fontFamily
      color: Ui.solid("foreground_0")
    }
  }

  Item {
    visible: overlay.keyboardMode && overlay.cursorX >= 0 && overlay.cursorY >= 0
    x: overlay.cursorX - 7
    y: overlay.cursorY - 7
    width: 14
    height: 14

    Rectangle {
      anchors.centerIn: parent
      width: 14
      height: 2
      color: Ui.solid("accent")
    }
    Rectangle {
      anchors.centerIn: parent
      width: 2
      height: 14
      color: Ui.solid("accent")
    }
  }

  // Eight resize spots (corners + edge midpoints) with their cursors,
  // shared by the handle visuals and the resize math. The table itself is
  // AnnotationTools', because the editor's select frame, its crop frame and
  // these handles are indexed by the same eight in the same order.
  readonly property var spots: AnnotationTools.resizeSpots()

  // Eight resize handles, 8px dots on 16px hit targets, shown once the
  // drag completes.
  Repeater {
    model: overlay.hasSelection || overlay.dragMode === "resize" ? 8 : 0

    delegate: Item {
      required property int index

      z: 1

      MouseArea {
        id: handleArea

        x: overlay.selX + overlay.selW * overlay.spots[index].fx - 8
        y: overlay.selY + overlay.selH * overlay.spots[index].fy - 8
        width: 16
        height: 16
        acceptedButtons: Qt.LeftButton
        preventStealing: true
        cursorShape: overlay.spots[index].cur

        function overlayPoint(mouse) {
          return handleArea.mapToItem(overlay, mouse.x, mouse.y)
        }

        onPressed: mouse => {
          const p = handleArea.overlayPoint(mouse)
          overlay.dragMode = "resize"
           overlay.dragHandle = index
           overlay.dragStartX = p.x
           overlay.dragStartY = p.y
           overlay.resizeMoved = false
           overlay.origX = overlay.selX
          overlay.origY = overlay.selY
          overlay.origW = overlay.selW
          overlay.origH = overlay.selH
          mouse.accepted = true
        }
        onPositionChanged: mouse => {
           if (!pressed) return
           const p = handleArea.overlayPoint(mouse)
           if (Math.abs(p.x - overlay.dragStartX) + Math.abs(p.y - overlay.dragStartY) >= 1) {
             overlay.resizeMoved = true
           }
           if (overlay.resizeMoved) overlay._resizeTo(p.x, p.y)
        }
        onReleased: mouse => {
           if (mouse.button !== Qt.LeftButton) return
           if (overlay.resizeMoved) {
             const p = handleArea.overlayPoint(mouse)
             overlay._resizeTo(p.x, p.y)
           }
           if (!overlay.hasSelection) overlay._clearSelection()
           overlay.resizeMoved = false
           overlay.dragMode = ""
          mouse.accepted = true
        }
        onCanceled: {
          overlay.resizeMoved = false
          overlay.dragMode = ""
        }
      }

      Rectangle {
        visible: overlay.dragMode === ""
        x: overlay.selX + overlay.selW * overlay.spots[index].fx - 4
        y: overlay.selY + overlay.selH * overlay.spots[index].fy - 4
        width: 8
        height: 8
        radius: 4
        color: Ui.solid("accent")
      }
    }
  }

  // Rectangle magnifier, shown only while SHIFT is held: a fixed square
  // with literal source pixels and a cross on the exact pixel, kept clear
  // of the live selection. No circle morph, no mask layers.
  Item {
    id: lensBox

    readonly property bool shown: overlay.shiftDown && frameImg.status === Image.Ready && overlay.cursorX >= 0
    readonly property real size: 120
    // Origin tracks the pointer until a rect exists to dodge. The content
    // stays centered on the pointer pixel either way, so the cross always
    // marks the pixel being magnified - which is the box center, not the
    // pointer, once the box has stepped aside.
    x: overlay.lensOrigin.x
    y: overlay.lensOrigin.y
    width: size
    height: size
    visible: shown
    // Whether the box center still sits on the pointer, within a pixel.
    // This is the one case where the lens cross and the cursor are the same
    // mark, and the only case where hiding the cursor loses nothing.
    readonly property bool coversPointer: Math.abs(x + width / 2 - overlay.cursorX) < 1
      && Math.abs(y + height / 2 - overlay.cursorY) < 1

    // Square lens: plain canvas, accent border below.

    Canvas {
        id: lens

        anchors.fill: parent
        contextType: "2d"
        renderStrategy: Canvas.Immediate
        // The backing is the item in DEVICE pixels. The scene presents a
        // backing 1:1 in device pixels from the item's top-left, so the
        // default (item-sized) backing covers only the top-left 1/DPR of
        // what the box occupies on screen and the rest stays bare backing -
        // the magnified region sat in the top-left corner with black down
        // the right and the bottom. A grab cannot see this, because
        // grabToImage stretches the item into the target buffer. The repaint
        // on a changed ratio rides the window's change signal below.
        canvasSize: Qt.size(Math.max(1, Math.round(width * overlay.reportedDpr)),
          Math.max(1, Math.round(height * overlay.reportedDpr)))

        onPaint: {
          const ctx = lens.getContext("2d")
          if (ctx === null) return
          // Clear the whole (device-sized) backing, then carry the DPR on
          // the transform so every coordinate below stays in box pixels.
          ctx.setTransform(1, 0, 0, 1, 0, 0)
          ctx.clearRect(0, 0, lens.canvasSize.width, lens.canvasSize.height)
          if (frameImg.status !== Image.Ready) return
          const fw = frameImg.implicitWidth
          const fh = frameImg.implicitHeight
          if (fw <= 0 || fh <= 0) return
          const fpx = fw / Math.max(1, view.width)
          const fpy = fh / Math.max(1, view.height)
          const stepX = overlay.magScale / fpx
          const stepY = overlay.magScale / fpy
          const fx = overlay.cursorX * fpx
          const fy = overlay.cursorY * fpy
           const rw = Math.max(1, Math.min(fw, Math.ceil(lens.width / stepX)))
           const rh = Math.max(1, Math.min(fh, Math.ceil(lens.height / stepY)))
           const ox = Math.max(0, Math.min(fw - rw, Math.floor(fx - rw / 2)))
           const oy = Math.max(0, Math.min(fh - rh, Math.floor(fy - rh / 2)))
          // Literal pixels, content centered on the pointer. The transform
          // carries the DPR, so the destination stays in box pixels and each
          // source pixel still lands as an exact block of device pixels.
          ctx.setTransform(overlay.reportedDpr, 0, 0, overlay.reportedDpr, 0, 0)
          ctx.imageSmoothingEnabled = false
          ctx.drawImage(frameImg, ox, oy, rw, rh, 0, 0, lens.width, lens.height)
        }

        Connections {
          target: overlay

          function onCursorXChanged() {
            lens.requestPaint()
          }

          function onCursorYChanged() {
            lens.requestPaint()
          }

          function onMagScaleChanged() {
            lens.requestPaint()
          }

          function onShiftDownChanged() {
            lens.requestPaint()
          }

          function onReportedDprChanged() {
            lens.requestPaint()
          }
        }

        Connections {
          target: view

          function onWidthChanged() {
            lens.requestPaint()
          }

          function onHeightChanged() {
            lens.requestPaint()
          }
        }

        Connections {
          target: frameImg

          function onStatusChanged() {
            lens.requestPaint()
          }
        }
      }

      Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.color: Ui.solid("accent")
        border.width: 1
      }

      // Cross dead-center: the content is centered on the pointer pixel, so
      // this is the magnified pixel and stays the box center even when the
      // box itself is not over the pointer.
      Item {
        x: lensBox.width / 2
        y: lensBox.height / 2

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
    onVisibleChanged: {
      if (visible) forceActiveFocus()
    }

    Keys.onEscapePressed: event => {
      overlay.cancelled()
      event.accepted = true
    }
    Keys.onReturnPressed: event => {
      if (overlay.hasSelection) overlay._emitSelection()
      event.accepted = true
    }
    Keys.onEnterPressed: event => {
      if (overlay.hasSelection) overlay._emitSelection()
      event.accepted = true
    }
    Keys.onPressed: event => {
      if (event.key === Qt.Key_Shift) {
        overlay.shiftDown = true
        event.accepted = true
        return
      }
      const step = event.modifiers & Qt.ShiftModifier ? 10 : 1
      if (event.key === Qt.Key_Left) {
        overlay._keyboardMove(-step, 0)
        event.accepted = true
      } else if (event.key === Qt.Key_Right) {
        overlay._keyboardMove(step, 0)
        event.accepted = true
      } else if (event.key === Qt.Key_Up) {
        overlay._keyboardMove(0, -step)
        event.accepted = true
      } else if (event.key === Qt.Key_Down) {
        overlay._keyboardMove(0, step)
        event.accepted = true
      } else if (event.key === Qt.Key_Space) {
        if (overlay.keyboardAnchor === null) {
          overlay.keyboardMode = true
          overlay.keyboardAnchor = { x: overlay.cursorX, y: overlay.cursorY }
        } else {
          overlay.keyboardAnchor = null
        }
        event.accepted = true
      }
    }
    Keys.onReleased: event => {
      if (event.key === Qt.Key_Shift) {
        overlay.shiftDown = false
        event.accepted = true
      }
    }
  }

    MouseArea {
      id: dragArea

      z: -1
      anchors.fill: parent
    // Both buttons explicitly: the default is left-only, which silently
    // swallowed right clicks instead of cancelling.
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    hoverEnabled: true
    // The lens replaces the cursor only while it covers the pointer, which
    // is when its cross and the pointer would be the same mark. Once a rect
    // has pushed the box aside the two are at different places, so the real
    // cursor stays: a blank one would leave the pointer unmarked entirely
    // for as long as the lens is up. A cross cursor also covers the gap
    // before the frame (or the first move) lands.
    cursorShape: lensBox.shown && lensBox.coversPointer
      ? Qt.BlankCursor : Qt.CrossCursor
    onClicked: mouse => {
      // Left picks; right cancels like Esc.
      if (mouse.button === Qt.RightButton) {
        overlay.cancelled()
        return
      }
      if (overlay.hasSelection && overlay.dragMode === ""
        && mouse.x >= overlay.selX && mouse.x <= overlay.selX + overlay.selW
        && mouse.y >= overlay.selY && mouse.y <= overlay.selY + overlay.selH) {
        overlay._emitSelection()
      }
    }
    onDoubleClicked: mouse => {
      if (mouse.button === Qt.LeftButton && overlay.hasSelection) {
        overlay._emitSelection()
      }
    }
    onPressed: mouse => {
      if (mouse.button !== Qt.LeftButton) return
      overlay.dragStartX = mouse.x
      overlay.dragStartY = mouse.y
      if (overlay.hasSelection
        && mouse.x >= overlay.selX && mouse.x <= overlay.selX + overlay.selW
        && mouse.y >= overlay.selY && mouse.y <= overlay.selY + overlay.selH) {
        overlay.dragMode = "move"
      } else {
        overlay.dragMode = "new"
      }
      overlay.origX = overlay.selX
      overlay.origY = overlay.selY
      overlay.origW = overlay.selW
      overlay.origH = overlay.selH
    }
    onPositionChanged: mouse => {
      overlay.keyboardMode = false
      overlay.keyboardAnchor = null
      overlay.cursorX = mouse.x
      overlay.cursorY = mouse.y
      if (!(mouse.buttons & Qt.LeftButton) || overlay.dragMode === "") return
      if (overlay.dragMode === "new") {
        const r = AnnotationTools.normRect(overlay.dragStartX, overlay.dragStartY, mouse.x, mouse.y)
        overlay.selX = r.x
        overlay.selY = r.y
        overlay.selW = r.w
        overlay.selH = r.h
      } else if (overlay.dragMode === "move") {
        overlay.selX = overlay.origX + mouse.x - overlay.dragStartX
        overlay.selY = overlay.origY + mouse.y - overlay.dragStartY
      } else if (overlay.dragMode === "resize") {
        overlay._resizeTo(mouse.x, mouse.y)
      }
      overlay._clampSelection()
    }
    onReleased: mouse => {
      if (mouse.button !== Qt.LeftButton) return
       if (overlay.dragMode === "resize") overlay._resizeTo(mouse.x, mouse.y)
       overlay._clampSelection()
       if (!overlay.hasSelection) overlay._clearSelection()
      overlay.dragMode = ""
    }
    onWheel: wheel => {
      // One notch per 120 delta; integer scale keeps pixels crisp.
      overlay.magScale = Math.max(2, Math.min(20,
        overlay.magScale + (wheel.angleDelta.y > 0 ? 1 : -1)))
      wheel.accepted = true
    }
  }

  // Resize the finished rect by dragging handle corners/edges. The
  // dragged point follows the pointer, the opposite side stays fixed;
  // dragging past it flips the rect through min/max.
  function _resizeTo(mx, my) {
    const spot = overlay.spots[overlay.dragHandle]
    if (!spot) return
    const r = AnnotationTools.resizeFromHandle({
      x: overlay.origX, y: overlay.origY, w: overlay.origW, h: overlay.origH
    }, spot, mx, my)
    overlay.selX = r.x
    overlay.selY = r.y
    overlay.selW = r.w
    overlay.selH = r.h
    overlay._clampSelection()
  }

  // Keep the selection inside the overlay window. A drag continuing past
  // a screen edge leaves the compositor's pointer space (the overlay
  // stops getting moves, or gets them out of bounds): unclamped, the
  // rect ends partially or wholly off-screen and the capture grabs
  // whatever fraction remains - the "stretched sliver" capture. On
  // release, anything that fell below the minimum size is dropped.
  function _clampSelection() {
    // Nothing to clamp while idle without a finished selection.
    if (overlay.dragMode === "" && !overlay.hasSelection) return
    const r = RectMath.clampRectInBox({
      x: overlay.selX, y: overlay.selY, w: overlay.selW, h: overlay.selH
    }, overlay.width, overlay.height)
    overlay.selX = r.x
    overlay.selY = r.y
    overlay.selW = r.w
    overlay.selH = r.h
  }
}
