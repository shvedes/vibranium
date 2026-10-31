pragma ComponentBehavior: Bound

import QtQuick
// Aliased because this component is itself called IconButton and exports that
// name from qs.common: an unaliased import would make the bare name resolve
// back to the wrapper, which instantiates the wrapper with none of the native
// behavior and reports no error at all.
import QtQuick.Controls as Ctl
import qs.common

// Icon button with two content modes sharing one fixed outer slot,
// corners follow RoundingPolicy, so the hover/click target stays constant across what the button shows:
//
//   name / colorKey - an SVG from the shipped set, rendered by Icon.qml at
//                     the bar's optical canvas and rasterized at device
//                     pixel ratio (crisp at every screen scale).
//   glyph           - a text glyph for dense chrome (menu steppers, micro
//                     actions in boxes), sized to the XS font.
//
// Icon mode sizes the slot from the bar tokens (Ui.barIconSlot /
// Ui.barIconCanvas) so the whole bar grows coherently with the font when
// Ui.barScaleWithFont is on; glyph mode keeps a fixed 16px micro-button.
// `iconSize` overrides the glyph paint size inside a custom
// slot; `faint` gives the slot a whisper of fill. Hover washes the fill
// and tightens the border, press tints both with the accent; disabled
// states fade. `forceHover` pins the hovered look on without a cursor
// (armed two-press confirms).
//
// The native button owns the interaction: press and hover state, the enabled
// gate, focus, and keyboard activation. This wrapper owns the shell's side of
// it - the two content modes, the slot tokens, the hover/press fills, the
// tooltip bubble, the press scale, the animation kill switch, and the split
// between the hard `enabled` lock and the soft `actionable` gate.
Item {
  id: root

  property string name: ""
  property string colorKey: "foreground_0"
  property string accentKey: ""
  property int dimTiers: 0
  property string glyph: ""
  property bool bright: false
  // Faint neutral fill instead of transparent ground: reads as a button,
  // not a bare rectangle outline. Opt-in so dense chrome stays flat.
  property bool faint: false
  // Bespoke glyph size for the embedded Icon (0 = the bar tokens). Lets a
  // resized slot keep generous internal gaps instead of a scaled-up glyph.
  property real iconSize: 0
  property real iconOpacity: 1
  // Pad variant (opt-in island pads, the Now Playing controls): bespoke
  // outer slot (0 = the token sizes below), rounded corners, no border.
  // Defaults keep every existing consumer pixel-identical.
  property real slotSize: 0
  property real cornerRadius: RoundingPolicy.radius
  property bool flat: false
  // Kill switch: disables color/border/scale tweens; the final state
  // still lands instantly. Follows the Button lib contract.
  property bool animationsEnabled: true
  // Two gates, and the split is the point. `enabled` is the hard lock: it
  // drops the whole subtree out of the hit-test chain, which also means a
  // disabled button can no longer set a cursor. `actionable` is the soft
  // gate - the button stays in the chain so an inert one can still show
  // the forbidden cursor and still clears its own hover chrome, and a
  // consumer's own `cursorShape` (a HoverHandler over this item) reaches
  // the user. The guard on `live` is what makes the button inert. Same
  // split the annotator's ToolBtn uses.
  property bool actionable: true
  readonly property bool live: root.enabled && root.actionable
  // Hover hint, opt-in: a small bubble above the button while the cursor
  // rests on it (island icon-only buttons). Empty (default) disables it
  // entirely - no hover tracking, no bubble, no behavior change for
  // existing consumers.
  property string tipText: ""
  // Force the hovered look without a cursor (two-press confirms show
  // their armed state this way). Never triggers the hover bubble.
  property bool forceHover: false

  readonly property bool iconMode: root.name !== ""

  // The ground. Declared here rather than read off the native control's
  // background so a consumer that assigns `color:` (the history rows do)
  // still replaces the shell's fill.
  property color color: root.bright || root.pressed ? Ui.tint("accent", 0.15)
    : root.hovered ? Ui.tint("foreground_1", 0.12)
    : root.faint ? Ui.tint("foreground_1", 0.07) : "transparent"
  // A Rectangle's radius is the shell's own knob; on the wrapper it is just
  // another property, still bound to the corner radius every consumer
  // assigns, so both names keep working.
  property real radius: root.cornerRadius

  readonly property bool pressed: btn.pressed && root.live
  readonly property bool hovered: (btn.hovered || root.forceHover) && root.live
  readonly property bool _focused: btn.activeFocus

  signal clicked()

  // Icon mode: the embedded icon's neutral default slot. Glyph mode: a
  // fixed 16px micro-button (menu steppers keep their dense size).
  readonly property real targetSize: root.slotSize > 0 ? root.slotSize
    : root.iconMode ? icon.defaultSlotSize : 16

  width: root.targetSize
  height: root.targetSize
  enabled: true
  opacity: root.enabled ? 1 : 0.4

  // Press push (the Button lib contract): 0.97 while held, linear back.
  scale: root.pressed ? 0.97 : 1

  // Linear on purpose - an eased press scale feels laggy.
  Behavior on scale {
    enabled: root.animationsEnabled
    NumberAnimation {
      duration: Ui.fastMs
    }
  }

  // The press scale, per frame, for the reason Glide.qml gives for having no
  // tick of its own: the animation clone has no signal to hang one on, and
  // the frame loop on the item is where the curve is actually visible.

  // The slot is the button's size in both content modes, so a size change is
  // the token move every consumer of this primitive makes.

  // The interaction edges. `hovered` and `pressed` are already gated through
  // `live` above, so these lines report the gated value the chrome used and
  // not Qt's raw one - which is why a disabled button logs no hover at all.

  onHoveredChanged: {
    root._syncTip()
  }

  on_FocusedChanged: {
  }

  // The wrapper's OWN clicked signal, not the native one: a consumer's
  // handler is attached here, so this is the edge a consumer of the
  // primitive sees. The native edge re-emits into it from `btn` below.

  // The hover bubble, and the 350ms hover delay that arms it. A bubble that
  // never appears on an island button is either a missing tipText or the
  // `live` gate, and these are the two lines that tell them apart.
  on_TipShownChanged: {
  }

  Ctl.Button {
    id: btn

    anchors.fill: parent
    // The chrome is full-bleed: the shell's own background and content
    // items replace the style's, so no style padding may sit between them.
    padding: 0
    enabled: root.enabled
    // Panels own Tab for their own row traversal, so the button takes focus
    // but is not a tab stop: a click still focuses it and Space/Enter
    // activate it.
    activeFocusOnTab: false
    onClicked: if (root.live) root.clicked()

    background: Rectangle {
      // Hover wash sits between the faint ground and the pressed/accent
      // state; the border tightens with it. Both tween through the shared
      // anims below, like every other hoverable chrome in the shell.
      color: root.color
      radius: root.radius
      border.width: root.flat ? 0 : 1
      // Focus is Qt's, the ring is the shell's: the accent border is the
      // ring this control has always worn, so a focused slot reads the
      // accent a press does, and a flat slot still shows focus in its fill.
      border.color: root.flat
        ? (root._focused ? Ui.tint("accent", 0.15) : "transparent")
        : root.bright || root.pressed || root._focused ? Theme.color("accent")
        : root.hovered ? Ui.tint("foreground_1", 0.7)
        : Ui.tint("foreground_1", 0.4)

      Behavior on color {
        enabled: root.animationsEnabled
        ColorAnim {}
      }
      Behavior on border.color {
        enabled: root.animationsEnabled
        ColorAnim {}
      }
    }

    contentItem: Item {
      Icon {
        id: icon

        visible: root.iconMode
        anchors.centerIn: parent
        name: root.name
        colorKey: root.colorKey
        accentKey: root.accentKey
        dimTiers: root.dimTiers
        size: root.iconSize
        opacity: root.iconOpacity
      }

      Text {
        anchors.centerIn: parent
        visible: !root.iconMode
        text: root.glyph
        color: root.bright ? Theme.color("accent") : Theme.color("foreground_1")
        font.pixelSize: Ui.fontXs
        font.family: Ui.fontFamily
        textFormat: Text.PlainText
      }
    }
  }

  // Hover-delay state for the bubble below (plain bool, not a Timer
  // binding, so leaving early cancels and re-entering restarts).
  property bool _tipShown: false

  // Qt's hover signal replaces the hand-rolled pointer watch. The gate is
  // the native hovered rather than root.hovered, because the armed look is
  // not a cursor: forceHover must paint the fill without popping a bubble.
  function _syncTip() {
    if (btn.hovered && root.tipText !== "" && root.live) tipTimer.restart()
    else {
      tipTimer.stop()
      root._tipShown = false
    }
  }

  onEnabledChanged: _syncTip()
  onActionableChanged: _syncTip()
  onTipTextChanged: _syncTip()

  Timer {
    id: tipTimer

    interval: 350
    onTriggered: root._tipShown = btn.hovered
  }

  // The bubble: left of the button, vertically centered, growing
  // leftward into the card. Island buttons live in clipped lists and
  // under the card edge - a bubble above the button clipped on the
  // viewport top and the island border. The row band is taller than the
  // bubble, so the leftward bubble never touches a clip boundary: it
  // briefly paints over the row's own text instead.
  Rectangle {
    id: tip

    visible: root._tipShown && root.tipText !== "" && root.live
    anchors.right: parent.left
    anchors.rightMargin: 6
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(tipLabel.implicitWidth + 2 * Ui.s, 240)
    height: tipLabel.implicitHeight + Ui.s
    z: 100
    color: Ui.solid("background_0")
    border.width: 1
    border.color: Ui.solid("background_3")

    Text {
      id: tipLabel

      anchors.fill: parent
      anchors.leftMargin: Ui.s
      anchors.rightMargin: Ui.s
      verticalAlignment: Text.AlignVCenter
      text: root.tipText
      color: Ui.solid("foreground_0")
      font.pixelSize: Ui.fontS
      font.family: Ui.fontFamily
      textFormat: Text.PlainText
      elide: Text.ElideRight
    }
  }
}
