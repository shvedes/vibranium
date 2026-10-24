pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters duplicated-name
import QtQuick
import qs.common

// Demand-loaded child of the ImageViewer facade. Everything the viewer draws is
// built here and goes with it: the window, the decoded image, the fit and zoom
// arithmetic, the pan offsets, the folder list the picker walks and the
// frosted toolbar over the image. A shell that never opens a picture constructs
// none of them, which is what the unit being first_use in the catalog is for.
//
// The controller holds objects and lifetime, not policy. The navigation model -
// which folder the picker is in, what the zoom factor is, whether the fit is
// on, which file is showing - belongs to the window, exactly as it belonged to
// the superseded source whose root object was the window
// (apps/ImageViewer.qml:9). Hoisting that state up here would buy nothing: the
// facade is the only caller of this object and the window is the only thing
// that draws it.
Item {
  id: root

  // Set when this object's own construction could not finish, so the facade can
  // answer unavailable instead of reporting a controller that is not there. A
  // Loader cannot raise a construction error to its caller, so the error is
  // reported here and read by the facade on every fresh demand, which is what
  // makes a failed first caller leave the next one a clean unit.
  //
  // The window is deliberately not covered by it. The window is built behind
  // `wanted`, which is false until the facade shows, so a window that failed to
  // build is a failure the demand has already been answered against. It is not
  // silent either: `openPath` below answers `false` on a null item, and the
  // facade turns that into `refused: <url>` rather than `opened:`.
  property string startupError: ""

  // Whether the viewer is up, read off the facade rather than owned here: the
  // close settle and the lease both live there, and a second copy of the flag is
  // a second thing that can disagree with the window - whose `win.visible` binds
  // to the facade's own property, so the facade is the only writer.
  readonly property bool wanted: ImageViewer.visible

  // The window holder, or null while nothing is loaded. The holder and not the
  // `Window` it holds, because the holder is where the API lives: `openPath`
  // and `currentPath` are on it and a bare `Window` carries neither. Typed `var`
  // for the same reason - the holder is a QtObject, not a window type, and the
  // `Window` it holds is one level down from here.
  readonly property var window: windowLoader.item

  // Hand a URL to the window. The URL, not the path: the facade has already
  // resolved the argument and the window puts it straight into an `Image`
  // source, which is what a `file:` URL is for. Fixed arity, because the `app`
  // host forwards what it was given and Quickshell's IpcHandler enforces exact
  // arity.
  function openPath(path) {
    if (root.window === null || root.window === undefined) return false
    if (typeof root.window.openPath !== "function") return false
    return root.window.openPath(path) === true
  }

  // Close the viewer, through the facade and not around it. The window's
  // `win.visible` is bound to the facade, so setting anything here would be a
  // second writer the window could disagree with; the facade's own close verb
  // is what actually flips the flag, and the return value says whether the
  // window is shut afterwards.
  function close() {
    if (!ImageViewer.visible) return true
    return ImageViewer.close() === true
  }

  Component.onCompleted: {
    // The gate is the one construction step this object has: it reads the
    // facade singleton and the screen list, and neither read is something it
    // can do without. A throw would leave the facade holding a controller whose
    // window never opens, so it is turned into startupError instead of
    // propagating - a Loader cannot raise a construction error to its caller.
    try {
      root.gateOpen()
    } catch (ignored) {
      root.startupError = "startup"
    }
  }

  // Whether the window's own build may proceed, as a function rather than an
  // inline binding so the construction check above and the loader below are the
  // same piece of policy and cannot drift apart.
  function gateOpen() {
    if (!root.wanted) return false
    // A Window with no screen to place itself on is a surface the compositor
    // decides about, so the load waits for a real one. Ui.primaryScreen is
    // already filtered to screens with a name and a non-zero size, and it is
    // null before the first screen report arrives.
    return Ui.primaryScreen !== null && Ui.primaryScreen !== undefined
  }

  Loader {
    id: windowLoader
    // One window, built on demand and destroyed with this object: there is no
    // second copy of the viewer and nothing to reconcile, because the only
    // reference anyone holds is `root.window` above.
    active: root.gateOpen()
    sourceComponent: windowComp
  }

  Component {
    id: windowComp

    // No handoff and no required property. The window reads the facade's
    // `visible` for its own map and unmap, which is the entire lifecycle, so
    // there is nothing here the controller would have to pass in; handing the
    // facade in as well would be a second reference to one object for no gain.
    // The mixer does pass its controller in, and the reason is that its rows
    // read the graph through one owner - nothing here reads this object.
    ImageViewerWindow {}
  }
}