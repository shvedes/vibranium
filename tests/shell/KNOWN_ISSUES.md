# `tests/shell/KNOWN_ISSUES.md`

Defects and doc/code drift the test suite found. Every entry here was
**independently reproduced** before being written down, not taken on an agent's
word — several plausible claims did not survive that and were dropped.

This file is the actionable list. The suites themselves pin each behaviour as
it currently is, with a comment saying why it is wrong, so a fix turns a suite
red and forces the record to be updated rather than passing silently.

**37 findings: 6 high, 14 medium, 17 low.** Two thirds of them came from the
behavioural QML component suites (`suites/qml/`), which is the argument for
having them: the component layer is where the shell's user-visible contracts
live, and reading the source does not find a `fail()` that forgets to re-mask.

Severity is about *consequence*, not effort:

- **High** - loses user data, silently breaks a security boundary, or takes
  the shell down on ordinary input.
- **Medium** - a documented contract does not hold; the shell misbehaves in a
  way a user would notice and report as "weird".
- **Low** - dead code, a stale comment, or a gap that is self-consistent.

---

## High

### 1. `Paths.cacheHome` uses the application-scoped fallback

`shell/common/Paths.qml:23` falls back to `StandardPaths.CacheLocation`, which Qt
defines as *application*-scoped (`GenericCacheLocation + "/" + applicationName`).
`ConfigLocation` on line 22 is **not** app-scoped, so the config side is right
and only the cache side is wrong.

The same file documents the cache path as `$XDG_CACHE_HOME/vibranium/
druncache.json` at line 110. Observed with `XDG_CACHE_HOME` empty:

```
cacheHome      = /home/<user>/.cache/quickshell      (not /home/<user>/.cache)
drunCacheFile  = /home/<user>/.cache/quickshell/vibranium/druncache.json
```

**Consequence:** a session started without `XDG_CACHE_HOME` writes the drun
cache somewhere the next session — which has the variable set — will not read
it. The cache silently resets, and where it lands depends on the binary name.
`StandardPaths.GenericCacheLocation` is what line 23 wants.

*Reproduced by `suites/qml/paths-presence-test.sh`; pinned there with a note.*

### 2. `PrintersLib` drops every `1setOf` attribute from real IPP output

`shell/services/system/PrintersLib.js:22` parses attribute lines with

```js
/^\s+([a-zA-Z0-9-]+)(?: \(([A-Za-z-]+)\) )?= (.*)$/
```

`ipptool` prints a `1setOf` as `printer-state-reasons (1setOf keyword) = none`.
The type-token class `[A-Za-z-]+` excludes both the digit in `1setOf` and the
space in `1setOf keyword`, so the whole line fails to match and is skipped.

**Consequence:** on real output `printer-state-reasons`, `job-state-reasons`,
`marker-names` and `marker-levels` are always absent, so `markers()` always
returns `[]` and `printerLine()` can never append a reason. "Stopped - paused"
is unreachable from a live printer. No rows are lost, so this degrades rather
than breaks.

*Reproduced by `suites/js/services-calendar-weather.test.mjs`.*

### 3. `MenuLib.guardLine` emits a bash syntax error for a trailing `;`

`shell/features/menu/MenuLib.js:687` appends `;` unconditionally and does not
strip an existing one:

```
guardLine(u, t, "true")   =>  if { true; } >/dev/null 2>&1; then echo 'u:t:1'; ...
guardLine(u, t, "true;")  =>  if { true;; } >/dev/null 2>&1; then echo 'u:t:1'; ...
```

`if { true;; }` is rejected by bash. Because `buildGuardScript` batches **all**
guards into one run, a single such row breaks the guard answer for **every** row
in the menu.

**Consequence:** no shipped bundle has this, but `docs/user/menus.md` invites
users to author `when:` conditions by hand, and a trailing `;` is the obvious
thing to write.

*Reproduced by `suites/js/menu.test.mjs`.*

### 4. `HyprlandEditorCli` does not honour its own one-line stdout contract

`shell/common/settings/HyprlandEditorCli.js:8-13` states that every run writes
exactly one line to stdout — the resolved path, or `err: <message>` — and that
empty output means the command never ran. The usage path (lines 44-45, 62)
writes **15 lines to stderr and nothing to stdout**.

Verified: 0 stdout lines, 15 stderr lines for a no-argument run.

