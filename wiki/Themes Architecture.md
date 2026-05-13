# Overview

Originally, Vibranium had its own theme architecture and mechanism for applying themes, built around a "quality over quantity" philosophy. The idea was simple: fewer themes, but each one polished to a high standard. This worked, but creating even a single theme required a significant amount of time and effort.

On top of that, each theme depended on third-party GTK themes. Since their development was outside of my control, this made the system somewhat unreliable.

This changed in `v0.7.0`, where Vibranium introduced an Omarchy-like theme system, with several important differences. To understand those differences, it helps to first look at how Omarchy works.

When you choose a theme, the switcher copies the entire theme directory into the current theme folder, then applies user overrides (if any) on top of it. While this works, the main downside is the copy process itself, especially for wallpapers.

A theme can include many wallpapers, and image files are significantly larger than typical config files. As a result, the switching time depends heavily on the size of the `backgrounds/` directory. This may even explain why Omarchy themes tend to include only a small number of wallpapers.

Vibranium approaches this differently by using symbolic links (`cp --link`) specifically for the `backgrounds/` directory, while still copying other files normally so they can be overridden by user configs.

---

## How does it work

When you select a theme (`CTRL + ALT + T`), `vb-theme-set` performs the following steps:

- Cleans up `~/.config/vibranium/current/*`, which stores the active theme and its state
- Copies the selected theme into `~/.config/vibranium/current/theme/*`
- If user overrides exist in `~/.config/vibranium/themes/<selected_theme_name>`, applies them on top of the current theme
- **Automatically generates** themes for *GTK*, *Qt*, *Obsidian*, *Hyprlock*, and more
- Restores the last used wallpaper from a state file (or falls back to the default if it doesn't exist)
- Live-updates already running applications (if supported)

For more details, see the source code of [`vb-theme-set`](https://github.com/shvedes/vibranium/blob/master/bin/vb-theme-set).

---

## Omarchy theme support

> [!WARNING]
> Starting from Hyprland v0.55.0, Vibranium now supports only lua-compatible themes. While the old *hyprlang* is still there, Vibranium has already fully migrated to lua, making it impossible to use `.conf` files in lua runtime.

Vibranium supports Omarchy themes, but not all of them.

In `v3.3.0`, Omarchy introduced template-based theme generation using Base16 colors via a `colors.toml` file. This is what makes compatibility possible.

As mentioned earlier, Vibranium is built from scratch and differs from Omarchy in several areas, including application choices. For example, Omarchy uses [Walker](https://github.com/abenz1267/walker) as its launcher, while Vibranium uses rofi.

Because of this, Omarchy themes typically do not include configs for tools used by Vibranium (such as `rofi.rasi`). By providing a `colors.toml`, a theme gives Vibranium enough information to generate the missing configs automatically. This applies not only to rofi, but to any component where the two systems differ.

---

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

> [!NOTE]
> Note that only HEX colors are supported by `colors-extended.toml`.

---

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

For implementation details, see [`vb-theme-set-templates`](https://github.com/shvedes/vibranium/blob/master/bin/vb-theme-set-templates).

---
## Theme types

Instead of placing all themes in a single flat menu, Vibranium organizes them into families.

If a theme, such as *Catppuccin* or *Gruvbox*, provides multiple variants like *Macchiato*, *Frappé*, or *Gruvbox Hard*, a single entry with the family name is shown. Selecting it reveals all available variants.

Themes without variants, such as *Ristretto* or *Evergarden*, are treated as standalone and appear directly in the top-level menu alongside theme families.

This approach keeps the menu clean, avoids clutter, and scales well as more themes are added.


---
# Further reading

- [Omarchy's template generator](https://github.com/basecamp/omarchy/blob/dev/bin/omarchy-theme-set-templates)
- [Vibranium themes folder](https://github.com/shvedes/vibranium/tree/master/themes)
- [Omarchy themes folder](https://github.com/basecamp/omarchy/tree/dev/themes)