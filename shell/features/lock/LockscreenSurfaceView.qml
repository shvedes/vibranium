pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import QtQuick as QQ
import QtQuick.Effects
import Quickshell.Wayland
import qs.common
import qs.services
import qs.features.lock

// One surface per screen, created by the WlSessionLock in Lockscreen.qml.
// Backdrop is a single captured frame of the screen (screen mode) or the
// wallpaper snapshot taken at lock time (background mode), dimmed at a
// configurable level and optionally blurred when blurBackground is enabled,
// with the auth field dead center. Field text mirrors Lockscreen.password so
// every screen types in lockstep even though only the focused one receives
// keys. In "none" mode there is no backdrop layer at all: the surface paints
// the plain theme background color.
WlSessionLockSurface {
  id: surface

  // Gates the entry fade only; in-card transitions (border fades, shake,
  // chip and layout hint) animate unconditionally. Follows the global
  // animation switch.
  readonly property bool anims: MotionPolicy.enabled

  // Password field autohide. Only opacity changes, so the input keeps focus
  // and hit-testing while invisible and a fade can never swallow a keystroke.
  // The countdown is re-armed by password edits, which Lockscreen mirrors to
  // every surface, so typing on one screen keeps all of them revealed.
  readonly property bool autohideEnabled: Settings.lockscreenAutohide === true
  readonly property int autohideDelayMs: Settings.lockscreenAutohideDelay * 1000
  property real autohideK: 1
  // The clock dims to half with the field, keeping one quiet focal point on
  // the idle screen instead of two bright blocks.
  property real clockIdleK: 1

  Behavior on autohideK {
    enabled: surface.anims
    NumberAnimation {
      duration: 600
      easing.type: Easing.Linear
    }
  }

  // The clock dim runs on its own curve: it settles into the dimmed band
  // softly while the field stays on a plain linear fade.
  Behavior on clockIdleK {
    enabled: surface.anims
    NumberAnimation {
      duration: 600
      easing.type: Easing.OutCubic
    }
  }

  function setIdleFade(faded) {
    autohideK = faded ? 0 : 1
    clockIdleK = faded ? 0.5 : 1
  }

  // Qualified: qs.services exports a Timer singleton that shadows QtQuick's.
  QQ.Timer {
    id: autohideTimer
    interval: surface.autohideDelayMs
    repeat: false

    onTriggered: {
      if (!surface.autohideEnabled || !surface.visible) return
      if (Lockscreen.authenticating) {
        autohideTimer.restart()
        return
      }
      surface.setIdleFade(true)
    }
  }

  // Restores the field and restarts the idle countdown. When the option is
  // off or the surface is hidden the timer stops and the field stays shown.
  function resetAutohide() {
    surface.setIdleFade(false)
    if (!surface.autohideEnabled || !surface.visible) {
      autohideTimer.stop()
      return
    }
    autohideTimer.restart()
  }

  // Backdrop source for this surface. "none" is a deliberate absence: the
  // plain theme color paints and no backdrop layer is built at all.
  readonly property string backgroundMode: Settings.lockscreenBackgroundMode

  // The compositor's name for this output. It is the only way to say which
  // screen a surface is about on a multi-monitor lock, where two screens can
  // resolve an effect differently.
  readonly property string screenName: String(surface.screen ? (surface.screen.name ?? "") : "")
  // Whether this surface's screen can carry a backdrop at all. A screen is
  // valid when it is present, named and non-zero-sized; the compositor
  // advertises a nameless zero-sized placeholder on wake for a moment, and a
  // backdrop built over one is invisible. The backdrop Loader and the
  // ScreencopyView below both gate on this one predicate.
  readonly property bool screenValid: !!surface.screen && surface.screenName !== ""
    && surface.screen.width > 0 && surface.screen.height > 0

  // The three effect values the surface paints with, resolved from the
  // settings here. "medium" and anything unrecognised fall back the same way in
  // each table, so a hand-edited store paints a sane surface rather than an
  // undrawable one.
  // "none" has no backdrop to blur, so blur is unavailable there even when a
  // persisted blurBackground value still says true.
  readonly property bool blurEnabled: surface.backgroundMode !== "none"
    && Settings.blurBackground === true

  // Blur radius per power preset, as MultiEffect.blurMax. The MultiEffect
  // below keeps `blur` (intensity) and `blurMultiplier` fixed at 1.0, so this
  // table is the effective radius.
  function _blurRadius(power) {
    if (power === "low") return 32
    if (power === "high") return 128
    // "medium" and anything unrecognised both land on 64, the long-standing
    // radius and the settings default.
    return 64
  }

  // Percent -> fraction, clamped. A value outside 0..100 is a store that has
  // been hand-edited; the clamp keeps the dim rectangle inside a drawable range
  // rather than letting a negative opacity through.
  function _dimFraction(percent) {
    const n = Number(percent)
    if (!isFinite(n)) return 0
    if (n < 0) return 0
    if (n > 100) return 1
    return n / 100
  }

  // Vignette darkness per backdrop level; 0 disables. Only the shape opacity
  // varies - the gradient geometry stays identical for every level. "off" and
  // anything unrecognised resolve to 0, which is also what keeps the vignette
  // Loader inactive.
  function _vignetteFactor(level) {
    if (level === "small") return 0.25
    if (level === "medium") return 0.45
    if (level === "large") return 0.65
    if (level === "gigantic") return 0.85
    return 0
  }

  readonly property real blurRadius: surface._blurRadius(
    String(Settings.lockscreenBlurPower === undefined || Settings.lockscreenBlurPower === null
      ? "" : Settings.lockscreenBlurPower))
  // Dim fraction (0-100 -> 0-1), one level for a blurred and a sharp backdrop
  // alike. A surface with no backdrop is not dimmed: the plain theme color is
  // what "none" shows.
  readonly property real dim: surface.backgroundMode === "none" ? 0
    : surface._dimFraction(Settings.lockscreenDim)
  readonly property real vignetteK: surface._vignetteFactor(
    String(Settings.lockscreenVignette === undefined || Settings.lockscreenVignette === null
      ? "" : Settings.lockscreenVignette))
  // Normalized entry-fade driver: 0 before lock, ramps 0 -> 1 on lock when
  // animations run, snaps to 1 otherwise. This is the only animated value for
  // the vignette. Painted darkness is derived from it and the LIVE vignetteK
  // (Vignette.qml computes opacity = intensity * progress), so a level change
  // while locked changes the darkness without touching this driver. Keeping
  // the driver normalized also decouples the shape scale from the level:
  // Vignette scales by progress alone, so changing the level cannot jump it.
  property real appearFade: 0
  color: Theme.color("background_0")

  Component.onCompleted: surface.grabFocus()

  onVisibleChanged: {
    if (!visible) {
      autohideTimer.stop()
      return
    }
    // Fresh inhibitor registry for the sleep hint: covers a caffeine
    // toggle (or any other app grabbing/releasing a lock) since the
    // last periodic refresh.
    Inhibitor.refresh()
    surface.appear()
    surface.grabFocus()
  }

  function grabFocus() {
    authBox.grabFocus()
    surface.resetAutohide()
  }

  // Backdrop never animates: blur covers from its first captured frame, so
  // neither lock nor unlock ever exposes the plain surface color underneath.
  // Only the normalized fade is written here. The vignette level is read live
  // from vignetteK, so a level change while locked is picked up by Vignette's
  // own derivation instead of needing another animation or a re-run of appear().
  function appear() {
    if (!surface.anims) {
      panel.appearK = 1
      surface.appearFade = 1
      return
    }
    panel.appearK = 0
    surface.appearFade = 0
    appearAnim.restart()
  }

  // The entry fade: panel opacity and the normalized vignette fade ramp
  // together, 500ms and 1300ms, so the vignette settles behind the card
  // rather than with it. The vignette animation tweens only the 0 -> 1 fade;
  // darkness is derived in Vignette as intensity * progress from that fade
  // and the live level, never snapshotted into an absolute factor here.
  ParallelAnimation {
    id: appearAnim

    NumberAnimation {
      target: panel
      property: "appearK"
      from: 0
      to: 1
      duration: 500
      easing.type: Easing.OutCubic
    }

    NumberAnimation {
      target: surface
      property: "appearFade"
      from: 0
      to: 1
      duration: 1300
      easing.type: Easing.OutCubic
    }
  }

  Connections {
    target: Lockscreen

    function onFailedAttemptsChanged() {
      if (Lockscreen.failedAttempts > 0) authBox.fail()
    }

    // Disabling the field during auth drops its focus.
    function onAuthenticatingChanged() {
      if (!Lockscreen.authenticating && Lockscreen.requested) surface.grabFocus()
    }

    function onPasswordChanged() {
      // A real keystroke reaches every surface through the mirrored password,
      // so the field reappears and the idle countdown restarts everywhere.
      surface.resetAutohide()
      // Programmatic assignment never fires edited, so sibling-screen syncs
      // and resets stay silent by construction.
      if (authBox.text === Lockscreen.password) return
      authBox.text = Lockscreen.password
    }
  }

  Connections {
    target: Settings

    function onOptionChanged(key, _) {
      if (key === "shell.lockscreen.autohide" || key === "shell.lockscreen.autohideDelay")
        surface.resetAutohide()
    }
  }

  // Backdrop: one source - a grabbed screen frame (screen mode) or the
  // wallpaper snapshot pinned at lock() time (background mode) - blurred by
  // the same layer effect, then a flat black overlay at configurable dim.
  // Blur/dim work identically over either source; blurBackground only
  // toggles the MultiEffect.
  Component {
    id: backdropComp

    Item {
      id: backdrop

      anchors.fill: parent

      layer.enabled: true
      layer.effect: MultiEffect {
        autoPaddingEnabled: false
        blurEnabled: surface.blurEnabled
        blur: 1
        // Power presets from Settings.lockscreenBlurPower; medium keeps the
        // long-standing radius. Only effective when blurBackground is true.
        blurMax: surface.blurRadius
        blurMultiplier: 1.0
      }

      // Screen mode: one grabbed frame. Only instantiated while screen mode
      // is active - background mode must not touch the capture backend at
      // all, and a hidden ScreencopyView would still grab a frame because
      // its context creation does not depend on visibility.
      Component {
        id: screencopyComp

        ScreencopyView {
          anchors.fill: parent
          // After wakeup the compositor may advertise a placeholder screen
          // with empty name or no Wayland output. Feeding that to
          // ScreencopyView warns "Capture source set to non captureable
          // object" and leaves the backdrop transparent. Gate on a
          // capturable source: a valid screen has a non-empty name and
          // dimensions > 0.
          readonly property bool _validSrc: surface.screenValid
          captureSource: _validSrc ? surface.screen : null
          // Single frame by design; a live feed would recompute the blur
          // every frame for as long as the session sits locked.
          live: _validSrc ? false : false
          visible: _validSrc
        }
      }

      Loader {
        anchors.fill: parent
        active: surface.backgroundMode === "screen"
        sourceComponent: screencopyComp
      }

      // Background mode: wallpaper snapshot from Lockscreen.backdropPath. An
      // empty path renders nothing, so the surface theme color painted
      // behind this layer shows through instead of a transparent flash.
      // PreserveAspectCrop matches WallpaperView's fill mode. The decode
      // runs async so the lock surface paints its first frame over the
      // theme color instantly, whatever the source resolution, and fades
      // the wallpaper in when it lands; with animations off it snaps.
      Image {
        id: backdropImage

        anchors.fill: parent
        visible: surface.backgroundMode === "background"
        source: Lockscreen.backdropPath !== "" ? Paths.toFileUrl(Lockscreen.backdropPath) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        opacity: status === Image.Ready && source.toString() !== "" ? 1 : 0
        Behavior on opacity {
          enabled: surface.anims
          NumberAnimation {
            duration: 500
            easing.type: Easing.OutCubic
          }
        }
        // The downloader preview's arrival, reversed: the frame spawns
        // slightly zoomed and pushes itself back to fit, so a settled
        // wallpaper keeps its real dimensions.
        onStatusChanged: {
          if (status !== Image.Ready || source.toString() === "") {
            fitAnim.stop()
            scale = 1
            return
          }
          if (!surface.anims) {
            scale = 1
            return
          }
          scale = 1.05
          fitAnim.restart()
        }

        NumberAnimation {
          id: fitAnim

          target: backdropImage
          property: "scale"
          from: 1.05
          to: 1
          duration: 700
          easing.type: Easing.OutCubic
        }
        // A session lock surface is not a Quickshell window and carries no
        // devicePixelRatio of its own, so the ratio is the one Qt reports for
        // the window this item is in. sourceSize is in DEVICE pixels while the
        // surface is measured in logical ones, and the bound is what keeps a
        // 5K wallpaper from being held at full size for as long as the session
        // stays locked - at the cost of the ratio squared in bytes, which is
        // what a device-pixel bound buys over upscaling from a logical one.
        readonly property real _dpr: Window.window
          ? Window.window.devicePixelRatio : 1
        sourceSize.width: surface.width > 0
          ? Math.round(surface.width * _dpr) : 0
        sourceSize.height: surface.height > 0
          ? Math.round(surface.height * _dpr) : 0
      }

      Rectangle {
        anchors.fill: parent
        color: "#000000"
        opacity: surface.dim
      }
    }
  }

  // Backdrop is needed whenever there is a source - blurred or just dimmed -
  // so the loader stays active for screen and background mode. "none" skips
  // it outright: no capture, no wallpaper decode, and the surface color is the
  // whole backdrop. Suppress the loader entirely for placeholder screens to
  // avoid the "Layershell screen does not correspond to a real screen"
  // warning on wakeup when the compositor briefly advertises a fallback.
  //
  // surface.screenValid is the one predicate for a real screen: the same one
  // the ScreencopyView above reads, so a suppressed backdrop and a captured
  // frame cannot disagree about what a valid screen is.
  Loader {
    anchors.fill: parent
    active: surface.screenValid && surface.backgroundMode !== "none"
    sourceComponent: backdropComp
  }

  // Vignette: radial edge darkening over any backdrop. Drawn outside the
  // captured/blurred layer so it stays crisp no matter the source or blur -
  // the dim rectangle and blur only ever touch the backdrop beneath it.
  // "none" paints the plain theme color, so there is no backdrop to darken and
  // the loader stays inactive regardless of the configured level.
  // Lazy: nothing instantiates while the level is off, and async load
  // keeps first paint off the Shape tessellation path - which is also why a
  // locked screen can paint one frame without the vignette and settle into it
  // a frame later. The level gate is live: "off" removes the vignette, and a
  // later level change re-instantiates it at the current normalized fade.
  //
  // A plain Loader, not a LazyLoader: LazyLoader is a QObject and hands its
  // payload no visual parent, so the payload is never in the scene graph and
  // cannot paint (measured: a parentless payload of any size stays
  // transparent). Forcing one in with `parent:` works, but the payload then
  // joins surface.children when the async load lands - i.e. after every
  // sibling was declared - so it paints above the auth field, the
  // now-playing pill and the sleep hint instead of beneath them, which is
  // the one thing this overlay must not do. A Loader keeps its declared
  // slot in the paint order because its item is a child of the Loader.
  Loader {
    anchors.fill: parent
    active: surface.backgroundMode !== "none" && surface.vignetteK > 0
    asynchronous: true

    // The shared vignette draws the gradient. The surface passes the LIVE
    // level as intensity and the normalized entry fade as progress; Vignette
    // derives opacity = intensity * progress and scales the shape by progress
    // alone. Neither input is a snapshot, so a level change while locked
    // changes darkness with no scale discontinuity.
    sourceComponent: Vignette {
      anchors.fill: parent
      intensity: surface.vignetteK
      progress: surface.appearFade
    }
  }

  // Clock band: a block above the auth field with real air around it, capped at
  // a fifth of the surface rather than the whole upper third. Every term is
  // measured here, so a short or fractionally-scaled output shrinks the clock
  // instead of painting it over the field - the same rule as the pickers'
  // content band. The block is bottom-anchored to this limit, so the time sits
  // close to the field without crowding the top edge.
  readonly property real clockTop: Math.max(Ui.l, Math.round(surface.height * 0.13))
  readonly property real clockBottom: panel.y - Math.round(surface.height * 0.10)
  readonly property real clockMaxH: Math.max(0, Math.min(
    Math.round(surface.height * 0.20), surface.clockBottom - surface.clockTop))

  // Huge time, with the optional date directly under it. The block is sized
  // from the band above and pinned to its lower edge, so it never touches the
  // field, and it rides the same entry fade as the panel.
  LockClock {
    id: lockClock

    anchors.horizontalCenter: parent.horizontalCenter
    y: surface.clockBottom - height
    maxWidth: Math.max(0,
      Math.min(surface.width * 0.86, surface.width - 2 * Ui.outerPad))
    maxHeight: surface.clockMaxH
    withDate: Settings.lockscreenDate
    showSeconds: Settings.lockscreenSeconds
    visible: Settings.lockscreenClock && surface.clockMaxH > 0
    opacity: panel.appearK * surface.clockIdleK
  }

  // The field itself sits dead center; indicators hang off it absolutely
  // so toggling them can never shift the input. Only this panel animates,
  // and only on entry - unlock tears the whole surface down instantly.
  // Sized from the box so the dimensions live in PasswordBox alone.
  Item {
    id: panel

    property real appearK: 1
    // "English (US)" -> "US", "Russian" -> "RU". Always uppercased no
    // matter which extraction path fires.
    readonly property string layoutCode: {
      const l = Keyboard.layout.trim()
      if (l === "") return ""
      const m = l.match(/\(([^)]+)\)/)
      const code = m ? m[1] : l.slice(0, 2)
      return code.toUpperCase()
    }

    anchors.centerIn: parent
    width: authBox.width
    height: authBox.height
    // The entry fade and the idle autohide multiply into one opacity; neither
    // touches visibility or enabled, so the field stays interactive throughout.
    opacity: appearK * surface.autohideK
    scale: 0.94 + 0.06 * appearK

    PasswordBox {
      id: authBox

      anchors.centerIn: parent

      enabled: !Lockscreen.authenticating
      busy: Lockscreen.authenticating

      // The field names itself with a glyph instead of a word: the same
      // lock the password manager puts on its vault rows, in the field's
      // left chrome slot, trading to the eye while the echo is revealed.
      iconName: "lock"
      // Caps does not need a chip above the box: with caps on, every echo
      // glyph jumps, so the field itself carries the state.
      capsActive: Keyboard.capsOn
      placeholder: ""

      onSubmitted: Lockscreen.tryUnlock()

      // Any real key press is activity for the grace window, including keys
      // the field swallows or that do not edit its text.
      onKeyPressed: Lockscreen.graceActivity()

      onEdited: text => Lockscreen.setPassword(text)
      onCancelled: Lockscreen.setPassword("")
      onCapsToggled: Keyboard.toggleCaps()
    }

    Text {

      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: authBox.bottom
      anchors.topMargin: 14
      // Hidden outright when the keyboard has a single layout.
      opacity: parent.layoutCode !== "" && Keyboard.layoutCount > 1 ? 0.8 : 0
      text: parent.layoutCode
      color: Theme.color("foreground_1")
      font.pixelSize: Ui.fontM
      font.family: Ui.fontFamily
      font.bold: true
      font.letterSpacing: 3

      Behavior on opacity {
        NumberAnimation {
          duration: 150
        }
      }
    }
  }

  // Currently-playing pill floating 5% of the screen height above the
  // bottom edge - proportional on any display. Rides the same entry fade
  // (and its gate) as the panel above.
  //
  // NOTE: the track gate lives HERE, not inside NowPlaying.qml. QML lets
  // this `visible:` assignment clobber the component-internal
  // `visible: root.hasTrack` binding, so gating internally alone never
  // hid the pill - it has to be and-ed at the instantiation site.
  NowPlaying {
    id: nowPlaying

    visible: Settings.lockscreenNowPlaying && nowPlaying.hasTrack
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: parent.height * 0.05
    opacity: panel.appearK
  }

  // Sleep-inhibitor hint at the right bottom, driven straight from
  // logind's ListInhibitors (via the Inhibitor registry) instead of
  // our Caffeine module - every app that actually blocks automatic
  // sleep shows up, ours or not. Uses Ui spacing so it stays correct
  // across scales/monitors; lines cap at 45% of the surface and elide,
  // so the block never hardcodes a width that could overflow.
  Column {
    id: caffeineHint

    visible: Inhibitor.sleepBlockers.length > 0
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: Ui.outerPad
    anchors.bottomMargin: Ui.outerPad
    spacing: Ui.s / 2
    // Rides the panel's own entry value like the pill above: appearK is
    // already animated and gated, so a second tween here would trail it and
    // would still fade when motion is off.
    opacity: panel.appearK

    readonly property real maxLineW: surface.width * 0.45

    Text {
      width: Math.min(implicitWidth, caffeineHint.maxLineW)
      text: "System Won't Suspend Automatically"
      color: Ui.solid("foreground_0")
      font.pixelSize: Ui.fontCardTitle
      font.family: Ui.fontFamily
      font.bold: true
      elide: Text.ElideRight
    }

    Repeater {
      model: Inhibitor.sleepBlockers

      delegate: Column {
        id: appBlock

        required property int index
        required property var modelData

        spacing: Ui.s / 4

        // Separator from the UI lib between apps, never before the
        // first one (Column skips invisible children), wrapped so the
        // hairline gets real top/bottom margins - a bare Divider in a
        // Column would sit flush against the app lines.
        Item {
          visible: appBlock.index > 0
          readonly property real sepMargin: Ui.s
          width: Math.max(whoText.width, reasonText.width)
          height: divider.height + 2 * sepMargin

          Divider {
            id: divider
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
          }
        }

        Text {
          id: whoText
          width: Math.min(implicitWidth, caffeineHint.maxLineW)
          text: appBlock.modelData.who + " is preventing system sleep"
          color: Ui.tint("foreground_1", 0.9)
          font.pixelSize: Ui.fontM
          font.family: Ui.fontFamily
          elide: Text.ElideRight
        }

        Text {
          id: reasonText
          width: Math.min(implicitWidth, caffeineHint.maxLineW)
          text: "Reason: " + appBlock.modelData.why
          color: Ui.tint("foreground_1", 0.75)
          font.pixelSize: Ui.fontM
          font.family: Ui.fontFamily
          elide: Text.ElideRight
        }
      }
    }
  }

  // Hides the pointer across the WHOLE surface, including the password box.
  // Declared last so it is above the field: Qt gives the cursor shape to the
  // topmost hover handler, and a field painted above this area re-shows its
  // native I-beam whenever the pointer sits over it. `NoButton` still lets
  // every press fall through to the field underneath.
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    cursorShape: Qt.BlankCursor

    // Pointer motion over the surface is the other half of grace-window
    // activity; acceptedButtons does not gate hover events. Qt synthesizes
    // one hover event when the surface first appears under the pointer, so
    // the first report per surface is recorded but never treated as input.
    property bool pointerSeen: false
    onPositionChanged: {
      if (pointerSeen) Lockscreen.graceActivity()
      pointerSeen = true
    }
  }
}
