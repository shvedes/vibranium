pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type signal-handler-parameters
import QtQuick
import qs.common

// Demand-loaded owner of the annotation surfaces. Constructed on first
// use and gone again on teardown, so a shell that never annotates pays for
// none of it: the region selector, the capture picker and the editor are
// built here and destroyed with this object. The capture service is not
// allowed to name any of them, so every request arrives through the
// neutral AnnotationActions contract and every outcome goes back through
// it.
//
// The controller holds no policy: the flow identity, the region crop
// pipeline, the runtime temp files and the lastPath bookkeeping all live
// in the service. What lives here is the objects - it opens one view per
// request, retargets it when the output set changes, answers the contract
// with a typed outcome and destroys the view when the service releases the
// request id.
//
// One view per kind at a time, which is also the surface invariant the
// service enforces through its flow identity: a second overlay, picker or
// editor would stack exclusive surfaces that fight for focus. A refused
// second open is answered "busy" so the caller can tell a refusal from a
// failure.
Item {
  id: root

  readonly property string tag: "annotations"

  // Stable identity for the contract: adopt() and release() compare the
  // handler, so a closure built at each call site could never be released.
  readonly property var viewCommand: command => root.runCommand(command)

  // One live view per kind, each paired with the request id the contract
  // minted for it. The id is what an outcome settles against, so a view
  // that answers after the service released it is refused instead of
  // reaching a newer flow.
  property var _picker: null
  property int _pickerId: 0
  property var _overlay: null
  property int _overlayId: 0
  property var _editor: null
  property int _editorId: 0

  Component {
    id: overlayComp

    AnnotationOverlay {}
  }

  Component {
    id: pickerComp

    CapturePicker {}
  }

  Component {
    id: editorComp

    AnnotationEditor {}
  }

  Component.onCompleted: AnnotationActions.adopt(root.viewCommand)

  // Nothing outlives the controller: an unadopted contract would hand the
  // next request to a dead object, and a view left mapped would keep an
  // exclusive surface claimed for a controller that no longer exists. The
  // requests go with the views - a record left behind would let a settled
  // answer reach a flow that has already moved on.
  Component.onDestruction: {
    AnnotationActions.close(root._pickerId)
    AnnotationActions.close(root._overlayId)
    AnnotationActions.close(root._editorId)
    AnnotationActions.release(root.viewCommand)
    root._destroyPicker()
    root._destroyOverlay()
    root._destroyEditor()
  }

  // --- contract commands ---
  function runCommand(command) {
    if (command === null || command === undefined || typeof command !== "object") return null
    const code = String(command.code)
    if (code === "open") return root._open(Number(command.id), command.request)
    if (code === "retarget") {
      root._retarget(Number(command.id), command.screen)
      return true
    }
    if (code === "close") {
      root._destroy(String(command.kind), Number(command.id))
      return true
    }
    if (code === "abandon") {
      // The view already answered and is closing itself; only the slot
      // goes, so its own teardown path stays in charge of the object.
      root._forget(String(command.kind), Number(command.id))
      return true
    }
    return null
  }

  function _open(id, request) {
    if (request === null || request === undefined || typeof request !== "object") return false
    if (id <= 0) return false
    const kind = String(request.kind)
    if (kind === "picker") return root._openPicker(id, request)
    if (kind === "region") return root._openRegion(id, request)
    if (kind === "editor") return root._openEditor(id, request)
    return false
  }

  function _openPicker(id, request) {
    if (root._picker !== null) return "busy"
    const view = pickerComp.createObject(root, { screen: request.screen, visible: true })
    if (view === null) return false
    root._picker = view
    root._pickerId = id
    return true
  }

  // A seeded overlay shows a frozen fullscreen grab the service already
  // saved; an immediate one grabs its own live frame, so the accepted
  // rect comes back with the frame the capture pipeline has to cut.
  function _openRegion(id, request) {
    if (root._overlay !== null) return "busy"
    const immediate = request.immediate === true
    const view = overlayComp.createObject(root, {
      screen: request.screen,
      seedUrl: immediate ? "" : String(request.url ?? ""),
      seedFrameW: immediate ? 0 : Number(request.frameW) || 0,
      seedFrameH: immediate ? 0 : Number(request.frameH) || 0,
      immediate: immediate,
      _uid: Number(request.jobId) || 0,
      visible: false
    })
    if (view === null) return false
    root._overlay = view
    root._overlayId = id
    view.visible = true
    return true
  }

  // The editor keeps the flow id it was opened with as its answer id: it
  // calls the service's registered noteSaved/noteCancelled with it, which
  // is the one-directional half of the boundary.
  function _openEditor(id, request) {
    if (root._editor !== null) return "busy"
    const view = editorComp.createObject(root, {
      shotPath: String(request.shotPath ?? ""),
      savePath: String(request.savePath ?? ""),
      saveToDisk: request.saveToDisk === true,
      fileType: String(request.fileType ?? "png"),
      showNotification: request.showNotification !== false,
      runtimeDir: String(request.runtimeDir ?? ""),
      directSource: request.directSource === true,
      screen: request.screen,
      _uid: Number(request.flowId) || 0,
      visible: true
    })
    if (view === null) return false
    root._editor = view
    root._editorId = id
    return true
  }

  // --- output reconciliation ---
  function _retarget(id, screen) {
    if (id <= 0 || screen === null || screen === undefined) return
    if (root._pickerId === id && root._picker !== null) {
      root._picker.screen = screen
      return
    }
    if (root._overlayId === id && root._overlay !== null) {
      root._overlay.screen = screen
      return
    }
    if (root._editorId === id && root._editor !== null) root._editor.screen = screen
  }

  // --- teardown ---
  function _destroy(kind, id) {
    if (kind === "picker") root._destroyPicker(id)
    else if (kind === "region") root._destroyOverlay(id)
    else if (kind === "editor") root._destroyEditor(id)
  }

  function _forget(kind, id) {
    if (kind === "picker" && root._pickerId === id) {
      root._picker = null
      root._pickerId = 0
      return
    }
    if (kind === "region" && root._overlayId === id) {
      root._overlay = null
      root._overlayId = 0
      return
    }
    if (kind === "editor" && root._editorId === id) {
      root._editor = null
      root._editorId = 0
    }
  }

  // The picker fades its veil out before it goes, so a dismiss reads as a
  // close instead of a cut. The id defaults to 0 so destruction, which has
  // no request left to name, still tears the view down.
  function _destroyPicker(id = 0) {
    const view = root._picker
    if (view !== null && (id <= 0 || root._pickerId === id)) {
      view.dismiss()
      view.destroy()
    }
    root._picker = null
    root._pickerId = 0
  }

  function _destroyOverlay(id = 0) {
    const view = root._overlay
    if (view !== null && (id <= 0 || root._overlayId === id)) view.destroy()
    root._overlay = null
    root._overlayId = 0
  }

  // A cancel from the service kills the editor's children: the export it
  // may be driving is abandoned with it.
  function _destroyEditor(id = 0) {
    const view = root._editor
    if (view !== null && (id <= 0 || root._editorId === id)) {
      view._stopProcesses()
      view.destroy()
    }
    root._editor = null
    root._editorId = 0
  }

  // The editor's window closed. The service hears it first, because the
  // cancel bookkeeping belongs to the flow that owns the editor; the
  // teardown here covers a window closed from the outside, since the
  // editor's own _close() already stopped its children and is gone.
  function _editorWindowClosed() {
    const view = root._editor
    if (view === null) return
    const id = root._editorId
    AnnotationActions.settle(id, { code: "closed" })
    if (view._closing !== true) {
      view._stopProcesses()
      view.destroy()
    }
    if (root._editor === view) {
      root._editor = null
      root._editorId = 0
    }
  }

  Connections {
    target: root._picker
    ignoreUnknownSignals: true

    function onChosen(mode) {
      AnnotationActions.settle(root._pickerId, { code: "chosen", mode: String(mode) })
    }

    function onCancelled() {
      AnnotationActions.settle(root._pickerId, { code: "cancelled" })
    }

    // A dismiss is not a close and never arrives here, so this is the
    // compositor taking the surface away. It has to be answered, or the
    // flow that opened the picker stays claimed.
    function onClosed() {
      AnnotationActions.settle(root._pickerId, { code: "closed" })
    }
  }

  Connections {
    target: root._overlay
    ignoreUnknownSignals: true

    // The accepted frame is handed over with the rect: the grab result is
    // only valid while this overlay lives, and the capture pipeline saves
    // it from inside this same tick. The service releases the request id
    // right after, which is what tears this overlay down.
    function onAccepted(x, y, w, h) {
      const view = root._overlay
      AnnotationActions.settle(root._overlayId, {
        code: "accepted",
        x: x,
        y: y,
        w: w,
        h: h,
        grab: view !== null ? view._grabResult : null,
        grabFrameW: view !== null ? Number(view.grabFrameW) || 0 : 0,
        grabFrameH: view !== null ? Number(view.grabFrameH) || 0 : 0
      })
    }

    function onCancelled() {
      AnnotationActions.settle(root._overlayId, { code: "cancelled" })
    }

    function onFailed(reason) {
      AnnotationActions.settle(root._overlayId, { code: "failed", reason: String(reason) })
    }
  }

  Connections {
    target: root._editor
    ignoreUnknownSignals: true

    function onClosed() {
      root._editorWindowClosed()
    }
  }
}
