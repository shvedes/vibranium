# menu

The summoned menu: one card, a stack of pages, and a single delegate that draws
every row type. `Menu` is the model (bundle loading, the page stack, the state
store, provider dispatch, search); `MenuView` is the window; `MenuPanel` is the
card; `MenuLib.js` is the pure layer underneath all three.

Three rules hold the module together, and most of the comments in the files are
about one of them:

1. **The card is sized from the model, never from its delegates.** Delegates are
   instantiated lazily, so a sum over the created set changes while scrolling.
   Width and height are both model-side rules: `MenuWidth` measures strings
   imperatively, `RowGeometry` turns a row's *kind* and *script* into a height
   with no measurement at all. A row whose copy the UI face draws takes the
   compact primary line; only a row that reaches a fallback face takes the
   taller one, so one Arabic title does not size the page.
2. **One rule, one file.** Row shape lives in `MenuLib.normalizeItem`, row
   height in `RowGeometry`, row width in `MenuWidth`, row rendering in `Entry`.
   A second copy of any of them is a copy that drifts.
3. **Providers overlay, they do not own.** A provider registered with
   `ProviderHost` answers for rows by id; what a hook's return value *means* is
   `MenuLib`'s value contract (`hookValue`, `hookBool`, `hookRan`), not the
   provider's.

## Files

| File | What it owns |
|---|---|
| `Menu.qml` | The singleton: bundle loading and extension merges, the page stack, the row state store, provider dispatch, search index and wiring. |
| `MenuView.qml` | The overlay window: screen-following placement of the card and the host for `MenuPanel`. |
| `MenuPanel.qml` | The card itself: row-set delivery, the fit trajectory and its history, slot claims, keyboard routing, frame persistence. |
| `MenuWidth.qml` | The card's width rule: shaping probes, the bounded shape cache, the trail reservation and the open-dropdown growth. |
| `RowGeometry.qml` | The row's token set as a singleton: the primary and fallback pinned line boxes from the theme's fonts, the per-row script selection, and the rule's entry points. |
| `RowRule.js` | The rest-height arithmetic itself: `colH`/`restH`/`restSeparator` over a token set, so the rule can be asked at any scale without a shell. |
| `Entry.qml` | The one list delegate, covering every row type: main line, trail cluster, dropdown slot, expansion slot. |
| `GridCell.qml` | The grid delegate: one cell, one glyph, no label. |
| `OptionRow.qml` | One option row inside a select's expansion (what `buildOptionsPage` builds a page of). |
| `NumberPicker.qml` | The inline numeric and range editor. |
| `InlineEditor.qml` | The inline text editor. |
| `MenuLib.js` | The pure layer: item/page normalization, search, staged flows, option geometry, keyboard routing, the provider value contract. Re-exports the guard emitters below. |
| `MenuGuard.js` | Guard emission: the one bash script answering every `when:`/`checked:`/`disabled:`/`requires:` expression, and the quoting its verdict tokens carry. |
| `MenuRow.js` | Row presentation: staged flows, the rest shape, the copy a stage overrides, the value slot and the inline dropdown's geometry. Re-exported by `MenuLib`. |
| `MenuLayout.js` | Grid composition: section-header weaving and the identity-stable chrome-slot pool. |
| `metadata.json` | Bundle metadata read by the loader. |
| `qmldir` | Module declaration for `qs.features.menu`. |
