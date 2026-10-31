# `tests/shell/` — the Vibranium shell test suite

Exhaustive, headless tests for the Quickshell shell in `shell/`. Every suite
runs without a compositor, a display, or a network.

```sh
bash tests/shell/run-all.sh                    # everything, classified
bash tests/shell/run-all.sh --list             # the suites and what they cover
bash tests/shell/run-all.sh --only menu,unitgate -v
bash tests/shell/run-all.sh --baseline         # recorded pre-existing failures
bash tests/shell/suites/js/menu.test.mjs       # one suite, directly
```

Current state: **45 suites, ~29,800 assertions**, in about two minutes.
`baseline.txt` is empty — nothing is waived, so any failure is a regression.

## What is covered

| Area | Suites | What it tests |
| --- | --- | --- |
| Pure JS libraries | 12 | every `.pragma library` file, every exported function, plus the seven drop-in launcher plugins |
| QML components, live | 7 | 28 `common/ui` components driven across event-loop turns, plus `UnitGate`, `Registry`, `Bus`, `Paths`, `FilePresence` |
| Architecture | 4 | the four-layer import contract, every import edge, module declarations, and the assertion kit itself |
| Static data | 6 | the 45-unit boot catalog, the nine IPP templates, lint baseline, shipped assets, the settings catalog, the themes |
| CLI | 1 | the node CLI over the Hyprland config editor, as a subprocess |

The pure-JS libraries are the bulk of the shell's logic — about 13,400 lines
under `shell/`, all written to be unit-drivable. They are covered exhaustively
rather than sampled: a suite asserts coverage of its own library's export list
at the end, so dropping a function makes the suite red.

## How deep is it, honestly

Measured rather than estimated. The pure-JS figure comes from instrumenting
`node:vm` to record every file the JS suites actually *evaluate* — not from
grepping the suites for a filename, which a single comment can fake.

| Subject | Covered | How |
| --- | --- | --- |
| `.js` libraries | **98%** | every exported function, in a node `vm` |
| `.qml` behaviourally exercised | **32/199 (16%)** | constructed in a live Quickshell, driven, result read back |
| `.qml` statically analysed | **199/199 (100%)** | imports, module declarations, lint, construction |
| Launcher plugins | **7/7** | through the real `PluginInstance.qml` host contract |
| Settings catalog | 32 `.jsonc` | `suites/static/settings-catalog-test.sh` |
| Themes | 30 | `suites/static/themes-test.sh` |

**The honest headline is the QML line.** Every `.qml` file is checked for import
correctness, module-boundary correctness, `singleton` declaration agreement, and
clean construction — but only a handful are *behaviourally* exercised, meaning
something is constructed, something is changed, and the result is read back.

`common/ui` is now behaviourally covered in full — all 28 components, which is
the whole component layer. The earlier 3% was a real gap and closing it is what
found most of the defects in `KNOWN_ISSUES.md`: a `fail()` that forgets to
re-mask a password, a `wrap: false` that wraps anyway, a gridline loop that
freezes the config on a wide domain.

What is still uncovered is the *feature* layer rather than the component layer:
`features/` has 132 files, of which the JS libraries are tested but the QML
surfaces around them (the panel, island and dropdown compositions) are
structurally analysed only. That is the biggest remaining gap.

### What can still be added

Ordered by value per unit of effort:

1. **Behavioural probes for the feature surfaces.** The 132 files under
   `features/` are covered structurally and, where the logic is in a JS
   library, behaviourally through that library. The QML compositions around
   them — `features/launcher/AppLauncherPanel.qml`, the bar's island and pill
   wiring, `features/wallpaper/WallpaperView.qml`, the OSD — are not. Same
   harness, same pump; this is simply the largest untouched surface left.
2. **State-machine probes for the untested `common/` singletons.** `Exec`,
   `Idle`, `RequestGate`, `Watch`, `SecretStore`, `ProcessRegistry`,
   `AudioNodes`, `Theme`, and the QML half of `common/collections/`
   (`OptimisticSet`, `KeyedModel`, `ListFrameState`). Same shape as the
   `UnitGate` and `Registry` probes, so they are the cheapest remaining win.
