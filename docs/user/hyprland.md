# Hyprland

Vibranium preconfigures parts of Hyprland and keeps those configuration files in its own installation directory.  
These files are considered internal and **must never be edited directly**.

## `hyprland.lua`

`hyprland.lua` is the first file loaded by Hyprland. In Vibranium it acts as a bootstrap file rather than a regular configuration file. It loads Vibranium's default configuration, shared Lua libraries, themes, and other internal components before any user configuration is applied.

**Never overwrite this file or remove its import logic.** All customizations should be made through the override mechanism described below.

## Changing Hyprland configuration

Most Hyprland settings can be changed without editing configuration files manually.

Open **Vibranium Menu** -> **Settings** -> **Hyprland**, where you'll find options for:

- **Appearance**

  - Gaps (including **smart gaps**)
  - Shadows
  - Blur
  - Corner rounding
  - Window dimming
  - Other visual options

- **Animations**

  - Built-in animation presets

- **Input**

  - Keyboard layouts
  - Mouse sensitivity
  - Other input-related settings

- **Advanced**

  - Less commonly used Hyprland options

Every setting changed through these menus is written to your own configuration files rather than applied only at runtime.  
Changes remain persistent across reboots, updates, and theme switches.  
The generated configuration is stored in `~/.config/hypr/hyprland.conf.d/`.

Depending on the setting, Vibranium updates files such as:

| File                | Purpose                                              |
| ------------------- | ---------------------------------------------------- |
| `look-and-feel.lua` | Gaps, shadows, blur, corner rounding, window dimming |
| `input.lua`         | Keyboard layouts and input settings                  |
| `advanced.lua`      | Advanced Hyprland options                            |
| `animations.lua`    | Active animation preset                              |
| `smart-gaps.lua`    | Smart gaps state                                     |

If you're curious how the settings work, open one of these files, change a setting from the Vibranium menu, then compare the file afterwards.

## Manual configuration

Hyprland processes configuration files from top to bottom.  
Vibranium loads all of its built-in `.lua` files first, then automatically loads every `.lua` file found in `~/.config/hypr/hyprland.conf.d/`.

Files are loaded in alphanumerical order. Since they are processed last, you can override any Vibranium setting simply by redefining it in one of these files.  
Some advanced configurations still require manual editing. For example:

- Writing custom Lua functions.
- Using new Hyprland features that Vibranium does not yet expose.
- Defining complex window rules or custom animation curves.

In those cases, either edit an existing file inside `hyprland.conf.d` or create a new one.  
Hyprland will automatically load it after reloading Vibranium through **Utilities** (++ctrl+alt+u++) -> **Reload Vibranium**.

## Animations

Vibranium includes several animation presets that can be selected from the settings.  
Each preset is a separate Lua file defining animation curves and where they are applied.   
The active preset is represented by a symbolic link named `animations.lua` inside `hyprland.conf.d`.

If this symbolic link is missing or broken, Hyprland falls back to its built-in default animations.  
Preset names are derived from their filenames.

### Adding custom animation presets

Custom animation presets can be added by creating the following directory if it does not already exist:

```text
~/.config/hypr/animations/
```

Create a new file named `<preset>.lua`, where `<preset>` becomes the preset's name in the settings menu, and define your animations there.
The official Hyprland [animation documentation](https://wiki.hypr.land/Configuring/Advanced-and-Cool/Animations/) is a useful reference.
After creating the file, ensure the Lua syntax is valid, then select the new preset from the Vibranium settings.
