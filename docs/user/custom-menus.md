# Custom menus

Vibranium menus can be extended without modifying any built-in files.

Custom entries are added through shell scripts placed in `~/.config/vibranium/user-menu.d/`.  
They are appended after the built-in menu items and automatically become part of the corresponding menu.  
Built-in entries cannot be removed, replaced, or reordered.

## Getting started

The `user-menu.d` directory is created during installation and contains an `example.sh` file documenting the complete API with commented examples.
Each menu is extended by creating a file whose name matches the corresponding menu executable.  
For example, the main menu is implemented by `vb-menu`, so its extension file is:

```text
~/.config/vibranium/user-menu.d/vb-menu.sh
```

Changes take effect the next time the menu is opened. No restart or reload is required.

## Available menus

| File name | Extends |
|-----------|---------|
| `vb-menu.sh` | Main menu |
| `vb-menu-utilities.sh` | Utilities |
| `vb-menu-tweaks.sh` | Tweaks |
| `vb-menu-setup.sh` | Setup |
| `vb-menu-recording.sh` | Recording |
| `vb-menu-emoji.sh` | Emoji picker |
| `cfgr-menu.sh` | Settings |
| `cfgr-audio.sh` | Audio settings |
| `cfgr-brightness.sh` | Brightness settings |
| `cfgr-general.sh` | General settings |
| `cfgr-idle.sh` | Idle settings |
| `cfgr-launcher.sh` | App launcher settings |
| `cfgr-misc.sh` | Miscellaneous settings |
| `cfgr-nightshift.sh` | Night light settings |
| `cfgr-player.sh` | Media player settings |
| `cfgr-power-profile.sh` | Power profile settings |
| `cfgr-recording.sh` | Recording settings |
| `cfgr-screenshots.sh` | Screenshot settings |
| `cfgr-waybar-menu.sh` | Waybar settings |
| `cfgr-waybar-module.sh` | Waybar module settings |
| `cfgr-wm-menu.sh` | Hyprland settings |
| `cfgr-wm-appearance.sh` | Window manager appearance |
| `cfgr-wm-input.sh` | Window manager input |
| `cfgr-wm-advanced.sh` | Window manager advanced settings |
| `cfgr-color-picker.sh` | Color picker settings |

## Adding menu items

Menu entries are registered by calling helper functions.

The most commonly used item types are:

- **Action** — execute a command or function.
- **Boolean** — toggle a setting.
- **Number** — edit an integer or floating-point value.
- **Selection** — choose one value from a predefined list.

For example:

```bash
cfgr::item::action \
    --label "Open terminal" \
    --func "kitty; helpers::ui::close_menus"
```

or:

```bash
cfgr::item::bool \
    --var my_setting \
    --label "Enable feature"
```

The full API, including every supported item type and all available options, is documented in:

```text
~/.config/vibranium/user-menu.d/example.sh
```

## Creating submenus

Custom entries are not limited to individual actions. A menu entry can open another menu built entirely by your own code.

Submenus use the same API as built-in menus and can contain actions, settings, separators, and additional submenus.

See `example.sh` for a complete working example.

## Icons

Every item can optionally display an icon.

Vibranium ships with its own `vb-*` icon set, but any icon from an installed XDG icon theme can be used.

Examples:

```text
vb-settings
vb-tools
vb-theme
vb-network
vb-brightness
```

## Troubleshooting

If a custom menu does not appear:

- Verify that the file name exactly matches the menu executable.
- Open the menu from a terminal to see any error messages.
- Compare your code with the examples in `~/.config/vibranium/user-menu.d/example.sh`.
