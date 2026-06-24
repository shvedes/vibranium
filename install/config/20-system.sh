#!/usr/bin/env bash

for entry in "$VIBRANIUM"/extras/etc/*; do
  [[ -e "$entry" ]] || continue
  helpers::copy "$entry" "/etc/${entry##*/}"
done

helpers::write_file /etc/modules-load.d/vb-ntsync.conf << EOF2
# Load ntsync driver for better gaming compatibility with Wine.
# More info: https://www.phoronix.com/news/Linux-6.14-NTSYNC-Driver-Ready
ntsync
EOF2

helpers::write_file /etc/modprobe.d/vb-blacklist.conf << EOF2
# Disable hardware watchdog
blacklist sp5100_tco
blacklist iTCO_wdt
EOF2

helpers::write_file /etc/modprobe.d/vb-v4l-dkms.conf << EOF2
options v4l2loopback exclusive_caps=1 card_label="Virtual Camera Loopback"
EOF2

helpers::write_file /etc/systemd/zram-generator.conf << EOF2
# vim:ft=systemd
# man zram-generator.conf:
#
# A piecewise-linear size 1:1 for the first 4G, then 1:2 above, up to a max of 32G:
#      zram device size
#          ^
#      32G>|                                                oooooooooooooo
#          |                                            o
#      30G>|                                        o
#          |
#         /=/
#          |
#       8G>│                           o
#          │                       o
#          │                   o
#          │               o
#          │           o
#       4G>│       o
#          │     o
#          │   o
#       1G>│ o
#          0───────────────────────────────────||──────────────────────> total usable RAM
#            ^     ^       ^               ^        ^       ^       ^
#            1G    4G      8G             12G      56G     60G     64G

[zram0]
zram-size = min(min(ram, 4096) + max(ram - 4096, 0) / 2, 32 * 1024)
compression-algorithm = lzo-rle zstd(level=3) (type=idle)
EOF2

sudo mkdir -p /etc/polkit-1/rules.d

helpers::write_file /etc/polkit-1/rules.d/50-vb-udisks2.rules << EOF2
// vim:ft=javascript
// Mount internal drivers without sudo prompt.
// Source: https://forum.manjaro.org/t/stable-update-2024-01-13-kernels-systemd-qt5-mesa-dbus-firefox-thunderbird/155007/123

polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.udisks2.") == 0 && subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
EOF2

# Auxiliary scripts (executed by the udev)
local_bin_files=()
for entry in "$VIBRANIUM"/extras/usr/local/bin/*; do
  [[ -e "$entry" ]] || continue
  dest="/usr/local/bin/${entry##*/}"
  helpers::copy "$entry" "$dest"
  local_bin_files+=("$dest")
done

for file in "${local_bin_files[@]}"; do
  helpers::sed "$file" "s/user_placeholder/$USER/g"
done
