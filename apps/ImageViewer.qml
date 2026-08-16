import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import QtCore

ApplicationWindow {
    id: root
    visible: true
    width: 1100
    height: 720
    minimumWidth: 360
    minimumHeight: 240
    color: "black"
    title: currentFileName === "" ? "Image Viewer" : currentFileName

    property url currentFile
    property string currentFileName: ""
    property int currentIndex: -1
    property string pendingFileName: ""

    property real zoomFactor: 1.0
    property bool fitToWindow: true
    property int rotationAngle: 0
    property real panX: 0
    property real panY: 0

    property bool chromeVisible: true
    property bool hoverNearTop: false
    property bool hoverNearBottom: false

    // small vector folder glyph, no unicode, no icon font dependency.
    // All parts are parent-relative so the shape scales cleanly to any
    // button size (tab 40% x 25%, body full-width starting at 19% height).
    component FolderGlyph: Item {
        implicitWidth: 20
        implicitHeight: 16
        Rectangle {
            width: parent.width * 0.4
            height: parent.height * 0.25
            color: "#7a7a7a"
            radius: 1
        }
        Rectangle {
            width: parent.width
            height: parent.height * 0.81
            y: parent.height * 0.19
            color: "#949494"
            radius: 1
        }
    }

    // small vector drive glyph for the devices section
    component DriveGlyph: Item {
        implicitWidth: 20
        implicitHeight: 16
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            y: parent.height * 0.25
            height: parent.height * 0.5
            radius: 2
            color: "#6e6e6e"
            border.color: "#4a4a4a"
            border.width: 1
        }
        Rectangle {
            width: parent.width * 0.2
            height: parent.height * 0.25
            radius: 2
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height * 0.375
            color: "#b8b8b8"
        }
    }

    // vector icon for the single view-mode button: the icon shows the
    // active mode (grid/list/details), clicking cycles through them.
    component ModeIcon: Item {
        property string mode: "grid"
        implicitWidth: 18
        implicitHeight: 14
        // grid: 2x2 squares, content 14x14 centered in the 18x14 box
        Rectangle { visible: parent.mode === "grid"; x: 2; y: 0; width: 5; height: 5; radius: 1; color: "#d0d0d0" }
        Rectangle { visible: parent.mode === "grid"; x: 9; y: 0; width: 5; height: 5; radius: 1; color: "#d0d0d0" }
        Rectangle { visible: parent.mode === "grid"; x: 2; y: 9; width: 5; height: 5; radius: 1; color: "#d0d0d0" }
        Rectangle { visible: parent.mode === "grid"; x: 9; y: 9; width: 5; height: 5; radius: 1; color: "#d0d0d0" }
        // list: three lines
        Rectangle { visible: parent.mode === "list"; x: 0; y: 0; width: 18; height: 3; radius: 1; color: "#d0d0d0" }
        Rectangle { visible: parent.mode === "list"; x: 0; y: 5.5; width: 18; height: 3; radius: 1; color: "#d0d0d0" }
        Rectangle { visible: parent.mode === "list"; x: 0; y: 11; width: 18; height: 3; radius: 1; color: "#d0d0d0" }
        // details: lines with a dot beside each, dots centered on the lines
        Rectangle { visible: parent.mode === "details"; x: 0; y: 0; width: 12; height: 3; radius: 1; color: "#d0d0d0" }
        Rectangle { visible: parent.mode === "details"; x: 14.5; y: 0.25; width: 2.5; height: 2.5; radius: 1.25; color: "#d0d0d0" }
        Rectangle { visible: parent.mode === "details"; x: 0; y: 5.5; width: 12; height: 3; radius: 1; color: "#d0d0d0" }
        Rectangle { visible: parent.mode === "details"; x: 14.5; y: 5.75; width: 2.5; height: 2.5; radius: 1.25; color: "#d0d0d0" }
        Rectangle { visible: parent.mode === "details"; x: 0; y: 11; width: 12; height: 3; radius: 1; color: "#d0d0d0" }
        Rectangle { visible: parent.mode === "details"; x: 14.5; y: 11.25; width: 2.5; height: 2.5; radius: 1.25; color: "#d0d0d0" }
    }

    // small sort direction arrow (▲/▼) drawn from two rotated bars, so no
    // glyph/font dependency. Two 6.7-long bars form a triangle in the 8x8 box.
    component SortArrow: Item {
        property bool up: true
        property bool on: false
        width: 8
        height: 8
        visible: on
        Rectangle { x: -1.66; y: 3; width: 7.83; height: 2; rotation: up ? 116.57 : 63.43; radius: 1; color: "#d0d0d0" }
        Rectangle { x: 1.84; y: 3; width: 7.83; height: 2; rotation: up ? 63.43 : 116.57; radius: 1; color: "#d0d0d0" }
    }

    component ToggleBtn: Rectangle {
        id: tbtn
        property string label: ""
        property bool on: false
        property bool hovered: false
        signal toggled()
        height: 24
        width: tbl.implicitWidth + 30
        radius: 3
        color: tma.containsMouse ? "#000000cc" : "#000000b3"
        border.color: "#444444"
        border.width: 1
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 6
            width: 12; height: 12; radius: 2
            border.color: tbtn.on ? "#8ab4f8" : "#666666"
            border.width: 1
            color: tbtn.on ? "#2b4a6b" : "transparent"
            Rectangle {
                anchors.centerIn: parent
                width: 6; height: 6; radius: 1
                visible: tbtn.on
                color: "#8ab4f8"
            }
        }
        Text {
            id: tbl
            anchors.left: parent.left
            anchors.leftMargin: 24
            anchors.verticalCenter: parent.verticalCenter
            text: tbtn.label
            color: "#b8b8b8"
            font.pixelSize: 11
        }
        MouseArea {
            id: tma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: tbtn.hovered = tma.containsMouse
            onClicked: {
                tbtn.on = !tbtn.on
                tbtn.toggled()
            }
        }
    }

    component SidebarBtn: Rectangle {
        id: sbtn
        property string label: ""
        property url target
        signal clicked()
        Layout.fillWidth: true
        height: 28
        radius: 3
        color: sma.containsMouse ? "#2c2c2c" : "transparent"
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 7
            FolderGlyph {
                Layout.preferredWidth: 14
                Layout.preferredHeight: 11
                Layout.alignment: Qt.AlignVCenter
            }
            Text {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: sbtn.label
                color: "#d0d0d0"
                font.pixelSize: 12
                elide: Text.ElideRight
            }
        }
        MouseArea {
            id: sma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: sbtn.clicked()
        }
    }

    component DeviceBtn: Rectangle {
        id: dbtn
        property string label: ""
        signal clicked()
        Layout.fillWidth: true
        height: 28
        radius: 3
        color: dma.containsMouse ? "#2c2c2c" : "transparent"
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 7
            DriveGlyph {
                Layout.preferredWidth: 14
                Layout.preferredHeight: 11
                Layout.alignment: Qt.AlignVCenter
            }
            Text {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: dbtn.label
                color: "#c8c8c8"
                font.pixelSize: 12
                elide: Text.ElideRight
            }
        }
        MouseArea {
            id: dma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: dbtn.clicked()
        }
    }

    // one key/value row of the mediainfo-style details box
    component MediaRow: Rectangle {
        id: mrow
        property string k: ""
        property string v: ""
        Layout.fillWidth: true
        height: 20
        color: "transparent"
        RowLayout {
            anchors.fill: parent
            spacing: 6
            Text {
                Layout.preferredWidth: 62
                text: mrow.k + ":"
                color: "#7a7a7a"
                font.pixelSize: 11
            }
            Text {
                Layout.fillWidth: true
                text: mrow.v
                color: "#d0d0d0"
                font.pixelSize: 11
                elide: Text.ElideMiddle
            }
        }
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: "#1e1e1e"
        }
    }

