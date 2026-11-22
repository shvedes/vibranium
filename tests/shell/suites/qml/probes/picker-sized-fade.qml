// Probe: picker entrance gate and one inherited fade (WAL-1, WAL-2).
//
// LIMITATION: ThemePickerPanel cannot be constructed headlessly. It reaches
// LayerSurface through MenuView -> OverlayWindow -> ScrimWindow, and no
// PanelWindow backend loads under QT_QPA_PLATFORM=offscreen (the same limit the
// polkit-flow-contract probe records). The panel is therefore NOT constructed
// here. The suite hands the real file in through the environment; this probe
// checks that file's structure and drives a small turn-based model of the
// reveal gate, sampling consecutive turns instead of only the end state.
//
// Contract under test:
//   * reveal() releases _settled/_fade from a live _sized edge or a callLater
//     that re-checks _sized && visible - never from an unconditional 16 ms
//     timer. No geometry Behavior can run while the panel is unsized.
//   * one root opacity + one Behavior on opacity; the five former per-child
//     presence fades are gone, so every child inherits the same fade.
//   * the contentBottom -> contentH -> deckH -> bigH chain is untouched.

import QtQuick
import Quickshell

Item {
  id: root

  width: 1
  height: 1

  readonly property string src: Quickshell.env("THEME_PANEL_SRC") || ""

  property int turn: 0
  property bool done: false

  function kv(key, value) { console.log("##KV## " + key + "=" + String(value)) }

  function countOf(s, needle) {
    let n = 0
    let at = 0
    while (true) {
      const found = s.indexOf(needle, at)
      if (found < 0) return n
      n++
      at = found + needle.length
    }
  }

  function slice(needle, len) {
    const at = root.src.indexOf(needle)
    return at < 0 ? "" : root.src.slice(at, at + len)
  }

  // ---- source facts --------------------------------------------------------

  readonly property bool srcSized: root.src.indexOf("readonly property bool _sized: width > 0 && height > 0") >= 0
  readonly property bool srcNoRevealTimer: root.src.indexOf("revealTimer") < 0
  readonly property bool srcCallLater: {
    const r = root.slice("function reveal()", 460)
    return r.indexOf("Qt.callLater") >= 0
      && r.indexOf("_sized") >= 0
      && r.indexOf("ThemePicker.visible") >= 0
  }
  readonly property bool srcSizeEdge: {
    const h = root.slice("on_SizedChanged", 260)
    return h.indexOf("_sized") >= 0 && h.indexOf("ThemePicker.visible") >= 0
  }
  readonly property bool srcGateLive: root.srcSized && root.srcNoRevealTimer
    && root.srcCallLater && root.srcSizeEdge

  readonly property int fadeBindingCount: root.countOf(root.src, "opacity: panel._fade ? 1 : 0")
  readonly property int rootOpacityBehaviorCount: root.countOf(root.src, "\n  Behavior on opacity {")
  readonly property int childPresenceBehaviorCount: root.countOf(root.src, "\n    Behavior on opacity {")
  readonly property bool srcOneRootFade: root.fadeBindingCount === 1
    && root.rootOpacityBehaviorCount === 1
    && root.childPresenceBehaviorCount === 0
    && root.slice("opacity: panel._fade ? 1 : 0", 160).indexOf("Glide { duration: Ui.fastMs }") >= 0
    && root.src.indexOf("opacity: panel._fade ? 1 : 0") < root.src.indexOf("id: stage")
  readonly property bool srcGeomGateKept: root.countOf(root.src, "enabled: MotionPolicy.enabled && panel._settled") >= 10
  readonly property bool srcContentChainKept: root.src.indexOf("contentBottom: footer.y - caption.implicitHeight - Ui.m * 2") >= 0

  // ---- turn-based model of the reveal gate --------------------------------

  property bool sized: false
  property bool settled: false
  property bool fade: false
  property int pending: 0
  property bool settledWhileUnsized: false
  property int animBeforeSized: 0
  property bool fadeBeforeSized: false
  property int childOpacityMismatch: 0

  // One root property, one reader per child - the shape srcOneRootFade checks.
  property real rootOpacity: 0
  property real stageOpacity: 0
  property real captionOpacity: 0
  property real emptyOpacity: 0
  property real searchOpacity: 0
  property real footerOpacity: 0

  function reveal() {
    root.settled = false
    root.fade = false
    root.pending = 0
    if (root.srcGateLive) {
      // Live edge: settled only when a real size has arrived.
      if (root.sized) { root.settled = true; root.fade = true }
    } else {
      // The old 16 ms timer: settles one turn later even at 0x0.
      root.pending = 1
    }
  }

  function sizePanel() {
    root.sized = true
    if (root.srcGateLive) {
      // on_SizedChanged fires with the real geometry; no Behavior runs.
      root.settled = true
      root.fade = true
    } else if (root.settled) {
      // Behaviors were armed by the timer, so the size change glides from
      // the zero-sized cards - the visible wrong-then-right frame.
      root.animBeforeSized++
    }
  }

  function tick() {
    root.turn++
    const t = root.turn

    if (t === 1) root.reveal()

    if (t === 2) {
      if (!root.srcGateLive && root.pending > 0) {
        root.pending = 0
        root.settled = true
        root.fade = true
      }
      if (!root.sized && root.settled) root.settledWhileUnsized = true
      if (!root.sized && root.fade) root.fadeBeforeSized = true
    }

    if (t === 3) root.sizePanel()

    // Sample each turn: children read one root value, never their own clock.
    root.rootOpacity = root.fade ? 1 : 0
    root.stageOpacity = root.rootOpacity
    root.captionOpacity = root.rootOpacity
    root.emptyOpacity = root.rootOpacity
    root.searchOpacity = root.rootOpacity
    root.footerOpacity = root.rootOpacity
    if (root.stageOpacity !== root.rootOpacity || root.captionOpacity !== root.rootOpacity
      || root.emptyOpacity !== root.rootOpacity || root.searchOpacity !== root.rootOpacity
      || root.footerOpacity !== root.rootOpacity) root.childOpacityMismatch++

    if (t >= 5) {
      root.kv("gate.live", root.srcGateLive)
      root.kv("gate.oneRootFade", root.srcOneRootFade)
      root.kv("gate.geometryGateKept", root.srcGeomGateKept)
      root.kv("gate.contentChainKept", root.srcContentChainKept)
      root.kv("frame.settledWhileUnsized", root.settledWhileUnsized)
      root.kv("frame.animBeforeSized", root.animBeforeSized)
      root.kv("frame.fadeBeforeSized", root.fadeBeforeSized)
      root.kv("frame.childrenInherit", root.childOpacityMismatch === 0 && root.srcOneRootFade)
      console.log("##DONE##")
      root.done = true
    }
  }

  Timer {
    interval: 25
    repeat: true
    running: !root.done
    onTriggered: root.tick()
  }
}
