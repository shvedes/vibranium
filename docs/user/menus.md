# The Vibranium menu

Press ++ctrl+alt+v++ (or the `Tools` key if your keyboard has one) and the Vibranium menu appears — the main entry points of the whole system. If the app launcher is Vibranium's front door, this is the control room.

## What's in it

| Entry | What it does |
|---|---|
| **Settings** | Every settings submenu in the system hangs off this |
| **Install** | Install packages, themes, fonts, webapps, TUIs |
| **Remove** | Remove packages, themes, fonts, webapps, TUIs |
| **Update** | Update Vibranium, system, AUR, themes |
| **Tweaks** | Complimentary system/apps tweaks |
| **Setup** | Optional [setup wizards](setup.md) |
| **Help** | Scoped help / wiki pages, full keybindings list |

!!! note
    In a VM, the **Setup** entry is hidden — none of those wizards make sense on virtual hardware.

## Settings, submenu by submenu

| Submenu | What you'll find |
|---|---|
| **Idle** | Lock/sleep timeouts, inhibit type |
| **Audio** | Volume step, visual/audio feedback, loopback ("hear my voice") |
| **Waybar** | Toggle modules on/off, position, appearance |
| **General** | General options, update channel |
| **Set Font** | Change the system font from a list of installed fonts |
| **Hyprland** | The WM itself: appearance, input, keyboard layoyts, advanced options |
| **Recording** | FPS, quality, container, codec, framerate mode, audio capture |
| **Brightness** | Step size and notification behavior |
| **Night Light** | The hyprsunset-based screen temperature controls |
| **Screenshots** | File type, JPEG quality, flash effects, annotation, cursor capture |
| **App Launcher** | Launcher behavior: icons, webapps, auto-select, search engine, PWAs |
| **Color Picker** | HEX preview, history size, notifications |
| **Media Control** | Fade duration, "now playing" on unlock, album art |
| **Power Profiles** | Which profile on AC, which on battery |
| **Miscellaneous** | Cursor theme, default browser, user wallpapers, environment editor, and more |

!!! tip "Some menus may be hidden based on machine type"
    Some submenus may be unavailable on specific hardware type.
    For exmaple, **Power Profiles** is hidden on desktop systems because there's no AC/battery cycles possible.

## Help

**Vibranium Menu** -> **Help** -> **Keybindings** shows every keybinding Hyprland is currently aware of, including your own custom ones from
`~/.config/hypr/hyprland.conf.d/binds.lua`, not just the defaults. It's a searchable list, which is far nicer than `hyprctl binds` in a terminal.
Use `vb-cmd-keybindings --list` to see this list in the terminal window.
