#!/bin/bash
# =============================================================================
# user-menu.d/example.sh -- user menu override for Vibranium
# =============================================================================
#
# What this does
# --------------
# Files in this directory are sourced at the end of a menu's _build()
# function, inside the cfgr::run loop. Any cfgr::item::* calls they
# contain are appended to the menu's item list -- same API, same
# behaviour as the built-in entries.
#
#
# How to activate
# ---------------
# Rename (or copy) this file to match a built-in menu script name, then
# replace the example items with your own. The file is sourced when the
# menu opens; no restart or daemon reload needed.
#
#   File name              Menu it extends
#   ---------------------  -----------------------------------------------
#   vb-menu.sh             Vibranium main menu (top-level)
#   vb-menu-utilities.sh   Utilities submenu
#   vb-menu-tweaks.sh      Tweaks submenu
#   vb-menu-setup.sh       Setup submenu (hardware config)
#   vb-menu-recording.sh   Recording submenu
#   vb-menu-emoji.sh       Emoji picker menu
#   cfgr-menu.sh           Settings hub
#   cfgr-audio.sh          Audio settings
#   cfgr-brightness.sh     Brightness settings
#   cfgr-general.sh        General settings
#   cfgr-idle.sh           Idle settings
#   cfgr-launcher.sh       App launcher settings
#   cfgr-misc.sh           Miscellaneous settings
#   cfgr-nightshift.sh     Night light settings
#   cfgr-player.sh         Media player settings
#   cfgr-power-profile.sh  Power profile settings
#   cfgr-recording.sh      Recording settings
#   cfgr-screenshots.sh    Screenshot settings
#   cfgr-waybar-menu.sh    Waybar settings hub
#   cfgr-waybar-module.sh  Waybar module settings
#   cfgr-wm-menu.sh        Hyprland settings hub
#   cfgr-wm-appearance.sh  WM appearance settings
#   cfgr-wm-input.sh       WM input settings
#   cfgr-wm-advanced.sh    WM advanced settings
#   cfgr-color-picker.sh   Color picker settings
#
#
# Example: adding a simple action
# --------------------------------
# Each line adds one menu row. Rows appear in the order they are
# registered. The examples below are commented out; uncomment the ones
# you want.
#
#   --label  what the user sees in the menu
#   --func   what runs when selected (function name or shell command)
#   --icon   optional icon name rofi can resolve. Use vb-* names
#            (from Vibranium's theme) or any standard icon name
#            from installed themes (Papirus, Adwaita, etc.)
#
#   cfgr::item::action --label "My Tool" --func "my-tool; helpers::ui::close_menus" --icon vb-tools
#
# When the command launches a GUI app or terminal, end it with
# "; helpers::ui::close_menus" so the menu chain closes immediately
# after launching. Without it the menu stays open until Escape.
#
# Some built-in menus (vb-menu, vb-menu-setup) define a shorter
# _die() alias. This file does not define it because not every menu
# script does. Use the full name for portability.
#
#   cfgr::item::action --label "System Monitor" \
#     --func "xdg-terminal-exec -- btop; helpers::ui::close_menus" --icon vb-console
#
#   cfgr::item::action --label "Calculator" \
#     --func "xdg-terminal-exec -- bc -l; helpers::ui::close_menus" --icon vb-calc
#
#
# Item types
# ----------
#
#   cfgr::item::action  --label "Label" --func "command; helpers::ui::close_menus" [--icon ICON]
#     Runs a function or shell command. Use for submenus, launchers,
#     terminal commands, or any custom action.
#
#   cfgr::item::bool  --var VAR_NAME --label "Label" [--hook HOOK] [--icon ICON]
#     Toggle for a boolean setting in ~/.config/vibranium/settings.
#     Displays current value (yes/no). Optional hook fires after toggle.
#
#   cfgr::item::digit  --var VAR --label "Label" --title "Title" --type int|float \
#       [--min N] [--max N] [--prompt "Hint"] [--icon ICON]
#     Numeric input with optional range validation.
#
#   cfgr::item::string  --var VAR --label "Label" --title "Title" \
#       --option "Pretty:value" [...] [--hook HOOK] [--icon ICON]
#     Select from a fixed list of choices.
#
#   cfgr::item::raw  "Display text" "dispatch_descriptor" [ICON]
#     Full manual control. Display text is sent to rofi as-is;
#     dispatch descriptor must match one of the internal formats.
#     Use when the displayed value comes from a getter function:
#
#       cfgr::item::raw \
#         "CPU temp : $(sensors -j | jq -r '...')" \
#         "action:_cpugov_menu"
#
#
# Submenu example
# ---------------
# Define a function that builds and runs its own menu, then register
# it as an action item. The function name must be defined in this file
# (it persists in the shell after sourcing).
#
#   _my_submenu() {
#     _b() {
#       cfgr::item::action --label "Item 1" --func "cmd1; helpers::ui::close_menus"
#       cfgr::item::action --label "Item 2" --func "cmd2; helpers::ui::close_menus"
#     }
#     cfgr::run "My Menu" "_b"
#   }
#   cfgr::item::action --label "My Submenu" --func "_my_submenu" --icon vb-tools
#
# The submenu inherits the parent's user-menu.d identity, so the same
# user files apply. Avoid recursive loops (a submenu loading itself).
#
#
# Icon reference
# --------------
# rofi resolves icon names through the XDG icon theme spec. Any name
# from any installed theme works. Vibranium icons (vb-*) are the
# default; you can also use names from Papirus, Adwaita, etc.
#
# To list available names from an installed theme:
#   find /usr/share/icons/$THEME -name '*.svg' | sed 's/.*\///;s/\.svg//' | sort -u
#
# Built-in vb-* names (used with --icon):
#
#   vb-settings   vb-install    vb-trash       vb-update
#   vb-tools      vb-help       vb-wm          vb-github
#   vb-arch-linux vb-keyboard   vb-package     vb-theme
#   vb-font       vb-console    vb-pwa         vb-volume
#   vb-video      vb-brightness vb-night-light vb-screenshot
#   vb-launcher   vb-music      vb-idle        vb-lock
#   vb-docker     vb-vm         vb-secure-boot vb-calc
#   vb-network
#
#
# Ordering
# --------
# Files are sourced in no guaranteed order (the existing _CFGR_ITEMS
# array order is the order of cfgr::item::* calls within each file).
# If you need multiple files, keep all items for one menu in a single
# file so you control the order.
#
#
# Troubleshooting
# ---------------
# - File not sourced? Check the name: it must exactly match the menu
#   script name with a .sh extension. The menu script name is the
#   file basename without directory path.
# - Item not showing? Open the menu from a terminal to see error
#   messages from cfgr::dispatch on stderr.
# - Functions defined in this file are available to submenus but not
#   persisted after the menu chain exits.
# - If you use cfgr::item::bool or cfgr::item::digit, the referenced
#   variable must exist in vb-core-defaults or be manually added to
#   ~/.config/vibranium/settings.
