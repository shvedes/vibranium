# Wallpaper

Wallpapers in Vibranium are **per-theme** and handled by `vb-core-wallpaper` on top of [awww](https://codeberg.org/LGFae/awww).

## Setting a wallpaper

**GUI way**:

1. Open the file manager (++super+e++)
2. Right-click any image
3. Choose **Set as wallpaper**

**CLI way**:

```bash
vb-core-wallpaper /path/to/your/beautiful_wallpaper.png
```

`vb-core-wallpaper --help` shows the full options list.

## The wallpaper cycle

++ctrl+alt+w++ cycles to the next wallpaper of the active theme.
Your custom wallpapers are **included** in the cycle, alongside the theme's defaults — Vibranium merges the theme's `backgrounds/` folder with your own picks.

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
