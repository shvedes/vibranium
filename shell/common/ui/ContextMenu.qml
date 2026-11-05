pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Widgets
import qs.common

// One shared context menu: the card, the rows and the pointer behaviour that
// every right-click menu in the tree uses - the wallpaper's, the image
// viewer's and the tray's DBusMenu. It exists because those three had grown
// three copies of the same card with three slightly different rhythms; the
// rows, their height, the space between them and the card's padding are now
// one implementation, so a menu cannot look like a stranger to the others.
//
// The type is layout only: it knows nothing about what a row DOES. A caller
// maps whatever it has (a wallpaper action, a viewer action, a DBusMenu entry)
// into the record shape below and handles `activated(entry)`, so the menu is
// usable for a static list and for a remote menu without growing two modes.
//
//   { label: "...",              // the row's text
//     icon: "image",             // themed icon name (optional)
//     iconSource: "file://...",  // image URL instead of a themed name (optional)
//     enabled: false,            // dimmed, blocked cursor, click refused (default: true)
//     separator: true,           // a 1px divider instead of a row (default: false)
//     indicator: "check",        // "check" | "radio" | "" - a leading indicator column
//     checked: true,             // fills the indicator
//     partial: true,             // a dash instead of a check (check indicators)
//     hasChildren: true,         // trailing chevron
//     payload: <anything> }      // handed back untouched through `activated`
//
// Scrolling: `maxHeight` caps the visible rows (0 = the whole list). A menu
// that can outgrow the screen - the tray's, whose remote entries are the
// application's business - sets it and gets a flickable; the rest do not and
// pay nothing for it.
Card {
  id: root

  // Rows, in the order they draw. See the record shape above.
  property var entries: []

  // The shared compact rhythm. The row height leaves a 12px label and a 16px
  // glyph a little air above and below, and the gap keeps one row's hover fill
  // off its neighbour's edge.
  property int rowHeight: Ui.menuRowH
  property int rowGap: Ui.menuRowGap
  // Inset from the card's edge to the rows, and from the card's edge to the
  // row's own content.
  property int padding: Ui.menuPad
  property int rowPadding: Ui.m

  // Rows taller than this are scrolled (0 = no cap).
  property int maxHeight: 0

  // The visible scroll offset. Writable so a caller that swaps the whole list
  // - the tray's submenu stack - can put the new level back at the top.
  property alias contentY: flick.contentY

  // A row was clicked. `entry` is the record it came from, untouched, so the
  // caller dispatches on its own field rather than on an index that a re-mapped
  // list can invalidate between the click and the handler.
  signal activated(var entry)

  // The rows' own size. Width follows the widest row and height the sum, so a
  // caller that does not set a size gets a card that fits its content - and one
  // that does set a width still gets the rows stretched to fill it.
  readonly property int contentWidth: menuCol.implicitWidth
  readonly property int contentHeight: menuCol.implicitHeight
  readonly property int shownHeight: root.maxHeight > 0
    ? Math.min(root.contentHeight, root.maxHeight) : root.contentHeight

  implicitWidth: root.contentWidth + 2 * root.padding
  implicitHeight: root.shownHeight + 2 * root.padding
  width: implicitWidth
  height: implicitHeight

  Flickable {
    id: flick

    anchors.fill: parent
    anchors.margins: root.padding
    contentWidth: width
    contentHeight: menuCol.implicitHeight
    boundsBehavior: Flickable.StopAtBounds
    clip: true
    // A capped list drags; an uncapped one is exactly as tall as its rows, so
    // there is nothing to drag and the pointer belongs to the rows.
    interactive: root.maxHeight > 0 && root.contentHeight > root.shownHeight

    Column {
      id: menuCol

      width: flick.width
      spacing: root.rowGap

      Repeater {
        model: root.entries

        delegate: Item {
          id: entryRow

          required property var modelData

          readonly property bool isSeparator: modelData.separator === true
          readonly property bool rowEnabled: modelData.enabled !== false
          readonly property string iconName: String(modelData.icon ?? "")
          readonly property string iconSource: String(modelData.iconSource ?? "")
          readonly property bool hasIcon: entryRow.iconName !== "" || entryRow.iconSource !== ""
          readonly property string indicator: String(modelData.indicator ?? "")
          readonly property bool checked: modelData.checked === true
          readonly property bool partial: modelData.partial === true
          readonly property bool hasChildren: modelData.hasChildren === true

          implicitWidth: entryContent.implicitWidth + 2 * root.rowPadding
          // At least as wide as its own content, and as wide as the column
          // when a caller stretches the card. The max() is what keeps this
          // off a binding loop: a row may grow to the column, never shrink to
          // it, so the column's implicit width stays the widest row's
          // intrinsic width and the card sizes from that. A plain
          // `width: menuCol.width` closes the circle (card width <- column
          // implicit width <- row width <- card width) and Qt breaks it by
          // leaving the list 0x0 - a card with no rows in it.
          width: Math.max(entryRow.implicitWidth, menuCol.width)
          height: entryRow.isSeparator ? 1 : root.rowHeight

          // A divider is not a row: it takes no hover fill, no cursor and no
          // click, and drawing it at one pixel keeps a long menu's groups from
          // reading as gaps in a list.
          Rectangle {
            anchors.fill: parent
            visible: entryRow.isSeparator
            color: Ui.solid("background_3")
            opacity: 0.7
          }

          Rectangle {
            anchors.fill: parent
            visible: !entryRow.isSeparator
            color: Ui.tint("foreground_0", 0.07)
            opacity: rowMa.containsMouse && entryRow.rowEnabled ? 1 : 0
          }

          // One row of content: optional indicator, optional icon, label,
          // optional chevron. The optional columns are hidden rather than
          // zero-width, because a positioner skips hidden items - a zero-width
          // column would still take its share of the spacing.
          Row {
            id: entryContent

            visible: !entryRow.isSeparator
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: root.rowPadding
            anchors.rightMargin: root.rowPadding
            anchors.verticalCenter: parent.verticalCenter
            spacing: 9
            // Dimming rides the whole row, so the glyph and the label stay one
            // weight instead of the icon reading brighter than its word.
            opacity: entryRow.rowEnabled ? 1 : Ui.disabledOpacity

            // Indicator column (check / radio).
            Item {
              visible: entryRow.indicator !== ""
              width: 16
              height: 16

              Rectangle {
                anchors.centerIn: parent
                visible: entryRow.indicator === "radio"
                width: 12
                height: 12
                radius: RoundingPolicy.radius
                color: "transparent"
                border.width: 1
                border.color: Ui.solid("foreground_0")
                opacity: entryRow.checked ? 1 : 0.7
              }

              Rectangle {
                anchors.centerIn: parent
                visible: entryRow.indicator === "radio" && entryRow.checked
                width: 6
                height: 6
                radius: RoundingPolicy.radius
                color: Ui.solid("foreground_0")
              }

              Rectangle {
                anchors.centerIn: parent
                visible: entryRow.indicator === "check"
                width: 12
                height: 12
                radius: RoundingPolicy.radius
                color: "transparent"
                border.width: 1
                border.color: Ui.solid("foreground_0")
                opacity: 0.7
              }

              Title {
                level: 5
                anchors.centerIn: parent
                visible: entryRow.indicator === "check" && entryRow.checked
                text: entryRow.partial ? "–" : "✓"
                color: Ui.solid("foreground_0")
              }
            }

            // Icon column: a themed glyph, or the image URL a remote menu
            // hands over.
            Item {
              visible: entryRow.hasIcon
              width: 16
              height: 16

              Icon {
                anchors.centerIn: parent
                visible: entryRow.iconName !== ""
                name: entryRow.iconName
                size: 16
              }

              IconImage {
                anchors.centerIn: parent
                visible: entryRow.iconSource !== ""
                width: 16
                height: 16
                asynchronous: true
                // A DBusMenu icon is an Image.source-ready URL (theme-resolved
                // or embedded png data), so it needs no themed-name lookup.
                source: entryRow.iconSource
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: String(entryRow.modelData.label ?? "")
              color: Ui.solid("foreground_0")
              font.pixelSize: 12
              font.family: Ui.fontFamily
            }

            // Submenu chevron.
            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: entryRow.hasChildren
              text: "›"
              color: Ui.solid("foreground_0")
              opacity: 0.6
              font.pixelSize: 12
              font.family: Ui.fontFamily
            }
          }

          MouseArea {
            id: rowMa

            anchors.fill: parent
            hoverEnabled: true
            // A dimmed row still answers the pointer, so the cursor can say
            // why: the blocked cursor over a row that would do nothing reads
            // as "not available" rather than as a dead click. A divider gets
            // the plain arrow, since it is neither.
            cursorShape: entryRow.isSeparator ? Qt.ArrowCursor
              : (entryRow.rowEnabled ? Qt.PointingHandCursor : Qt.ForbiddenCursor)
            onClicked: {
              if (entryRow.isSeparator || !entryRow.rowEnabled) return
              root.activated(entryRow.modelData)
            }
          }
        }
      }
    }
  }
}
