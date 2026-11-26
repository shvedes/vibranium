pragma ComponentBehavior: Bound
import QtQml
import QtQuick
import qs.features.menu
import qs.features.launcher
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
// The services live in BootServices.qml, not here. Splitting them
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

  // One row per owned id. Each resolve closure is the former case body, and
  // ready/teardown carry the predicates and controller releases that used to
  // live in the other two switches. The table itself runs no singleton code.
  property var handlers: ({
    "clipboard": {
      resolve: function() { void Clipboard.tag },
      ready: null,
      teardown: null
    },
    "osd": {
      resolve: function() { void OSD.tag },
      ready: null,
      teardown: null
    },
    "notifications": {
      resolve: function() { void Notifications.tag },
      ready: function() { return Notifications.tag === "notifications" },
      teardown: null
    },
    "menu": {
      resolve: function() { void Menu.tag },
      ready: null,
      teardown: null
    },
    "app": {
      resolve: function() { void AppHost.tag },
      ready: function() { return AppHost.tag === "app" },
      teardown: null
    },
    "appLauncher": {
      resolve: function() { void AppLauncher.tag },
      ready: function() { return AppLauncher.facadeReady === true },
      teardown: function() { AppLauncher.teardownController() }
    },
    "polkit": {
      resolve: function() { void Polkit.tag },
      ready: null,
      teardown: null
    },
    "emojiPicker": {
      resolve: function() { void EmojiPicker.tag },
      ready: null,
      teardown: null
    },
    "keybindings": {
      resolve: function() { void Keybindings.tag },
      ready: null,
      teardown: null
    },
    "themePicker": {
      resolve: function() { void ThemePicker.tag },
      ready: null,
      teardown: null
    },
    "themeRemover": {
      resolve: function() { void ThemeRemover.tag },
      ready: null,
      teardown: null
    },
    "cursorPicker": {
      resolve: function() { void CursorPicker.tag },
      ready: null,
      teardown: null
    },
    "wallpaperPicker": {
      resolve: function() { void WallpaperPicker.tag },
      ready: null,
      teardown: null
    },
    "fontPicker": {
      resolve: function() { void FontPicker.tag },
      ready: null,
      teardown: null
    },
    "pass": {
      resolve: function() {
        void Pass.tag
        late._observePass()
      },
      ready: function() { return Pass.facadeReady === true },
      teardown: function() { Pass.teardownController() }
    },
    "audioMixer": {
      resolve: function() { void AudioMixer.tag },
      ready: function() { return AudioMixer.facadeReady === true },
      teardown: function() { AudioMixer.teardownController() }
    },
    "imageViewer": {
      resolve: function() { void ImageViewer.tag },
      ready: function() { return ImageViewer.facadeReady === true },
      teardown: function() { ImageViewer.teardownController() }
    },
    "powerMenu": {
      resolve: function() { void PowerMenu.tag },
      ready: null,
      teardown: null
    }
  })

  function handler(id) {
    return Object.prototype.hasOwnProperty.call(handlers, id) ? handlers[id] : null
  }

  function resolve(id) {
    var row = handler(id)
    if (!row) return false
    row.resolve()
    return true
  }

  function readyState(id) {
    var row = handler(id)
    return row && row.ready ? row.ready() : false
  }

  function teardown(id) {
    var row = handler(id)
    if (row && row.teardown) row.teardown()
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