**Consequence:** a caller in Hyprland's config VM cannot observe a child exit
status, so it reads that one stdout line. A usage error is therefore
indistinguishable from a launch that never happened — the exact ambiguity the
line was written to remove.

*Reproduced by `suites/cli/hyprland-editor-cli-test.sh`.*

### 5. A failed unlock leaves the password in plain text on the lock screen

`shell/common/ui/PasswordBox.qml:44-51`. `fail()` calls `shake()` and restarts
the failure timer, and `clearFailure()` only stops the timer. Neither of them
drops `revealed`.

```
pw.text = "s3cret"; pw.revealed = true; pw.fail()
// on the next event-loop turn:
//   revealed  === true
//   echoMode  === 0  (TextInput.Normal)
//   the display row paints "s3cret" verbatim
```

**Consequence:** live. `features/lock/LockscreenSurfaceView.qml:99-101` is the
whole failure path (`onFailedAttemptsChanged: authBox.fail()`) and it does not
call `clear()`, so a password the user chose to reveal stays painted in the
clear after a wrong attempt, until they type or cancel. The polkit surface is
unaffected - `PolkitView.qml:117` calls `clear()`, and `clear()` does drop
`revealed`.

The one-line fix is for `fail()` to re-mask; the same finding says something
about the design, which is that `revealed` and `hidden` are two independent
flags for one piece of state, so any path that resets one and not the other
leaks.

*Reproduced by `suites/qml/textinput-test.sh`.*

### 6. `FunctionGraph` draws one gridline per integer of domain, uncapped

`shell/common/ui/FunctionGraph.qml:211`:

```qml
for (xi = Math.ceil(x0); xi <= Math.floor(x1); xi++) { ... stroke() }
```

One `beginPath`/`moveTo`/`lineTo`/`stroke` per **integer** in the x-range, with
no cap. Measured, scaling linearly:

| domain | strokes | startup |
| --- | --- | --- |
| 20 | 241 | 241 ms |
| 20,000 | 40,001 | 541 ms |
| 200,000 | 400,001 | 3,050 ms |
| 800,000 | 1,600,001 | 11,300 ms |
| 2,000,000 | 4,000,001 | never returns (killed at 15 s) |

With `renderStrategy: Canvas.Immediate` (`:179`) the repaint is synchronous with
`requestPaint()`, which fires on every `funcBody` keystroke, every `xMin`/`xMax`
change, every theme change and every DPR change. **In the running shell that is
a multi-second UI freeze per keystroke.**

The loop is also **non-terminating** for an infinite endpoint, which is worse
than slow: `Math.ceil(-Infinity) + 1 === -Infinity` in IEEE 754, so `xi` never
advances while `xi <= Infinity` stays true.

**Reachability:** latent. Both in-tree hosts (`LauncherEntry.qml:376-380` and
`ClipboardPreview.qml:315-319`) leave the domain at `[-10, 10]`, which is 21
strokes and free. It goes live the moment a host widens the domain.

*Reproduced by `suites/qml/calendar-graph-test.sh`, which keeps this as a live
regression test: it re-runs the probe with a wide domain under a timeout and
asserts the probe does *not* reach its sentinel. If anyone adds a cap, that
assertion flips to FAIL.*

---

## Medium

### 6. `ClipboardLib` mints unrecognisable `.svg+xml` snapshot files

`shell/features/clipboard/ClipboardLib.js:891-894` inverts a mime type into a
file extension by taking the subtype verbatim:

```
image/png      -> t123-1.png
image/jpeg     -> t123-1.jpeg
image/svg+xml  -> t123-1.svg+xml     <-- no such extension anywhere
```

`isImageExt("svg+xml")` is `false`, `mimeForExt("svg+xml")` falls back to
`image/png`, and `extIconName` returns `""`. The row still gets the right icon
because `buildTitleSub` reads the mime, but a re-copy routed through the
extension would be typed PNG.

*Reproduced by `suites/js/clipboard.test.mjs`.*

### 7. `UnitLib` cannot parse an inch source using the `in` keyword

`splitExplicit` (`shell/features/launcher/UnitLib.js:283-286`) receives only the
text *after* the number, so `"5 in cm"` arrives as `" in cm"` — the only keyword
is the leading `in`, leaving an empty head, and `tryConvert` returns `null`.

