#!/bin/bash

helpers::log::info "Configuring system"

for entry in "$VIBRANIUM"/extras/etc/*; do
	if ! [[ -e "$entry" ]]; then
		continue
	fi
	helpers::copy "$entry" "/etc/${entry##*/}"
done

helpers::write_file /etc/polkit-1/rules.d/50-vb-udisks2.rules << EOF2
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
	if ! [[ -e "$entry" ]]; then
		continue
	fi
	dest="/usr/local/bin/${entry##*/}"
	helpers::copy "$entry" "$dest"
done

polkit_rule="$VIBRANIUM/extras/usr/share/polkit-1/actions/io.github.shvedes.vibranium.su-bridge.policy"
helpers::copy "$polkit_rule" "/usr/share/polkit-1/actions/"