3. **Real synthesised input.** Every `MouseArea`/`Keys.onPressed` handler in
   the component layer is currently untestable: QML offers no way to post a key
   or mouse event without a compositor, so the suites assert the routing
   properties those handlers read and skip the handler itself. A
   `QTest`-backed path, or a Quickshell build with a test injection point,
   would close this.
4. **`qmltestrunner` suites.** The binary and the `QtTest` module are both
   installed, so `TestCase` with async `tryCompare`/`wait` and key/mouse
   simulation is available — but only for components that avoid Quickshell's
   C++ types, because `quickshell-coreplugin` is linked into the `qs` binary and
   no other Qt app can load it. That rules out nearly every component in this
   tree, since they transitively import `Quickshell`. Worth it for new
   standalone fixtures, not for retesting the shell.
5. **Generated property tests** over the JS libraries, with a seed and a
   shrinking loop. The one thing that would find bugs the hand-written cases
   miss — at the cost of a fuzzer harness, and non-reproducible output unless
   the failing seed is pinned into the suite.

Not reachable here at any effort: rendered pixels, presentation latency, real
input routing from a compositor, second-output geometry, and anything behind a
PAM, polkit, PipeWire or CUPS daemon.

## Testing the UI headlessly

Yes — and this is the part that is easy to underestimate. `QT_QPA_PLATFORM=
offscreen` suppresses the **render** loop, not the binding, layout or animation
passes. A real component in a real scene can therefore be asserted on:

```qml
Chip { id: chip; text: "abc"; boxed: true }
// chip.implicitWidth evaluates. The layout pass ran.
```

`suites/qml/ui-test.sh` does exactly that against the real `common/ui`
components, and asserts the things a source read cannot reach:

- **Layout as a function of input.** `Chip` is `35.84` wide with the box on;
  dropping the box removes exactly `2 * Ui.s` (`16`). That is the padding term
  in the source being *measured* rather than read.
- **Derived state.** `ProgressBar.clamped` is `100` for `250` and `0` for `-40`;
  `CheckBox.boxSize` defaults to `14` and honours an explicit `size`.
- **Signals.** `Toggle.toggle()` emits `toggled` exactly once carrying the new
  value, and a disabled `Toggle` does not move.
- **An animation sampled *in flight*.** `Chip` drives its colours through
  `Behavior on color { ColorAnim {} }`. Reading the colour on three successive
  event-loop turns gives three distinct values whose alpha moves monotonically
  — `0.882 → 0.765 → 0.647`. If the animation were not wired and a value were
  snapping to its target, the first sample would already equal the last, and
  that is what the assertion checks.
- **A real event loop.** The probe steps through four `Timer` turns instead of
  reading everything synchronously, which matters: the chip's width at
  `Component.onCompleted` (`35.84`) is *not* the width it actually uses
  (`37.56`), because the label's implicit width needs a layout pass first. A
  synchronous snapshot would assert a value the component never has.

That last point is the general lesson for this tree: anything driven by a
`Behavior`, a `Connections`, or a binding that depends on a font or the theme
needs an event-loop turn before it is read, and a probe that samples
immediately gets a plausible wrong answer rather than an obvious failure.

## Layout

```
tests/shell/
  run-all.sh            the runner
  baseline.txt          recorded pre-existing failures (currently none)
  KNOWN_ISSUES.md       38 verified defects, severity-ordered
  lib/
    lib.sh              paths, and the Quickshell/Qt platform gate
    harness.sh          bash assertion kit
    qmlloader.mjs       node loader for QML .pragma library scripts
    assert.mjs          JS assertion kit
    qmlprobe.sh         headless Quickshell probe runner
  suites/
    architecture/       layer rules, import resolution, qmldir, the kit itself
    js/                 one .test.mjs per library area
    qml/                one probe .qml plus its driver, per component area
    static/             boot catalog, ipptool, qmllint, assets, catalog, themes
    cli/                the Hyprland editor CLI
```

A suite is discovered by name: `<name>-test.sh` or `<name>.test.mjs`, anywhere
under `suites/`. A suite that records **no assertions at all** is reported as
`NO-ASSERTIONS` and fails the run — a suite that asserts nothing has not
demonstrated anything, and that must never be able to pass silently.
`suites/architecture/harness-test.sh` exists for the same reason one level up:
it tests the kit, so a broken harness cannot report a green run.