component FilePicker: Window {
    id: picker

    // ---- public API (mirrors what ImageViewer.qml expects from FileDialog) ----
    signal accepted()
    property url selectedFile: ""
    property url folder: ""

    // Setup runs when the window becomes visible. Unlike a Popup, a Window
    // has no open()/close() of its own, so defining them here is safe and
    // keeps the host app's API unchanged. A QML Window exposes no usable
    // parent(), so the host app passes itself via the host property; the
    // picker centers over it and becomes its transient window at open time.
    property Window host: null

    function open() {
        if (host) {
            x = host.x + (host.width - width) / 2
            y = host.y + (host.height - height) / 2
            transientParent = host
        }
        visible = true
    }
    function close() { visible = false }

    onVisibleChanged: {
        if (!visible)
            return
        if (folder.toString() === "") {
            var pics = stdLoc("PicturesLocation")
            folder = pics !== "" ? pics : Qt.resolvedUrl(".")
        }
        model.folder = folder
        selectedFile = ""
        selectedIndex = -1
        previewFile = ""
        contentRoot.forceActiveFocus()
    }
    // StandardPaths.<Location> is a scoped enum (StandardPaths.StandardLocation.X)
    // as of Qt 6.5+; the flat form (StandardPaths.X) silently evaluates to
    // undefined on versions where it's not aliased -- property lookups don't
    // throw, so this fails with zero errors and FolderListModel just quietly
    // refuses to accept the resulting empty url. This helper tries both forms
    // and always returns something usable instead of failing silently.
    function stdLoc(name) {
        var enumVal = StandardPaths.StandardLocation !== undefined
            ? StandardPaths.StandardLocation[name]
            : undefined
        if (enumVal === undefined)
            enumVal = StandardPaths[name]
        if (enumVal === undefined) {
            console.warn("[FilePicker] StandardPaths enum", name, "not found in either form")
            return ""
        }
        var raw = StandardPaths.writableLocation(enumVal)
        if (raw === undefined || raw === "")
            return ""
        return Qt.resolvedUrl(raw)
    }

    // label for a standard location: the real folder name (XDG "Movies"
    // maps to ~/Videos on most systems, so don't hardcode the name)
    function stdLabel(locName, fallback) {
        var p = stdLoc(locName)
        if (p === "")
            return fallback
        var parts = p.toString().split("/").filter(function(s) { return s.length > 0 })
        return parts.length > 0 ? parts[parts.length - 1] : fallback
    }

    onFolderChanged: {
        selectedFile = ""
        selectedIndex = -1
        previewFile = ""
        model.folder = folder
        refreshCrumbs()
    }
    Component.onCompleted: refreshCrumbs()

    // ---- own window: resizable, adapts to its size, WM draws the shadow ----
    title: "Open image"
    visible: false
    minimumWidth: 620
    minimumHeight: 420
    width: 980
    height: 620
    color: "#000000"

    property url previewFile: ""
    property int selectedIndex: -1  // avoids O(n) linear scans on every click/keypress
    property bool previewIsGif: previewFile.toString().toLowerCase().endsWith(".gif")
    property string viewMode: "grid"   // "grid" | "list" | "details"
    property bool showHidden: false
    property string sortColumn: ""      // "" = default (dirs-first) | "name" | "size" | "modified"
    property bool sortDesc: false

    // nameFilters apply to files only, dirs always show when showDirs is true
    property var imageFilters: ["*.png", "*.PNG", "*.jpg", "*.JPG", "*.jpeg", "*.JPEG", "*.bmp", "*.BMP", "*.gif", "*.GIF", "*.webp", "*.WEBP", "*.svg", "*.SVG", "*.ico", "*.ICO", "*.tif", "*.TIF", "*.tiff", "*.TIFF"]
    property real cellScale: 100
    property real colSizeW: 80
    property real colModW: 130

    FolderListModel {
        id: model
        showDirs: true
        showDotAndDotDot: false
        sortField: picker.sortColumn === "" ? FolderListModel.Type
                  : picker.sortColumn === "size" ? FolderListModel.Size
                  : picker.sortColumn === "modified" ? FolderListModel.Time
                  : FolderListModel.Name
        sortReversed: picker.sortDesc
        nameFilters: picker.imageFilters
        showHidden: picker.showHidden
    }

    // ---- mounted devices: partition labels from /dev/disk/by-label ----
    // Each label is probed against likely mountpoints; only devices whose
    // mountpoint is found AND listable by the user are listed, and each
    // entry remembers its mountpoint so clicking navigates straight there.
    property var devices: []          // [{label, url}] of navigable devices
    property var deviceQueue: []      // [{label, cands, idx}] probes still pending
    property var deviceFound: []      // probes that succeeded so far
    property var deviceSeen: {}       // urls already added, for dedupe
    property var mountRoots: []       // mount-root dirs still being scanned
    property list<string> crumbList: []

    FolderListModel {
        id: devModel
        folder: "file:///dev/disk/by-label"
        showDirs: false
        showDotAndDotDot: false
        onStatusChanged: {
            if (status !== FolderListModel.Ready)
                return
            if (count === 0 || devModel.get(0, "filePath").indexOf("/dev/disk/by-label/") !== 0)
                return
            picker.devices = []
            picker.deviceFound = []
            picker.deviceQueue = []
            picker.deviceSeen = {}
            picker.deviceFound.push({ label: "System", url: "file:///" })
            picker.deviceSeen["file:///"] = true
            for (var i = 0; i < count; i++) {
                var label = picker.decodeLabel(get(i, "fileName"))
                if (label === "" || label.indexOf("zram") === 0 || label.indexOf("loop") === 0)
                    continue
                picker.deviceQueue.push({ label: label, cands: picker.navCandidatesFor(label), idx: 0 })
            }
            picker.scanMounts()
        }
    }

    // scan udisks-managed mount roots (/media, /run/media/<user>) for mounted
    // volumes that lack a by-label entry. /mnt is deliberately excluded: a
    // folder under /mnt is often just a plain directory, not a real mount,
    // and real /mnt mounts are already found by the by-label candidate probes.
    function scanMounts() {
        var roots = []
        var home = picker.stdLoc("HomeLocation").toString()
        var hparts = home.replace("file://", "").split("/").filter(function(x) { return x !== "" })
        var user = hparts.length > 0 ? hparts[hparts.length - 1] : ""
        roots.push("file:///media")
        if (user !== "")
            roots.push("file:///run/media/" + user)
        picker.mountRoots = roots
        picker.scanNextMountRoot()
    }

    function scanNextMountRoot() {
        if (picker.mountRoots.length === 0) {
            picker.probeNextDevice()
            return
        }
        var url = picker.mountRoots.shift()
        var mdl = Qt.createQmlObject(
            'import Qt.labs.folderlistmodel; FolderListModel { showDirs: true; showDotAndDotDot: false; folder: "' + url + '" }',
            picker)
        if (!mdl) {
            picker.scanNextMountRoot()
            return
        }
        var done = false
        mdl.statusChanged.connect(function() {
            if (done)
                return
            if (mdl.status === FolderListModel.Ready) {
                done = true
                var path = url.replace("file://", "")
                if (mdl.count > 0 && mdl.get(0, "filePath").indexOf(path) === 0) {
                    for (var i = 0; i < mdl.count; i++) {
                        if (!mdl.isFolder(i))
                            continue
                        var u = "file://" + mdl.get(i, "filePath")
                        if (picker.deviceSeen[u] === undefined) {
                            picker.deviceSeen[u] = true
                            picker.deviceFound.push({ label: picker.deviceLabelFor(u), url: u })
                        }
                    }
                }
                mdl.destroy()
                picker.scanNextMountRoot()
            } else if (mdl.status === FolderListModel.Null) {
                done = true
                picker.scanNextMountRoot()
                mdl.destroy()
            }
        })
    }

    function deviceLabelFor(url) {
        var p = url.replace("file://", "").replace(/\/+$/, "")
        var parts = p.split("/").filter(function(x) { return x !== "" })
        return parts.length > 0 ? parts[parts.length - 1] : url
    }

    // probe model used to verify a candidate mountpoint exists and lists
    // A fresh model is created per candidate: reusing one model for rapid
    // sequential probes makes it thrash (stuck Null states, bogus resets).
    // Creating and destroying one-off models keeps every probe reliable.

    function probeNextDevice() {
        while (picker.deviceQueue.length > 0) {
            var cur = picker.deviceQueue[0]
            if (cur.idx >= cur.cands.length) {
                picker.deviceQueue.shift()
                continue
            }
            var url = cur.cands[cur.idx]
            cur.idx++
            var mdl = Qt.createQmlObject(
                'import Qt.labs.folderlistmodel; FolderListModel { showDirs: true; showDotAndDotDot: false; folder: "' + url + '" }',
                picker)
            if (!mdl) {
                picker.probeNextDevice()
                return
            }
            var done = false
            mdl.statusChanged.connect(function() {
                if (done)
                    return
                if (mdl.status === FolderListModel.Ready) {
                    done = true
                    picker.evaluateProbe(url, mdl)
                    mdl.destroy()
                } else if (mdl.status === FolderListModel.Null) {
                    done = true
                    picker.probeNextDevice()
                    mdl.destroy()
                }
            })
            return
        }
        picker.devices = picker.deviceFound
        picker.deviceFound = []
    }

    // called when a candidate's model finished loading: the dir exists and
    // lists only if the listing's paths really live under it (FolderListModel
    // falls back to the process cwd for broken dirs)
    function evaluateProbe(url, mdl) {
        var path = url.replace("file://", "")
        if (mdl.count > 0 && mdl.get(0, "filePath").indexOf(path) === 0 && picker.deviceSeen[url] === undefined) {
            var cur = picker.deviceQueue[0]
            if (cur !== undefined) {
                picker.deviceSeen[url] = true
                picker.deviceFound.push({ label: cur.label, url: url })
            }
            picker.deviceQueue.shift()
        }
        picker.probeNextDevice()
    }

    function decodeLabel(name) {
        var s = name.replace(/\\x([0-9a-fA-F]{2})/g, function(m, h) {
            return String.fromCharCode(parseInt(h, 16))
        })
        return decodeURIComponent(s)
    }

    // likely mountpoints for a label: udisks2 style, manual /media//mnt
    // mounts under the label itself and under its lowercase first word,
    // since mount folder names often differ from the partition label.
    function navCandidatesFor(label) {
        var home = picker.stdLoc("HomeLocation").toString()
        var hparts = home.replace("file://", "").split("/").filter(function(x) { return x !== "" })
        var user = hparts.length > 0 ? hparts[hparts.length - 1] : ""
        var names = []
        var seen = {}
        var all = [label, label.toLowerCase().split(" ")[0]]
        for (var i = 0; i < all.length; i++) {
            if (all[i] !== "" && seen[all[i]] === undefined) {
                seen[all[i]] = true
                names.push(all[i])
            }
        }
        var cands = []
        for (var j = 0; j < names.length; j++) {
            var n = names[j]
            if (user !== "")
                cands.push("file:///run/media/" + user + "/" + n)
            cands.push("file:///media/" + n)
            cands.push("file:///mnt/" + n)
            if (user !== "")
                cands.push("file:///media/" + user + "/" + n)
        }
        return cands
    }

    function pathSegments() {
        var p = picker.folder.toString().replace("file://", "")
        if (p === "")
            return []
        var parts = p.split("/").filter(function(s) { return s.length > 0 })
        return parts
    }

    function refreshCrumbs() {
        picker.crumbList = picker.pathSegments()
    }

    function goToSegment(index) {
        var parts = picker.crumbList
        var built = "/" + parts.slice(0, index + 1).join("/")
        picker.folder = Qt.resolvedUrl("file://" + built)
    }

    function goUp() {
        var s = picker.folder.toString()
        if (s.length <= "file:///".length + 1)
            return
        if (s.endsWith("/"))
            s = s.slice(0, -1)
        var slash = s.lastIndexOf("/")
        if (slash > "file://".length)
            picker.folder = s.substring(0, slash)
    }

    function humanSize(bytes) {
        if (bytes === undefined || bytes <= 0)
            return ""
        var units = ["B", "KiB", "MiB", "GiB"]
        var i = 0
        var v = bytes
        while (v >= 1024 && i < units.length - 1) {
            v /= 1024
            i++
        }
        return (i === 0 ? v : v.toFixed(1)) + " " + units[i]
    }

    function selectRow(fileUrl, isDir, idx) {
        // folders also become the active selection (highlight only); files
        // additionally load a preview. Single-click never navigates.
        picker.selectedFile = fileUrl
        picker.selectedIndex = idx
        picker.previewFile = isDir ? "" : fileUrl
    }

    function activateRow(fileUrl, isDir) {
        if (isDir) {
            picker.folder = fileUrl
        } else {
            picker.selectedFile = fileUrl
            picker.accepted()
            picker.close()
        }
    }

    // Open/Enter behavior: a selected folder navigates into it (like a file
    // manager); a selected file accepts and closes the dialog.
    function accept() {
        if (picker.selectedFile.toString() === "")
            return
        var row = picker.selectedIndex
        if (row >= 0 && model.get(row, "fileIsDir")) {
            picker.folder = picker.selectedFile
            return
        }
        picker.accepted()
        picker.close()
    }

    function sortBy(col) {
        if (picker.sortColumn === col) {
            picker.sortDesc = !picker.sortDesc
        } else {
            picker.sortColumn = col
            picker.sortDesc = false
        }
    }

    function selectIndex(i) {
        if (model.count === 0)
            return
        if (i < 0) i = 0
        if (i >= model.count) i = model.count - 1
        var url = model.get(i, "fileUrl")
        var isDir = model.get(i, "fileIsDir")
        picker.selectedFile = url
        picker.selectedIndex = i
        picker.previewFile = isDir ? "" : url
    }

    function moveSelection(dx, dy) {
        if (model.count === 0)
            return
        var row = picker.selectedIndex
        if (row < 0) {
            picker.selectIndex(0)
            return
        }
        if (picker.viewMode === "grid") {
            var cols = Math.max(1, Math.floor(gridView.width / gridView.cellWidth))
            var r = Math.floor(row / cols)
            var c = row % cols
            r = Math.max(0, r + dy)
            c = Math.max(0, Math.min(cols - 1, c + dx))
            var target = r * cols + c
            if (target >= model.count) target = model.count - 1
            row = target
            gridView.positionViewAtIndex(row, GridView.Center)
        } else if (picker.viewMode === "list") {
            row = Math.max(0, Math.min(model.count - 1, row + dy))
            listView.positionViewAtIndex(row, ListView.Center)
        } else {
            row = Math.max(0, Math.min(model.count - 1, row + dy))
            detailsView.positionViewAtIndex(row, ListView.Center)
        }
        picker.selectIndex(row)
    }

    function typeName(suffix) {
        var s = String(suffix).toLowerCase()
        var map = {
            "jpg": "JPEG image", "jpeg": "JPEG image",
            "png": "PNG image", "gif": "GIF image",
            "bmp": "BMP image", "webp": "WebP image",
            "svg": "SVG image", "ico": "ICO icon",
            "tif": "TIFF image", "tiff": "TIFF image"
        }
        return map[s] !== undefined ? map[s] : (s === "" ? "" : s.toUpperCase() + " file")
    }

    function infoSize() {
        var i = picker.selectedIndex
        return i < 0 ? "" : humanSize(model.get(i, "fileSize"))
    }
    function infoModified() {
        var i = picker.selectedIndex
        return i < 0 ? "" : Qt.formatDateTime(model.get(i, "fileModified"), "yyyy-MM-dd hh:mm")
    }
    function infoType() {
        var i = picker.selectedIndex
        return i < 0 ? "" : typeName(model.get(i, "fileSuffix"))
    }
    function infoPath() {
        var s = picker.selectedFile.toString()
        var slash = s.lastIndexOf("/")
        return slash > 0 ? s.substring(0, slash).replace("file://", "") : ""
    }

    // ---- background: the WM renders the drop shadow around the window ----
    Rectangle {
        anchors.fill: parent
        color: "#1c1c1c"
        border.color: "#4a4a4a"
        border.width: 1
    }


    ColumnLayout {
        id: contentRoot
        anchors.fill: parent
        spacing: 0
        focus: true

        Shortcut {
            sequence: "Escape"
            onActivated: picker.close()
        }

        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (selectedFile != "") picker.accept();
                event.accepted = true;
            } else if (event.key === Qt.Key_Backspace && crumbList.length > 0) {
                goUp();
                event.accepted = true;
            } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_H) {
                showHidden = !showHidden;
                event.accepted = true;
            } else if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal)) {
                picker.cellScale = Math.min(150, picker.cellScale + 10);
                event.accepted = true;
            } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Minus) {
                picker.cellScale = Math.max(60, picker.cellScale - 10);
                event.accepted = true;
            } else if (event.key === Qt.Key_Up) {
                picker.moveSelection(0, -1); event.accepted = true;
            } else if (event.key === Qt.Key_Down) {
                picker.moveSelection(0, 1); event.accepted = true;
            } else if (event.key === Qt.Key_Left) {
                picker.moveSelection(-1, 0); event.accepted = true;
            } else if (event.key === Qt.Key_Right) {
                picker.moveSelection(1, 0); event.accepted = true;
            }
        }

        // ---- path bar: the window's header, not a side note ----
        Rectangle {
            Layout.fillWidth: true
            height: 42
            color: "#262626"
            radius: 3

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 10

                FolderGlyph {
                    Layout.preferredWidth: 22
                    Layout.preferredHeight: 18
                    Layout.alignment: Qt.AlignVCenter
                }

                Flow {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 18
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 2
                    clip: true

                    Repeater {
                        model: picker.crumbList
                        delegate: Row {
                            spacing: 3
                            Rectangle {
                                width: segLabel.implicitWidth + 16
                                height: 18
                                radius: 4
                                border.width: 1
                                border.color: segMa.containsMouse ? "#6a6a6a" : (index === picker.crumbList.length - 1 ? "#5a5a5a" : "#3a3a3a")
                                color: segMa.containsMouse ? "#3a3a3a" : (index === picker.crumbList.length - 1 ? "#2d2d2d" : "#262626")
                                Text {
                                    id: segLabel
                                    anchors.centerIn: parent
                                    text: modelData === "" ? "/" : modelData
                                    color: index === picker.crumbList.length - 1 ? "#f0f0f0" : "#b0b0b0"
                                    font.pixelSize: 12
                                }
                                MouseArea {
                                    id: segMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: picker.goToSegment(index)
                                }
                            }
                            Text {
                                visible: index < picker.crumbList.length - 1
                                anchors.verticalCenter: parent.verticalCenter
                                text: "/"
                                color: "#5a5a5a"
                                font.pixelSize: 12
                            }
                        }
                    }
                }

                ToggleBtn {
                    label: "Hidden"
                    on: picker.showHidden
                    onToggled: picker.showHidden = on
                    Layout.alignment: Qt.AlignVCenter
                    ToolTip.visible: hovered
                    ToolTip.text: "Show hidden items (Ctrl+H)"
                    ToolTip.delay: 400
                }

                Rectangle {
                    id: modeBtn
                    objectName: "modeBtn"
                    Layout.preferredWidth: 30
                    Layout.preferredHeight: 24
                    Layout.alignment: Qt.AlignVCenter
                    radius: 3
                    color: mmb.containsMouse ? "#000000cc" : "#000000b3"
                    border.color: "#444444"
                    border.width: 1
                    ModeIcon {
                        anchors.centerIn: parent
                        mode: picker.viewMode
                    }
                    ToolTip.visible: mmb.containsMouse
                    ToolTip.text: "View: " + picker.viewMode + " (click to change)"
                    ToolTip.delay: 400
                    MouseArea {
                        id: mmb
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            picker.viewMode = picker.viewMode === "grid" ? "list"
                                : picker.viewMode === "list" ? "details" : "grid"
                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: "#3a3a3a"
        }

        // ---- main body: sidebar | file area | preview ----
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // sidebar
            Rectangle {
                Layout.preferredWidth: 170
                Layout.fillHeight: true
                color: "#181818"

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 3

                    Text {
                        Layout.fillWidth: true
                        text: "PLACES"
                        color: "#666666"
                        font.pixelSize: 10
                        font.letterSpacing: 1.2
                        leftPadding: 4
                    }

                    SidebarBtn { label: "Home";      onClicked: { var p = picker.stdLoc("HomeLocation");      if (p !== "") picker.folder = p } }
                    SidebarBtn { label: picker.stdLabel("DownloadLocation", "Downloads");  onClicked: { var p = picker.stdLoc("DownloadLocation");  if (p !== "") picker.folder = p } }
                    SidebarBtn { label: picker.stdLabel("DocumentsLocation", "Documents");  onClicked: { var p = picker.stdLoc("DocumentsLocation"); if (p !== "") picker.folder = p } }
                    SidebarBtn { label: picker.stdLabel("MusicLocation", "Music");      onClicked: { var p = picker.stdLoc("MusicLocation");     if (p !== "") picker.folder = p } }
                    SidebarBtn { label: picker.stdLabel("PicturesLocation", "Pictures");   onClicked: { var p = picker.stdLoc("PicturesLocation");  if (p !== "") picker.folder = p } }
                    SidebarBtn { label: picker.stdLabel("MoviesLocation", "Videos");     onClicked: { var p = picker.stdLoc("MoviesLocation");    if (p !== "") picker.folder = p } }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.topMargin: 6
                        Layout.bottomMargin: 6
                        height: 1
                        color: "#2e2e2e"
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "DEVICES"
                        color: "#666666"
                        font.pixelSize: 10
                        font.letterSpacing: 1.2
                        leftPadding: 4
                    }

                    Repeater {
                        model: picker.devices
                        delegate: DeviceBtn {
                            label: modelData.label
                            onClicked: picker.folder = modelData.url
                        }
                    }

                    Item { Layout.fillHeight: true }
                }
            }

            Rectangle { width: 1; Layout.fillHeight: true; color: "#333333" }

            // file area
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#1c1c1c"

                // -- grid mode --
                GridView {
                    id: gridView
                    visible: picker.viewMode === "grid"
                    anchors.fill: parent
                    anchors.margins: 8
                    cellWidth: 104 * picker.cellScale / 100
                    cellHeight: 104 * picker.cellScale / 100
                    clip: true
                    model: model

                    delegate: Rectangle {
                        width: gridView.cellWidth - 4
                        height: gridView.cellHeight - 4
                        radius: 4
                        opacity: fileName.charAt(0) === "." ? 0.45 : 1.0
                        color: picker.selectedFile === fileUrl ? "#094771" : (gma.containsMouse ? "#2a2a2a" : "transparent")

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 4
                            spacing: 2

                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                FolderGlyph {
                                    anchors.centerIn: parent
                                    width: 64 * picker.cellScale / 100
                                    height: 51 * picker.cellScale / 100
                                    visible: fileIsDir
                                }
                                Image {
                                    anchors.fill: parent
                                    visible: !fileIsDir
                                    source: fileIsDir ? "" : fileUrl
                                    asynchronous: true
                                    fillMode: Image.PreserveAspectFit
                                    sourceSize.width: 96 * picker.cellScale / 100
                                    sourceSize.height: 96 * picker.cellScale / 100
                                    cache: true
                                }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: fileName
                                color: "#e0e0e0"
                                font.pixelSize: 10
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideMiddle
                            }
                        }

                        MouseArea {
                            id: gma
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: picker.selectRow(fileUrl, fileIsDir, index)
                            onDoubleClicked: picker.activateRow(fileUrl, fileIsDir)
                        }
                    }
                }

                // -- list mode --
                ListView {
                    id: listView
                    visible: picker.viewMode === "list"
                    anchors.fill: parent
                    anchors.margins: 8
                    clip: true
                    model: model

                    delegate: Rectangle {
                        width: listView.width
                        height: 26 * picker.cellScale / 100
                        radius: 4
                        opacity: fileName.charAt(0) === "." ? 0.45 : 1.0
                        color: picker.selectedFile === fileUrl ? "#094771" : (lma.containsMouse ? "#2a2a2a" : "transparent")

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 6

                            FolderGlyph {
                                width: 16 * picker.cellScale / 100
                                height: 13 * picker.cellScale / 100
                                visible: fileIsDir
                            }
                            Image {
                                visible: !fileIsDir
                                width: 16 * picker.cellScale / 100
                                height: 16 * picker.cellScale / 100
                                source: fileIsDir ? "" : fileUrl
                                asynchronous: true
                                fillMode: Image.PreserveAspectFit
                                sourceSize.width: 16 * picker.cellScale / 100
                                sourceSize.height: 16 * picker.cellScale / 100
                                cache: true
                            }
                            Text {
                                Layout.fillWidth: true
                                text: fileName
                                color: "#e0e0e0"
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                        }

                        MouseArea {
                            id: lma
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: picker.selectRow(fileUrl, fileIsDir, index)
                            onDoubleClicked: picker.activateRow(fileUrl, fileIsDir)
                        }
                    }
                }

                // -- details mode --
                ColumnLayout {
                    visible: picker.viewMode === "details"
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 0

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.bottomMargin: 4
                        height: 24
                        color: "#242424"
                        radius: 3
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 0
                            Item { Layout.fillWidth: true; Layout.fillHeight: true
                                RowLayout { anchors.fill: parent; spacing: 3
                                    Text { text: "Name"; color: "#a0a0a0"; font.pixelSize: 11; font.bold: picker.sortColumn === "name" }
                                    SortArrow { up: !picker.sortDesc; on: picker.sortColumn === "name"; Layout.alignment: Qt.AlignVCenter }
                                    Item { Layout.fillWidth: true }
                                }
                                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: picker.sortBy("name") }
                            }
                            Item { Layout.preferredWidth: 6; Layout.fillHeight: true
                                Rectangle { width: 1; height: 14; anchors.centerIn: parent; color: "#4a4a4a" }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.SizeHorCursor
                                    property real startW: 0
                                    property real startX: 0
                                    onPressed: function(mouse) { startW = picker.colSizeW; startX = mouse.x }
                                    onPositionChanged: function(mouse) { picker.colSizeW = Math.max(40, Math.min(300, startW + (mouse.x - startX))) }
                                }
                            }
                            Item { Layout.preferredWidth: picker.colSizeW; Layout.fillHeight: true
                                RowLayout { anchors.fill: parent; spacing: 3
                                    Text { text: "Size"; color: "#a0a0a0"; font.pixelSize: 11; font.bold: picker.sortColumn === "size" }
                                    SortArrow { up: !picker.sortDesc; on: picker.sortColumn === "size"; Layout.alignment: Qt.AlignVCenter }
                                }
                                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: picker.sortBy("size") }
                            }
                            Item { Layout.preferredWidth: 6; Layout.fillHeight: true
                                Rectangle { width: 1; height: 14; anchors.centerIn: parent; color: "#4a4a4a" }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.SizeHorCursor
                                    property real startW: 0
                                    property real startX: 0
                                    onPressed: function(mouse) { startW = picker.colModW; startX = mouse.x }
                                    onPositionChanged: function(mouse) { picker.colModW = Math.max(70, Math.min(300, startW + (mouse.x - startX))) }
                                }
                            }
                            Item { Layout.preferredWidth: picker.colModW; Layout.fillHeight: true
                                RowLayout { anchors.fill: parent; spacing: 3
                                    Text { text: "Modified"; color: "#a0a0a0"; font.pixelSize: 11; font.bold: picker.sortColumn === "modified" }
                                    SortArrow { up: !picker.sortDesc; on: picker.sortColumn === "modified"; Layout.alignment: Qt.AlignVCenter }
                                }
                                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: picker.sortBy("modified") }
                            }
                        }
                    }

                    ListView {
                        id: detailsView
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        model: model

                        delegate: Rectangle {
                            width: detailsView.width
                            height: 24 * picker.cellScale / 100
                            radius: 4
                            opacity: fileName.charAt(0) === "." ? 0.45 : 1.0
                            color: picker.selectedFile === fileUrl ? "#094771" : (dma.containsMouse ? "#2a2a2a" : "transparent")

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 6
                                FolderGlyph {
                                    width: 16 * picker.cellScale / 100
                                    height: 13 * picker.cellScale / 100
                                    visible: fileIsDir
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: fileName
                                    color: "#e0e0e0"
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                }
                                Text {
                                    Layout.preferredWidth: picker.colSizeW
                                    text: fileIsDir ? "" : picker.humanSize(fileSize)
                                    color: "#a0a0a0"
                                    font.pixelSize: 11
                                }
                                Text {
                                    Layout.preferredWidth: picker.colModW
                                    text: fileIsDir ? "" : Qt.formatDateTime(fileModified, "yyyy-MM-dd hh:mm")
                                    color: "#a0a0a0"
                                    font.pixelSize: 11
                                }
                            }

                            MouseArea {
                                id: dma
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: picker.selectRow(fileUrl, fileIsDir, index)
                                onDoubleClicked: picker.activateRow(fileUrl, fileIsDir)
                            }
                        }
                    }
                }
            }

            Rectangle { width: 1; Layout.fillHeight: true; color: "#333333" }

            // live preview panel
            Rectangle {
                Layout.preferredWidth: 230
                Layout.fillHeight: true
                color: "#161616"

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 8

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 170
                        color: "#0d0d0d"
                        border.color: "#333333"
                        border.width: 1
                        radius: 3

                        // preview: plain Image honors sourceSize (fast, low-memory) and shows the
// first frame of GIFs; a separate AnimatedImage plays GIFs below it.
                        Image {
                            id: previewImg
                            objectName: "previewImg"
                            anchors.fill: parent
                            anchors.margins: 4
                            visible: picker.previewFile.toString() !== ""
                            source: picker.previewFile
                            asynchronous: true
                            fillMode: Image.PreserveAspectFit
                            sourceSize.width: 480
                            sourceSize.height: 480
                            cache: false
                        }
                        AnimatedImage {
                            objectName: "gifImg"
                            anchors.fill: parent
                            anchors.margins: 4
                            visible: picker.previewFile.toString() !== "" && picker.previewIsGif
                            source: picker.previewFile
                            cache: false
                        }
                        // uncapped decode used only for accurate Width/Height metadata. It only
// loads when the capped preview hit its limit (image larger than the
// preview), so small images never pay for a second decode.
                        AnimatedImage {
                            id: metaImg
                            objectName: "metaImg"
                            visible: false
                            source: previewImg.status === Image.Ready &&
                                    (previewImg.implicitWidth >= 480 || previewImg.implicitHeight >= 480)
                                    ? previewImg.source : ""
                            asynchronous: true
                            cache: false
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: picker.previewFile.toString() === ""
                            text: "no preview"
                            color: "#555555"
                            font.pixelSize: 11
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: picker.previewFile.toString() !== "" && previewImg.status === Image.Error
                            text: "cannot preview"
                            color: "#aa5555"
                            font.pixelSize: 11
                        }
                    }

                    // ---- mediainfo-style details ----
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        color: "#101010"
                        border.color: "#333333"
                        border.width: 1
                        radius: 3

