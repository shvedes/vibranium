#!/usr/bin/env bash

helpers::log::info "Setting up systemd units"

system_services=(
  "ly@tty1"
  "power-profiles-daemon"
)

user_services=(
  "awww"
  "waybar"
  "cliphist"
  "alacritty"
  "gnome-polkit"
)

if [[ "$CHASSIS_TYPE" != vm ]]; then
  system_services+=("bluetooth")
  user_services+=("hyprsunset")
fi

user_timers=(
  "vibranium-update"
  "fetch-arch-updates"
)

masked_services=(
  "systemd-networkd-wait-online.service"
  "systemd-userdbd.socket"
)

masked_user_services=("at-spi-dbus-bus")

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

for service in "${masked_user_services[@]}"; do
  systemctl -q --user mask "$service"
done

override_services=(
  "awww"
  "waybar"
  "swayosd"
  "hypridle"
  "cliphist"
  "alacritty"
  "hyprsunset"
  "gnome-polkit"
)

for unit in "${override_services[@]}"; do
  mkdir -p "$HOME/.config/systemd/user/${unit}.service.d"
  vb::write_file "$HOME/.config/systemd/user/${unit}.service.d/override.conf" <<EOF
[Unit]
StartLimitIntervalSec=1
ConditionEnvironment=XDG_CURRENT_DESKTOP=Hyprland
EOF
done
