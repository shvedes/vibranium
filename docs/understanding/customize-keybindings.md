# Customizing keybindings

Vibranium keybindings are defined using Hyprland's Lua configuration system.
The default bindings are stored inside the Vibranium installation directory.
These files are managed by Vibranium and **must not be edited directly**.  
Updates may overwrite them. User customization is done through override files.

## The override system

Hyprland loads its configuration through:

```text
~/.config/hypr/hyprland.lua
```

This file loads Vibranium defaults and then loads all Lua files from:

```text
~/.config/hypr/hyprland.conf.d/
```

This directory is intended for user modifications.

A default installation contains several example files:

```text
binds.lua
monitors.lua
window-rules.lua
input.lua
```

These files do not modify anything by default. They contain examples and documentation for available configuration options.  
Any additional `*.lua` file created inside this directory is loaded automatically.

## Adding a keybinding

Custom bindings are added with the same API used by Vibranium.

Example:

```lua
-- Open calculator with Super + C
hl.bind("SUPER + C", hl.dsp.exec_raw("vb-util-calc"))

-- Open btop with Super + Shift + B
hl.bind("SUPER + SHIFT + B", hl.dsp.exec_raw("vb-launch-tui -- btop"))
```

After saving the file, Hyprland reloads the configuration automatically.  
If automatic reload is disabled, reload manually from the Utilities Menu.

## Unbinding and replacing bindings

Adding a new binding does not automatically replace an existing one.  
If a key combination is already used, both bindings may execute.  
Remove the original binding first:

```lua
-- Remove the existing launcher shortcut
hl.unbind("SUPER + A")

-- Assign a new shortcut
hl.bind(
    "SUPER + A",
    hl.dsp.exec_raw("vb-launch-cmd -- firefox")
)
```
Bindings are processed in configuration order, so placement can matter.

## Viewing active bindings

The complete active keymap can be viewed from **Vibranium Menu -> Help -> Keybindings**, or:

```bash
vb-cmd-keybindings --list | less
```

Both methods show the final binds, including user overrides.

## Mouse bindings

Mouse bindings use the same API with the `mouse` option.

Example:

```lua
-- Move floating windows with Super + left mouse button
hl.bind(
    "SUPER + mouse:272",
    hl.dsp.window.drag(),
    { mouse = true }
)

-- Resize floating windows with Super + right mouse button
hl.bind(
    "SUPER + mouse:273",
    hl.dsp.window.resize(),
    { mouse = true }
)
```

## Common Lua API patterns

Most customizations use three basic operations:

| Pattern | Purpose |
|---------|---------|
| `hl.bind("MOD + KEY", action)` | Create a keybinding |
| `hl.bind("MOD + KEY", function() ... end)` | Run custom Lua code |
| `hl.unbind("MOD + KEY")` | Remove an existing binding |

Vibranium also provides helper wrappers under `Hypr.Guard.*`.  
These helpers prevent actions from running when required objects, such as windows or monitors, do not exist.  
The default configuration contains many examples of these patterns.

## Further reading

- [Hyprland binds documentation](https://wiki.hypr.land/Configuring/Basics/Binds/)
- [The Hyprland Lua config](../internals/hyprland-lua.md)
- [Keyboard shortcuts](../user/keybindings.md)
