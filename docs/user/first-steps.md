# First steps

After installation, reboot the system and log in using the **Hyprland (uwsm-managed)** session.  
The desktop is ready to use immediately, but a few minutes spent learning the basics will make navigation significantly easier.

## First login

During the first login, Vibranium performs several one-time initialization tasks, including:

- hardware-specific configuration
- automatic display scaling
- MIME type registration
- other system initialization tasks

These steps complete automatically in the background.

## Learn the essential shortcuts

Vibranium is designed around keyboard navigation.

The most commonly used shortcuts are:

- ++super+a++ — application launcher
- ++ctrl+alt+v++ — Vibranium menu
- ++ctrl+alt+u++ — Utilities menu
- ++super+return++ — terminal
- ++super+q++ — close the active window
- ++super+shift+s++ — capture a screen region

The complete shortcut reference is available on the [Keyboard shortcuts](keybindings.md) page.

## Open the Vibranium menu

Press ++ctrl+alt+v++ to open the main menu.

From there you can access:

- **Settings** — desktop and system configuration
- **Install** — packages, themes, fonts, TUIs, and web applications
- **Remove** — uninstall installed components
- **Update** — update Vibranium or the operating system
- **Tweaks** — optional system modifications
- **Setup** — configuration wizards
- **Help** — documentation and shortcut reference

Most configuration changes take effect immediately without requiring a logout.

## Take a screenshot

The default screenshot shortcuts are:

- ++super++shift++s++ — select a region
- ++super++shift++a++ — active window
- ++super++shift++z++ — entire screen

The standard ++print-screen++ key is also supported.  
Screenshots are saved to `~/Pictures/Screenshots` and copied to the clipboard automatically.

## Directory layout

The most important directories are:

| Path | Purpose |
|------|---------|
| `~/.config/vibranium/` | Your settings, themes, hooks, environment files, and more |
| `~/.local/share/vibranium/` | Vibranium installation files. **Do not modify this directory** |
| `~/.local/state/vibranium/` | Persistent application state. **Do not modify this directory** |
| `~/.cache/vibranium/` | Cache/log files |
| `~/.config/hypr/hyprland.conf.d/` | Your [Hyprland](hyprland.md) overrides |
| `~/.config/waybar/` | Your Waybar configuration |
