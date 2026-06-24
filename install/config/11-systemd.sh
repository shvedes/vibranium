#!/usr/bin/env bash

LOGIND_CONF="/etc/systemd/logind.conf"

# Don't let systemd handle hardware power button.
# Long press still shuts down the machine; it's being handled by firmware.
helpers::sed "$LOGIND_CONF" -E '/^#?HandlePowerKey=/s/^#//;/HandlePowerKey/s/=.*/=ignore/'

sudo mkdir -p /etc/tmpfiles.d

helpers::write_file /etc/tmpfiles.d/coredump.conf << EOF2
# Clear all coredumps that were created more than 3 days ago
d /var/lib/systemd/coredump 0755 root root 3d
EOF2

helpers::write_file /etc/tmpfiles.d/thp.conf << EOF2
# Improve performance for applications that use tcmalloc
# https://github.com/google/tcmalloc/blob/master/docs/tuning.md#system-level-optimizations
w! /sys/kernel/mm/transparent_hugepage/defrag - - - - defer+madvise
EOF2

helpers::write_file /etc/tmpfiles.d/thp-shrinker.conf << EOF2
# THP Shrinker has been added in the 6.12 kernel. The default value is 511.
# THP=always vastly overprovisions THPs in sparsely accessed memory areas,
# resulting in excessive memory pressure and premature OOM killing. 409
# means that any THP with more than 409 out of 512 (80%) zero-filled pages
# will be split. This reduces memory usage close to what madvise gives,
# while still keeping most of the performance benefit of THP=always.
w! /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none - - - - 409
EOF2
