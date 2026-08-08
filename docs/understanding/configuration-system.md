# The cfgr menu system

Every settings menu in Vibranium — from **Vibranium Menu -> Settings** and all of its submenus — is powered by a single system: **cfgr** (*configure*).

The engine's internal implementation is documented separately in [The cfgr engine](../internals/cfgr-internals.md).  
This page focuses on how the system works and how to use it conceptually.

## The concept

cfgr provides a declarative way to create menus.  
Instead of manually handling menu rendering, input processing, validation, and setting changes, a menu script only describes its contents:

- what items exist
- what settings they control
- what actions they perform

The cfgr library handles:

- rendering through rofi
- reading and validating settings
- updating configuration values
- running hooks
- opening nested menus

## Menu structure

A cfgr menu consists of a `_build()` function and a call to `cfgr::run`.

Example:

```bash
_build() {
  cfgr::item::bool \
    --var VIBRANIUM_SCREENSHOT_FLASH_SCREEN \
    --label "Flash screen"

  cfgr::item::string \
    --var VIBRANIUM_RECORDING_QUALITY \
    --label "Quality" \
    --title "Recording quality" \
    --option "Medium:medium" \
    --option "High:high" \
    --option "Very high:very_high"

  cfgr::item::action \
    --func "cfgr-wm-menu" \
    --label "Hyprland" \
    --icon vb-wm
}

cfgr::run "Screenshots" "_build"
```

Each `cfgr::item::*` call adds one row to the menu.

## Item types

cfgr provides four primary item types:

| Type | Display | Behavior |
|------|---------|----------|
| `bool` | `Label : yes/no` | Toggles a boolean setting and optionally runs a hook |
| `digit` | `Label : value` | Opens an input prompt, validates the value, and writes it |
| `string` | `Label : current value` | Opens a selector containing predefined options |
| `action` | Action row | Runs a command or opens another menu |

## Menu lifecycle

cfgr rebuilds menus dynamically.

The basic flow is:

```
loop:
  load settings
  validate values
  clear previous items
  execute _build()
  display menu
  dispatch selected action
  repeat
```

Because `_build()` runs every iteration:

- displayed values always reflect the current configuration
- external changes are picked up automatically
- conditional menu entries work naturally

Example:

```bash
_build() {
  cfgr::item::bool \
    --var VIBRANIUM_VOLUME_USE_AUDIO_FEEDBACK \
    --label "Audio feedback"

  if [[ "$VIBRANIUM_VOLUME_USE_AUDIO_FEEDBACK" == "true" ]]; then
    cfgr::item::string \
      --var VIBRANIUM_VOLUME_AUDIO_FEEDBACK_VARIANT \
      --label "Sound variant" \
      --title "Select variant" \
      --option "Variant 1:variant1" \
      --option "Variant 2:variant2"
  fi
}
```

When audio feedback is disabled, the variant selector disappears on the next rebuild.

## Hooks

Some settings require additional actions after being changed.  
cfgr supports hooks that execute after the new value has been written.

Example:

```bash
cfgr::item::bool \
  --var VIBRANIUM_BAR_PACMAN_MODULE_ENABLE \
  --label "Updates module" \
  --hook "vb-refresh-waybar-module pacman"
```

The hook runs after the setting is updated, so it can immediately react to the new state.

Examples:

- restarting a service
- refreshing Waybar
- reloading a configuration
- applying a visual change

## Nested menus

Menus can open other menus.

A settings path such as:

```text
Settings -> Hyprland -> Appearance
```

is a chain of multiple cfgr menus.

An `action` item can launch another menu script, creating additional levels without special handling.

## Settings integration

cfgr works directly with Vibranium's settings system.

When a setting item is changed:

1. The value is validated.
2. The settings file is updated.
3. Any configured hook is executed.
4. The menu is rebuilt with the new state.

Settings are stored in:

```text
~/.config/vibranium/settings
```

The settings validation system is documented in [Settings & validation](settings.md).

## Mental model

cfgr is a declarative menu system for Vibranium.

A menu defines its rows and behavior. The library turns that definition into a working interface with:

- validation
- settings editing
- dynamic values
- hooks
- nested menus
- rofi rendering
