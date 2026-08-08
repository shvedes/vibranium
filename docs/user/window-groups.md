# Window groups

A **window group** is a collection of windows that share the same screen space as a single window — the classic "tabs for your windows" pattern. Hyprland supports them natively, and Vibranium wires them up with sensible bindings.

> Related Hyprland wiki: [Group variables](https://wiki.hypr.land/Configuring/Basics/Variables/#group)

## Creating a group

Press ++super+g++ with a window focused.
The window is now in "group mode": you'll see a small indicator at the top of it.  
Open another window, and it locks in the same space, with the indicator showing it belongs to the group.

## Navigating

| Shortcut | Action |
|---|---|
| ++alt+j++ / ++alt+l++ | Focus left/right window |
| ++alt+1++ ... ++alt+0++ | Jump straight to the N-th window in the group |
| ++super+ctrl+shift+j++ / ++super+ctrl+shift+l++ | Move a window within the group (backwards/forwards) |

## Locking

A group can be **locked** so no new windows can join it.

Press ++super+ctrl+g++ to (un)lock.
When locked, the group's border changes to a blend of orange and red.
New windows you open will appear *outside* the group instead of joining it.

## Going further

The full group keybinding set is searchable: **Vibranium Menu** -> **Help** -> **Keybindings**, then type `group`.
You can also adjust group behavior in your Hyprland overrides (`~/.config/hypr/hyprland.conf.d/*.lua`).
