#!/usr/bin/env bash

# Source: Omarchy
# Slightly adapted for Vibranium.

if [[ "$CHASSIS_TYPE" == vm ]]; then
  exit 0
fi

# First check that wireless-regdb is there
if [[ -f "/etc/conf.d/wireless-regdom" ]]; then
  unset WIRELESS_REGDOM
  . /etc/conf.d/wireless-regdom
fi

# If the region is already set, we're done
if [[ ! -n ${WIRELESS_REGDOM} ]]; then
  # Get the current timezone
  if [[ -e "/etc/localtime" ]]; then
    TIMEZONE=$(readlink -f /etc/localtime)
    TIMEZONE=${TIMEZONE#/usr/share/zoneinfo/}

    # Some timezones are formatted with the two letter country code at the start
    COUNTRY="${TIMEZONE%%/*}"

    # If we don't have a two letter country, get it from the timezone table
    if [[ ! $COUNTRY =~ ^[A-Z]{2}$ ]] && [[ -f /usr/share/zoneinfo/zone.tab ]]; then
      COUNTRY=$(awk -v tz="$TIMEZONE" '$3 == tz {print $1; exit}' /usr/share/zoneinfo/zone.tab)
    fi

    # Check if we have a two letter country code
    if [[ $COUNTRY =~ ^[A-Z]{2}$ ]]; then
      # Append it to the wireless-regdom conf file that is used at boot
      echo "WIRELESS_REGDOM=\"$COUNTRY\"" | sudo tee -a /etc/conf.d/wireless-regdom > /dev/null
      UpdateSummary "wifi: set up wireless regulatory domain based on /etc/localtime data"
    else
      _log_warn "No configured timezone found. Regulatory domain remains unchanged"
      sudo pacman -Rnsc --noconfirm wireless-regdb &> /dev/null
    fi
  fi
fi
