pragma ComponentBehavior: Bound
import QtQml
import QtQuick
import qs.services
import qs.services as Services
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

// Late boot half: every feature-module import and every singleton touch
// that is not needed before first paint.
//
// Boot.qml keeps the whole catalog (ids, dependencies, counts) plus the
// floor and Phase-1 resolvers, so the static catalog suite and the graph
// validation see one unchanged table. What moves here is the *code* behind
// the late resolvers, ready predicates and teardowns, together with the
// imports that pull those types in. Importing a module loads its whole
// file set before anything paints, so holding these imports here - and
// constructing this object asynchronously after Phase 1 - keeps ~190ms of
// type loading off the time-to-paint path (measured best-of-3, in-probe:
// 687ms full import set vs 492ms floor+P1 set).
//
// Loaded via Qt.createComponent(..., Component.Asynchronous) from Boot,
// never via `import qs.boot` member access, so no pre-paint import edge
// reaches this file. Nothing here runs at construction: resolve/ready/
// teardown are pure dispatches, and the two Connections only observe.
Item {
  id: late

  // Boot, set at createObject time. Late readiness refreshes go through
  // it so the gate bookkeeping stays in one place.
  property var boot: null

  function resolve(id) {
    switch (id) {
      case "idleDaemon":       void IdleDaemon.tag; break
      case "inhibitor":        void Inhibitor.tag; break
      case "session":          void Session.tag; break
      case "lockscreen":       void Lockscreen.locked; break
      case "clipboard":        void Clipboard.tag; break
      case "privacy":          void Privacy.tag; break
      case "osd":              void OSD.tag; break
      case "notifications":    void Notifications.tag; break
      case "mediaEvents":      void Services.MediaEvents.tag; break
      case "menu":             void Menu.tag; break
      case "audio":            void Audio.tag; break
      case "mediaArt":         void MediaArt.tag; break
      case "keyboard":         void Keyboard.tag; break
      case "app":              void AppHost.tag; break
      case "appLauncher":      void AppLauncher.tag; break
      case "timer":            void Services.Timer.tag; break
      case "recording":        void Recording.tag; break
      case "update":           void Update.tag; break
      case "polkit":           void Polkit.tag; break
      case "emojiPicker":      void EmojiPicker.tag; break
      case "keybindings":      void Keybindings.tag; break
      case "themePicker":      void ThemePicker.tag; break
      case "themeRemover":     void ThemeRemover.tag; break
      case "cursorPicker":     void CursorPicker.tag; break
      case "wallpaperPicker":  void WallpaperPicker.tag; break
      case "fontPicker":       void FontPicker.tag; break
      case "pass":             void Pass.tag; break
      case "audioMixer":       void AudioMixer.tag; break
      case "imageViewer":      void ImageViewer.tag; break
      case "archUpdates":      void Services.ArchUpdates.tag; break
      case "powerProfile":     void Services.PowerProfile.tag; break
      case "printers":         void Services.Printers.tag; break
      case "powerPolicy":      void Services.PowerPolicy.tag; break
      case "batteryAlert":     void Services.BatteryAlert.tag; break
      case "connectivity":     void Services.Connectivity.tag; break
      case "screenshots":      void Screenshots.tag; break
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
      case "screenshots":   return Screenshots._runtimeReady === true
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

  Connections {
    target: Screenshots
    function on_RuntimeReadyChanged() {
      if (late.boot) late.boot._refreshUnit("screenshots")
    }
  }

  Connections {
    target: Pass
    function onInitializedChanged() {
      if (late.boot) late.boot._refreshUnit("pass")
    }
  }
}
