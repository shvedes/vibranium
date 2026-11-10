# Assets

Static assets shipped with the shell. QML reaches them through `Icons` and
through direct relative paths, so a path cited here is a path that exists.

## Layout

| Path | Contents |
| --- | --- |
| `icons/` | the SVG glyph root |
| `icons/README.md` | the per-icon provenance table |
| `battery/` | battery levels and charging |
| `file/` | file-type glyphs |
| `hypr/` | Hyprland setting glyphs |
| `player/` | media player glyphs |
| `weather/` | weather condition glyphs |

The resolver is `shell/common/theme/Icons.qml`; the file-type table it shares
with the file views is `shell/common/theme/FileIcons.js`. A glyph is walked
through as an example below, and the asset harness lives in
`tests/shell/run-all.sh` with this suite in
`tests/shell/suites/static/assets-test.sh` and the shipped manifest in
`shell/assets/icons/README.md`.

A condition glyph: `icons/weather/weather-clear-day.svg`.

## Conventions

Icons are 24x24 SVGs with a single `<svg>` root. `Icons` strips the document
and rewrites its paints to the theme tone at load time, so a glyph carries no
colour of its own. The battery set is contiguous (0..3 plus charging); a
missing level would read as a percentage with no glyph and no error.
