pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Short-text swap with a slidefade: three Texts share one box, and on a
// `text` flip the outgoing string rises and fades while the incoming
// one rises from below and fades in - bottom to top over `duration`
// OutCubic. The opacity is deliberately staggered rather than
// mirrored: two mirrored binding fades sum to 1 every frame (a morph,
// not a fade), so the exit drops fast while the enter holds a short
// pause, and total light dips mid-swap. Empty swaps snap (a vanishing
// string always coincides with its owner's own show/hide fade).
// MotionPolicy gates every tween, so with animations off the swap is
// a single-frame switch. The box does not clip; hosts clip when the
// travel could paint outside their chrome.
//
// Triple-buffered: the incoming string always stages on an idle layer,
// so a flip that lands while two swaps are still in flight never steals
// a live layer - every outgoing string finishes its exit undisturbed.
// (Two layers pop under rapid flips: the reused layer's string changes
// mid-exit and its travel reverses.) With all three live the oldest
// exit is reused, so even a flip faster than the tween hands off from
// live values instead of jumping.
Item {
  id: root

  // The string fading (or faded) in.
  property string text: ""
  property color color: Ui.solid("foreground_0")
  property int fontSize: Ui.fontM
  property string fontFamily: Ui.fontFamily
  property int fontWeight: Font.Normal
  property real letterSpacing: 0
  property int horizontalAlignment: Text.AlignLeft
  // Rise travel and tween duration; design tokens by default.
  property real slide: Ui.s
  property int duration: Ui.fastMs
  // Text presentation forwarded to every layer. Defaults keep the plain,
  // un-elided copy the existing consumers paint; a host swapping styled
  // subtext or elided rows sets these once at construction. The enums are
  // ints so the library needs no Text-specific property type here.
  property int textFormat: Text.PlainText
  property int elide: Text.ElideNone
  property int wrapMode: Text.NoWrap
  property var fontFeatures: ({})
  // Optional per-string color resolver. A swap that changes color with the
  // string (a red notice replacing normal copy) sets this instead of
  // reassigning `color`: each layer resolves its OWN text, so the outgoing
  // copy keeps its color while it fades and only the incoming string lands
  // in the new one. Without it every layer reads `color`, as before.
  property var colorFor: null
  function colorOf(s) {
    return typeof root.colorFor === "function" ? root.colorFor(s) : root.color
  }

  // The string currently fading (or faded) in, for readers that must
  // not sample a tween mid-flight.
  readonly property string currentText: root._front === 0 ? root._a : root._front === 1 ? root._b : root._c
  // The resting layer's baseline, for hosts that align a sibling against this
  // same line of type.
  readonly property real baselineOffset: slideA.baselineOffset
  // The three slide layers, A first: each carries .text, .rise
  // (0 at rest, +slide staged below, -slide exiting above) and
  // .opacity for drivers that sample the travel itself.
  // probe hook: slides -> read by textinput.qml for
  // ghost snapshot readback; inert in production
  readonly property var slides: [slideA, slideB, slideC]

  // The front layer tracks `text` so the first paint lands without
  // motion; onCompleted freezes it into a snapshot and every later
  // flip stages on an idle layer, then trades front. Same-string
  // writes are no-ops.
  property string _a: text
  property string _b: ""
  property string _c: ""
  property int _front: 0
  // One exiting mark per layer. Each layer retires its own mark in its
  // fadeOutX.onFinished, so a mark is never held past the tween that owns
  // it: no wall-clock guess, and a finished layer is idle again at once.
  // The stamp written on each flip guards that edge - a finish from an
  // older exit cannot clear a mark a newer flip has re-stamped.
  // A layer is idle when it is neither front nor exiting, and the next
  // flip always enters from an idle one.
  property bool _exitA: false
  property bool _exitB: false
  property bool _exitC: false
  // Monotonic exit stamps: the victim of a flip with no idle layer is
  // the oldest exit.
  property int _exitSeq: 0
  property int _seqA: -1
  property int _seqB: -1
  property int _seqC: -1

  Component.onCompleted: {
    _a = text
  }

  function _layerText(i) { return i === 0 ? root._a : i === 1 ? root._b : root._c }
  function _setLayerText(i, v) { if (i === 0) root._a = v; else if (i === 1) root._b = v; else root._c = v }
  function _layerExit(i) { return i === 0 ? root._exitA : i === 1 ? root._exitB : root._exitC }
  function _setLayerExit(i, v) { if (i === 0) root._exitA = v; else if (i === 1) root._exitB = v; else root._exitC = v }
  function _layerSeq(i) { return i === 0 ? root._seqA : i === 1 ? root._seqB : root._seqC }
  function _setLayerSeq(i, v) { if (i === 0) root._seqA = v; else if (i === 1) root._seqB = v; else root._seqC = v }
  function _layerItem(i) { return i === 0 ? slideA : i === 1 ? slideB : slideC }
  function _fadeOutFor(i) { return i === 0 ? fadeOutA : i === 1 ? fadeOutB : fadeOutC }

  onTextChanged: {
    if (text === root._layerText(root._front)) return
    let target = -1
    for (let i = 0; i < 3; i++) {
      if (i !== root._front && !root._layerExit(i)) { target = i; break }
    }
    if (target < 0) {
      let oldest = 2147483647
      for (let i = 0; i < 3; i++) {
        if (i === root._front) continue
        if (root._layerSeq(i) < oldest) { oldest = root._layerSeq(i); target = i }
      }
      if (target < 0) target = (root._front + 1) % 3
    }
    const outgoing = root._front
    // The outgoing front keeps its string: it finishes its own exit
    // while the victim stages the new one below.
    root._setLayerText(target, text)
    root._setLayerExit(target, false)
    root._setLayerSeq(target, -1)
    root._setLayerExit(outgoing, true)
    const stamp = root._exitSeq++
    root._setLayerSeq(outgoing, stamp)
    root._fadeOutFor(outgoing).stamp = stamp
    root._front = target
    if (MotionPolicy.enabled) {
      // The shared enter tween is interrupted exactly once per flip,
      // so it stops and retargets; each layer owns its exit tween, so
      // concurrent exits all run to zero instead of freezing mid-fade
      // when the next flip would retarget a shared one. Every handoff
      // starts from the live value, never from rest.
      fadeIn.stop()
      root._fadeOutFor(target).stop()
      fadeInTween.target = root._layerItem(target)
      fadeInTween.from = root._layerItem(target).opacity
      const out = root._fadeOutFor(outgoing)
      out.stop()
      out.from = root._layerItem(outgoing).opacity
      out.restart()
      fadeIn.restart()
    } else {
      // No opacity binding exists to break, so plain assignments snap
      // every layer to rest: the front opaque, the rest invisible and
      // unstaged.
      fadeIn.stop()
      root._fadeOutFor(0).stop()
      root._fadeOutFor(1).stop()
      root._fadeOutFor(2).stop()
      for (let i = 0; i < 3; i++) root._layerItem(i).opacity = i === target ? 1 : 0
      root._setLayerExit(0, false)
      root._setLayerExit(1, false)
      root._setLayerExit(2, false)
    }
  }

  implicitWidth: Math.max(slideA.implicitWidth, slideB.implicitWidth, slideC.implicitWidth)
  implicitHeight: Math.max(slideA.implicitHeight, slideB.implicitHeight, slideC.implicitHeight)

  Text {
    id: slideA
    property real rise: root._exitA ? -root.slide : (root._front === 0 ? 0 : root.slide)
    width: parent.width
    y: (parent.height - implicitHeight) / 2 + rise
    text: root._a
    color: root.colorOf(root._a)
    font.pixelSize: root.fontSize
    font.family: root.fontFamily
    font.weight: root.fontWeight
    font.letterSpacing: root.letterSpacing
    horizontalAlignment: root.horizontalAlignment
    textFormat: root.textFormat
    elide: root.elide
    wrapMode: root.wrapMode
    font.features: root.fontFeatures
    // Owned by fadeOutA/fadeIn, not bound: the tweens hand off at rest
    // values (0 out, 1 in), so nothing reasserts on landing.
    opacity: 1
    Behavior on rise {
      enabled: MotionPolicy.enabled
      NumberAnimation { duration: root.duration; easing.type: Easing.OutCubic }
    }
  }

  Text {
    id: slideB
    property real rise: root._exitB ? -root.slide : (root._front === 1 ? 0 : root.slide)
    width: parent.width
    y: (parent.height - implicitHeight) / 2 + rise
    text: root._b
    color: root.colorOf(root._b)
    font.pixelSize: root.fontSize
    font.family: root.fontFamily
    font.weight: root.fontWeight
    font.letterSpacing: root.letterSpacing
    horizontalAlignment: root.horizontalAlignment
    textFormat: root.textFormat
    elide: root.elide
    wrapMode: root.wrapMode
    font.features: root.fontFeatures
    opacity: 0
    Behavior on rise {
      enabled: MotionPolicy.enabled
      NumberAnimation { duration: root.duration; easing.type: Easing.OutCubic }
    }
  }

  Text {
    id: slideC
    property real rise: root._exitC ? -root.slide : (root._front === 2 ? 0 : root.slide)
    width: parent.width
    y: (parent.height - implicitHeight) / 2 + rise
    text: root._c
    color: root.colorOf(root._c)
    font.pixelSize: root.fontSize
    font.family: root.fontFamily
    font.weight: root.fontWeight
    font.letterSpacing: root.letterSpacing
    horizontalAlignment: root.horizontalAlignment
    textFormat: root.textFormat
    elide: root.elide
    wrapMode: root.wrapMode
    font.features: root.fontFeatures
    opacity: 0
    Behavior on rise {
      enabled: MotionPolicy.enabled
      NumberAnimation { duration: root.duration; easing.type: Easing.OutCubic }
    }
  }

  // No wall-clock retire: a layer that keeps an exit mark also owns a
  // fadeOutX running to opacity 0, so `finished` is a real edge for it.
  // A tween that is stopped is the flip's target and is unmarked at that
  // same moment, so no marked tween can miss its edge - no fallback timer.

  // One exit tween per layer: concurrent exits each run to zero, so a
  // flip landing mid-flight never freezes a fading layer. The shared
  // enter below is the staggered one - the exit drops fast while the
  // enter holds a short pause, so the pair never sums to a constant 1
  // and the dip is the visible fade. Targets and starts are set per
  // flip (interrupts hand off from the current value); ends equal the
  // rest values, so the tweens land and stay without any binding.
  NumberAnimation {
    id: fadeOutA
    // probe hook: slideSwapFadeOutA -> read by ui.qml for
    // finished-edge exit mark; inert in production
    objectName: "slideSwapFadeOutA"
    property int stamp: -1
    target: slideA
    property: "opacity"
    to: 0
    duration: root.duration
    easing.type: Easing.OutCubic
    onFinished: {
      if (root._seqA === fadeOutA.stamp) root._exitA = false
    }
  }
  NumberAnimation {
    id: fadeOutB
    property int stamp: -1
    target: slideB
    property: "opacity"
    to: 0
    duration: root.duration
    easing.type: Easing.OutCubic
    onFinished: {
      if (root._seqB === fadeOutB.stamp) root._exitB = false
    }
  }
  NumberAnimation {
    id: fadeOutC
    property int stamp: -1
    target: slideC
    property: "opacity"
    to: 0
    duration: root.duration
    easing.type: Easing.OutCubic
    onFinished: {
      if (root._seqC === fadeOutC.stamp) root._exitC = false
    }
  }
  SequentialAnimation {
    id: fadeIn
    PauseAnimation { duration: root.duration / 3 }
    NumberAnimation {
      id: fadeInTween
      property: "opacity"
      to: 1
      duration: root.duration
      easing.type: Easing.OutCubic
    }
  }
}
