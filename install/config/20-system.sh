#!/bin/bash

helpers::log::info "Configuring system"

for entry in "$VIBRANIUM"/extras/etc/*; do
  [[ -e "$entry" ]] || continue
  helpers::copy "$entry" "/etc/${entry##*/}"
done

helpers::write_file /etc/modules-load.d/vb-ntsync.conf <<EOF2
# This file was created by Vibranium install scripts.
# ################################################## #
# Load ntsync driver for better gaming compatibility with Wine.
# More info: https://www.phoronix.com/news/Linux-6.14-NTSYNC-Driver-Ready
ntsync
EOF2

helpers::write_file /etc/modprobe.d/vb-blacklist.conf <<EOF2
# # This file was created by Vibranium install scripts.
# #################################################### #
# Disable hardware watchdog
blacklist sp5100_tco
blacklist iTCO_wdt
EOF2

helpers::write_file /etc/modprobe.d/vb-v4l-dkms.conf <<EOF2
options v4l2loopback exclusive_caps=1 card_label="Virtual Camera Loopback"
EOF2

helpers::write_file /etc/polkit-1/rules.d/50-vb-udisks2.rules <<EOF2
// vim:ft=javascript
// This file was created by Vibranium install scripts.
// ///////////////////////////////////////////////////
//
// Mount internal drivers without sudo prompt.
// Source: https://forum.manjaro.org/t/stable-update-2024-01-13-kernels-systemd-qt5-mesa-dbus-firefox-thunderbird/155007/123

polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.udisks2.") == 0 && subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
EOF2

for entry in "$VIBRANIUM"/extras/usr/local/bin/*; do
  [[ -e "$entry" ]] || continue
  dest="/usr/local/bin/${entry##*/}"
  helpers::copy "$entry" "$dest"
done

polkit_rule="$VIBRANIUM/extras/usr/share/polkit-1/actions/io.github.shvedes.vibranium.su-bridge"
helpers::copy "$polkit_rule" "/usr/share/polkit-1/actions/"
