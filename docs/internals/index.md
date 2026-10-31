# Internals

This section is currently empty — the documentation is being reworked.

Deep-dive material on Vibranium's internals (architecture, the cfgr engine, theme engine, installer, script conventions, contributing) will be published here in the future.

## Icons

Every themed icon in the shell — bar, menus, the launcher, clipboard,
lockscreen, islands and power menu — is a recolored SVG from the shipped set
(`shell/lib/Icons.qml` + `shell/assets/icons/`) — deliberately **not** font
glyphs, since user-selectable fonts make glyph coverage unreliable and the
shipped set is stylistically coherent. The recoloring contract, per-icon
provenance and the on-demand recolor pipeline are documented in
`shell/assets/icons/README.md`.

Every icon is rendered by a shared primitive (`shell/lib/Icon.qml`) instead
of per-widget `Image`/`IconImage` literals. Call sites pass `name` + `colorKey`
and either rely on the bar tokens (when drop-in slot chrome is wanted) or pass
an explicit `size` (menus, islands, panels).

Bar icons additionally size from a fixed slot/canvas pair:

- **Slot** (default 27px, `Ui.barIconSlot`) — the fixed outer hit/click
  target, so the hover/click area is identical across glyphs and bar modules
  size their pill from it.
- **Optical canvas** (default 16px, `Ui.barIconCanvas`) — the area the glyph
  actually paints in, centered inside the slot, so thin marks and full
  squares carry equal visual weight.
- **`Ui.barScaleWithFont`** (default on) — when set, slot and canvas
  multiply by `Ui.fontScale`, so the whole bar grows coherently with the
  shell font. `fontScale` currently defaults to 1 (Vibranium has no user
  font-size scaling yet); it is the single hook `Icon.qml` and
  `IconButton.qml` read.

### Device pixel ratio

`Icon.qml` rasterizes each SVG at `canvas * devicePixelRatio`:
`sourceSize` controls the texture resolution, and Qt applies the screen
scale factor to SVG rasterization **only** when `sourceSize` is unset. A
logical-sized texture would otherwise be stretched over the physical
pixels and stay permanently blurred (bilinear upscale, deterministic, not a
stale cache). The ratio is read from the item's own window
(`Window.window.devicePixelRatio`, the window `devicePixelRatioChanged`
notify re-rasterizes when a bar window moves to a different-scale screen).
At integer DPR the mapping is exact texel-per-pixel; at fractional scales a
1px edge may receive sub-pixel AA, which is the same mechanism that renders
text and is not a defect — do **not** pixel-grid-snap to "fix" it.

`IconButton.qml` is the same primitive with a press/border treatment and a
`clicked()` signal; it hosts an `Icon` in icon mode and keeps a text-glyph
mode for menu steppers.

### Debug switches

Set `VIBRANIUM_DEBUG_BAR_ICONS=1` to draw 1px transparent bounds over every
`Icon`: red for the outer slot (when tokens are in effect; matches the
explicit `size` otherwise), blue for the optical canvas (the painted
content). Handy when aligning or resizing icons.

## Hybrid rule for glyphs

Vibranium has no current need for inline icon glyphs inside text. If a case
appears where an icon must flow inline in a text label (a battery percentage
with a bolt glyph, a brand mark in a text-heavy menu row), follow this rule,
in order:

1. Prefer an existing glyph from the configured font before adding assets.
2. If a custom mark is truly required, generate a minimal private-use font
   from the SVG rather than growing per-case hacks, and record provenance in
   `shell/assets/icons/README.md` the same way every shipped icon already is.