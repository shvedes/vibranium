#!/usr/bin/env bash

_log_info "Setting up systemd units"

system_services=(
  "ly@tty1"
  "power-profiles-daemon"
)

user_services=(
  "waybar"
  "hypridle"
  "cliphist"
  "alacritty"
  "gnome-polkit"
)

if [[ "$CHASSIS_TYPE" != vm ]]; then
  system_services+=("bluetooth")
  user_services+=("hyprpaper" "hyprsunset")
fi

user_timers=(
  "vibranium-update"
)

masked_services=(
  "systemd-networkd-wait-online.service"
)

for service in "${masked_services[@]}"; do
  if systemctl -q is-enabled "$service"; then
    sudo systemctl -q disable "$service"
    sudo systemctl -q mask "$service"
  fi
done

for service in "${system_services[@]}"; do
  sudo systemctl -q enable "$service"
done

for service in "${user_services[@]}"; do
  systemctl -q --user enable "$service"
done

for timer in "${user_timers[@]}"; do
  systemctl -q --user enable "${timer}.timer"
done

override_services=(
  "waybar"
  "hyprpaper"
  "hypridle"
  "hyprsunset"
  "swyaosd"
  "alacritty"
  "cliphist"
  "gnome-polkit"
)

for unit in "${override_services[@]}"; do
  mkdir -p "$HOME/.config/systemd/user/${unit}.service.d"
  cat > "$HOME/.config/systemd/user/${unit}.service.d/override.conf" << 'EOF'
[Unit]
StartLimitIntervalSec=1
ConditionEnvironment=XDG_CURRENT_DESKTOP=Hyprland
EOF
done

masked_u_services=("at-spi-dbus-bus")

for unit in "${masked_u_services[@]}"; do
  systemctl -q --user mask "$unit"
done

UpdateSummary "Systemd: masked at-spi-dbus-bus user service (not needed in a wm environment)"
UpdateSummary "Systemd: masked systemd-networkd-wait-online to prevent boot delays"
UpdateSummary "Systemd: enabled system services (display manager, power profiles)"
UpdateSummary "Systemd: enabled user services (Waybar, idle daemon, clipboard, etc.)"
UpdateSummary "Systemd: enabled vibranium-update timer for automatic update notifications"
UpdateSummary "Systemd: created service overrides with Hyprland environment condition"