```
tryConvert("5 in cm")        => null
tryConvert("5in in cm")      => { ok: true, value: 5, ... }
tryConvert("5 in to cm")     => { ok: true, value: 5, ... }
tryConvert("5 inches in cm") => { ok: true, value: 5, ... }
tryConvert("1in")            => { ok: true, value: 1, ... }
```

**Consequence:** `"5 in cm"` is the most natural spelling of the unit the
header explicitly discusses, and it is the one that does not work.

*Reproduced by `suites/js/math-calc-color.test.mjs`.*

### 8. `CalcLib` treats a signed number as a calc query, hiding the app list

`shell/features/launcher/CalcLib.js:13-14, 28` — the quick-reject charset
`^[0-9+\-*/%^().\s]+$` admits `-`, and the "must look like an expression" test
is satisfied by a leading sign.

```
isPotentialCalc("42")   => false   (correct: documented intent)
isPotentialCalc("-42")  => true    (typing a negative number hides every app)
```

The header states the operator requirement exists so that "typing a number does
not hide every application match."

*Reproduced by `suites/js/math-calc-color.test.mjs`.*

### 9. `isBrowserPlayer` checks the wrong variable on its identity branch

`shell/common/NowPlaying.js`:

```js
if (n.indexOf("chrome") >= 0 && d.indexOf("instance") >= 0)
```

`n` is the identity, `d` the dbus name. The first half tests `n` for `chrome`
but the second half tests `d` for `instance` — almost certainly meant to be `n`.

```
isBrowserPlayer("org.mpris.MediaPlayer2.instance5", "Chrome")  => true   (wrong)
isBrowserPlayer("org.mpris.MediaPlayer2.foo", "Google Chrome") => false (wrong)
isBrowserPlayer("...chrome.instance1", "Google Chrome")        => true   (right, via the preceding line)
```

**Consequence:** latent today, because real Chromium dbus names match the
preceding line first. A browser whose identity is a display name and whose
dbus name is not `chrome` is not filtered out of the MPRIS player list.

*Reproduced by `suites/js/bar-models.test.mjs`.*

This defect used to be recorded against two files: `common/NowPlaying.js` and
an unimported partial copy at `features/bar/modules/NowPlaying/Model.js`, which
is since deleted. One fix in one place is now enough.

### 10. `BarLib.rebuildZoneOrder` silently duplicates a slot

`shell/features/bar/BarLib.js:271-298` — the leftover branch appends a raw
`ordered` entry even when that id was already emitted, so an `ordered` set
shorter than the movable set produces a repeat:

```
rebuildZoneOrder([a,b,c], ordered=[a,b,c], ...) => ["a","b","c"]   correct
rebuildZoneOrder([a,b,c], ordered=[c,a],   ...) => ["c","a","c"]   duplicated
```

`renderLayout` has no dedupe pass, so a duplicated id renders twice. Nothing
enforces that `ordered` is exactly the movable set.

*Reproduced by `suites/js/bar-models.test.mjs`.*

### 11. `lastSampleFor` and `filterPackages` throw on a null collection

Both read `.length` / `.name` on their argument with no guard, while their
siblings in the same files tolerate a missing argument:

```js
lastSampleFor(null, "x")     // TypeError: Cannot read properties of null
filterPackages([null], "x")   // TypeError: Cannot read properties of null (reading 'name')
filterPackages(pkgs, undefined) // silently filters for the string "undefined"
```

`ArchUpdates/Model.js:58` has no nullish guard on `query` at all, so
`filterPackages(pkgs, undefined)` returns `[]` as if the user had typed
`"undefined"`.

**Consequence:** the header for these modules explicitly justifies the guards
elsewhere — "a delegate mid-teardown, a model swap" — so an unguarded read
here takes the bar module down with it.

*Reproduced by `suites/js/bar-models.test.mjs`.*

### 12. `PathPolicy` echoes `LEXICAL` instead of the requested verb

`shell/common/path/PathPolicy.js:45-46` and its README both state that `mode`
"names the requested verb and is echoed". In code, `allowed()` (line 187) and
`denied()` (line 299) both set `mode: LEXICAL`, and no other field carries
`options.mode`. `PathPolicy.qml:_project` does not forward it either.

**Consequence:** a caller cannot read back which verb it asked for, and two
different verbs produce byte-identical results.

