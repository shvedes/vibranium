# Cursor themes

Vibranium provides a single place to install and configure cursor themes.  
When a cursor theme is selected, Vibranium applies it consistently across the desktop and remembers the selection for future sessions.

## Installing a cursor theme

Before a theme can be selected, it must be installed.

Open **Vibranium Menu** -> **Install** -> **Package**, then install any cursor theme package, for example:

* `breeze-cursors`
* `bibata-cursor-*`
* `xcursor-*`

## Selecting a cursor theme

Open **Vibranium Menu** -> **Settings** -> **Misc** -> **Cursor theme**.  
The menu displays every installed cursor theme together with the available cursor sizes.  
Selecting a theme applies it immediately. Your selection remains active across reboots.

## What gets updated

Vibranium applies the selected cursor theme everywhere it is needed, including:

- GTK applications
- X11 applications
- Hyprland
- Desktop applications that use system cursor settings

This ensures that nearly all applications use the same cursor theme without requiring additional manual configuration.

!!! note
    Some legacy X11 applications may require a restart or a new login before they begin using the new cursor theme. This is a limitation of those applications rather than Vibranium.

## Listing installed themes

`vb-cursor-list` lists every installed cursor theme together with the cursor sizes they provide.  
This can be useful for scripting or for inspecting the available themes from the command line.
