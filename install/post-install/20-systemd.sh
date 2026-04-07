#!/usr/bin/env bash

_log_info "Setting up systemd units"

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
    UpdateSummary "Masked system service: ${service}"
  fi
done

for service in "${system_services[@]}"; do
  sudo systemctl -q enable "$service"
  UpdateSummary "Enabled system service: ${service}.service"
done

for service in "${user_services[@]}"; do
  systemctl -q --user enable "$service"
  UpdateSummary "Enabled user service: ${service}.service"
done

for timer in "${user_timers[@]}"; do
  systemctl -q --user enable "${timer}.timer"
  UpdateSummary "Enabled user timer: ${timer}.timer"
done

for service in "${masked_user_services[@]}"; do
  systemctl -q --user mask "$service"
  UpdateSummary "Masked user service: ${service}.service"
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
  cat >"$HOME/.config/systemd/user/${unit}.service.d/override.conf" <<'EOF'
[Unit]
StartLimitIntervalSec=1
ConditionEnvironment=XDG_CURRENT_DESKTOP=Hyprland
EOF
  UpdateSummary "Created override for ${unit}.service"
done
