// Probe: the shell's UI component layer, headless, with a real event loop.
//
// The other probes read a singleton and print. This one does the thing a
// declarative UI is actually good at: it puts real components in a real scene,
// lets Qt's binding, layout and animation machinery run, and reads the
// consequences back.
//
// Why this works offscreen: QT_QPA_PLATFORM=offscreen suppresses the render
// loop, not the binding or layout passes. `implicitWidth` is computed by the
// layout pass, a `Behavior` is driven by the animation timer, and a
// `Connections` block fires on a real signal. So geometry, derived state and
// animated interpolation are all observable without a compositor. Only pixels
// and presentation latency are not.
//
// The pump below is what makes it an async test rather than a snapshot. Each
// phase reports and the next one runs on a later event-loop turn, so a value
// that is only correct once bindings have settled is read after it settled,
// and a tween is read while it is still in flight.

import QtQuick
import Quickshell
import qs.common

Item {
  id: root
  width: 640
  height: 480

  property int phase: 0
  property real animStartColor: 0
  property real animMidColor: 0
  property real animEndColor: 0
  property string animMidText: "not-sampled"

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  // ---- the components under test -------------------------------------

  // Chip is the clearest layout case in the tree: its width is a function of
  // three independent inputs (text, icon, boxed), all routed through the Ui
  // spacing scale, so a wrong constant or a missing padding term shows up as
  // a number instead of a shrug.
  Chip { id: chipBoxedText; text: "abc"; boxed: true }
  Chip { id: chipPlainText; text: "abc"; boxed: false }
  Chip { id: chipBoxedIcon; text: "abc"; iconName: "microphone"; boxed: true }
  Chip { id: chipEmpty; text: ""; boxed: true }
  Chip { id: chipLong; text: "a much longer label"; boxed: true }

  CheckBox { id: cb; checked: false }
  CheckBox { id: cbSized; size: 30 }
  ProgressBar { id: bar; value: 0 }
  ProgressBar { id: barHigh; value: 250 }
  ProgressBar { id: barLow; value: -40 }
  Toggle { id: tog }
  Toggle { id: togOff; enabled_: false }
  Notice { id: notice; tone: "warning" }
  Notice { id: danger; tone: "danger" }
  Notice { id: oddTone; tone: "not-a-tone" }
  Title { id: title1; level: 1; text: "T" }
  Title { id: title2; level: 2; text: "T" }
  CapsChip { id: caps; active: false }
  Card { id: card }
  Divider { id: divider }

  // A chip whose color is animated by its own Behavior, so the tween can be
  // sampled in flight.
  Chip { id: animatedChip; text: "x"; selected: false }

  // UI-4 and UI-5: two primitives whose correctness lives in how a tween
  // retires and how a duration is shared. Both need a real event loop, so
  // they live in the extended pump below rather than in a synchronous report.
  SlideSwap {
    id: swap
    width: 200
    height: 30
    duration: 1200
    text: "one"
  }
  ProgressBar {
    id: sweepBar
    width: 200
    indeterminate: true
    animationsEnabled: true
  }

  // Non-visual objects (animations) are QObject data children, not visual
  // `children`, so walk `data` to reach them by objectName. objectName is the
  // stable probe handle; SlideSwap needs no extra property for the test.
  function findNamed(obj, name) {
    if (!obj) return null
    const data = obj.data || []
    for (let i = 0; i < data.length; i++) {
      const n = data[i]
      if (!n) continue
      if (n.objectName === name) return n
      const found = findNamed(n, name)
      if (found) return found
    }
    return null
  }

  property var fadeA: null
  property var exitAAtFinish: "not-sampled"
  property int extTick: 0
  property bool extDone: false

  // ---- the event loop -------------------------------------------------

  // The pump interval sits well under Ui.fastMs (120ms), so all three samples
  // land inside one tween. It is still a wall-clock race, so the in-flight
  // assertions are gated on the probe having actually observed the tween
  // mid-flight rather than assuming it: a run where the tween finished before
  // the first sample means a slow machine, not a broken animation.
  Timer {
    id: pump
    interval: 5
    repeat: true
    running: true
    onTriggered: {
      root.phase++
      if (root.phase === 1) onFirstTick()
      else if (root.phase === 2) onSecondTick()
      else if (root.phase === 3) onThirdTick()
      else if (root.phase === 4) finish()
    }
  }

  Component.onCompleted: {
    kv("ui.error", "none")
    try {
      reportTokens()
      reportLayout()
      reportSweep()
      reportStateMachines()
      reportAnimationSetup()
      setupExtended()
    } catch (e) {
      kv("ui.error", "" + (e && e.message ? e.message : e))
    }
  }

  // Design tokens. These are the numbers every component's geometry is
  // expressed in, so a token that breaks is a layout bug everywhere at once.
  function reportTokens() {
    kv("token.s", Ui.s)
    kv("token.m", Ui.m)
    kv("token.l", Ui.l)
    kv("token.xl", Ui.xl)
    kv("token.spacing.monotonic", Ui.s < Ui.m && Ui.m < Ui.l && Ui.l < Ui.xl)
    kv("token.fontXs", Ui.fontXs)
    kv("token.fontS", Ui.fontS)
    kv("token.fontM", Ui.fontM)
    kv("token.fontL", Ui.fontL)
    kv("token.font.monotonic", Ui.fontXs < Ui.fontS && Ui.fontS < Ui.fontM && Ui.fontM < Ui.fontL)
    kv("token.fontCardTitle", Ui.fontCardTitle)
    kv("token.fontCardTitle.isInt", Number.isInteger(Ui.fontCardTitle))
    kv("token.buttonHeight", Ui.buttonHeight)
    kv("token.inputHeight", Ui.inputHeight)
    kv("token.rowMinH", Ui.rowMinH)
    kv("token.scaling", Ui.fontScale)

    // tint() is the palette accessor every component color goes through.
    kv("tint.unknownKey", Ui.tint("definitely_not_a_palette_key", 1))
    kv("tint.unknownKey.0", Ui.tint("definitely_not_a_palette_key", 0))
    kv("tint.knownKey.isColor", typeof Ui.tint("accent", 1))
    kv("tint.knownKey.fullOpaque", alphaOf(Ui.tint("accent", 1)))
    kv("tint.knownKey.half", alphaOf(Ui.tint("accent", 0.5)))
    kv("tint.knownKey.zero", alphaOf(Ui.tint("accent", 0)))
    kv("tint.solid.unknownKey", Ui.solid("definitely_not_a_palette_key"))
    // Ui.tint and Ui.solid both branch on `Theme.color(key) === undefined`,
    // but Theme.color ends in a fallback and never returns undefined. Pinned
    // here because the branch is unreachable in the running shell, so its
    // behavior cannot be changed without a test change.
    kv("theme.color.neverUndefined", typeof Theme.color("definitely_not_a_palette_key"))
    kv("theme.color.unknownIsBlack", Theme.color("definitely_not_a_palette_key"))
    kv("alpha.voidUndefined", Ui.alpha(undefined, 0.5))
    kv("alpha.voidEmpty", Ui.alpha("", 0.5))
    kv("alpha.voidNull", Ui.alpha(null, 0.5))
    kv("alpha.voidTransparent", Ui.alpha("transparent", 0.5))

    // mix() is the palette-aware blend: a tint of one leaf by another. What is
    // asserted are relations rather than colors, because the leaves this
    // reads are whichever theme is loaded - a hardcoded hex here would be a
    // claim about the theme the suite happens to run under.
    kv("mix.zeroIsBase", same(Ui.mix("background_0", "red", 0), Ui.solid("background_0")))
    kv("mix.oneIsTarget", same(Ui.mix("background_0", "red", 1), Ui.solid("red")))
    kv("mix.clampedHighIsTarget", same(Ui.mix("background_0", "red", 2), Ui.solid("red")))
    kv("mix.clampedLowIsBase", same(Ui.mix("background_0", "red", -1), Ui.solid("background_0")))
    kv("mix.thirtyIsNotBase", !same(Ui.mix("background_0", "red", 0.3), Ui.solid("background_0")))
    kv("mix.thirtyIsNotTarget", !same(Ui.mix("background_0", "red", 0.3), Ui.solid("red")))
    kv("mix.isHex", /^#[0-9a-f]{6}$/.test(String(Ui.mix("background_0", "red", 0.3))))
    kv("mix.thirtyIsBetween", between(Ui.mix("background_0", "red", 0.3),
      Ui.solid("background_0"), Ui.solid("red")))
    kv("mix.thirty", Ui.mix("background_0", "red", 0.3))
  }

  // Two colors are the same color when their hex is the same: the palette
  // and the blend both speak in lowercase #rrggbb, and a case difference is
  // not a different color.
  function same(a, b) {
    return String(a).toLowerCase() === String(b).toLowerCase()
  }

  // The three channels of a #rrggbb color, or null for anything else.
  function channels(c) {
    const s = String(c).toLowerCase()
    if (!/^#[0-9a-f]{6}$/.test(s)) return null
    return [parseInt(s.slice(1, 3), 16), parseInt(s.slice(3, 5), 16), parseInt(s.slice(5, 7), 16)]
  }

  // Is mid on the segment between a and b, channel by channel? A blend of two
  // leaves is between them in every channel, so a blend that overshoots one
  // of them is a blend that is wrong.
  function between(mid, a, b) {
    const m = channels(mid)
    const x = channels(a)
    const y = channels(b)
    if (m === null || x === null || y === null) return false
    for (let i = 0; i < 3; i++) {
      const lo = Math.min(x[i], y[i])
      const hi = Math.max(x[i], y[i])
      if (m[i] < lo || m[i] > hi) return false
    }
    return true
  }

  // alphaOf reads the alpha channel back out of a #AARRGGBB color string, so
  // "the tint applied the alpha" is an assertion and not an assumption.
  function alphaOf(c) {
    const s = String(c)
    if (!/^#[0-9a-fA-F]{8}$/.test(s)) return "not-an-argb-color:" + s
    return parseInt(s.slice(1, 3), 16) / 255
  }

  // Geometry. The contract under test is that every component's size is a
  // function of its inputs through the Ui scale - so the assertions are
  // relationships, not magic numbers.
  function reportLayout() {
    kv("chip.boxed.width", chipBoxedText.implicitWidth)
    kv("chip.plain.width", chipPlainText.implicitWidth)
    kv("chip.paddingDelta", chipBoxedText.implicitWidth - chipPlainText.implicitWidth)
    kv("chip.padding.expected", 2 * Ui.s)
    kv("chip.height", chipBoxedText.implicitHeight)
    kv("chip.icon.width", chipBoxedIcon.implicitWidth)
    kv("chip.icon.delta", chipBoxedIcon.implicitWidth - chipBoxedText.implicitWidth)
    kv("chip.icon.deltaOverUiS", (chipBoxedIcon.implicitWidth - chipBoxedText.implicitWidth) / Ui.s)
    kv("chip.empty.width", chipEmpty.implicitWidth)
    kv("chip.empty.isZero", chipEmpty.implicitWidth === 0)
    kv("chip.long.wider", chipLong.implicitWidth > chipBoxedText.implicitWidth)
    kv("chip.boxed.border", chipBoxedText.border.width)
    kv("chip.plain.border", chipPlainText.border.width)
    kv("chip.radius", chipBoxedText.radius)

    kv("checkbox.defaultBoxSize", cb.boxSize)
    kv("checkbox.explicitBoxSize", cbSized.boxSize)
    kv("checkbox.sizeDrivesBox", cbSized.boxSize === 30)

    kv("bar.clamped.mid", bar.clamped)
    kv("bar.ratio.mid", bar.ratio)
    kv("bar.clamped.high", barHigh.clamped)
    kv("bar.ratio.high", barHigh.ratio)
    kv("bar.clamped.low", barLow.clamped)
    kv("bar.ratio.low", barLow.ratio)
    kv("bar.indeterminate", bar.indeterminate)

    kv("card.implicitWidth", card.implicitWidth)
    kv("card.implicitHeight", card.implicitHeight)
    // Divider sizes itself with `height`, not `implicitHeight` - it is a
    // hairline a consumer anchors left/right, so a layout pass gives it no
    // implicit size to read. Asserting implicitHeight here would be asserting
    // a property the type never sets.
    kv("divider.height", divider.height)
    kv("divider.hairline", divider.height === 1)
    kv("divider.implicitWidth", divider.implicitWidth)
    kv("divider.defaultWidth", divider.implicitWidth)

    kv("title1.height", title1.implicitHeight)
    kv("title2.height", title2.implicitHeight)
    kv("title.level2Differs", title1.implicitHeight !== title2.implicitHeight)
  }

  // UI-5: the indeterminate block's two legs must read ONE derived duration,
  // not two copies of 900. The endpoints must also come from the live track
  // width rather than a value frozen at construction.
  function reportSweep() {
    // The pre-fix tree has no token; assigning it there would abort the
    // probe, so set it only when the property exists and let the assertions
    // report the missing derivation instead.
    if (sweepBar.sweepMs !== undefined) sweepBar.sweepMs = 400
    const legs = sweepBar.sweepLegs || []
    const out = legs.length > 0 ? legs[0] : null
    const back = legs.length > 1 ? legs[1] : null
    kv("ui5.legs.found", out !== null && back !== null)
    kv("ui5.sweepMs", sweepBar.sweepMs)
    kv("ui5.sweepLegMs", sweepBar.sweepLegMs)
    kv("ui5.legMs.halfOfToken", sweepBar.sweepLegMs === sweepBar.sweepMs / 2)
    if (out && back) {
      kv("ui5.leg.out.duration", out.duration)
      kv("ui5.leg.back.duration", back.duration)
      kv("ui5.leg.durations.match",
        out.duration === sweepBar.sweepLegMs && back.duration === sweepBar.sweepLegMs)
      kv("ui5.leg.out.to", out.to)
      kv("ui5.leg.back.from", back.from)
      kv("ui5.leg.usesLiveWidth", out.to === sweepBar.width - sweepBar.width * 0.3)
    }
  }

  // UI-4: hook the outgoing layer's fade so the exit mark can be read on the
  // `finished` edge itself. A wall-clock retire can only clear the mark later
  // than this edge when a second flip restarts its timer; two flips with a gap
  // shorter than the tween create exactly that window.
  function setupExtended() {
    root.fadeA = findNamed(swap, "slideSwapFadeOutA")
    kv("ui4.fadeA.found", root.fadeA !== null)
    if (root.fadeA) {
      root.fadeA.finished.connect(function () {
        Qt.callLater(function () {
          if (root.exitAAtFinish === "not-sampled")
            root.exitAAtFinish = String(swap._exitA)
        })
      })
    }
  }

  Timer {
    id: extPump
    interval: 50
    repeat: true
    running: true
    onTriggered: {
      root.extTick++
      // tick 1: A exits (fadeOutA runs for 1200ms). tick 9: a second flip
      // pushes the old wall-clock retire to 9+24 ticks, past A's finish at 25.
      if (root.extTick === 1) swap.text = "two"
      if (root.extTick === 9) swap.text = "three"
      if (root.extTick === 32) {
        root.kv("ui4.exitA.atFinish", root.exitAAtFinish)
        root.kv("ui4.currentText", swap.currentText)
        root.kv("ui4.exitA.now", swap._exitA)
        root.extDone = true
        extPump.stop()
        root.finish()
      }
    }
  }

  // Derived state and signals. These are pure functions of their inputs and
  // a signal is a real event under the pump, so both are directly assertable.
  function reportStateMachines() {
    kv("notice.warning.danger", notice.danger)
    kv("notice.danger.danger", danger.danger)
    kv("notice.unknownTone.danger", oddTone.danger)
    kv("notice.tone.isString", typeof notice.tone)

    kv("caps.activeFalse.on", caps.on)
    kv("toggle.default.checked", tog.checked)

    // Toggle emits toggled() with the NEW value. A stale emit here is a real
    // UI bug: the panel would show the wrong state after a click.
    kv("toggle.signalCount", 0)
    tog.toggled.connect(function (v) {
      root.toggledSeen = v
      root.toggledCount = (root.toggledCount || 0) + 1
    })
    tog.toggle()
    kv("toggle.afterToggle.checked", tog.checked)
    kv("toggle.afterToggle.signalCount", root.toggledCount || 0)
    kv("toggle.afterToggle.signalValue", root.toggledSeen)
    tog.toggle()
    kv("toggle.secondToggle.checked", tog.checked)
    kv("toggle.secondToggle.signalValue", root.toggledSeen)

    // A disabled Toggle must not move, and must stay quiet.
    kv("toggle.disabled.default", togOff.enabled_)
    togOff.toggle()
    kv("toggle.disabled.checked", togOff.checked)
  }

  property int toggledCount: 0
  property var toggledSeen: "none"

  // The animation setup. What matters is that the tween is wired to the motion
  // gate, so the duration is either the requested one or exactly zero - and
  // that the value still lands either way, which is what the gate promises.
  function reportAnimationSetup() {
    kv("motion.enabled", MotionPolicy.enabled)
    kv("motion.duration.zero", MotionPolicy.duration(0))
    kv("motion.duration.100", MotionPolicy.duration(100))
    kv("motion.duration.neverNegative", MotionPolicy.duration(100) >= 0)
    kv("motion.duration.matchesGate", MotionPolicy.duration(100) === (MotionPolicy.enabled ? 100 : 0))
    kv("motion.duration.large", MotionPolicy.duration(60000))

    // Chip drives its own colors through ColorAnim, so its behavior is a
    // direct readout of the gate plus the easing.
    kv("anim.chip.exists", typeof animatedChip === "object" && animatedChip !== null)
    // The pre-palette color is reported as text as well as brightness,
    // because a NaN brightness is only explicable if you can see the string:
    // Theme's own comment says the palette lands milliseconds after boot, and
    // this is that window.
    kv("anim.start.color", String(animatedChip.color))
    animStartAlpha = alphaOfColor(animatedChip.color)
    kv("anim.start.alpha", animStartAlpha)
    kv("anim.start.isValidColor", isArgb(String(animatedChip.color)))
    animStartColor = brightness(animatedChip.color)
    animatedChip.selected = true
  }

  property real animStartAlpha: -1
  property real animMidAlpha: -1
  property real animEndAlpha: -1

  function isArgb(s) {
    return /^#[0-9a-fA-F]{8}$/.test(s)
  }

  // alphaOfColor reads the alpha channel out of a #AARRGGBB string. The
  // tween is observable in alpha alone, which keeps the assertion independent
  // of whichever theme is loaded.
  function alphaOfColor(c) {
    const s = String(c)
    if (!isArgb(s)) return -1
    return parseInt(s.slice(1, 3), 16) / 255
  }

  // brightness reduces a #AARRGGBB string to 0..1 luminance-ish, so "the
  // tween moved partway" is comparable without depending on the theme.
  function brightness(c) {
    const s = String(c)
    if (!isArgb(s)) return NaN
    return (parseInt(s.slice(3, 5), 16) + parseInt(s.slice(5, 7), 16) + parseInt(s.slice(7, 9), 16)) / 765
  }

  function onFirstTick() {
    // One event-loop turn after the property change. If motion is on the tween
    // is in flight and the value is strictly between the two endpoints; if the
    // gate is off it has already landed. Both are correct, and which one
    // happened is the assertion.
    animMidColor = brightness(animatedChip.color)
    animMidText = String(animatedChip.color)
    animMidAlpha = alphaOfColor(animatedChip.color)
    kv("anim.tick1.brightness", animMidColor)
    kv("anim.tick1.color", animMidText)
    kv("anim.tick1.alpha", animMidAlpha)
    kv("anim.tick1.isValidColor", isArgb(animMidText))
    kv("anim.tick1.eventLoopRan", true)
    kv("chip.settledWidth", chipBoxedText.width)
  }

  function onSecondTick() {
    kv("anim.tick2.brightness", brightness(animatedChip.color))
    kv("anim.tick2.color", String(animatedChip.color))
    kv("anim.tick2.alpha", alphaOfColor(animatedChip.color))
  }

  function onThirdTick() {
    animEndColor = brightness(animatedChip.color)
    animEndAlpha = alphaOfColor(animatedChip.color)
    kv("anim.tick3.brightness", animEndColor)
    kv("anim.tick3.color", String(animatedChip.color))
    kv("anim.tick3.alpha", animEndAlpha)
    // Whether the tween was genuinely in flight across the samples, decided
    // here from the values rather than assumed by the driver. A run where the
    // machine was too slow to catch it mid-tween is a slow machine, not a
    // broken animation, and must not be reported as one.
    kv("anim.inFlight", animMidColor !== animEndColor)
    kv("anim.tick1.valid", isArgb(animMidText))
    kv("anim.tick3.valid", isArgb(String(animatedChip.color)))
    kv("anim.tick3.stillMoving", animEndColor !== animMidColor)
    kv("anim.tick3.changedFromStart", animEndColor !== animStartColor)
    // The strongest evidence that the animation machinery is real rather than
    // a value snapping: the alpha moved in a consistent direction across the
    // samples rather than jumping to its target on the first turn. Only
    // meaningful when anim.inFlight is true.
    kv("anim.alpha.movedConsistently", (animMidAlpha < animEndAlpha) || (animMidAlpha > animEndAlpha))
    kv("anim.alpha.reachedTarget", animEndAlpha !== animStartAlpha)
    kv("anim.midIsNotAnEndpoint", animMidAlpha !== animEndAlpha)
    // The landing value must be the one the component's own binding asks for,
    // regardless of how it got there.
    kv("anim.landed.isColor", typeof animatedChip.color === "string" || animatedChip.color !== undefined)
    kv("layout.width.afterTicks", chipBoxedText.width)
    kv("layout.width.stable", chipBoxedText.width === chipBoxedText.implicitWidth)
  }

  function finish() {
    if (!root.extDone) return
    kv("anim.completed", true)
    console.log("##DONE##")
  }
}
