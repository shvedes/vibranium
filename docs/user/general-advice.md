# General advice

Some things are not configuration options or setup steps, but they make living with Vibranium and Arch Linux easier.

## Update your OS regularly

Read the [Project philosophy](../understanding/philosophy.md) first. Vibranium manages its own components, but the underlying Arch Linux system is still your responsibility.

Update Arch regularly instead of letting updates accumulate for months. Smaller, frequent updates are easier to understand and troubleshoot.

!!! warning "After a long gap"

    If your system has not been updated for a long time, check the [Arch Linux news](https://archlinux.org/) before upgrading. Important changes may require manual intervention.

## Learn Hyprland basics

Vibranium exposes many Hyprland options through graphical settings, but it does not replace understanding the compositor itself.

For advanced customization, the [Hyprland wiki](https://wiki.hypr.land/) is the primary reference.

Your custom configuration belongs in:

```text
~/.config/hypr/hyprland.conf.d/
```

Vibranium uses Lua for Hyprland configuration, and the included examples provide practical references for creating your own changes.

## Report problems

Vibranium is actively developed. If you encounter bugs, unexpected behavior, or have suggestions, report them through the project's [issue tracker](https://github.com/shvedes/vibranium/issues).

Feedback helps improve the project and identify problems that are difficult to reproduce.

## The main idea

Vibranium provides a working foundation, but the final system is yours.

Use the defaults, customize what you need, and treat the configuration as something you can understand and control.