*Reported by `suites/js/path-process-runtime.test.mjs`, recorded as a skip
there with the exact discrepancy.*

### 13. `Registry` treats a prototype key as a registered service

`shell/common/bus/Registry.qml:50, 62` — the `!target` guard cannot fire for a
name that resolves on the prototype chain:

```js
Registry.call("constructor", "toString")  // returns a string, not null
Registry.register("__proto__", obj)       // reparents the map instead of keying it
```

`register("__proto__", obj)` also makes `Object.keys` — the same accessor
`offers()` reads — blind to the name, so every miss then resolves against the
registered object until the next `register()` rebuilds the map.

**Consequence:** every caller in the tree checks for a `null`/`true` sentinel,
so that sentinel is unreachable for such a name. Latent only because no service
is named after a prototype key.

*Reproduced by `suites/qml/registry-bus-test.sh`, which also records that
`Bus.publish` has no id guard where `Registry.register` does, so `publish(7, …)`
and `publish("7", …)` are the same topic.*

---

## Low

### 14. `Ui.tint` / `Ui.solid` have an unreachable fallback

`shell/common/ui/Ui.qml:133` branches on `Theme.color(key) === undefined`, but
`Theme.color` ends in a fallback map and returns a string for every input — an
unknown key comes back as `#000000`, not `undefined`. The `"transparent"` arm is
therefore dead in the running shell.

*Reproduced by `suites/qml/ui-test.sh`.*

### 15. `FuncLib` documents `pix` as supported implicit multiplication

`shell/common/math/FuncLib.js:26` lists `pix` in the implicit-multiplication
examples. It fails at two layers: the standalone-`x` regex rejects the trailing
`x`, and `tokenize` reads the letter run as one word and throws
`unknown function: pix`. The same rule correctly rejects `xterm`, so the gate is
right and the documented example is stale.

*Reproduced by `suites/js/math-calc-color.test.mjs`.*

### 16. Stale counts and lists in the shell's own documentation

Measured, not assumed — each of these is asserted against the real value by a
suite, so the drift is visible in the test output:

| Claim | Says | Is | Asserted by |
| --- | --- | --- | --- |
| `shell/README.md:183` | 173 lint warnings | **167** | `suites/static/qmllint-test.sh` |
| `shell/README.md:185` | 4 unresolved types | **5** (`AuthFlow` missing from the list) | `suites/static/qmllint-test.sh` |
| `shell/services/weather/Model.js:429` | 15 weather icons | **16** (`weather-rain` missing) | `suites/js/services-calendar-weather.test.mjs` |
| `shell/assets/icons/README.md:143` | 15 weather icons | **16** | `suites/static/assets-test.sh` |
| `common/text/ImageExts.js:8` | a 21-entry table | **22** | `suites/js/text.test.mjs` |
| `shell/README.md` (activation table) | 5 modes | **6** (`settings` accepted by the gate) | `suites/qml/unitgate-test.sh` |
| `services/system/ipptool/README.md:25` | 3 variables | **4** (`$subid` undocumented) | `suites/static/ipptool-test.sh` |
| `shell/assets/README.md` | cites `tests/run-all.sh`, `tests/shell.d/*` | none of those existed | `suites/static/assets-test.sh` |

### 17. Eleven shipped icons are referenced by nothing

`hypr-animations`, `hypr-decoration`, `hypr-dim`, `hypr-gaps`, `hypr-glow`,
`hypr-layout-dwindle`, `hypr-layout-master`, `hypr-layout-scrolling`,
`hypr-shadow`, `hypr-touchpad`, `power-balanced`.

Ten are the themed-`hypr/` settings set, of which only `hypr-blur` is selected
(by `features/annotations/AnnotationEditor.qml:148`). The eleventh,
`power-balanced`, is not selected by
`features/bar/modules/PowerProfile/PowerProfile.qml:56-57`. None has a
provenance row, so the icons README's own "every new icon needs a provenance
row" rule was never applied to that directory.

Separately, ten provenance rows name icons that are not on disk
(`apps`, `battery-4`, `battery-5`, `color-picker`, `droplett`, `inhibitor`,
`network-storage`, `nightlight`, `notifications-off`, `power-saver`), and the
battery row says `0,1,3,4,5` while disk has `0,1,2,3`.

**Recorded rather than failed:** wiring the `hypr/` set up and deleting it, or
fixing the battery row and renaming the files, are decisions about the product
rather than facts for a test to assert.

