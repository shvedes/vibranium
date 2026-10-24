pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.common
import "../collections/FrozenFootprint.js" as FP

// IslandHost: the single shared island window per BarView (per screen).
// Modules stop owning windows; they lend an anchor item plus a content
// Component. The host owns the window, the card chrome, positioning,
// focus grab, ESC, outside-click dismissal and the close fade. Only one
// island is ever open per screen (exclusive by construction).
//
// Built on a full-screen PanelWindow (layer-shell) rather than a
// PopupWindow: xdg_popup cannot attach to a layer surface, so a popup
// anchored to the bar dies with a fatal Wayland protocol error. Instead
// the host is a transparent overlay on the bar's screen with the card
// parked at a fixed spot relative to the served module - it cannot move
// freely, but it is fully interactive (clicks, wheel, keys).
//
// Dismissal: HyprlandFocusGrab routes input to the host and its bar
// while open - clicking anywhere else clears the grab and closes. A
// full-screen MouseArea under the card is a second net in case the grab
// is unavailable; the card swallows its own clicks so content
// interactions never fall through to it.
//
// Content loading: the window and the card chrome (theme fill, border,
// padded body) are cheap and stay alive - the close fade needs them. The
// actual island content is lent per show as a `contentComponent` and the
// card's Loader instantiates it while the host is open (and through the
// close fade, so items never vanish mid-animation), destroying it when
// the fade lands at opacity 0. A closed host is therefore a window shell
// only - no content items, no pollers' trees, no delegates - and opening
// one is exactly one synchronous component incubation.
//
// Sizing contract: the content root Item exposes its own size, no
// cross-boundary alias reads:
//   property int islandContentWidth: 380
//   property int islandContentHeight: Math.ceil(body.implicitHeight) + 2 * Ui.outerPad
//   property bool islandSelfAnimating: false
// The card binds to the live content while loaded, else to the frozen
// footprint keyed by the opener's slot id (`anchor.moduleId`, set by the
// Zone wrapper; fallback key "default").
//
// Keyboard contract: the content root Item may also expose, optionally,
//   property var islandNavTarget: someList
// which is the object the arrows and Enter are routed to. It is duck-typed
// (moveBy(dx, dy) for a direction, activate() for Enter, each probed
// separately), so a `List` or `GridList` satisfies it with one line and an
// island with bespoke rows can hand over anything that does. An island that
// omits it keeps the arrow keys for whatever it handles itself.
//
// Nothing about the content's own keyboard handling is needed for Escape:
// the router wraps the card, so it is an ancestor of every focused child
// and the ladder is delivery order rather than a stack an island maintains.
// See IslandNav.qml for why that is a wrapper and not a sibling sink.
//
// Overlay classification: the three module-local overlay windows
// (TrayMenu, ColorPickerOverlay, NetworkQrOverlay) are separate
// layer-shell surfaces on WlrLayer.Overlay and stay independent of this
// host; each is incompatible for a specific, verifiable reason.
//   - TrayMenu: a structural clone of this host (full-screen transparent
//     window, card parked under the clicked item, focus-grab dismissal),
//     but on WlrLayer.Overlay where this host sits on WlrLayer.Top, so
//     migrating it would put the tray popup underneath every island.
//   - ColorPickerOverlay: a full-screen opaque ScreencopyView still
//     frame whose magnifier lens reads real pixels, and whose
//     captureItem the module grabs. This host's card is themed, clipped
//     and faded, and its content is destroyed once the fade lands, so a
//     captured frame cannot live in a content Loader.
//   - NetworkQrOverlay: holds WlrKeyboardFocus.Exclusive
//     unconditionally, while this host gates focus on root.open and
//     unmaps with the fade; the QR surface must stay mapped and focused
//     while the code, the password reveal and the error states run.
// None of the three keeps a frozen footprint, so the footprint contract here
// does not reach them. The color picker takes a surface claim while its pick
// runs, but that claim belongs to the pick, not to this host: it is taken
// and released with the pick's own lifetime.
PanelWindow {
  id: root

  // The currently served module; used for centering.
  property Item anchorItem: null
  // The lent content for the current island.
  property Component contentComponent: null
  // Where the bar sits: "top" drops the island below it, "bottom" above.
  property string barPosition: "top"
  // Gap between the bar edge and the island (the spacing token).
  property int margin: Ui.s

  property bool open: false

  // Read-only: the instantiated content (null while closed).
  readonly property alias content: cardLoader.item

  // Global animation kill switch (hypr.animations.enabled): off snaps the
  // card to final opacity instead of fading. Wired here at library level
  // like PanelCard - every island consumer follows the switch.
  property bool animationsEnabled: MotionPolicy.enabled

  // Last live content size per opener slot id. When the Loader destroys
  // the content, the card sizes from this instead - the closed host keeps
  // the footprint it had, and a reopen never starts from the fallback.
  //
  // The map, its bound, its LRU eviction and its diagnostics live in
  // FrozenFootprint (a pure .pragma library): this host is a PanelWindow,
  // which qmltestrunner cannot load, so the parts worth testing cannot
  // live here. A rejected size leaves the entry it would have replaced
  // untouched, so a collapsed measurement can never freeze in.
  property var _footprint: FP.create(root.frozenCapacity)
  property string _key: "default"

  // One entry per opener slot id. The bar module catalog is 25 slots
  // wide, so a layout that keeps every module on the bar never evicts;
  // eviction starts only once layout churn has retired more distinct
  // ids than the bar has slots, which is exactly when the retired
  // entries are the ones worth dropping.
  readonly property int frozenCapacity: 32

  function _frozenW(key): int {
    return FP.w(root._footprint, key)
  }
  function _frozenH(key): int {
    return FP.h(root._footprint, key)
  }
  function _keyFor(anchor): string {
    try {
      const mid = anchor && anchor.moduleId !== undefined ? String(anchor.moduleId || "") : ""
      return mid !== "" ? mid : "default"
    } catch (e) { return "default" }
  }
  function _saveFrozen() {
    if (!root.open || !root.content) return
    const w = root.content.islandContentWidth
    const h = root.content.islandContentHeight
    // typeof NaN is "number", so a zero, negative or non-finite size
    // passes a typeof check. Freezing one would collapse every later open
    // of that slot, so the size is refused here and the footprint keeps
    // the last good entry.
    const saved = FP.save(root._footprint, root._key, w, h)
    if (!saved.ok) {
      return
    }
    // Copy on write: the library hands back a new store, so the card
    // bindings re-read the map instead of the mutated one.
    root._footprint = saved.store
  }

  // Footprint and card state in one plain object, for a probe or a
  // diagnostic dump: how many footprints are retained, the bound, which
  // opener slot the map is keyed on, whether content is live, and the
  // card size those two produce.
  function diagnostics(): var {
    const fp = FP.diagnostics(root._footprint)
    return {
      count: fp.count,
      capacity: fp.capacity,
      key: root._key,
      contentLive: root.content !== null,
      keys: fp.keys,
      active: fp.active,
      cardWidth: Math.round(card.width),
      cardHeight: Math.round(card.height)
    }
  }

  // The content's keyboard target, or null. A function rather than a binding
  // for the reason in the header: `cardLoader.item` is typed QtObject, so a
  // binding reading a property the content may not declare is a binding that
  // can fail to evaluate - and Qt answers that by dropping it, silently,
  // leaving an island that never navigates. Probed with `!== undefined`,
  // per key press instead of per property notification.
  function _navTarget(): var {
    const c = root.content
    if (c === null || c === undefined) return null
    try {
      const t = c.islandNavTarget
      return t === undefined ? null : t
    } catch (e) { return null }
  }

  // Whether the loaded content wants the router to stand down. False when the
  // content declares no predicate, which is the answer for every island that
  // has no inline editor to protect.
  function _navBlocked(): bool {
    const c = root.content
    if (c === null || c === undefined) return false
    try {
      return c.blockedNavKeys === true
    } catch (e) { return false }
  }

  function show(anchor, comp) {
    root._key = root._keyFor(anchor)
    root.anchorItem = anchor
    if (root.contentComponent !== comp) root.contentComponent = comp
    root.open = true
    root.requestPark()
  }
  function toggle(anchor, comp) {
    if (root.isOpenFor(anchor)) root.close()
    else root.show(anchor, comp)
  }
  function close() {
    root.open = false
    // Clear the pile synchronously as well: when animations are off the fade
    // snaps to zero and the window can unmap before requestPark's deferred
    // positionCard runs, leaving the showing flag stuck true and the pile
    // shifted into the middle of the screen. Publishing false here (harmless
    // geometry) returns it to the bar dock immediately; requestPark below
    // reconciles the record afterwards.
    try {
      const key = root._islandKey
      if (key !== "") DesktopLayoutState.publishIsland(key, false, 0, 0)
    } catch (e) {}
    root.requestPark()
  }
  function isOpenFor(anchor): bool {
    return root.open && root.anchorItem === anchor
  }

  // Notification-pile clearance, published as plain data per screen (see
  // DesktopLayoutState.publishIsland): target geometry from positionCard
  // below - the parked y/h - never the animated card props, so a mid-glide
  // park can never freeze a half height in. `open` rides along as the
  // showing flag, so close() clears the pile through the requestPark above
  // it, and resizes repark through the existing size/content triggers.
  // `_islandKey` is the last published screen: a rewired anchor evicts the
  // old key, so a host never clears two screens at once. Teardown releases
  // it, so a destroyed-while-open host cannot hold the pile down.
  //
  // Last screen key published for the pile ("" when none).
  property string _islandKey: ""

  Component.onDestruction: {
    if (root._islandKey !== "") DesktopLayoutState.releaseIsland(root._islandKey)
  }

  function anchorScreen(): var {
    try {
      const a = root.anchorItem
      const w = a && a.barWindow ? a.barWindow : null
      return w ? w.screen : null
    } catch (e) { return null }
  }
  function grabWindows(): var {
    try {
      const a = root.anchorItem
      const w = a && a.barWindow ? a.barWindow : null
      return w ? [root, w] : [root]
    } catch (e) { return [root] }
  }

  // Full-screen transparent overlay on the bar's screen. Only mapped while
  // open (or fading out) so it never intercepts input when closed.
  screen: root.anchorScreen()
  visible: root.open || card.opacity > 0
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  anchors.top: true
  anchors.bottom: true
  anchors.left: true
  anchors.right: true

  WlrLayershell.namespace: "vibranium:island"
  WlrLayershell.layer: WlrLayer.Top
  // Keyboard focus follows `open`, NOT `visible`: the window stays mapped
  // through the close fade so the opacity has something to animate, but
  // keyboard ownership must release the moment the logical close fires or the
  // user is locked out of their own desktop for the length of the fade.
  //
  // THE PRIME IS LOAD-BEARING, and this is the whole reason the keyboard
  // works at all. Hyprland focuses an OnDemand surface when it FIRST MAPS -
  // and not when an already-mapped surface goes from None back to OnDemand.
  // This window is exactly that second case on every reopen: it stayed mapped
  // through the fade, so a reopen that asked for OnDemand got no focus, no
  // active focus item, and therefore no key events reaching any Keys handler.
  // Without the prime, ESC and the arrows reach no Keys handler at all.
  //
  // Exclusive is granted for one timer tick on every open to cover both the
  // first-map and the reopen case, then released back to OnDemand. Exclusive
  // has to stay brief: while it is set, Hyprland routes EVERY pointer event
  // to this surface regardless of which output the cursor is on, so holding
  // it would break clicks on every other monitor. 75ms is several Qt/Wayland
  // commit cycles and imperceptible.
  WlrLayershell.keyboardFocus: root.open
    ? (root.focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
    : WlrKeyboardFocus.None

  // True once the Exclusive phase has run for this open.
  property bool focusPrimed: false

  function beginFocusPrime() {
    if (root.open && root.backingWindowVisible) focusPrimeTimer.restart()
  }

  Timer {
    id: focusPrimeTimer

    // Several Qt/Wayland commit cycles after the surface becomes visible,
    // short enough that the Exclusive phase is never perceptible.
    interval: 75
    onTriggered: if (root.open) root.focusPrimed = true
  }

  // A layer surface holding compositor keyboard focus still needs an
  // ACTIVE-FOCUS ITEM inside it before any Keys handler fires: the grant is
  // about the surface, Qt's key delivery is about an item. The router holds
  // the sink, and the grant lands a round trip after the map, so the request
  // is deferred a turn and gated on the island still being open.
  //
  // It is a request, not a seizure: a content child that grabs focus for
  // itself (the calendar, the media island's body) wins deliberately, and
  // PanelFocus inside the router re-asserts only when nothing holds focus.
  function grabNavFocus() {
    Qt.callLater(() => {
      if (root.open && nav.focusSink) nav.focusSink.forceActiveFocus()
    })
  }
  // The ONE onOpenChanged in this file, and it carries every open-time job:
  // the focus prime, the focus request, and the card re-park. Splitting it
  // across two handlers is not a style question - a second assignment to the
  // same signal handler is a load-time error for the whole type.
  onOpenChanged: {
    if (root.open) {
      root.focusPrimed = false
      root.beginFocusPrime()
      root.grabNavFocus()
      // The bar or its modules may have moved while the host was closed, so
      // the card re-parks on open like it does when the anchor is rewired.
      root.requestPark()
    } else {
      focusPrimeTimer.stop()
      root.focusPrimed = false
    }
  }

  // Outside-click dismissal. While open, input is routed to the island and
  // its bar window; clicking anywhere else clears the grab and closes.
  HyprlandFocusGrab {
    active: root.open
    windows: root.grabWindows()
    onCleared: root.close()
  }

  // Exposed for content that needs to inspect card geometry
  property alias card: card

  // The key surface of the island, and the parent of everything below it.
  //
  // It WRAPS the card rather than sitting beside it, and that is the whole
  // point: a key event is delivered to the focused item and bubbles up its
  // parent chain, so an ancestor is the only place that sees both halves of
  // an island's keyboard - the keys a focused child (the calendar, a search
  // field, a slider) did not consume, and the keys nothing in the content
  // claims at all. The FocusScope this replaces was a SIBLING of the card,
  // so it only ever saw the second half: every island whose content grabs
  // focus for itself (the media island, the weather editor) had to
  // re-implement Escape itself.
  IslandNav {
    id: nav

    anchors.fill: parent
    active: root.open
    onEscapePressed: root.close()
    // Tab is not intercepted: it reaches Qt's own focus traversal inside the
    // island. An earlier revision routed it to the bar to hop between islands,
    // which is a separate feature that should not be wearing Tab's name.
    onDeleteRequested: {
      // Nothing on this bar's islands deletes a row generically. The signal is
      // routed rather than swallowed so an island that grows a delete action
      // wires it in one place, and a surface with no use for it stays silent
      // instead of every Delete key on the desktop reaching here.
    }
    target: root._navTarget()
    // The content's stand-down predicate, if it declares one: an island with
    // an inline editor sets `blockedNavKeys` so the router yields the keyboard
    // while that editor holds focus. Probed exactly as `target` is, and for
    // the same reason - a binding that reads a property the content may not
    // declare can fail to evaluate, and Qt drops such a binding silently.
    contentBlocked: root._navBlocked()

    // Dismissal net: any click outside the card closes the host. Inside the
    // router and declared before the card, so the card paints above it and
    // content clicks never fall through to it.
    MouseArea {
      id: dismissArea

      anchors.fill: parent
      enabled: root.open
      acceptedButtons: Qt.AllButtons
      onPressed: root.close()
    }

    // The card, parked next to the served module. Both windows are
    // full-screen on the same screen, so coordinates inside the bar window
    // equal coordinates inside this one; positionCard() maps the module
    // position over and re-runs whenever the host opens or the module is
    // wired. The chrome (theme fill, border, clip, padded body) comes from
    // the shared Card primitive; the content itself lives behind cardLoader
    // and only exists while the host is open (plus the fade-out window).
    Card {
      id: card

      objectName: "islandCard"
      // Live content size while anything is loaded; the frozen footprint
      // once it is gone.
      width: cardLoader.active && root.content
        ? root.content.islandContentWidth : root._frozenW(root._key)
      height: cardLoader.active && root.content
        ? root.content.islandContentHeight : root._frozenH(root._key)
      // Island windows wear the theme accent on their border at half
      // strength - a lighter stroke, not a see-through window (the card
      // body stays opaque). Card's default neutral stroke stays for
      // non-island consumers (OSD, TrayMenu).
      border.color: Ui.tint("accent", 1)
      opacity: root.open ? 1 : 0

      // Window grow/shrink follows the house resize tween (PanelCard,
      // MenuPanel) for discrete content changes. Self-animating content
      // (islandSelfAnimating) steps the Behavior aside so the card tracks
      // the content's own tween frame by frame - one easing only. The
      // opacity gate keeps the very first size evaluation (during the
      // fade-in, right after the content incubated) a snap instead of a
      // grow: the window then maps at its final size. Position is
      // unaffected: positionCard() owns card.x/y and the vertical park does
      // not depend on the height, so the card stays put while it grows.
      Behavior on height {
        enabled: root.animationsEnabled && !(root.content && root.content.islandSelfAnimating)
          && (card.opacity === 1 || !root.open)
        Glide { duration: Ui.resizeMs }
      }

      Behavior on opacity {
        enabled: root.animationsEnabled
        NumberAnimation { duration: Ui.fastMs }
      }

      Loader {
        id: cardLoader

        anchors.fill: parent.contentArea
        // Live while the host is open and through the close fade (items
        // must not vanish mid-animation); destroyed once the card is back
        // at opacity 0. Synchronous incubation: a frame of blank card on
        // first open is worse than the one-off build cost, and consumers'
        // open-time wiring (focus grabs et al) can assume the item exists
        // by the next event-loop turn.
        active: root.open || card.opacity > 0
        sourceComponent: root.contentComponent
        onLoaded: {
          if (cardLoader.item && cardLoader.item.islandHost !== undefined)
            cardLoader.item.islandHost = root
        }
      }
    }
  }

  // Freeze the last live size while the content exists. Size changes
  // also re-park the card (fresh content, list growth, skeleton swaps).
  Connections {
    target: root.content
    enabled: root.content !== null
    function onIslandContentWidthChanged() {
      root._saveFrozen()
      root.requestPark()
    }
    function onIslandContentHeightChanged() {
      root._saveFrozen()
      root.requestPark()
    }
  }
  onContentChanged: {
    root._saveFrozen()
    root.requestPark()
  }

  // One park per turn: every geometry trigger above funnels through
  // here, so a burst of width/height/content/anchor changes parks once
  // instead of once per change. The triggers stay (width, height,
  // content, anchor, bar position, open, map); the storm is what goes.
  property bool _parkQueued: false
  function requestPark() {
    if (root._parkQueued) return
    root._parkQueued = true
    Qt.callLater(() => { root._parkQueued = false; root.positionCard() })
  }

  function positionCard() {
    if (!root.anchorItem) return
    let barWin = null
    try {
      barWin = root.anchorItem.barWindow || null
    } catch (e) { barWin = null }
    if (!barWin) return
    const w = cardLoader.active && root.content
      ? root.content.islandContentWidth : root._frozenW(root._key)
    const h = cardLoader.active && root.content
      ? root.content.islandContentHeight : root._frozenH(root._key)
    if (!(w > 0) || !(h > 0)) return
    const screenW = root.width
    const screenH = root.height
    const barH = barWin.height
    // Parallel axis (along the bar): center the card under the module. The
    // bar spans the screen width, so its content x maps straight to screen x.
    const anchorX = root.anchorItem.mapToItem(barWin.contentItem, 0, 0).x
    let x = anchorX + root.anchorItem.width / 2 - w / 2
    // Perpendicular axis: hug the bar surface's edge (the bar is aligned to
    // its screen edge regardless of the bar's internal layout), dropping
    // below a top bar or above a bottom one.
    let y = root.barPosition === "bottom" ? screenH - barH - h - root.margin : barH + root.margin
    x = Math.max(root.margin, Math.min(x, screenW - w - root.margin))
    y = Math.max(root.margin, Math.min(y, screenH - h - root.margin))
    card.x = Math.round(x)
    card.y = Math.round(y)
    // Clearance for the notification pile: this park's target geometry (the
    // clamped y/h above, the footprints the card is actually parked at) plus
    // the showing flag. Plain data keyed by this window's screen, no-op when
    // unchanged - every open, close, move and resize funnels through here,
    // so the pile follows opens, closes and dynamic resizes by value.
    //
    // A close must clear the pile even when the surface has already unmapped
    // (animations off: the fade snaps to zero and the window drops before the
    // repark lands). Otherwise the showing flag stays true and the pile stays
    // shifted into the middle of the screen. So on close the flag is published
    // (with harmless geometry) regardless of the size guard below.
    let islandName = ""
    try { islandName = root.screen ? String(root.screen.name || "") : "" } catch (e) { islandName = "" }
    if (root._islandKey !== "" && root._islandKey !== islandName) DesktopLayoutState.releaseIsland(root._islandKey)
    if (islandName !== "") root._islandKey = islandName
    if (islandName !== "") {
      if (screenW > 100 && screenH > 100) {
        DesktopLayoutState.publishIsland(islandName, root.open, y, y + h)
      } else if (!root.open) {
        DesktopLayoutState.publishIsland(islandName, false, 0, 0)
      }
    }
  }

  // Re-park when the module wiring lands and when the position flips. Re-park
  // on open too, and it lives in the single onOpenChanged handler up with the
  // focus prime rather than here: a second assignment to `onOpenChanged` is
  // "Property value set multiple times", which Qt resolves by refusing to load
  // the whole type - so a duplicated handler takes down every island on the
  // bar, not just the island being opened.
  onAnchorItemChanged: root.requestPark()
  onBarPositionChanged: root.requestPark()

  // The first positionCard runs while the window is still at its default
  // size (100x100) and cross-window mapping is not yet valid. Re-run once
  // the surface actually maps and whenever the compositor configures a
  // real size, so the card lands at final coordinates. Mapping is also what
  // arms the focus prime, so both jobs hang off the one handler.
  onBackingWindowVisibleChanged: {
    if (!root.backingWindowVisible) return
    root.beginFocusPrime()
    root.requestPark()
  }
  onWidthChanged: {
    if (root.width > 100) root.requestPark()
  }
  onHeightChanged: {
    if (root.height > 100) root.requestPark()
  }
}