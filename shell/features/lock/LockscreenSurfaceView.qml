pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import QtQuick.Effects
import Quickshell.Wayland
import qs.services
import qs.common
import qs.features.lock

// One surface per screen, created by the WlSessionLock in Lockscreen.qml.
// Backdrop is a single captured frame of the screen (screen mode) or the
// wallpaper snapshot taken at lock time (background mode), dimmed at a
// configurable level and optionally blurred when blurBackground is enabled,
// with the auth field dead center. Field text mirrors Lockscreen.password so
// every screen types in lockstep even though only the focused one receives
// keys.
WlSessionLockSurface {
  id: surface

  // Gates the entry fade only; in-card transitions (border fades, shake,
  // chip and layout hint) animate unconditionally. Follows the global
  // animation switch.
  readonly property bool anims: MotionPolicy.enabled

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
  readonly property bool blurEnabled: Settings.blurBackground === true

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
  // Dim fraction from separate settings for blurred vs non-blurred backdrops
  // (0-100 -> 0-1). Picks the active dim based on blurEnabled.
  readonly property real dim: surface._dimFraction(surface.blurEnabled
    ? Settings.lockscreenDimBlurred
    : Settings.lockscreenDim)
  readonly property real vignetteK: surface._vignetteFactor(
    String(Settings.lockscreenVignette === undefined || Settings.lockscreenVignette === null
      ? "" : Settings.lockscreenVignette))
  // Animated vignette factor, driven by appear(): ramps 0 -> vignetteK
  // on lock when animations run, snaps instantly otherwise.
  property real vigK: 0
  color: Theme.color("background_0")

  Component.onCompleted: surface.grabFocus()

  onVisibleChanged: {
    if (!visible) return
    // Fresh inhibitor registry for the sleep hint: covers a caffeine
    // toggle (or any other app grabbing/releasing a lock) since the
    // last periodic refresh.
    Inhibitor.refresh()
    surface.appear()
    surface.grabFocus()
  }

  function grabFocus() {
    authBox.grabFocus()
  }

  // Backdrop never animates: blur covers from its first captured frame, so
  // neither lock nor unlock ever exposes the plain surface color underneath.
  function appear() {
    if (!surface.anims) {
      panel.appearK = 1
      surface.vigK = surface.vignetteK
      return
    }
    panel.appearK = 0
    surface.vigK = 0
    appearAnim.restart()
  }

  // The entry fade: panel opacity and the vignette factor ramp together, 500ms
  // and 1300ms, so the vignette settles behind the card rather than with it.
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
      property: "vigK"
      from: 0
      to: surface.vignetteK
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
      // Programmatic assignment never fires edited, so sibling-screen syncs
      // and resets stay silent by construction.
      if (authBox.text === Lockscreen.password) return
      authBox.text = Lockscreen.password
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
        active: Settings.lockscreenBackgroundMode === "screen"
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
        id: backdropImg
        anchors.fill: parent
        visible: Settings.lockscreenBackgroundMode === "background"
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

  // Backdrop is always needed - blurred or just dimmed - so the loader stays
  // active. Capture warmup in Lockscreen.qml primes the backend regardless of
  // blur state. Suppress the loader entirely for placeholder screens to
  // avoid the "Layershell screen does not correspond to a real screen"
  // warning on wakeup when the compositor briefly advertises a fallback.
  //
  // surface.screenValid is the one predicate: the same one the ScreencopyView
  // above reads, so a suppressed backdrop and a captured frame cannot disagree
  // about what a valid screen is.
  Loader {
    id: backdropLoader
    anchors.fill: parent
    active: surface.screenValid
    sourceComponent: backdropComp
  }

  // Vignette: radial edge darkening over any backdrop. Drawn outside the
  // captured/blurred layer so it stays crisp no matter the source or blur -
  // the dim rectangle and blur only ever touch the backdrop beneath it.
  // Lazy: nothing instantiates while the level is off, and async load
  // keeps first paint off the Shape tessellation path - which is also why a
  // locked screen can paint one frame without the vignette and settle into it
  // a frame later.
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
    id: vignetteLoader
    anchors.fill: parent
    active: surface.vignetteK > 0
    asynchronous: true

    // The shared vignette draws the gradient; the surface only decides how
    // dark it is and how far the fade has run. The ratio is the fade
    // progress, which is what the component scales the shape by.
    sourceComponent: Vignette {
      anchors.fill: parent
      intensity: surface.vignetteK
      progress: surface.vignetteK > 0 ? surface.vigK / surface.vignetteK : 1
    }
  }

  // Hides the pointer across the whole lockscreen. NoButton keeps clicks
  // falling through to the input field underneath.
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    cursorShape: Qt.BlankCursor
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
    opacity: appearK
    scale: 0.94 + 0.06 * appearK

    CapsChip {
      active: Keyboard.capsOn
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: authBox.top
      anchors.bottomMargin: 12
    }

    PasswordBox {
      id: authBox

      anchors.centerIn: parent

      enabled: !Lockscreen.authenticating
      busy: Lockscreen.authenticating

      // The field names itself with a glyph instead of a word: the same
      // lock the password manager puts on its vault rows, sitting in the
      // field's left chrome slot, always visible.
      iconName: "lock"
      placeholder: ""

      onSubmitted: Lockscreen.tryUnlock()

      onEdited: text => Lockscreen.setPassword(text)
      onCancelled: Lockscreen.setPassword("")
      onCapsToggled: Keyboard.toggleCaps()
    }

    Text {
      id: layoutHint

      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: authBox.bottom
      anchors.topMargin: 14
      // Hidden outright when the keyboard has a single layout.
      opacity: parent.layoutCode !== "" && Keyboard.layoutCount > 1 ? 0.8 : 0
      text: parent.layoutCode
      color: Theme.color("foreground_1")
      font.pixelSize: 12
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
    opacity: panel.appearK

    readonly property real maxLineW: surface.width * 0.45

    Behavior on opacity {
      NumberAnimation {
        duration: 200
      }
    }

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
}