## How each kind of suite works

### JS library suites — `suites/js/*.test.mjs`

A `.pragma library` file is not a node module: it has no exports, and its
`.import "x.js" as Y` lines are QML syntax. `lib/qmlloader.mjs` reproduces
both rules, giving each library its own `vm` context the way `QJSEngine` does,
so a `var` in one library cannot collide with the same name in another.

`lib/assert.mjs` is the assertion kit, deliberately shaped like the bash one:
same `section`/`group` vocabulary, same TSV result file, same
`PASS`/`FAIL`/`SKIP` vocabulary.

### QML probes — `suites/qml/`

A QML singleton cannot be unit-tested from node, but it can be *observed* from
a live Quickshell. `lib/qmlprobe.sh` mirrors the shell tree into a throwaway
config directory, evaluates a probe that imports the real `qs.*` modules, and
kills the process as soon as the probe prints its sentinel — about 110ms per
probe.

The protocol a probe follows:

```qml
console.log("##KV## " + key + "=" + value)   // one per observation
console.log("##DONE##")                       // exactly one, last
```

`qp_run` returns 0 only when `##DONE##` was seen, so a probe that fails to
construct is a failure and not a silently empty result set.

`Qt.quit()` and `Qt.exit()` are both no-ops in this configuration, which is why
the sentinel-and-kill protocol exists rather than a clean exit.

### Static and architecture suites

These read the tree as text. They need no Quickshell, so they run anywhere.
Every one of them resolves the edges it asserts on rather than counting files,
and several carry deliberate non-vacuity guards — a layer rule that passes
because the resolver found nothing is worse than no rule at all.

## The runner

Each suite is classified, and the classification is the point:

| Status | Meaning |
| --- | --- |
| `PASS` | every assertion passed |
| `BASELINE` | red by exactly the failures recorded in `baseline.txt` |
| `RESOLVED` | green, but still carries a baseline entry — prune it |
| `BLOCKED` | could not run here. **Never** counted as a pass. |
| `REGRESSION` | a failure outside the baseline. The runner exits 1. |

A baseline is a claim that must stay true, not a waiver: a suite that is red
beyond its recorded failures is a regression, not an expected state. Entries
require a reason, because a baseline line without one is indistinguishable
from a test nobody got round to writing.

Suites run sequentially in a fixed order. The whole run is about half a
minute; trading that for output that does not depend on scheduling is the
right way round.

## Writing a suite

