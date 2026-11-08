pragma ComponentBehavior: Bound
import QtQml
import QtQuick
import qs.features.menu
import qs.features.launcher
import qs.features.lock
import qs.features.clipboard
import qs.features.polkit
import qs.features.osd
import qs.features.notifications
import qs.features.pass
import qs.features.annotations
import qs.features.apps
import qs.features.apps.audioMixer
import qs.features.apps.imageViewer
import qs.features.pickers.theme
import qs.features.pickers.emoji
import qs.features.pickers.keybindings
import qs.features.pickers.cursor
import qs.features.pickers.font
import qs.features.wallpaperPicker
import qs.features.powerMenu

// Feature half of the late boot: the feature modules nothing on the first
// screen needs (menu, launcher, apps, pickers, annotations, notifications,
// clipboard, polkit, OSD, power menu) and the singleton touches that reach
// them.
//
// The services and the bar live in BootBar.qml, not here. Splitting the two
// is what keeps the bar off this file's compile: a component's imports load
// their whole file sets before it is ready, so when the bar shared this half
// it could not be demanded until every feature module had been loaded too.
//
// Boot.qml keeps the whole catalog (ids, dependencies, counts) plus the floor
// and Phase-1 resolvers, so the static catalog suite and the graph validation
// see one unchanged table. What moves here is the *code* behind the late
// resolvers, ready predicates and teardowns, together with the imports that
// pull those types in.
//
// Loaded via Qt.createComponent(..., Component.Asynchronous) from Boot, never
// via `import qs.boot` member access, so no pre-paint import edge reaches this
// file. Nothing here runs at construction: resolve/ready/teardown are pure
// dispatches, and the Connections only observe.
Item {
  id: late

  // Boot, set at createObject time. Late readiness refreshes go through
  // it so the gate bookkeeping stays in one place.
  property var boot: null

  function resolve(id) {
    switch (id) {
      case "lockscreen":       void Lockscreen.locked; break
      case "clipboard":        void Clipboard.tag; break
      case "osd":              void OSD.tag; break
      case "notifications":    void Notifications.tag; break
      case "menu":             void Menu.tag; break
      case "app":              void AppHost.tag; break
      case "appLauncher":      void AppLauncher.tag; break
      case "polkit":           void Polkit.tag; break
      case "emojiPicker":      void EmojiPicker.tag; break
      case "keybindings":      void Keybindings.tag; break
      case "themePicker":      void ThemePicker.tag; break
      case "themeRemover":     void ThemeRemover.tag; break
      case "cursorPicker":     void CursorPicker.tag; break
      case "wallpaperPicker":  void WallpaperPicker.tag; break
      case "fontPicker":       void FontPicker.tag; break
      case "pass":
        void Pass.tag
        late._observePass()
        break
      case "audioMixer":       void AudioMixer.tag; break
      case "imageViewer":      void ImageViewer.tag; break
      case "powerMenu":        void PowerMenu.tag; break
      default:                 return false
    }
    return true
  }

  function readyState(id) {
    switch (id) {
      case "notifications": return Notifications.tag === "notifications"
      case "app":           return AppHost.tag === "app"
      case "appLauncher":   return AppLauncher.facadeReady === true
      case "pass":          return Pass.facadeReady === true
      case "audioMixer":    return AudioMixer.facadeReady === true
      case "imageViewer":   return ImageViewer.facadeReady === true
      default:              return false
    }
  }

  function teardown(id) {
    switch (id) {
      case "appLauncher": AppLauncher.teardownController(); break
      case "pass":        Pass.teardownController(); break
      case "audioMixer":  AudioMixer.teardownController(); break
      case "imageViewer": ImageViewer.teardownController(); break
      default:            break
    }
  }

  // The annotation controller component. Boot's Loader stays declarative
  // about *when* (demand-driven) while the *what* lives here with the
  // annotations import, assigned once the late half has loaded.
  Component {
    id: annotationComp
    AnnotationController {}
  }
  function annotationComponent() {
    return annotationComp
  }

  // An observation edge, attached when the unit is first resolved rather than
  // when this half is constructed. A Connections element evaluates `target`
  // at creation, so `target: Pass` here instantiated the singleton the moment
  // _adoptLate built this object - before its turn and inside the window the
  // split exists to keep clear. Boot refreshes each unit right after
  // resolve(), so the initial state needs no connection; this only carries
  // later transitions.
  function _observePass() {
    if (passConnection.target === null) passConnection.target = Pass
  }

  Connections {
    id: passConnection
    target: null
    function onInitializedChanged() {
      if (late.boot) late.boot._refreshUnit("pass")
    }
  }
}
