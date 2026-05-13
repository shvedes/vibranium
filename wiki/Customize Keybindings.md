
# How to Customize Keybindings

Vibranium's keybindings are defined in `~/.local/share/vibranium/default/hypr/binds.conf` and loaded by Hyprland at startup. Because that file lives inside the Vibranium installation directory, you should not edit it directly - your changes will be overwritten on the next update.

Instead, use the user override mechanism described below.

---

## The override file

Hyprland's configuration is assembled from several sourced files. The entry point is `~/.config/hypr/hyprland.conf`, which sources the Vibranium defaults last. Any file you source *after* the defaults overrides them.

All your overrides live in `~/.config/hypr/hyprland.conf.d/*.conf`. Out of the box, you will find several files there, including `binds.conf`, `monitors.conf`, `window-rules.conf`, `input.conf`, and others.

By default, these files don’t change anything, so on startup Hyprland simply reads them and does nothing. However, they contain basic syntax overviews, live examples, and optional Vibranium settings that you can enable.

Any other file with the `*.conf` extension will be sourced automatically as soon as it is created or updated.

---

## Adding a new keybinding

In `binds.conf`, use the standard Hyprland `bind` syntax:

```
# Open a calculator with Super + C
bind = SUPER, C, exec, vb-util-calc

# Open btop with Super + Shift + B
bind = SUPER SHIFT, B, exec, vb-core-term --floating -- btop
```

### Unbinding

If your keybinding overrides one of Vibranium’s defaults, a single key press will trigger both actions: the default one and yours. Or maybe you just want to *unbind* a default keybinding. Here’s how:


```
# Let’s say you want to remap the app launcher from SUPER + A to SUPER + SPACE.

# 1. Unbind the existing keybinding:
unbind = SUPER, A

# 2a. Rebind it to a new key:
bindd = SUPER, SPACE, Open app launcher, exec, vb-core-launcher

# 2b. Or rebind the SAME key to a different action:
bind = SUPER, A, exec, my-cool-app

# Hyprland reads config files from top to bottom, which is important
# for understanding how bindings are applied.
```

As soon as you save the file, Hyprland will pick up the changes and reload automatically. If you have `disable_autoreload` enabled, you can reload Hyprland manually using the Utilities Menu (`CTRL + ALT + U`).

---

## View all current keybindings

There are two ways to do this.

First, open the *Vibranium Menu* (`CTRL + ALT + V`), go to *Help*, and select *Keybindings*. This will show all the keybindings Hyprland is currently aware of.

The second option is via the terminal. Run `vb-cmd-keybindings --list` to print all keybindings directly to the output. For easier navigation, you can pipe it into `less`: `vb-cmd-keybindings --list | less`.

---

## Mouse bindings

Mouse bindings use `bindm`:

```
# Move floating windows with Super + left mouse button
bindm = SUPER, mouse:272, movewindow

# Resize floating windows with Super + right mouse button
bindm = SUPER, mouse:273, resizewindow
```

---

## Further reading

- [Hyprland bind documentation](https://wiki.hypr.land/Configuring/Binds/) — full Hyprland bind syntax
