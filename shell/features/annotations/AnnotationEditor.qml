pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type signal-handler-parameters
import QtQuick
import QtQuick.Dialogs
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.common
import "AnnotationTools.js" as AnnotationTools
import "../../common/capture/ShotLib.js" as ShotLib
import "../../common/text/StringUtils.js" as SU
import "../../common/math/Range.js" as Range

// Native annotation editor as a modal fullscreen overlay: black veil over
// the desktop, the shot fitted center, one Canvas painting base image +
// replayed strokes in image pixels, floating icon tool panel at the
// bottom. Clipboard offers a persistent file URI through wl-copy (plus a
// text URI fallback) and toasts reuse the daemon bridge.
// Owned one-directionally by the screenshots service via shotPath; file
// browsing stays with ImageViewer.
//
// Keyboard is Exclusive while open (modal) so hotkeys always land: U/R
// undo/redo (shortcuts only, no buttons), B/E/L/A/G/O/T/D/C/V tools,
// Ctrl+Z/Y/S/C, Delete drops the selection, Enter confirms a staged
// crop, Escape walks back (field -> crop -> selection -> arm discard ->
// close).
//
// SPLIT MAP (one owner each, no behavior change): Canvas (board image +
// stroke replay, view rect, probes, board I/O), Toolbar (tool row,
// palette, handles, tool buttons), Crop (crop frame/rect, staged crop,
// apply). Strokes paint above the board image line, chrome below it.
PanelWindow {
  id: editor

  required property string shotPath
  // Instance id assigned by the screenshots service: pairs probe
  // lines with annotate() opens in the logs.
  property int _uid: -1
  property bool _closing: false
  readonly property string _sessionId: Quickshell.processId + "-" + Date.now()
  // Final save target: the temp-load flows (annotator opened by a capture)
  // write here on Save; direct opens choose a distinct Save As target.
  property string savePath: ""
  // False in clipboard-only flows: Save copies pixels, writes no file.
  property bool saveToDisk: true
  property string fileType: "png"
  // Snapshot of shell.screenshots.showNotification at capture time.
  // Gates only the success toasts below; failures still notify.
  property bool showNotification: true

  // Each item: { tool, color, width, points: [{x,y}], text?, fontSize? }
  // in document pixels (== source image pixels pre-crop). Every tool paints
  // from these alone, so a replay can never go stale.
  property var strokes: []
  property int redoIndex: 0  // strokes.length == committed; redo past it
  // Dirty means visible work exists (fully undone counts as clean).
  // An applied crop frame counts: cancelling must guard it, and
  // copying must snapshot it instead of copying the file reference.
  readonly property bool dirty: editor.redoIndex > 0 || editor.cropFrame !== null
    || editor.docRot !== 0 || editor.preview !== null || editor.cropRect !== null
    || editor.textRect !== null || editor.textAnchor !== null || editor.selectedIndex >= 0
  readonly property bool canClear: editor.redoIndex > 0 || editor.cropFrame !== null
    || editor.docRot !== 0 || editor.preview !== null || editor.cropRect !== null
    || editor.textRect !== null || editor.textAnchor !== null

  property string tool: "brush"
  // A tool switch commits an open field, the same as a press outside it: the
  // toolbar sits outside the input box, and a tool chosen there must not leave
  // a live field behind on a canvas that now belongs to another tool.
  onToolChanged: {
    if (editor.textAnchor !== null) editor._finishText(true)
    // A tool switch drops the active element: the focus the last release left
    // behind is that tool's, and the next tool starts with nothing selected.
    if (editor.selectedIndex >= 0) editor.selectedIndex = -1
  }
  property string ink: "#ffffff"
  property real penWidth: 3
  property int fontSize: 24

  // Base image pixel size once decoded (0 until then).
  property int imgW: 0
  property int imgH: 0
  // Document view into the base image: full frame, narrowed by crops.
  property var viewRect: ({ x: 0, y: 0, w: 0, h: 0 })
  property bool boardReady: false
  property string loadState: "loading"
  property bool exporting: false
  property int _exportSeq: 0
  property string _activeOutput: ""
  property bool _outputClipboardOwned: false
  property string _preservedOutput: ""
  property bool directSource: false
  property string runtimeDir: Paths.vibraniumRuntime
  property bool _saveTargetExisted: false
  property bool _saveTargetPending: false
  property int _saveCheckSeq: 0
  property int _copySeq: 0
  property string _fallbackTarget: ""
  property bool _fallbackCommitted: false
  property var _childProcesses: []
  property bool _saveDialogOpen: false
  readonly property bool interactionLocked: editor.exporting || editor._saveTargetPending || editor._saveDialogOpen

  // ---- blur (the picture only) ----
  // One GPU-blurred copy of the picture, grabbed to a PNG once per shot. The
  // on-screen overlay and the export canvas both draw from that file, so a
  // region costs a clipped texture copy and nothing per frame. The plate is
  // bounded to _blurPlateMax on its long side: blur is low-frequency, so a
  // downscaled plate upscales without visible loss and costs a fraction of a
  // full-resolution layer.
  readonly property int _blurPlateMax: 2048
  readonly property real _blurPlateK: editor.imgW > 0 && editor.imgH > 0
    ? Math.min(1, editor._blurPlateMax / Math.max(editor.imgW, editor.imgH)) : 1
  readonly property int _blurPlateW: Math.max(1, Math.round(editor.imgW * editor._blurPlateK))
  readonly property int _blurPlateH: Math.max(1, Math.round(editor.imgH * editor._blurPlateK))
  // Blur radius in document pixels: ~96 at plate scale, scaled up for large
  // shots and capped. Measured on a text page: 96 and up left nothing legible,
  // 60 left the words readable.
  readonly property int _blurRadius: Range.clamp(Math.round(96 / editor._blurPlateK), 96, 240)
  property string blurPlateUrl: ""
  property string _blurPlatePath: ""
  property bool _blurPlatePending: false
  // Set once the grab has run: the effect item hides from then on.
  property bool _blurPlateDone: false
  property int _blurPlateTries: 0
  // Blur regions in document pixels, clipped to the applied crop frame. The
  // overlay and the export both read this list, so a staged frame trims what
  // the canvas would have clipped anyway.
  readonly property var blurRects: editor._blurRects()
  // The live drag's region (null when it is not a blur drag, or when it sits
  // on area that is already blurred).
  readonly property var previewBlurRect: editor._previewBlurRect()

  // In-progress stroke (preview), pending crop rect and pending text
  // rect, all in document pixels.
  property var preview: null
  property var cropRect: null
  // Applied crop frame in document pixels (rounded ints), null
  // when the whole document is kept. Strokes, history and the
  // view rect stay untouched while it lives, so it can be
  // resized later; save/copy honor it for one grab.
  property var cropFrame: null
  readonly property var _cropDimRect: editor.cropRect !== null && editor.cropRect.w > 1 && editor.cropRect.h > 1
    ? editor.cropRect : editor.cropFrame
  // Fades the outer dim veil in for both a staged and an applied frame.
  // Canvas paints are one-shot, not declarative, so a Behavior alone does
  // nothing - onCropDimOpacityChanged drives repaints for every frame.
  property real cropDimOpacity: editor._cropDimRect !== null ? 1 : 0
  Behavior on cropDimOpacity {
    enabled: editor.animOn
    NumberAnimation { duration: 220; easing.type: Easing.OutQuad }
  }
  onCropDimOpacityChanged: board.requestPaint()
  property var textRect: null
  property var textAnchor: null
  // Inline field metrics for the staged text rect (display px).
  property real textRectW: 0
  property real textPx: 24
  // Selected stroke index for the select tool (-1 = none).
  property int selectedIndex: -1

  // Two-step destructive buttons arm instead of a dialog.
  property bool clearArmed: false
  property bool discardArmed: false
  onCanClearChanged: {
    if (!editor.canClear) editor.clearArmed = false
  }

  readonly property var palette: ["#ffffff", "#000000", "#ff5555", "#50fa7b",
    "#8be9fd", "#f1fa8c", "#bd93f9", "#ffb86c"]

  // The selected element, or -1. A selection only counts while it is live:
  // inside the committed range and inside the stroke list, the same bounds
  // the paint and the handles test against.
  readonly property int selectedStrokeIndex: {
    const i = editor.selectedIndex
    return i >= 0 && i < editor.redoIndex && i < editor.strokes.length ? i : -1
  }

  // The colour the palette is editing: the active element's own colour while
  // one is active - a Select selection or the element the last drag just
  // committed - and the next-stroke ink otherwise. One expression for the tile
  // highlight and the screen-reader state, so they cannot disagree about which
  // swatch is current.
  readonly property string activeColor: {
    const i = editor.selectedStrokeIndex
    return i >= 0 ? String(editor.strokes[i].color || "") : editor.ink
  }

  // A palette tile. While an element is active it recolours that element -
  // text included, since a text stroke paints from its own colour - and with
  // nothing active it chooses the ink for the next one. Select with nothing
  // selected leaves both alone rather than recolouring whatever happens to be
  // next.
  function applyColor(color) {
    const i = editor.selectedStrokeIndex
    if (i >= 0) {
      const kept = editor.strokes.slice()
      kept[i] = Object.assign({}, kept[i], { color: color })
      editor.strokes = kept
      board.requestPaint()
      return true
    }
    if (editor.tool === "select") return false
    editor.ink = color
    return true
  }

  // The pen-width control, with the same rule as the palette: the active
  // element's own line is resized, and the width is remembered for the next
  // one either way. Text carries its size in fontSize, so a text element is not
  // touched here.
  function applyWidth(v) {
    editor.penWidth = v
    const i = editor.selectedStrokeIndex
    if (i < 0 || editor.strokes[i].tool === "text") return false
    const kept = editor.strokes.slice()
    kept[i] = Object.assign({}, kept[i], { width: v })
    editor.strokes = kept
    board.requestPaint()
    return true
  }

  // tool -> [icon, fallback glyph]. The eraser svg is still to come and
  // renders its letter until it lands in assets/icons - Icons.url("")
  // keeps the binding pending, so adding the file lights the button up
  // after a shell restart with no code change.
  readonly property var tools: ["select", "brush", "line", "eraser", "arrow", "arrowCorner", "rect",
    "ellipse", "text", "blur", "crop"]
  readonly property var toolMeta: ({
    brush: { icon: "brush", glyph: "B", key: "B", tip: "Brush (B)" },
    line: { icon: "line", glyph: "L", key: "L", tip: "Line (L)" },
    eraser: { icon: "eraser", glyph: "E", key: "E", tip: "Eraser (E)" },
    arrow: { icon: "arrow", glyph: "A", key: "A", tip: "Arrow (A)" },
    arrowCorner: { icon: "arrow-corner", glyph: "N", key: "N", tip: "Elbow arrow (N)" },
    rect: { icon: "selection", glyph: "R", key: "G", tip: "Rectangle (G)" },
    ellipse: { icon: "circle", glyph: "O", key: "O", tip: "Ellipse (O)" },
    blur: { icon: "hypr-blur", glyph: "D", key: "D", tip: "Blur (D)" },
    text: { icon: "text", glyph: "T", key: "T", tip: "Text (T)" },
    crop: { icon: "crop", glyph: "C", key: "C", tip: "Crop (C)" },
    select: { icon: "cursor", glyph: "V", key: "V", tip: "Select (V)" }
  })

  // Toolbar scale factor (shell.screenshots.uiSize): small 1, medium
  // 1.25, large 1.5. Applies to toolbar metrics only, never the canvas.
  readonly property real uiScale: {
    Settings.rev
    const v = Settings.value("shell.screenshots.uiSize")
    return v === "large" ? 1.5 : v === "medium" ? 1.25 : 1
  }

  // Whether this surface moves at all: MotionPolicy.enabled, the one
  // shared compositor-wide switch (Hyprland Appearance -> Animations), so
  // the hover fades and the slide-in read the same answer as the rest of
  // the shell instead of a local copy of the key. The gate is `=== true`,
  // which fails closed: a build without the setting, or a settings backend
  // that has not answered yet, reads as "no motion" rather than
  // "all motion".
  readonly property bool animOn: MotionPolicy.enabled

  // Free view over the fitted document: zoom multiplier plus display
  // pan offset. The backing stays document pixels (save is unaffected);
  // only display geometry and mapping follow the view.
  // Zoom per wheel notch, in either direction. Also the open framing
  // step, so opening and zooming agree on the size of one step.
  readonly property real _wheelStep: 1.2
  // Open framing: one wheel step out from fit, for region and
  // screen captures alike. `0` returns here (not to 1), so reset
  // always matches what the user opened with.
  readonly property real _openZoom: 1 / editor._wheelStep
  property real viewZoom: editor._openZoom
  property real _zoomAnim: editor.viewZoom
  property real _boardZoom: editor._openZoom
  Behavior on _zoomAnim {
    enabled: editor.animOn
    NumberAnimation { duration: 260; easing.type: Easing.OutQuad }
  }
  on_ZoomAnimChanged: editor._settleBoardZoom()
  property var viewPan: ({ x: 0, y: 0 })

  // Display geometry. No device ratio appears anywhere in the display
  // path. The scene presents an item-sized backing 1:1 in LOGICAL pixels
  // over the item's rect, so a backing built at item * DPR covers only
  // the top-left 1/DPR of the item and the remainder stays bare, while
  // putting that ratio on the paint transform instead draws every stroke
  // that much too large, anchored at the item's top-left. Backing is the
  // item, the transform is _paintK, and the picture is boardImage laid
  // out by ordinary item geometry underneath, so ink and pixels share a
  // single mapping with no second one to hold in step with it.
  //
  // A grab cannot check this: grabToImage stretches the item into its
  // target buffer, so it renders a wrongly sized backing as though it
  // were correct. Only a marker document measured on screen settles it.
  // _bufPerPx below keeps stroke widths a constant on-screen thickness
  // across zooms.
  readonly property real _paintK: editor._fit * editor._zoomAnim
  // Doc-space size of one backing pixel under the K transform above -
  // draw line widths at this so they come out ~1px regardless of zoom,
  // instead of getting thicker/thinner as K changes.
  readonly property real _bufPerPx: editor._paintK > 0 ? 1 / editor._paintK : 1

  readonly property string fileUrl: Paths.toFileUrl(editor.shotPath)

   onLoadStateChanged: {
      if (loadState === "ready") {
        panel.reveal()
        editor._settleBoardZoom()
      }
     else {
       slideAnim.stop()
       panel.visible = false
     }
   }
   onCropFrameChanged: {
     if (boardReady) board.requestPaint()
   }
    onCropRectChanged: {
      if (boardReady) board.requestPaint()
    }
    onSelectedIndexChanged: {
      if (boardReady) board.requestPaint()
    }

  color: Ui.solid("background_0")
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  anchors.left: true
  anchors.right: true
  anchors.top: true
  anchors.bottom: true

  WlrLayershell.namespace: "vibranium:screenshot-annotate"
  WlrLayershell.layer: WlrLayer.Overlay
  // Modal: hotkeys must land regardless of prior focus.
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

  // Cumulative document rotation in degrees. Never wrapped modulo 360 -
  // trig is periodic regardless, and wrapping would make _rotAnim's
  // Behavior animate the long way around every time docRot crosses 0
  // (e.g. 270 -> 0 reads as a -270 spin instead of continuing +90).
  // Strokes stay in original document coordinates; only the paint
  // transform and the backing size rotate - so hit tests, crops, grids
  // and the mouse map never need remapping math.
  property int docRot: 0

  // Visual rotation actually used for layout/paint: bound straight to
  // docRot, but the Behavior below eases any change instead of snapping,
  // so _docW/_docH/_fit/_geom (all downstream of this) animate too - the
  // whole horizontal<->vertical morph plays out over the animation
  // instead of jumping instantly and only spinning after.
  property real _rotAnim: editor.docRot
  Behavior on _rotAnim {
    enabled: editor.animOn
    // Fast start, slow settle - no bounce/overshoot, just a curve
    // instead of a straight linear ramp.
    NumberAnimation { duration: 500; easing.type: Easing.OutExpo }
  }

  // Bounding box of the (unrotated) view rect at the current animated
  // angle - the general rotating-rectangle formula, not a discrete
  // swap. At angle 0/90/180/270 this reduces to exactly the values a
  // swap-or-not would give, so nothing downstream needs to know the
  // difference; at in-between angles it gives the true morphing size.
  readonly property real _docW: {
    const a = editor._rotAnim * Math.PI / 180
    return Math.abs(editor.viewRect.w * Math.cos(a)) + Math.abs(editor.viewRect.h * Math.sin(a))
  }
  readonly property real _docH: {
    const a = editor._rotAnim * Math.PI / 180
    return Math.abs(editor.viewRect.w * Math.sin(a)) + Math.abs(editor.viewRect.h * Math.cos(a))
  }

  // Fit scale of the displayed document into the stage. Below this the
  // short axis of an extreme-aspect capture (very tall+thin or
  // wide+short) is too thin to click or draw on; overflow the stage
  // instead of shrinking further - middle-drag pan and wheel zoom
  // already exist to reach the rest.
  readonly property real _minAxisPx: 160
  readonly property real _fit: AnnotationTools.fitScale(
    stage.width, stage.height, editor._docW, editor._docH, editor._minAxisPx)
  readonly property real _boardPaintK: editor._fit * editor._boardZoom
  readonly property real _boardScale: editor._boardZoom > 0
    ? editor._zoomAnim / editor._boardZoom : 1
  readonly property var _boardGeom: AnnotationTools.boardGeom(
    stage.width, stage.height, editor._docW, editor._docH,
    editor._fit, editor._boardZoom, editor.viewPan)

  // The picture's own display size, before rotation: the view rect at the
  // same fit and board zoom the box above is built with. The box is this
  // rect ROTATED, so the picture must never be sized from the box itself.
  readonly property var _pictureSize: AnnotationTools.pictureSize(
    editor.viewRect, editor._fit, editor._boardZoom)

  // Live board geometry from synchronous state only. Every mapping
  // read goes through here so handlers never mix binding generations.
  readonly property var _geom: AnnotationTools.boardGeom(
    stage.width, stage.height, editor._docW, editor._docH,
    editor._fit, editor._zoomAnim, editor.viewPan)

  // Eight resize spots (corners + edge midpoints) with their cursors,
  // shared by the select and crop-frame handle visuals and resize math.
  // Same table as the region overlay reads: corners on even indexes, edge
  // midpoints on odd ones. One table serves every consumer, so a row inserted
  // into one copy cannot shift the cursor on the others.
  readonly property var handleSpots: AnnotationTools.resizeSpots()

  // Document-space handles of the current selection bounds, in
  // handleSpots order. Single source for the display corners below and
  // the resize anchors in the press handler.
  function _selectDocHandles() {
    if (editor.selectedIndex < 0 || editor.selectedIndex >= editor.strokes.length) return null
    return AnnotationTools.selectHandles(editor._strokeBounds(editor.strokes[editor.selectedIndex]))
  }

  // Free zoom about the stage center; pan is middle-drag's job
  // and is never touched here, so repeated zooms cannot walk.
  function _zoomAt(mx, my, f) {
    void mx
    void my
    editor.viewZoom = Range.clamp(editor.viewZoom * f, 0.25, 8)
    editor._settleBoardZoom()
  }

  function _settleBoardZoom() {
    if (!editor.boardReady) return
    if (Math.abs(editor._zoomAnim - editor.viewZoom) > 0.0001) return
    editor._boardZoom = editor.viewZoom
    board.requestPaint()
  }

  function _resetView() {
    editor.viewZoom = editor._openZoom
    editor.viewPan = { x: 0, y: 0 }
    editor._settleBoardZoom()
  }

  function _clampDocumentRect(r) {
    return AnnotationTools.clampDocumentRect(r, editor.viewRect)
  }

  function _exportViewRect() {
    return AnnotationTools.exportViewRect(editor.viewRect, editor.cropFrame)
  }

  function _exportSize(vr) {
    return AnnotationTools.exportSize(vr, editor.docRot)
  }

  function exportTo(path, done) {
    const target = String(path ?? "")
    if (target === "" || !editor.boardReady || editor.imgW <= 0) return false
    if (exportCanvas.getContext("2d") === null) return false
    exportCanvas.renderTo(target, done)
    return true
  }

  // Overlay point -> document pixels, clamped to the document. Mapped
  // through the shared geometry source, then inverse-rotated, so ink
  // always lands exactly under the cursor at any zoom, pan or rotation.
  function _toDoc(mx, my) {
    const vr = editor.viewRect
    if (editor._geom.w <= 0 || editor._geom.h <= 0) return { x: vr.x, y: vr.y }
    const rot = ((editor._rotAnim % 360) + 360) % 360
    return AnnotationTools.displayToDoc(mx, my, editor._geom, vr, rot)
  }

  // Document point -> overlay display coords (inverse of _toDoc).
  function _toDisplay(p) {
    const vr = editor.viewRect
    if (editor._geom.w <= 0 || editor._geom.h <= 0) return { x: editor._geom.x, y: editor._geom.y }
    const rot = ((editor._rotAnim % 360) + 360) % 360
    return AnnotationTools.docToDisplay(p, editor._geom, vr, rot)
  }

  // Display-space box of the staged text rect: axis-aligned bbox of
  // its mapped corners. Null without a staged rect (click-placed
  // mode). Single source for the inset field box below, so the box
  // and the outline can never disagree with each other.
  readonly property var _textFieldBox: {
    const t = editor.textRect
    if (t === null) return null
    const a = editor._toDisplay({ x: t.x, y: t.y })
    const b = editor._toDisplay({ x: t.x + t.w, y: t.y + t.h })
    return {
      x: Math.min(a.x, b.x),
      y: Math.min(a.y, b.y),
      w: Math.abs(b.x - a.x),
      h: Math.abs(b.y - a.y)
    }
  }

  // Display-px inset so caret and glyphs sit inside the staged box
  // with real margins instead of harsh border-to-border alignment.
  // Proportional with guards: calm on giant boxes, never eats small
  // ones whole. Any residual font-metric overflow lands in the margin,
  // never past the border.
  function _textPad(dispH) {
    return AnnotationTools.textPad(dispH)
  }

  // Inset field box derived from _textFieldBox: position, size and
  // fitted font (line == inner height) in one place, so preview and
  // commit below can never disagree. Null without a staged rect.
  readonly property var _textFieldInner: {
    const b = editor._textFieldBox
    if (b === null) return null
    const pd = editor._textPad(b.h)
    const w = Math.max(1, b.w - 2 * pd)
    const h = Math.max(1, b.h - 2 * pd)
    return { x: b.x + pd, y: b.y + pd, w: w, h: h, pad: pd, font: Math.max(1, h / 1.2) }
  }

  // Clamp a document point into the drawable area: the view rect, or the
  // applied crop frame when one is staged (drawing into the dimmed
  // cut-away zone must not be possible - the input clamps to the kept
  // area and the paint clips, so ink can never land outside the image).
  function _clampDoc(p) {
    return AnnotationTools.clampDocPoint(p, editor.viewRect, editor.cropFrame)
  }

  // Clamp into the view rect only, ignoring the frame. The crop tool
  // needs this: staging or resizing a frame must be able to reach the
  // image edges - and grow past the current frame - or re-cropping a
  // bigger area would be impossible.
  function _clampView(p) {
    return AnnotationTools.clampViewPoint(p, editor.viewRect)
  }

  function _clampDocPoints(points) {
    return points.map(p => editor._clampDoc(p))
  }

  function _hitTolerance() {
    return AnnotationTools.hitTolerance(editor._paintK)
  }

  function _commit(stroke) {
    // A blur region needs an area: a click, or a drag shorter than a few
    // pixels, would push a region that paints nothing anywhere.
    if (stroke.tool === "blur") {
      const pts = stroke.points || []
      const r = pts.length >= 2
        ? AnnotationTools.normRect(pts[0].x, pts[0].y, pts[pts.length - 1].x, pts[pts.length - 1].y)
        : null
      if (r === null || r.w < 4 || r.h < 4) return
      // Already blurred: the area is not blurred twice and no stroke is kept
      // for it, so a drag over a blind spot leaves the history untouched.
      if (editor._blurCoverage(r) >= 0.9) return
    }
    const kept = editor.strokes.slice(0, editor.redoIndex)
    kept.push(stroke)
    editor.strokes = kept
    editor.redoIndex = kept.length
    // The new element stays active after release, with no selection chrome:
    // the palette and the width control keep editing it until a new drag or a
    // tool switch takes the focus away. The outline is drawn for the Select
    // tool only, which is what makes this focus invisible.
    editor.selectedIndex = kept.length - 1
    board.requestPaint()
  }

   function undo() {
     if (editor.redoIndex > 0) {
       editor.redoIndex--
       if (editor.selectedIndex >= editor.redoIndex) editor.selectedIndex = -1
       board.requestPaint()
     }
   }

  // Crop lives outside strokes/redoIndex entirely, so undo() never saw
  // it. A pending or applied crop is the most recent thing the user
  // did - drop that first, same priority order Escape already uses,
  // then fall through to normal stroke undo.
  function undoOrDiscardCrop() {
    if (editor.cropRect !== null || editor.cropFrame !== null) {
      editor.cropRect = null
      editor.cropFrame = null
      board.requestPaint()
      return
    }
    editor.undo()
  }

   function redo() {
     if (editor.redoIndex < editor.strokes.length) {
       editor.redoIndex++
       if (editor.selectedIndex >= editor.strokes.length) editor.selectedIndex = -1
       board.requestPaint()
     }
   }

  function clearAll() {
    editor.strokes = []
    editor.redoIndex = 0
    editor.preview = null
    editor.cropRect = null
    editor.cropFrame = null
    editor.docRot = 0
    editor.textRect = null
    editor.textAnchor = null
    textField.text = ""
    editor.textRectW = 220
    editor.textPx = editor.fontSize * editor._fit * editor._zoomAnim
    editor.selectedIndex = -1
    editor.clearArmed = false
    board.requestPaint()
  }

  // The one place the editor becomes ready. Idempotent, and it repaints: a
  // Canvas never repaints on its own once its image arrives, so without the
  // repaint the board reveals an empty black sheet.
  function _markBoardReady() {
    if (editor.imgW <= 0 || editor.boardReady) return
    settleTimer.stop()
    editor.boardReady = true
    editor.loadState = "ready"
    // The plate can decode before the probe reports the size, which leaves its
    // grab waiting on this: same deferred call, same guard, one grab.
    blurPlateTimer.start()
    board.requestPaint()
  }

  function _textCommitPoint() {
    return editor._clampDoc(editor._toDoc(textField.x, textField.y))
  }

  function _finishText(commit) {
    if (editor.textAnchor === null) return
    if (commit === true && textField.text !== "") {
      const fs = AnnotationTools.commitFontSize(editor.textPx, editor._fit * editor._zoomAnim)
      editor._commit({
        tool: "text",
        color: editor.ink,
        width: editor.penWidth,
        points: [editor._textCommitPoint()],
        text: textField.text,
        fontSize: fs
      })
    }
    editor.textAnchor = null
    editor.textRect = null
    textField.text = ""
  }

  function _daemonNotify(summary, body, appName = "Screenshots") {
    Exec.notify(summary, body, { app: appName, replaceId: 3, timeoutMs: 3000 })
  }

  function _colorName(value) {
    const names = {
      "#ffffff": "white", "#000000": "black", "#ff5555": "red",
      "#50fa7b": "green", "#8be9fd": "cyan", "#f1fa8c": "yellow",
      "#bd93f9": "purple", "#ffb86c": "orange"
    }
    return names[value] || value
  }

  function _saveDialogType() {
    const filter = String(saveDialog.selectedNameFilter ?? "").toLowerCase()
    if (filter.indexOf("jpeg") >= 0 || filter.indexOf(".jpg") >= 0) return "jpeg"
    if (filter.indexOf("png") >= 0) return "png"
    return editor.fileType === "jpeg" ? "jpeg" : "png"
  }

  function _openSaveDialog() {
    if (saveDialog.opened) return
    const parts = editor.shotPath.split("/")
    const base = parts[parts.length - 1].replace(/\.[^.]+$/, "")
    const suggested = Paths.screenshotsDir + "/annotated-" + base + "."
      + ShotLib.suffixFor(editor.fileType)
     saveDialog.currentFile = Paths.toFileUrl(suggested)
     editor._saveTargetExisted = false
     editor._saveDialogOpen = true
     saveDialog.open()
  }

  function _isRuntimeOutput(path) {
    return SU.isUnder(String(path ?? ""), editor.runtimeDir)
  }

  function _cleanupExportOutput(path) {
    if (String(path ?? "") === "") return
    if (!editor._outputClipboardOwned
      && (editor._isRuntimeOutput(path) || editor._saveTargetExisted !== true)) {
      Exec.rm(String(path))
    }
  }

  function _cleanupPreservedOutput() {
    const output = editor._preservedOutput
    if (output === "") return
    if (String(Quickshell.clipboardText ?? "") === Paths.toFileUrl(output)) {
      editor._preservedOutput = ""
      return
    }
    editor._preservedOutput = ""
    editor._cleanupExportOutput(output)
  }

  function _cleanupFallbackTarget() {
    if (editor._fallbackTarget !== "") {
      if (!editor._fallbackCommitted) {
        Exec.rm(editor._fallbackTarget)
      }
      editor._fallbackTarget = ""
      editor._fallbackCommitted = false
    }
  }

  function _trackProcess(proc) {
    editor._childProcesses = editor._childProcesses.concat([proc])
  }

  function _untrackProcess(proc) {
    editor._childProcesses = editor._childProcesses.filter(p => p !== proc)
  }

  function _killProcess(proc) {
    if (proc === null || proc === undefined) return
    proc.signal(9)
    proc.destroy()
  }

  function _stopProcesses() {
    const processes = editor._childProcesses.slice()
    editor._childProcesses = []
    for (let i = 0; i < processes.length; i++) editor._killProcess(processes[i])
  }

  function _beginExport(kind, target) {
    if (editor.loadState !== "ready" || editor.interactionLocked) return false
     editor.exporting = true
     editor._exportSeq++
     editor._activeOutput = target
     editor._outputClipboardOwned = false
    exportSettle.kind = kind
    exportSettle.target = target
    exportSettle.seq = editor._exportSeq
    exportSettle.attempts = 0
    exportSettle.restart()
    return true
  }

  function _exportFailed(reason, preserveOutput) {
    const output = editor._activeOutput
    exportSettle.stop()
    editor._saveTargetPending = false
    editor.exporting = false
    editor._exportSeq++
    editor._activeOutput = ""
    editor._outputClipboardOwned = false
    if (preserveOutput === true && output !== "") editor._preservedOutput = output
    else editor._cleanupExportOutput(output)
    editor._daemonNotify("Screenshot", reason)
  }

  function _finishSavedOutput(output) {
    editor.exporting = false
    editor._saveTargetExisted = true
    const dir = SU.dirname(output)
    if (editor.showNotification) editor._daemonNotify("Screenshot Saved", "Saved to " + dir)
    Registry.call("screenshots", "noteSaved", editor._uid, output)
    editor._close()
    gc()
  }

  function _finishFileOffer(kind, output) {
    const oneShot = editor._isRuntimeOutput(output)
    const deleteAfter = kind === "copy" ? (output !== editor.shotPath || oneShot) : !editor.saveToDisk
    if (!deleteAfter && !oneShot) editor._outputClipboardOwned = true
    const onCopyFailed = () => {
      if (kind === "save" && editor.saveToDisk) {
        editor._finishSavedOutput(output)
        return
      }
      editor._exportFailed("Clipboard copy failed", true)
    }
    editor._copyImageFile(output, deleteAfter, () => {
      editor.exporting = false
      if (kind === "copy" || !editor.saveToDisk) {
        Registry.call("screenshots", "noteCancelled", editor._uid)
        if (editor.showNotification) editor._daemonNotify("Screenshot Copied", "Copied to clipboard")
        editor._close()
        gc()
        return
      }
      editor._finishSavedOutput(output)
    }, onCopyFailed)
  }

  function _performExport(kind, target, seq) {
    if (seq !== editor._exportSeq || !editor.exporting) return
    const cleanCopy = kind === "copy" && !editor.dirty
    const output = cleanCopy ? editor.shotPath : target
    if (cleanCopy) {
      editor._finishFileOffer(kind, output)
      return
    }
    if (!editor.exportTo(output, ok => {
      if (seq !== editor._exportSeq || !editor.exporting) return
      if (!ok) {
        editor._exportFailed("Export failed")
        return
      }
      editor._finishFileOffer(kind, output)
    })) editor._exportFailed("Export failed")
  }

  function _prepareExport() {
    editor._cleanupPreservedOutput()
    if (editor.preview !== null) return false
    editor._finishText(true)
    if (editor.cropRect !== null) editor._applyCrop()
    editor.selectedIndex = -1
    editor._lastSelectPress = null
    return true
  }

  function save() {
    if (editor.loadState !== "ready" || editor.interactionLocked) return
    if (!editor._prepareExport()) return
    if (editor.directSource) {
      editor._openSaveDialog()
      return
    }
    const target = editor.saveToDisk
      ? (editor.savePath !== "" ? editor.savePath : editor.shotPath)
      : editor._copyTempPath()
    editor._beginExport("save", target)
  }

  function copy() {
    if (editor.loadState !== "ready" || editor.interactionLocked) return
    if (!editor._prepareExport()) return
    const target = editor.dirty ? editor._copyTempPath() : ""
    editor._beginExport("copy", target)
  }

  Timer {
    id: exportSettle

    property string kind: ""
    property string target: ""
    property int seq: -1
    property int attempts: 0

    interval: 16
    repeat: true
    onTriggered: {
      if (!editor.exporting || seq !== editor._exportSeq) {
        exportSettle.stop()
        return
      }
      if (Math.abs(editor._rotAnim - editor.docRot) <= 0.1 || exportSettle.attempts >= 47) {
        exportSettle.stop()
        editor._performExport(exportSettle.kind, exportSettle.target, exportSettle.seq)
        return
      }
      exportSettle.attempts++
    }
  }

  Timer {
    id: exportPaintTimer

    interval: 5000
    onTriggered: exportCanvas.complete(false)
  }

  function _canonicalPath(path, done) {
    const proc = canonicalComp.createObject(editor, {
      command: Exec.setsidTimeoutCmd(["realpath", "-m", "--", path], 2)
    })
    if (proc === null) {
      done(false, "")
      return
    }
    editor._trackProcess(proc)
    const output = proc.stdout
    proc.exited.connect(code => {
      const canonical = String(output.text ?? "").trim()
      editor._untrackProcess(proc)
      proc.destroy()
      done(code === 0 && canonical.startsWith("/"), canonical)
    })
    proc.running = true
  }

  function _fileIdentity(path, allowMissing, done) {
    const proc = identityComp.createObject(editor, {
      command: Exec.setsidTimeoutCmd(["stat", "-Lc", "%d:%i", "--", path], 2)
    })
    if (proc === null) {
      done(false, "")
      return
    }
    editor._trackProcess(proc)
    const output = proc.stdout
    proc.exited.connect(code => {
      const identity = String(output.text ?? "").trim()
      editor._untrackProcess(proc)
      proc.destroy()
      if (code === 0 && identity !== "") {
        done(true, identity)
        return
      }
      done(allowMissing && code === 1, "")
    })
    proc.running = true
  }

  function _validateSaveTarget(path) {
    const seq = ++editor._saveCheckSeq
    let remaining = 2
    let targetPath = ""
    let sourcePath = ""
    let failed = false
    editor._saveTargetPending = true
    const checkIdentity = () => {
      if (seq !== editor._saveCheckSeq) return
      if (failed || targetPath === "" || sourcePath === "") {
        editor._saveTargetPending = false
        editor._exportFailed("Could not validate Save As target")
        return
      }
      if (targetPath === sourcePath) {
        editor._saveTargetPending = false
        editor._exportFailed("Choose a different Save As file")
        return
      }
      let identityRemaining = 2
      let targetIdentity = ""
      let sourceIdentity = ""
      const finishIdentity = () => {
        identityRemaining--
        if (identityRemaining > 0) return
        if (seq !== editor._saveCheckSeq) return
        editor._saveTargetPending = false
        editor._saveTargetExisted = targetIdentity !== ""
        if (failed || sourceIdentity === "") {
          editor._exportFailed("Could not validate Save As target")
          return
        }
        if (targetIdentity !== "" && targetIdentity === sourceIdentity) {
          editor._exportFailed("Choose a different Save As file")
          return
        }
        if (!editor._beginExport("save", path)) editor._exportFailed("Export failed")
      }
      editor._fileIdentity(path, true, (ok, value) => {
        if (!ok) failed = true
        else targetIdentity = value
        finishIdentity()
      })
      editor._fileIdentity(editor.shotPath, false, (ok, value) => {
        if (!ok) failed = true
        else sourceIdentity = value
        finishIdentity()
      })
    }
    const complete = () => {
      remaining--
      if (remaining > 0) return
      if (seq !== editor._saveCheckSeq) return
      checkIdentity()
    }
    editor._canonicalPath(path, (ok, value) => {
      failed = failed || !ok
      targetPath = value
      complete()
    })
    editor._canonicalPath(editor.shotPath, (ok, value) => {
      failed = failed || !ok
      sourcePath = value
      complete()
    })
  }

  FileDialog {
    id: saveDialog

    title: "Save annotated image"
    fileMode: FileDialog.SaveFile
     nameFilters: ["PNG image (*.png)", "JPEG image (*.jpg *.jpeg)"]
     currentFolder: Paths.toFileUrl(Paths.screenshotsDir)
     onAccepted: {
       editor._saveDialogOpen = false
        const path = ShotLib.ensureImageSuffix(
         ShotLib.pathFromFileUrl(selectedFile), editor._saveDialogType())
      if (!path.startsWith("/")) {
        editor._exportFailed("Save As requires an absolute path")
        return
      }
      editor._validateSaveTarget(path)
    }
     onRejected: {
       editor._saveDialogOpen = false
       editor._saveCheckSeq++
        editor._saveTargetPending = false
        editor._saveTargetExisted = false
     }
   }

  function _setClipboardFallback(path, deleteAfter, then, onFailed) {
    if (deleteAfter !== true) {
      Quickshell.clipboardText = Paths.toFileUrl(path)
      if (typeof then === "function") then()
      return
    }
    editor._copySeq++
    const mime = ShotLib.mimeForPath(path)
    const ext = mime === "image/jpeg" ? "jpg"
      : mime === "image/webp" ? "webp"
      : mime === "image/bmp" ? "bmp"
      : mime === "image/tiff" ? "tif"
      : mime === "image/svg+xml" ? "svg" : "png"
    const target = Paths.screenshotFallbackDir + "/image-" + editor._sessionId + "-"
      + editor._uid + "-" + editor._copySeq + "." + ext
    const proc = fallbackComp.createObject(editor, {
      command: Exec.setsidTimeoutCmd(["cp",
        "--remove-destination", "--", path, target], 10)
    })
    if (proc === null) {
      if (typeof onFailed === "function") onFailed()
      return
    }
    editor._trackProcess(proc)
    editor._fallbackTarget = target
    editor._fallbackCommitted = false
    proc.exited.connect((code) => {
      editor._untrackProcess(proc)
      proc.destroy()
      if (editor._closing) {
        if (editor._fallbackTarget === target) {
          editor._fallbackTarget = ""
          editor._fallbackCommitted = false
        }
        Exec.rm(target)
        return
      }
      if (code !== 0) {
        if (editor._fallbackTarget === target) {
          editor._fallbackTarget = ""
          editor._fallbackCommitted = false
        }
        Exec.rm(target)
        if (typeof onFailed === "function") onFailed()
        return
      }
      editor._fallbackCommitted = true
      editor._copyImageFile(target, false, () => {
        if (editor._fallbackTarget === target) {
          editor._fallbackTarget = ""
          editor._fallbackCommitted = false
        }
        Exec.rm(path)
        if (typeof then === "function") then()
      }, onFailed)
    })
    proc.running = true
  }

  function _copyImageFile(path, deleteAfter, then, onFailed) {
    if (deleteAfter === true) {
      editor._setClipboardFallback(path, deleteAfter, then, onFailed)
      return
    }
    const proc = copyComp.createObject(editor, {
      command: Exec.setsidTimeoutCmd(ShotLib.copyImageCmd(path), 10)
    })
    const done = () => {
      if (typeof then === "function") then()
    }
    if (proc === null) {
      editor._setClipboardFallback(path, deleteAfter, done, onFailed)
      return
    }
    editor._trackProcess(proc)
    proc.exited.connect((code) => {
      editor._untrackProcess(proc)
      proc.destroy()
      if (code === 0) {
        done()
      } else {
        editor._setClipboardFallback(path, deleteAfter, done, onFailed)
      }
    })
    proc.running = true
  }

  Component {
    id: copyComp

    Process {
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
  }

  Component {
    id: fallbackComp

    Process {
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
  }

  Component {
    id: canonicalComp

    Process {
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
  }

  Component {
    id: identityComp

    Process {
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
  }

  function _copyTempPath() {
    editor._copySeq++
     return editor.runtimeDir + "/copy-" + editor._sessionId + "-" + editor._uid + "-" + editor._copySeq + "."
       + ShotLib.suffixFor(editor.fileType)
  }

  function cancel() {
    if (editor.interactionLocked) return
    if (editor.dirty && !editor.discardArmed) {
      editor.discardArmed = true
      discardTimer.restart()
      return
    }
    Registry.call("screenshots", "noteCancelled", editor._uid)
    editor._close()
  }

   function _close() {
     if (editor._closing) return
     editor._closing = true
     const output = editor._activeOutput
     exportSettle.stop()
     exportPaintTimer.stop()
    editor._exportSeq++
    editor._saveCheckSeq++
    editor._saveTargetPending = false
    editor._saveDialogOpen = false
      editor.exporting = false
      editor._activeOutput = ""
      editor._stopProcesses()
      editor._cleanupExportOutput(output)
      editor._cleanupPreservedOutput()
     editor._cleanupFallbackTarget()
    board.unloadImage(editor.fileUrl)
    editor.visible = false
    editor.destroy()
  }

   Component.onDestruction: {
     editor._stopProcesses()
    editor._cleanupExportOutput(editor._activeOutput)
    editor._cleanupPreservedOutput()
    editor._cleanupFallbackTarget()
    editor._cleanupBlurPlate()
  }

  Timer {
    id: discardTimer

    interval: 3000
    onTriggered: editor.discardArmed = false
  }

  Timer {
    id: clearTimer

    interval: 3000
    onTriggered: editor.clearArmed = false
  }

  Item {
    id: stage

    enabled: !editor.interactionLocked
    x: 0
    y: 0
    width: editor.width
    height: editor.height

    Text {
      anchors.centerIn: parent
      visible: editor.loadState === "loading"
      text: "Loading..."
      font.pixelSize: Ui.fontM
      font.family: Ui.fontFamily
      color: Ui.solid("foreground_0")
    }

    Text {
      id: loadError

      anchors.centerIn: parent
      visible: editor.loadState === "error"
      text: "Image could not be loaded. Cancel to close."
      font.pixelSize: Ui.fontM
      font.family: Ui.fontFamily
      color: Ui.solid("foreground_0")
    }

    ToolBtn {
      visible: editor.loadState === "error"
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: loadError.bottom
      anchors.topMargin: Ui.m
      iconName: "xmark"
      iconColor: "red"
      tip: "Cancel (Esc)"
      onActivated: editor.cancel()
    }

      // Hidden probe: reports the file's true pixel size. Cached on
      // purpose (default): the board draws the same URL and reads it back
      // out of the shared image cache. cache:false starves canvas
      // drawImage silently - verified painfully.
      Image {
        id: probe

        visible: false
        source: editor.fileUrl

      onStatusChanged: {
        if (status === Image.Error) {
          settleTimer.stop()
          editor.boardReady = false
          editor.loadState = "error"
          board.unloadImage(editor.fileUrl)
          return
        }
        if (status !== Image.Ready) return
         // implicitWidth and sourceSize agree here, and both are the file's
         // PIXELS: measured on a 2304x1296 JPEG, Qt reports 2304 for each
         // (a raster source gets no DPR correction). Checked because a
         // DPR-corrected reading would silently crop every drawImage source
         // rect - which is what an earlier theory of this bug assumed.
         editor.imgW = Math.round(implicitWidth)
         editor.imgH = Math.round(implicitHeight)
         editor.viewRect = { x: 0, y: 0, w: editor.imgW, h: editor.imgH }
         // State before the load, not after: a canvas whose image is already
         // cached can report it as loaded from inside loadImage(), and a
         // readiness handler that ran then would be looking at the previous
         // capture's state.
         editor.boardReady = false
         editor.loadState = "loading"
         board.loadImage(editor.fileUrl)
         // Restart the bound before promoting, not after. _markBoardReady
         // stops it, and restarting it on the next line left it ticking every
         // 50ms for six seconds after the editor was already up. With the
         // size gate in _markBoardReady this timer is also the only path to
         // readiness while the window is still unconfigured, so it has to be
         // the one that stops.
         settleTimer.attempts = 0
         settleTimer.restart()
         // Readiness is this check, not a signal and not a poll. The board
         // shares the probe's image cache (deliberately, see above), so
         // loadImage() completes against a cache hit and isImageLoaded()
         // already reads true right here. Canvas.imageLoaded does not
         // fire for loadImage() on this Qt - measured, cold and cached - so
         // a handler on it waits forever, and the 50ms poll it replaced
         // could only ever be later. The poll stays below as the failure
         // bound, and it promotes too, for a window not yet configured or a
         // frame big enough that the decode is still running.
         if (board.isImageLoaded(editor.fileUrl)) {
           editor._markBoardReady()
         } else {
           board.requestPaint()
         }
         // No bake here. The bake composites the image plus the strokes, and
         // on open there are no strokes: the board paints the frame straight
         // from the file until the first one lands (see the useBaked branch
         // in onPaint). Baking anyway filled a full-resolution canvas before
         // the editor had even revealed, which on a 4K frame is tens of
         // milliseconds of main-thread work between the keypress and the
         // window appearing - for a bitmap identical to the file on disk.
         // The first stroke change requests it.
      }
    }

    // The failure bound, and a fallback promotion for a frame big enough
    // that its decode is still running when loadImage() returns. In the
    // common case this timer never promotes anything: readiness is settled
    // synchronously in the probe's onStatusChanged.
    Timer {
      id: settleTimer

      property int attempts: 0

      interval: 50
      repeat: true
      onTriggered: {
        if (board.isImageLoaded(editor.fileUrl)) {
          editor._markBoardReady()
          return
        }
        board.requestPaint()
        settleTimer.attempts++
        if (settleTimer.attempts >= 120) {
          editor.boardReady = false
          editor.loadState = "error"
          settleTimer.stop()
        }
      }
    }

    // Drop shadow under the board: hidden source rect, MultiEffect
    // shadow item above it. Separates the shot from the flat background
    // without any border chrome.
    Rectangle {
      id: boardShadow

      x: board.x
      y: board.y
      width: board.width * board.scale
      height: board.height * board.scale
      visible: false
      color: "#000000"
    }

    MultiEffect {
      x: board.x
      y: board.y
      width: board.width * board.scale
      height: board.height * board.scale
      visible: editor.imgW > 0
      source: boardShadow
      shadowEnabled: true
      // Soft halo only: scaling the shadow shape (shadowScale) enlarges
      // its hard source edge faster than the blur softens it, which
      // reads as a thick black outline instead of a shadow. Max blur
      // at source size is the wide soft cast.
      shadowBlur: 1.0
      shadowColor: "#a0000000"
    }

    // The picture, placed by ordinary item geometry. Painting it into the
    // board canvas would make its on-screen size depend on the canvas backing
    // lining up with the item's rect under a fractional
    // device ratio - a Canvas backing is presented 1:1 in device pixels,
    // and when that ratio is not the one the backing was sized with, the
    // picture is either short of the item (black bars down the right and
    // bottom) or past it (enlarged, running off the edges). An Image has no
    // backing and no second transform: it fills exactly the rect below.
    // Outer box carries the zoom about the top-left, exactly as the canvas
    // does; the image inside carries the rotation about the centre, which is
    // the pivot the canvas rotates its paint around. transformOrigin is one
    // value per item, so the two transforms need two items.
    Item {
      id: boardImageBox

      x: editor._geom.x + (editor._geom.w - width * editor._boardScale) / 2
      y: editor._geom.y + (editor._geom.h - height * editor._boardScale) / 2
      width: Math.max(1, Math.round(editor._boardGeom.w))
      height: Math.max(1, Math.round(editor._boardGeom.h))
      scale: editor._boardScale
      transformOrigin: Item.TopLeft

      Image {
        id: boardImage

        // The box around this item is the ROTATED bounding box of the
        // document, so filling it would scale the picture to the swapped
        // aspect first and then rotate that distortion - a quarter turn left
        // a 16:9 shot squeezed towards 9:16 on an unchanged wide footprint.
        // The picture keeps its own unrotated size, centred in the box, and
        // the rotation alone produces the box's footprint: at any angle the
        // rotated size is exactly the box (docW/docH are that same bounding
        // box), and the ink canvas paints through the identical mapping.
        width: Math.max(1, Math.round(editor._pictureSize.w))
        height: Math.max(1, Math.round(editor._pictureSize.h))
        anchors.centerIn: parent
        rotation: editor._rotAnim
        transformOrigin: Item.Center
        visible: editor.imgW > 0 && status === Image.Ready
        fillMode: Image.Stretch
        // Smooth, or the 0.833 downscale to the fitted size samples
        // nearest-neighbour and the shot comes out visibly blocky.
        smooth: true
        source: editor.fileUrl
        asynchronous: false
        cache: true
      }

      // The blur plate: the picture decoded at plate size, blurred by an effect
      // item, and grabbed once into the PNG that both the overlay and the
      // export draw from. The effect is its own item rather than layer.effect
      // on purpose - a grab of a layered item comes back with the unblurred
      // source (measured), while an effect item's own rendering is the blurred
      // result, and that still holds while the picture covers it.
      //
      // It is hidden again the moment the grab lands, so the blur shader is not
      // paid for on every frame the editor redraws while it is open.
      // One deferred pass owns the export plate: it runs when the picture or
      // the plate size lands, and retries a bounded number of times while the
      // source is still decoding at the old size.
      Timer {
        id: blurPlateTimer

        interval: 150
        repeat: false
        onTriggered: editor._grabBlurPlate()
      }

      Item {
        id: blurPlateBox

        anchors.fill: parent
        z: -1
        clip: true

        Image {
          id: blurSource

          width: editor._blurPlateW
          height: editor._blurPlateH
          source: editor.fileUrl
          sourceSize.width: editor._blurPlateW
          sourceSize.height: editor._blurPlateH
          fillMode: Image.Stretch
          smooth: true
          visible: false

          // Grabbing straight from status is a frame early: the effect has not
          // rendered yet, so the grab would be blank.
          onStatusChanged: if (status === Image.Ready) blurPlateTimer.start()
        }

        MultiEffect {
          id: blurPlate

          width: editor._blurPlateW
          height: editor._blurPlateH
          visible: editor.imgW > 0 && !editor._blurPlateDone
          source: blurSource
          blurEnabled: true
          blurMax: 96
          blur: 1.0
        }
      }
    }

    // Blur regions: the picture blurred inside each committed rectangle, sitting
    // above the picture and below the ink. Ordering between blur and the other
    // tools is deliberately not modelled - blur is a picture treatment here, so
    // every annotation stays legible above it.
    Item {
      id: blurLayer

      x: board.x
      y: board.y
      width: board.width
      height: board.height
      scale: board.scale
      transformOrigin: Item.TopLeft
      visible: editor.imgW > 0
      clip: true

      // Document pixels -> canvas backing pixels, rotation about the document
      // centre, then the view offset: the chain the board paints with.
      Item {
        scale: editor._boardPaintK
        transformOrigin: Item.TopLeft

        Item {
          width: editor._docW
          height: editor._docH
          rotation: editor._rotAnim
          transformOrigin: Item.Center

          Item {
            x: editor._docW / 2 - (editor.viewRect.x + editor.viewRect.w / 2)
            y: editor._docH / 2 - (editor.viewRect.y + editor.viewRect.h / 2)

            Repeater {
              model: editor.blurRects

              delegate: Item {
                id: blurRegion

                required property var modelData

                // The blur pulls pixels in from beyond the region, so it reads a
                // window grown by twice the radius and the clip keeps that margin
                // outside the rectangle: taps that run off the texture edge
                // sample transparency, and at a corner the shortfall is diagonal,
                // which reads as rounded corners.
                readonly property real pad: editor._blurRadius * 2
                readonly property real srcX: Math.max(0, modelData.x - pad)
                readonly property real srcY: Math.max(0, modelData.y - pad)
                readonly property real srcW: Math.max(1,
                  Math.min(editor.imgW, modelData.x + modelData.w + pad) - srcX)
                readonly property real srcH: Math.max(1,
                  Math.min(editor.imgH, modelData.y + modelData.h + pad) - srcY)

                x: modelData.x
                y: modelData.y
                width: modelData.w
                height: modelData.h
                clip: true

                Image {
                  id: regionSource

                  x: blurRegion.srcX - modelData.x
                  y: blurRegion.srcY - modelData.y
                  width: blurRegion.srcW
                  height: blurRegion.srcH
                  source: editor.fileUrl
                  sourceClipRect: Qt.rect(blurRegion.srcX, blurRegion.srcY,
                    blurRegion.srcW, blurRegion.srcH)
                  fillMode: Image.Stretch
                  smooth: true
                  visible: false
                }

                MultiEffect {
                  x: blurRegion.srcX - modelData.x
                  y: blurRegion.srcY - modelData.y
                  width: blurRegion.srcW
                  height: blurRegion.srcH
                  source: regionSource
                  blurEnabled: true
                  blurMax: editor._blurRadius
                  blur: 1.0
                }
              }
            }

            // The live drag, newest of all.
            Item {
              id: previewBlur

              readonly property var rect: editor.previewBlurRect
              readonly property bool on: rect !== null
              readonly property real pad: editor._blurRadius * 2
              readonly property real srcX: Math.max(0, (on ? rect.x : 0) - pad)
              readonly property real srcY: Math.max(0, (on ? rect.y : 0) - pad)
              readonly property real srcW: Math.max(1,
                Math.min(editor.imgW, (on ? rect.x + rect.w : 0) + pad) - srcX)
              readonly property real srcH: Math.max(1,
                Math.min(editor.imgH, (on ? rect.y + rect.h : 0) + pad) - srcY)

              visible: on
              x: on ? rect.x : 0
              y: on ? rect.y : 0
              width: on ? rect.w : 1
              height: on ? rect.h : 1
              clip: true

              Image {
                id: previewSource

                x: previewBlur.srcX - (previewBlur.on ? previewBlur.rect.x : 0)
                y: previewBlur.srcY - (previewBlur.on ? previewBlur.rect.y : 0)
                width: previewBlur.srcW
                height: previewBlur.srcH
                source: editor.fileUrl
                sourceClipRect: Qt.rect(previewBlur.srcX, previewBlur.srcY,
                  previewBlur.srcW, previewBlur.srcH)
                fillMode: Image.Stretch
                smooth: true
                visible: false
              }

              MultiEffect {
                x: previewBlur.srcX - (previewBlur.on ? previewBlur.rect.x : 0)
                y: previewBlur.srcY - (previewBlur.on ? previewBlur.rect.y : 0)
                width: previewBlur.srcW
                height: previewBlur.srcH
                source: previewSource
                blurEnabled: true
                blurMax: editor._blurRadius
                blur: 1.0
              }
            }
          }
        }
      }
    }

    Canvas {
      id: board

      x: editor._geom.x + (editor._geom.w - width * editor._boardScale) / 2
      y: editor._geom.y + (editor._geom.h - height * editor._boardScale) / 2
      width: Math.max(1, Math.round(editor._boardGeom.w))
      height: Math.max(1, Math.round(editor._boardGeom.h))
      scale: editor._boardScale
      transformOrigin: Item.TopLeft
      visible: editor.imgW > 0
      contextType: "2d"
      renderStrategy: Canvas.Immediate
      // Backing equals the item, and _boardPaintK maps document pixels onto
      // backing pixels 1:1. The scene presents a backing 1:1 in LOGICAL
      // pixels over the item's rect, so the backing is the item's own size
      // and carries no device ratio at all - which is what puts the ink on
      // the same pixels as boardImage, and the ink on the pixel the cursor is
      // over. Scaling either by the ratio draws the strokes 1.2x too large,
      // anchored at the item's top-left, so they land down and to the right
      // of the cursor.
      //
      // The picture is deliberately NOT painted here: it is boardImage, an
      // Image laid out by ordinary geometry, so its placement never depends
      // on a backing at all.
      //
      // Pinned explicitly rather than left to the default: the box resizes
      // with the zoom, and a trailing canvasSize addresses a stale backing.
      canvasSize: Qt.size(Math.max(1, Math.round(width)),
        Math.max(1, Math.round(height)))

      // A fresh overlay window configures fullscreen asynchronously:
      // the probe/load/paint sequence above can run while the stage
      // is still a pre-configure placeholder (logged as tiny canvas
      // sizes), and nothing else reliably repaints once the real size
      // lands. Repaint explicitly on every resize, and re-run the
      // settle polling while the file is still decoding.
      onWidthChanged: board._resized()
      onHeightChanged: board._resized()

      function _resized() {
        board.requestPaint()
        // Trailing paint after geometry settles: the trace proves the
        // canvas backing trails item size by a beat at every step, so a
        // paint requested with the resize can address a stale backing
        // (tiny upscaled mush, or a top-left fraction with black
        // bands). This fires once the storm passes, when canvasSize,
        // backing and transform all read settled.
        paintCooldown.restart()
        if (!board.isImageLoaded(editor.fileUrl)) {
          settleTimer.attempts = 0
          settleTimer.restart()
        }
      }

      Timer {
        id: paintCooldown

        interval: 80
        repeat: false
        onTriggered: {
          board.requestPaint()
        }
      }

      onPaint: {
        if (!editor.boardReady || editor.imgW <= 0) return
         const ctx = board.getContext("2d")
         if (ctx === null) return
         const vr = editor.viewRect
         ctx.save()
         ctx.setTransform(1, 0, 0, 1, 0, 0)
         ctx.clearRect(0, 0, board.canvasSize.width, board.canvasSize.height)
         // _boardPaintK maps document pixels onto backing pixels 1:1 (see
         // canvasSize), over the item's own rect, so a document point lands
         // on the same screen pixel the cursor is over.
          ctx.setTransform(editor._boardPaintK, 0, 0,
            editor._boardPaintK, 0, 0)
        // The document backing rotates continuously with _rotAnim;
        // strokes stay in original coordinates and ride the transform
        // (keeps hit tests, crops and grids free of remapping math).
        // Always applied - rotate(0) is the identity, so this needs no
        // special case at rest.
        ctx.translate(editor._docW / 2, editor._docH / 2)
        ctx.rotate(editor._rotAnim * Math.PI / 180)
        ctx.translate(-vr.w / 2, -vr.h / 2)
        // Ink only. The picture is boardImage, underneath, unclipped by
        // design: the cut-away zone must keep showing it under the dim veil
        // (clipping the base left only the dark window background there -
        // the "pure black" letterbox the veil then made look intentional
        // but unreadable).
        //
        // Strokes and the live preview ARE clipped: ink must never render
        // past the frame edge, whatever got recorded into it.
        // (save/restore so the chrome below starts from the plain K
        // transform and re-establishes its own wrapper.)
        ctx.save()
        if (editor.cropFrame !== null) {
          const f = editor.cropFrame
          ctx.beginPath()
          ctx.rect(f.x - vr.x, f.y - vr.y, f.w, f.h)
          ctx.clip()
        }
        // Every committed stroke in one pass, then the live preview. Blur
        // regions are the overlay below this canvas, so ink is never buried.
        for (let i = 0; i < editor.redoIndex && i < editor.strokes.length; i++) {
          editor._paintStroke(ctx, editor.strokes[i], undefined, undefined, 1)
        }
        if (editor.preview !== null)
          editor._paintStroke(ctx, editor.preview, undefined, undefined, 1)
        ctx.restore()
        ctx.restore()
        // ---- above this line: strokes (clipped), over boardImage
        // ---- below this line: chrome, never clipped by the frame
        ctx.save()
        ctx.setTransform(editor._boardPaintK, 0, 0,
            editor._boardPaintK, 0, 0)
        ctx.translate(editor._docW / 2, editor._docH / 2)
        ctx.rotate(editor._rotAnim * Math.PI / 180)
        ctx.translate(-vr.w / 2, -vr.h / 2)
        if (editor.tool === "select"
          && editor.selectedIndex >= 0 && editor.selectedIndex < editor.redoIndex
          && editor.selectedIndex < editor.strokes.length) {
          const b = editor._strokeBounds(editor.strokes[editor.selectedIndex])
          if (b !== null) {
            ctx.strokeStyle = Ui.solid("accent")
            ctx.lineWidth = Math.max(1, Math.round(editor._bufPerPx))
            if (typeof ctx.setLineDash === "function") ctx.setLineDash([6, 4])
            ctx.strokeRect(b.x - vr.x, b.y - vr.y, b.w, b.h)
            // Chrome below shares this state: drop the dash again or the
            // crop/text outlines come out dashed too.
            if (typeof ctx.setLineDash === "function") ctx.setLineDash([])
          }
        }
        if (editor.cropRect !== null) {
          const c = editor.cropRect
          ctx.strokeStyle = Ui.solid("accent")
          ctx.lineWidth = Math.max(1, Math.round(editor._bufPerPx))
          ctx.strokeRect(c.x - vr.x, c.y - vr.y, c.w, c.h)
        }
         if (editor._cropDimRect !== null) {
           // Staged and applied crop rectangles dim the cut-away sides.
           // The outline for a staged rect is drawn above; an applied
           // frame also gets its persistent outline here.
           const f = editor._cropDimRect
           const fx = f.x - vr.x
           const fy = f.y - vr.y
           ctx.fillStyle = "rgba(0, 0, 0, " + (0.55 * editor.cropDimOpacity) + ")"
           ctx.fillRect(0, 0, fx, vr.h)
           ctx.fillRect(fx + f.w, 0, vr.x + vr.w - (f.x + f.w), vr.h)
           ctx.fillRect(fx, 0, f.w, fy)
           ctx.fillRect(fx, fy + f.h, f.w, vr.y + vr.h - (f.y + f.h))
         }
         if (editor.cropFrame !== null) {
           const f = editor.cropFrame
           ctx.strokeStyle = Ui.solid("accent")
           ctx.lineWidth = Math.max(1, Math.round(editor._bufPerPx))
           ctx.strokeRect(f.x - vr.x, f.y - vr.y, f.w, f.h)
         }
        // Staged text rect: initial-selection feedback only. Once the
        // field holds input the rect hides - it sized and placed the
        // field, and keeping it would double-frame the text.
        if (editor.textRect !== null && textField.text === "") {
          const t = editor.textRect
          ctx.strokeStyle = Ui.solid("accent")
          ctx.lineWidth = Math.max(1, Math.round(editor._bufPerPx))
          if (typeof ctx.setLineDash === "function") ctx.setLineDash([6, 4])
          ctx.strokeRect(t.x - vr.x, t.y - vr.y, t.w, t.h)
        }
        ctx.restore()
       }
     }

    Canvas {
      id: exportCanvas

       property string pendingPath: ""
       property var pendingDone: null
       property bool saving: false

      x: 0
      y: 0
       width: 1
       height: 1
       visible: true
       opacity: 0
       contextType: "2d"
      renderStrategy: Canvas.Immediate

         function renderTo(path, done) {
          const vr = editor._exportViewRect()
          const size = editor._exportSize(vr)
          if (!Number.isFinite(size.w) || !Number.isFinite(size.h)
            || size.w < 1 || size.h < 1) {
            if (typeof done === "function") done(false)
            return
          }
          const width = Math.max(1, Math.round(size.w))
          const height = Math.max(1, Math.round(size.h))
           exportCanvas.pendingPath = String(path ?? "")
           exportCanvas.pendingDone = done
           // A blur region can only be drawn from the plate. While its grab is
           // still in flight the export waits for it instead of writing a shot
           // with the blur missing; the 5s exportPaintTimer still fails the
           // save if the grab never lands.
           if (editor._blurPlatePending && editor.blurRects.length > 0) {
             exportPaintTimer.restart()
             return
           }
           if (editor.blurPlateUrl !== "") {
             try { exportCanvas.loadImage(editor.blurPlateUrl) } catch (e) {}
           }
           exportCanvas.width = width
           exportCanvas.height = height
           exportCanvas.canvasSize = Qt.size(width, height)
          if (!exportCanvas.isImageLoaded(editor.fileUrl)) {
            exportCanvas.loadImage(editor.fileUrl)
            exportPaintTimer.restart()
            if (exportCanvas.isImageLoaded(editor.fileUrl)) exportCanvas.requestPaint()
            return
          }
          exportCanvas.requestPaint()
          exportPaintTimer.restart()
        }

       onImageLoaded: {
         if (exportCanvas.pendingPath !== "") {
           exportCanvas.requestPaint()
           exportPaintTimer.restart()
         }
       }

       function complete(ok) {
         if (exportCanvas.pendingPath === "") return
         const done = exportCanvas.pendingDone
         exportCanvas.pendingPath = ""
         exportCanvas.pendingDone = null
         exportCanvas.saving = false
         exportPaintTimer.stop()
         if (typeof done === "function") done(ok)
       }

         onPaint: {
           if (exportCanvas.pendingPath === "") return
           if (exportCanvas.saving) return
         if (!editor.boardReady || editor.imgW <= 0 || probe.status !== Image.Ready) {
           exportCanvas.complete(false)
           return
         }
         if (!exportCanvas.isImageLoaded(editor.fileUrl)) return
         const ctx = exportCanvas.getContext("2d")
         if (ctx === null) {
           exportCanvas.complete(false)
           return
         }
        const vr = editor._exportViewRect()
        const size = editor._exportSize(vr)
        ctx.setTransform(1, 0, 0, 1, 0, 0)
        ctx.clearRect(0, 0, size.w, size.h)
        ctx.save()
        ctx.translate(size.w / 2, size.h / 2)
        ctx.rotate(editor.docRot * Math.PI / 180)
        ctx.translate(-vr.w / 2, -vr.h / 2)
         ctx.drawImage(editor.fileUrl, vr.x, vr.y, vr.w, vr.h, 0, 0, vr.w, vr.h)
        ctx.save()
        ctx.beginPath()
        ctx.rect(0, 0, vr.w, vr.h)
        ctx.clip()
        for (let i = 0; i < editor.redoIndex && i < editor.strokes.length; i++) {
          const s = editor.strokes[i]
          if (s.tool === "blur") editor._drawBlurRegion(ctx, s, -vr.x, -vr.y)
          else editor._paintStroke(ctx, s, -vr.x, -vr.y)
        }
         ctx.restore()
         ctx.restore()
         const target = exportCanvas.pendingPath
         exportCanvas.saving = true
         const finish = ok => exportCanvas.complete(ok)
          const direct = exportCanvas.save(target, Qt.size(size.w, size.h))
         if (direct === true) {
           finish(true)
           return
         }
          // grabToImage writes targetSize * this window's ratio - the same
          // multiplication ShotLib.grabResultSize documents, and the same one
          // the screenshots service divides out through grabTargetSize.
          // Asking for the document size verbatim did not: a 1920x1080 shot
          // was written as 2304x1296 with the image in the top-left of a
          // larger canvas, which is what made an exported shot look enlarged
          // and refuse to fit. Dividing the target by the ratio makes the
          // grab land on the canvas's own backing exactly - a backing is
          // presented 1:1 in device pixels - so pixels are copied, not
          // resampled.
          //
          // The ratio is this window's own devicePixelRatio. A window that
          // has not reported one reads 0, which means "not mapped yet" and
          // falls to 1 - never to Screen.devicePixelRatio, which is a
          // different screen's number and is stable for as long as mapping
          // takes, so a scale settled against it would be the wrong scale.
          const ratio = editor.devicePixelRatio > 0 ? editor.devicePixelRatio : 1
          const grabbed = exportCanvas.grabToImage(result => {
            const ok = result !== null && result !== undefined
              && typeof result.saveToFile === "function"
              && result.saveToFile(target) !== false
            finish(ok)
          }, Qt.size(Math.max(1, Math.round(size.w / ratio)),
            Math.max(1, Math.round(size.h / ratio))))
         if (!grabbed) finish(false)
      }
    }

    // Inline text editor: a chromeless TextInput inset inside the
    // staged rectangle with real margins, fitted font, native caret.
    // Dragged-rect mode sizes and places the field off the same
    // display box as the dashed outline, then grows with the content
    // (a fixed width would scroll long text sideways and disagree
    // with the commit). Click-placed mode floats at the point and
    // grows as you type. Enter commits, escaping drops.
    TextInput {
      id: textField

      z: 1
      visible: editor.textAnchor !== null
      width: editor._textFieldInner !== null
        ? Math.max(8, Math.round(Math.max(editor._textFieldInner.w, textField.contentWidth + 24)))
        : editor.textRectW > 0 ? editor.textRectW : 220
      height: editor._textFieldInner !== null
        ? Math.max(8, Math.round(editor._textFieldInner.h))
        : implicitHeight
      font.pixelSize: Math.max(1, Math.round(editor.textPx))
      font.family: Ui.fontFamily
      color: editor.ink
      // Explicit top-left: the line must start inside the box, never
      // centered or bottom-pinned out of it.
      horizontalAlignment: TextInput.AlignLeft
      verticalAlignment: TextInput.AlignTop
      selectionColor: Ui.solid("accent")
      selectedTextColor: Ui.solid("background_0")
       cursorVisible: true
       Accessible.role: Accessible.EditableText
       Accessible.name: "Annotation text"
       // Click-placed mode only: the box grows with the text so content
      // always fits inside it (writes through textRectW to keep the
      // width binding intact). A dragged rect owns an exact box and
      // must not fight it.
      onTextChanged: {
        if (editor.textRect === null) {
          editor.textRectW = Math.max(140, Math.min(stage.width - x - Ui.m, contentWidth + 24))
        }
        // The staged outline shows only before the first input -
        // typing alone never repaints the board, so kick it here.
        board.requestPaint()
      }
      x: editor.textAnchor !== null
        ? Math.max(0, Math.min(stage.width - width,
          editor._textFieldInner !== null ? editor._textFieldInner.x : editor._toDisplay(editor.textAnchor).x)) : 0
      y: editor.textAnchor !== null
        ? Math.max(0, Math.min(stage.height - height,
          editor._textFieldInner !== null ? editor._textFieldInner.y : editor._toDisplay(editor.textAnchor).y)) : 0
      onAccepted: editor._finishText(true)
      onVisibleChanged: {
        if (visible) forceActiveFocus()
      }
    }

      MouseArea {
        id: drawArea

        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        hoverEnabled: true
        cursorShape: drawArea.dragCursor >= 0 ? drawArea.dragCursor
          : drawArea.hoverHandleCursor >= 0 ? drawArea.hoverHandleCursor
          : (editor.tool === "crop" && drawArea.hoverInCrop) ? Qt.PointingHandCursor
          : (editor.tool === "select" && editor.cropFrame !== null
            && drawArea.hoverInFrame) ? Qt.SizeAllCursor : Qt.CrossCursor
        enabled: editor.loadState === "ready"

        // Resize cursor override while a drag owns the pointer, and the
        // handle under the pointer while hovering. Qt cursor values, or
        // -1 for the tool default below.
        property int dragCursor: -1
        property int hoverHandleCursor: -1

        // Hover-only frame check for the cursor above - cheap, recomputed
        // on every move, no drag state involved.
        property bool hoverInFrame: false

        property var anchor: null
        property var moveBase: null
        property bool resizeMode: false
        property var resizeFixed: null
        property var resizeOrig: null
        property var resizeBase: null
        // Grabbed handle index in handleSpots order (-1 = none).
        // Even indexes are corners (uniform scale), odd are edge
        // midpoints (single-axis stretch).
        property int resizeHandle: -1
        property var panFrom: null
        property var panBase: null
        // Fixed frame bounds at the start of a frame resize drag
        // ({x0,y0,x1,y1}, document pixels); the grabbed handle's own
        // axes follow the pointer, the rest stay put.
        property var cropGrab: null
        // Grabbed frame handle index in handleSpots order (-1 = none).
        property int cropHandle: -1
        // True while the resize drag writes the applied frame (false:
        // it writes the staged rect).
        property bool cropResizeFrame: false
        // Whole-area crop drag ({frame, ox, oy}: which area plus its
        // origin at press time), null when not dragging.
        property var cropDrag: null
        // Pointer hovers the selected crop area (crop tool only).
        property bool hoverInCrop: false
        // Frame origin at press time, for a select-tool body drag.
        property var cropMoveBase: null


      // Display-space handles of the current selection, in
      // handleSpots order (corners + edge midpoints), for the visuals
      // and the resize hit test.
      function _selectCorners() {
        const dc = editor._selectDocHandles()
        if (dc === null) return null
        return dc.map(p => editor._toDisplay(p))
      }

      // Display-space handles of any document rect, in handleSpots
      // order (corners + edge midpoints). Null when there is no rect.
      function _handlesOf(r) {
        if (r === undefined || r === null) return null
        return [
          { x: r.x, y: r.y },
          { x: r.x + r.w / 2, y: r.y },
          { x: r.x + r.w, y: r.y },
          { x: r.x + r.w, y: r.y + r.h / 2 },
          { x: r.x + r.w, y: r.y + r.h },
          { x: r.x + r.w / 2, y: r.y + r.h },
          { x: r.x, y: r.y + r.h },
          { x: r.x, y: r.y + r.h / 2 }
        ].map(q => editor._toDisplay(q))
      }

      // Display-space handles of the applied crop frame, same order.
      function _cropCorners() {
        if (editor.cropFrame === null) return null
        return drawArea._handlesOf(editor.cropFrame)
      }

      // Display-space handles of the staged crop rect, same order.
      function _cropRectCorners() {
        if (editor.cropRect === null) return null
        return drawArea._handlesOf(editor.cropRect)
      }

      // Resize cursor for the handle under the pointer, or -1. Mirrors
      // the handle visuals exactly: select bounds first, then whichever
      // crop area owns the grabs.
      function _hoverHandleCursor(mx, my) {
        if (editor.tool === "select" && editor.selectedIndex >= 0) {
          const cs = drawArea._selectCorners()
          if (cs !== null) {
            for (let i = 0; i < 8; i++) {
              if (Math.abs(mx - cs[i].x) + Math.abs(my - cs[i].y) < 14) return editor.handleSpots[i].cur
            }
          }
          return -1
        }
        if (editor.tool === "crop") {
          const t = editor.cropFrame !== null ? editor.cropFrame : editor.cropRect
          if (t !== null && t.w > 1 && t.h > 1) {
            const hs = drawArea._handlesOf(t)
            for (let i = 0; i < 8; i++) {
              if (Math.abs(mx - hs[i].x) + Math.abs(my - hs[i].y) < 14) return editor.handleSpots[i].cur
            }
          }
        }
        return -1
      }

      function _inside(mp) {
        // Hit test in stage space against the shared geometry source.
        // (board.mapToItem here inverted the mapping direction, adding
        // the board origin twice: presses inside small/offset boards
        // were dropped while margin presses slipped through.)
        const g = editor._geom
        return mp.x >= g.x && mp.x <= g.x + g.w && mp.y >= g.y && mp.y <= g.y + g.h
      }

      onPressed: mouse => {
        if (mouse.button === Qt.MiddleButton) {
          drawArea.panFrom = { x: mouse.x, y: mouse.y }
          drawArea.panBase = { x: editor.viewPan.x, y: editor.viewPan.y }
          drawArea.dragCursor = Qt.SizeAllCursor
          return
        }
        if (mouse.button === Qt.RightButton) {
           const hadTransient = editor.preview !== null || editor.cropRect !== null
             || editor.cropFrame !== null || editor.textRect !== null
             || editor.textAnchor !== null || editor.selectedIndex >= 0
     editor.preview = null
    editor.cropRect = null
    editor.cropFrame = null
    editor.textRect = null
          editor.textAnchor = null
          editor.selectedIndex = -1
          // Clean right-click closes straight away (armed discard still
          // guards dirty documents via cancel()).
          if (!hadTransient) editor.cancel()
          return
        }
         // A press anywhere outside the open text field accepts the text.
         // The field handles its own clicks, and it is the only thing above
         // this area, so a press arriving here is a press outside it -
         // whether it lands on the picture or on the letterbox round it.
         if (editor.textAnchor !== null) {
           editor._finishText(true)
           return
         }
         if (!drawArea._inside(mouse)) return
         // A new element takes the focus: whatever the last release left active
         // stops being the colour and width target here. Select keeps its own
         // selection, which its press handler decides.
         if (editor.tool !== "select") editor.selectedIndex = -1
         const raw = editor._toDoc(mouse.x, mouse.y)
        // Frame-managing drags (crop tool; select with a staged frame)
        // work in raw coords - they resize/move the frame itself and
        // clamp their own result. Everything else anchors at the clamped
        // point: pressed inside the frame but the image edge is nearer
        // than it looks (zoomed in), the anchor pins to the kept area
        // instead of the letterbox.
        const frameMode = (editor.tool === "select" && editor.cropFrame !== null)
        const p = (editor.tool === "crop" || frameMode)
          ? editor._clampView(raw) : editor._clampDoc(raw)
        // A frame in place is a dead zone for everything except the
        // tools that manage the frame itself - the stuff outside it is
        // getting cut away, so it should not be paintable in the
        // meantime either.
         if (editor.tool !== "crop" && editor.tool !== "select" && !editor._insideFrame(raw)) return
         editor.preview = null
         drawArea.anchor = p
        drawArea.resizeMode = false
        if (editor.tool === "brush") {
          editor.preview = { tool: "brush", color: editor.ink, width: editor.penWidth, points: [p] }
        } else if (editor.tool === "eraser") {
          editor.strokes = editor.strokes.slice(0, editor.redoIndex)
          editor.redoIndex = editor.strokes.length
          editor._eraseAt(p)
        } else if (editor.tool === "text") {
          // Drag stages a sizing rect that follows the pointer freely (font
          // fits its height); a plain click keeps the slider size.
          editor.textRect = { x: p.x, y: p.y, w: 0, h: 0 }
          editor.textAnchor = null
          textField.text = ""
        } else if (editor.tool === "crop") {
          // A selected crop area is adjusted by grabs only: handles
          // resize it, a press inside drags it whole. A fresh rect can
          // only be staged from outside - pressing inside never starts
          // a new selection. The applied frame wins over a staged rect.
          const hasFrame = editor.cropFrame !== null
          const target = hasFrame ? editor.cropFrame : editor.cropRect
          let grabbed = -1
          let inside = false
          if (target !== null && target.w > 1 && target.h > 1) {
            const hs = drawArea._handlesOf(target)
            for (let i = 0; i < 8; i++) {
              if (Math.abs(mouse.x - hs[i].x) + Math.abs(mouse.y - hs[i].y) < 14) {
                grabbed = i
                break
              }
            }
            if (grabbed < 0) {
              inside = p.x >= target.x && p.x <= target.x + target.w
                && p.y >= target.y && p.y <= target.y + target.h
            }
          }
          if (grabbed >= 0) {
            drawArea.cropGrab = { x0: target.x, y0: target.y, x1: target.x + target.w, y1: target.y + target.h }
            drawArea.cropHandle = grabbed
            drawArea.cropResizeFrame = hasFrame
            drawArea.dragCursor = editor.handleSpots[grabbed].cur
          } else if (inside) {
            drawArea.cropDrag = { frame: hasFrame, ox: target.x, oy: target.y }
            drawArea.dragCursor = Qt.PointingHandCursor
          } else {
            editor.cropRect = { x: p.x, y: p.y, w: 0, h: 0 }
            drawArea.dragCursor = -1
          }
        } else if (editor.tool === "select") {
          if (editor.cropFrame !== null) {
            // The frame owns the canvas while it is staged: select
            // relocates it instead of touching strokes underneath.
            // Outside it is the dead zone from the gate above -
            // nothing to select there anyway.
            if (editor._insideFrame(p)) {
              drawArea.cropMoveBase = { x: editor.cropFrame.x, y: editor.cropFrame.y }
              drawArea.dragCursor = Qt.SizeAllCursor
            } else {
              drawArea.anchor = null
              drawArea.dragCursor = -1
            }
            return
          }
          editor.strokes = editor.strokes.slice(0, editor.redoIndex)
          editor.redoIndex = editor.strokes.length
          // Handle grab resizes (corners locked aspect, side midpoints
          // single-axis); otherwise select/move.
          const corners = drawArea._selectCorners()
          let grabbed = -1
          if (corners !== null) {
            for (let i = 0; i < 8; i++) {
              if (Math.abs(mouse.x - corners[i].x) + Math.abs(mouse.y - corners[i].y) < 14) {
                grabbed = i
                break
              }
            }
          }
          if (grabbed >= 0) {
            const dc = editor._selectDocHandles()
            drawArea.resizeMode = true
            drawArea.resizeHandle = grabbed
            drawArea.resizeFixed = dc[(grabbed + 4) % 8]
            drawArea.resizeOrig = dc[grabbed]
            drawArea.dragCursor = editor.handleSpots[grabbed].cur
            drawArea.resizeBase = editor.strokes[editor.selectedIndex].points.map(q => ({ x: q.x, y: q.y }))
            // Same snapshot _selectAt takes: the position branch is
            // gated on moveBase, so a corner grab without it never moves.
            drawArea.moveBase = drawArea.resizeBase.map(q => ({ x: q.x, y: q.y }))
          } else {
            editor._selectAt(p, mouse.x, mouse.y)
            drawArea.dragCursor = drawArea.moveBase !== null ? Qt.SizeAllCursor : -1
          }
        } else {
          editor.preview = { tool: editor.tool, color: editor.ink, width: editor.penWidth, points: [p, p] }
          drawArea.dragCursor = -1
        }
      }
      onPositionChanged: mouse => {
        if (editor.tool === "select" && editor.cropFrame !== null) {
          drawArea.hoverInFrame = editor._insideFrame(editor._toDoc(mouse.x, mouse.y))
        } else if (drawArea.hoverInFrame) {
          drawArea.hoverInFrame = false
        }
        // Pointer cursor over the selected crop area (crop tool only).
         // Document-space test: _toDoc follows the current rotation and
         // clamps only at the image boundary.
        if (editor.tool === "crop" && (editor.cropFrame !== null || editor.cropRect !== null)) {
          const t = editor.cropFrame !== null ? editor.cropFrame : editor.cropRect
           const dp = editor._toDoc(mouse.x, mouse.y)
           drawArea.hoverInCrop = t !== null && t.w > 1 && t.h > 1
             && dp.x >= t.x && dp.x <= t.x + t.w
             && dp.y >= t.y && dp.y <= t.y + t.h
        } else if (drawArea.hoverInCrop) {
          drawArea.hoverInCrop = false
        }
        // Handle resize cursor, hover only: an active drag keeps the
        // cursor grabbed at press time (see dragCursor).
        if (!(mouse.buttons & Qt.LeftButton)) {
          drawArea.hoverHandleCursor = drawArea._hoverHandleCursor(mouse.x, mouse.y)
        }
        if ((mouse.buttons & Qt.MiddleButton) && drawArea.panFrom !== null && drawArea.panBase !== null) {
          editor.viewPan = {
            x: drawArea.panBase.x + mouse.x - drawArea.panFrom.x,
            y: drawArea.panBase.y + mouse.y - drawArea.panFrom.y
          }
          return
        }
        if (!(mouse.buttons & Qt.LeftButton) || drawArea.anchor === null) return
        const raw = editor._toDoc(mouse.x, mouse.y)
        // Same clamp contract as the press: stroke points follow the
        // kept area's edges instead of trailing into the cut-away zone
        // (or off the image) where the canvas would silently clip them;
        // crop and frame drags clamp to the view rect so the frame can
        // still grow to the image edges.
        const frameMode = (editor.tool === "select" && editor.cropFrame !== null)
        const p = (editor.tool === "crop" || frameMode)
          ? editor._clampView(raw) : editor._clampDoc(raw)
        if (editor.tool === "brush" && editor.preview !== null) {
          const prev = editor.preview
          const pts = prev.points.slice()
          const last = pts[pts.length - 1]
          // Cut at the kept area's edge instead of squeezing the trail
          // onto it: inside samples land verbatim; the first sample past
          // the edge pins ONE boundary point; further movement outside
          // records nothing. Without this, a drag along the border
          // stacked a run of clamped points on it - and moving the crop
          // frame later exposed that stack as a line drawn on its edge.
          const isOut = p.x !== raw.x || p.y !== raw.y
          if (!isOut) {
            if (p.x !== last.x || p.y !== last.y) pts.push(p)
          } else if (prev.out !== true && (p.x !== last.x || p.y !== last.y)) {
            pts.push(p)
          }
          editor.preview = { tool: "brush", color: editor.ink, width: editor.penWidth, points: pts, out: isOut }
          board.requestPaint()
        } else if (editor.tool === "eraser") {
          editor._eraseAt(p)
          } else if ((editor.tool === "line" || editor.tool === "arrow" || editor.tool === "arrowCorner"
            || editor.tool === "rect" || editor.tool === "ellipse" || editor.tool === "blur")
            && editor.preview !== null) {
            editor.preview = {
              tool: editor.tool, color: editor.ink, width: editor.penWidth,
              points: [drawArea.anchor, p]
            }
            board.requestPaint()
          } else if (editor.tool === "crop" && drawArea.cropGrab !== null
            && (drawArea.cropResizeFrame ? editor.cropFrame !== null : editor.cropRect !== null)) {
            // Live resize of the grabbed crop area (applied frame or
            // staged rect): the handle follows the pointer on its own
            // axes, the opposite edges stay fixed. Clamped to the view
            // rect so the area can never hang off the image (it would
            // keep un-croppable pixels staged).
            const spot = editor.handleSpots[drawArea.cropHandle] || { fx: 0, fy: 0 }
            const g = drawArea.cropGrab
            const vr2 = editor.viewRect
            const cx = v => Range.clamp(v, vr2.x, vr2.x + vr2.w)
            const cy = v => Range.clamp(v, vr2.y, vr2.y + vr2.h)
            const ex0 = spot.fx === 0 ? p.x : g.x0
            const ex1 = spot.fx === 1 ? p.x : g.x1
            const ey0 = spot.fy === 0 ? p.y : g.y0
            const ey1 = spot.fy === 1 ? p.y : g.y1
            const r = AnnotationTools.normRect(cx(ex0), cy(ey0), cx(ex1), cy(ey1))
             if (r.w >= 2 && r.h >= 2) {
               const resized = editor._clampDocumentRect(r)
               if (drawArea.cropResizeFrame) editor.cropFrame = resized
               else editor.cropRect = resized
              board.requestPaint()
            }
          } else if (editor.tool === "crop" && drawArea.cropDrag !== null) {
            // Whole-area drag of the grabbed crop area: it follows the
            // pointer, clamped into the view rect.
            const dd = drawArea.cropDrag
            const cur = dd.frame ? editor.cropFrame : editor.cropRect
            if (cur === null) {
              drawArea.cropDrag = null
            } else {
              const vr3 = editor.viewRect
               const nx = Math.max(vr3.x, Math.min(vr3.x + vr3.w - cur.w, dd.ox + p.x - drawArea.anchor.x))
               const ny = Math.max(vr3.y, Math.min(vr3.y + vr3.h - cur.h, dd.oy + p.y - drawArea.anchor.y))
               const moved = editor._clampDocumentRect({ x: nx, y: ny, w: cur.w, h: cur.h })
               if (dd.frame) editor.cropFrame = moved
               else editor.cropRect = moved
              board.requestPaint()
            }
          } else if (editor.tool === "crop" && editor.cropRect !== null) {
            editor.cropRect = AnnotationTools.normRect(drawArea.anchor.x, drawArea.anchor.y, p.x, p.y)
            board.requestPaint()
          } else if (editor.tool === "select" && drawArea.cropMoveBase !== null && editor.cropFrame !== null) {
            // Clamped to the document so the frame can't be dragged
            // past the edges it is supposed to be cropping within.
            const f = editor.cropFrame
            const vr = editor.viewRect
             const nx = Math.max(vr.x, Math.min(vr.x + vr.w - f.w, drawArea.cropMoveBase.x + p.x - drawArea.anchor.x))
             const ny = Math.max(vr.y, Math.min(vr.y + vr.h - f.h, drawArea.cropMoveBase.y + p.y - drawArea.anchor.y))
             editor.cropFrame = editor._clampDocumentRect({ x: nx, y: ny, w: f.w, h: f.h })
            board.requestPaint()
          } else if (editor.tool === "text" && editor.textRect !== null) {
            // The box follows the pointer on both axes: the first move past a
            // seed size grows it, later moves resize it freely, and dragging
            // past the anchor flips it through normRect.
            editor.textRect = AnnotationTools.normRect(drawArea.anchor.x, drawArea.anchor.y, p.x, p.y)
            board.requestPaint()
          } else if (editor.tool === "select" && editor.selectedIndex >= 0 && drawArea.moveBase !== null) {
            if (drawArea.resizeMode && drawArea.resizeFixed !== null && drawArea.resizeOrig !== null
              && drawArea.resizeBase !== null) {
              const fx = drawArea.resizeFixed.x
              const fy = drawArea.resizeFixed.y
              const ox = drawArea.resizeOrig.x
              const oy = drawArea.resizeOrig.y
              const spot = editor.handleSpots[drawArea.resizeHandle]
              const movedFor = (sx, sy) => drawArea.resizeBase.map(q => ({
                x: fx + (q.x - fx) * sx, y: fy + (q.y - fy) * sy
              }))
              // Text strokes carry a single anchor point, so scaling
              // points alone only slides them: the font rides the same
              // factor, otherwise the box never changes size.
              const applyMoved = (moved, sFont) => {
                const kept = editor.strokes.slice()
                const prev = editor.strokes[editor.selectedIndex]
                const next = Object.assign({}, prev, { points: editor._clampDocPoints(moved) })
                if (prev.tool === "text") {
                  next.fontSize = Range.clamp(
                    Math.round((prev.fontSize || 24) * sFont), 4, 200)
                }
                kept[editor.selectedIndex] = next
                editor.strokes = kept
                board.requestPaint()
              }
              if (spot !== undefined && spot !== null && (spot.fx === 0.5 || spot.fy === 0.5)) {
                // Edge midpoint: stretch one axis about the opposite
                // edge, floored so the shape can never invert.
                let sx = 1
                let sy = 1
                if (spot.fx !== 0.5) {
                  const dx = ox - fx
                  sx = Math.abs(dx) >= 1 ? (p.x - fx) / dx : 1
                  if (!(sx > 0)) sx = 0.05
                  sx = Range.clamp(sx, 0.05, 20)
                }
                if (spot.fy !== 0.5) {
                  const dy = oy - fy
                  sy = Math.abs(dy) >= 1 ? (p.y - fy) / dy : 1
                  if (!(sy > 0)) sy = 0.05
                  sy = Range.clamp(sy, 0.05, 20)
                }
                applyMoved(movedFor(sx, sy), sx !== 1 ? sx : sy)
              } else {
                // Corner: uniform scale about the fixed corner, aspect
                // preserved by construction, floored so the shape can
                // never invert.
                const denom = Math.sqrt((ox - fx) * (ox - fx) + (oy - fy) * (oy - fy))
                if (denom >= 1) {
                  const num = Math.sqrt((p.x - fx) * (p.x - fx) + (p.y - fy) * (p.y - fy))
                  const s = Range.clamp(num / denom, 0.05, 20)
                  applyMoved(movedFor(s, s), s)
                }
              }
            } else {
              const dx = p.x - drawArea.anchor.x
              const dy = p.y - drawArea.anchor.y
              const moved = editor._clampDocPoints(drawArea.moveBase.map(q => ({ x: q.x + dx, y: q.y + dy })))
              const kept = editor.strokes.slice()
              kept[editor.selectedIndex] = Object.assign({}, editor.strokes[editor.selectedIndex], { points: moved })
              editor.strokes = kept
              board.requestPaint()
            }
          }
      }
      onReleased: mouse => {
        if (mouse.button === Qt.MiddleButton) {
          drawArea.panFrom = null
          drawArea.panBase = null
          drawArea.dragCursor = -1
          return
        }
        if (mouse.button !== Qt.LeftButton || drawArea.anchor === null) return
        // The release point must honor the same clamp as the moves: the
        // pointer can leave the window mid-drag and release out of
        // bounds, and this last point is what gets committed into the
        // stroke - unclamped, it is the leak that lets a stroke start on
        // the image and end inside the dimmed cut-away (or off-image).
         const p = (editor.tool === "crop" || (editor.tool === "select" && editor.cropFrame !== null))
           ? editor._clampView(editor._toDoc(mouse.x, mouse.y))
           : editor._clampDoc(editor._toDoc(mouse.x, mouse.y))
         if (editor.tool === "crop" && editor.cropRect !== null
           && (editor.cropRect.w <= 1 || editor.cropRect.h <= 1)) editor.cropRect = null
         if (editor.tool === "text" && editor.textRect !== null) {
          // Dragged sizing rect: the field opens inside it with the line
          // fitted to its height, and it stays visible while typing so the
          // caret can never sit outside the selected area. A plain click
          // has no box: it keeps the slider size and anchors at the point.
          const t = editor.textRect
          if (t.w > 8 && t.h > 8) {
            editor.fontSize = Range.clamp(Math.round(t.h), 10, 72)
            // Font from the inset box itself (see _textFieldInner), so
            // preview, commit and outline all share one size.
            const ti = editor._textFieldInner
            editor.textPx = ti !== null ? ti.font
              : Math.max(1, t.h * editor._fit * editor._zoomAnim / 1.2)
            editor.textAnchor = { x: t.x, y: t.y }
          } else {
            // Click-placed: no box, the field floats at the point and
            // grows as you type.
            editor.textRect = null
            editor.textRectW = 220
            editor.textPx = editor.fontSize * editor._fit * editor._zoomAnim
            editor.textAnchor = p
          }
          textField.text = ""
        } else if (editor.preview !== null && editor.tool !== "crop" && editor.tool !== "text"
          && editor.tool !== "eraser" && editor.tool !== "select") {
          // The pointer can leave the window mid-drag and release out of
          // bounds; every stroke point was already clamped to the kept
          // area as it arrived, so the commit is safe as-is - a click
          // (anchor == release point) is a deliberate dot and commits too.
          // A release outside the kept area must not drag the trail's
          // tail along the boundary: the moves already cut it at the
          // edge, so an out-of-bounds release keeps the trail's own last
          // point instead of adding one more clamped one.
          const relRaw = editor._toDoc(mouse.x, mouse.y)
          const relOut = p.x !== relRaw.x || p.y !== relRaw.y
          const pts = editor.preview.points.slice(0, editor.preview.points.length - 1)
          pts.push(relOut ? editor.preview.points[editor.preview.points.length - 1] : p)
          const stroke = {
            tool: editor.preview.tool, color: editor.preview.color,
            width: editor.preview.width,
            points: pts
          }
           editor._commit(stroke)
         }
           editor.preview = null
           drawArea.anchor = null
          drawArea.moveBase = null
          drawArea.dragCursor = -1
          drawArea.resizeMode = false
          drawArea.resizeFixed = null
          drawArea.resizeOrig = null
          drawArea.resizeBase = null
          drawArea.resizeHandle = -1
          drawArea.cropGrab = null
          drawArea.cropHandle = -1
          drawArea.cropResizeFrame = false
          drawArea.cropDrag = null
          drawArea.cropMoveBase = null
        }
      onWheel: wheel => {
        editor._zoomAt(wheel.x, wheel.y, wheel.angleDelta.y > 0
          ? editor._wheelStep : 1 / editor._wheelStep)
        wheel.accepted = true
      }
      onClicked: mouse => {
        // Click (no drag) confirms a staged crop rect, like Enter - but
        // only from outside it. Inside clicks are move-grabs (possibly
        // without movement), never a new selection.
        if (mouse.button === Qt.LeftButton && editor.tool === "crop" && editor.cropRect !== null
          && editor.cropRect.w > 1 && editor.cropRect.h > 1) {
           const p = editor._toDoc(mouse.x, mouse.y)
           const c = editor.cropRect
           if (p.x < c.x || p.x > c.x + c.w || p.y < c.y || p.y > c.y + c.h) {
            editor._applyCrop()
          }
        }
      }
    }

    // Selection resize handles: accent squares on the selected bounds
    // corners and edge midpoints (select tool only).
    Repeater {
      model: editor.tool === "select" && editor.selectedIndex >= 0 ? 8 : 0

      delegate: Rectangle {
        required property int index

        property var corner: {
          const cs = drawArea._selectCorners()
          return cs !== null ? cs[index] : null
        }

        x: (corner !== null ? corner.x : -100) - 5
        y: (corner !== null ? corner.y : -100) - 5
        width: 10
        height: 10
        color: Ui.solid("accent")
        border.color: Ui.solid("background_0")
        border.width: 1
      }
    }

    // Crop frame handles: accent squares on the applied frame
    // corners and edge midpoints (crop tool only).
    Repeater {
      model: editor.tool === "crop" && editor.cropFrame !== null ? 8 : 0

      delegate: Rectangle {
        required property int index

        property var corner: {
          const cs = drawArea._cropCorners()
          return cs !== null ? cs[index] : null
        }

        x: (corner !== null ? corner.x : -100) - 5
        y: (corner !== null ? corner.y : -100) - 5
        width: 10
        height: 10
        color: Ui.solid("accent")
        border.color: Ui.solid("background_0")
        border.width: 1
      }
    }

    // Staged crop rect handles: same 8 grabs, so a selected area is
    // only ever extended by grabs, never re-dragged from inside.
    Repeater {
      model: editor.tool === "crop" && editor.cropRect !== null
        && editor.cropRect.w > 1 && editor.cropRect.h > 1 ? 8 : 0

      delegate: Rectangle {
        required property int index

        property var corner: {
          const cs = drawArea._cropRectCorners()
          return cs !== null ? cs[index] : null
        }

        x: (corner !== null ? corner.x : -100) - 5
        y: (corner !== null ? corner.y : -100) - 5
        width: 10
        height: 10
        color: Ui.solid("accent")
        border.color: Ui.solid("background_0")
        border.width: 1
      }
    }
  }

  // Floating tool panel: icon tools, swatches, knobs, actions. The only
  // chrome on the overlay - no status lines, no hints, no dialogs. Slides
  // up from below on open.

  // Hover tooltip shared by every panel control.
  property var _tipAnchor: null
  property string _tipText: ""

  function _tipOn(item, text) {
    editor._tipAnchor = item
    editor._tipText = text
  }

  function _tipOff(item) {
    if (editor._tipAnchor === item) {
      editor._tipAnchor = null
      editor._tipText = ""
    }
  }

  // Toolbar button: fixed slot, re-rasterized icon glyph, hover/active
  // chrome with fade (gated by the global animation switch), tooltip.
  component ToolBtn: Item {
    id: toolButton

    property string iconName: ""
    property string iconGlyph: ""
    property string iconColor: "foreground_0"
     property bool active: false
     property bool checkable: false
     property string tip: ""
    property bool hovered: false
    // Two independent gates. `enabled` is the hard lock and drops the whole
    // subtree out of the hit-test chain, which also means a disabled item
    // can no longer set its own cursor. `actionable` is the soft gate the
    // swatches and the knob use: the MouseArea stays in the chain so
    // Qt.ForbiddenCursor actually reaches the user, and the guard on `live`
    // is what makes the button inert instead.
    property bool actionable: true
    readonly property bool live: enabled && actionable
    signal activated()

    width: Math.round(27 * editor.uiScale)
    height: Math.round(27 * editor.uiScale)
    activeFocusOnTab: true
    enabled: !editor.interactionLocked

     Accessible.role: Accessible.Button
     Accessible.name: tip
     Accessible.checkable: toolButton.checkable
     Accessible.checked: toolButton.active
     Accessible.onPressAction: if (toolButton.live) toolButton.activated()

    Keys.onReturnPressed: if (toolButton.live) toolButton.activated()
    Keys.onEnterPressed: if (toolButton.live) toolButton.activated()
    Keys.onSpacePressed: if (toolButton.live) toolButton.activated()

    Rectangle {
      anchors.fill: parent
      color: toolButton.active ? Ui.tint("accent", 0.15)
        : toolButton.live && toolButton.hovered ? Ui.tint("foreground_1", 0.07) : "transparent"
      border.width: toolButton.active || toolButton.activeFocus ? 2 : 1
      border.color: toolButton.active || toolButton.activeFocus ? Theme.color("accent")
        : Ui.tint("foreground_1", toolButton.live && toolButton.hovered ? 0.7 : 0.4)
      Behavior on color {
        enabled: editor.animOn
        ColorAnim {}
      }
      Behavior on border.color {
        enabled: editor.animOn
        ColorAnim {}
      }
    }

    Icon {
      anchors.centerIn: parent
      visible: iconName !== ""
      name: iconName
      colorKey: iconColor
      size: Math.round(14 * editor.uiScale)
    }

    Text {
      anchors.centerIn: parent
      visible: iconName === ""
      text: iconGlyph
      color: active ? Theme.color("accent") : Theme.color("foreground_1")
      font.pixelSize: Math.round(Ui.fontXs * editor.uiScale)
      font.family: Ui.fontFamily
      textFormat: Text.PlainText
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      hoverEnabled: true
      cursorShape: toolButton.live ? Qt.PointingHandCursor : Qt.ForbiddenCursor
      onClicked: if (toolButton.live) toolButton.activated()
    }

    // Gating the handler itself makes it drop its own hover state when the
    // button is disabled mid-hover, which clears the chrome and the tooltip
    // without a second resync path.
    HoverHandler {
      enabled: toolButton.live
      onHoveredChanged: {
        toolButton.hovered = hovered
        if (hovered) editor._tipOn(toolButton, toolButton.tip)
        else editor._tipOff(toolButton)
      }
    }
  }

  // House slider idiom (Volume island VSlider): 6px track, accent fill,
  // drag + wheel, no library widget.
  component Knob: Item {
    id: knob

    property real from: 0
    property real to: 100
    property real value: 0
    property real step: 1
    property string tip: ""
    signal moved(real v)

    width: 100
    height: Math.round(27 * editor.uiScale)
    activeFocusOnTab: true
    enabled: !editor.interactionLocked
    opacity: editor.tool === "select" ? 0.5 : 1

    Accessible.role: Accessible.Slider
    Accessible.name: tip
    Accessible.description: "Range " + knob.from + " to " + knob.to
      + ", step " + knob.step + ", value " + knob.value
    Accessible.onIncreaseAction: {
      if (editor.tool !== "select") {
        knob.moved(Math.min(knob.to, knob.value + knob.step))
      }
    }
    Accessible.onDecreaseAction: {
      if (editor.tool !== "select") {
        knob.moved(Math.max(knob.from, knob.value - knob.step))
      }
    }

    Keys.onPressed: event => {
      if (editor.tool === "select") return
      let delta = 0
      if (event.key === Qt.Key_Left || event.key === Qt.Key_Down) delta = -step
      else if (event.key === Qt.Key_Right || event.key === Qt.Key_Up) delta = step
      else if (event.key === Qt.Key_PageDown) delta = -step * 10
      else if (event.key === Qt.Key_PageUp) delta = step * 10
      if (delta !== 0) {
        moved(Range.clamp(value + delta, from, to))
        event.accepted = true
      }
    }

    readonly property real frac: (value - from) / Math.max(0.001, to - from)

    Rectangle {
      x: 0
      y: 0
      width: parent.width
      height: parent.height
      radius: RoundingPolicy.radius
      color: Theme.color("background_2")
      border.width: knob.activeFocus ? 2 : 1
      border.color: knob.activeFocus ? Ui.solid("accent")
        : Ui.tint("foreground_1", 0.4)

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: parent.width * Range.clamp01(knob.frac)
        radius: RoundingPolicy.radius
        color: Theme.color("accent")
      }
    }

    MouseArea {
      anchors.fill: parent
      anchors.topMargin: -6
      anchors.bottomMargin: -6
      hoverEnabled: true
      cursorShape: editor.tool === "select" ? Qt.ForbiddenCursor : Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton

      function update(x) {
        const r = Range.clamp01(x / width)
        knob.moved(Range.clamp(
          Math.round((knob.from + r * (knob.to - knob.from)) / knob.step) * knob.step,
          knob.from, knob.to))
      }

      onPressed: mouse => {
        if (editor.tool !== "select") update(mouse.x)
      }
      onPositionChanged: mouse => {
        if (editor.tool !== "select" && pressed) update(mouse.x)
      }
    }

    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: event => {
        if (editor.tool === "select") return
        const d = event.angleDelta.y > 0 ? knob.step
          : (event.angleDelta.y < 0 ? -knob.step : 0)
        if (d !== 0) knob.moved(Math.max(knob.from,
          Math.min(knob.to, knob.value + d)))
      }
    }

    HoverHandler {
      onHoveredChanged: {
        if (hovered) editor._tipOn(knob, knob.tip)
        else editor._tipOff(knob)
      }
    }
  }

  Rectangle {
    id: panel

     enabled: editor.loadState === "ready" && !editor.interactionLocked
     visible: false
     property real revealOffset: 0
     x: Math.round((editor.width - width) / 2)
     y: editor.height - height - Ui.m + revealOffset
    width: toolRow.width + midRow.width + actRow.width + Ui.m * 3 + Ui.s
    height: Math.round(44 * editor.uiScale)
    // Corners follow RoundingPolicy (hypr.decoration.rounding).
    radius: RoundingPolicy.radius
    color: Ui.solid("background_1")
    border.color: Ui.tint("foreground_1", 0.4)
    border.width: 1
     Component.onCompleted: Qt.callLater(reveal)
      function reveal() {
        if (editor.loadState !== "ready") {
          panel.visible = false
          return
        }
        if (!editor.animOn) {
         panel.revealOffset = 0
         panel.visible = true
          return
       }
       panel.revealOffset = 220
       panel.visible = true
       slideAnim.to = 0
       slideAnim.start()
     }

     NumberAnimation {
       id: slideAnim

          target: panel
          property: "revealOffset"
        duration: Ui.slowMs
        easing.type: Easing.OutExpo
      }

    Row {
      id: toolRow

      anchors.left: midRow.right
      anchors.leftMargin: Ui.m
      anchors.verticalCenter: parent.verticalCenter
      spacing: 3

      Repeater {
        model: editor.tools

        delegate: ToolBtn {
          required property string modelData

          iconName: Icons.url(editor.toolMeta[modelData].icon) !== "" ? editor.toolMeta[modelData].icon : ""
          iconGlyph: editor.toolMeta[modelData].glyph
           active: editor.tool === modelData
           checkable: true
           tip: editor.toolMeta[modelData].tip
          onActivated: editor.tool = modelData
        }
      }
    }

    Row {
      id: midRow

      anchors.left: parent.left
      anchors.leftMargin: Ui.m
      anchors.verticalCenter: parent.verticalCenter
      spacing: 5

      Repeater {
        model: editor.palette

        delegate: Rectangle {
          id: swatch

          required property string modelData

          activeFocusOnTab: true
          enabled: !editor.interactionLocked
          // Dimmed only when the tile would do nothing: Select is active and no
          // element is selected for it to recolour.
          opacity: editor.tool === "select" && editor.selectedStrokeIndex < 0 ? 0.5 : 1
           Accessible.role: Accessible.Button
           Accessible.name: "Color " + editor._colorName(swatch.modelData)
           Accessible.checkable: true
           Accessible.checked: editor.activeColor === swatch.modelData
           Accessible.onPressAction: editor.applyColor(swatch.modelData)

          Keys.onReturnPressed: editor.applyColor(swatch.modelData)
          Keys.onEnterPressed: editor.applyColor(swatch.modelData)
          Keys.onSpacePressed: editor.applyColor(swatch.modelData)

          width: Math.round(27 * editor.uiScale)
          height: Math.round(27 * editor.uiScale)
          radius: RoundingPolicy.radius
          anchors.verticalCenter: parent.verticalCenter
          color: swatch.modelData
          border.width: editor.activeColor === swatch.modelData || swatch.activeFocus ? 2 : 0
          border.color: Ui.solid("accent")

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: editor.tool === "select" && editor.selectedStrokeIndex < 0
              ? Qt.ForbiddenCursor : Qt.PointingHandCursor
            onClicked: editor.applyColor(swatch.modelData)
          }
        }
      }

      Knob {
        width: Math.round(100 * editor.uiScale)
        anchors.verticalCenter: parent.verticalCenter
        from: 1
        to: 24
        step: 1
        value: editor.penWidth
        tip: "Pen width"
        onMoved: v => editor.applyWidth(v)
      }
    }

    Row {
      id: actRow

      anchors.left: toolRow.right
      anchors.leftMargin: Ui.m
      anchors.verticalCenter: parent.verticalCenter
      spacing: 3

      ToolBtn {
        iconName: "clear"
         iconColor: "red"
         active: editor.clearArmed
         tip: "Clear all"
         actionable: editor.loadState === "ready" && editor.canClear
         opacity: editor.canClear ? 1 : 0.5
         onActivated: {
           if (!editor.canClear) return
           if (editor.clearArmed) editor.clearAll()
           else {
             editor.clearArmed = true
             clearTimer.restart()
           }
         }
      }
       ToolBtn {
         iconName: "copy"
         tip: "Copy (Ctrl+C)"
          actionable: editor.loadState === "ready" && editor.textAnchor === null
          onActivated: editor.copy()
       }
       ToolBtn {
         iconName: "save"
         tip: "Save (Ctrl+S)"
         actionable: editor.loadState === "ready"
         onActivated: editor.save()
       }
      ToolBtn {
        iconName: "rotate-ccw"
        tip: "Rotate counter-clockwise"
        onActivated: editor._rotate(-1)
      }
      ToolBtn {
        iconName: "rotate-cw"
        tip: "Rotate clockwise"
        onActivated: editor._rotate(1)
      }
      ToolBtn {
        iconName: "xmark"
        iconColor: "red"
        active: editor.discardArmed
        tip: "Cancel (Esc)"
        onActivated: editor.cancel()
      }
    }
  }

  // Hover tooltip, declared last so it paints above the panel it
  // describes. Positioned above the hovered control.
  Rectangle {
    id: tipBox

    property var anchorItem: editor._tipAnchor

    visible: editor._tipText !== "" && anchorItem !== null
    width: tipLabel.width + 18
    height: 26
    // Corners follow RoundingPolicy (hypr.decoration.rounding).
    radius: RoundingPolicy.radius
    x: anchorItem !== null
      ? Math.max(8, Math.min(stage.width - width - 8,
        anchorItem.mapToItem(stage, anchorItem.width / 2, 0).x - width / 2)) : 0
    y: anchorItem !== null
      ? Math.max(8, anchorItem.mapToItem(stage, 0, 0).y - height - 6) : 0
    color: Ui.solid("background_1")
    border.color: Ui.tint("foreground_1", 0.4)
    border.width: 1

    Text {
      id: tipLabel

      anchors.centerIn: parent
      text: editor._tipText
      font.pixelSize: Ui.fontS
      font.family: Ui.fontFamily
      color: Ui.solid("foreground_0")
    }
  }

  // Window-level hotkeys: no focus scope to lose, the active window owns
  // them. Letter tools stay off while the text field is open.
  Shortcut {
    sequence: "U"
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor.undoOrDiscardCrop()
  }
  Shortcut {
    sequence: "R"
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor.redo()
  }
  Shortcut {
    sequence: "Ctrl+Z"
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor.undoOrDiscardCrop()
  }
  Shortcut {
    sequences: ["Ctrl+Shift+Z", "Ctrl+Y"]
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor.redo()
  }
  Shortcut {
    sequence: "Ctrl+S"
    enabled: editor.loadState === "ready" && !editor.interactionLocked
      && editor.textAnchor === null
    onActivated: editor.save()
  }
  Shortcut {
    sequence: "Ctrl+C"
    enabled: editor.loadState === "ready" && !editor.interactionLocked
      && editor.textAnchor === null
    onActivated: editor.copy()
  }
  Shortcut {
    sequence: "Escape"
    enabled: !editor.interactionLocked
    onActivated: {
      if (editor.textAnchor !== null) {
        editor.textAnchor = null
        editor.textRect = null
      }
      else if (editor.textRect !== null) editor.textRect = null
      else if (editor.cropRect !== null || editor.cropFrame !== null) {
        editor.cropRect = null
        editor.cropFrame = null
      }
      else if (editor.selectedIndex >= 0) editor.selectedIndex = -1
      else editor.cancel()
    }
  }
  Shortcut {
    sequences: ["Delete", "Backspace"]
    enabled: !editor.interactionLocked && editor.textAnchor === null && editor.selectedIndex >= 0
    onActivated: editor.deleteSelected()
  }
  Shortcut {
     sequence: "Return"
     enabled: !editor.interactionLocked && editor.tool === "crop" && editor.cropRect !== null && editor.textAnchor === null
    onActivated: editor._applyCrop()
  }
  Shortcut {
    sequence: "B"
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor.tool = "brush"
  }
  Shortcut {
    sequence: "L"
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor.tool = "line"
  }
  Shortcut {
    sequence: "E"
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor.tool = "eraser"
  }
  Shortcut {
    sequence: "A"
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor.tool = "arrow"
  }
  Shortcut {
    sequence: "G"
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor.tool = "rect"
  }
  Shortcut {
    sequence: "O"
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor.tool = "ellipse"
  }
  Shortcut {
    sequence: "T"
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor.tool = "text"
  }
  Shortcut {
    sequence: "C"
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor.tool = "crop"
  }
  Shortcut {
    sequence: "D"
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor.tool = "blur"
  }
  Shortcut {
    sequence: "N"
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor.tool = "arrowCorner"
  }
  Shortcut {
    sequence: "0"
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor._resetView()
  }
  Shortcut {
    sequence: "V"
    enabled: !editor.interactionLocked && editor.textAnchor === null
    onActivated: editor.tool = "select"
  }

  // Rotate the whole document 90 degrees (dir +1 clockwise, -1
  // counter-clockwise). Strokes keep their coordinates and ride the
  // paint transform, so redo history, grids and hit tests survive
  // untouched. docRot itself just accumulates the target angle - the
  // _rotAnim Behavior is what actually animates the visible turn (paint
  // rotation, and _docW/_docH/_fit/_geom morphing along with it).
  function _rotate(dir) {
    if (editor.loadState !== "ready" || editor.interactionLocked) return
    const vr = editor.viewRect
    if (vr.w <= 0 || vr.h <= 0) return
    // (No canvasSize call: backing follows the item; the paint reads
    // live item geometry.)
     editor._finishText(true)
     editor.docRot = editor.docRot + (dir > 0 ? 90 : -90)
     editor.strokes = editor.strokes.slice(0, editor.redoIndex)
     editor.redoIndex = editor.strokes.length
    editor.selectedIndex = -1
    editor.preview = null
    editor.cropRect = null
     editor.textRect = null
    editor.textAnchor = null
    board.requestPaint()
  }

  // True when p (document pixels) sits inside the applied frame, or
  // when there is no frame at all - the no-frame case is the default
  // "everything is fair game" state every gate above falls back to.
  function _insideFrame(p) {
    return AnnotationTools.insideFrame(p, editor.cropFrame)
  }

  function _applyCrop() {
    const c = editor.cropRect
    editor.cropRect = null
    if (!c || c.w < 2 || c.h < 2) {
      board.requestPaint()
      return
    }
    // Non-destructive: the staged rect becomes the applied frame.
    // Strokes, redo history and the view rect stay untouched, so
    // the frame can be resized later and save/copy cut at the end.
     editor.cropFrame = editor._clampDocumentRect(c)
    editor.selectedIndex = -1
    board.requestPaint()
  }

  // Select press: a repeat click on the current selection (same spot,
  // quick) cycles through the stack beneath it, so overlapped strokes
  // stay reachable; otherwise the topmost hit wins and drags. Hits are
  // box hits, not ink hits: an object is grabbable anywhere inside the
  // bounds its outline draws, so a circle takes a click through its middle.
  property var _lastSelectPress: null

  function _selectAt(p, mx, my) {
    const hits = []
    for (let i = editor.redoIndex - 1; i >= 0; i--) {
      if (AnnotationTools.hitStrokeBox(editor.strokes[i], p.x, p.y)) hits.push(i)
    }
    const prev = editor._lastSelectPress
    editor._lastSelectPress = { x: mx, y: my, t: Date.now() }
    if (hits.length === 0) {
      editor.selectedIndex = -1
      drawArea.moveBase = null
      return
    }
    const at = hits.indexOf(editor.selectedIndex)
    if (at >= 0 && prev !== null && Date.now() - prev.t < 450
      && Math.abs(prev.x - mx) + Math.abs(prev.y - my) < 12) {
      editor.selectedIndex = hits[(at + 1) % hits.length]
    } else {
      editor.selectedIndex = hits[0]
    }
    drawArea.moveBase = editor.strokes[editor.selectedIndex].points.map(q => ({ x: q.x, y: q.y }))
  }

  // deleteSelected drops the current selection, if any.
  function deleteSelected() {
    if (editor.selectedIndex < 0) return
    const kept = editor.strokes.slice(0, editor.redoIndex)
    kept.splice(editor.selectedIndex, 1)
    editor.strokes = kept
    editor.redoIndex = kept.length
    editor.selectedIndex = -1
    board.requestPaint()
  }

  // Loose document-pixel bounds of a stroke for the selection outline.
  function _strokeBounds(s) {
    return AnnotationTools.strokeBounds(s)
  }

  // Object deletion is stroke-based, not pixel-based. Removes the topmost
  // stroke near the pointer.
  function _eraseAt(p) {
    const tol = editor._hitTolerance()
    for (let i = editor.redoIndex - 1; i >= 0; i--) {
      if (AnnotationTools.hitStroke(editor.strokes[i], p.x, p.y, tol)) {
        const kept = editor.strokes.slice(0, editor.redoIndex)
        kept.splice(i, 1)
        editor.strokes = kept
        editor.redoIndex = kept.length
        editor.selectedIndex = -1
        editor._lastSelectPress = null
        board.requestPaint()
        return
      }
    }
  }

  // Blur regions in paint order: committed strokes up to the redo point, then
  // the live preview. Intersecting with the crop frame here (rather than
  // clipping the overlay as a whole) trims each region the way the canvas
  // would have clipped the ink.
  // Fraction of a blur region already covered by committed ones, sampled on
  // a grid. Overlap is not cumulative - every region blurs the same picture -
  // so re-blurring an area that is already blurred is pure work: the preview
  // hides and the commit drops once the area is essentially all covered.
  function _blurCoverage(r) {
    if (r === null || r === undefined || !(r.w > 0) || !(r.h > 0)) return 0
    const regions = []
    for (let i = 0; i < editor.redoIndex && i < editor.strokes.length; i++) {
      const s = editor.strokes[i]
      if (s === null || s === undefined || s.tool !== "blur") continue
      const pts = Array.isArray(s.points) ? s.points : []
      if (pts.length < 2) continue
      regions.push(AnnotationTools.normRect(pts[0].x, pts[0].y,
        pts[pts.length - 1].x, pts[pts.length - 1].y))
    }
    if (regions.length === 0) return 0
    const n = 10
    let hit = 0
    for (let gy = 0; gy < n; gy++) {
      for (let gx = 0; gx < n; gx++) {
        const px = r.x + (gx + 0.5) * r.w / n
        const py = r.y + (gy + 0.5) * r.h / n
        for (let i = 0; i < regions.length; i++) {
          const q = regions[i]
          if (px >= q.x && px <= q.x + q.w && py >= q.y && py <= q.y + q.h) {
            hit++
            break
          }
        }
      }
    }
    return hit / (n * n)
  }

  // Blur rect for a corner pair, clipped to the applied frame. One place for
  // the geometry the layer stack, the drag preview and the export all use.
  function _blurRectOf(x1, y1, x2, y2) {
    let r = AnnotationTools.normRect(x1, y1, x2, y2)
    if (!(r.w > 0) || !(r.h > 0)) return null
    const f = editor.cropFrame
    if (f !== null) {
      const x0 = Math.max(f.x, r.x)
      const y0 = Math.max(f.y, r.y)
      const x1b = Math.min(f.x + f.w, r.x + r.w)
      const y1b = Math.min(f.y + f.h, r.y + r.h)
      if (!(x1b > x0) || !(y1b > y0)) return null
      r = { x: x0, y: y0, w: x1b - x0, h: y1b - y0 }
    }
    return r
  }

  function _blurRectAt(i) {
    const s = editor.strokes[i]
    if (s === null || s === undefined || s.tool !== "blur") return null
    const pts = Array.isArray(s.points) ? s.points : []
    if (pts.length < 2) return null
    return editor._blurRectOf(pts[0].x, pts[0].y, pts[pts.length - 1].x, pts[pts.length - 1].y)
  }

  // Committed blur regions in paint order, for the export walk.
  function _blurRects() {
    const out = []
    const total = Math.min(editor.redoIndex, editor.strokes.length)
    for (let i = 0; i < total; i++) {
      const r = editor._blurRectAt(i)
      if (r !== null) out.push(r)
    }
    return out
  }

  // The document layer stack in stroke order: contiguous runs of ink and the
  // blur regions between them. A blur covers everything below it - the picture
  // and the ink committed before it - and ink committed after it comes later
  // in the stack, so it draws on top. The export walks the strokes in this same
  // order, which is what keeps a saved shot equal to what was on screen.

  // The live drag's blur rect, or null. Read by the preview layer only: the
  // stack's model deliberately ignores the preview, so a brush drag does not
  // rebuild the ink canvases on every mouse sample.
  function _previewBlurRect() {
    const p = editor.preview
    if (p === null || p === undefined || p.tool !== "blur") return null
    const pts = Array.isArray(p.points) ? p.points : []
    if (pts.length < 2) return null
    const r = editor._blurRectOf(pts[0].x, pts[0].y, pts[pts.length - 1].x, pts[pts.length - 1].y)
    if (r === null) return null
    // Dragging across an area that is already blurred paints nothing.
    return editor._blurCoverage(r) >= 0.9 ? null : r
  }


  // One blur region into a canvas whose transform maps document pixels onto
  // its backing: the plate covers the whole document at document size, so the
  // clip does the cropping and no source-rect math is needed - the same
  // geometry the on-screen overlay clips to, at any plate size.
  function _drawBlurRegion(ctx, s, offsetX, offsetY) {
    if (editor.blurPlateUrl === "" || !Array.isArray(s.points) || s.points.length < 2) return
    const r = AnnotationTools.normRect(s.points[0].x, s.points[0].y,
      s.points[s.points.length - 1].x, s.points[s.points.length - 1].y)
    if (!(r.w > 0) || !(r.h > 0)) return
    ctx.save()
    ctx.beginPath()
    ctx.rect(r.x + offsetX, r.y + offsetY, r.w, r.h)
    ctx.clip()
    ctx.drawImage(editor.blurPlateUrl, offsetX, offsetY, editor.imgW, editor.imgH)
    ctx.restore()
  }

  // Blur the plate once and keep it as a PNG. This grab is the only pixel
  // readback in the blur path - once per shot, never per stroke.
  function _grabBlurPlate() {
    if (editor._blurPlatePending || editor._blurPlateDone
      || editor.imgW <= 0 || editor._blurPlateW < 16) return
    // The source must be decoded at the plate's size: a status that reads
    // Ready while sourceSize is still the placeholder means a 1x1 texture,
    // and a grab of that writes a blank plate.
    if (blurSource.status !== Image.Ready
      || blurSource.sourceSize.width !== editor._blurPlateW
      || blurSource.sourceSize.height !== editor._blurPlateH) {
      if (editor._blurPlateTries < 20) {
        editor._blurPlateTries++
        blurPlateTimer.restart()
      }
      return
    }
    const path = editor.runtimeDir + "/blur-" + editor._sessionId + ".png"
    editor._blurPlatePending = true
    const grabbed = blurPlate.grabToImage(result => {
      editor._blurPlatePending = false
      if (result === null || result === undefined
        || typeof result.saveToFile !== "function"
        || result.saveToFile(path) === false) {
        // Retryable on purpose: one failed grab must not cost every later
        // export its blur for the rest of the session.
        if (editor._blurPlateTries < 20) {
          editor._blurPlateTries++
          blurPlateTimer.restart()
        }
        return
      }
      editor._blurPlatePath = path
      editor._blurPlateDone = true
      editor.blurPlateUrl = Paths.toFileUrl(path)
      // An export that arrived while the plate was still rendering waited
      // for this: repaint it now instead of letting it time out.
      if (exportCanvas.pendingPath !== "") {
        try { exportCanvas.loadImage(editor.blurPlateUrl) } catch (e) {}
        exportCanvas.requestPaint()
        exportPaintTimer.restart()
      }
    }, Qt.size(editor._blurPlateW, editor._blurPlateH))
    if (!grabbed) {
      editor._blurPlatePending = false
      if (editor._blurPlateTries < 20) {
        editor._blurPlateTries++
        blurPlateTimer.restart()
      }
    }
  }

  function _cleanupBlurPlate() {
    const path = editor._blurPlatePath
    editor._blurPlatePath = ""
    editor.blurPlateUrl = ""
    editor._blurPlatePending = false
    if (path !== "" && SU.isUnder(String(path), editor.runtimeDir)) Exec.rm(path)
  }

  function _paintStroke(ctx, s, offsetX, offsetY, displayScale) {
    const pts = s.points || []
    if (pts.length === 0) return
    // Blur is not ink: the region is a clipped copy of the blurred plate,
    // drawn by the QML overlay on screen and by _drawBlurRegion on export.
    if (s.tool === "blur") return
    const vr = editor.viewRect
    const ox = offsetX === undefined ? -vr.x : offsetX
    const oy = offsetY === undefined ? -vr.y : offsetY
    const scale = displayScale === undefined || !Number.isFinite(displayScale)
      || displayScale <= 0 ? 1 : displayScale
    const width = (s.width || 3) * scale
    ctx.save()
    ctx.strokeStyle = s.color
    ctx.fillStyle = s.color
    ctx.lineWidth = width
    ctx.lineCap = "round"
    ctx.lineJoin = "round"
    if (s.tool === "brush") {
      ctx.beginPath()
      ctx.moveTo(pts[0].x + ox, pts[0].y + oy)
      for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x + ox, pts[i].y + oy)
      ctx.stroke()
    } else if (s.tool === "line" || s.tool === "arrow") {
      const a = pts[0]
      const b = pts[pts.length - 1]
      const headLen = Math.max(14 * scale, width * 5)
      if (s.tool === "arrow") {
        // Shaft stops inside the head: round caps extend past endpoints,
        // so a full-length shaft pokes through the chevron.
        const dx = b.x - a.x
        const dy = b.y - a.y
        const len = Math.sqrt(dx * dx + dy * dy)
        const bx = len > 0 ? b.x - dx / len * headLen * 0.85 : b.x
        const by = len > 0 ? b.y - dy / len * headLen * 0.85 : b.y
        ctx.beginPath()
        ctx.moveTo(a.x + ox, a.y + oy)
        ctx.lineTo(bx + ox, by + oy)
        ctx.stroke()
        const head = AnnotationTools.arrowHead(a.x, a.y, b.x, b.y, headLen)
        ctx.beginPath()
        ctx.moveTo(b.x + ox, b.y + oy)
        ctx.lineTo(head[0].x + ox, head[0].y + oy)
        ctx.lineTo(head[1].x + ox, head[1].y + oy)
        ctx.closePath()
        ctx.fill()
      } else {
        ctx.beginPath()
        ctx.moveTo(a.x + ox, a.y + oy)
        ctx.lineTo(b.x + ox, b.y + oy)
        ctx.stroke()
      }
    } else if (s.tool === "arrowCorner") {
      // Elbow arrow: dominant-axis-first from the anchor, then to the
      // release point. The head rides the final segment.
      const a = pts[0]
      const b = pts[pts.length - 1]
      const m = AnnotationTools.elbowMid(a, b)
      const headLen = Math.max(14 * scale, width * 5)
      const dx = b.x - m.x
      const dy = b.y - m.y
      const len = Math.sqrt(dx * dx + dy * dy)
      const hx = len > 0 ? dx / len : (b.x >= a.x ? 1 : -1)
      const hy = len > 0 ? dy / len : 0
      const tipBase = { x: b.x - hx * headLen * 0.85, y: b.y - hy * headLen * 0.85 }
      ctx.beginPath()
      ctx.moveTo(a.x + ox, a.y + oy)
      ctx.lineTo(m.x + ox, m.y + oy)
      ctx.lineTo(tipBase.x + ox, tipBase.y + oy)
      ctx.stroke()
      const head = AnnotationTools.arrowHead(tipBase.x, tipBase.y, b.x, b.y, headLen)
      ctx.beginPath()
      ctx.moveTo(b.x + ox, b.y + oy)
      ctx.lineTo(head[0].x + ox, head[0].y + oy)
      ctx.lineTo(head[1].x + ox, head[1].y + oy)
      ctx.closePath()
      ctx.fill()
    } else if (s.tool === "rect") {
      const n = AnnotationTools.normRect(pts[0].x, pts[0].y, pts[pts.length - 1].x, pts[pts.length - 1].y)
      // Square corners on purpose: the round join above is there for the brush
      // and arrow, and on a rectangle it reads as a rounded box. strokeRect
      // takes its joins from the context, so it has to be set here.
      ctx.lineJoin = "miter"
      ctx.strokeRect(n.x + ox, n.y + oy, n.w, n.h)
    } else if (s.tool === "ellipse") {
      const n = AnnotationTools.normRect(pts[0].x, pts[0].y, pts[pts.length - 1].x, pts[pts.length - 1].y)
      const cx = n.x + n.w / 2 + ox
      const cy = n.y + n.h / 2 + oy
      const rx = Math.max(0.5, n.w / 2)
      const ry = Math.max(0.5, n.h / 2)
      // Bezier ellipse (no ctx.ellipse dependency): kappa-circle math.
      const k = 0.5522848
      ctx.beginPath()
      ctx.moveTo(cx - rx, cy)
      ctx.bezierCurveTo(cx - rx, cy - k * ry, cx - k * rx, cy - ry, cx, cy - ry)
      ctx.bezierCurveTo(cx + k * rx, cy - ry, cx + rx, cy - k * ry, cx + rx, cy)
      ctx.bezierCurveTo(cx + rx, cy + k * ry, cx + k * rx, cy + ry, cx, cy + ry)
      ctx.bezierCurveTo(cx - k * rx, cy + ry, cx - rx, cy + k * ry, cx - rx, cy)
      ctx.closePath()
      ctx.stroke()
    } else if (s.tool === "text") {
      const fs = (s.fontSize || 24) * scale
      // Family list: canvas warns and falls back per paint when the
      // system family is missing, so always offer monospace last.
      ctx.font = fs + "px " + Ui.fontFamily + ", monospace"
      ctx.textBaseline = "top"
      const lines = String(s.text || "").split("\n")
      for (let i = 0; i < lines.length; i++) {
        ctx.fillText(lines[i], pts[0].x + ox, pts[0].y + oy + i * fs * 1.2)
      }
    }
    ctx.restore()
  }
}

