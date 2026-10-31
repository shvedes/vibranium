pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type signal-handler-parameters
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.common
import "../../common/capture/ShotLib.js" as ShotLib
import "../../common/capture/RectMath.js" as RectMath
import "../../common/text/UnitIpc.js" as UnitIpc

// Headless capture protocol, IPC and state owner. A mode resolves its
// target, grabs one physical frame, probes its decoded size, saves it
// directly, and optionally runs an exact area crop, clipboard offer,
// notification, and annotation flow.
//
// What actually captures a frame: the grab is a Quickshell screen capture
// against the Hyprland compositor, so neither `grim` nor `wl-copy` is in
// the capture path, and the encoder is the file's suffix rather than a
// process. `magick` appears once, in the exact-area crop, and `wl-copy`
// once, in the clipboard offer; neither is on the path that produces the
// frame.
//
// The annotation surfaces are not ours: the region selector, the capture
// picker and the editor are demanded on demand through the neutral
// AnnotationActions contract and owned by an on-demand controller, so
// this file holds no annotation type and constructs no view. What crosses
// the boundary is a request record and a request id, which is also the
// identity every flow check below validates against.
//
// SPLIT MAP (one owner each, no behavior change): Flow (capture flow:
// mode resolve, target screen, frame grab, attempts, _flow/_activeFlow
// guards), Delivery (persist + offer: save, clipboard copy, daemon
// toast, emit, crop), AnnotateBridge (annotation handoff: request
// records + ids over the AnnotationActions contract, editor/picker
// demand).
Singleton {
  id: root

  readonly property string tag: "screenshots"

  // Schema options, rev-captured so settings edits apply live.
  readonly property string fileType: {
    Settings.rev
    const v = Settings.value("shell.screenshots.fileType")
    return v === "jpeg" ? "jpeg" : "png"
  }
  readonly property bool saveToDisk: Settings.value("shell.screenshots.saveToDisk") !== false
  readonly property bool showNotification: Settings.value("shell.screenshots.showNotification") !== false
  readonly property bool autoAnnotate: Settings.value("shell.screenshots.autoAnnotate") === true
  readonly property bool captureCursor: Settings.value("shell.screenshots.captureCursor") === true
  readonly property var _lockState: Bus.latest("lockscreen.state")
  readonly property bool sessionLocked: root._lockState !== null
    && root._lockState.locked === true
  readonly property string runtimeDir:
    Paths.vibraniumRuntime + "/screenshots-" + Quickshell.processId
  readonly property string fallbackDir: Paths.screenshotFallbackDir
  property bool _runtimeReady: false
  property bool _runtimeFailed: false
  property var _queuedStart: null
  property var _activeDelivery: null
  property var _ownedPaths: []
  property string _flow: ""
  property int _flowSeq: 0
  property int _activeFlow: 0
  // Token for the exclusive-surface claim the running flow holds, released
  // by _releaseFlow() and by Component.onDestruction.
  property var _claimToken: null
  // True while the running flow asked to keep the screen as it stands, in
  // which case it holds no claim and nothing it does dismisses an open
  // overlay. Flow state rather than an argument because the stages that
  // continue an already-claimed flow inherit it from the claim instead.
  property bool _flowKeep: false
  // Annotation request ids (0 = no view). They are the only handle this
  // service keeps on the annotation surfaces: the request record behind an
  // id carries the screen and the job/flow identity each check needs, and
  // releasing the id is what tears the view down.
  property int _editorRequest: 0
  property int _pickerRequest: 0
  property int _regionRequest: 0
  property var _cropProcess: null
  property var _cropJob: null
  property var _mkdirProcess: null
  property var _startupProcess: null
  property var _sourceStatProcess: null
  property var _copyProcesses: []
  property string _fallbackTarget: ""
  property bool _fallbackCommitted: false
  property int _copySeq: 0
  property int _jobSeq: 0
  property int _activeJob: 0
  property int _editorUid: -1
  readonly property string _sessionId: Quickshell.processId + "-" + Date.now()

  onSessionLockedChanged: {
    if (sessionLocked) root._cancelActiveFlow("session-locked")
  }

  // Per-stage wall clock. A capture is a sequence of asynchronous hops and
  // each stage stamps itself on the way in. The marks are replaced wholesale
  // rather than mutated so a capture that is cancelled mid-flight leaves
  // nothing for the next one to read.
  property var _marks: ({})
  property double _t0: 0

  function _mark(name) {
    const next = Object.assign({}, root._marks)
    next[name] = Date.now()
    root._marks = next
  }

  function _armClock() {
    root._t0 = Date.now()
    root._marks = ({})
  }

  // Raised when a capture completes (file path, "" when clipboard-only or
  // when the annotator path saved over it). The annotation editor (spec
  // 11) and any future bar module bind this.
  signal captured(string path)

  // Last completed shot's path ("" before the first one).
  property string lastPath: ""

  // Screen mode: the focused monitor, falling back to the primary. The choice is
  // made here rather than at the call sites, and the fallback is not a failure:
  // a compositor that has not published a focused monitor yet lands on the
  // primary and the capture is still correct.
  function _targetScreen() {
    const focused = Hyprland.focusedMonitor
    if (focused !== null && focused !== undefined) {
      const s = ShotLib.pickFocusedScreen(Ui.validScreens, screen => {
        const m = Hyprland.monitorFor(screen)
        return m !== null && m !== undefined ? m : null
      }, focused.id)
      if (s !== null) return s
    }
    return Ui.primaryScreen
  }

  function _matchingScreen(screen) {
    return ShotLib.matchScreen(screen, Ui.validScreens)
  }

  function _screenValid(screen) {
    return root._matchingScreen(screen) !== null
  }

  // The output set moved. This runs on every hotplug, on every resolution
  // change and on every wake, so each branch says what it did about it - a
  // retarget, a cancel, or nothing because the screen survived as the same
  // object. A resolution change makes `matchScreen` return a different object
  // for the same panel, so "retargeted" here does not mean the monitor moved.
  function _screenSetChanged() {
    if (root._pickerRequest !== 0) {
      const request = AnnotationActions.spec(root._pickerRequest)
      const current = request !== null ? root._matchingScreen(request.screen) : null
      if (current === null) {
        root._pickerOutcome(root._pickerRequest, { code: "cancelled" })
        return
      }
      if (current !== request.screen) {
        AnnotationActions.retarget(root._pickerRequest, current)
      }
    }
    if (root._pendingPick !== null) {
      const current = root._matchingScreen(root._pendingPick.screen)
      if (current === null) {
        const flowId = root._pendingPick.flowId
        root._pendingPick = null
        root._releaseFlow(flowId)
        return
      }
      root._pendingPick.screen = current
    }
    if (root._regionRequest !== 0) {
      const request = AnnotationActions.spec(root._regionRequest)
      const current = request !== null ? root._matchingScreen(request.screen) : null
      if (current === null) {
        root._regionOutcome(root._regionRequest, { code: "failed", reason: "screen disconnected" })
        return
      }
      if (current !== request.screen) {
        AnnotationActions.retarget(root._regionRequest, current)
      }
    }
    if (root._liveRegion !== null) {
      const current = root._matchingScreen(root._liveRegion.screen)
      if (current === null) {
        root._cancelActiveFlow("screen-disconnected")
        root._daemonNotify("Screenshot", "Screen disconnected")
        return
      }
      root._liveRegion.screen = current
    }
    if (root._regionSeed !== null) {
      const current = root._matchingScreen(root._regionSeed.screen)
      if (current === null) {
        root._cancelActiveFlow("screen-disconnected")
        root._daemonNotify("Screenshot", "Screen disconnected")
        return
      }
      root._regionSeed.screen = current
    }
    if (root._editorRequest !== 0) {
      const request = AnnotationActions.spec(root._editorRequest)
      const current = request !== null ? root._matchingScreen(request.screen) : null
      if (current === null) {
        root._cancelActiveFlow("screen-disconnected")
        return
      }
      if (current !== request.screen) {
        AnnotationActions.retarget(root._editorRequest, current)
      }
    }
    if (root._shotScreen !== null) {
      const current = root._matchingScreen(root._shotScreen)
      if (current === null) {
        const jobId = root._activeJob
        root._fail(shotWin, "screen disconnected", root._activeFlow, jobId)
      } else if (current !== root._shotScreen) {
        root._shotScreen = current
        shotWin.targetScreen = current
      }
    }
  }

  // Persistent shot window: one layer surface, one screencopy context and
  // one decode probe reused across captures. Idle releases the surface and
  // capture target so no compositor buffers remain between shots.
  property ShellScreen _shotScreen: null

  PanelWindow {
    id: shotWin

    property ShellScreen targetScreen: null
    property string mode: ""
    property int jobId: 0
    property var config: null

    property alias view: view
    property alias frameProbe: frameProbe

    // Compositor scale for mapping logical selection coordinates to
    // physical frame pixels. The lookup is guarded because a screen the
    // compositor cannot map must fall back rather than throw; the
    // precedence between the two sources is the shared one.
    readonly property real dpr: {
      let scale = 0
      try {
        const scr = screen !== null && screen !== undefined ? screen : root._shotScreen
        const m = scr !== null && scr !== undefined ? Hyprland.monitorFor(scr) : null
        scale = m !== null && m !== undefined ? m.scale : 0
      } catch (e) { scale = 0 }
      return ShotLib.compositorScale(scale, Screen.devicePixelRatio)
    }

    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    exclusiveZone: -1
    visible: root._shotScreen !== null
    anchors.left: true
    anchors.right: true
    anchors.top: true
    anchors.bottom: true
    // Full-screen at WlrLayer.Top for the whole frame -> grab -> decode ->
    // save hop, and nothing in it wants input: the ScreencopyView is
    // opacity: 0 and the decode probe is visible: false. Without an empty
    // region the surface is still the topmost pointer target in the
    // compositor for that interval and a click during it is swallowed.
    mask: Region { width: 0; height: 0 }
    WlrLayershell.namespace: "vibranium:screenshot"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    screen: root._shotScreen

    ScreencopyView {
      id: view

      property int attempts: 0

      // The ratio Qt renders an ItemGrabResult target at: this window's own
      // effective DPR. Screen.devicePixelRatio is a different number whenever
      // Qt's ratio is already folded into the window's logical size (a
      // 1600x900 surface over a 1920x1080 frame reports 2 there and 1.2
      // here), and a target divided by the wrong one saves a fraction of the
      // frame - which then leaves every selection mapped onto a grid smaller
      // than the file it is cut from. Read off the window that owns it, whose
      // devicePixelRatio is notifying: a capture that follows this window onto
      // an output of another scale re-derives the target instead of keeping
      // the ratio it mapped with.
      readonly property real reportedDpr: shotWin.devicePixelRatio > 0
        ? shotWin.devicePixelRatio
        : ShotLib.qtDpr(Screen.devicePixelRatio)

      anchors.fill: parent
      captureSource: shotWin.targetScreen
      live: false
      paintCursor: root.captureCursor
      opacity: 0

      // The frame is the compositor's, not a child's. This is where it
      // lands, and `attempts` is the poll count the frameTimer gave up
      // on if it ever has to - so the number that explains a slow capture
      // is the number that explains a failed one.
      //
      // The signal is the delivery channel: a frame that lands settles
      // on this tick through _settleFrame below - no interval collapse,
      // no 1ms restart hack. The poll alongside only re-requests frames
      // (bounded retries); the grabWatchdog bounds the whole wait.
      onHasContentChanged: {
        if (hasContent !== true) return
        const win = frameTimer.win
        if (win === null || win.view !== view) return
        frameTimer.stop()
        root._settleFrame(win)
      }

      // The compositor ended the stream, which is a reason no frame is
      // coming rather than a reason to wait out the next 250ms interval.
      // `shotWin.visible` is the liveness gate: it is bound to
      // root._shotScreen !== null, so it is true only while a capture is
      // armed and _releaseShot clears it - which is what bounds this. The
      // ladder still decides when to give up, because this re-request does
      // not spend an attempt: frameTimer keeps polling alongside it and
      // fails the job at the eighth, so a stream that ends without content
      // ends the capture rather than re-arming forever.
      onStopped: {
        if (shotWin.visible && !view.hasContent) view.captureFrame()
      }
    }

    // Hidden probe: decodes the grabbed frame URL and reports its saved
    // pixel size. cache:false is scoped to this full-res probe only: a
    // cached grab would pin a full-frame texture per capture, and the
    // probe fires once per capture (capture flow, never per frame), so
    // no debounce window applies.
    Image {
      id: frameProbe

      visible: false
      cache: false
      source: ""

       onStatusChanged: {
         if (status !== Image.Ready || root._pendingFinish === null) return
         const pending = root._pendingFinish
         const jobId = Number(pending.jobId) || 0
         const flowId = Number(pending.flowId) || 0
         if (jobId <= 0 || flowId <= 0 || pending.win !== shotWin
           || jobId !== root._activeJob || flowId !== root._activeFlow
           || String(frameProbe.source) !== String(pending.url)) return
         decodeTimer.stop()
         root._finish(shotWin, frameProbe, jobId, flowId)
       }
    }

  }

  // Release the shot window back to idle. The view and probe persist for
  // the next capture.
  function _releaseShot() {
    frameTimer.win = null
    grabWatchdog.stop()
    shotWin.frameProbe.source = ""
    root._shotScreen = null
    shotWin.targetScreen = null
    shotWin.jobId = 0
    shotWin.config = null
    root._activeShot = null
  }

  // Shared capture tail: teardown, then an optional region cut,
  // then either immediate delivery (clipboard copy, daemon toast,
  // emit) or the deferred annotation flow.
  function _finishTail(job) {
    const jobId = Number(job.jobId) || 0
    const flowId = Number(job.flowId) || 0
    if (!ShotLib.jobLive(jobId, root._activeJob, flowId, root._activeFlow)) {
      root._removeJobPaths(job.path, job.cropTo)
      return
    }
    if (job.win !== null && job.win !== undefined) job.win.frameProbe.source = ""
    root._grabResult = null
    if (job.cropTo !== "" && job.cropTo !== undefined && job.crop !== null && job.crop !== undefined) {
      const c = job.crop
      const full = String(job.path)
      const dst = String(job.cropTo)
      // An external cropper, and deliberately so. The shell-native
      // equivalent is a QImage-backed Canvas - AnnotationEditor's
      // exportCanvas does exactly this on save, measured at 18ms against
      // magick's 88ms here - but a Canvas only reaches onPaint inside a
      // MAPPED window, and a region capture's window belongs to the
      // annotation overlay, which the headless service cannot reach.
      // Hosting the canvas in this file's own shotWin does not help either:
      // that window is only mapped for a fullscreen capture, which is the
      // one mode that never crops. So the cut stays a process until either
      // the overlay performs it (a contract change - the service hands it
      // the rect and the destination and awaits the file) or the service
      // maps a window of its own for the cut.
      const argv = Exec.setsidTimeoutCmd(["magick", full, "-crop",
        c.w + "x" + c.h + "+" + c.x + "+" + c.y, "+repage", dst], 15)
      const proc = cropComp.createObject(root, { command: argv })
      if (proc === null) {
        root._removeJobPaths(full, dst)
        root._fail(job.win, "crop process failed", flowId, jobId)
        return
      }
      root._cropProcess = proc
      root._cropJob = job
      proc.exited.connect((code) => {
        const timedOut = code === 124
        proc.destroy()
        if (root._cropProcess === proc) root._cropProcess = null
        if (root._cropJob === job) root._cropJob = null
        if (!ShotLib.jobLive(jobId, root._activeJob, flowId, root._activeFlow)) {
          root._removeJobPaths(full, dst)
          return
        }
        if (code !== 0) {
          root._removeJobPaths(full, dst)
          root._fail(job.win, timedOut ? "crop timed out" : "crop failed", flowId, jobId)
          return
        }
        Exec.rm(full)
        root._forgetPath(full)
        job.path = dst
        job.cropTo = ""
        root._deliverTail(job)
      })
      proc.running = true
      return
    }
    root._deliverTail(job)
  }

  function _deliverTail(job) {
    if (job.mode === "region-seed") {
      root._activeJob = 0
      root._releaseShot()
      root._openRegionSeed(job)
      return
    }
    root._activeJob = 0
    root._releaseShot()
    if (job.defer) {
      root._pendingAnnotate = {
        temp: job.path, final: job.finalPath, prev: root.lastPath,
        config: job.config, flowId: job.flowId, screen: job.screen
      }
      if (!root.annotate(job.path, job.flowId)) {
        root._abortPendingAnnotate("Annotator unavailable")
      }
      gc()
      return
    }
    root._pendingAnnotate = null
    const delivery = {
      mode: job.mode, path: job.path, prev: root.lastPath,
      config: job.config, flowId: job.flowId,
      w: job.crop !== null && job.crop !== undefined
        ? (job.crop.w || 0) : (job.frameW || 0),
      h: job.crop !== null && job.crop !== undefined
        ? (job.crop.h || 0) : (job.frameH || 0)
    }
    root._activeDelivery = delivery
    root._copyImage(job.path, !job.config.saveToDisk, job.config.fileType, delivery,
      () => root._finishDelivery(delivery),
      () => root._failDelivery(delivery, "Clipboard image copy failed"))
  }

  // Deferred-annotation handshake (unique temp file, see _finishTail).
  // Set only by a deferred tail; a direct annotate/save leaves it null so
  // stray callbacks can never resurrect ancient paths.
  property var _pendingAnnotate: null

  // True while an annotator window is open. New capture flows are
  // refused while set: overlapping a fresh capture onto an open editor
  // clobbers _pendingAnnotate (leaking temps, confusing lastPath and
  // the clipboard), stacks Exclusive overlays that fight for focus
  // and configure, and interleaves logs beyond readability. Cleared
  // by every editor exit, which all funnel through noteSaved /
  // noteCancelled below.
  property bool _editorOpen: false

  // One flow at a time, and the refusal is the interesting half: a second
  // capture keypress during a live flow is dropped here, which looks to a
  // user exactly like a screenshot key that did nothing.
  //
  // `keepSurfaces` takes no claim at all, and the claim IS the dismissal:
  // taking it fires the closer of whichever overlay holds the screen, so a
  // flow that claims can never photograph an open menu - the one thing a
  // capture pressed over a menu is for. Skipping it is safe for the copy
  // because the shot window contributes nothing to what the compositor
  // hands back: transparent colour, an empty input mask, no keyboard focus,
  // and a screencopy child at opacity 0.
  function _claimFlow(kind, keepSurfaces) {
    if (root.sessionLocked) {
      root._daemonNotify("Screenshot", "Screenshots are unavailable while locked")
      return 0
    }
    if (root._flow !== "") return 0
    root._flowSeq++
    root._activeFlow = root._flowSeq
    root._flow = kind
    root._flowKeep = keepSurfaces === true
    if (!root._flowKeep) {
      root._claimToken = SurfaceClaim.claim("screenshots", root._cancelActiveFlow, root)
    }
    root._armClock()
    return root._activeFlow
  }

  function _releaseFlow(id) {
    // The flow-id guard runs first: ~20 sites call this, and a late one
    // from a finished flow must not release the claim a newer flow holds.
    if (!ShotLib.flowLive(id, root._activeFlow)) return
    root._activeFlow = 0
    root._flow = ""
    root._flowKeep = false
    SurfaceClaim.release(root._claimToken)
    root._claimToken = null
    root._t0 = 0
    root._marks = ({})
  }

  // The set of files this flow owns and will delete. Reported at release so
  // a leftover temp is visible as "owned=1" on a flow that ended, which is
  // the shape a leak takes; the names are leaves only, and only on the
  // teardown line where the count is the point.
  function _ownPath(path) {
    const value = String(path ?? "")
    if (value === "" || root._ownedPaths.includes(value)) return
    root._ownedPaths = root._ownedPaths.concat([value])
  }

  function _forgetPath(path) {
    root._ownedPaths = root._ownedPaths.filter(p => p !== String(path ?? ""))
  }

  function _removeJobPaths(path, cropTo) {
    const paths = [String(path ?? "")]
    const crop = String(cropTo ?? "")
    if (crop !== "" && !paths.includes(crop)) paths.push(crop)
    for (let i = 0; i < paths.length; i++) {
      if (paths[i] === "") continue
      Exec.rm(paths[i])
      root._forgetPath(paths[i])
    }
  }

  function _removeOwnedPaths() {
    const paths = root._ownedPaths
    root._ownedPaths = []
    for (let i = 0; i < paths.length; i++) Exec.rm(paths[i])
  }

  // The capture landed: notify if asked, publish the path, release the flow.
  function _finishDelivery(delivery) {
    if (delivery === null || root._activeDelivery !== delivery) return
    if (delivery.flowId !== root._activeFlow) return
    root._activeDelivery = null
    root._forgetPath(delivery.path)
    if (delivery.config.showNotification) root._notifyDone(delivery.mode, delivery.config.saveToDisk)
    root.lastPath = delivery.config.saveToDisk ? delivery.path : ""
    root.captured(root.lastPath)
    root._releaseFlow(delivery.flowId)
    gc()
  }

  function _failDelivery(delivery, reason) {
    if (delivery === null || root._activeDelivery !== delivery) return
    if (delivery.flowId !== root._activeFlow) return
    root._activeDelivery = null
    // The delivery reached the clipboard stage and did not complete, which
    // is a different failure from the capture itself failing: the frame is
    // on disk (if it was ever saved) and only the paste is missing.
    if (delivery.config.saveToDisk) root._forgetPath(delivery.path)
    else root._removeJobPaths(delivery.path, "")
    root._daemonNotify("Screenshot", reason)
    root._releaseFlow(delivery.flowId)
    gc()
  }

  function _abortPendingAnnotate(reason) {
    const pending = root._pendingAnnotate
    if (pending === null) return false
    root._pendingAnnotate = null
    // The deferred temp is discarded and lastPath rolls back, so the shot
    // is gone even though a file was written.
    if (pending.temp !== "") Exec.rm(pending.temp)
    root._forgetPath(pending.temp)
    root.lastPath = pending.prev
    root._releaseFlow(pending.flowId)
    if (reason !== "") root._daemonNotify("Screenshot", reason)
    return true
  }

  function _abortSuppliedFlow(id) {
    if (ShotLib.flowLive(Number(id) || 0, root._activeFlow)) {
      root._cancelActiveFlow("abandoned-by-caller")
    }
  }

  // SIGKILL to the process group, then the object. A child that outlives a
  // cancel is the failure this exists to prevent, and a capture that leaves a
  // `magick` holding a 4K PNG open is visible in `ps` long after.
  function _killProcess(proc, what) {
    if (proc === null || proc === undefined) return
    proc.signal(9)
    proc.destroy()
  }

  // A live flow torn down: the user locked the session, a screen vanished,
  // a caller walked away, or the process is going away. The line is
  // reported once, at the top, with everything that was in flight at the
  // time - because the question after a cancel is "what did it cancel",
  // and the answer is a list of the parts that were running, not a list of
  // the parts that were null.
  function _cancelActiveFlow(reason) {
    const id = root._activeFlow
    if (id === 0) return
    grabWatchdog.stop()
    decodeTimer.stop()
    frameTimer.stop()
    root._pendingFinish = null
    root._decodeAttempts = 0
    root._activeJob = 0
    root._activeDelivery = null
    if (root._cropProcess !== null) {
      const cropJob = root._cropJob
      root._killProcess(root._cropProcess, "crop")
      root._cropProcess = null
      root._cropJob = null
      if (cropJob !== null) root._removeJobPaths(cropJob.path, cropJob.cropTo)
    }
    if (root._mkdirProcess !== null) {
      root._killProcess(root._mkdirProcess, "mkdir")
      root._mkdirProcess = null
    }
    if (root._sourceStatProcess !== null) {
      root._killProcess(root._sourceStatProcess, "sourceStat")
      root._sourceStatProcess = null
    }
    const copies = root._copyProcesses.slice()
    root._copyProcesses = []
    for (let i = 0; i < copies.length; i++) root._killProcess(copies[i], "copy")
    if (root._fallbackTarget !== "") {
      if (!root._fallbackCommitted) {
        Exec.rm(root._fallbackTarget)
      }
      root._fallbackTarget = ""
      root._fallbackCommitted = false
    }
    if (root._editorRequest !== 0) {
      const request = root._editorRequest
      root._editorRequest = 0
      // The view goes before the bookkeeping: noteCancelled() forgets the
      // request itself, and a forgotten request is no longer releasable,
      // so a cancel that ran the bookkeeping first would leave an editor
      // mapped with nothing tracking it.
      AnnotationActions.close(request)
      Registry.call("screenshots", "noteCancelled", root._editorUid)
    }
    if (root._pendingAnnotate !== null) {
      const pending = root._pendingAnnotate
      root._pendingAnnotate = null
      Exec.rm(pending.temp)
      root._forgetPath(pending.temp)
      root.lastPath = pending.prev
    }
    root._destroyPicker()
    if (root._regionRequest !== 0) {
      AnnotationActions.close(root._regionRequest)
      root._regionRequest = 0
    }
    root._liveRegion = null
    root._pendingPick = null
    root._pendingCrop = null
    root._activeJob = 0
    root._releaseShot()
    shotWin.frameProbe.source = ""
    root._grabResult = null
    root._discardRegionSeed()
    root._removeOwnedPaths()
    root._releaseFlow(id)
  }

  // Editor callbacks through the Registry (the coupling stays
  // service <- editor one-directional: the editor calls in, the service
  // never calls out). Either way the deferred runtime temp is consumed
  // and deleted: annotated saves keep the final file, everything else
  // restores the previous shot. Either answer also drops the request: the
  // editor closes itself from here, so the controller is told to abandon
  // the tracking rather than to destroy a view that is already on its way
  // out.
  function _forgetEditorRequest() {
    if (!ShotLib.requestLive(root._editorRequest, root._editorRequest)) return
    AnnotationActions.abandon(root._editorRequest)
    root._editorRequest = 0
  }

  // The editor answered. Four outcomes, all of them transitions, and they
  // are the difference between "the user has a screenshot" and "the user
  // dismissed a dialog": a save with a path, a save with no path (the
  // editor closed without writing), a save somewhere other than the path
  // this flow reserved, and a cancel. Only the first publishes.
  function noteSaved(uid, path) {
    if (Number(uid) !== root._editorUid || root._editorUid < 0) return false
    const p = String(path ?? "")
    const pend = root._pendingAnnotate
    root._pendingAnnotate = null
    root._editorOpen = false
    root._forgetEditorRequest()
    root._editorUid = -1
    if (pend !== null) {
      Exec.rm(pend.temp)
      root._forgetPath(pend.temp)
    }
    if (p === "") {
      // An empty path is an editor that closed over its own Save As. The
      // file was never written, so `lastPath` keeps whatever it was and no
      // `captured` fires - the deferred temp is already gone.
      root._releaseFlow(Number(uid))
      return pend !== null
    }
    if (pend !== null && p !== pend.final) {
      // Saved somewhere the flow did not reserve. The file exists and is
      // the user's, so nothing is deleted; the flow still releases, because
      // the reserved temp has been consumed and there is nothing left to
      // wait for.
      root._releaseFlow(Number(uid))
      return false
    }
    root.lastPath = p
    root.captured(p)
    root._releaseFlow(Number(uid))
    return true
  }

  function noteCancelled(uid) {
    if (Number(uid) !== root._editorUid || root._editorUid < 0) return false
    const pend = root._pendingAnnotate
    root._pendingAnnotate = null
    root._editorOpen = false
    root._forgetEditorRequest()
    const flowId = Number(uid)
    root._editorUid = -1
    if (pend !== null) {
      Exec.rm(pend.temp)
      root._forgetPath(pend.temp)
    }
    // A discard is a user action, not a failure: the deferred temp is dropped
    // and lastPath rolls back, which is the difference between "the user has a
    // screenshot" and "the user dismissed a dialog".
    root.lastPath = pend !== null ? pend.prev : root.lastPath
    root._releaseFlow(flowId)
    return true
  }

  // One pending start. A capture that arrives before the runtime directory
  // exists parks here rather than guessing, so the wait is bounded to one
  // call.
  function _queueStart(callback) {
    if (root._queuedStart !== null) return false
    root._queuedStart = callback
    return true
  }

  // The runtime directory gates the first capture; the orphan sweep and
  // the fallback prune run in the background as best-effort, so a slow
  // sweep is not a slow first screenshot. The prune always runs and
  // excludes only the active path: wl-paste feeds the exclusion alone and
  // never gates the time-based sweep.
  function _initRuntime() {
    const current = Quickshell.processId
    const clipboardPath = ShotLib.pathFromFileUrl(String(Quickshell.clipboardText ?? ""))
    const activeFallback = clipboardPath.startsWith(root.fallbackDir + "/")
      ? ShotLib.sq(clipboardPath) : "''"
    const mkdirScript = "set -eu; rt=" + ShotLib.sq(Paths.vibraniumRuntime)
      + "; fb=" + ShotLib.sq(root.fallbackDir)
      + "; mkdir -p -- \"$rt/screenshots-" + current + "\" \"$fb\""
    const sweepScript = "set -eu; rt=" + ShotLib.sq(Paths.vibraniumRuntime)
      + "; fb=" + ShotLib.sq(root.fallbackDir)
      + "; active=" + activeFallback + "; "
      + "if uri=$(wl-paste --type text/uri-list 2>/dev/null | head -n 1); then "
      + "case \"$uri\" in file://*) p=${uri#file://}; p=${p#localhost}; "
      + "case \"$p\" in \"$fb\"/*) active=\"$p\";; esac;; esac; fi; "
      + "for d in \"$rt\"/screenshots-*; do [ -d \"$d\" ] || continue; "
      + "pid=${d##*-}; [ \"$pid\" = \"" + current + "\" ] && continue; "
      + "kill -0 \"$pid\" 2>/dev/null || rm -rf -- \"$d\"; done; "
      + "if [ -n \"$active\" ]; then find \"$fb\" -type f -mmin +1440 ! -path "
      + "\"$active\" -delete 2>/dev/null || true; "
      + "else find \"$fb\" -type f -mmin +1440 -delete 2>/dev/null || true; fi"
    const sweepArgv = Exec.setsidTimeoutCmd(["sh", "-c", sweepScript], 15)
    const sweepProc = startupComp.createObject(root, { command: sweepArgv })
    if (sweepProc !== null) {
      sweepProc.exited.connect((code) => { sweepProc.destroy() })
      sweepProc.running = true
    }
    const argv = Exec.setsidTimeoutCmd(["sh", "-c", mkdirScript], 15)
    const proc = startupComp.createObject(root, { command: argv })
    if (proc === null) {
      root._runtimeFailed = true
      root._daemonNotify("Screenshot", "Runtime directory initialization failed")
      return
    }
    root._startupProcess = proc
    proc.exited.connect((code) => {
      proc.destroy()
      if (root._startupProcess === proc) root._startupProcess = null
      if (code !== 0) {
        root._runtimeFailed = true
        root._queuedStart = null
        root._daemonNotify("Screenshot", "Runtime directory initialization failed")
        return
      }
      root._runtimeReady = true
      const queued = root._queuedStart
      root._queuedStart = null
      if (typeof queued === "function") queued()
    })
    proc.running = true
  }

  Component.onCompleted: {
    Registry.register("screenshots", { noteSaved: root.noteSaved, noteCancelled: root.noteCancelled })
    root._initRuntime()
  }

  Component.onDestruction: {
     root._cancelActiveFlow("shutdown")
     SurfaceClaim.releaseOwner(root)
     if (root._startupProcess !== null) {
       root._killProcess(root._startupProcess, "startup")
       root._startupProcess = null
     }
    Registry.unregister("screenshots")
  }

  // Monotonic capture sequence: fileStem() resolves seconds, so two
  // captures within one second would share a name without this.
  property int _shotSeq: 0

  function _nextStem() {
    root._shotSeq++
    return ShotLib.fileStem() + "-" + root._sessionId + "-" + root._shotSeq
  }

  property var _activeShot: null

  // Region selection (spec 11). The selector itself is an on-demand view
  // behind the neutral contract; what stays here is the flow state around
  // it - the seed file, the live grab job and the accepted regions that
  // flow back into the shot-window pipeline as crops. One at a time, like
  // captures.
  property var _regionSeed: null
  property var _liveRegion: null
  property var _pendingCrop: null  // logical { x, y, w, h }, consumed by _finish

  // Echo guard: shortcut triggers occasionally fire twice within
  // milliseconds. 100ms drops the echo but passes the picker's
  // immediate continuation and any human re-press.
  property double _lastStartMs: 0

  function _debounced(what) {
    const now = Date.now()
    if (now - root._lastStartMs < 100) return true
    root._lastStartMs = now
    return false
  }

  function _destroyPicker() {
    if (!ShotLib.requestLive(root._pickerRequest, root._pickerRequest)) return
    AnnotationActions.close(root._pickerRequest)
    root._pickerRequest = 0
  }

  // The seed frame is on disk and the selector is opening over it. This is
  // the point where the flow stops being a capture and becomes a
  // conversation with the user.
  function _openRegionSeed(job) {
    if (Number(job.flowId) !== root._activeFlow || !root._screenValid(job.screen)
      || !root._ownedPaths.includes(String(job.path))) {
      root._removeJobPaths(job.path, "")
      root._releaseFlow(Number(job.flowId))
      return
    }
    const seed = {
      id: job.id, jobId: job.jobId, path: job.path, url: Paths.toFileUrl(job.path),
      frameW: job.frameW, frameH: job.frameH, screen: job.screen,
      config: job.config, flowId: job.flowId
    }
    const opened = AnnotationActions.request("region", {
      screen: seed.screen, url: seed.url, frameW: seed.frameW, frameH: seed.frameH,
      immediate: false, jobId: seed.jobId, flowId: seed.flowId
    })
    if (!opened.ok) {
      root._removeJobPaths(seed.path, "")
      root._daemonNotify("Screenshot", "Region selector unavailable")
      root._releaseFlow(seed.flowId)
      return
    }
    root._regionSeed = seed
    root._regionRequest = opened.id
  }

  // The live branch: the selector grabs its own frame, so the service's
  // shot window is not involved at all and the frame has no size until the
  // selector reports one.
  function _openLiveRegion(target) {
    root._jobSeq++
    const jobId = root._jobSeq
    root._activeJob = jobId
    const opened = AnnotationActions.request("region", {
      screen: target, url: "", frameW: 0, frameH: 0,
      immediate: true, jobId: jobId, flowId: root._activeFlow
    })
    if (!opened.ok) {
      root._activeJob = 0
      root._releaseFlow(root._activeFlow)
      return false
    }
    root._liveRegion = {
      jobId: jobId, flowId: root._activeFlow, screen: target,
      config: {
        fileType: root.fileType, saveToDisk: root.saveToDisk,
        autoAnnotate: root.autoAnnotate, showNotification: root.showNotification
      }
    }
    root._regionRequest = opened.id
    return true
  }

  // Editor instance sequence: pairs annotate() opens with editor requests.
  property int _editorSeq: 0

  // The picker is a toggle, so a second call is a dismissal rather than a
  // second capture. The region selector is the same: either entry point
  // dismisses whichever selection surface is already up, so a shortcut
  // pressed over an open picker never looks dead.
  function openPicker() {
    if (!root._runtimeReady) {
      if (root._runtimeFailed) return false
      return root._queueStart(() => root.openPicker())
    }
    if (root._pickerRequest !== 0) {
      const flowId = root._activeFlow
      root._destroyPicker()
      root._releaseFlow(flowId)
      return true
    }
    if (root._pendingPick !== null) {
      const flowId = root._pendingPick.flowId
      root._pendingPick = null
      root._releaseFlow(flowId)
      return true
    }
    if (root._regionRequest !== 0 || root._liveRegion !== null) {
      root._cancelActiveFlow("toggle-dismissed")
      return true
    }
    if (root._debounced("picker")) return false
    const flowId = root._claimFlow("picker")
    if (flowId === 0) return false
    const s = root._targetScreen()
    if (!s) {
      root._releaseFlow(flowId)
      return false
    }
    const opened = AnnotationActions.request("picker", { screen: s })
    if (!opened.ok) {
      root._releaseFlow(flowId)
      return false
    }
    root._pickerRequest = opened.id
    return true
  }

  // One router for every annotation outcome. A result is matched against
  // the request the service is holding, so an answer for a request it
  // already released - a view that outlived its flow - is dropped instead
  // of running against the flow that replaced it.
  function _onViewSettled(id, outcome) {
    if (id === root._pickerRequest) root._pickerOutcome(id, outcome)
    else if (id === root._regionRequest) root._regionOutcome(id, outcome)
    else if (id === root._editorRequest) root._editorOutcome(id, outcome)
  }

  // A choice arms the next step rather than running it: the picker goes
  // first, then the pending pick runs on a fresh tick so the overlay's
  // exclusive surface is unmapped before a new one is claimed. Deferred
  // through Qt.callLater, not a 0ms Timer: one deferred call needs no
  // timer object, and clearing _pendingPick disarms it (the runner
  // returns on a null pending, so no stop is needed).
  function _runPendingPick() {
    const pending = root._pendingPick
    root._pendingPick = null
    if (pending === null) return
    if (pending.flowId !== root._activeFlow || !root._screenValid(pending.screen)) {
      root._releaseFlow(pending.flowId)
      return
    }
    if (pending.mode === "region") root.openRegionSelect(pending.screen, pending.flowId, true)
    else if (pending.mode === "screen") root.capture(pending.mode, pending.screen, pending.flowId)
  }

  function _pickerOutcome(id, outcome) {
    if (id !== root._pickerRequest) return
    const code = String(outcome.code)
    if (code === "chosen") {
      const request = AnnotationActions.spec(id)
      const pickerScreen = request !== null ? request.screen : root._targetScreen()
      const flowId = root._activeFlow
      root._destroyPicker()
      root._pendingPick = { mode: String(outcome.mode), screen: pickerScreen, flowId: flowId }
      Qt.callLater(() => root._runPendingPick())
      return
    }
    if (code === "cancelled" || code === "closed") {
      const flowId = root._activeFlow
      root._destroyPicker()
      root._releaseFlow(flowId)
    }
  }

  property var _pendingPick: null

  // Open the annotator over a finished shot. File mode (path given) or
  // last-shot mode (path empty). The editor is a fullscreen overlay, so
  // it needs the target screen like the region selector does. Deferred
  // captures hand it the final save path plus the disk flag; direct
  // opens use Save As. One editor at a time: a second
  // Exclusive overlay fights the first for focus and configure.
  //
  // The probe below is a child because Quickshell 0.3.1 has no stat
  // primitive: `test -f && test -r` answers "is this a readable regular
  // file" in one fork, and a non-zero exit here becomes the user's "Image
  // not found" toast. A file that is present but unreadable also exits
  // non-zero, which is why `readable` and not only the code are the
  // answer - the two are different mistakes with the same symptom.
  function _statRegularFile(path, done) {
    const argv = Exec.setsidTimeoutCmd(["sh", "-c",
      "test -f \"$1\" && test -r \"$1\"", "sh", path], 2)
    const proc = statComp.createObject(root, { command: argv })
    if (proc === null) {
      done(false)
      return
    }
    root._sourceStatProcess = proc
    proc.exited.connect(code => {
      if (root._sourceStatProcess !== proc) {
        proc.destroy()
        return
      }
      proc.destroy()
      root._sourceStatProcess = null
      done(code === 0)
    })
    proc.running = true
  }

  function _createEditor(target, flowId) {
    const pend = root._pendingAnnotate
    if (pend !== null && Number(pend.flowId) !== flowId) {
      root._releaseFlow(flowId)
      return false
    }
    const s = pend !== null ? pend.screen : root._targetScreen()
    if (!root._screenValid(s)) {
      root._releaseFlow(flowId)
      return false
    }
    const direct = pend === null
    const savePath = !direct && pend.temp === target ? pend.final : ""
    const config = pend !== null ? pend.config : {
      fileType: root.fileType, saveToDisk: true,
      autoAnnotate: root.autoAnnotate, showNotification: root.showNotification
    }
    root._editorSeq++
    const opened = AnnotationActions.request("editor", {
      shotPath: target, savePath: savePath, saveToDisk: direct ? true : config.saveToDisk,
      fileType: config.fileType, runtimeDir: root.runtimeDir, directSource: direct,
      screen: s, flowId: flowId, showNotification: config.showNotification === true
    })
    if (!opened.ok) {
      if (root._activeFlow === flowId) root._cancelActiveFlow("editor-unavailable")
      else root._releaseFlow(flowId)
      return false
    }
    root._editorRequest = opened.id
    root._editorUid = flowId
    root._editorOpen = true
    return true
  }

  // The annotator entry point. Two shapes: a path (annotate this file) and
  // no path (annotate the last shot). The path form runs two probes
  // before the editor opens - a `FileView` read and then the child `test`
  // - and both refusals report separately, because "the file is not
  // there" and "the file is there and unreadable" produce the same toast
  // and are different problems.
  function annotate(path, existingFlow) {
    if (!root._runtimeReady) {
      if (root._runtimeFailed || Number(existingFlow) > 0) return false
      return root._queueStart(() => root.annotate(path, existingFlow))
    }
    if (root.sessionLocked) {
      root._daemonNotify("Screenshot", "Screenshots are unavailable while locked")
      root._abortSuppliedFlow(existingFlow)
      return false
    }
    if (root._flow !== "" && Number(existingFlow) !== root._activeFlow) return false
    const p = String(path === undefined ? "" : path)
    const target = p !== "" ? p : root.lastPath
    if (target === "") {
      root._abortSuppliedFlow(existingFlow)
      return false
    }
    if (p !== "" && !target.startsWith("/")) {
      root._notifyError("Image path")
      root._abortSuppliedFlow(existingFlow)
      return false
    }
    if (p !== "") {
      sourceProbe.path = ""
      sourceProbe.path = target
      const ok = sourceProbe.waitForJob()
      if (!ok || !sourceProbe.loaded) {
        sourceProbe.path = ""
        root._notifyError("Image")
        root._abortSuppliedFlow(existingFlow)
        return false
      }
    }
    const suppliedFlow = Number(existingFlow) || 0
    const flowId = suppliedFlow > 0 ? suppliedFlow : root._claimFlow("editor")
    if (flowId === 0 || root._activeFlow !== flowId) {
      root._abortSuppliedFlow(suppliedFlow)
      return false
    }
    if (p === "") return root._createEditor(target, flowId)
    root._statRegularFile(target, ok => {
      if (flowId !== root._activeFlow) return
      if (!ok) {
        root._notifyError("Image")
        root._releaseFlow(flowId)
        return
      }
      root._createEditor(target, flowId)
    })
    return true
  }

  function openRegionSelect(screen, existingFlow, immediate) {
    if (!root._runtimeReady) {
      if (root._runtimeFailed || Number(existingFlow) > 0) return false
      return root._queueStart(() => root.openRegionSelect(screen, existingFlow, immediate))
    }
     if (Number(existingFlow) > 0 && root._activeFlow !== Number(existingFlow)) return false
     if (!(Number(existingFlow) > 0)
       && (root._regionRequest !== 0 || root._liveRegion !== null
         || root._pickerRequest !== 0 || root._pendingPick !== null)) {
       root._cancelActiveFlow("toggle-dismissed")
       return true
     }
     if (Number(existingFlow) === 0 && immediate !== true && root._debounced("region")) return false
     const flowId = Number(existingFlow) > 0 ? Number(existingFlow) : root._claimFlow("region")
     if (flowId === 0) return false
     const target = screen !== undefined && screen !== null ? screen : root._targetScreen()
     if (!root._screenValid(target)) {
      root._releaseFlow(flowId)
      return false
    }
     if (immediate === true) return root._openLiveRegion(target)
     root._armShot(target, "region-seed", false)
     return true
  }

  // A window closed from outside the editor's own save and cancel paths.
  // The editor answers those through the Registry, so what is left here is
  // the cancel half of the bookkeeping plus the release of the request.
  function _editorOutcome(id, outcome) {
    if (id !== root._editorRequest) return
    if (String(outcome.code) !== "closed") return
    Registry.call("screenshots", "noteCancelled", root._editorUid)
    AnnotationActions.close(id)
    root._editorRequest = 0
  }

  function _discardRegionSeed() {
    const seed = root._regionSeed
    root._regionSeed = null
    if (seed !== null) root._removeJobPaths(seed.path, "")
  }

  function _captureSeedRegion(x, y, w, h, seed, expectedJobId) {
    if (seed === null) {
      root._discardRegionSeed()
      root._releaseFlow(root._activeFlow)
      return false
    }
    const flowId = Number(seed.flowId) || 0
    const jobId = Number(expectedJobId) || 0
    if (root._regionSeed !== seed
      || !ShotLib.jobLive(jobId, root._activeJob, flowId, root._activeFlow)) return false
    if (w <= 1 || h <= 1) {
      // A click rather than a drag. `RectMath.clampRect` below floors a
      // sub-2px rect to 1x1, so the unclamped request is what tells "the
      // selection was 0x0" apart from "the selection was 1x1 and the clamp
      // floored it".
      root._discardRegionSeed()
      root._activeJob = 0
      root._releaseFlow(flowId)
      return false
    }
    if (!root._screenValid(seed.screen)) {
      root._discardRegionSeed()
      root._activeJob = 0
      root._releaseFlow(flowId)
      root._daemonNotify("Screenshot", "Screen disconnected")
      return false
    }
    const config = seed.config
    const suffix = ShotLib.suffixFor(config.fileType)
    const defer = config.autoAnnotate
    const stem = root._nextStem()
    const cropDst = defer ? root.runtimeDir + "/pending-" + stem + "." + suffix
      : config.saveToDisk ? Paths.screenshotsDir + "/" + stem + "." + suffix
      : root.runtimeDir + "/clipboard-" + stem + "." + suffix
    const finalPath = defer && config.saveToDisk
      ? Paths.screenshotsDir + "/" + stem + "." + suffix : ""
    const crop = RectMath.clampRect({
      x: x, y: y, w: w, h: h
    }, seed.frameW, seed.frameH)
    root._regionSeed = null
    root._ownPath(cropDst)
    root._finishTail({
      id: seed.id, jobId: jobId, win: null, mode: "region", path: seed.path,
      crop: crop, cropTo: cropDst, defer: defer, finalPath: finalPath,
      config: config, flowId: flowId, screen: seed.screen,
      frameW: seed.frameW, frameH: seed.frameH
    })
    return true
  }

  Connections {
    target: Ui

    function onValidScreensChanged() {
      root._screenSetChanged()
    }
  }

  // The one place an annotation answer enters this file. The contract
  // fires it synchronously from the controller's own signal handler, so
  // the crop pipeline and the flow bookkeeping below still run on the tick
  // the selector or the editor produced.
  Connections {
    target: AnnotationActions

    function onSettled(id, outcome) {
      root._onViewSettled(Number(id), outcome)
    }
  }

  // The request id is the identity: the record behind it carries the job
  // and flow identity, and the seed url the seeded branch matched on.
  function _regionIdentityValid(id, seed) {
    if (!ShotLib.requestLive(id, root._regionRequest)) return false
    const request = AnnotationActions.spec(id)
    if (request === null) return false
    if (seed === null) {
      return ShotLib.liveRegionIdentity(root._liveRegion, request, root._activeFlow)
    }
    return ShotLib.seedRegionIdentity(seed, root._regionSeed, request, root._activeFlow)
  }

  // Releasing the request is what tears the selector down, so every
  // terminal path ends here and none of them references a view.
  function _closeRegion(id) {
    if (!ShotLib.requestLive(id, id)) return
    AnnotationActions.close(id)
    if (root._regionRequest === id) root._regionRequest = 0
  }

  function _regionOutcome(id, outcome) {
    if (id !== root._regionRequest) return
    const code = String(outcome.code)
    if (code === "accepted") root._regionAccepted(id, outcome)
    else if (code === "cancelled") root._regionCancelled(id)
    else if (code === "failed") root._regionFailed(id, String(outcome.reason ?? ""))
  }

  // An accepted rect is window-logical. The live branch cuts it out of the
  // frame the selector grabbed, the seeded branch out of the seed file
  // this flow already saved; both release the selector before the crop
  // runs, because nothing else in the flow needs it.
  function _regionAccepted(id, outcome) {
    const request = AnnotationActions.spec(id)
    const seed = root._regionSeed
    const x = Number(outcome.x) || 0
    const y = Number(outcome.y) || 0
    const w = Number(outcome.w) || 0
    const h = Number(outcome.h) || 0
    if (root._liveRegion !== null) {
      const live = root._liveRegion
      if (!root._regionIdentityValid(id, null) || request === null
        || !root._screenValid(live.screen) || !root._screenValid(request.screen)) {
        root._closeRegion(id)
        root._liveRegion = null
        root._activeJob = 0
        root._releaseFlow(live.flowId)
        return
      }
      const result = outcome.grab
      const frameW = Number(outcome.grabFrameW) || 0
      const frameH = Number(outcome.grabFrameH) || 0
      if (result === null || result === undefined
        || typeof result.saveToFile !== "function" || frameW <= 0 || frameH <= 0) {
        // The live branch's preview never became a grab result. This is the
        // failure the user sees as "Region preview not ready": a missing
        // grab handle and a 0-sized frame are different bugs with one toast.
        root._closeRegion(id)
        root._liveRegion = null
        root._activeJob = 0
        root._daemonNotify("Screenshot", "Region preview not ready")
        root._releaseFlow(live.flowId)
        return
      }
      const full = root.runtimeDir + "/live-region-" + root._nextStem() + ".png"
      root._ownPath(full)
      // The selector's own grab, saved by us. It is a full-screen frame
      // and the region is cut out of it afterwards, so the file written
      // here is always the whole screen and the crop below is what cuts
      // the selection out of it.
      const ok = result.saveToFile(full)
      const liveSeed = {
        id: live.jobId, jobId: live.jobId, path: full, url: Paths.toFileUrl(full),
        frameW: frameW, frameH: frameH, screen: live.screen,
        config: live.config, flowId: live.flowId
      }
      root._closeRegion(id)
      root._liveRegion = null
      root._regionSeed = liveSeed
      if (!ok) {
        root._regionSeed = null
        root._removeJobPaths(full, "")
        root._activeJob = 0
        root._daemonNotify("Screenshot", "Region preview save failed")
        root._releaseFlow(live.flowId)
        return
      }
      root._ensureOutputDir(
        () => root._captureSeedRegion(x, y, w, h, liveSeed, live.jobId),
        live.config.saveToDisk, live.flowId, live.jobId, live.screen)
      return
    }
    if (!root._regionIdentityValid(id, seed) || seed === null || request === null
      || !root._screenValid(seed.screen) || !root._screenValid(request.screen)) {
      if (seed !== null && root._regionRequest === id && root._regionSeed === seed) {
        root._closeRegion(id)
        root._discardRegionSeed()
        root._activeJob = 0
        root._releaseFlow(seed.flowId)
        if (!root._screenValid(seed.screen)) {
          root._daemonNotify("Screenshot", "Screen disconnected")
        }
      }
      return
    }
    // The seeded branch mints a NEW job for the crop that follows.
    root._closeRegion(id)
    root._jobSeq++
    const jobId = root._jobSeq
    root._activeJob = jobId
    root._ensureOutputDir(
      () => root._captureSeedRegion(x, y, w, h, seed, jobId), seed.config.saveToDisk,
      seed.flowId, jobId, seed.screen)
  }

  function _regionCancelled(id) {
    const seed = root._regionSeed
    if (root._liveRegion !== null) {
      const live = root._liveRegion
      if (!root._regionIdentityValid(id, null)) return
      // No file has been written at this point in the live branch: the
      // selector was cancelled before it handed back a grab result.
      root._closeRegion(id)
      root._liveRegion = null
      root._activeJob = 0
      root._releaseFlow(live.flowId)
      return
    }
    if (!root._regionIdentityValid(id, seed)) return
    // The seeded branch has a file on disk by this point, and discarding the
    // seed is what removes it.
    root._closeRegion(id)
    root._discardRegionSeed()
    root._releaseFlow(seed.flowId)
  }

  function _regionFailed(id, reason) {
    // A request with no record has no view: the controller that owned it
    // is gone, so nothing will settle it again and the flow is released
    // here instead of staying claimed for a surface that is not there.
    if (AnnotationActions.spec(id) === null) {
      root._closeRegion(id)
      root._liveRegion = null
      root._activeJob = 0
      root._discardRegionSeed()
      root._releaseFlow(root._activeFlow)
      return
    }
    const seed = root._regionSeed
    if (root._liveRegion !== null) {
      const live = root._liveRegion
      if (!root._regionIdentityValid(id, null)) return
      root._closeRegion(id)
      root._liveRegion = null
      root._activeJob = 0
      root._daemonNotify("Screenshot", reason)
      root._releaseFlow(live.flowId)
      return
    }
    if (!root._regionIdentityValid(id, seed)) return
    root._closeRegion(id)
    root._discardRegionSeed()
    root._daemonNotify("Screenshot", reason)
    root._releaseFlow(seed.flowId)
  }

  // Arm the persistent shot window for one capture: retarget, show (the
  // null -> target captureSource swap opens a fresh recording context, so
  // the attempt loop below always sees a new frame), run.
  //
  // The geometry goes on the arm line rather than on the grab line because
  // this is where the screen and both scale ratios are decided: the
  // compositor scale that maps a selection onto frame pixels, and the
  // window DPR that sizes the grab target. They are different numbers and
  // a capture cut to the wrong grid looks like a soft screenshot rather
  // than like a bug.
  function _armShot(targetScreen, mode, immediate) {
    root._jobSeq++
    root._activeJob = root._jobSeq
    shotWin.targetScreen = targetScreen
    shotWin.mode = mode
    shotWin.jobId = root._activeJob
    shotWin.config = {
      fileType: root.fileType,
      saveToDisk: root.saveToDisk,
      autoAnnotate: root.autoAnnotate,
      showNotification: root.showNotification
    }
    root._shotScreen = targetScreen
    root._activeShot = shotWin
    root._beginFrame(shotWin, immediate)
  }

  // The whole-screen capture entry point. Every refusal here is a
  // transition a user can see - a key that did nothing.
  //
  // `keepSurfaces` is the mode that photographs the screen as it stands;
  // see _claimFlow. It is honoured only on a flow this call starts, so a
  // flow handed in from the picker handoff keeps the flag it was claimed
  // with rather than one passed to the wrong stage.
  function capture(mode, screen, existingFlow, immediate, keepSurfaces) {
    if (!root._runtimeReady) {
      if (root._runtimeFailed || Number(existingFlow) > 0) return false
      return root._queueStart(() => root.capture(mode, screen, existingFlow, immediate, keepSurfaces))
    }
     const supplied = Number(existingFlow) || 0
     if (supplied > 0 && root._activeFlow !== supplied) return false
     if (supplied === 0 && immediate !== true && root._debounced("capture")) return false
     const flowId = supplied > 0 ? supplied : root._claimFlow("capture", keepSurfaces)
     if (flowId === 0) return false
     const targetScreen = screen !== undefined && screen !== null
       ? screen : root._targetScreen()
     if (!root._screenValid(targetScreen)) {
      root._releaseFlow(flowId)
      return false
    }
    root._pendingAnnotate = null
    root._armShot(targetScreen, mode, immediate === true)
    return true
  }

  // Start the compositor's screencopy. The immediate shape fires one
  // capture on the next tick and then polls; the ordinary one starts
  // polling straight away at a shorter interval. Both are bounded by the
  // attempt count below, so neither can spin. Delivery itself is
  // signal-driven (onHasContentChanged -> _settleFrame); the poll only
  // re-requests.
  function _beginFrame(win, immediate) {
    win.view.attempts = 0
    frameTimer.win = win
    if (immediate === true) {
      frameTimer.interval = root.framePollMs
      Qt.callLater(() => {
        if (frameTimer.win !== win || win.view === null) return
        win.view.captureFrame()
        frameTimer.restart()
      })
      return
    }
    frameTimer.interval = root.frameFirstPollMs
    frameTimer.restart()
  }

  // Settle one grabbed frame: deliver it when the job is still live,
  // fail it otherwise. Single home for the liveness check and the
  // timeout branch, called from the poll and from the content signal
  // alike so the two can never disagree on the verdict.
  function _settleFrame(win) {
    if (win === null) return false
    const jobId = Number(win.jobId) || 0
    const flowId = Number(root._activeFlow) || 0
    if (!ShotLib.jobLive(jobId, root._activeJob, flowId, root._activeFlow)) return false
    win.view.attempts = 0
    if (win.view.hasContent) {
      root._deliver(win, jobId, flowId)
    } else {
      root._fail(win, "frame never arrived", flowId, jobId)
    }
    return true
  }

  // Frame poll bounds, named: first poll faster, then the retry cadence.
  readonly property int frameFirstPollMs: 120
  readonly property int framePollMs: 250
  Timer {
    id: frameTimer

    property var win: null
    interval: root.frameFirstPollMs
    repeat: true
    running: false
    onTriggered: {
      const win = frameTimer.win
      if (win === null) {
        frameTimer.stop()
        return
      }
      const jobId = Number(win.jobId) || 0
      const flowId = Number(root._activeFlow) || 0
      if (!ShotLib.jobLive(jobId, root._activeJob, flowId, root._activeFlow)) {
        frameTimer.stop()
        return
      }
      if (win.view.hasContent || win.view.attempts >= 8) {
        frameTimer.stop()
        root._settleFrame(win)
        return
      }
      // The poll itself: up to eight re-requests per capture. The
      // interval settles to the retry cadence after the first poll.
      win.view.attempts++
      win.view.captureFrame()
      frameTimer.interval = root.framePollMs
    }
  }

  // Keeps the grab result alive across the async save.
  property var _grabResult: null

  property var _pendingFinish: null  // { win, mode, url }
  property int _decodeAttempts: 0

  function _deliver(win, expectedJobId, expectedFlowId) {
    root._decodeAttempts = 0
    root._grabView(win, expectedJobId, expectedFlowId)
  }

  // Grab watchdog bound, named: a grab whose callback never arrives
  // fails here instead of hanging the capture.
  readonly property int grabWatchdogMs: 2500
  Timer {
    id: grabWatchdog

    interval: root.grabWatchdogMs
    property var win: null
    property int jobId: 0
    property int flowId: 0
    onTriggered: {
      const win = grabWatchdog.win
      const jobId = grabWatchdog.jobId
      const flowId = grabWatchdog.flowId
      grabWatchdog.win = null
      grabWatchdog.jobId = 0
      grabWatchdog.flowId = 0
      if (!ShotLib.jobLive(jobId, root._activeJob, flowId, root._activeFlow)) return
      // `grabToImage` accepted the call and its callback never arrived.
      // That is distinct from a grab that was refused outright, and it is
      // the one that hangs a capture if the watchdog is ever wrong.
      root._fail(win, "grab callback timed out", flowId, jobId)
    }
  }

  // Qt multiplies targetSize by its effective DPR. Convert the physical
  // screencopy source size into that target space before grabbing.
  function _grabView(win, expectedJobId, expectedFlowId) {
    const requestedJobId = Number(expectedJobId) || 0
    const requestedFlowId = Number(expectedFlowId) || 0
    const jobId = requestedJobId > 0 ? requestedJobId : Number(win.jobId) || 0
    const flowId = requestedFlowId > 0 ? requestedFlowId : Number(root._activeFlow) || 0
    if (!ShotLib.jobLive(jobId, root._activeJob, flowId, root._activeFlow)
      || Number(win.jobId) !== jobId) return
    const mode = String(win.mode)
    const source = ShotLib.grabSourceSize(win.view.width, win.view.height, win.dpr,
      win.view.sourceSize.width, win.view.sourceSize.height)
    const target = ShotLib.grabTargetSize(source.width, source.height, win.view.reportedDpr)
    grabWatchdog.win = win
    grabWatchdog.jobId = jobId
    grabWatchdog.flowId = flowId
    grabWatchdog.restart()
    // The two sizes are the whole point of this function and they are not
    // the same number. `source` is the physical screencopy frame Qt will
    // read; `target` is what `grabToImage` is asked to render at, which Qt
    // multiplies by the window's own DPR before writing. Getting the second
    // one wrong saves a fraction of the frame, and the symptom is a soft
    // screenshot rather than an error.
    const grab = win.view.grabToImage(result => {
      if (!ShotLib.jobLive(jobId, root._activeJob, flowId, root._activeFlow)
        || Number(win.jobId) !== jobId) {
        if (grabWatchdog.jobId === jobId && grabWatchdog.flowId === flowId) {
          grabWatchdog.stop()
          grabWatchdog.win = null
          grabWatchdog.jobId = 0
          grabWatchdog.flowId = 0
        }
        return
      }
      grabWatchdog.stop()
      grabWatchdog.win = null
      grabWatchdog.jobId = 0
      grabWatchdog.flowId = 0
      const url = result !== null && result !== undefined && result.url !== undefined
        ? String(result.url) : ""
      if (url === "") {
        // Qt accepted the grab and produced a result with no url. "No result
        // at all" and "a result with no url" are different failures, and both
        // arrive here.
        root._fail(win, "grab failed", flowId, jobId)
        return
      }
      root._grabResult = result
      root._pendingFinish = {
        win: win, mode: mode, url: url, jobId: jobId, flowId: flowId
      }
      root._mark("decode")
      win.frameProbe.source = url
      decodeTimer.restart()
    }, Qt.size(target.width, target.height))
    if (!grab) {
      // Refused synchronously: nothing was scheduled and the watchdog is
      // the only thing still running, so it is stopped here rather than
      // left to fire a second, misleading failure.
      grabWatchdog.stop()
      grabWatchdog.win = null
      grabWatchdog.jobId = 0
      grabWatchdog.flowId = 0
      root._fail(win, "grabToImage refused", flowId, jobId)
    }
  }

  // Fires when a grabbed URL never decodes. Re-grabs the live view (its
  // frame keeps flowing) up to two extra attempts, then fails loudly -
  // never stalls. Named bound like the grab watchdog above.
  readonly property int decodeWatchdogMs: 2500
  Timer {
    id: decodeTimer

    interval: root.decodeWatchdogMs
    onTriggered: {
      if (root._pendingFinish === null) return
      const pending = root._pendingFinish
      const jobId = Number(pending.jobId) || 0
      const flowId = Number(pending.flowId) || 0
      if (!ShotLib.jobLive(jobId, root._activeJob, flowId, root._activeFlow)) {
        root._pendingFinish = null
        root._grabResult = null
        if (pending.win !== null && pending.win !== undefined) pending.win.frameProbe.source = ""
        return
      }
      const win = pending.win
      if (root._decodeAttempts >= 2) {
        root._fail(win, "frame decode stalled", flowId, jobId)
        return
      }
      // A retry re-grabs from scratch: three grabs for one capture is a
      // decode problem, not a busy compositor.
      root._decodeAttempts++
      root._pendingFinish = null
      root._grabResult = null
      win.frameProbe.source = ""
      root._grabView(win, jobId, flowId)
    }
  }

  function _finish(win, probeImage, expectedJobId, expectedFlowId) {
    const pending = root._pendingFinish
    const jobId = Number(expectedJobId) || 0
    const flowId = Number(expectedFlowId) || 0
    if (pending === null || pending.win !== win
      || !ShotLib.jobLive(jobId, root._activeJob, flowId, root._activeFlow)
      || Number(pending.jobId) !== jobId || Number(pending.flowId) !== flowId
      || Number(win.jobId) !== jobId) return
    const mode = String(pending.mode)
    const screen = win.targetScreen
    const currentConfig = win.config !== null && win.config !== undefined ? win.config : {
      fileType: root.fileType, saveToDisk: root.saveToDisk,
      autoAnnotate: root.autoAnnotate, showNotification: root.showNotification
    }
    const config = {
      fileType: String(currentConfig.fileType), saveToDisk: currentConfig.saveToDisk === true,
      autoAnnotate: currentConfig.autoAnnotate === true,
      showNotification: currentConfig.showNotification === true
    }
    const result = root._grabResult
    const fw = Math.round(probeImage.implicitWidth)
    const fh = Math.round(probeImage.implicitHeight)
    const pendingCrop = root._pendingCrop
    const previousPath = root.lastPath
    // The ratio this window's logical pixels map onto the frame that was
    // just decoded, measured from the two. win.dpr is the monitor's
    // configured compositor scale, which is not the same number once Qt's
    // own ratio is in the window's logical size - and this is the grid fw
    // and fh are counted in, so it is the only one that lines up with them.
    const dpr = fw > 0 && win.view.width > 0 ? fw / win.view.width
      : (win.dpr > 0 ? win.dpr : 1)
    root._pendingFinish = null
    root._pendingCrop = null
    if (!(fw > 0 && fh > 0) || result === null || result === undefined) {
      root._fail(win, "empty frame", flowId, jobId)
      return
    }
    const ft = config.fileType
    const suffix = ShotLib.suffixFor(ft)
    const isSeed = mode === "region-seed"
    const defer = !isSeed && config.autoAnnotate
    const dir = defer ? root.runtimeDir
      : (config.saveToDisk && !isSeed ? Paths.screenshotsDir : root.runtimeDir)
    const stem = root._nextStem()
    const isRegion = !isSeed && pendingCrop !== null
    const cropDst = isRegion
      ? (defer ? root.runtimeDir + "/pending-" + stem + "." + suffix
        : config.saveToDisk ? Paths.screenshotsDir + "/" + stem + "." + suffix
        : root.runtimeDir + "/clipboard-" + stem + "." + suffix)
      : ""
    const fullTemp = isRegion ? root.runtimeDir + "/full-" + stem + "." + suffix : ""
    const path = isSeed ? root.runtimeDir + "/region-seed-" + stem + ".png"
      : isRegion ? fullTemp
      : defer ? dir + "/pending-" + stem + "." + suffix
      : config.saveToDisk ? dir + "/" + stem + "." + suffix
      : dir + "/clipboard-" + stem + "." + suffix
    const finalPath = defer && config.saveToDisk
      ? Paths.screenshotsDir + "/" + stem + "." + suffix : ""
    // The save plan, before the write. The destination decides the rest of the
    // flow - a deferred temp is consumed by the editor, a clipboard file is
    // deleted after the URI is published, and a seed is deleted when the
    // region is chosen or dismissed. `dpr` above is the measured ratio the
    // crop rect is mapped through.
    root._ownPath(path)
    if (fullTemp !== "") root._ownPath(fullTemp)
    if (cropDst !== "") root._ownPath(cropDst)
    root._ensureOutputDir(() => {
      if (!ShotLib.jobLive(jobId, root._activeJob, flowId, root._activeFlow)) {
        root._removeJobPaths(path, cropDst)
        return
      }
      if (!root._screenValid(screen)) {
        root._fail(win, "screen disconnected", flowId, jobId)
        return
      }
      if (root._grabResult !== result) {
        // The grab was superseded between the decode and the write: the
        // file is not written and the result object is gone.
        root._fail(win, "grab expired", flowId, jobId)
        return
      }
      let crop = null
      if (pendingCrop !== null) {
        // The pending rect is window-logical; the crop is cut in frame
        // pixels, so the compositor scale is applied before the clamp.
        crop = RectMath.clampRect(RectMath.scaleRect(pendingCrop, dpr), fw, fh)
      }
      const ok = typeof result.saveToFile === "function" && result.saveToFile(path)
      if (!ok) {
        root._removeJobPaths(path, cropDst)
        root._fail(win, "save failed: " + path, flowId, jobId)
        return
      }
      // The transition: the frame is on disk. Everything after it (crop,
      // clipboard, editor) can still fail.
      root._finishTail({
        id: stem, jobId: jobId, win: win, mode: mode,
        path: path, crop: crop, cropTo: cropDst,
        defer: defer, finalPath: finalPath, frameW: fw, frameH: fh,
        prev: previousPath, screen: screen, config: config, flowId: flowId
      })
    }, config.saveToDisk, flowId, jobId, screen)
  }

  // The completion toast. The copy is fixed text from ShotLib and the
  // summary names the destination.
  function _notifyDone(mode, saved) {
    root._daemonNotify(saved === true ? "Screenshot Saved" : "Screenshot Copied", ShotLib.notifyBody(mode, saved), "Screenshots")
  }

  // URI-list clipboard offer for a saved file. One-shot sources are
  // copied to the persistent fallback directory before the URI is
  // published; saved files are referenced directly. A text URI remains
  // the last-resort fallback when wl-copy is unavailable.
  function _trackCopyProcess(proc) {
    root._copyProcesses = root._copyProcesses.concat([proc])
  }

  function _untrackCopyProcess(proc) {
    root._copyProcesses = root._copyProcesses.filter(p => p !== proc)
  }

  // Stage the one-shot source into the persistent fallback directory
  // before the URI is published, so a paste target that reads the URI later
  // still finds a file. This is the only place a screenshot is copied, and
  // it runs only when `saveToDisk` is off - a saved file is referenced in
  // place and is never staged.
  function _setClipboardFallback(path, deleteAfter, fileType, owner, done, failed) {
    if (owner !== null && root._activeDelivery !== owner) return
    if (deleteAfter !== true) {
      // The last resort: a text URI in the shell's own clipboard, for when
      // wl-copy is not installed. It is a paste target that most
      // applications will not accept as an image.
      Quickshell.clipboardText = Paths.toFileUrl(path)
      if (typeof done === "function") done()
      return
    }
    root._copySeq++
    const lower = path.toLowerCase()
    const ext = lower.endsWith(".jpg") || lower.endsWith(".jpeg")
      ? "jpg" : ShotLib.suffixFor(fileType)
    const target = root.fallbackDir + "/image-" + root._sessionId + "-"
      + root._copySeq + "." + ext
    const argv = Exec.setsidTimeoutCmd(["cp",
      "--remove-destination", "--", path, target], 10)
    const proc = fallbackComp.createObject(root, { command: argv })
    if (proc === null) {
      Exec.rm(target)
      if (typeof failed === "function") failed()
      return
    }
    root._fallbackTarget = target
    root._fallbackCommitted = false
    root._trackCopyProcess(proc)
    proc.exited.connect((code) => {
      proc.destroy()
      root._untrackCopyProcess(proc)
      if (owner !== null && root._activeDelivery !== owner) {
        if (root._fallbackTarget === target) {
          root._fallbackTarget = ""
          root._fallbackCommitted = false
        }
        Exec.rm(target)
        return
      }
      if (code !== 0) {
        if (root._fallbackTarget === target) {
          root._fallbackTarget = ""
          root._fallbackCommitted = false
        }
        Exec.rm(target)
        if (typeof failed === "function") failed()
        return
      }
      // The staged copy is now the file the URI will name, so the original
      // one-shot is only removable once the offer has been published - and
      // the offer is the next call. `committed` is what a cancel between
      // here and there respects.
      root._fallbackCommitted = true
      root._copyImage(target, false, fileType, owner, () => {
        if (root._fallbackTarget === target) {
          root._fallbackTarget = ""
          root._fallbackCommitted = false
        }
        Exec.rm(path)
        if (typeof done === "function") done()
      }, failed)
    })
    proc.running = true
  }

  // The paste itself: `sh -c 'printf <uri> | wl-copy --type text/uri-list'`.
  // A URI list rather than an image, so the paste target gets a path it
  // reopens; `wl-copy` exits once the offer is taken, so a zero exit means
  // published and nothing more.
  function _copyImage(path, deleteAfter, fileType, owner, done, failed) {
    if (owner !== null && root._activeDelivery !== owner) return
    if (deleteAfter === true) {
      root._setClipboardFallback(path, deleteAfter, fileType, owner, done, failed)
      return
    }
    if (!String(path).startsWith(root.runtimeDir + "/")) root._forgetPath(path)
    const argv = Exec.setsidTimeoutCmd(ShotLib.copyImageCmd(path), 10)
    const proc = copyComp.createObject(root, { command: argv })
    if (proc === null) {
      root._setClipboardFallback(path, deleteAfter, fileType, owner, done, failed)
      return
    }
    root._trackCopyProcess(proc)
    proc.exited.connect((code) => {
      proc.destroy()
      root._untrackCopyProcess(proc)
      if (owner !== null && root._activeDelivery !== owner) return
      if (code === 0) {
        if (typeof done === "function") done()
        return
      }
      // A non-zero wl-copy is the one case where the fallback earns its
      // keep: the offer has not landed, but the capture is fine and a
      // second mechanism is about to be tried.
      root._setClipboardFallback(path, deleteAfter, fileType, owner, done, failed)
    })
    proc.running = true
  }

  function _daemonNotify(summary, body, appName = "Vibranium") {
    Exec.run(["notify-send", "-r", "3", "-t", "3000", "-a", appName,
      summary, body])
  }

  // The single loud-failure path. Every stage that cannot recover funnels
  // here: the reason is the fixed string the failing stage chose, and it is
  // the reason the toast carries too, so the two cannot disagree about what
  // happened.
  function _fail(win, reason, flowId, jobId) {
    const requestedFlow = Number(flowId) || 0
    const expectedJob = Number(jobId) || 0
    if (requestedFlow > 0 && requestedFlow !== root._activeFlow) return
    if (expectedJob > 0 && expectedJob !== root._activeJob) return
    grabWatchdog.stop()
    decodeTimer.stop()
    frameTimer.stop()
    root._pendingFinish = null
    root._decodeAttempts = 0
    root._pendingCrop = null
    if (root._pendingAnnotate !== null) {
      const pending = root._pendingAnnotate
      root._pendingAnnotate = null
      Exec.rm(pending.temp)
      root._forgetPath(pending.temp)
      root.lastPath = pending.prev
    }
    root._activeDelivery = null
    root._activeJob = 0
    root._releaseShot()
    root._grabResult = null
    root._discardRegionSeed()
    root._removeOwnedPaths()
    root._daemonNotify("Screenshot", "Capture failed: " + reason)
    root._releaseFlow(requestedFlow > 0 ? requestedFlow : root._activeFlow)
  }

  function _notifyError(label) {
    root._daemonNotify("Screenshot", label + " not found")
  }

  // ~/Pictures/Screenshots may not exist on first run (bash ran mkdir -p).
  // Quickshell has no directory primitive; probe with FileView and create
  // via mkdir -p exactly once per session when needed.
  property bool _dirChecked: false

  // The first capture of a session pays for a directory probe and
  // possibly a `mkdir`. Both are one-shot and cached in `_dirChecked`, so
  // every later capture avoids that cost.
  function _ensureOutputDir(cb, saveToDisk, expectedFlow, expectedJob, expectedScreen) {
    const needed = saveToDisk === undefined ? root.saveToDisk : saveToDisk
    const requestedFlow = Number(expectedFlow) || 0
    const requestedJob = Number(expectedJob) || 0
    const flowId = requestedFlow > 0 ? requestedFlow : Number(root._activeFlow) || 0
    const jobId = requestedJob > 0 ? requestedJob : Number(root._activeJob) || 0
    const screen = expectedScreen !== undefined ? expectedScreen : null
    if (!needed) {
      cb()
      return
    }
    if (root._dirChecked) {
      cb()
      return
    }
    dirProbe.path = Paths.screenshotsDir
    dirProbe.waitForJob()
    if (dirProbe.loaded) {
      root._dirChecked = true
      cb()
      return
    }
    const argv = Exec.setsidTimeoutCmd(["mkdir", "-p",
      Paths.screenshotsDir], 15)
    const proc = mkdirComp.createObject(root, { command: argv })
    if (proc === null) {
      root._fail(root._activeShot, "cannot create " + Paths.screenshotsDir, flowId, jobId)
      return
    }
    root._mkdirProcess = proc
    proc.exited.connect((code) => {
      const timedOut = code === 124
      proc.destroy()
      if (root._mkdirProcess === proc) root._mkdirProcess = null
      if (flowId !== root._activeFlow || jobId !== root._activeJob) return
      if (code === 0 && root._screenValid(screen)) {
        root._dirChecked = true
        cb()
      } else if (code !== 0) {
        root._fail(root._activeShot, timedOut
          ? "screenshot directory creation timed out"
          : "cannot create " + Paths.screenshotsDir, flowId, jobId)
      } else {
        // mkdir succeeded and the screen went away in the same tick. The
        // directory is now cached, so the next capture on any screen will
        // not pay for it again - which is the only thing this branch is
        // actually for.
        root._dirChecked = true
        root._fail(root._activeShot, "screen disconnected", flowId, jobId)
      }
    })
    proc.running = true
  }

  FileView {
    id: sourceProbe

    path: ""
    printErrors: false
  }

  FileView {
    id: dirProbe

    path: ""
    printErrors: false
  }

  Component {
    id: statComp

    Process {
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
  }

  Component {
    id: startupComp

    Process {
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
  }

  Component {
    id: mkdirComp

    Process {
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
  }

  // One-shot clipboard offers (see _copyImage): needs its own Process
  // to read the exit code and publish the URI-list offer.
  Component {
    id: copyComp

    Process {
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
  }

  // Region cuts (see _finishTail): needs its own Process to gate
  // delivery on the cropper's exit code.
  Component {
    id: cropComp

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

  IpcHandler {
    target: "screenshots"

    function help(command: string): string {
      return UnitIpc.help("screenshots", "Screenshots", "native capture + annotation", [
        { name: "screen", help: "capture the active screen" },
        { name: "region", help: "pick a region, then capture it" },
        { name: "picker", help: "choose region or screen" },
        { name: "asIs", help: "capture the active screen as it stands, open menus included" },
        { name: "annotate", help: "(path) open the annotation editor" },
      ], command)
    }
    function ping(): string { return "pong" }
    function status(): string {
      return JSON.stringify({
        unit: "screenshots",
        busy: root._flow !== "" || root._queuedStart !== null,
        fileType: root.fileType,
        lastPath: root.lastPath
      })
    }
    // The verbs report the verdict of the call, not the request: `ok` here
    // means a flow was claimed and the pipeline is running.
    function screen(): string {
      const ok = root.capture("screen", undefined, 0, true)
      return ok ? "ok" : "error: capture refused"
    }
    function asIs(): string {
      // No picker: this verb exists to grab the frame that is on screen
      // right now, and an overlay asking "region or screen?" between the
      // keypress and the frame is exactly the delay it is meant to skip.
      // Immediate like `screen`, so the frame is requested on the next tick.
      const ok = root.capture("screen", undefined, 0, true, true)
      return ok ? "ok" : "error: capture refused"
    }
    function region(): string {
      const ok = root.openRegionSelect(undefined, 0, true)
      return ok ? "ok" : "error: region select unavailable"
    }
    function picker(): string {
      const ok = root.openPicker()
      return ok ? "ok" : "error: picker unavailable"
    }
    function annotate(path: string): string {
      const ok = root.annotate(path)
      return ok ? "ok" : "error: nothing to annotate"
    }
    function lastShot(): string { return root.lastPath }
  }
}