*Measured by `suites/static/assets-test.sh`.*

### 18. Undeclared, redundant and untested helpers

- `shell/features/bar/modules/Volume/Model.js:33-37` — the prefix regex is
  `/^built-?in audio\s+/i`, where the optional character is the **hyphen**, not
  the space, so `"built in audio x"` is not stripped. The source comment is
  accurate; only a reader would assume otherwise.
- `shell/features/bar/modules/Volume/Model.js:105` — `Math.round(volume * 100)`
  with a bare `=== 0`, so a tiny negative volume rounds to `-0` and reports
  "Silenced" while `-0.5` reports "Quiet".
- `common/NowPlaying.js:94-96` — `endedNaturally` is `pos >= len - 4`, so any
  track of 4s or less is *always* natural. A one-second skip in a five-second
  track reads as an auto-advance and stays silent.
- `shell/common/settings/UnitIpc.js` was the one `.pragma library` in the tree
  no suite read; it is now covered by `suites/js/modules-wallpaper.test.mjs`.

*All recorded by the JS suites that own the files.*

---

# QML component findings

These came from the behavioural QML suites, which construct real components in
a live Quickshell and drive them across event-loop turns. They are numbered
from 19 so the numbering the earlier sections established stays stable.

## Medium

### 19. `List.qml` ignores `wrap: false` and wraps anyway

`shell/common/ui/List.qml:657` computes `i = (i + dir + count) % count`
unconditionally, so the clamp at `:689` can only fire after the scan has
visited every index - which, given the scan skips non-selectable rows, happens
only when nothing in the list is selectable.

```
wrap: false, 8 rows, currentIndex = 0, move(-1)
// expected: no move, cursor stays 0
// actual:   returns true, cursor = 7
```

The header at `:35-36` and `:647` both promise a clamp.

The second half of this finding is fixed: `move()` from an unseated cursor
(`currentIndex = -1`) computed `(-1 - 1 + 8) % 8 = 6`, landing a row short of
the top end, while `GridList.moveCell` and `moveRow` both special-cased that
state (`GridList.qml:154`, `:174`). `move()` now enters from the end the key
travels toward - row 0 going down, the last row going up - which is what any
consumer that starts its cursor unset (an island table painting the selection
bar) needs on its first keypress.

**Latent:** no consumer sets `wrap: false` today - `grep 'wrap:'` finds only
the declaration.

*Reproduced by `suites/qml/list-test.sh`.*

### 20. `List.restoreAt()` writes the cursor onto a non-selectable row

`shell/common/ui/List.qml:789-799`. The request is clamped, the scan loop at
`:790-796` only reassigns `i` when it finds a selectable row, and `:799` then
writes the clamped request unconditionally - discarding the scan.

```
isSelectable: () => false, 6 rows, restoreAt(4, 0)
// expected: cursor untouched, which is what settle() does in the same situation
// actual:   currentIndex = 4
```

The highlight bar paints a row that cannot be selected, and `move()` returns
`false` from there, so the cursor is stuck for the rest of the session.

*Reproduced by `suites/qml/list-test.sh`.*

### 21. `Calendar.stepMonth` discards input while the slide is in flight

`shell/common/ui/Calendar.qml:82` returns early while `root._sliding` is set,
and `_sliding` is only cleared by `monthSlide.onFinished` after `Ui.fastMs`
(120 ms).

```
from 2024/8: stepMonth(1) x3, stepMonth(-12), stepMonth(0)  in one turn
// expected: the view moves by -9 months
// actual:   exactly one step lands. viewMonth 8 -> 9 and stays 9
```

**Consequence:** two chevron clicks inside 120 ms, a fast wheel scroll, or key
repeat advance the calendar by one month with no feedback at all. The guard
drops the pending delta rather than coalescing it - a one-line fix.

*Reproduced by `suites/qml/calendar-graph-test.sh`.*

### 22. `InputField.revealed` does not consult `revealable`

`shell/common/ui/InputField.qml:237-238`:

```qml
echoMode: root.revealed ? TextInput.Normal : (root.sensitive ? TextInput.Password : root.echoMode)
```

There is no `root.revealable` term, so `sensitive: true, revealable: false,
revealed: true` unmasks the field.

