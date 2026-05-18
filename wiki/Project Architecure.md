# Overview

Vibranium is not a traditional dotfiles repository, nor a desktop environment, nor an installer-and-forget script. It is an **opinionated, self-managing runtime** that sits alongside Hyprland and provides a unified interface for controlling a Wayland desktop.

This article explains how Vibranium fits together conceptually.

## What Vibranium really is

At its core, Vibranium is a Bash library plus a collection of scripts that share that library. These scripts are:

- **Keybinding targets** — bound directly in [`binds.lua`](https://github.com/shvedes/vibranium/blob/master/default/hypr/binds.lua) and called by Hyprland when you press a sequence of keys
- **Custom [Waybar](https://github.com/alexays/waybar) modules** — run on a timer or signal and emit JSON status text
- **[Rofi](https://github.com/davatorium/rofi) menus** — configuration panels built with the `cfgr` framework
- **Core or auxiliary utilities** — install packages, apply themes, manage PWAs, get configs values, toggle configs values and so on

None of these components are daemons. Vibranium does not have a server process. It is entirely event-driven: a keybinding fires, a script runs, the script finishes. This makes Vibranium as lightweight as possible, while keeping wide range of customization.

## The three-tier library stack

Almost every script sources [`vb-lib-core`](https://github.com/shvedes/vibranium/blob/master/bin/vb-lib-core). Beyond that, scripts pull in additional libraries based on what they need:

```
vb-lib-core          (almost always sourced)
  |
  +-- vb-lib-cfgr    (sourced by cfgr-* and vb-menu-* scripts)
  |
  +-- vb-lib-hypr    (sourced by cfgr-wm-* scripts)
```

[`vb-lib-core`](https://github.com/shvedes/vibranium/blob/master/bin/vb-lib-core) is the single source of truth for:
- Sourcing user settings (`~/.config/vibranium/settings`)
- Sourcing the active theme's runtime vars (`vb-lib-theme`)
- Terminal I/O (prompts, spinners, header printing)
- The [rofi](https://github.com/davatorium/rofi) menu wrapper
- The settings validator ⭐ (`helpers::check`)
- Logging (`log::info`, `log::warn`, `log::error`)
- Hyprland utilities ⭐ (`hypr::flash::border`, `hypr::flash::screen`)

[`vb-lib-cfgr`](https://github.com/shvedes/vibranium/blob/master/bin/vb-lib-cfgr) builds on `vb-lib-core` to provide a declarative menu system. A script describes its menu contents using `cfgr::item::*` calls, and the library handles menu rendering, rofi interaction, and Vibranium settings.

[`vb-lib-hypr`](https://github.com/shvedes/vibranium/blob/master/bin/vb-lib-hypr) provides a typed interface to `hyprctl`, with batched reads via `hypr::fetch` and writes via `hypr::set`. It is used only by the WM configuration menus.

These three libraries are pretty much self-documented, so you could go and check the source code by yourself!

### The configuration pipeline

When you change a setting via the menus, the write path is:

```
User selects item in rofi
      |
cfgr::dispatch reads the dispatch descriptor
      |
cfgr::toggle_bool / cfgr::set_digit / cfgr::set_string
      |
sed -i edits ~/.config/vibranium/settings
      |
Optional hook function runs (e.g. restart a service)
      |
cfgr::run re-sources settings and rebuilds the menu
```

The settings file is a plain shell script. On the next read of any setting, `helpers::check` validates and normalizes the value.

## The settings validation system

Settings defaults and metadata are defined in [`vb-core-defaults`](https://github.com/shvedes/vibranium/blob/master/bin/vb-core-defaults) using structured comments (`@type`, `@range`, `@values`). The [`vb-parse-defaults.awk`](https://github.com/shvedes/vibranium/blob/master/awk/vb-parse-defaults.awk) parses this file into associative arrays that `helpers::check` uses for validation.

The metadata is lazy-loaded on the first call to `helpers::check` and cached in global arrays for the lifetime of the process. Every subsequent validation reuses the same parsed data.

This design means you can add a new setting by annotating it in `vb-core-defaults`; the validator picks it up automatically without any code changes.

## The menu system

Configuration menus are built with the `cfgr` library's declarative API. Each menu is a small script that defines a `_build` function and calls `cfgr::run`. The library handles the event loop:

```
cfgr::run loop:
  source settings file  (pick up any changes from other menus)
  helpers::check        (validate required variables)
  clear item arrays
  call _build()         (populate item arrays via cfgr::item::* calls)
  cfgr::build_menu()    (align columns, normalize bool display)
  helpers::ui::menu()   (show rofi, wait for selection)
  cfgr::dispatch()      (route to toggle/picker/action based on type)
  repeat
```

Because `_build` is called on every iteration, the displayed values always reflect the current, up-to-date state of present options.

## Runtime directories and state

Vibranium's runtime state is spread across four XDG-compliant locations:

| Location                      | Purpose                                                  |
| ----------------------------- | -------------------------------------------------------- |
| `~/.config/vibranium/`        | User configuration, active theme, user themes            |
| `~/.local/state/vibranium/`   | Persistent state (brightness, wallpaper, update channel) |
| `~/.cache/vibranium/`         | Ephemeral cache (e.g. logs)                              |
| `$XDG_RUNTIME_DIR/vibranium/` | Session-scoped mostly lock files                         |

The installation itself lives at `~/.local/share/vibranium/` (a Git repository that is never modified at runtime except by explicit [`vb-update`](https://github.com/shvedes/vibranium/blob/master/bin/vb-update) calls).

## What vibranium does not do

- It does not replace Hyprland's config system; it extends it by managing a set of sourced fragments.
- It does not manage dotfiles for every application on your system; it themes a specific curated set.
- It does not have an undo/history system for settings changes.
- It does not isolate the user from the underlying tools (pacman, hyprctl, wpctl, etc.); you can always use them directly.