Source the kit, use its assertions, and end with `t_summary`:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "my-thing" "what it covers"
t_section "a behaviour cluster"
t_eq "a label" "expected" "$actual"
t_summary
```

`require_qs` applies the platform gate, which pins **Quickshell 0.3.2 / Qt
6.12.0** and calls `t_block` on a mismatch — an unrunnable suite is never
reported as a pass.

Three assertion kinds are worth knowing about, because they are what keeps a
suite honest:

- `t_note` records an observation that is not an assertion — a documented
  difference from the shell README, a host-dependent value. Notes are counted
  separately so they can never be mistaken for coverage.
- `t_skip` marks behaviour that is explicitly unverified, with a reason. A skip
  is never a pass; it is a visible gap in the total.
- The qml helpers `qp_probe_ran <key>` distinguishes "the value was empty" from
  "the probe never got that far" — the difference between a wrong value and a
  broken singleton.

## Platform gate

Suites that need a live Quickshell are pinned to **Quickshell 0.3.2 /
Qt 6.12.0** (`lib/lib.sh`). `hasVersion()` is not accepted as a substitute: it
does not verify patch releases. A different pair fails the gate rather than
being assumed compatible.

## What cannot be verified here

Stated so nobody reads a skip as a pass. All of it is environmental, and every
one of the 13 skips in the suite carries its reason inline.

- **No compositor, and no screens at all.** `Quickshell.screens` is *empty*
  under `offscreen` - not one virtual screen - so `Ui.primaryScreen` is `null`
  and every per-screen surface is untestable. Multi-output geometry, screen
  hotplug and nested-compositor behaviour are source-level only.
- **No window backend.** `PanelWindow`-backed types cannot be constructed:
  `IslandHost` and `ScrimWindow` both fail with "No PanelWindow backend loaded",
  at component-compile time, so a probe that merely *mentions* one never
  loads. `suites/qml/host-button-test.sh` therefore reads the **real**
  `IslandHost.qml` over `XMLHttpRequest` and rewrites only the window surface -
  the root type, twelve window/layershell property lines, one handler, and the
  `HyprlandFocusGrab` block (removed so the suite can never dispatch a real
  focus grab at the user's compositor). Every function, the `Card`, the `Loader`
  and the `Connections` are the file's own bytes, and the probe self-reports
  what it dropped so a source change it no longer understands fails loudly.
  That is a real caveat: those assertions are on a modified copy, and the
  window-only behaviour is not asserted at all.
- **No synthesised input.** QML offers no way to post a key or mouse event
  without a compositor: `MouseArea.clicked()` throws `Insufficient arguments`,
  and `containsMouse` / `containsPress` / `AbstractButton.pressed` are
  read-only platform state that stays false. Every hover, press, key and wheel
  handler is therefore skipped, with the *routing* properties those handlers
  read asserted instead. That is 41 skips, and it is the largest single gap in
  the component coverage.
- **No PipeWire daemon.** Tracker unbinding is unverifiable, and the audio
  service's PipeWire-dependent behaviour is not exercised.
- **No PAM agent, polkit agent or credential store.** The polkit and lock
  surfaces are covered structurally, not by an actual authentication.
- **No cupsd and no printer.** The IPP suites read the request templates, the
  caller and the parser, and cross-check them. `ipptool` is never invoked:
  `services/system/ipptool/README.md` forbids sending a real request as
  verification. There is no live IPP round trip.
- **No network.** The weather provider fetches in `Weather.qml` are not
  exercised; the pure halves of its model are.
- **First-frame presentation latency is unmeasurable.** `QT_QPA_PLATFORM=
  offscreen` drives no render loop, so only a construction-to-layout proxy
  exists.
- **Binding re-evaluation timing is not measured.** The probes read singletons
  imperatively, and the runner kills the process on the sentinel, so whether a
  `readonly property var x: Singleton.latest(...)` binding re-evaluates on
  publish is out of reach. The value a read returns is covered.

## Findings

Defects and doc/code drift live in **[`KNOWN_ISSUES.md`](KNOWN_ISSUES.md)**,
severity-ordered, each with a reproduction and the suite that pins it. Every
entry there was independently reproduced before being written down; several
plausible claims from the review did not survive that and were dropped.

**38 findings: 7 high, 14 medium, 17 low.** Two thirds came from the
behavioural QML component suites, which is the argument for having them.

The high ones:

- **`PasswordBox.fail()` does not re-mask.** A user who reveals their password
  and then gets it wrong leaves it painted in the clear on the lock screen
  until they type or cancel — `LockscreenSurfaceView.qml:99-101` is the whole
  failure path and never calls `clear()`.
- **`FunctionGraph` draws one gridline per integer of domain, uncapped.** A
  wide enough domain never returns from the first repaint, which with
  `Canvas.Immediate` is a multi-second freeze per keystroke.
- **`Paths.cacheHome`** writes the drun cache where the next session will not
  read it.
- **`PrintersLib`** drops every `1setOf` attribute from real IPP output.
- **`MenuLib.guardLine`** emits `if { true;; }` for a config-authored trailing
  `;`, which breaks the guard answer for *every* row, because the guards are
  batched into one run.
- **`HyprlandEditorCli`** writes 15 lines to stderr on the usage path, so a
  caller keying on the documented one-line stdout cannot tell a usage error
  from a launch that never happened.

The suite records what it found rather than only what it asserts. `t_note`
lines carry a surprising-but-correct behaviour with its reason, and the suites
pin each known defect as it currently is, with a comment saying why it is
wrong, so a fix turns a suite red and forces the record to be updated instead
of passing silently.

`shell/README.md` also documents several results that have drifted and are now
measured rather than assumed — the lint warning total (167, not 173), the
`unresolved-type` list (5, not 4; `AuthFlow` is missing from it), the weather
icon set (16, not the 15 two files claim) and the `ImageExts` table size (22,
not 21). The full list is in `KNOWN_ISSUES.md` section 16.