**Honest severity: not reachable from user input.** The only two paths to
`revealed` are the eye `MouseArea` (`eyeButton.visible: root.revealable`, so it
takes no clicks) and the Ctrl+H branch, which is itself gated on
`revealable`. It is reachable only from a consumer binding, so this is a
hardening gap in a shared primitive rather than a live exposure -
`root.revealed && root.revealable` would close it.

*Reproduced by `suites/qml/textinput-test.sh`.*

### 23. `Calendar.viewMonth` is a writable int with no normalisation

`shell/common/ui/Calendar.qml:31-32` declares `viewYear`/`viewMonth` as plain
ints. `monthGrid` compares `cellMonth === month` against the raw value, so an
out-of-range month makes **every one of the 42 cells report `inMonth: false`** -
the whole grid renders in the dimmed neighbouring-month colour and the selected
day has no highlight, while the title (which goes through
`Qt.formatDate(new Date(2024, 12, 1), ...)`) reads "January 2025" beside a
`viewYear` of 2024.

```
viewMonth: 12   -> reads 12, viewYear 2024, grid is 2024-12-30..2025-02-09, 0 cells in month
viewMonth: -1   -> reads -1, grid is 2023-11-27..2024-01-07, 0 cells in month
```

**Latent:** only `stepMonth`/`selectDay` write the view and both go through
`CalendarLib.stepMonth`, which rolls the year correctly (verified in both
directions). This is one host assignment away.

*Reproduced by `suites/qml/calendar-graph-test.sh`.*

### 24. The password glyph model logs one warning per character of every secret

`shell/common/ui/PasswordBox.qml:286` binds a delegate to
`passwordInput.text[index]` while the ListModel row count is trimmed separately
by `syncModel()` (`:243-247`, driven by a `Connections` at `:255-261`). Every
departing glyph produces an `Unable to assign [undefined] to QString` warning.
The probe counts 11 for a `set / shorten / clear` sequence, one per character.

**Consequence:** nothing stale is painted - the delegates die in the same frame
- but the shell wipes passwords routinely (`LockscreenSurfaceView.qml:112`,
`PolkitView.qml:117`), so a session journal records **the length of every secret
that was ever on screen**. Fix: carry the character in the model
(`append({ ch: ... })`, then `text: model.ch`) or guard the index.

*Reproduced by `suites/qml/textinput-test.sh`.*

## Low

### 25. `InputField.clear()` does not emit `edited`

`shell/common/ui/InputField.qml:117-119` assigns `input.text = ""` and emits
nothing, while the clear affordance at `:370-374` assigns the same string *and*
emits `root.edited("")`. `InputField.qml:158` documents `edited()` as the
consumption path ("Panels simply listen to edited()"), so a consumer mirroring
the field through that signal goes stale on every `clear()`.

*Reproduced by `suites/qml/textinput-test.sh`.*

### 26. `PasswordBox.busy` paints a border and does nothing else

`shell/common/ui/PasswordBox.qml:100-103` is its only use. With `busy: true`,
`enabled` and `input.readOnly` are unchanged and keystrokes and Enter still
land. Both in-tree call sites also bind `enabled` to the same state
(`PolkitView.qml:210`, `LockscreenSurfaceView.qml:373`), which is what actually
gates - so this is a false-friend name on a security component rather than a
hole.

*Reproduced by `suites/qml/textinput-test.sh`.*

### 27. A no-op `List.seatTo()` leaves a stale pursuit claim armed

`shell/common/ui/List.qml:507` returns early for an already-reached target
*before* the `_followIdx`/`_pursuitIdx` reset at `:515-516`. `pursue()` reads
exactly those claims (`:913`, `:937`) to decide whether a running tween is its
own, so a claim surviving a no-op seat can let a pursuit re-aim a tween it does
not own. `_seatEpoch` is still bumped, which is the part the deferred-retry
guard relies on.

*Reproduced by `suites/qml/list-test.sh`.*

### 28. `FunctionGraph._niceStep` lets `Infinity` through

`shell/common/ui/FunctionGraph.qml:88`: `raw = Infinity / 6`, the guard
`!(raw > 0)` does not fire on `Infinity`, `mag` becomes `Infinity`, `norm`
becomes `NaN`, and the result is `Infinity` rather than the documented
degenerate-span fallback of 1. The caller then computes
`Math.ceil(y0 / Infinity) = 0`, so the effect is one gridline and no crash.
Unreachable today because `yMin`/`yMax` come from FuncLib's percentile range
over samples already clipped to |y| <= 1e6. Every other degenerate span is
correct: 0 -> 1, -1000 -> 1, NaN -> 1.

