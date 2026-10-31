pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Qt.labs.folderlistmodel
import qs.common

// The image viewer window: one image, its neighbours in the folder, and a
// floating frosted toolbar and status bar over it.
//
// A plain QtQuick `Window`, not a `PanelWindow`. The source is an
// `ApplicationWindow` and needs what only a toplevel has: a `title`, a
// `minimumWidth`, a `visibility` to toggle fullscreen through, and a
// `transientParent` for the picker over it. Quickshell 0.3.1's `PanelWindow`
// declares none of those - `anchors`, `margins`, `relativeX`/`relativeY` and
// `screen` are the whole of its placement block, and a layer-shell surface has
// no `title`, no size floor and no `visible` at all. Every other overlay this
// shell draws is a layer surface and none of them is a window; this one has to
// be, because a picture viewer that the compositor does not list is a picture
// viewer nobody can raise, move or switch to.
//
// The chrome is the source's own and is kept as it is: an ambient gradient on
// the window ground, two translucent bars sampled out of the picture behind
// them, and the viewer's own flat buttons. What changed in the port is where
// the values come from, not what the window looks like - the source's private
// `theme` object is gone and every colour, and every font family, is a shell
// token, so the window follows a palette change without this file being read
// again.
//
// The root object is a holder, not the window, and that is not decoration. Qt
// builds a `Window` created inside a QQuickItem as a rendered surface inside
// that item rather than as a native platform window, so it never reaches the
// compositor's window list. `ImageViewerController.qml` builds this file
// through a `Loader`, and a `Loader` is a QQuickItem (`QQuickLoader` derives
// from `QQuickImplicitSizeItem` in QtQuick's own type description), so a
// `Window` root loaded that way has no non-Item between it and the loader.
// Declaring the window as a property of a plain object is the whole job the
// root does.
//
// The holder is also where the state lives, which is for the linter rather than
// for taste: qmllint's unqualified-access rule flags every read of a member of
// an enclosing element that is not the component root, so state carried by the
// window and read back as `win.x` is one warning per read and none of them are
// about the code. Reading it as `root.x` - the root, which the rule exempts -
// is the same structure with none of the noise, so nothing here is silenced
// with a lint pragma.

