# Overriding configs

Vibranium ships with sensible defaults for many parts of the desktop. The important thing to understand is that **your configuration is yours**.  
Most files inside `~/.config/` are normal user configuration files. You can edit them, replace them, or remove them without worrying about Vibranium updates overwriting your changes.
The only exceptions are files that are part of Vibranium's internal system, such as the installation itself, UWSM environment integration, and the Hyprland bootstrap configuration.

## The principle

```text
~/.config/<app>/             <- your configuration, editable
~/.local/share/vibranium/    <- Vibranium installation, managed internally
```

Vibranium copies its default configurations into your home directory during installation. After that, they become your files.  
Vibranium does not continuously manage or overwrite your changes.

## Internal files

Some files are intentionally managed by Vibranium and should not be edited directly.

### `~/.local/share/vibranium/`

This is Vibranium's installation directory. It contains the internal templates, scripts, and resources used by the system.  
Changes made here may be lost during updates.

### `~/.config/uwsm/env`

This file is managed by UWSM and Vibranium. It provides the session environment required for the desktop to start correctly.  
Do not edit it directly. Add personal environment variables through **Vibranium Menu** -> **Settings** -> **Misc** -> **Edit Env**.

See [Environment variables](environment-variables.md).

### `~/.config/hypr/hyprland.lua`

This is Hyprland's entry point in Vibranium.

It is a bootstrap file that loads Vibranium's internal configuration, Lua libraries, themes, and other components before user configuration is applied.  
Do not overwrite it or remove its import logic. Custom Hyprland changes should be made through `~/.config/hypr/hyprland.conf.d/`.

See [Hyprland](hyprland.md).

## Learning configuration syntax

If you want to customize an application manually, its documentation is usually the best reference.  
Many applications provide useful manual pages:

```bash
man dunstrc
man zathurarc
man rofi
```

For applications without detailed manual pages, refer to their official documentation online. 
Hyprland configuration is documented through the [Hyprland wiki](https://wiki.hypr.land/). Vibranium also keeps examples inside `~/.config/hypr/hyprland.conf.d/`.

## Resetting configurations

`vb-refresh-config` can restore Vibranium's default configurations.

It is intended as a recovery tool when:

- A configuration was damaged.
- You want to restore the original defaults.
- A configuration change caused unexpected behavior.

Before replacing files, it creates backups so your previous configuration can be recovered.  
A `--nuke` option is available for a complete reset. Use it carefully.  
Use `vb-refresh-config --help` for complete option list.