*Reproduced by `suites/qml/calendar-graph-test.sh`.*

### 29. `Ui.tint`'s and `Icons.url`'s "pending binding" guards are unreachable

Both the same shape, one layer apart: each guards on a lookup returning
`undefined`, and each lookup answers every key - including `""` and unknown
names - from a fallback map.

- `shell/common/ui/Ui.qml:133` - `tint`/`solid` branch on
  `Theme.color(key) === undefined`; `Theme.color:47-67` returns `#000000` for
  an unknown key. (Finding 14.)
- `shell/common/theme/Icons.qml:101` and `:111` - the two "keeps the binding
  pending" guards cannot fire, so `colorKey: ""` and an unknown `accentKey`
  both yield a fully-formed data URL with the glyph painted in the `#000000`
  fallback.

Neither is a visible bug today, but both are comments promising a state the code
cannot reach, which is how a future reader wastes an afternoon.

*Reproduced by `suites/qml/ui-test.sh` and `suites/qml/ui-rest-test.sh`.*

---

# IslandHost and IconButton findings

### 30. `IslandHost`'s first size evaluation grows instead of snapping

`shell/common/ui/IslandHost.qml:262-266`. The comment promises "a snap instead
of a grow: the window then maps at its final size", but the first open does not
do that.

```
show() a content declaring islandContentWidth 300 / islandContentHeight 140
  first event-loop turn:  card.height 37.9, card.opacity between 0.4 and 1
  nine turns later:       card.height 140
```

The width (which has no `Behavior`) is 300 immediately, so the card **grows
tall and narrow** while fading in - the window maps at the wrong size for the
duration of the tween. The control that proves it is the tween rather than a
bad expression: the same first open with `animationsEnabled = false` reports
height 140 and opacity 1 on the *same* turn. The `islandSelfAnimating` term of
the gate is equally ineffective on that first change; only the
`animationsEnabled` term is honoured.

A four-`Item` model with no shell code reproduces it, so this is a
`Behavior.enabled` first-change ordering effect. The comment's claim is simply
not what the code does.

*Reproduced by `suites/qml/host-button-test.sh`.*

### 31. A runtime `margin` change does not re-park the card

`shell/common/ui/IslandHost.qml:77` versus `:342-344`. `positionCard` reads
`root.margin` in both axes, but the only re-park triggers are
`onOpenChanged`, `onAnchorItemChanged` and `onBarPositionChanged` - there is no
`onMarginChanged` beside them.

```
open the island, then margin = 20 (from the Ui.s default of 8)
// expected: the card re-parks 12px further from the bar
// actual:   card.y stays 48 and card.x stays 8, including when margin is put back
```

The margin *is* a real term in the park - flipping `barPosition` at margin 20
lands y at 340, where at 8 it would be 352 - so the value is read, just not
observed as a trigger. No consumer sets `margin` at runtime today
(`BarView.qml:144-148` sets only `barPosition`), so the visible consequence is
nil.

*Reproduced by `suites/qml/host-button-test.sh`.*

### 32. A slot served by a shared `Component` is never frozen

`shell/common/ui/IslandHost.qml:157-163` with `:294-309`, against the frozen
footprint contract in the header at `:89-92`.

```
show(anchorShared, compTall) then show(anchorSharedTwin, compTall)
// expected per the header: a 220x90 entry for "shared-twin"
// actual: _frozenW("shared-twin") == 0 while the open card is 220x90,
//         and once the host closes, that card settles to 0x0
```

`show()` only assigns `contentComponent` when it differs (`:160`), and the
`Loader` keeps its item, so neither a content change nor a content size change
fires and `_saveFrozen` has nothing to hang off. Needs two slots sharing one
`Component`: the live card hides it, the closed card shows it.

*Reproduced by `suites/qml/host-button-test.sh`.*

---

# Findings from the bar-module, pass and wallpaper suites, and from the catalog and theme suites

### 33. The legacy settings monolith lacked an option four consumers read - RESOLVED

`default/vibranium/menus/settings.jsonc` was a second copy of the settings
catalog, and it did not declare `shell.osd.blockBrowsers`, which four
components read:

