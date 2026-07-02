---
name: vibranium-themes
description: Theme system for Vibranium - structure, community themes, template engine
---

## Structure

Each dir in `themes/`:

| File | Purpose |
|------|---------|
| `colors-extended.toml` | 62-color palette: dim/normal/bright per hue, background_0-5, foreground_0-4, accent |
| `theme.info` | `FAMILY=`, `VARIANT=`, `LIGHT=true/false` |
| `neovim.lua` | LazyVim colorscheme config |
| `vb-lib-theme` | Pango color vars for notifs (optional, template-generated) |

`colors-extended.toml` format:
```toml
black_dim = "#1b2532"
black = "#202a37"
black_bright = "#26303d"
red_dim = "#c33c5e"
red = "#c94f6d"
...
background_0 = "#192330"
background_5 = "#5a6b84"
foreground_0 = "#cdcecf"
accent_dim = "#526f97"
accent = "#719cd6"
```

## Omarchy Community Themes

`vb-theme-install` pulls from GitHub. Strips vendor prefixes (`omarchy-`, `vibranium-`, `theme-`) from repo name. Checks for `colors.toml` (Omarchy base16) or `colors-extended.toml` (Vibranium). Both supported for backward compat.

Community themes -> `$XDG_CONFIG_HOME/vibranium/themes/`. `vb-theme-set` discovers from `$VIBRANIUM/themes/` (official) + user path. Populates `FAMILIES`, `STANDALONE_THEMES`, `THEME_LIGHT` assoc arrays.

## Template System

`default/themed/` uses Jinja-like placeholders. 2 variants per app:
- `.tpl` — base (Omarchy-compat), computes shades from 16 base16 colors
- `.extended.tpl` — Vibranium native, references named keys from `colors-extended.toml`

When `colors-extended.toml` exists in active theme -> extended templates take priority.

Placeholder ops (parsed by `awk`): `{{ var_lower }}`, `{{ var_strip }}`, `{{ var|lightness=+0.15 }}`, `{{ var|alpha=0.5 }}`, `{{ var_upper }}`, `{{ var_0x }}`, `{{ var_r/g/b }}`, `{{ var_rgb }}`, `{{ var_h/s/l }}`, `{{ var_hsl }}`, `{{ var_hwb }}`, `{{ var_w }}`.

`vb-theme-set-templates` pipeline:
1. Read `colors.toml` + `colors-extended.toml` -> flat key/value table
2. Walk user templates (`$XDG_CONFIG_HOME/vibranium/themed/`) first, then built-in
3. Extended wins over base when available
4. `force_template_files` in `settings.advanced` overrides theme-shipped files

Apps w/ templates: alacritty, btop, chromium, colors.css, dunst, gtk.css, hyprland, hyprlock, hyprtoolkit, neovim, obsidian, qtct, rofi, swayosd, vb-lib-theme (bash + lua), vscode, waybar, yazi, zathura.
