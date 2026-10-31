# Wallpaper

Wallpapers in Vibranium are **per-theme** and handled natively by the shell's wallpaper service (`Wallpaper.qml`). The per-theme pointer is cached in `wallpaper.json`.

## Setting a wallpaper

**GUI way**:

1. Open the file manager (++super+e++)
2. Right-click any image
3. Choose **Set as wallpaper**

**CLI way**:

```bash
vb-shell wallpaper /path/to/your/beautiful_wallpaper.png
```

`vb-shell wallpaper` accepts `--next`, `--prev`, `refresh`, `get`, and a bare image path (which sets it). It routes every verb through the shell's wallpaper IPC handler.

## The wallpaper cycle

++ctrl+alt+w++ cycles to the next wallpaper of the active theme.
Your custom wallpapers are **included** in the cycle, alongside the theme's defaults — Vibranium merges the theme's `backgrounds/` folder with your own picks.

## Transitions

**Vibranium Menu** -> **Settings** -> **Wallpaper** (visible while the wallpaper is on):

- **Transition** — how the new wallpaper replaces the old one: instant cut, crossfade, a slide from a random edge, a slanted band sweeping from a random angle and origin, a circle that randomly grows or shrinks from anywhere, or a random pick per swap.
- **Transition speed** — Slow, Default or Fast. Every effect follows the preset; each keeps its own motion curve.

With animations disabled globally, swaps always cut instantly regardless of these options.

## Per-theme, on purpose

Wallpapers are stored **per theme**, by design. If you want the same custom wallpaper in a different theme, you set it again there.  
If you really want to reuse a wallpaper, the file sits in `~/.config/vibranium/themes/<theme>/backgrounds/` — just copy between themes.

> The [theme internals](../internals/theme-engine.md) page explains the structure.

## Managing your wallpapers

**Vibranium Menu** -> **Settings** -> **Misc** -> **User wallpapers** opens the management options:

- **Open the folder** — where your custom wallpapers live
- **Open** — open selected file
- **Delete** — remove custom wallpapers

## Tips

- The wallpaper is restored correctly after theme switches and on login — the state is tracked per theme, so switching back to a theme you used before brings back *its* wallpaper, not the last one globally.
- If the wallpaper setting is disabled in the general settings, the wallpaper service doesn't even start — no wasted resources.