- `features/bar/modules/NowPlaying/NowPlaying.qml:17`
- `features/bar/modules/NowPlaying/NowPlayingIsland.qml:28`
- `features/lock/NowPlaying.qml:29`
- `services/media/MediaState.qml:48`

It was the documented fallback for a missing `_index.jsonc`
(`Settings.qml:578`), so on that path all four read `undefined`. It also
declared three options the split catalog had dropped -
`shell.statusbar.weatherMiddleClick`, `shell.volume.audioFeedback`,
`shell.volume.audioFeedbackVariant` - which nothing reads.

**Resolved.** The second copy is gone: the catalog lives in
`default/vibranium/settings/` and the stores read that directory or
nothing. A catalog that cannot be read now leaves the store with no
options and says why in the log, rather than quietly swapping in a
different option set. `Paths.settingsBundlePath` - the path the menu
opens to mean "the settings pages" - is the catalog's own
`_index.jsonc`.

*Reproduced by `suites/static/settings-catalog-test.sh`.*

### 34. Ten icon names the settings catalog declares resolve to nothing

`animation`, `apps`, `blur`, `glow`, `layout`, `mouse`, `scroll`, `shadow`,
`tools`, `view-grid`.

`Icons.url()` returns `""` for an unrecognised name (`Icons.qml:141`), so each
of these renders as a correctly sized blank with no warning - the same
silent-failure shape as finding 3. `main.jsonc` and `utilities.jsonc` are clean,
so the drift is specific to the settings catalog. Either the names are stale
options, or the icons were never shipped.

*Reproduced by `suites/static/settings-catalog-test.sh`.*

### 35. A signal-strength tier that no input can reach

`shell/features/bar/modules/Network/Model.js:16-23` and its `README.md:26-29`
both document tier `0 = whole glyph`, but the lowest branch is `s < 0.25 -> 1`.
**No input ever returns 0**; the reachable range is 1..4. So a zero-width signal
renders as a one-tier icon rather than the documented full glyph.

*Reproduced by `suites/js/modules-wallpaper.test.mjs`.*

### 36. Bluetooth section headers interleave on a mixed device list

`shell/features/bar/modules/Bluetooth/Model.js:94-105` (`sectionTitleFor`) and
`:124-139` (`listEntries`) both assume a paired-then-available ordering, but
`sortDeviceRows` tiers **connected first**. Given four rows spanning both
states, the headers interleave - one header per row rather than two.

Latent only: no caller passes one combined list (`BluetoothIsland.qml:108-116`
splits into two) and `listEntries` has no caller at all. The functions are
internally inconsistent, which is a trap for the first caller that tries.

*Reproduced by `suites/js/modules-wallpaper.test.mjs`.*

### 37. The pass browser surfaces an empty `.git` folder

`shell/features/pass/Model.js:72` filters a directory as
`f === ".git" || f.indexOf(".git/") === 0 || f.indexOf("/.git/") !== -1`. All
three shapes require a slash, so a `find` line reading `d a/.git` matches none
and the folder appears in the browser. Its *children* are filtered, so it reads
as an empty directory rather than being hidden.

*Reproduced by `suites/js/modules-wallpaper.test.mjs`.*

### 38. 107 of the 201 constructible types have never been built by any test

Under `QT_QPA_PLATFORM=offscreen` Quickshell loads **no `PanelWindow` backend at
all**, so any type that reaches a window cannot be constructed. The widest door
is `services/screenshots/Screenshots.qml:185`, which builds a `PanelWindow`
during singleton construction - and everything that touches it goes with it,
which is all of `qs.services` (18 entries) plus every feature that reads a
service.

That is one environmental fact with a very long reach, not 107 separate
problems. `suites/qml/construction-test.sh` now attempts all 201 and buckets
them: **94 clean, 86 needs-environment, 21 declared-but-uncreatable, 0 broken**.
The `broken` bucket being empty is the load-bearing result: there is no genuine
construction failure in the tree.

The 21 uncreatable types root at 14 x `PanelWindow`, 6 x `Variants` and
1 x `WlSessionLockSurface` - the last two are C++-registered too, they are simply
never used in a position `qmllint` flags, so `shell/README.md`'s list of four is
incomplete.

*Reproduced by `suites/qml/construction-test.sh`.*
