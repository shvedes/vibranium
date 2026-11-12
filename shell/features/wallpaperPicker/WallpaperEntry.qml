pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs.common
import qs.features.wallpaperPicker
import "../../common/text/StringUtils.js" as SU

// One wallpaper in the picker's cascade.
//
// The tile is a picture first: the selected wallpaper paints as a full 16:9
// card, its neighbours as narrow slices of the same deck. What it looks like
// is the whole of its job - selection, pending deletion and the decode budget
// all arrive as properties, and the deck's own cell places and moves it
// (x/y/width/height are bound there, so that arithmetic has one home). The
// wallpaper in use is named in accent under the deck rather than marked on the
// picture, so the deck itself stays a wall of images.
Rectangle {
  id: tile

  property string file: ""
  // Position in the deck relative to the selection: 0 is the big card,
  // negative is to its left. The panel's own binding keeps this current.
  property int rel: 0
  // A removal is in flight for this file: the tile stays in place but takes no
  // clicks.
  property bool pending: false
  // Removal armed for this file: the red pane slides up from the bottom of the
  // picture, and the next Delete removes it.
  property bool deleteArmed: false
  // Whether this tile is close enough to the selection to spend a decode on.
  property bool decode: true
  // Decode box in device pixels, shared by the deck and read here so a 5K
  // wallpaper is never rasterized at its own size.
  property int decodeW: 0
  property int decodeH: 0
  readonly property bool selected: tile.rel === 0

  signal chosen()

  radius: RoundingPolicy.radius
  color: Ui.solid("background_2")
  border.width: tile.selected ? 2 : 1
  border.color: tile.selected
    ? Ui.solid("accent")
    : Ui.tint("foreground_1", 0.10)
  clip: true
  opacity: tile.pending ? 0.35 : 1

  // The cell places and animates the deck; the tile only fades for its own
  // state changes (a removal in flight). Same clock and curve as the rest of
  // the shell, off with the global switch.
  Behavior on opacity {
    enabled: MotionPolicy.enabled
    Glide { duration: Ui.fastMs }
  }

  readonly property string path: tile.file !== ""
    ? SU.joinPath(WallpaperPicker.backgroundsDir, tile.file)
    : ""

  // The content window. A Rectangle's clip is its bounding box and not its
  // rounded path, so a picture inside a rounded tile paints square corners over
  // the frame - and so does the red confirm pane under it. One mask over the
  // content keeps everything inside the same radius the tile follows, so the
  // picture meets the frame's inner edge instead of crossing it. The layer
  // exists only while rounding is on: a square theme has nothing to mask and
  // must not pay an offscreen pass per tile for it.
  //
  // The frame's own border stays outside this item: it is drawn on the rounded
  // path already, and masking it as well would eat half its width.
  Item {
    id: frame

    anchors.fill: parent
    layer.enabled: RoundingPolicy.radius > 0
    layer.smooth: true
    layer.samples: 4
    layer.effect: MultiEffect {
      maskEnabled: true
      maskSource: frameMask
      maskThresholdMin: 0.5
      // A feathered rim rather than a hard one: the mask samples a rectangle at
      // the tile's own size, and a hard edge there shows the stair-stepping of
      // whichever corner is being rounded.
      maskSpreadAtMin: 0.5
    }

    Image {
      id: preview

      anchors.fill: parent
      source: tile.decode && tile.path !== "" ? Paths.toFileUrl(tile.path) : ""
      sourceSize.width: tile.decodeW
      sourceSize.height: tile.decodeH
      // Cropped, not fitted: a slice of the picture is the point, and the card
      // keeps the frame it was sized for whatever the wallpaper's aspect is.
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      smooth: true
      opacity: status === Image.Ready ? 1 : 0

      Behavior on opacity {
        enabled: MotionPolicy.enabled
        NumberAnimation { duration: Ui.normalMs; easing.type: Easing.OutCubic }
      }
    }

    Icon {
      anchors.centerIn: parent
      visible: preview.status === Image.Error && tile.file !== ""
      name: "image"
      colorKey: "foreground_1"
      size: tile.selected ? 40 : 24
      opacity: 0.3
    }

    // Everything that is not the selection sits behind one flat veil: the same
    // strength for every neighbour, no ramp, because the deck is a set of pictures
    // and the only thing worth reading off their brightness is which one is the
    // selection. The veil follows the tile's rounding - a square one painted over
    // the rounded corners, which read as four dark nicks on every neighbour.
    Rectangle {
      anchors.fill: parent
      radius: RoundingPolicy.radius
      color: Ui.tint("background_0", 0.35)
      opacity: tile.selected ? 0 : 1

      // The card taking the selection gives the veil up over the same glide the
      // card beside it takes it on, so the exchange happens on the deck's clock
      // rather than as a flash the moment the index changes.
      Behavior on opacity {
        enabled: MotionPolicy.enabled
        Glide { duration: Ui.slowMs }
      }
    }

    // The armed removal: a red pane rises from the bottom of the picture with the
    // trash glyph centered, so the destructive step is aimed at the image it will
    // remove rather than at a line of text elsewhere on the surface.
    Rectangle {
      id: deletePane

      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: tile.deleteArmed ? Math.min(Math.round(tile.height * 0.18), 76) : 0
      color: Ui.solid("red")
      clip: true

      Behavior on height {
        enabled: MotionPolicy.enabled
        Glide { duration: Ui.normalMs }
      }

      Icon {
        anchors.centerIn: parent
        name: "remove"
        colorKey: "background_0"
        size: 36
        opacity: tile.deleteArmed ? 1 : 0

        Behavior on opacity {
          enabled: MotionPolicy.enabled
          Glide { duration: Ui.fastMs }
        }
      }
    }
  }

  // The shape the content is masked to: the tile's own corners, painted opaque
  // for the mask to read (it samples alpha, not luminance) and never drawn
  // itself. It keeps its own layer on because an item that is not painted has
  // no texture for the effect to sample.
  Rectangle {
    id: frameMask

    anchors.fill: parent
    radius: RoundingPolicy.radius
    color: "#000000"
    visible: false
    layer.enabled: true
    layer.smooth: true
    layer.samples: 4
  }

  MouseArea {
    anchors.fill: parent
    enabled: !tile.pending
    cursorShape: Qt.PointingHandCursor
    onClicked: tile.chosen()
  }
}
