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
  // Directory the picture is read from: the user overlay or the install
  // tree. Empty falls back to the user overlay for a departing tile.
  property string dir: ""
  // A revealed wallpaper the user disabled: the picture stays, and the badge
  // over it says the theme no longer offers it.
  property bool disabled: false
  // Position in the deck relative to the selection: 0 is the big card,
  // negative is to its left. The panel's own binding keeps this current.
  property int rel: 0
  // A removal is in flight for this file: the tile stays in place but fades.
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
  // No border, selected or otherwise: the footer names the applied wallpaper
  // in accent, so marking the picture as well would be a second answer to the
  // same question, and a border that only shows up mid-glide reads as a flicker.
  clip: true
  // A removal in flight fades the whole tile. A revealed disabled wallpaper is
  // dimmed by a pane over its picture instead (see `frame`), so its badge and
  // its frame stay fully opaque.
  opacity: tile.pending ? 0.35 : 1

  // The cell places and animates the deck; the tile only fades for its own
  // state changes (a removal in flight). Same clock and curve as the rest of
  // the shell, off with the global switch.
  Behavior on opacity {
    enabled: MotionPolicy.enabled
    Glide { duration: Ui.fastMs }
  }

  readonly property string path: tile.file !== ""
    ? SU.joinPath(tile.dir !== "" ? tile.dir : WallpaperPicker.backgroundsDir, tile.file)
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
      // The decoded picture arrives over the card's flat placeholder on the
      // shared short clock. The overlay still owns the entrance; this only
      // softens the moment a cached or freshly decoded image replaces the
      // fill, so no tile snaps from one frame to the next. With motion off the
      // Behavior is disabled and the picture lands immediately.
      opacity: status === Image.Ready ? 1 : 0
      Behavior on opacity {
        enabled: MotionPolicy.enabled
        Glide { duration: Ui.normalMs }
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

    // A revealed disabled wallpaper is dimmed over the picture, not by the
    // tile's own opacity: the badge and the frame announce a state, and a
    // transparent tile would make them read as disabled too. It sits under the
    // badge and over the neighbour veil, so a hidden slice is dimmed twice -
    // once for being off the selection, once for being hidden.
    //
    // The veil is black rather than a palette tint, which is what the deck uses
    // for its neighbours: `background_0` is a near-white cream on the light
    // themes, and tinting a picture with it brightens the tile instead of
    // dimming it. A scrim has one meaning on every palette.
    Rectangle {
      anchors.fill: parent
      radius: RoundingPolicy.radius
      color: Qt.rgba(0, 0, 0, 0.45)
      opacity: tile.disabled ? 1 : 0

      Behavior on opacity {
        enabled: MotionPolicy.enabled
        Glide { duration: Ui.fastMs }
      }
    }

    // The disabled marker, on top of the picture rather than beside it: a
    // revealed hidden wallpaper has to read as not offered by the theme at a
    // glance, and Enter is what puts it back.
    Rectangle {
      visible: tile.disabled

      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Ui.s
      implicitWidth: badgeLabel.implicitWidth + Ui.s * 2
      implicitHeight: Math.round(Ui.fontS * 2)
      radius: Math.round(implicitHeight / 2)
      color: Ui.tint("background_0", 0.78)
      border.width: 1
      border.color: Ui.tint("foreground_1", 0.35)

      Text {
        id: badgeLabel

        anchors.centerIn: parent
        text: "Hidden"
        color: Ui.solid("foreground_0")
        font.pixelSize: Ui.fontS
        font.family: Ui.fontFamily
      }
    }

    // The armed removal: a red pane rises from the bottom of the picture with the
    // trash glyph centered, so the destructive step is aimed at the image it will
    // remove rather than at a line of text elsewhere on the surface.
    Rectangle {

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

}
