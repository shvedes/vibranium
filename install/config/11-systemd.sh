#!/usr/bin/env bash

LOGIND_CONF="/etc/systemd/logind.conf"

helpers::log::info "Configuring systemd"

# Don't let systemd handle hardware power button.
# Long press still shuts down the machine; it's being handled by firmware.
helpers::sed "$LOGIND_CONF" -E '/^#?HandlePowerKey=/s/^#//;/HandlePowerKey/s/=.*/=ignore/'

helpers::write_file /etc/tmpfiles.d/vb-coredump.conf << EOF2
# This file was created by Vibranium install scripts.
# #################################################### #
# Clear all coredumps that were created more than 3 days ago
d /var/lib/systemd/coredump 0755 root root 3d
EOF2

helpers::write_file /etc/tmpfiles.d/vb-thp.conf << EOF2
# This file was created by Vibranium install scripts.
# #################################################### #
# Improve performance for applications that use tcmalloc
# https://github.com/google/tcmalloc/blob/master/docs/tuning.md#system-level-optimizations
w! /sys/kernel/mm/transparent_hugepage/defrag - - - - defer+madvise
EOF2

helpers::write_file /etc/tmpfiles.d/vb-thp-shrinker.conf << EOF2
# This file was created by Vibranium install scripts.
# #################################################### #
# THP Shrinker has been added in the 6.12 kernel. The default value is 511.
# THP=always vastly overprovisions THPs in sparsely accessed memory areas,
# resulting in excessive memory pressure and premature OOM killing. 409
# means that any THP with more than 409 out of 512 (80%) zero-filled pages
# will be split. This reduces memory usage close to what madvise gives,
# while still keeping most of the performance benefit of THP=always.
w! /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none - - - - 409
EOF2

helpers::write_file /etc/systemd/zram-generator.conf << EOF2
# vim:ft=systemd
# man zram-generator.conf:
# This file was created by Vibranium install scripts.
# #################################################### #
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

helpers::write_file /etc/systemd/system.conf.d/50-fast-shutdown.conf <<EOF2
# vim:ft=systemd
# This file was created by Vibranium install scripts.
# #################################################### #
[Manager]
DefaultTimeoutStopSec=5s
EOF2

helpers::write_file /etc/systemd/system/user@.service.d/50-fast-shutdown.conf <<EOF2
# vim:ft=systemd
# This file was created by Vibranium install scripts.
# #################################################### #
[Service]
TimeoutStopSec=5s
EOF2
