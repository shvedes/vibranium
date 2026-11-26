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
import "generated/features" as Generated

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

  // Generator-owned rows for every id this half owns. Constructed
  // synchronously in this provider's adoption turn and inert until a generated
  // id is demanded.
  property var generatedHandlers: Generated.FeaturesHandlers { boot: boot }

  function handler(id) {
    if (Object.prototype.hasOwnProperty.call(generatedHandlers.handlers, id)) return generatedHandlers.handlers[id]
    return null
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
}