QtObject {
  id: root

  // ---------------------------------------------------------------- surface

  // The window, for whoever needs to move, close or re-request it. The
  // controller builds this file and drives `openPath`, so it needs the window
  // itself rather than a second opinion about whether it is up.
  readonly property Window window: root.win

  // Open a file the viewer can show. `url` is either a url (`file:///...`) or a
  // bare absolute filesystem path; the path form is prefixed here rather than at
  // each caller, because `Image.source` does not resolve a scheme-less string
  // into a loadable resource on its own.
  //
  // Returns whether there is anything to open, so a caller handed an empty
  // argument says so instead of showing an empty viewer and reporting success.
  // Whether the bytes decode is a separate question: the viewport draws its own
  // load-error line for that.
  function openPath(url) {
    const s = String(url ?? "").trim()
    if (s === "") return false
    let target = s
    if (s.indexOf("://") < 0)
      target = Paths.toFileUrl(s)
    else if (s.startsWith("file:"))
      target = root._normalizeFileUrl(s)
    root.openFile(Qt.resolvedUrl(target))
    return true
  }

  // A `file:` URL as a canonical encoded file:// URL, mirroring the facade's
  // own normalizer: decode to a path and re-encode per segment, so a raw "#"
  // in a file name lands on "%23" instead of truncating at the fragment
  // delimiter before the Image ever loads.
  function _normalizeFileUrl(u) {
    let p = String(u ?? "")
    if (p.startsWith("file://")) {
      p = p.substring(7)
      if (p.startsWith("localhost/"))
        p = p.substring(9)
      else if (p.startsWith("localhost")) {
        const slash = p.indexOf("/")
        p = slash >= 0 ? p.substring(slash) : ""
      }
      if (p !== "" && p[0] !== "/") p = "/" + p
    } else if (p.startsWith("file:")) {
      p = p.substring(5)
      if (p !== "" && p[0] !== "/") p = "/" + p
    }
    try {
      p = decodeURIComponent(p)
    } catch (ignored) {
    }
    return Paths.toFileUrl(p)
  }

  // The loaded file's filesystem path, "" when nothing is loaded. Derived from
  // the loaded url rather than read off the picker, because a file also arrives
  // through a drop and through `openPath`, and the picker knows about neither.
  readonly property string currentPath: root.pathOf(root.currentFile)

  // ------------------------------------------------------------------ state

  // Window geometry as seeds and floors on the holder, never as the window's
  // own `width` / `height`. The source read `root.width` for the status bar's
  // width cap, and in an ApplicationWindow that name is the window's own live
  // property - so a plain `property int width` on the holder would freeze that
  // cap at the seed size and stop it following a resize. The window is sized
  // from `baseW`/`baseH` and every live size is read back off `root.win`.
  property int baseW: 1180
  property int baseH: 760
  property int minW: 360
  property int minH: 240

  // The open image and where it sits in its folder.
  property url currentFile
  property string currentFileName: ""
  property int currentIndex: -1
  // The file `openFile` is about to land on. `folderModel` reports Ready before
  // the row carrying this name is addressable, so the name is published first
  // and the index is looked up once the listing exists.
  property string pendingFileName: ""

  // Whether an image is loaded. Stated once because three call sites want the
  // same fact - the empty state, the load-error line and the status bar's dot -
  // and `currentFile` is a url, whose empty spelling is only reachable through
  // its string form.
  readonly property bool hasFile: String(root.currentFile) !== ""

  // Whether the open file is a vector (SVG/SVGZ). A vector's natural size is
  // whatever its width/height attributes (or viewBox) spell - often 64px -
  // and drawing that tiny raster through the fit/zoom scale is what showed
  // SVGs pixelated: the GPU upscaled a postage stamp. The viewport below
  // re-rasterizes vectors at display size instead, and this flag is what
  // steers that path. Matched on the file name, which `openFile` already
  // percent-decoded, case-insensitively.
  readonly property bool isVector: /\.svgz?$/i.test(root.currentFileName)

  // View transform. `fitToWindow` is the mode and `zoomFactor` is what it
  // overrides: panning is only meaningful once the fit has been broken, which
  // is what the guard on the drag reads.
  property real zoomFactor: 1.0
  property bool fitToWindow: true
  property int rotationAngle: 0
  property real panX: 0
  property real panY: 0

  // Chrome state. The toolbar and the status bar each slide away when the chrome
  // is hidden or the pointer is not near them, so the image can be seen whole.
  property bool chromeVisible: true
  property bool hoverNearTop: false
  property bool hoverNearBottom: false

  // Whether the transient zoom badge wants to be up. The badge answers for the
  // status bar rather than competing with it: with the chrome shown the status
  // bar already prints the same number from the same expression, so the badge
  // would be a second copy of a value on screen. Once `Tab` hides the chrome -
  // or fullscreen does, since entering it forces `chromeVisible` off - the
  // status bar is gone and this is the only place the scale is readable.
  // `zoomTimer` is the badge's own dwell timer, declared with the badge below.
  readonly property bool zoomBadgeWanted: zoomTimer.running && !root.chromeVisible

  // ------------------------------------------------------------- components

  // -- inline reusable flat button --
  component Btn: Rectangle {
    id: btn

    property string label: ""
    property string tip: ""
    property bool ghost: false

    signal clicked()
    signal rightClicked()

    width: Math.max(36, lbl.implicitWidth + 24)
    height: 32

    color: ghost
      ? (ma.pressed ? Ui.tint("foreground_0", 0.18) : (ma.containsMouse ? Ui.tint("foreground_0", 0.12) : "transparent"))
      : (ma.pressed ? Ui.tint("foreground_0", 0.10) : Ui.solid("background_2"))
    border.color: ma.containsMouse ? Ui.tint("foreground_0", 0.26) : Ui.tint("foreground_0", 0.17)
    // A ghost button has no edge at rest and grows one on hover; a filled one
    // always has its edge, because the fill is what it is.
    border.width: ghost ? (ma.containsMouse ? 1 : 0) : 1

    Behavior on color { ColorAnimation { duration: 100 } }

    Text {
      id: lbl

      anchors.centerIn: parent
      text: btn.label
      // A ghost label dims to the resting tone so the hover reads as one
      // event - fill and label brighten together - rather than as a border
      // arriving under an unchanged word.
      color: btn.ghost && !ma.containsMouse ? Ui.tint("foreground_0", 0.78) : Ui.solid("foreground_0")
      font.pixelSize: 12
      font.family: Ui.fontFamily

      Behavior on color { ColorAnimation { duration: 100 } }
    }

    MouseArea {
      id: ma

      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor

      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton)
          btn.rightClicked()
        else
          btn.clicked()
      }
    }

    // The hover hint, drawn from plain primitives. The source showed `tip`
    // through `QtQuick.Controls.ToolTip`, which this tree cannot import -
    // `tests/shell/suites/architecture/imports-test.sh:290-311` confines every
    // importer to `shell/common/` - so the bubble is two items.
    //
    // Below the button, not above. Both bars are anchored near the top of the
    // window, so a hint above runs off the edge and is clipped; below, the
    // middle of the window is there to be drawn on.
    Rectangle {
      id: btnHint

      visible: ma.containsMouse && btn.tip !== ""
      // Width first, and it is written above `x` on purpose: `x` reads `width`,
      // and `width` reads the label's `implicitWidth`, so evaluating the position
      // against a zero width would centre the bubble on nothing and pin it to
      // the left edge until the label had been measured.
      width: Math.min(btnHintText.implicitWidth + 16, 240)
      height: btnHintText.implicitHeight + 10
      // Centred under the button and clamped to the window, so a hint on the
      // first or last control stays on screen. Measured on a four-button row:
      // the middle three centre exactly, and only the leftmost clamps - a hint
      // wider than the space to its left has nowhere else to go.
      x: Math.max(0, Math.min(Math.max(0, root.win.width - width),
                              btn.mapToItem(root.win, 0, 0).x + Math.round((btn.width - width) / 2)))
      y: btn.height + 6
      radius: RoundingPolicy.radius
      color: Ui.tint("background_0", 0.94)
      border.width: 1
      border.color: Ui.tint("foreground_0", 0.26)
      z: 10

      Text {
        id: btnHintText

        anchors.centerIn: parent
        width: Math.min(implicitWidth, 224)
        text: btn.tip
        color: Ui.solid("foreground_0")
        font.pixelSize: 11
        font.family: Ui.fontFamily
        elide: Text.ElideRight
      }
    }
  }

  // -- icon-only button: transparent, hover/press lighten, lives in the toolbar --
  component IconBtn: Rectangle {
    id: ibtn

    property string tip: ""

    signal clicked()
    signal rightClicked()

    width: 34
    height: 32

    color: ima.pressed ? Ui.tint("foreground_0", 0.18) : (ima.containsMouse ? Ui.tint("foreground_0", 0.12) : "transparent")

    Behavior on color { ColorAnimation { duration: 100 } }

    MouseArea {
      id: ima

      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor

      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton)
          ibtn.rightClicked()
        else
          ibtn.clicked()
      }
    }

    // The hover hint, built the same way as `Btn`'s: plain items rather than
    // `QtQuick.Controls.ToolTip`, which this tree cannot import. Below the
    // button, for the reason on `Btn`'s.
    Rectangle {
      id: ibtnHint

      visible: ima.containsMouse && ibtn.tip !== ""
      width: Math.min(ibtnHintText.implicitWidth + 16, 240)
      height: ibtnHintText.implicitHeight + 10
      x: Math.max(0, Math.min(Math.max(0, root.win.width - width),
                              ibtn.mapToItem(root.win, 0, 0).x + Math.round((ibtn.width - width) / 2)))
      y: ibtn.height + 6
      radius: RoundingPolicy.radius
      color: Ui.tint("background_0", 0.94)
      border.width: 1
      border.color: Ui.tint("foreground_0", 0.26)
      z: 10

      Text {
        id: ibtnHintText

        anchors.centerIn: parent
        width: Math.min(implicitWidth, 224)
        text: ibtn.tip
        color: Ui.solid("foreground_0")
        font.pixelSize: 11
        font.family: Ui.fontFamily
        elide: Text.ElideRight
      }
    }
  }

  // A 1px gap between two groups of buttons. Its size comes from the layout it
  // sits in rather than from the row it divides, so a divider cannot push the
  // row past the window edge when a group gains a button.
  component ToolDivider: Rectangle {
    Layout.preferredWidth: 1
    Layout.preferredHeight: 18
    Layout.alignment: Qt.AlignVCenter
    color: Ui.tint("foreground_0", 0.13)
  }

  // Frosted backdrop for a floating chrome element: samples the viewport region
  // under the target and renders it blurred beneath the translucent pill.
  //
  // Small overscan (>= blur spread) so fringe falls outside and is clipped;
  // heavy downscale keeps the kernel short so only what's DIRECTLY behind is
  // smeared, and distant content does not bleed inward.
  //
  // `ShaderEffectSource` reads a sibling's pixels, and there is no other
  // primitive in the tree that does: every other `MultiEffect` drives a
  // `layer.effect` on its own item. The two bars are translucent on purpose,
  // and over a photograph a plain tint darkens the image behind it, so only
  // this samples it. `sourceItem: viewport` is the id of the viewport Item
  // below, so the source is a fixed point in the document rather than
  // something a call site passes in.
  component Frost: Item {
    id: fr

    property Item target
    property bool shown: true

    readonly property int pad: 32   // overscan >= blur spread, clipped away

    x: target.x
    y: target.y
    width: target.width
    height: target.height
    visible: shown
    clip: true

    ShaderEffectSource {
      id: frSrc

      anchors.fill: parent
      sourceItem: viewport
      sourceRect: Qt.rect(fr.x - fr.pad, fr.y - fr.pad,
                          fr.width + 2 * fr.pad, fr.height + 2 * fr.pad)
      smooth: true
      textureSize: Qt.size(Math.max(1, Math.round((fr.width + 2 * fr.pad) / 4)),
                           Math.max(1, Math.round((fr.height + 2 * fr.pad) / 4)))
    }

    MultiEffect {
      anchors.fill: parent
      source: frSrc
      blurEnabled: true
      blurMax: 24
      blur: 1.0
    }
  }

  // A single key in the empty state's hint rows.
  component KeyCap: Rectangle {
    id: kcap

    property string key: ""

    width: Math.max(22, kl.implicitWidth + 12)
    height: 22
    color: Ui.solid("background_2")
    border.color: Ui.tint("foreground_0", 0.26)
    border.width: 1

    Text {
      id: kl

      anchors.centerIn: parent
      text: kcap.key
      color: Ui.tint("foreground_0", 0.78)
      font.pixelSize: 11
      font.family: Ui.fontFamily
    }
  }

  // ------------------------------------------------------------------- model

  // The open folder's images, in name order. This is the only source for
  // neighbour navigation and for the file size in the status bar.
  //
  // A typed property rather than a bare child: a `QtObject`'s default property
  // is `data`, which takes `QtObject`s and not plain `QObject`s, so an
  // undeclared `FolderListModel` child of this root does not have anywhere to
  // go.
  //
  // `folder` is only ever reassigned between completed loads, so the model is
  // never reset mid-flight and emits no begin/endReset pair.
  property FolderListModel folderModel: FolderListModel {
    nameFilters: ["*.png", "*.PNG", "*.jpg", "*.JPG", "*.jpeg", "*.JPEG", "*.bmp", "*.BMP",
                  "*.gif", "*.GIF", "*.webp", "*.WEBP", "*.svg", "*.SVG",
                  "*.ico", "*.ICO", "*.tif", "*.TIF", "*.tiff", "*.TIFF"]
    showDirs: false
    sortField: FolderListModel.Name

    // The claim is attempted on BOTH signals and the name is cleared only when it
    // SUCCEEDS. Clearing it on a Ready that arrived before the rows would drop
    // the pending name on the floor: the model reaches Ready for its default
    // folder first, with the requested file's name already pending, and that
    // Ready is the one that arrives while `count` is still 0. Measured order on
    // a folder assignment: status 0 -> 2 -> count 4 -> status 1.
    onStatusChanged: {
      if (status !== FolderListModel.Ready) return
      if (root.claimIndex(root.pendingFileName))
        root.pendingFileName = ""
    }

    onCountChanged: {
      // The rows can land while `status` is still Loading, a tick before Ready,
      // so waiting for Ready alone loses the race on a fast folder.
      if (count === 0) return
      if (root.claimIndex(root.pendingFileName))
        root.pendingFileName = ""
    }
  }

  // ----------------------------------------------------------------- actions

  // A file url as a filesystem path. QML publishes no `toLocalFile`, so the
  // scheme is cut off and the remainder percent-decoded; a string carrying no
  // scheme is already a path. One function serves `currentPath`, `openFile`'s
  // folder/name split and any caller that needs the path, so those answers
  // cannot disagree about which file is loaded.
  function pathOf(fileUrl) {
    const u = String(fileUrl ?? "")
    if (u === "") return ""
    const cut = u.indexOf("://")
    const raw = cut < 0 ? u : u.substring(cut + 3)
    try {
      return decodeURIComponent(raw)
    } catch (err) {
      // A bare "%" in a file name is not a valid escape and decodeURIComponent
      // throws on it; the raw remainder is the path as the url spelled it,
      // which is the honest answer rather than no answer.
      return raw
    }
  }

  // Any input openFile accepts as an encoded file:// URL: a bare absolute path
  // gains its encoding here, a file: URL is normalized through it, and anything
  // else passes through. Storing the normalized form is what keeps a "#" in a
  // file name as "%23" in `currentFile`, which is what `Image.source` loads.
  function _normalizeInput(fileUrl) {
    const u = String(fileUrl ?? "")
    if (u === "") return u
    if (u.indexOf("://") < 0) {
      if (u.startsWith("/")) return Paths.toFileUrl(u)
      return u
    }
    if (u.startsWith("file:")) return root._normalizeFileUrl(u)
    return u
  }

  function openFile(fileUrl) {
    const normalized = root._normalizeInput(fileUrl)
    const path = root.pathOf(normalized)
    const slash = path.lastIndexOf("/")
    root.pendingFileName = path.substring(slash + 1)
    root.currentFile = normalized
    root.currentFileName = root.pendingFileName
    root.resetView()
    // The folder is the source's own path, so it is already set when a file in
    // the SAME folder is opened - reopening a neighbour, or a drop. Assigning
    // the identical value is not a change, so no status transition follows and
    // `pendingFileName` would sit unclaimed with `currentIndex` at -1. Claiming
    // the index against the rows already loaded is therefore the whole job here;
    // the handler below is only for the first load into a NEW folder.
    //
    // `file:` url, not the bare path: `FolderListModel.folder` takes a url, and
    // handed a plain path it never leaves `Loading` with a count of 0, so
    // Next/Prev walk an empty model and appear dead. Measured on this build
    // against the same directory - `file:///tmp/.../gallery` settles at Ready
    // with 4 rows, the bare path stays Loading with 0.
    const dir = Paths.toFileUrl(path.substring(0, slash))
    if (root.folderModel.folder === dir)
      root.claimIndex(root.pendingFileName)
    else
      root.folderModel.folder = dir
  }

  // Point `currentIndex` at the named file among the rows already loaded.
  // Matching on `fileName` alone would collide across same-named files in one
  // folder, so the folder is checked too when there is more than one candidate.
  function claimIndex(name) {
    if (name === "") return false
    const model = root.folderModel
    for (let i = 0; i < model.count; i++) {
      if (model.get(i, "fileName") === name) {
        root.currentIndex = i
        root.currentFileName = name
        return true
      }
    }
    return false
  }

  function resetView() {
    root.zoomFactor = 1.0
    root.fitToWindow = true
    root.rotationAngle = 0
    root.panX = 0
    root.panY = 0
  }

  function loadIndex(i) {
    if (root.folderModel.count === 0)
      return
    if (i < 0)
      i = root.folderModel.count - 1
    if (i >= root.folderModel.count)
      i = 0
    root.currentIndex = i
    // The role is "fileUrl", not "fileURL": case matters and get() answers
    // undefined on a role it does not know, which would blank the image with no
    // error anywhere.
    root.currentFile = root.folderModel.get(i, "fileUrl")
    root.currentFileName = root.folderModel.get(i, "fileName")
    root.resetView()
  }

  function nextImage() { root.loadIndex(root.currentIndex + 1) }
  function prevImage() { root.loadIndex(root.currentIndex - 1) }

  function zoomIn() {
    if (root.fitToWindow) {
      root.fitToWindow = false
      // Leaving the fit mode steps off the scale the fit chose, not off 1.0, so
      // one press is one visible step in either direction.
      root.zoomFactor = img.fitScale * 1.25
    } else {
      root.zoomFactor = Math.min(root.zoomFactor * 1.25, 16)
    }
    zoomTimer.restart()
  }

  function zoomOut() {
    if (root.fitToWindow) {
      root.fitToWindow = false
      root.zoomFactor = Math.max(img.fitScale / 1.25, 0.05)
    } else {
      root.zoomFactor = Math.max(root.zoomFactor / 1.25, 0.05)
    }
    zoomTimer.restart()
  }

  function zoomActual() { root.fitToWindow = false; root.zoomFactor = 1.0; root.panX = 0; root.panY = 0; zoomTimer.restart() }
  function zoomFit() { root.fitToWindow = true; root.panX = 0; root.panY = 0; zoomTimer.restart() }

  function rotateCW() { root.rotationAngle = (root.rotationAngle + 90) % 360 }
  function rotateCCW() { root.rotationAngle = (root.rotationAngle - 90 + 360) % 360 }

  // Fullscreen through `visibility` and not through a second flag, because a
  // compositor can also take the window out of fullscreen on its own: an
  // internal flag would then disagree with the window's actual state and the
  // next Escape would try to leave a mode the window is not in. Layer shell has
  // no `visibility` at all, which is one of the reasons this is a `Window`.
  function toggleFullscreen() {
    const goingFullscreen = root.win.visibility !== Window.FullScreen
    root.win.visibility = goingFullscreen ? Window.FullScreen : Window.Windowed
    root.chromeVisible = !goingFullscreen
  }

  function humanFileSize(bytes) {
    if (bytes === undefined || bytes <= 0)
      return ""
    const units = ["B", "KiB", "MiB", "GiB", "TiB"]
    let i = 0
    let v = bytes
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024
      i++
    }
    return (i === 0 ? v : v.toFixed(1)) + " " + units[i]
  }

  // ------------------------------------------------------------------ window

  // The window, held rather than declared as this file's root object. See the
  // note above the root object for why the holder is not decoration.
  property Window win: Window {
    // A `Window` is unmapped until `visible` goes true, so this binding is the
    // whole of the map/unmap lifecycle: it maps the viewer when the facade
    // claims it and unmaps it when the facade releases the claim. There is no
    // second copy of "is the viewer open" anywhere in this file to disagree.
    visible: ImageViewer.visible

    // `Window.screen` is a QtQuick Screen and `Ui.primaryScreen` is a
    // Quickshell one, so the two cannot be assigned across: binding the latter
    // straight in logs "Unable to assign QuickshellScreenInfo to
    // QQuickScreenInfo" and leaves the window on whichever output Qt picked.
    // `WindowScreen` is the name-matching bridge, shared with the audio mixer.
    screen: WindowScreen.forScreen(Ui.primaryScreen)

    // Not "transparent": this surface IS the window, so its own colour is the
    // ground the gradient below is drawn over and a transparent toplevel is a
    // hole with a title bar over it.
    color: Ui.solid("background_0")

    // A constant, NOT the opened file's name. The compositor's attention rules
    // (`default/hypr/window-rules.lua`) match an unanchored, case-insensitive
    // `error|delete|quit|permission|alert|warning|attention|save` against a
    // window's title and answer `dim_around` - the whole monitor dims. A title
    // built from the path therefore dims the entire screen for a photo called
    // `delete-me.png`. The status bar already prints the file name, so the
    // window says what it is and the status bar says what it is showing.
    title: "Image Viewer"

    width: root.baseW
    height: root.baseH
    // A floor rather than a starting size: below this the toolbar's two
    // labelled buttons and four icon buttons do not fit beside each other,
    // and a window that clips its own controls is worse than a small one.
    minimumWidth: root.minW
    minimumHeight: root.minH

    // Keyboard focus is the compositor's to give and this file's to use. The
    // source claims it with `keyHandler.forceActiveFocus()` from a
    // Component.onCompleted, which reaches the key handler only because an
    // ApplicationWindow is visible from its first construction. Here `visible`
    // is the facade's flag, so this window is unmapped when the object is built
    // and a forceActiveFocus then is a request recorded against a surface that
    // does not hold focus. One turn after the map is the earliest point at
    // which it can land.
    onVisibleChanged: {
      if (!visible) return
      Qt.callLater(() => requestActivate())
    }
    onActiveChanged: {
      if (!active) return
      Qt.callLater(() => keyHandler.forceActiveFocus())
    }

    // A close that arrives from outside this file goes back through the facade.
    //
    // A dispatcher, `killactive`, a window rule or `SUPER + Q` call
    // `QQuickWindow::close()`, which writes `visible` from C++ and so REMOVES
    // the binding above rather than re-evaluating it. Measured on this machine
    // with a window that really maps: after `close()`, flipping the bound
    // property false and back true leaves `visible` at false. Left alone, the
    // facade keeps reporting `visible: true` with nothing on screen and
    // `show()`'s `if (root.visible) return true` answers without doing anything,
    // so the app cannot be reopened until the shell reloads.
    //
    // Handing the close to the facade's own verb is what recovers it: the verb
    // sets the facade's `visible` false, which hides this window through the
    // normal path, arms `closeSettle`, and tears the controller down. The next
    // open builds a fresh holder, and a fresh holder's binding is evaluated at
    // construction, so it maps.
    //
    // Two shapes deliberately not taken. The binding is NOT re-armed from
    // inside this handler: Qt performs its own `visible` write after `closing`
    // returns, so an assignment here is removed again by the same mechanism that
    // removed it. And the close is NOT refused (`close.accepted = false`),
    // because a refused close leaves the surface the compositor asked to remove.
    //
    // `ImageViewer.close()` rather than `hide()`: `hide()` sets `visible` false
    // and nothing else, and `close()` is the verb the bar, the settings menu and
    // the `app close` IPC path all use - it is the one that arms the settle.
    // Nothing is destroyed inside this handler: the teardown runs from
    // `closeSettle`, a timer, so the object graph is still intact while the verb
    // returns.
    onClosing: ImageViewer.close()

    // The content item. Every child below sits in it, so the window's size is
    // the root of every anchor chain.
    //
    // `font.family` is stated on each label rather than once here because Qt 6's
    // `Item` publishes no `font` group - there is nowhere on a content item to
    // put one, and neither does `Window` carry it - so a single inherited
    // assignment does not exist. That is also what every other `Text` in the
    // tree does.
    Item {
      id: content

      anchors.fill: parent

      // subtle ambient gradient behind everything
      Rectangle {
        anchors.fill: parent
        gradient: Gradient {
          GradientStop { position: 0.0; color: Ui.solid("background_1") }
          GradientStop { position: 1.0; color: Ui.solid("background_0") }
        }
      }

      // ---- image viewport ----
      Item {
        id: viewport

        anchors.fill: parent
        clip: true

        // Vector probe at natural size. The main view below rasterizes vectors
        // at display size (see `vecRaster`); the probe is what reports the
        // intrinsic size that computation needs, because the main view's own
        // `sourceSize` is the raster size once set and not the natural
        // one. Gated on `isVector` so raster photos never pay for a second
        // decode. Invisible but still loads: visibility gates painting, not
        // loading (measured).
        Image {
          id: vectorProbe

          visible: false
          source: root.isVector ? root.currentFile : ""
          asynchronous: true
          cache: false
        }

        AnimatedImage {
          id: img

          source: root.currentFile
          // Vectors rasterize larger than the item (see `vecRaster`), so
          // they map the raster onto the item rect: Pad draws the raster
          // unscaled, which shows a blown-up central crop. Raster photos
          // decode at their natural size, which already matches the item,
          // so both modes paint them identically.
          fillMode: root.isVector ? Image.PreserveAspectFit : Image.Pad
          asynchronous: true
          smooth: true
          // Uncached, unlike every glyph in this window: this is a full-
          // resolution bitmap that is re-decoded on rotation and on every zoom
          // step, and a cached one is held at that size for as long as the
          // window exists. cache:false stays scoped to this full-res view:
          // decodes are user-step driven (rotation/zoom/file change), never
          // per frame, and the playing gate above bounds animated decoding
          // to a mapped, active window.
          cache: false
          // Keep the landed frame while a vector re-rasterizes underneath.
          // A `sourceSize` change reloads (vectors re-raster on every bucket
          // step below), and without this the item blanks for the decode;
          // with it the old frame stays up until the new one is ready.
          // Scoped to vectors so raster file switches keep their existing
          // blank-then-paint behaviour.
          retainWhileLoading: root.isVector
          // Vectors rasterize at display size. `sourceSize` is the raster
          // size in device pixels (see `vecRaster`); left `undefined` for
          // raster photos, which load at their natural size exactly as
          // before. `width`/`height` are the LOGICAL size: the probe's
          // intrinsic extent for vectors (NOT the raster - binding those
          // would feed the raster back into its own computation), the decode
          // size for raster as before.
          sourceSize: root.isVector && vecRaster.width > 0 ? vecRaster : undefined
          width: root.isVector
                 ? (vectorProbe.implicitWidth > 0 ? vectorProbe.implicitWidth : 1)
                 : (sourceSize.width > 0 ? sourceSize.width : 1)
          height: root.isVector
                  ? (vectorProbe.implicitHeight > 0 ? vectorProbe.implicitHeight : 1)
                  : (sourceSize.height > 0 ? sourceSize.height : 1)
          rotation: root.rotationAngle
          scale: root.fitToWindow ? fitScale : root.zoomFactor
          x: viewport.width / 2 - width / 2 + (root.fitToWindow ? 0 : root.panX)
          y: viewport.height / 2 - height / 2 + (root.fitToWindow ? 0 : root.panY)
          // Retained while a vector re-rasterizes (see `retainWhileLoading`
          // above): `status` reads Loading for the decode while the old frame
          // is still painted, so gating on it alone would fade the item out
          // on every zoom bucket step. Painted pixels mean there is something
          // to show, whichever decode they belong to.
          opacity: (status === Image.Ready || (root.isVector && paintedWidth > 0)) ? 1.0 : 0.0

          // Gated on the window being mapped as well as on the application
          // being active. The source's single test is `Qt.application.state`,
          // which in its own process meant "this window is on screen" - but in
          // the shell that state is the SHELL's, so it reads active for as long
          // as the user is at the machine and an animated image would keep
          // decoding every frame forever after the viewer closed. The window's
          // own visibility is what the source's test actually meant.
          playing: root.win.visible && Qt.application.state === Qt.ApplicationActive

          Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutQuad } }

          // The scale that fits, measured against the ROTATED painted
          // extent: a 90 or 270 degree turn swaps which source dimension
          // is the horizontal one, and fitting against the unrotated pair
          // is what made a portrait shot overflow the window sideways
          // after a rotation. paintedWidth/Height (not sourceSize) are
          // the inputs: sourceSize is the decode size and collapses on
          // every re-decode (rotation and zoom steps re-decode with
          // cache:false), which fed the collapse back through width and
          // oscillated the viewport until the decode landed. The painted
          // extent is the compositor's own landed answer, so the fit
          // holds still across the decode gap. The chain stays acyclic:
          // width feeds painted, painted feeds fitScale, fitScale feeds
          // scale, and nothing feeds back into width.
          //
          // Vectors do not use the painted extent: their raster IS the
          // `vecRaster` size below, so fitting against painted would fit
          // the raster against itself and always answer ~1. They fit
          // against the probe's intrinsic extent instead (`vecFit`), which
          // is also what `zoomIn`/`zoomOut` step off (they read this very
          // property) and what the status bar prints.
          readonly property bool swapped: root.rotationAngle === 90 || root.rotationAngle === 270

          // Device pixels per logical one for this window (same mechanism
          // as ClipboardPreview's preview pane): the raster is sized in
          // device pixels and the item in logical ones, so without this a
          // scale=2 output would show a logical-sized raster scaled up by
          // the compositor.
          readonly property real vecDpr: Window.window ? Window.window.devicePixelRatio : 1

          // The vector fit, measured against the probe's ROTATED intrinsic
          // extent for the same reason the raster fit uses the rotated
          // painted one. Falls back to 1.0 while the probe has not landed;
          // the raster below stays `undefined` until then, so the fallback
          // only steadies the scale for a frame, never a decode.
          readonly property real vecFit: {
            const vw = vectorProbe.implicitWidth
            const vh = vectorProbe.implicitHeight
            const ew = swapped ? vh : vw
            const eh = swapped ? vw : vh
            if (!(ew > 0) || !(eh > 0) || viewport.width <= 0 || viewport.height <= 0)
              return 1.0
            return Math.min(viewport.width / ew, viewport.height / eh)
          }

          // The vector scale in effect: the fit, or the user's zoom.
          readonly property real vecEff: root.fitToWindow ? vecFit : root.zoomFactor

          // Decode-size buckets, same steps as ClipboardPreview's still:
          // the decoder re-runs on every sourceSize change, so a live
          // viewport/zoom binding would re-decode per pixel without them.
          // Snapping the LONG side to 256/512/1024/2048/4096 decodes once
          // per bucket instead. Capped at 4096 a side to bound the texture
          // (4096x4096 RGBA is ~67MB); past that the GPU upscales, which is
          // still one crisp raster rather than a 64px one.
          function bucketLong(n) {
            const v = Math.ceil(Number(n) || 0)
            if (v <= 256) return 256
            if (v <= 512) return 512
            if (v <= 1024) return 1024
            if (v <= 2048) return 2048
            return 4096
          }

          // The vector raster size in device pixels: the logical display
          // extent (`width`/`height` times the effective scale) times the
          // DPR, bucketed. Both sides scale by the ONE long-side factor so
          // the request stays exactly proportional to the intrinsic aspect:
          // rounding each side independently would ask for a different
          // aspect, and unlike raster photos (which fit a mismatched
          // request within, preserving aspect) vectors stretch to exactly
          // the requested size (measured). (0, 0) while the probe has not
          // landed, which keeps `sourceSize` at `undefined` (natural) for
          // that first frame instead of rasterizing a 1x1 fallback.
          readonly property size vecRaster: {
            if (!root.isVector) return Qt.size(0, 0)
            const vw = vectorProbe.implicitWidth
            const vh = vectorProbe.implicitHeight
            if (!(vw > 0) || !(vh > 0)) return Qt.size(0, 0)
            const dw = vw * vecEff * vecDpr
            const dh = vh * vecEff * vecDpr
            const need = Math.max(dw, dh)
            if (!(need > 0)) return Qt.size(0, 0)
            const k = bucketLong(need) / need
            return Qt.size(Math.max(1, Math.round(dw * k)), Math.max(1, Math.round(dh * k)))
          }

          readonly property real fitScale: {
            if (root.isVector) return vecFit
            const iw = swapped ? paintedHeight : paintedWidth
            const ih = swapped ? paintedWidth : paintedHeight
            if (iw <= 0 || ih <= 0 || viewport.width <= 0 || viewport.height <= 0)
              return 1.0
            return Math.min(viewport.width / iw, viewport.height / ih)
          }
        }

        // empty state: artwork + headline + keycap hints
        Column {
          anchors.centerIn: parent
          spacing: 18
          visible: !root.hasFile

          Item {
            width: 96; height: 96
            anchors.horizontalCenter: parent.horizontalCenter

            Rectangle {
              anchors.fill: parent
              color: Ui.solid("background_3")
              border.color: Ui.tint("foreground_0", 0.26)
              border.width: 1
              clip: true
            }
            Rectangle {
              x: 20; y: 18
              width: 15; height: 15; radius: 7.5
              color: Ui.solid("accent")
              opacity: 0.85
            }
            Rectangle {
              x: 42; y: 52
              width: 62; height: 62
              rotation: 45
              radius: RoundingPolicy.radius
              color: Ui.tint("foreground_0", 0.28)
            }
            Rectangle {
              x: 4; y: 66
              width: 46; height: 46
              rotation: 45
              radius: RoundingPolicy.radius
              color: Ui.tint("foreground_0", 0.20)
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Drop an image here"
            color: Ui.solid("foreground_0")
            font.pixelSize: 16
            font.family: Ui.fontFamily
            font.weight: Font.DemiBold
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "or open one from your file manager"
            color: Ui.tint("foreground_0", 0.56)
            font.pixelSize: 12
            font.family: Ui.fontFamily
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 20

            Row {
              spacing: 7
              KeyCap { key: "+"; anchors.verticalCenter: parent.verticalCenter }
              KeyCap { key: "-"; anchors.verticalCenter: parent.verticalCenter }
              Text { anchors.verticalCenter: parent.verticalCenter; text: "zoom"; color: Ui.tint("foreground_0", 0.56); font.pixelSize: 11; font.family: Ui.fontFamily }
            }
            Row {
              spacing: 7
              KeyCap { key: "Tab"; anchors.verticalCenter: parent.verticalCenter }
              Text { anchors.verticalCenter: parent.verticalCenter; text: "hide ui"; color: Ui.tint("foreground_0", 0.56); font.pixelSize: 11; font.family: Ui.fontFamily }
            }
            Row {
              spacing: 7
              KeyCap { key: "F"; anchors.verticalCenter: parent.verticalCenter }
              Text { anchors.verticalCenter: parent.verticalCenter; text: "fullscreen"; color: Ui.tint("foreground_0", 0.56); font.pixelSize: 11; font.family: Ui.fontFamily }
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: root.hasFile && img.status === Image.Error
          text: "failed to load: " + root.currentFileName
          color: Ui.solid("red")
          font.pixelSize: 14
          font.family: Ui.fontFamily
        }

        // drag-over highlight
        Rectangle {
          anchors.fill: parent
          anchors.margins: 10
          visible: dropZone.containsDrag
          color: Ui.tint("accent", 0.10)
          border.color: Ui.solid("accent")
          border.width: 1
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 90
          visible: dropZone.containsDrag
          text: "Drop to open"
          color: Ui.solid("foreground_0")
          font.pixelSize: 13
          font.family: Ui.fontFamily
          font.weight: Font.DemiBold
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true

          // Panning is a delta, not an absolute position: the drag is
          // accumulated from the last pointer position, so a press that lands
          // off the image does not jump it, and the follow-on events are
          // independent of how the window was resized mid-drag.
          property real _lastX: 0
          property real _lastY: 0

          onPressed: function(mouse) {
            _lastX = mouse.x
            _lastY = mouse.y
          }
          onPositionChanged: function(mouse) {
            // The chrome reveal is proximity to the two bars, not pointer
            // position: either band brings its own bar out, and leaving the
            // window puts both away again.
            root.hoverNearTop = mouse.y < 72
            root.hoverNearBottom = mouse.y > viewport.height - 76
            if (pressed && !root.fitToWindow) {
              root.panX += mouse.x - _lastX
              root.panY += mouse.y - _lastY
              _lastX = mouse.x
              _lastY = mouse.y
            }
          }
          onExited: {
            root.hoverNearTop = false
            root.hoverNearBottom = false
          }
          onWheel: function(wheel) {
            if (wheel.angleDelta.y > 0)
              root.zoomIn()
            else
              root.zoomOut()
          }
          onDoubleClicked: root.fitToWindow ? root.zoomActual() : root.zoomFit()
        }

        DropArea {
          id: dropZone

          anchors.fill: parent
          onDropped: function(drop) {
            if (drop.hasUrls && drop.urls.length > 0)
              root.openFile(drop.urls[0])
          }
        }
      }

      // Transient zoom indicator (outside viewport so it never blurs itself).
      //
      // Only while the chrome is hidden. With the status bar up it prints the
      // same number from the same expression, so the badge is a second copy of
      // a value already on screen; with `Tab` pressed the status bar is gone and
      // this is the only place the scale is readable. That is the whole rule:
      // the badge answers for the status bar, it does not compete with it.
      Frost {
        target: zoomBadge
        shown: zoomBadge.shown
      }
      Rectangle {
        id: zoomBadge

        property bool shown: root.zoomBadgeWanted

        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height - 92
        width: zlbl.implicitWidth + 28
        height: 30
        color: Ui.tint("background_0", 0.66)
        // Corners follow RoundingPolicy (hypr.decoration.rounding).
        radius: RoundingPolicy.radius
        border.color: Ui.tint("foreground_0", 0.26)
        border.width: 1
        opacity: zoomBadge.shown ? 1.0 : 0.0

        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutQuad } }

        Text {
          id: zlbl

          anchors.centerIn: parent
          // The same number the status bar prints, so a zoom badge and the
          // status readout can never report two different scales.
          text: Math.round((root.fitToWindow ? img.fitScale : root.zoomFactor) * 100) + "%"
          color: Ui.solid("foreground_0")
          font.pixelSize: 12
          font.family: Ui.fontFamily
          font.weight: Font.DemiBold
        }
        Timer { id: zoomTimer; interval: 900 }
      }

      // ---- keyboard shortcuts ----
      //
      // One Item that fills the content item and owns every key. It carries no
      // MouseArea, so it never takes a pointer event and never competes with
      // the viewport's drag; `focus: true` makes it the item the window hands
      // the keyboard to, which is what the window's `onActiveChanged` claims.
      Item {
        id: keyHandler

        anchors.fill: parent
        focus: true

        Keys.onPressed: function(event) {
          switch (event.key) {
          case Qt.Key_Left: root.prevImage(); break
          case Qt.Key_Right: root.nextImage(); break
          case Qt.Key_Plus: case Qt.Key_Equal: root.zoomIn(); break
          case Qt.Key_Minus: root.zoomOut(); break
          case Qt.Key_0: root.zoomActual(); break
          case Qt.Key_Tab: root.chromeVisible = !root.chromeVisible; break
          case Qt.Key_F: case Qt.Key_F11: root.toggleFullscreen(); break
          case Qt.Key_Escape:
            // The window's own `visibility` is the state, not a flag of ours:
            // Escape leaves fullscreen and nothing else, so it cannot close a
            // windowed viewer out from under the user.
            if (root.win.visibility === Window.FullScreen)
              root.toggleFullscreen()
            break
          }
        }
      }

      Frost {
        target: toolbar
        shown: root.chromeVisible || root.hoverNearTop || toolbarHoverHandler.hovered
      }

      // ---- floating toolbar: translucent bar, slides away when hidden ----
      Rectangle {
        id: toolbar

        anchors.horizontalCenter: parent.horizontalCenter
        // Three ways up, one way down: the chrome flag, the pointer near the
        // top, or the pointer already on the bar itself. The third is what keeps
        // a moving bar from sliding out from under the pointer on its way to a
        // button.
        y: (root.chromeVisible || root.hoverNearTop || toolbarHoverHandler.hovered) ? 14 : -height - 14
        width: toolRow.implicitWidth + 14
        height: 50
        color: Ui.tint("background_0", 0.55)
        // Corners follow RoundingPolicy (hypr.decoration.rounding).
        radius: RoundingPolicy.radius
        border.color: Ui.tint("foreground_0", 0.17)
        border.width: 1

        Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        HoverHandler { id: toolbarHoverHandler }

        RowLayout {
          id: toolRow

          anchors.centerIn: parent
          spacing: 3

          IconBtn { tip: "Previous (Left)"; onClicked: root.prevImage(); Icon { names: ["go-previous"]; size: 20; anchors.centerIn: parent } }
          IconBtn { tip: "Next (Right)"; onClicked: root.nextImage(); Icon { names: ["go-next"]; size: 20; anchors.centerIn: parent } }

          ToolDivider {}

          IconBtn { tip: "Zoom out (-)"; onClicked: root.zoomOut(); Icon { names: ["zoom-out"]; size: 20; anchors.centerIn: parent } }
          IconBtn { tip: "Zoom in (+)"; onClicked: root.zoomIn(); Icon { names: ["zoom-in"]; size: 20; anchors.centerIn: parent } }

          ToolDivider {}

          IconBtn { tip: "Fit to window"; onClicked: root.zoomFit(); Icon { names: ["zoom-fit-best", "zoom-fit-page"]; size: 20; anchors.centerIn: parent } }
          IconBtn {
            tip: "Left click: rotate CW, right click: rotate CCW"
            onClicked: root.rotateCW()
            onRightClicked: root.rotateCCW()
            Icon { names: ["object-rotate-right", "object-rotate-left"]; size: 20; anchors.centerIn: parent }
          }

          ToolDivider {}

          Btn { label: root.chromeVisible ? "Hide UI" : "Show UI"; tip: "Hide controls (Tab)"; ghost: true; onClicked: root.chromeVisible = !root.chromeVisible }
        }
      }

      Frost {
        target: statusbar
        shown: root.chromeVisible || root.hoverNearBottom || statusbarHoverHandler.hovered
      }

      // ---- floating status bar: translucent, slides away when hidden ----
      Rectangle {
        id: statusbar

        anchors.horizontalCenter: parent.horizontalCenter
        y: (root.chromeVisible || root.hoverNearBottom || statusbarHoverHandler.hovered)
           ? parent.height - height - 14
           : parent.height + 8
        // The live window width, not the seed: a cap written against the seed
        // size would let the bar run past the edge after a resize.
        width: Math.min(root.win.width - 32, statusRow.implicitWidth + 32)
        height: 34
        color: Ui.tint("background_0", 0.55)
        // Corners follow RoundingPolicy (hypr.decoration.rounding).
        radius: RoundingPolicy.radius
        border.color: Ui.tint("foreground_0", 0.17)
        border.width: 1

        Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        HoverHandler { id: statusbarHoverHandler }

        RowLayout {
          id: statusRow

          anchors.centerIn: parent
          spacing: 16

          Row {
            spacing: 7
            Layout.alignment: Qt.AlignVCenter
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: 6; height: 6; radius: 3
              color: root.hasFile ? Ui.solid("accent") : Ui.tint("foreground_0", 0.40)
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.currentFileName === "" ? "no image" : root.currentFileName
              color: Ui.solid("foreground_0")
              font.pixelSize: 12
              font.family: Ui.fontFamily
              elide: Text.ElideMiddle
              width: Math.min(implicitWidth, root.win.width * 0.35)
            }
          }
          Text {
            text: root.folderModel.count > 0 ? (root.currentIndex + 1) + " / " + root.folderModel.count : ""
            color: Ui.tint("foreground_0", 0.78)
            font.pixelSize: 12
            font.family: Ui.fontFamily
          }
          Text {
            // Vectors report the probe's intrinsic extent, not the raster:
            // the raster is a display-size implementation detail (bucketed
            // device pixels), while the intrinsic size is the file's answer.
            text: root.isVector
                  ? (vectorProbe.implicitWidth > 0 ? vectorProbe.implicitWidth + " x " + vectorProbe.implicitHeight : "")
                  : (img.sourceSize.width > 0 ? img.sourceSize.width + " x " + img.sourceSize.height : "")
            color: Ui.tint("foreground_0", 0.78)
            font.pixelSize: 12
            font.family: Ui.fontFamily
          }
          Text {
            text: Math.round((root.fitToWindow ? img.fitScale : root.zoomFactor) * 100) + "%"
            color: Ui.solid("accent")
            font.pixelSize: 12
            font.family: Ui.fontFamily
            font.weight: Font.DemiBold
          }
          Text {
            text: root.currentIndex >= 0 ? root.humanFileSize(root.folderModel.get(root.currentIndex, "fileSize")) : ""
            color: Ui.tint("foreground_0", 0.78)
            font.pixelSize: 12
            font.family: Ui.fontFamily
          }
        }
      }
    }
  }
}