pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.common
import qs.features.wallpaper
import "../../common/capture/ShotLib.js" as ShotLib
import "WallpaperTrans.js" as Trans

// Per-screen wallpaper surface living on the background layer. Swaps run
// through one master progress value (0 -> 1) driving the configured
// transition - crossfade, edge slides, or a mask reveal (slanted swipe,
// growing circle, shrinking hole). Curves are hardcoded per kind; the
// speed preset only scales duration. The very first paint waits for the
// animation switch to resolve (HyprlandSettings.ready), then plays a
// crossfade whatever the setting says, because a bootup paints over the
// theme fill instead of an outgoing frame.
//
// The window never closes: disabled state only hides the images, keeping
// the surface alive so the right-click menu can bring the wallpaper back.
PanelWindow {
  id: win

  readonly property int fadeMs: Wallpaper.fadeMs
  readonly property string sourceUrl: Wallpaper.current !== "" ? Paths.toFileUrl(Wallpaper.current) : ""
  property bool painted: false
  property bool pendingFade: false
  property bool fading: false
  // Cold start: the animation switch resolves when
  // HyprlandSettings.ready flips (schema parse + hyprctl batch).
  // The first resolved wallpaper often lands before that, so
  // show() parks its URL here instead of snapping; a later show()
  // overwrites it, latest wins. Replayed from onAnimKnownChanged.
  // The decode starts as soon as the animation switch resolves; the fade then
  // waits for the boot's construction to finish (bootBuilt below) so it plays
  // on a quiet thread. On a boot this surface is the one that maps first - the
  // bar's module registry rides the async half (see Boot._bootVisuals) - so its
  // crossfade over the theme fill opens the entrance, and the bar's slidefade
  // follows on its own latch.
  property bool animKnown: HyprlandSettings.ready
  property string pendingUrl: ""

  // The shell's one-time boot construction has to finish before the first
  // fade starts: that construction blocks the GUI thread in turns of 100ms and
  // 150ms, and a fade running through it freezes at whatever opacity it had
  // reached and jumps ahead - measured on a cold boot as the first fade losing
  // its middle and its tail, which reads as a flicker. The theme fill holds
  // the surface until the milestone lands; a later swap is never gated.
  readonly property bool bootBuilt: DesktopLayoutState.bootConstructionSettled

  onAnimKnownChanged: win._replayPending()
  onBootBuiltChanged: win._replayPending()

  // Latest wins: a show() that arrives while either gate is closed parks its
  // url, and the gate that opens last plays it.
  function _replayPending() {
    if (!win.animKnown || !win.bootBuilt || win.pendingUrl === "") return
    const url = win.pendingUrl
    win.pendingUrl = ""
    win.show(url)
  }

  // Start the tween for a decode that already landed. Mask kinds wait a few
  // frames before the tween samples them: a cached decode lands Ready with
  // zero intervening frames, so the mask FBOs (warmed from show()) and the
  // receiver layer have never rendered and the effect samples emptiness - the
  // intermittent "swipe/circle sometimes cut or jump". Fade and slide sample
  // no mask and start at once.
  function _startPendingFade() {
    if (!win.pendingFade) return
    if (MotionPolicy.enabled && Trans.isMaskKind(win.transKind)) warmupTimer.restart()
    else    win.startTrans()
  }

  // Resolved transition kind for the in-flight swap ("" when idle).
  // `random` is resolved once per swap, never re-rolled mid-flight.
  property string transKind: ""
  property real transProgress: 1
  // Origin (0..1 in both axes) and angle (QML clockwise degrees) of the
  // swipe band, rolled per swap so every sweep opens from somewhere new.
  property real swipeCenterXFrac: 0.5
  property real swipeCenterYFrac: 0.5
  property real swipeAngleDeg: 0
  // Rolled per swap for the unified kinds: slide direction (an edge)
  // and circle mode (growing vs shrinking).
  property string slideFrom: "left"
  property bool circleGrow: true
  // Origin of the circle reveals (0..1 in both axes), rolled per swap
  // like the swipe band so discs spawn anywhere instead of dead center.
  property real discCenterXFrac: 0.5
  property real discCenterYFrac: 0.5
  // Every kind follows the selected speed preset; curves stay fixed.
  readonly property int transMs: Trans.durationFor(Trans.normalizeSpeed(Settings.value("shell.wallpaper.transitionSpeed")))

  // Theme background shows through while disabled and before the first
  // image decodes, so the surface never flashes plain black.
  color: Theme.color("background_0")
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  anchors.left: true
  anchors.right: true
  anchors.top: true
  anchors.bottom: true

  WlrLayershell.layer: WlrLayer.Background
  WlrLayershell.namespace: "vibranium:wallpaper"
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  // Empty path keeps the previous frame; only non-empty changes transition.
  onSourceUrlChanged: {
    if (win.sourceUrl === "") return
    win.show(win.sourceUrl)
  }
  Component.onDestruction: win._endSwap()

  // This screen's in-flight swap, reported to the service so next/prev IPC
  // spam is refused while any screen is still decoding or animating.
  // Idempotent: a superseding show() keeps the one active swap active, and
  // every end path (promote, error, teardown) is guarded, so a begin always
  // pairs with exactly one end.
  property bool swapActive: false
  function _beginSwap() {
    if (win.swapActive) return
    win.swapActive = true
    Wallpaper._swapBegin()
  }
  function _endSwap() {
    if (!win.swapActive) return
    win.swapActive = false
    Wallpaper._swapEnd()
    // The first fade is the boot entrance's last motion on this surface, and
    // it ends after the bar's slidefade whenever the decode lands late. See
    // DesktopLayoutState.noteBootEntrancePlayed.
    DesktopLayoutState.noteBootEntrancePlayed("wallpaper")
  }

  function transSetting() {
    return Trans.normalizeKind(Settings.value("shell.wallpaper.transition"))
  }

  // Hardcoded curve per kind (no curve selection by design). Slides
  // glide in and out (InOutCubic reads clearly non-linear across a full
  // screen); fades stay linear like before.
  function easingFor(kind, grow) {
    if (kind === "fade") return Easing.Linear
    if (kind === "swipe") return Easing.InOutCubic
    if (kind === "circle") return grow ? Easing.OutCubic : Easing.InCubic
    if (kind === "slide") return Easing.InOutCubic
    return Easing.Linear
  }

  function useMask() {
    return win.fading && Trans.isMaskKind(win.transKind)
  }

  // Decode-size buckets: the decoder re-runs on every sourceSize change,
  // so a live window-geometry binding re-decodes per pixel of resize.
  // Rounding up to 256-px steps decodes once per step instead, still at
  // device pixels (never below what the pane can show).
  function _bucketPx(n) {
    const v = Math.round(Number(n) || 0)
    if (v <= 0) return 0
    return Math.ceil(v / 256) * 256
  }

  function show(url) {
    if (!win.animKnown || !win.bootBuilt) {
      win.pendingUrl = url
      warmupTimer.stop()
      return
    }
    // A warmup waiting on the previous decode belongs to that decode: the
    // source below is replaced, so firing it later would animate pixels that
    // are already stale. The new decode arms its own warmup on Ready.
    // From here the swap is in flight until it promotes or errors, which is
    // what the service's next/prev spam gate reads.
    warmupTimer.stop()
    win._beginSwap()
    // The bootup paints over the theme fill rather than an outgoing frame, so
    // a slide or a mask reveal reads as a glitch, and `random` can hand the
    // boot an effect the user picked for later swaps. The first paint is a
    // crossfade whatever the setting says; every later swap resolves it.
    const firstPaint = !win.painted || baseImg.source.toString() === ""
    const kind = firstPaint ? "fade" : Trans.resolveKind(win.transSetting(), Math.random())
    // A fresh origin per swipe keeps every sweep opening from somewhere
    // new; circles get a fresh origin anywhere for the same reason.
    if (Trans.isSwipeKind(kind)) {
      win.swipeCenterXFrac = 0.1 + Math.random() * 0.8
      win.swipeCenterYFrac = 0.1 + Math.random() * 0.8
      win.swipeAngleDeg = Math.random() * 180
    }
    if (kind === "slide") {
      const dirs = Trans.slideDirections()
      win.slideFrom = dirs[Math.floor(Math.random() * dirs.length)]
    }
    if (kind === "circle") {
      win.circleGrow = Math.random() < 0.5
      win.discCenterXFrac = 0.1 + Math.random() * 0.8
      win.discCenterYFrac = 0.1 + Math.random() * 0.8
    }
    if (!MotionPolicy.enabled || kind === "none") {
      if (win.fading) {
        win.fading = false
        transAnim.stop()
      }
      win.transKind = ""
      win.painted = true
      // A snap still decodes behind the curtain. Assigning baseImg.source
      // directly empties the item for the whole asynchronous decode, so the
      // window color shows through until the pixmap lands - the theme
      // background flashing for the length of a 5K jpeg decode. Staging into
      // frontImg (opacity 0 while idle) leaves the outgoing image up and
      // promotes the new one in a single step once it is Ready, which is
      // what the animated path already does. Both items then name the same
      // url at the same sourceSize, so they share one QQuickPixmap and the
      // staging costs no extra decoded copy.
      win.pendingFade = true
      frontImg.source = url
      return
    }
    if (firstPaint) {
      // First paint is the bootup fade: the async decode lands through
      // frontImg's status handler, so the theme fill stays visible (never a
      // black flash) and boot never stalls on a sync decode.
      frontImg.source = url
      win.pendingFade = true
      win.painted = true
      win.transKind = kind
      return
    }
    if (win.fading) {
      win.fading = false
      transAnim.stop()
      const mid = frontImg.source.toString()
      if (mid !== "") baseImg.source = mid
    }
    win.transKind = kind
    win.pendingFade = true
    frontImg.source = url
  }

  function startTrans() {
    // transKind is "" for a snap, and a snap is staged through here like any
    // other swap - so the promote has to recognise it, or a "none" transition
    // with motion enabled would animate the frame it just staged.
    if (!MotionPolicy.enabled || win.transKind === "") {
      win.pendingFade = false
      win.fading = false
      baseImg.source = frontImg.source
      // Same idle-drop as finishTrans: the snap promote leaves both
      // items on one url, so the front reference goes.
      frontImg.source = ""
      win._endSwap()
      return
    }
    // Stray warmup guard: a superseded timer must not animate pixels that are
    // not Ready yet. pendingFade stays set, so the decode's own Ready still
    // re-arms the start through the status handler.
    if (frontImg.status !== Image.Ready) {
      return
    }
    win.pendingFade = false
    win.fading = true
    // Reset the tween origin imperatively: the progress relies on restart()
    // applying from:0 before the first frame, and a stale 1 would flash a
    // full mask for one frame on masked kinds.
    win.transProgress = 0
    // Same hand-back the row slide makes: the tween released its target when
    // it stopped, and a window swaps more than once, so every swap hands the
    // target back before it asks for a run.
    transAnim.target = win
    transAnim.restart()
  }

  function finishTrans() {
    if (!win.fading) return
    win.fading = false
    baseImg.source = frontImg.source
    // The promote leaves both items naming the same url (one shared
    // pixmap); drop the front reference so the idle layer holds no
    // second decoded copy - at rest the window carries exactly one
    // texture. front opacity/offsets/masks self-reset through the
    // fading=false bindings below - nothing to scrub imperatively.
    frontImg.source = ""
    win.transKind = ""
    win._endSwap()
  }

  // Fades like a wallpaper swap instead of cutting; drops out of rendering
  // only once fully transparent. Gated by the global animation switch.
  Item {
    anchors.fill: parent
    visible: opacity > 0
    opacity: Wallpaper.enabled ? 1 : 0

    Behavior on opacity {
      enabled: MotionPolicy.enabled
      NumberAnimation {
        duration: win.fadeMs
      }
    }

    Image {
      id: baseImg
      anchors.fill: parent
      fillMode: Image.PreserveAspectCrop
      // Async decode: the wallpapers live at 5K+ and a synchronous decode
      // stalls the UI thread for tens of ms per screen - the bar and every
      // other surface freeze behind it on cold boot.
      asynchronous: true
      // Bound decode: PreserveAspectCrop rasterizes at the bound's own pixel
      // size otherwise - a 5640x2400 jpeg costs ~54MB RGBA and the upload to
      // match, on every screen. The bound is in DEVICE pixels and the window
      // is measured in logical ones, so the window's own ratio is the
      // multiplier: a logical bound is the softness this line exists to
      // remove, because the compositor scales the texture up to the surface
      // from it. The ratio is squared in the bytes it costs - 1.44x here at
      // 1.2, 4x on a scale=2 output - and the bound is what keeps that
      // square from being the square of the source.
      sourceSize.width: win._bucketPx(win.width > 0 ? win.width * win.devicePixelRatio : 0)
      sourceSize.height: win._bucketPx(win.height > 0 ? win.height * win.devicePixelRatio : 0)
    }

    Image {
      id: frontImg
      // Explicit geometry (no anchors.fill): slides translate this layer,
      // which conflicts with anchor positioning.
      width: parent.width
      height: parent.height
      // Opacity: the crossfade ramps with progress; slides and masks
      // paint opaque - the motion/mask does the revealing. Idle parks
      // at 0 so no stale frame lingers.
      opacity: !win.fading ? 0 : (win.transKind === "fade" ? win.transProgress : 1)
      x: (win.fading && win.transKind === "slide") ? Trans.slideX(win.slideFrom, win.transProgress, win.width) : 0
      y: (win.fading && win.transKind === "slide") ? Trans.slideY(win.slideFrom, win.transProgress, win.height) : 0
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      // Same device-pixel bound, bucket-snapped like baseImg above so a
      // resize re-decodes once per 256-px step instead of per pixel.
      sourceSize.width: win._bucketPx(win.width > 0 ? win.width * win.devicePixelRatio : 0)
      sourceSize.height: win._bucketPx(win.height > 0 ? win.height * win.devicePixelRatio : 0)
      // Mask reveal for wipe/grow/outer. The layer (a fullscreen
      // offscreen pass) exists only while a masked transition runs.
      // The mask reads ALPHA, not luminance: grow and wipe paint opaque
      // shapes on transparency, and outer reuses the grow disc with an
      // inverted mask (a black opaque disc would NOT conceal - opaque
      // black still has alpha 1).
      layer.enabled: win.useMask()
      layer.smooth: true
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: Trans.isSwipeKind(win.transKind) ? swipeBand
          : (win.circleGrow ? growDisc : outerDisc)
        maskInverted: win.transKind === "circle" && !win.circleGrow
        maskThresholdMin: 0.5
        maskSpreadAtMin: 0.02
      }
      onStatusChanged: {
        if (status === Image.Ready && win.pendingFade) {
          win._startPendingFade()
        }
        if (status === Image.Error) {
          warmupTimer.stop()
          win.pendingFade = false
          win.painted = baseImg.source.toString() !== ""
          win._endSwap()
        }
      }
    }

    // Mask shapes for the reveal kinds. Warmed from show() (transKind set)
    // through finishTrans() (transKind cleared), not only while fading: the
    // mask FBO must already have rendered when startTrans() flips fading on,
    // otherwise the effect samples an empty mask for the first frames and
    // the swipe/circle reads as a cut or a late jump. Idle (transKind "")
    // keeps all three off so no resident FBO is held per screen.
    //
    // VISIBLE while their kind runs, hidden behind the photos (z: -1 under
    // the opaque fullscreen base/front images) rather than with
    // visible: false: an invisible item's layer is never (re-)rendered, so
    // the effect sampled a permanently empty mask - full tween timing with
    // zero visible reveal, then a hard cut at finishTrans. A visible item's
    // layer re-renders every frame, which is what an animated mask needs.
    // Slanted reveal band: zero-width at progress 0, full coverage at
    // 1, oriented and centered wherever the swap rolled them.
    Item {
      id: swipeBand
      anchors.fill: parent
      visible: Trans.isSwipeKind(win.transKind)
      z: -1
      // Forced into an offscreen layer while invisible: mask sources
      // must render even though they never paint (Omarchy does the same
      // on its reveal mask - a plain invisible item would sample empty
      // and hide the whole frame).
      layer.enabled: Trans.isSwipeKind(win.transKind)
      readonly property var band: Trans.swipeBandRect(win.transProgress, width, height,
        win.swipeCenterXFrac, win.swipeCenterYFrac, win.swipeAngleDeg)
      Rectangle {
        x: swipeBand.band.cx - width / 2
        y: swipeBand.band.cy - height / 2
        width: swipeBand.band.fullW
        height: swipeBand.band.fullH
        rotation: swipeBand.band.angleDeg
        color: "white"
      }
    }

    // Reveal discs, spawned at the rolled origin. Grow expands from
    // nothing; outer starts covering the frame and shrinks away (both
    // opaque-on-transparent - the inverted effect does the concealing
    // for outer, since opaque black would NOT conceal).
    Item {
      id: growDisc
      anchors.fill: parent
      visible: win.transKind === "circle" && win.circleGrow
      z: -1
      layer.enabled: win.transKind === "circle" && win.circleGrow
      readonly property real cx: width * win.discCenterXFrac
      readonly property real cy: height * win.discCenterYFrac
      readonly property real diameter: Trans.discDiameter(win.transProgress, width, height, win.discCenterXFrac, win.discCenterYFrac, false)
      Rectangle {
        x: growDisc.cx - width / 2
        y: growDisc.cy - height / 2
        width: growDisc.diameter
        height: growDisc.diameter
        radius: width / 2
        color: "white"
      }
    }

    Item {
      id: outerDisc
      anchors.fill: parent
      visible: win.transKind === "circle" && !win.circleGrow
      z: -1
      layer.enabled: win.transKind === "circle" && !win.circleGrow
      readonly property real cx: width * win.discCenterXFrac
      readonly property real cy: height * win.discCenterYFrac
      readonly property real diameter: Trans.discDiameter(win.transProgress, width, height, win.discCenterXFrac, win.discCenterYFrac, true)
      Rectangle {
        x: outerDisc.cx - width / 2
        y: outerDisc.cy - height / 2
        width: outerDisc.diameter
        height: outerDisc.diameter
        radius: width / 2
        color: "white"
      }
    }
  }

  // The copy names the image the surface is showing, so it is refused when
  // nothing is: a copy of "whatever was last resolved" while the wallpaper is
  // off would put an invisible image on the clipboard.
  readonly property bool hasImage: Wallpaper.enabled && Wallpaper.current !== ""

  // The card's entries. Each carries the action name the row reports back, so
  // the markup holds no per-entry branch. The toggle row names the state it
  // would produce, not the switch it performs: the label is the setting's own
  // answer, read from the same `Wallpaper.enabled` that hides the images, so
  // "Show" is offered exactly when nothing is on screen.
  // The copy acts on the image on screen, so it dims out when there is none: a
  // row that is a no-op is worse than one that says so. `action` is the
  // record's payload, handed back untouched when the row is clicked.
  readonly property var menuEntries: [
    { label: Wallpaper.enabled ? "Hide wallpaper" : "Show wallpaper", icon: "image", action: "toggle" },
    { label: "Copy image", icon: "copy", action: "image", enabled: win.hasImage }
  ]

  // Open at the click point, in the surfaced window's coordinates (the menu
  // surface covers the same screen, so the two agree).
  property bool menuOpen: false
  property real menuX: 0
  property real menuY: 0

  function openMenu(x, y) {
    win.menuX = x
    win.menuY = y
    win.menuOpen = true
    // On the next tick, when the surface is mapped: the key scope is what
    // makes Escape reach the menu.
    Qt.callLater(menuKeyScope.forceActiveFocus)
  }

  function closeMenu() {
    if (!win.menuOpen) return
    win.menuOpen = false
  }

  function runMenuAction(action) {
    win.closeMenu()
    switch (action) {
    case "toggle": return Settings.toggleWallpaper()
    case "image": return win.copyImage()
    }
  }

  function copyImage() {
    if (!win.hasImage) return
    win._copy("Image copied to clipboard", ShotLib.copyImageCmd(Wallpaper.current))
  }

  // The argv reaches the child as written, not through the setsid/timeout
  // helpers: those judge their tail against the CommandSpec allowlist, which
  // holds the file tools and a shell but not wl-copy, so a prefixed build
  // answers null - the click copied nothing and said nothing. wl-copy forks
  // and returns, so there is no long-lived child for a timeout to bound.
  function _copy(what, argv) {
    const proc = Exec.run(argv)
    if (proc === null) return
    proc.exited.connect(code => {
      if (code !== 0) return
      Exec.run(["notify-send", "-r", "3", "-t", "3000", "-a", "Vibranium",
        "Wallpaper", what])
    })
  }

  // Left click does nothing. Right click opens the menu, and the input area
  // stays live while the wallpaper is hidden - which is what makes the menu's
  // re-enable reachable at all.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: mouse => {
      if (mouse.button === Qt.RightButton) win.openMenu(mouse.x, mouse.y)
    }
  }

  // The menu surface. A window of its own rather than a card drawn on this
  // one: the wallpaper sits on the Background layer, where anything painted is
  // behind every window on screen. Overlay is the layer above them, and the
  // full-screen transparent net beneath the card is the outside-click
  // dismissal.
  PanelWindow {
    id: menuWin

    screen: win.screen
    visible: win.menuOpen
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    exclusiveZone: -1
    anchors.left: true
    anchors.right: true
    anchors.top: true
    anchors.bottom: true

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "vibranium:wallpaper-menu"
    // OnDemand only while open, so Escape can reach the key scope; the
    // wallpaper surface itself never takes the keyboard.
    WlrLayershell.keyboardFocus: win.menuOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    // A click the compositor routes anywhere but here clears the grab, which
    // closes the card.
    HyprlandFocusGrab {
      active: win.menuOpen
      windows: [menuWin]
      onCleared: win.closeMenu()
    }

    MouseArea {
      anchors.fill: parent
      enabled: win.menuOpen
      acceptedButtons: Qt.AllButtons
      onPressed: win.closeMenu()
    }

    // The card, its rows and their rhythm are the shared ContextMenu; what
    // stays here is the anchoring - clamped against the surface after layout,
    // so a click near an edge still opens the whole card on screen.
    ContextMenu {
      id: menuCard

      entries: win.menuEntries
      x: Math.max(Ui.m, Math.min(Math.round(win.menuX), menuWin.width - width - Ui.m))
      y: Math.max(Ui.m, Math.min(Math.round(win.menuY), menuWin.height - height - Ui.m))

      onActivated: entry => win.runMenuAction(entry.action)
    }

    FocusScope {
      id: menuKeyScope

      anchors.fill: parent
      focus: win.menuOpen

      Keys.onEscapePressed: event => {
        win.closeMenu()
        event.accepted = true
      }
    }
  }

  DropArea {
    id: dropArea
    anchors.fill: parent
    enabled: Wallpaper.enabled
    // True only while a payload that passed the hover filter is over the
    // area. DropArea.containsDrag is true for every hovering drag whether
    // or not onEntered accepted it, so the overlay must bind to this
    // verdict instead of containsDrag.
    property bool dragOk: false
    onEntered: drag => {
      if (!Wallpaper.enabled) return
      dragOk = Wallpaper._dropIsSupported(drag)
      // Hover-time filter: only payloads handleDroppedUri can turn
      // into a wallpaper accept the drag, so folders, text and
      // non-image files never trigger the overlay.
      if (dragOk) drag.acceptProposedAction()
    }
    onExited: dragOk = false
    onDropped: drop => {
      dragOk = false
      if (!Wallpaper._dropIsSupported(drop)) return
      // The payload is reduced to its one image by the same call the hover
      // filter used, so the drag that lit this area is the drag handled here.
      const uri = Wallpaper._droppedUri(drop)
      if (uri === "") return
      Wallpaper.handleDroppedUri(uri)
    }
  }

  // Drag feedback: tinted overlay while a supported drag hovers the
  // background. Hidden entirely when wallpaper is disabled so no drag cue
  // appears. Inset by the bar's exclusive zone so the border never hides
  // under the top-layer bar (which lives above Background).
  Rectangle {
    anchors.fill: parent
    anchors.topMargin: DesktopLayoutState.barEnabled && DesktopLayoutState.barPosition === "top" ? DesktopLayoutState.barHeight : 0
    anchors.bottomMargin: DesktopLayoutState.barEnabled && DesktopLayoutState.barPosition === "bottom" ? DesktopLayoutState.barHeight : 0
    visible: dropArea.dragOk
    color: Ui.tint("accent", 0.12)
    border.color: Ui.solid("accent")
    border.width: 2
  }

  // Mask warmup: a few frames between decode-Ready and tween start (see
  // frontImg.onStatusChanged). Gives the mask FBOs and the receiver layer
  // one render before the effect samples them. Imperceptible (tens of ms
  // against 250-1200ms transitions) and mask-kinds only.
  Timer {
    id: warmupTimer

    interval: 50
    repeat: false
    onTriggered: win.startTrans()
  }

  // The shared number tween, on the transition preset's own clock. The gate
  // is the policy call, not a separate check: transProgress has no Behavior of
  // its own, so this duration is the only place the switch reaches the swap.
  // The curve is per-kind and stays spelled out - four kinds, four curves, and
  // only the growing circle is the primitive's default.
  //
  // onStopped coexists with the primitive's own rather than replacing it: a
  // derived object's handler is a second connection to the same signal, so the
  // release still runs and this transition still finishes.
  Glide {
    id: transAnim
    target: win
    property: "transProgress"
    from: 0
    to: 1
    duration: MotionPolicy.duration(win.transMs)
    easing.type: win.easingFor(win.transKind, win.circleGrow)
    onStopped: win.finishTrans()
  }
}
