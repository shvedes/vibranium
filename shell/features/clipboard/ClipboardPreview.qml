pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import "ClipboardLib.js" as CL

// Preview pane to the right of the list. Mode precedence:
//   secret ▸ image ▸ text (file dump | inline) ▸ function graph ▸
//   info cards (media, folder) ▸ empty.
// Media sits inside a 16:9 stage so screenshots letterbox correctly; GIFs
// render as stills. Everything shares an outer gutter so the right margin
// is never clipped.
//
// Media RAM contract: the Image rasterizes at exactly stage px *
// devicePixelRatio - the true device-pixel count the pane can show. A
// 4K screenshot therefore decodes into a small preview texture instead
// of a blanket 1280x1280 (~6.5MB) that ignores the pane size.
Rectangle {
  id: root

  property var entry: null
  property var previewData: ({})              // panel publishes per selection

  readonly property var d: previewData || ({})

    readonly property string mediaFile: {
    if (!root._paint || root._paint.type !== "image") return ""
    if (root._paint.imageDataFile) return String(root._paint.imageDataFile)
    if (root._paint.imageFile) return String(root._paint.imageFile)
    if (root._paint.filePaths && root._paint.filePaths.length === 1) return String(root._paint.filePaths[0])
    return ""
  }
  readonly property string mediaSource: mediaFile !== "" ? "file://" + mediaFile : ""

  readonly property bool isSecret: root._paint ? root._paint.type === "secret" : false
  readonly property bool isMedia: root._paint && root._paint.type === "image" && mediaSource !== ""
  // Static function graph: text entries holding a single correct f(x).
  // Same grid/axis/curve as the launcher's live graph, frozen per
  // selection. Secrets never graph, even when their payload parses.
  readonly property string funcBody: (root._paint && root._paint.type === "text" && !isSecret)
    ? CL.funcBodyFor(String(root._paint.raw || "").slice(0, 4096)) : ""
  readonly property bool isFunc: funcBody !== ""
  readonly property bool isInline: root._paint && (root._paint.type === "text" || root._paint.type === "url") && !isSecret && !isFunc
  readonly property bool isTextfile: d.kind === "textfile" && !isFunc
  readonly property bool isMediaInfo: root._paint && root._paint.type === "file" && d.kind === "mediainfo"
  readonly property var mi: d.mi || null
  // Folder card: name, file count and total size straight off the
  // entry's own probe fields - the capture-time walk already paid for
  // them, so the card spawns nothing.
  readonly property bool isFolderInfo: root._paint && (root._paint.type === "folder"
    || root._paint.allFolders === true)
  readonly property var folderRows: CL.folderInfoRows(root._paint)
  // Git rows for a folder carrying a persisted payload: entry-owned, so
  // nothing accumulates in previewData and restarts keep their rows. A
  // missing payload probes on demand (or revalidates in the background),
  // never from here.
  readonly property var gitRows: CL.gitInfoRows(root._paint && root._paint.git ? root._paint.git : null)
  // A binary file row shows its name, never the skeleton: there is no
  // preview coming that the skeleton could stand in for.
  readonly property bool isBinary: root.d.kind === "binary" && root._paint && root._paint.type === "file"
  // miRows is defined in 3e - it needs the parsed AND summary branches.
  readonly property bool isUnpreviewable: !isSecret && !isMedia
    && !isInline && !isTextfile && !isMediaInfo && !isFolderInfo && !isFunc

  readonly property var miRows: {
    if (mi)
      return CL.mediaInfoRows(mi)
    if (d.summary)
      return [{ icon: String(d.summary.video ? "recording" : "file-music"),
                label: "File", value: String(d.summary.ext).toUpperCase() }]
    return []
  }
  readonly property bool hasSelection: root._paint != null
  property bool mediaFailed: false

  // Staged paint entry: selection changes fade the old contents out,
  // swap, then fade the new contents in - never a 1-frame snap. While
  // a fade is in flight newer selections only update the pending slot;
  // the swap always lands the latest one. MotionPolicy off paints
  // directly. Only the contents travel: the background Rectangle below
  // stays solid throughout.
  //
  // Image-to-image swaps skip the content fade: the media stage below
  // crossfades from its own skeleton as the decode lands, so a second
  // whole-pane fade on top reads as one extra flicker per switch that
  // the selection change itself never asked for.
  property var _paint: entry
  property var _pendingPaint: null
  property bool _fading: false
  // The painted row's id, for readers that must not sample a paint
  // mid-flight (the panel keys the preview payload off this, so a
  // payload racing the fade never decorates the outgoing contents).
  readonly property int paintId: root._paint ? root._paint.id : -1
  // The media file a paint entry would stage, or "" when it stages none -
  // the same resolution mediaSource applies to _paint, so an image swap
  // is recognised before any decode or fade runs.
  function _mediaFileOf(p) {
    if (!p || p.type !== "image") return ""
    if (p.imageDataFile) return String(p.imageDataFile)
    if (p.imageFile) return String(p.imageFile)
    if (p.filePaths && p.filePaths.length === 1) return String(p.filePaths[0])
    return ""
  }
  function _stage(next) {
    root._pendingPaint = next
    if (!MotionPolicy.enabled) {
      root._paint = next
      root._fading = false
      return
    }
    if (root._fading) return
    if (next === root._paint) return
    // Same logical row, refreshed payload: a background probe patch
    // replaces the entry object without moving selection, so swap it
    // silently instead of fading. Fades are for entry switches only.
    if (next && root._paint && next.id !== undefined && next.id === root._paint.id) {
      root._paint = next
      return
    }
    if (root._mediaFileOf(root._paint) !== "" && root._mediaFileOf(next) !== "") {
      root._paint = next
      return
    }
    root._fading = true
    fadeOut.from = contentHost.opacity
    fadeOut.restart()
  }
  onEntryChanged: {
    root._stage(entry)
  }
  // Window-open snap: land on the current entry with no animation. The
  // panel calls this after seating, so everything after it is either an
  // entry switch (which fades) or a same-row refresh (which swaps
  // silently above). Also clears a fade left in flight by a close.
  function snapOpen() {
    fadeOut.stop()
    fadeIn.stop()
    root._pendingPaint = root.entry
    root._paint = root.entry
    root._fading = false
    contentHost.opacity = 1
  }
  Component.onCompleted: {
    // Freeze the staged paint entry: the binding above only seeds the
    // first frame, and every later swap goes through _stage, so the
    // self-assignment drops it with no value change and no tween.
    root._paint = root._paint
  }

  // Content dip for the staged swap above: out, swap under cover, back
  // in. Handoffs start from the live opacity and ends equal rest, so
  // an interrupted flip stays continuous.
  NumberAnimation {
    id: fadeOut
    target: contentHost
    property: "opacity"
    to: 0
    duration: Ui.fastMs
    easing.type: Easing.OutCubic
    onFinished: {
      root._paint = root._pendingPaint
      fadeIn.from = contentHost.opacity
      fadeIn.restart()
    }
  }
  NumberAnimation {
    id: fadeIn
    target: contentHost
    property: "opacity"
    to: 1
    duration: Ui.fastMs
    easing.type: Easing.OutCubic
    onFinished: {
      root._fading = false
      if (root._pendingPaint !== root._paint) root._stage(root._pendingPaint)
    }
  }

  // Decode budget for the full-res still below: at most one decode per
  // 200ms and only while the pane is shown, so scrolling the history
  // does not fork a decode per row. Hiding drops the texture outright
  // (with cache:false there is nothing to keep it alive), and showing
  // re-arms through the same debounce. A stale source is dropped the
  // moment the selection moves on: without the reset the outgoing file
  // keeps painting under the incoming entry for the whole debounce
  // window, so switching previews flashes the previous image back until
  // the next decode lands.
  property string _decodeSource: ""
  function _syncDecodeSource() {
    root._decodeSource = (root.isMedia && root.visible) ? root.mediaSource : ""
  }
  onMediaSourceChanged: {
    if (root._decodeSource !== "" && root._decodeSource !== root.mediaSource)
      root._decodeSource = ""
    decodeDebounce.restart()
  }
  onVisibleChanged: {
    if (root.visible) decodeDebounce.restart()
    else { decodeDebounce.stop(); root._decodeSource = "" }
  }
  Timer {
    id: decodeDebounce
    interval: 200
    repeat: false
    onTriggered: root._syncDecodeSource()
  }

  // Decode-size buckets: the decoder re-runs on every sourceSize change,
  // so a live pixel-geometry binding re-decodes per pixel of pane
  // resize. Snapping to 256/512/1024/2048 decodes once per bucket
  // instead, still at-or-above the pane's device-pixel count.
  function _decodeBucket(n) {
    const v = Math.ceil(Number(n) || 0)
    if (v <= 256) return 256
    if (v <= 512) return 512
    if (v <= 1024) return 1024
    return 2048
  }

  // Large dumps are capped for the text bindings below: the pane shows
  // the head and names the total, so a huge paste never pays a
  // full-string Text layout while hidden or while shown.
  function _dumpText(s) {
    const t = String(s || "")
    if (t.length <= 10000) return t
    return t.slice(0, 10000) + "\n... [truncated, " + t.length + " chars total]"
  }

  // Preview pane's own window DPR (same mechanism as Icon.qml) so the
  // raster is exactly stage * DPR device pixels - texel-crisp at any
  // scale factor and never larger than the pane can show.
  readonly property real _dpr: Window.window ? Window.window.devicePixelRatio : 1

  // placeholder copy - multi-file selections intentionally not previewed
  readonly property string phTitle: !hasSelection ? "No selection"
    : (isBinary ? "Binary file" : "Nothing to preview")
  readonly property string phNote: hasSelection && root._paint.filePaths && root._paint.filePaths.length === 1
    ? String(root._paint.filePaths[0]) : ""

  color: Theme.color("background_0")
  // No box border: the panel draws the single vertical separator in the
  // shared gap instead.
  clip: true
  // Corners follow RoundingPolicy (hypr.decoration.rounding).
  radius: RoundingPolicy.radius

  // Skeleton media-info row: 16px icon slot, short label bar, value bar
  // in the delegate's own offsets (Ui.l + Ui.s, 56 label column).
  // Static, island chrome (tint @0.14, 2px corners). Stays local: it
  // mocks the clipboard's textual preview rows, which the wallpaper
  // pane has no equivalent of.
  component SkeletonMiRow: Item {
    id: miRow

    property real labelW: 44
    property real valueFrac: 0.7

    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: 16
      height: 16
      radius: RoundingPolicy.radius
      color: Ui.tint("foreground_1", 0.14)
    }

    Rectangle {
      x: Ui.l + Ui.s
      width: miRow.labelW
      height: 8
      radius: RoundingPolicy.radius
      anchors.verticalCenter: parent.verticalCenter
      color: Ui.tint("foreground_1", 0.14)
    }

    Rectangle {
      x: Ui.l + Ui.s + 56 + Ui.s
      width: Math.max(0, (parent.width - (Ui.l + Ui.s + 56 + Ui.s)) * miRow.valueFrac)
      height: 8
      radius: RoundingPolicy.radius
      anchors.verticalCenter: parent.verticalCenter
      color: Ui.tint("foreground_1", 0.14)
    }
  }

  // Outer gutter - guarantees the right margin.
  Item {
    id: gutter
    anchors.fill: parent
    anchors.margins: Ui.m
    anchors.topMargin: Ui.s
    anchors.bottomMargin: Ui.s
  }

  // Contents host: the staged swap fades this whole box (out, swap
  // under cover, back in) while the background Rectangle stays solid.
  Item {
    id: contentHost
    anchors.fill: gutter
    // __PREV_SECRET__
    // ---- secret ----
    Item {
      anchors.fill: parent
      visible: isSecret
      Column {
        anchors.centerIn: parent
        spacing: Ui.s
        Icon {
          anchors.horizontalCenter: parent.horizontalCenter
          name: "lock"
          colorKey: "foreground_1"
          size: 44
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: "Sensitive content hidden"
          color: Ui.tint("foreground_1", 0.5)
          font.pixelSize: Ui.fontM
          font.family: Ui.fontFamily
          font.italic: true
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          width: 220
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          text: "Still pasteable with Ctrl+V"
          color: Ui.tint("foreground_1", 0.45)
          font.pixelSize: Ui.fontS
          font.family: Ui.fontFamily
        }
      }
    }

    // __PREV_MEDIA__
    // ---- media stage (image aspect) ----
    // Static images only. GIFs render as stills, videos/listings were dropped.
    // Stage matches the image's own aspect so no 16:9 letterbox gaps.
    Item {
      id: stage
      anchors.fill: parent
      visible: isMedia

      readonly property real imgAspect: (root._paint && root._paint.imageW > 0 && root._paint.imageH > 0) ? root._paint.imageW / root._paint.imageH : 16/9
      readonly property real stageW: Math.min(gutter.width, gutter.height * imgAspect)
      readonly property real stageH: stageW / imgAspect

      Image {
        id: still
        anchors.centerIn: parent
        width: stage.stageW
        height: stage.stageH
        fillMode: Image.PreserveAspectFit
        source: root._decodeSource
        asynchronous: true
        smooth: true
        opacity: status === Image.Ready ? 1 : 0

        Behavior on opacity {
          enabled: MotionPolicy.enabled
          NumberAnimation { duration: Ui.slowMs; easing.type: Easing.OutCubic }
        }
        // Scoped to this full-res still only: a cached 4K decode would pin
        // tens of MB per previewed shot, and the debounce + visible gate
        // above bound how often a decode is even started.
        cache: false
        // Rasterize at the pane's true device-pixel count, not the source
        // resolution: the decoder downsamples during load, so a 4K/5K
        // screenshot costs ~1.3MB of texture instead of tens of MB.
        // Bucket-snapped (see _decodeBucket): one decode per bucket, not
        // one per pixel of pane resize.
        sourceSize.width: root._decodeBucket(stage.stageW * root._dpr)
        sourceSize.height: root._decodeBucket(stage.stageH * root._dpr)
        onSourceChanged: root.mediaFailed = false
        onStatusChanged: {
          if (status === Image.Error) root.mediaFailed = true
          else if (status === Image.Ready) root.mediaFailed = false
          else if (status === Image.Loading) root.mediaFailed = false
        }
      }

      // Decode failure only
      Item {
        anchors.centerIn: parent
        visible: root.mediaFailed && root.isMedia && still.status === Image.Error
        Column {
          anchors.centerIn: parent
          spacing: Ui.s
          Icon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: "bug"
            colorKey: "foreground_1"
            size: 40
            opacity: 0.5
          }
          Text {
            text: "Failed to decode"
            color: Ui.tint("foreground_1", 0.5)
            font.pixelSize: Ui.fontS
            font.family: Ui.fontFamily
          }
        }
      }
    }

    // __PREV_INFO__
    // ---- info card (media metadata, or folder name/count/size) ----
    // One scrollable card in one row vocabulary; the model switches on
    // the painted row. The media format tag hides for folders, which
    // carry no format.
    Flickable {
      id: infoFlick
      anchors.fill: parent
      visible: isMediaInfo || isFolderInfo
      clip: true
      contentWidth: width
      contentHeight: infoCol.implicitHeight + 2 * Ui.s
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: infoCol
        width: infoFlick.width - 2 * Ui.s
        x: Ui.s
        y: Ui.s
        spacing: Ui.s

        // container tag (format), then metadata rows
        Text {
          width: parent.width
          visible: mi !== null && mi.format !== undefined
          text: mi !== null && mi.format !== undefined ? String(mi.format) : ""
          color: Ui.tint("foreground_1", 0.45)
          font.pixelSize: Ui.fontS
          font.family: Ui.fontFamily
          elide: Text.ElideRight
        }

        // metadata rows: icon + label + value, donated proportions
        Repeater {
          model: isFolderInfo ? folderRows.concat(gitRows) : miRows
          // Delegate root is a plain Item (explicit geometry) so its
          // children may use anchors; Column-positioner children must not.
          delegate: Item {
            required property var modelData
            width: infoCol.width
            height: Math.max(16, valLbl.implicitHeight)
            Icon {
              name: modelData.icon
              colorKey: "foreground_1"
              size: 16
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              // -> 16 is Ui.l, so the offsets below read tokens verbatim.
              x: Ui.l + Ui.s
              width: 56
              text: modelData.label
              color: Ui.tint("foreground_1", 0.5)
              font.pixelSize: Ui.fontS
              font.family: Ui.fontFamily
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              id: valLbl
              x: Ui.l + Ui.s + 56 + Ui.s
              width: parent.width - x
              text: modelData.value
              color: Ui.tint("foreground_1", 0.9)
              font.pixelSize: Ui.fontS
              font.family: Ui.fontFamily
              elide: Text.ElideRight
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }
    }

    // __PREV_TEXT__
    // ---- text: file dump (source/markdown/etc) ----
    Flickable {
      id: fileFlick
      anchors.fill: parent
      visible: isTextfile
      clip: true
      contentHeight: fileText.height
      contentWidth: width
      flickableDirection: Flickable.VerticalFlick

      Text {
        id: fileText
        width: fileFlick.width
        text: isTextfile ? root._dumpText(d.content) : ""
        color: Ui.tint("foreground_0", 1)
        font.pixelSize: Ui.fontM
        font.family: "monospace"
        wrapMode: Text.WrapAnywhere
        textFormat: Text.PlainText
      }
    }

    // ---- inline clipboard text ----
    Flickable {
      id: inlineFlick
      anchors.fill: parent
      visible: isInline && !isTextfile
      clip: true
      contentHeight: inlineText.height
      contentWidth: width
      flickableDirection: Flickable.VerticalFlick

      Text {
        id: inlineText
        width: inlineFlick.width
        text: isInline ? root._dumpText(root._paint.preview || root._paint.raw) : ""
        color: Ui.tint("foreground_0", 1)
        font.pixelSize: Ui.fontM
        font.family: Ui.fontFamily
        wrapMode: Text.WrapAnywhere
        textFormat: Text.PlainText
      }
    }

    // __PREV_FUNC__
    // ---- static function graph (single correct f(x)) ----
    // Same FunctionGraph (grid, axes, curve) the launcher draws live -
    // frozen per selected entry. The graph is what a function entry shows
    // instead of an inline text dump; the header already reads "y = <expr>".
    // Fill mode: the graph absorbs the full gutter height, no top/bottom
    // gaps - the plot box (not a fixed pixel height) is what stretches.
    Item {
      anchors.fill: parent
      visible: isFunc

      FunctionGraph {
        anchors.fill: parent
        fillHeight: true
        funcBody: root.funcBody
      }
    }

    // __PREV_PLACEHOLDER__
    // ---- placeholder (no preview / empty) ----
    // Skeleton of a media-info card behind (format bar + mock rows in the
    // delegate's geometry). With no selection the skeleton stands alone;
    // otherwise it dims under the message - same treatment as the list's
    // empty state.
    Item {
      anchors.fill: parent
      visible: isUnpreviewable

      Column {
        x: Ui.s
        y: Ui.s
        width: parent.width - 2 * Ui.s
        spacing: Ui.s
        opacity: 0.8
        visible: !hasSelection && !root.isBinary

        Rectangle {
          width: parent.width * 0.4
          height: 8
          radius: RoundingPolicy.radius
          color: Ui.tint("foreground_1", 0.14)
        }

        SkeletonMiRow { width: parent.width; height: 16; labelW: 44; valueFrac: 0.7 }
        SkeletonMiRow { width: parent.width; height: 16; labelW: 52; valueFrac: 0.45 }
        SkeletonMiRow { width: parent.width; height: 16; labelW: 36; valueFrac: 0.8 }
        SkeletonMiRow { width: parent.width; height: 16; labelW: 48; valueFrac: 0.55 }
      }

      Rectangle {
        anchors.fill: parent
        visible: hasSelection && !root.isBinary
        color: Ui.tint("background_0", 0.45)
      }

      Column {
        anchors.centerIn: parent
        visible: hasSelection
        width: gutter.width - Ui.l
        spacing: Ui.s
        Icon {
          anchors.horizontalCenter: parent.horizontalCenter
          name: hasSelection ? "bug" : "file"
          colorKey: "foreground_1"
          size: 54
          opacity: 0.35
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          width: 220
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          text: phTitle
          color: Ui.tint("foreground_1", 0.6)
          font.pixelSize: Ui.fontM
          font.family: Ui.fontFamily
          font.italic: true
          textFormat: Text.PlainText
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          width: 240
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          visible: phNote !== ""
          text: phNote
          color: Ui.tint("foreground_1", 0.4)
          font.pixelSize: Ui.fontXs
          font.family: Ui.fontFamily
          elide: Text.ElideMiddle
          textFormat: Text.PlainText
        }
      }
    }

  }

  // Keyboard scroll target: textfile dump, inline text or the info
  // card. Secrets, media, function graphs and placeholders
  // intentionally no-op.
  function scrollText(delta) {
    const view = isTextfile ? fileFlick
      : (isInline ? inlineFlick : ((isMediaInfo || isFolderInfo) ? infoFlick : null))
    if (!view) return false
    const maxY = Math.max(0, view.contentHeight - view.height)
    const next = Math.max(0, Math.min(maxY, view.contentY + delta))
    if (next === view.contentY) return false
    view.contentY = next
    return true
  }
  function resetTextScroll() {
    fileFlick.contentY = 0
    inlineFlick.contentY = 0
    infoFlick.contentY = 0
  }

  // Reset policy: scroll to top when the painted entry id or preview
  // kind changes. Kind tracking ignores unrelated payload identity
  // churn so background probes never reset the user's position.
  property int _scrolledId: -1
  property string _scrolledKind: ""
  on_PaintChanged: {
    const id = root._paint ? root._paint.id : -1
    if (id === root._scrolledId) return
    root._scrolledId = id
    root._scrolledKind = String(root.d.kind || "")
    root.resetTextScroll()
  }
  onDChanged: {
    const kind = String(root.d.kind || "")
    if (kind === root._scrolledKind) return
    root._scrolledKind = kind
    root.resetTextScroll()
  }
}