Text {
                            anchors.centerIn: parent
                            visible: picker.selectedFile.toString() === ""
                            text: "no selection"
                            color: "#555555"
                            font.pixelSize: 11
                        }
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 0
                            visible: picker.selectedFile.toString() !== ""
                            MediaRow { k: "Name"; v: decodeURIComponent(picker.selectedFile.toString().split("/").pop()) }
                            MediaRow { k: "Path"; v: picker.infoPath() }
                            MediaRow { k: "Size"; v: picker.infoSize() }
                            MediaRow { k: "Type"; v: picker.infoType() }
                            MediaRow { k: "Modified"; v: picker.infoModified() }
                            MediaRow { k: "Width"; v: metaImg.status === Image.Ready ? metaImg.implicitWidth : (previewImg.status === Image.Ready && previewImg.implicitWidth < 480 && previewImg.implicitHeight < 480 ? previewImg.implicitWidth : "") }
                            MediaRow { k: "Height"; v: metaImg.status === Image.Ready ? metaImg.implicitHeight : (previewImg.status === Image.Ready && previewImg.implicitWidth < 480 && previewImg.implicitHeight < 480 ? previewImg.implicitHeight : "") }
                        }
    }
    }
    }
}

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: "#3a3a3a"
        }

        // ---- bottom bar ----
        Rectangle {
            Layout.fillWidth: true
            height: 42
            color: "#000000b3"
            radius: 3

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 8

                Item { Layout.fillWidth: true }

                Rectangle {
                    width: 74; height: 28; radius: 3
                    color: cancelMa.containsMouse ? "#3a3a3a" : "#262626"
                    border.color: "#5a5a5a"; border.width: 1
                    Text { anchors.centerIn: parent; text: "Cancel"; color: "#f0f0f0"; font.pixelSize: 12 }
                    MouseArea { id: cancelMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: picker.close() }
                }
                Rectangle {
                    width: 74; height: 28; radius: 3
                    enabled: picker.selectedFile.toString() !== ""
                    opacity: enabled ? 1.0 : 0.4
                    color: openMa.containsMouse ? "#3a3a3a" : "#262626"
                    border.color: "#5a5a5a"; border.width: 1
                    Text { anchors.centerIn: parent; text: "Open"; color: "#f0f0f0"; font.pixelSize: 12 }
                    MouseArea {
                        id: openMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (picker.selectedFile.toString() !== "") {
                                picker.accept()
}
    }
    }
}
}
    }
    }
}


    // -- inline reusable flat button, no theme, black/transparent only --
    component Btn: Rectangle {
        id: btn
        property string label: ""
        property string tip: ""
        signal clicked()
        signal rightClicked()
        width: Math.max(32, lbl.implicitWidth + 18)
        height: 26
        radius: 3
        color: ma.pressed ? "#3a3a3a" : (ma.containsMouse ? "#333333" : "#262626")
        border.color: ma.containsMouse ? "#808080" : "#5a5a5a"
        border.width: 1
        Text {
            id: lbl
            anchors.centerIn: parent
            text: btn.label
            color: "#f0f0f0"
            font.pixelSize: 13
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
        ToolTip.visible: btn.tip !== "" && ma.containsMouse
        ToolTip.text: btn.tip
        ToolTip.delay: 400
    }

    // -- icon-only button: transparent, hover/press darken, lives inside an Island --
    component IconBtn: Rectangle {
        id: ibtn
        property string tip: ""
        signal clicked()
        signal rightClicked()
        width: 30
        height: 26
        radius: 3
        color: ima.pressed ? "#3a3a3a" : (ima.containsMouse ? "#333333" : "#262626")
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
        ToolTip.visible: ibtn.tip !== "" && ima.containsMouse
        ToolTip.text: ibtn.tip
        ToolTip.delay: 400
    }

    // -- button island: one shared background/border for a group of IconBtns --
    component Island: Rectangle {
        default property alias content: islandRow.children
        width: 32
        height: 28
        radius: 4
        color: "#262626"
        border.color: "#5a5a5a"
        border.width: 1
        RowLayout {
            id: islandRow
            anchors.fill: parent
            spacing: 0
        }
    }

    // -- vector toolbar icons (drawn with rotated bars, no glyph/font deps) --
    component IconPrev: Item {
        width: 16; height: 14
        Rectangle { x: 0.57; y: 3.4; width: 14.87; height: 2.2; rotation: -19.65; radius: 1.1; color: "#e8e8e8" }
        Rectangle { x: 0.57; y: 8.4; width: 14.87; height: 2.2; rotation: 19.65; radius: 1.1; color: "#e8e8e8" }
    }
    component IconNext: Item {
        width: 16; height: 14
        Rectangle { x: 0.57; y: 3.4; width: 14.87; height: 2.2; rotation: 19.65; radius: 1.1; color: "#e8e8e8" }
        Rectangle { x: 0.57; y: 8.4; width: 14.87; height: 2.2; rotation: -19.65; radius: 1.1; color: "#e8e8e8" }
    }
    component IconMinus: Item {
        width: 16; height: 14
        Rectangle { x: 0.5; y: 5.75; width: 15; height: 2.5; radius: 1.25; color: "#e8e8e8" }
    }
    component IconPlus: Item {
        width: 16; height: 14
        Rectangle { x: 0.5; y: 5.75; width: 15; height: 2.5; radius: 1.25; color: "#e8e8e8" }
        Rectangle { x: 6.75; y: 0.75; width: 2.5; height: 13.5; radius: 1.25; color: "#e8e8e8" }
    }
    component IconFit: Item {
        width: 16; height: 14
        Rectangle { x: 2.5; y: 1.2; width: 4; height: 1.8; radius: 0.9; color: "#e8e8e8" }
        Rectangle { x: 2.5; y: 1.2; width: 1.8; height: 4; radius: 0.9; color: "#e8e8e8" }
        Rectangle { x: 9.5; y: 1.2; width: 4; height: 1.8; radius: 0.9; color: "#e8e8e8" }
        Rectangle { x: 11.7; y: 1.2; width: 1.8; height: 4; radius: 0.9; color: "#e8e8e8" }
        Rectangle { x: 2.5; y: 11; width: 4; height: 1.8; radius: 0.9; color: "#e8e8e8" }
        Rectangle { x: 2.5; y: 8.8; width: 1.8; height: 4; radius: 0.9; color: "#e8e8e8" }
        Rectangle { x: 9.5; y: 11; width: 4; height: 1.8; radius: 0.9; color: "#e8e8e8" }
        Rectangle { x: 11.7; y: 8.8; width: 1.8; height: 4; radius: 0.9; color: "#e8e8e8" }
    }
    component IconRotate: Item {
        width: 16; height: 14
        Text {
            anchors.centerIn: parent
            font.family: "DejaVu Sans"
            font.pixelSize: 22
            color: "#e8e8e8"
            text: "\u21BB"
        }
    }

    FolderListModel {
        id: folderModel
        nameFilters: ["*.png", "*.PNG", "*.jpg", "*.JPG", "*.jpeg", "*.JPEG", "*.bmp", "*.BMP", "*.gif", "*.GIF", "*.webp", "*.WEBP", "*.svg", "*.SVG", "*.ico", "*.ICO", "*.tif", "*.TIF", "*.tiff", "*.TIFF"]
        showDirs: false
        sortField: FolderListModel.Name
        onStatusChanged: {
            if (status === FolderListModel.Ready && pendingFileName !== "") {
                for (var i = 0; i < count; i++) {
                    if (get(i, "fileName") === pendingFileName) {
                        currentIndex = i
                        break
                    }
                }
                pendingFileName = ""
            }
        }
    }

    function openFile(fileUrl) {
        var path = fileUrl.toString()
        var slash = path.lastIndexOf("/")
        var dirUrl = path.substring(0, slash)
        var fileName = decodeURIComponent(path.substring(slash + 1))
        pendingFileName = fileName
        currentFile = fileUrl
        currentFileName = fileName
        resetView()
        folderModel.folder = dirUrl
    }

    function resetView() {
        zoomFactor = 1.0
        fitToWindow = true
        rotationAngle = 0
        panX = 0
        panY = 0
    }

    function loadIndex(i) {
        if (folderModel.count === 0)
            return
        if (i < 0)
            i = folderModel.count - 1
        if (i >= folderModel.count)
            i = 0
        currentIndex = i
        // role is "fileUrl", not "fileURL" -- case matters, get() returns undefined on a bad role
        currentFile = folderModel.get(i, "fileUrl")
        currentFileName = folderModel.get(i, "fileName")
        resetView()
    }

    function nextImage() { loadIndex(currentIndex + 1) }
    function prevImage() { loadIndex(currentIndex - 1) }

    function zoomIn() {
        if (fitToWindow) {
            fitToWindow = false
            zoomFactor = img.fitScale * 1.25
        } else {
            zoomFactor = Math.min(zoomFactor * 1.25, 16)
        }
    }
    function zoomOut() {
        if (fitToWindow) {
            fitToWindow = false
            zoomFactor = Math.max(img.fitScale / 1.25, 0.05)
        } else {
            zoomFactor = Math.max(zoomFactor / 1.25, 0.05)
        }
    }
    function zoomActual() { fitToWindow = false; zoomFactor = 1.0; panX = 0; panY = 0 }
    function zoomFit() { fitToWindow = true; panX = 0; panY = 0 }

    function rotateCW() { rotationAngle = (rotationAngle + 90) % 360 }
    function rotateCCW() { rotationAngle = (rotationAngle - 90 + 360) % 360 }

    function toggleFullscreen() {
        var goingFullscreen = root.visibility !== Window.FullScreen
        root.visibility = goingFullscreen ? Window.FullScreen : Window.Windowed
        chromeVisible = !goingFullscreen
    }

    function humanFileSize(bytes) {
        if (bytes === undefined || bytes <= 0)
            return ""
        var units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var i = 0
        var v = bytes
        while (v >= 1024 && i < units.length - 1) {
            v /= 1024
            i++
        }
        return (i === 0 ? v : v.toFixed(1)) + " " + units[i]
    }

    // pick up a file passed on the command line, if any.
    // skip .qml args: `qml ImageViewer.qml` puts this file's own path
    // in arguments[1], which used to get opened as an "image" and fail
    // on every single launch, file or no file.
    Component.onCompleted: {
        var args = Qt.application.arguments
        for (var i = 1; i < args.length; i++) {
            if (args[i].toLowerCase().endsWith(".qml"))
                continue
            openFile(Qt.resolvedUrl(args[i]))
            break
        }
        keyHandler.forceActiveFocus()
    }

    // custom in-app picker -- replaces QtQuick.Dialogs.FileDialog.
    // the native/portal dialog's theme is outside this app's control
    // (dark sidebar on dark background, no thumbnails); this one is not.
    FilePicker {
        id: fileDialog
        host: root
        onAccepted: root.openFile(selectedFile)
    }

    // ---- image viewport ----
    Item {
        id: viewport
        anchors.fill: parent
        clip: true

        AnimatedImage {
            id: img
            source: root.currentFile
            fillMode: Image.Pad
            asynchronous: true
            smooth: true
            cache: false
            width: sourceSize.width > 0 ? sourceSize.width : 1
            height: sourceSize.height > 0 ? sourceSize.height : 1
            rotation: root.rotationAngle
            scale: root.fitToWindow ? fitScale : root.zoomFactor
            x: viewport.width / 2 - width / 2 + (root.fitToWindow ? 0 : root.panX)
            y: viewport.height / 2 - height / 2 + (root.fitToWindow ? 0 : root.panY)

            readonly property bool swapped: root.rotationAngle === 90 || root.rotationAngle === 270
            readonly property real fitScale: {
                var iw = swapped ? sourceSize.height : sourceSize.width
                var ih = swapped ? sourceSize.width : sourceSize.height
                if (iw <= 0 || ih <= 0 || viewport.width <= 0 || viewport.height <= 0)
                    return 1.0
                return Math.min(viewport.width / iw, viewport.height / ih)
            }
        }

        Text {
            anchors.centerIn: parent
            visible: root.currentFile === ""
            text: "drop an image here, or press O to open"
            color: "#666666"
            font.pixelSize: 15
        }

        Text {
            anchors.centerIn: parent
            visible: root.currentFile !== "" && img.status === Image.Error
            text: "failed to load: " + root.currentFileName
            color: "#aa5555"
            font.pixelSize: 14
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            onPressed: function(mouse) {
                _lastX = mouse.x
                _lastY = mouse.y
            }
            onPositionChanged: function(mouse) {
                root.hoverNearTop = mouse.y < 28
                root.hoverNearBottom = mouse.y > viewport.height - 28
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
            property real _lastX: 0
            property real _lastY: 0
        }

        DropArea {
            anchors.fill: parent
            onDropped: function(drop) {
                if (drop.hasUrls && drop.urls.length > 0)
                    root.openFile(drop.urls[0])
            }
        }
    }

    // ---- keyboard shortcuts ----
    Item {
        id: keyHandler
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
            switch (event.key) {
            case Qt.Key_O: fileDialog.open(); break
            case Qt.Key_Left: root.prevImage(); break
            case Qt.Key_Right: root.nextImage(); break
            case Qt.Key_Plus: case Qt.Key_Equal: root.zoomIn(); break
            case Qt.Key_Minus: root.zoomOut(); break
            case Qt.Key_0: root.zoomActual(); break
            case Qt.Key_Tab: root.chromeVisible = !root.chromeVisible; break
            case Qt.Key_F: case Qt.Key_F11: root.toggleFullscreen(); break
            case Qt.Key_Escape:
                if (root.visibility === Window.FullScreen)
                    root.toggleFullscreen()
                break
            }
        }
    }

    // ---- top toolbar: black, translucent, slides off-screen when hidden ----
    Rectangle {
        id: toolbar
        anchors.left: parent.left
        anchors.right: parent.right
        height: 40
        y: (root.chromeVisible || root.hoverNearTop || toolbarHoverHandler.hovered) ? 0 : -height
        color: "transparent"

        Behavior on y { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

        HoverHandler { id: toolbarHoverHandler }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 6

            Btn { label: "Open"; tip: "Open image (O)"; onClicked: fileDialog.open() }
            Island { width: 62
                IconBtn { tip: "Previous (Left)"; onClicked: root.prevImage(); IconPrev { anchors.centerIn: parent } }
                IconBtn { tip: "Next (Right)"; onClicked: root.nextImage(); IconNext { anchors.centerIn: parent } }
            }
            Island { width: 62
                IconBtn { tip: "Zoom out (-)"; onClicked: root.zoomOut(); IconMinus { anchors.centerIn: parent } }
                IconBtn { tip: "Zoom in (+)"; onClicked: root.zoomIn(); IconPlus { anchors.centerIn: parent } }
            }
            Island {
                IconBtn { tip: "Fit to window"; onClicked: root.zoomFit(); IconFit { anchors.centerIn: parent } }
            }
            Island {
                IconBtn { tip: "Left click: rotate CW, right click: rotate CCW"; onClicked: root.rotateCW(); onRightClicked: root.rotateCCW(); IconRotate { anchors.centerIn: parent } }
            }
            Item { Layout.fillWidth: true }
            Btn { label: root.chromeVisible ? "Hide UI" : "Show UI"; tip: "Hide controls (Tab)"; onClicked: root.chromeVisible = !root.chromeVisible }
        }
    }

    // ---- bottom status bar: black, translucent, slides off-screen when hidden ----
    Rectangle {
        id: statusbar
        anchors.left: parent.left
        anchors.right: parent.right
        height: 26
        y: (root.chromeVisible || root.hoverNearBottom || statusbarHoverHandler.hovered) ? parent.height - height : parent.height
        color: "#80000000"

        Behavior on y { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

        HoverHandler { id: statusbarHoverHandler }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 16

            Text {
                text: root.currentFileName === "" ? "no image" : root.currentFileName
                color: "#e8e8e8"
                font.pixelSize: 12
                elide: Text.ElideMiddle
                Layout.fillWidth: true
            }
            Text {
                text: folderModel.count > 0 ? (root.currentIndex + 1) + " / " + folderModel.count : ""
                color: "#c0c0c0"
                font.pixelSize: 12
            }
            Text {
                text: img.sourceSize.width > 0 ? img.sourceSize.width + " x " + img.sourceSize.height : ""
                color: "#c0c0c0"
                font.pixelSize: 12
            }
            Text {
                text: Math.round((root.fitToWindow ? img.fitScale : root.zoomFactor) * 100) + "%"
                color: "#c0c0c0"
                font.pixelSize: 12
            }
            Text {
                text: root.currentIndex >= 0 ? root.humanFileSize(folderModel.get(root.currentIndex, "fileSize")) : ""
                color: "#c0c0c0"
                font.pixelSize: 12
            }
        }
    }
}
