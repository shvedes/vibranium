# Overview

Originally, Vibranium had its own theme architecture and mechanism for applying themes, built around a "quality over quantity" philosophy. The idea was simple: fewer themes, but each one polished to a high standard. This worked, but creating even a single theme required a significant amount of time and effort.

On top of that, each theme depended on third-party GTK themes. Since their development was outside of my control, this made the system somewhat unreliable.

This changed in `v0.7.0`, where Vibranium introduced an Omarchy-like theme system, with several important differences. To understand those differences, it helps to first look at how Omarchy works.

When you choose a theme, the switcher copies the entire theme directory into the current theme folder, then applies user overrides (if any) on top of it. While this works, the main downside is the copy process itself, especially for wallpapers.

A theme can include many wallpapers, and image files are significantly larger than typical config files. As a result, the switching time depends heavily on the size of the `backgrounds/` directory. This may even explain why Omarchy themes tend to include only a small number of wallpapers.

Vibranium approaches this differently by using symbolic links (`cp --link`) specifically for the `backgrounds/` directory, while still copying other files normally so they can be overridden by user configs.

## How does it work

When you select a theme (`CTRL + ALT + T`), `vb-theme-set` performs the following steps:

- Cleans up `~/.config/vibranium/current/*`, which stores the active theme and its state
- Copies the selected theme into `~/.config/vibranium/current/theme/*`
- If user overrides exist in `~/.config/vibranium/themes/<selected_theme_name>`, applies them on top of the current theme
- **Automatically generates** themes for *GTK*, *Qt*, *Obsidian*, *Hyprlock*, and more
- Restores the last used wallpaper from a state file (or falls back to the default if it doesn't exist)
- Live-updates already running applications (if supported)

For more details, see the source code of [`vb-theme-set`](https://github.com/shvedes/vibranium/blob/master/bin/vb-theme-set).

## Omarchy theme support


Vibranium supports Omarchy themes, but not all of them.

In `v3.3.0`, Omarchy introduced template-based theme generation using Base16 colors via a `colors.toml` file. This is what makes compatibility possible.

As mentioned earlier, Vibranium is built from scratch and differs from Omarchy in several areas, including application choices. For example, Omarchy uses [Walker](https://github.com/abenz1267/walker) as its launcher, while Vibranium uses rofi.

Because of this, Omarchy themes typically do not include configs for tools used by Vibranium (such as `rofi.rasi`). By providing a `colors.toml`, a theme gives Vibranium enough information to generate the missing configs automatically. This applies not only to rofi, but to any component where the two systems differ.

## Generating themes from templates

In addition to Omarchy-style [`colors.toml`](https://github.com/basecamp/omarchy/blob/dev/themes/tokyo-night/colors.toml), Vibranium provides an extended format: [`colors-extended.toml`](https://github.com/shvedes/vibranium/blob/master/themes/nightfox-nightfox/colors-extended.toml).

This format includes:
- 3 shades for each color (`green`, `red`, `blue`, `purple`, `pink`, `yellow`, `orange`, `cyan`, `black`, `gray` and `white`)
- 6 background shades
- 5 foreground shades
- 3 accent colors

Combined with template files, this allows generating high-quality themes from a **single** template.

Vibranium supports both Omarchy templates and its own extended format. These can coexist and complement each other.

For a full list of templates, see the [`themed`](https://github.com/shvedes/vibranium/tree/master/default/themed) directory.

If you don't like the default implementation of a template and want to override it, or just want to add your own template for an application, you can place them in `~/.config/vibranium/themed`.

> [!NOTE]
> Note that only HEX colors are supported by `colors-extended.toml`.

## The template generator

The idea originates from Omarchy, but the implementation has been significantly extended. While remaining compatible with basic Omarchy templates, Vibranium adds the following features:

- `{{ key_upper }}` -> `#1e1e2e` -> `#1E1E2E`
- `{{ key_lower }}` -> `#1E1E2E` -> `#1e1e2e`
- `{{ key_0x }}`:
  - `#1e1e2e` -> `0x1e1e2e`
  - `#1e1e2ecc` -> `0x1e1e2ecc`
- `{{ key_r }}` -> `#1e1e2e` -> `30`
- `{{ key_g }}` -> `#1e1e2e` -> `30`
- `{{ key_b }}` -> `#1e1e2e` -> `46`
- `{{ key_rgb }}` -> `#1e1e2e` -> `30,30,46`

In addition to the above, templates support inline color calculations via a pipe syntax. See the section below for full details.

For implementation details, see [`vb-theme-set-templates`](https://github.com/shvedes/vibranium/blob/master/bin/vb-theme-set-templates).

## Inline color calculations

Vibranium templates support inline color calculations directly within placeholder keys. This is primarily useful when only `colors.toml` is available, since that file provides only the 16 base colors without tints, shades, or semantic variants. Rather than leaving the output looking flat, templates can derive the missing colors on the fly from the base palette.

The syntax extends any existing key with one or more pipe-separated operations:

```
{{ key_<format>|operation=value|operation=value }}
```

The base key before the first `|` must be a valid key as it appears in the substitution table — format suffix included. Plain `{{ key }}` keys (raw hex) also work. Operations are applied left to right, and the result is emitted in the same format as the base key.

### Available operations by format

**HEX** — keys like `{{ background_0 }}`, `{{ color4_strip }}`, `{{ color4_upper }}`, `{{ color4_0x }}`

| Operation | Value | Description |
|---|---|---|
| `alpha` | `0.0` – `1.0` | Appends a two-digit hex alpha byte to the color |
| `lightness` | `0.0` – `1.0` or signed | Sets or shifts HSL lightness; see below |

**RGB** — keys ending in `_rgb`, e.g. `{{ background_0_rgb }}`

| Operation | Value | Description |
|---|---|---|
| `alpha` | `0.0` – `1.0` | Appends alpha as a literal float fourth channel |
| `red` | `+N` / `-N` | Offsets the red channel by N (0–255), clamped |
| `green` | `+N` / `-N` | Offsets the green channel by N (0–255), clamped |
| `blue` | `+N` / `-N` | Offsets the blue channel by N (0–255), clamped |
| `lightness` | `0.0` – `1.0` or signed | Sets or shifts HSL lightness; see below |

**HSL** — keys ending in `_hsl`, e.g. `{{ background_0_hsl }}`

| Operation | Value | Description |
|---|---|---|
| `lighten` | `N` | Increases lightness by N percentage points, clamped to 100 |
| `darken` | `N` | Decreases lightness by N percentage points, clamped to 0 |
| `saturate` | `N` | Increases saturation by N percentage points, clamped to 100 |
| `desaturate` | `N` | Decreases saturation by N percentage points, clamped to 0 |
| `hue` | `+N` / `-N` | Rotates the hue by N degrees; wraps around 360 |

### The `lightness` operation

The `lightness` operation works on both HEX and RGB keys and operates in two modes depending on whether the value carries a sign:

- **Absolute** (`lightness=0.75`): sets the HSL lightness to exactly that ratio, where `0.0` is black and `1.0` is white. Useful for generating a specific tint regardless of the source color.
- **Relative** (`lightness=+0.15`, `lightness=-0.10`): shifts the current lightness by that amount. Useful when you want any color to appear slightly lighter or darker without knowing its exact L value ahead of time.

In both cases the color is round-tripped through HSL, so hue and saturation are preserved.

The HSL format uses different operation names for the same concept (`lighten`/`darken`) and accepts integer percentage points rather than a float ratio, since the stored value is already `h,s,l`.

### Number format

Values are parsed by AWK's standard numeric coercion. Both `0.20` and `.20` are accepted, so `lightness=+.15` is equivalent to `lightness=+0.15`. Integers work the same way: `alpha=1` is treated as `1.0`.

### Order of operations

Operations are applied strictly left to right. The order only matters when two operations affect the same channel or the same color space. For example:

```
{{ color4_rgb|lightness=0.8|blue=-30 }}
```

This sets lightness to 80% first (rebuilding RGB from HSL), then subtracts 30 from the resulting blue channel. Reversing the order would subtract 30 from the original blue first and then discard it during the HSL rebuild — producing a different result. As a rule: apply channel offsets (`red`, `green`, `blue`) after `lightness` if you want them to survive.

### Practical examples

Generating a semi-transparent overlay background in a CSS-like config:

```
background-color: {{ background_0_rgb|alpha=0.85 }};
```

Lightening an arbitrary accent color for a hover state:

```
hover-color: {{ color4|lightness=+0.15 }};
```

A tint variant for a border, always at a fixed light level regardless of theme:

```
border: 2px solid #{{ color4_strip|lightness=0.75 }};
```

A 0x-prefixed color for a compositor rule, brightened:

```
col.active_border = {{ color4_0x|lightness=+0.12 }}ff
```

An RGBA string for a notification background with a blue tint:

```
background = {{ background_0_rgb|blue=+18|alpha=0.92 }};
```

Rotating the hue of a base color for a complementary accent:

```
accent-alt: hsl({{ color4_hsl|hue=+180 }});
```

### Cautions

**Achromatic colors are hue-neutral.** Pure greys (saturation = 0) have no meaningful hue. Lightness operations on grey work correctly, but `hue` rotation and `saturate` on an HSL key have no visual effect because both H and S are zero for those colors.

**Hex variants preserve their format.** If you use `{{ color4_strip|lightness=+0.15 }}`, the output is bare hex without a `#` — the same format the plain `{{ color4_strip }}` key would have produced. The same applies to `_upper` (uppercased result) and `_0x` (result prefixed with `0x`). Combine with care if the target config expects a specific prefix.

**Unknown keys are left verbatim.** If the base key does not exist in the substitution table — for example because `colors.toml` does not define it — the entire `{{ ... }}` token is left unchanged in the output rather than replaced with an empty string. This makes errors visible rather than silently producing broken configs.

**`alpha` on a HEX key appends a byte, not a channel.** The result is an 8-character `#rrggbbaa` string. If the target config does not understand 8-character hex (e.g. some older GTK config formats), this will break it.

**Operations outside their format are silently ignored.** Writing `{{ background_0_hsl|alpha=0.5 }}` does nothing, because `alpha` is not defined for HSL keys. The color is still substituted — just without the operation applied.

---

Instead of placing all themes in a single flat menu, Vibranium organizes them into families.

If a theme, such as *Catppuccin* or *Gruvbox*, provides multiple variants like *Macchiato*, *Frappé*, or *Gruvbox Hard*, a single entry with the family name is shown. Selecting it reveals all available variants.

Themes without variants, such as *Ristretto* or *Evergarden*, are treated as standalone and appear directly in the top-level menu alongside theme families.

This approach keeps the menu clean, avoids clutter, and scales well as more themes are added.

# Further reading

- [Omarchy's template generator](https://github.com/basecamp/omarchy/blob/dev/bin/omarchy-theme-set-templates)
- [Vibranium themes folder](https://github.com/shvedes/vibranium/tree/master/themes)
- [Omarchy themes folder](https://github.com/basecamp/omarchy/tree/dev/themes)
