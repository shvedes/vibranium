#!/bin/bash

LOGIND_CONF="/etc/systemd/logind.conf"

helpers::log::info "Configuring systemd"

# Don't let systemd handle hardware power button.
# Long press still shuts down the machine; it's being handled by firmware.
helpers::sed "$LOGIND_CONF" -E '/^#?HandlePowerKey=/s/^#//;/HandlePowerKey/s/=.*/=ignore/'
