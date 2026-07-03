#!/bin/bash

if [[ "$CHASSIS_TYPE" == vm ]]; then
  exit 0
fi

if [[ -f "/etc/conf.d/wireless-regdom" ]]; then
  unset WIRELESS_REGDOM
  . /etc/conf.d/wireless-regdom
fi

if [[ ! -n ${WIRELESS_REGDOM} ]]; then
  if [[ -e "/etc/localtime" ]]; then
    TIMEZONE=$(readlink -f /etc/localtime)
    TIMEZONE=${TIMEZONE#/usr/share/zoneinfo/}

    # Some timezones are formatted with the two letter country code at the start
    COUNTRY="${TIMEZONE%%/*}"

    # If we don't have a two letter country, get it from the timezone table
    if [[ ! $COUNTRY =~ ^[A-Z]{2}$ ]] && [[ -f /usr/share/zoneinfo/zone.tab ]]; then
      COUNTRY=$(awk -v tz="$TIMEZONE" '$3 == tz {print $1; exit}' /usr/share/zoneinfo/zone.tab)
    fi

    if [[ $COUNTRY =~ ^[A-Z]{2}$ ]]; then
      helpers::append_once /etc/conf.d/wireless-regdom "WIRELESS_REGDOM=" "WIRELESS_REGDOM=\"$COUNTRY\""
    else
      helpers::log::warn "No configured timezone found"
      helpers::log::warn "Regulatory domain remains unchanged"
      sudo pacman -Rnsc --noconfirm wireless-regdb &>/dev/null
    fi
  fi
fi
