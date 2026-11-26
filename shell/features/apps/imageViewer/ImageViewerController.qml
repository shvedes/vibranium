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

  // Idempotent focus for an already open viewer. The mapped path asks the
  // live QuickWindow for activation; a window still waiting for a primary
  // screen is handled by its existing on-visible activation.
  function focusWindow() {
    if (root.window === null || root.window === undefined) return false
    const win = root.window.window
    if (win === null || win === undefined) return false
    win.requestActivate()
    return true
  }

  // The URL the facade's `openPath` verb asked for, published as live state
  // instead of handed to a window that may not exist yet.
  //
  // APP-1: on a cold shell the facade shows before `Ui.primaryScreen` resolves,
  // so `windowLoader` is still inactive when the verb arrives. The old code
  // handed the URL straight to a null window and reported `refused:`, and when
  // the screen gate opened the window built empty. The request now waits here:
  // the facade is the only writer, and the window DERIVES its initial content
  // from this property at construction (the real build edge), so an early
  // request is honoured rather than dropped. A later request overwrites this
  // one, which is exactly the supersession we want - the newest intent wins.
  property string requestedPath: ""

  // Hand a URL to the window. The URL, not the path: the facade has already
  // resolved the argument and the window puts it straight into an `Image`
  // source, which is what a `file:` URL is for. Fixed arity, because the `app`
  // host forwards what it was given and Quickshell's IpcHandler enforces exact
  // arity.
  //
  // APP-1: publish the request BEFORE looking for a window. If the screen gate
  // has not opened there is no window to hand to, but the intent is no longer
  // lost: it is live state above and the window reads it when it is built. The
  // verdict stays honest - an existing window answers for itself, and a
  // controller still waiting for a screen reports that the request has been
  // accepted into live state (it will converge) rather than refusing a valid
  // path. Validation remains the facade's job and is unchanged.
  function openPath(path) {
    const asked = path === undefined || path === null ? "" : String(path)
    if (asked === "") return false
    root.requestedPath = asked
    if (root.window === null || root.window === undefined) return true
    if (typeof root.window.openPath !== "function") return true
    return root.window.openPath(asked) === true
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

    // The window reads the facade's `visible` for its own map and unmap, so the
    // controller is not its lifecycle owner. It is handed in for one thing only
    // (APP-1): the `requestedPath` live state the window uses to seed its
    // content when it is built after a cold start. One reference, one reader,
    // and no second copy of the request on the window side.
    ImageViewerWindow {
      controller: root
    }
  }
}
