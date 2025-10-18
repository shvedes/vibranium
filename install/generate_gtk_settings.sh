#!/usr/bin/env bash

cat <<EOF > "$HOME/.config/gtk-3.0/settings.ini"
[Settings]
gtk-theme-name=Nightfox
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=Cascadia Code
gtk-cursor-theme-name=macOS
gtk-cursor-theme-size=22
gtk-toolbar-style=GTK_TOOLBAR_ICONS
gtk-toolbar-icon-size=GTK_ICON_SIZE_LARGE_TOOLBAR
gtk-button-images=0
gtk-menu-images=0
gtk-enable-event-sounds=1
gtk-enable-input-feedback-sounds=0
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintmedium
gtk-xft-rgba=rgb
gtk-application-prefer-dark-theme=1
EOF

cat <<EOF > "$HOME/.config/gtk-4.0/settings.ini"
[Settings]
gtk-theme-name=Nightfox
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=Cascadia Code
gtk-cursor-theme-name=macOS
gtk-cursor-theme-size=22
gtk-application-prefer-dark-theme=0
EOF
