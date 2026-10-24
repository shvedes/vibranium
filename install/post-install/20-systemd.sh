#!/bin/bash

helpers::log::info "Setting up systemd units"

system_services=(
	"ly@tty1"
	"power-profiles-daemon"
)

user_services=(
	"vibranium-shell"
)

if [[ "$CHASSIS_TYPE" != vm ]]; then
	system_services+=("bluetooth")
	user_services+=("hyprsunset")
fi

user_timers=(
	"vibranium-update"
)

masked_user_services=("at-spi-dbus-bus")

for service in "${system_services[@]}"; do
	sudo systemctl enable "$service"
done

for service in "${user_services[@]}"; do
	systemctl --user enable "$service"
done

for timer in "${user_timers[@]}"; do
	systemctl --user enable "${timer}.timer"
done

for service in "${masked_user_services[@]}"; do
	systemctl --user mask "$service"
done
