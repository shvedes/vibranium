# Waybar modules

Vibranium uses [Waybar](https://github.com/Alexays/Waybar) as its status bar.
Alongside the standard Waybar modules, Vibranium provides custom modules that integrate with its services, settings, and runtime state.
This page describes the available modules and how they behave.

## Available modules

Some modules are **state-based**. They only appear when the corresponding feature is active.

| Module | Visible when |
|--------|--------------|
| `recording` | A screen recording is active |
| `inhibitor` | A system sleep inhibitor is active |
| `timer` | A countdown timer is running |
| `reading-mode` | Reading mode is enabled |
| `nightshift` | Night light is enabled |
| `pacman` | Arch or AUR updates are available |
| `update` | A Vibranium update is available |
| `weather` | Enabled and initial data has been fetched |

Other modules are always available and provide direct interaction:

- **Color picker**
- **Power profile**
- **Clock**
- **Workspaces**
- **System tray**
- **Network**
- **Volume**
- **Microphone**
- **Battery**
- **Keyboard layout**

Standard modules are integrated with Vibranium where applicable.  
For example, volume changes update immediately and keyboard layout switching follows the configured layouts.

## Enabling and disabling modules

Modules can be managed from **Vibranium Menu -> Settings -> Waybar -> Toggle Modules**.
The module list is generated dynamically.

If a module configuration is removed from Waybar, its corresponding entry disappears from the settings menu automatically.  
Removed modules do not leave stale configuration entries behind.

## Dependency handling

Some custom modules require external command-line tools.

If a required dependency is missing, Vibranium detects it during module updates or Waybar restarts and displays 
a notification containing the missing dependency. This prevents silently broken modules.

## Weather module

The weather module requires enabling it through the Waybar settings.

On first activation, Vibranium detects the module and attempts to determine your location automatically using IP-based geolocation.

!!! note "Changing the city"

    The city can currently be changed manually only.

    Edit:

    ```text
    ~/.config/vibranium/settings
    ```

    and modify:

    ```bash
    VIBRANIUM_BAR_WEATHER_MODULE_CITY
    ```

    Then reload Waybar from the Utilities Menu.  
    Setting the value to `not_set` restores automatic location detection.

## Updates module

The updates module is disabled by default.

When enabled, it checks for available:

- Arch Linux updates
- AUR updates

The update check runs in the background through a systemd timer, so Waybar is never blocked while fetching package information.
The module displays the number of pending updates and provides a detailed breakdown in its tooltip.
If the combined Arch and AUR update count exceeds **125 packages**, Vibranium sends a reminder notification even if the Waybar module itself is disabled.

## Customization

Waybar configuration is stored in:

```text
~/.config/waybar/
```

Custom modules use standard Waybar `custom/*` module definitions with Vibranium-provided scripts.

The configuration files contain examples of:

- click actions
- update intervals
- signals
- custom execution scripts

The signal-based communication system is documented in:

[The Waybar protocol](../internals/waybar-protocol.md)
