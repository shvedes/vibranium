pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import qs.features.menu
import "MenuLib.js" as MenuLib
import "../../common/math/Range.js" as Range

// One child entry inside a group row's inline dropdown: the compact form of the
// entries the group collects. A child is an ordinary menu row that happens to
// live under another row: it asks RowGeometry the same questions Entry asks,
// lays its text column out the same way, and centres its toggle on that column.
// Only the register is smaller (fontM and childIconW instead of fontL and
// rowIconW).
//
// A toggle is flipped in place by the group cursor (Entry) or by a click here;
// a row of another type renders as reference copy until the group grows a view
// for it. A child's ctrl+i copy is an overlay in its own slot: it never resizes
// the card, and the rows around it move inside the group's clipped box instead.
//
// The widget is state-externalized like OptionRow: `checked` is bound by the
// owner and every activation reports back through picked(), so the store write
// that makes the state real stays in one place.
Rectangle {
  id: child

  required property var modelData
  required property int index

  // Group cursor position and the stored toggle state, owned by the row.
  property bool cursor: false
  property bool checked: false
  // Rows below a focused child slide down inside the clipped dropdown while
  // that child's ctrl+i description is open. A transform, not y: the Column
  // owns y and would overwrite it.
  // slideY tracks the bar's own frame directly: the slot is the one animation,
  // so a Behavior here would re-ease the same value a frame late.
  property real slideY: 0
  transform: Translate { y: child.slideY }
  readonly property string label: child.modelData && child.modelData.label !== undefined
    ? String(child.modelData.label) : ""
  readonly property string iconName: child.modelData && typeof child.modelData.icon === "string"
    ? String(child.modelData.icon) : ""
  readonly property string subText: child.modelData && typeof child.modelData.sub === "string"
    ? String(child.modelData.sub) : ""
  readonly property bool isToggle: !!child.modelData && child.modelData.type === "toggle"
  // The child's title register is fontM; its sub line is the shared fontXs
  // register. RowGeometry tokensFor builds the rest of the token set, so the
  // same rule that sizes a top-level row sizes this one at the smaller line.
  readonly property real labelLineH: Math.ceil(labelMetrics.height)
  readonly property real subLineH: RowGeometry.subHFor(child.subText)
  readonly property string kind: MenuLib.restKind(child.modelData, child.subText)
  readonly property real colH: RowGeometry.colHFor(child.kind, child.labelLineH, child.subLineH)
  readonly property real restH: RowGeometry.restHFor(child.kind, child.labelLineH, child.subLineH)
  // The child's own ctrl+i copy, in its own DropdownSlot - the same primitive
  // Entry uses, one level down. The slot is an overlay, excluded from this
  // row's layout height: a nested desc never resizes the card.
  readonly property string descText: child.modelData && typeof child.modelData.desc === "string"
    ? String(child.modelData.desc) : ""
  readonly property string warnText: child.modelData && typeof child.modelData.warning === "string"
    ? String(child.modelData.warning) : ""
  readonly property bool hasInfo: child.descText !== "" || child.warnText !== ""
  readonly property bool infoOpen: child.modelData
    ? Menu.stateOf(child.modelData).info === true : false
  // The continuous selection background runs from the row's top to the bottom
  // of its nested slot. The slot's top gap is inside its own height, so a
  // closed slot leaves this exactly at the row's rest height.
  readonly property real barH: Math.max(restH, infoSlot.y + infoSlot.height)
  // Destination bar height, constant for the whole unfold. The group decides
  // top-vs-bottom push from settledExtra, while the bar, the reveal and the
  // push magnitudes all read the live barH - one clock for every motion.
  readonly property real settledBarH: Math.max(restH, infoSlot.y + infoSlot.settledH)
  readonly property real settledExtra: Math.max(0, settledBarH - restH)
  // What barH is heading for, from the copy's own measured height. Stable for
  // the whole unfold, so the reveal fraction is the bar's growth over a fixed
  // span rather than over the slot's still-animating height.
  readonly property real _revealTargetExtra: Math.max(0,
    infoSlot.topGap + copyCol.implicitHeight + infoSlot.gap - Ui.rowPadV)

  FontMetrics {
    id: labelMetrics

    font.pixelSize: Ui.fontM
    font.family: Ui.fontFamily
  }

  signal picked()

  width: parent.width
  height: child.restH
  radius: RoundingPolicy.radius
  // Always transparent: the group's sliding cursor bar paints the selection
  // behind the rows, exactly as the select dropdown does.
  color: "transparent"

  // --- main line: icon | label (sub line) | toggle ---
  // Same inset, same pinned line stack and same toggle anchor as Entry's
  // mainLine. Ui.rowPadV above plus the shared rest height below gives the row
  // one padding token on both sides instead of a locally chosen number.
  Item {
    id: mainLine

    visible: child.label !== "" || child.subText !== ""
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: Ui.m
    anchors.rightMargin: Ui.m
    anchors.topMargin: Ui.rowPadV
    height: child.colH

    MouseArea {
      anchors.fill: parent
      cursorShape: child.isToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: child.picked()
    }

    Icon {
      id: glyph

      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      visible: child.iconName !== ""
      size: Ui.childIconW
      name: child.iconName
      colorKey: "foreground_0"
    }

    Column {
      id: labelCol

      anchors.left: glyph.visible ? glyph.right : parent.left
      anchors.leftMargin: glyph.visible ? Ui.s : 0
      anchors.right: togglePill.visible ? togglePill.left : parent.right
      anchors.rightMargin: Ui.s
      anchors.verticalCenter: parent.verticalCenter
      spacing: 1

      Text {
        id: labelText

        width: Math.min(implicitWidth, parent.width)
        text: child.label
        // The cursor is the hint this widget owns (the group paints its bar
        // behind the row); the stored state belongs to the pill.
        color: child.cursor ? Theme.color("foreground_0")
          : Ui.tint("foreground_1", 0.85)
        font.pixelSize: Ui.fontM
        font.family: Ui.fontFamily
        elide: Text.ElideRight
        textFormat: Text.PlainText

        Behavior on color {
          enabled: MotionPolicy.enabled
          ColorAnim {}
        }
      }

      Text {
        id: subLine

        width: Math.min(implicitWidth, parent.width)
        height: child.subLineH
        visible: child.subText !== ""
        text: child.subText === "" ? "" : MenuLib.styledMarkup(child.subText)
        color: Ui.tint("foreground_1", 0.55)
        font.pixelSize: Ui.fontXs
        font.family: Ui.fontFamily
        elide: Text.ElideRight
        textFormat: Text.StyledText
      }
    }

    Toggle {
      id: togglePill

      anchors.right: parent.right
      // The same anchor as a top-level entry's toggle: centred on the text
      // column, not on the row's padding or on its first line.
      anchors.verticalCenter: parent.verticalCenter
      visible: child.isToggle
      checked: child.checked
      animationsEnabled: MotionPolicy.enabled
      onToggled: child.picked()
    }
  }

  DropdownSlot {
    id: infoSlot

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: mainLine.bottom
    // The gap above the copy rides inside the slot's height tween, so the
    // selection bar can follow one number all the way down.
    topGap: Ui.m
    open: child.hasInfo && child.infoOpen
    // The slot is an overlay painted above the following children; their own
    // slide is driven by groupComp from liveExtra.
    z: 1
    // The selection bar is the single reveal clock. The slot's own fade would
    // stack a second, shorter tween on the copy and let it arrive first.
    opacity: 1

    Column {
      id: copyCol

      x: Ui.m
      width: parent.width - 2 * Ui.m
      spacing: Ui.m
      // Track the bar's growth over a fixed span: the copy and the background
      // reach full and zero on the same frame, in both directions.
      opacity: Range.clamp01((child.barH - child.restH) / Math.max(1, child._revealTargetExtra))

      Divider {
        width: parent.width
        color: Ui.tint("background_3", 0.8)
      }

      BodyText {
        width: parent.width
        visible: child.descText !== ""
        markup: true
        text: (infoSlot.open || infoSlot.closing)
          ? MenuLib.styledMarkup(child.descText) : ""
      }

      Notice {
        width: parent.width
        visible: child.warnText !== ""
        markup: true
        message: (infoSlot.open || infoSlot.closing)
          ? MenuLib.styledMarkup(child.warnText) : ""
      }
    }
  }
}
