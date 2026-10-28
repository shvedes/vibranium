pragma ComponentBehavior: Bound

import QtQml
import QtQuick
import Quickshell.Services.Notifications
import qs.common
import qs.features.notifications
import "NotificationsLib.js" as NotificationsLib
import "../../common/text/StringUtils.js" as SU

// One notification, as a card. Everything drawn here is read off the entry's
// plain-value snapshot rather than off the Notification itself, and that is not
// a style choice: the Notification is destroyed the moment `closed` returns,
// while this card is still on screen for its exit fade. Reading the object
// directly would mean reading freed memory for the length of a fade.
//
// The entry is the row, because a row is a notification and the pile's array
// holds nothing else. The entry is also what the card names rather than
// dereferences: an action button calls `entry.invokeAction(identifier)`,
// which the entry resolves against its own live pointer.
//
// Layout, from the requirement:
//
//   | appicon > app <spacing> <time> |
//   | <title>                        |
//   | <body>                 <provided_icon> |
//   | <buttons>                              |
//
// The artwork is taller than a one-line body, and it hangs below the body's
// own line rather than deciding the body's height: the buttons sit a gap
// under the text, and the artwork fills the space to their right.
Rectangle {
  id: root

  // The row, as the Repeater hands it over. `modelData` rather than the role's
  // own name: naming the field `entry` and declaring it `required` does NOT
  // receive a ListModel role inserted as a live object on this build
  // (measured - "Required property entry was not initialized", no delegate),
  // while `modelData` does. `entry` is the derived name for it.
  required property var modelData

  readonly property var entry: root.modelData

  // A complete empty snapshot, so every read below is a read of a field that
  // exists. A half-built `{}` makes each of those bindings evaluate to
  // `undefined` for the frames before `modelData` resolves, and an
  // `undefined` on a typed property is a warning per property rather than one
  // about the real cause.
  readonly property var _emptyShot: ({
    id: 0,
    summary: "",
    body: "",
    appName: "",
    appIcon: "",
    desktopEntry: "",
    image: "",
    clock: "",
    progress: -1,
    vol: -1,
    volMuted: false,
    hideMeta: false,
    iconColor: "",
    urgency: -1,
    actions: []
  })
  readonly property var shot: (root.entry ? root.entry.snapshot : null) || root._emptyShot

  // The meta line, resolved once per snapshot rather than by two separate reads of
  // the clock and the sender. One string, always present, so a frame before
  // `shot` resolves reads "" rather than `undefined`.
  readonly property string meta: NotificationsLib.metaLine(root.shot.clock, root.shot.appName)

  // The link under the pointer, "" when the pointer is on none of them.
  //
  // The body text's handler fills this in as the pointer moves: it knows
  // where the pointer is, and the text knows which anchor a position falls
  // in. A plain item is not sent hover events in Qt 6 - `Item.hoverEnabled`
  // is gone from the QML API - so the text's own `hoveredLink` never moves
  // and cannot be the answer.
  property string hoveredLink: ""

  // The body as it is drawn: the sender's markup with the shell's link
  // treatment on it - the anchors in the theme's accent colour and without
  // an underline of their own, and the one under the pointer underlined.
  readonly property string bodyMarkup: SU.linkMarkup(
    String(root.shot.body), root.linkColor, root.hoveredLink)

  // The colour the body's links are painted in.
  //
  // The theme's accent rather than the palette's link colour: the shell is
  // themed, and a link a theme switch does not reach is a link that keeps
  // the wrong colour across one. The accent is also what says "this does
  // something" everywhere else in the shell, and with the underline gone
  // until the pointer arrives, the colour is what says it is a link at all.
  readonly property string linkColor: String(Ui.solid("accent"))

  // Urgency, read off the snapshot rather than off the live Notification.
  //
  // The card is still on screen for its exit fade after the Notification is
  // destroyed, and a live read answers "not urgent" for the length of that
  // fade - so the card would lose its urgent face exactly as it left. The
  // snapshot is a plain value, and it outlives the object it was copied from.
  readonly property bool urgent: root.shot.urgency === NotificationUrgency.Critical

  // The card's own surface. An urgent card is the theme's background shifted
  // toward the theme's red - five percent of it - so the urgency is on the
  // card's face and not only on its border, and the shift is the theme's own
  // red rather than a color chosen here.
  //
  // Five percent, and not more, because this is the card's SURFACE: the text
  // on it has to stay readable and the card has to stay a card. At a third
  // the surface stopped being the theme's background tinted by a red and
  // became a red panel, which is a louder thing than a notification should
  // be. The crisp signal is the border, which is already the theme's red;
  // this is the warmth under it.
  readonly property real urgentMix: 0.06
  readonly property color fill: root.urgent
    ? Ui.mix("background_0", "red", root.urgentMix)
    : Ui.solid("background_0")

  // 2px accent border, lifted on hover. Urgent is red rather than accent, so
  // urgency stays legible without reading the text.
  readonly property color baseBorder: root.urgent
    ? Theme.color("red") : Theme.color("accent")

  // Padding, one step below the panel's Ui.m: a card is read at a glance and
  // re-read often, so the air that suits a panel costs a notification a whole
  // line of body. 10 rather than Ui.s because Ui.s (8) put the body flush
  // against the border on a 2px edge.
  readonly property int padV: 10
  readonly property int padH: 10
  readonly property int iconSize: 20
  // The thumbnail a sender provides (`shot.image`), painted on the right of
  // the body in the macOS-style layout. Larger than the app icon above, since
  // it is artwork rather than identity.
  readonly property int providedIconSize: 40
  // The gap between the card's own blocks (title, meta line, body, buttons). One
  // property so the card tightens as a whole: at Ui.s the four gaps were 32px of
  // the card's height for content that is one line each.
  readonly property int gap: 6

  // Whether the artwork reaches into the band the action buttons sit in.
  //
  // The artwork hangs below the body's row, and the buttons start a gap below
  // that row: an artwork taller than the body text and that gap ends up
  // beside the buttons as well. The buttons then stop at the artwork's left
  // edge instead of running under it.
  readonly property bool artworkBesideButtons:
    providedIcon.height > bodyRow.height + root.gap

  // How tall the body's row is.
  //
  // The artwork is taller than a one-line body, and letting it decide the
  // row's height pushed the action buttons a whole artwork down the card: a
  // 30px gap between a line of text and the buttons under it, where every
  // other gap on the card is 6px.
  //
  // With buttons under it, the row is as tall as the body text and the
  // artwork hangs beside the buttons, which the card's height makes room
  // for. Without buttons there is nothing for the artwork to hang beside -
  // the volume lane or the progress bar is under the body then, and the
  // artwork would hang into those - so the row is as tall as the taller of
  // the two, and the artwork stands in its own band as it did.
  readonly property int bodyRowHeight: {
    if (!bodyText.visible) return providedIcon.height
    if (root.shot.actions.length > 1) return bodyText.height
    return Math.max(bodyText.height, providedIcon.height)
  }

  color: root.fill
  border.width: 2
  // Corners follow RoundingPolicy (hypr.decoration.rounding): the card
  // inherits the shell's own decoration rounding, so it never disagrees
  // with it. The pile is a stack of rectangles and the corners are where
  // two adjacent cards read as separate.
  radius: RoundingPolicy.radius
  clip: true
  width: parent.width
  // The height is the content's, and it is set rather than left implicit
  // because nothing lays this card out any more: a Column would, and the
  // Column is what cannot carry the slide (see _place). Notifications.yOf
  // reads cardHeight back off the entry to place the cards below. The
  // eight-line body cap is what stops a corner pile growing to screen height.
  implicitHeight: body.implicitHeight + 2 * root.padV
  height: root.implicitHeight

  // Lifted on hover, from the CARD's own hover rather than a MouseArea's.
  //
  // `HoverHandler` rather than `MouseArea.containsMouse`: the content column is
  // a sibling ABOVE any MouseArea placed here, and it covers the card edge to
  // edge - every one of its Text items is a hover target of its own. A
  // MouseArea underneath them therefore only saw the pointer in the gaps
  // between the text runs, which is why the border lifted when the cursor was
  // over the padding or the border itself and not when it was over the title.
  // A HoverHandler on the card is what receives hover for the whole item,
  // including over its children, so the lift is the whole card.
  border.color: hover.hovered ? Qt.lighter(root.baseBorder, 1.5) : root.baseBorder

  Behavior on border.color {
    enabled: Notifications.animationsEnabled
    ColorAnim {}
  }

  // The slide. Two measured facts about this build (Quickshell 0.3.1 / Qt
  // 6.11.2) decide its shape, and both are the reason it is not written the
  // obvious way:
  //
  //   - a Column assigns its children's y itself, and a Behavior never sees
  //     that assignment. A Column whose middle child collapsed moved the cards
  //     below from y=48 to y=24 in one frame, while the same property driven
  //     by a binding tweened 24 -> 33.8 -> 40.8 -> 44.0 over the same
  //     interval. So this card is not laid out by a Column; Notifications.yOf
  //     gives the target and the card's y is a binding, which the Behavior can
  //     see. See NotificationsView for why the pile is an Item.
  //
  //   - a Repeater over a plain JS array recreates every delegate whenever the
  //     array changes, and a recreated delegate starts AT its bound value,
  //     which is a slide with no distance. The pile is therefore repeated over
  //     a row-wise model (NotificationsView.rows), whose surviving rows keep
  //     their delegates - measured, an array-backed Repeater went from
  //     serials 32,33,34,35,31 to 43,44,45,42 across one dismissal while a
  //     ListModel-backed one kept 11,15,13,12.
  //
  // `Notifications.yOf` sums the card heights above this one, which is why
  // this card publishes its own below: a card's height is its content - the
  // six-line body cap, the buttons - and nothing else knows it.
  //
  // Two placements, and the difference is the bottom dock. At the top dock
  // `yOf` is the answer on its own: the box's y is the constant `topInset`, so a
  // newcomer is already in its final place and the pile grows downward from a
  // fixed edge. At the bottom dock the pile is anchored by its bottom edge, so
  // the box's y climbs a slot per arrival while its height catches up over the
  // slide, and a card placed by `yOf` in that window is laid out against the
  // box's old top - a full card height below the bar, off the bottom of the
  // screen, until the box carries it up. Measured at the bottom dock: a
  // newcomer at 392..446 against a bar edge of 386 and a screen ending at 426,
  // for six frames.
  //
  // An arriving card is therefore placed against the box's CURRENT height
  // rather than its final one: `yOf` plus how much the box has still to grow.
  // That cancels the box's own motion exactly, so the card holds the bar edge
  // from its first frame and the cards above it do the sliding.
  //
  // `parent.height` rather than a height passed in: this card is the box's
  // delegate, the box is its parent, and `width: parent.width` above already
  // reads it the same way. The `growing` half is what keeps the answer honest
  // afterwards - once the box has caught up the two placements are the same
  // number, and `arriving` alone is a stale claim that must not move a card
  // that is merely re-measuring.
  readonly property bool arriving: Notifications.isArriving(root.entry)
  readonly property bool growing: parent.height < Notifications.pileHeight() - 0.5

  y: root.arriving && root.growing
    ? Notifications.yOf(root.entry) + parent.height - Notifications.pileHeight()
    : Notifications.yOf(root.entry)

  // Not tweened while it is being placed against a moving box: the slide
  // already IS the box's, and a tween here would chase a target that is itself
  // animating - a card that opened a gap to the bar edge and then closed it.
  Behavior on y { enabled: !(root.arriving && root.growing) && Notifications.animationsEnabled; Glide {} }

  // The height this card publishes to the pile. A freshly constructed delegate
  // measures a few pixels short for one frame - the body has not wrapped - and
  // the pile corrects that by a few pixels over the next one, through the same
  // slide every other reflow uses.
  onHeightChanged: {
    // -> Single write-back so the pile geometry cache stays in step.
    if (root.entry) Notifications.noteCardHeight(root.entry, root.height)
  }

  // Fade in on admission and out on release. The controller keeps a released
  // entry in the pile until this has landed, so the slide above has a gap to
  // slide into and the window stays mapped until the last card has gone.
  opacity: root.entry ? (root.entry.leaving ? 0 : 1) : 1

  Behavior on opacity {
    enabled: Notifications.animationsEnabled
    // -> Shared exit token so the fade cannot desync the controller drop.
    NumberAnimation { duration: Notifications.exitMs; easing.type: Easing.OutCubic }
  }

  // Hover is a HoverHandler on the card itself (see border.color), and the two
  // gestures stay a MouseArea beneath the content so the action buttons and the
  // reply field still take their own clicks.
  HoverHandler {
    id: hover
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: mouse => {
      // Left first: activateSender's own contract is that it is called BEFORE
      // anything else for this notification, because a sender that answers by
      // mapping a new window takes focus itself and a request that landed
      // afterwards would pull focus back off it.
      if (mouse.button === Qt.RightButton) {
        Notifications.dismiss(root.entry ? root.entry.notifId : -1)
        return
      }
      // A lone action draws no button (see the actions loader below), so the
      // body click is the only way to reach it - and the one the sender
      // meant: a single action is the default activation. Falls back to
      // focusing the sender when the entry is already gone.
      const acts = root.shot.actions ? root.shot.actions : []
      if (acts.length === 1 && root.entry
        && root.entry.invokeAction(String(acts[0].identifier))) return
      // The snapshot carries appName, appIcon and desktopEntry, which is the
      // whole of what the matcher reads - so the card never has to hold the
      // live notification to identify its sender.
      WindowFocus.activateSender(root.shot)
    }
  }

  // The volume lane's percent reserve: a full three digits, so the lane
  // beside it does not move as the level goes 9% -> 10% -> 100%. The
  // island's own percentColumn, same text, same font. Lives here rather
  // than in the body Column because a positioner would spend a spacing gap
  // on even a zero-size child.
  TextMetrics {
    id: volReserve

    font.family: Ui.fontFamily
    font.pixelSize: Ui.fontXs
    text: "100%"
  }

  Column {
    id: body

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: root.padH
    anchors.rightMargin: root.padH
    anchors.topMargin: root.padV
    spacing: root.gap

    // --- header: app icon, app name, time ---
    //
    // macOS-style top line: the sending app's identity on the left, the
    // arrival time on the right. The app icon is the app's own (never the
    // sender's artwork, which lives on the right of the body below), so a
    // notification carrying an image still names its sender up here.
    Row {
      width: parent.width
      spacing: root.gap
      visible: appIcon.visible || appName.visible || time.visible

      Image {
        id: appIcon

        anchors.verticalCenter: parent.verticalCenter
        source: root.appIconUrl
        asynchronous: true
        retainWhileLoading: true
        cache: true
        width: root.appIconUrl === "" ? 0 : root.iconSize
        height: width
        visible: width > 0
        fillMode: Image.PreserveAspectFit
        sourceSize.width: root.iconSize * 2
        sourceSize.height: root.iconSize * 2
      }

      Text {
        id: appName

        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, parent.width
          - (appIcon.visible ? appIcon.width + parent.spacing : 0)
          - (time.visible ? time.implicitWidth + parent.spacing : 0))
        text: String(root.shot.appName)
        color: Ui.tint("foreground_1", 0.7)
        font.family: Ui.fontFamily
        font.pixelSize: Ui.fontM
        font.bold: true
        elide: Text.ElideRight
        textFormat: Text.PlainText
        visible: text !== ""
      }

      Text {
        id: time

        anchors.verticalCenter: parent.verticalCenter
        visible: String(root.shot.clock) !== "" && !root.shot.hideMeta
        text: String(root.shot.clock)
        color: Ui.tint("foreground_1", 0.5)
        font.family: Ui.fontFamily
        font.pixelSize: Ui.fontM
        textFormat: Text.PlainText
        elide: Text.ElideRight
      }
    }

    // --- title ---
    Text {
      id: title

      width: parent.width
      text: String(root.shot.summary)
      color: Ui.solid("foreground_0")
      font.family: Ui.fontFamily
      font.pixelSize: Ui.fontCardTitle
      font.bold: true
      elide: Text.ElideRight
      textFormat: Text.PlainText
      visible: text !== ""
    }

    // --- body: text on the left, provided icon on the right, no gap ---
    Row {
      id: bodyRow

      width: parent.width
      spacing: 0
      visible: bodyText.visible || providedIcon.visible
      // The row is as tall as the body TEXT, not as tall as the artwork -
      // see bodyRowHeight for why, and for the one case where the artwork
      // still decides.
      height: root.bodyRowHeight

      Text {
        id: bodyText

        width: root.providedImageUrl !== ""
          ? Math.max(0, parent.width - providedIcon.width) : parent.width
        visible: String(root.shot.body) !== ""
        text: root.bodyMarkup
        textFormat: Text.RichText
        color: Ui.solid("foreground_1")
        font.family: Ui.fontFamily
        font.pixelSize: Ui.fontM
        wrapMode: Text.WordWrap
        maximumLineCount: 6
        elide: Text.ElideRight
        onLinkActivated: link => Qt.openUrlExternally(link)

        // The pointer over a link, and the link that says so.
        //
        // The handler, not the text's own `hoveredLink`: that property is
        // fed by hover events, and a plain item does not get them in Qt 6 -
        // `Item.hoverEnabled` is gone from the QML API, and a handler is
        // what receives the pointer now. The handler knows where the
        // pointer is, and the text knows which anchor a position falls in.
        HoverHandler {
          id: bodyHover

          // The pointer shape is the LINK's, not the body's: the shape
          // follows the link under the pointer, so the rest of the body
          // keeps the arrow it deserves.
          cursorShape: root.hoveredLink !== ""
            ? Qt.PointingHandCursor : Qt.ArrowCursor

          // The link under the pointer. The text is asked rather than told,
          // because Qt underlines every anchor by itself and its CSS has no
          // way to underline one anchor only - so the shell names the anchor
          // under the pointer and underlines that one itself.
          onPointChanged: {
            if (!hovered) return
            root.hoveredLink = bodyText.linkAt(point.position.x, point.position.y)
          }

          // Off the text, there is no link under the pointer.
          onHoveredChanged: {
            if (!hovered) root.hoveredLink = ""
          }
        }
      }

      Image {
        id: providedIcon

        visible: root.providedImageUrl !== ""
        source: root.providedImageUrl
        asynchronous: true
        retainWhileLoading: true
        cache: true
        width: visible ? root.providedIconSize : 0
        height: width
        fillMode: Image.PreserveAspectFit
        sourceSize.width: root.providedIconSize * 2
        sourceSize.height: root.providedIconSize * 2
      }
    }

    // --- action buttons (under the body) ---
    //
    // A flow in the column, not behind a loader. A loader with an explicit
    // size resizes the item it loaded and drops that item's own height
    // binding, so a band read off the loaded flow's children froze at
    // whatever the first layout produced - the flow lays out once at zero
    // width, before the card's width is known, and puts the buttons on a row
    // each - and the buttons sat in a band a third taller than they are.
    //
    // The flow's own height is the live one: it follows the flow's layout,
    // whatever width it has. An invisible child is skipped by the column,
    // spacing included, so a notification with no buttons spends nothing on
    // them.
    Flow {
      id: actionsFlow

      // The buttons stop at the artwork's left edge when the artwork hangs
      // beside them (see artworkBesideButtons), so a long action never runs
      // under the artwork.
      width: Math.max(0, parent.width
        - (root.artworkBesideButtons ? root.providedIconSize : 0))
      height: implicitHeight
      spacing: root.gap
      visible: root.shot.actions.length > 1

      Repeater {
        model: root.shot.actions

        delegate: Button {
          required property var modelData

          // An action arrives as a pair of strings, which is all the card
          // draws; the object it came from dies with the notification.
          label: String(modelData.text)
          variant: "outline"
          color: hovered ? Qt.lighter(Ui.solid("background_1"), 1.15) : Ui.solid("background_1")
          // Denser than the primitive's defaults, for the reason the card's
          // own padding is: an action sits on a 330px card among one-line
          // text, where Ui.l per side and a 28px control is more chrome
          // than the label. padH keeps the width label + 2 * padH.
          padH: Ui.s
          implicitHeight: 24
          animationsEnabled: Notifications.animationsEnabled
          visible: label !== ""
          onClicked: root.entry.invokeAction(String(modelData.identifier))
        }
      }
    }

    // --- the volume lane ---
    Row {
      width: parent.width
      spacing: root.gap
      visible: root.shot.vol >= 0

      Icon {
        id: volIcon

        anchors.verticalCenter: parent.verticalCenter
        name: NotificationsLib.volIconFor(root.shot.vol / 100, root.shot.volMuted)
        colorKey: "foreground_1"
        accentKey: (root.shot.volMuted || root.shot.vol / 100 <= 0.01) ? "red" : ""
        dimTiers: NotificationsLib.volDimTiersFor(root.shot.vol / 100, root.shot.volMuted)
        size: root.iconSize
      }

      ProgressBar {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, parent.width - volIcon.width - volPercent.width - 2 * parent.spacing)
        height: 6
        value: Math.max(0, root.shot.vol)
        dimWhenEmpty: false
        glideMs: Ui.fastMs
        animationsEnabled: Notifications.animationsEnabled
      }

      Text {
        id: volPercent

        anchors.verticalCenter: parent.verticalCenter
        width: Math.ceil(volReserve.advanceWidth)
        horizontalAlignment: Text.AlignRight
        text: Math.round(Math.max(0, root.shot.vol)) + "%"
        color: Ui.tint("foreground_1", 0.55)
        font.family: Ui.fontFamily
        font.pixelSize: Ui.fontXs
        textFormat: Text.PlainText
        elide: Text.ElideRight
      }
    }

    // --- the generic progress bar ---
    Row {
      width: parent.width
      spacing: root.gap
      visible: root.shot.progress >= 0 && root.shot.vol < 0

      ProgressBar {
        id: bar

        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, parent.width - progressLabel.width - parent.spacing)
        height: 6
        value: Math.max(0, root.shot.progress) * 100
        dimWhenEmpty: false
        glideMs: Ui.fastMs
        animationsEnabled: Notifications.animationsEnabled
      }

      Text {
        id: progressLabel

        anchors.verticalCenter: parent.verticalCenter
        text: Math.round(Math.max(0, root.shot.progress) * 100) + "%"
        color: Ui.tint("foreground_1", 0.5)
        font.family: Ui.fontFamily
        font.pixelSize: Ui.fontXs
        textFormat: Text.PlainText
      }
    }

  }

  // The app's own identity icon (never the sender's artwork, which is shown on
  // the right of the body). "" when nothing resolves.
  readonly property string appIconUrl: {
    const name = String(root.shot.appIcon)
    const tone = String(root.shot.iconColor ?? "")
    if (name !== "") return AppIcons.url(name, String(root.shot.appName), tone)
    return AppIcons.url(String(root.shot.appName), "", tone)
  }

  // The artwork a sender provides (`shot.image`), shown on the right of the
  // body. "" when the sender sent none.
  readonly property string providedImageUrl: {
    const image = String(root.shot.image)
    if (image === "") return ""
    return image.indexOf(":") > 0 ? image : "file://" + image
  }

  // `shot.iconColor` paints the appIcon leg only, and within that leg only the
  // glyph the shell ships itself: AppIcons threads the tone into Icons.url and
  // nowhere else, and a shipped asset is one Icons.recolor rewrites to a single
  // hex, so it has no color of its own to keep. `shot.image` is the sender's own
  // artwork and is never recolored, because repainting somebody else's icon in a
  // tone they did not choose is a different change from choosing a tone for ours.
}
