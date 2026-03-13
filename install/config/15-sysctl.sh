#!/usr/bin/env bash

case "$CHASSIS_TYPE" in
    laptop|convertible|tablet)
		DIRTY_BYTES="134217728"
		DIRTY_BACKGROUND_BYTES="33554432"
		DIRTY_WRITEBACK_CENTISECS="1000"
        ;;

	desktop)  # Desktop
		DIRTY_BYTES="268435456"
		DIRTY_BACKGROUND_BYTES="67108864"
		DIRTY_WRITEBACK_CENTISECS="1500"
        ;;

    vm)
        exit 0
        ;;
esac

sudo tee /etc/sysctl.d/vibranium-sysctl.conf >/dev/null <<EOF
# Enable the sysctl setting kernel.unprivileged_userns_clone to allow normal users to run unprivileged containers.
kernel.unprivileged_userns_clone = 1

# Hide any kernel messages from the console
kernel.printk = 3 3 3 3

# Restricting access to kernel pointers in the proc filesystem
kernel.kptr_restrict = 2

# Disable Kexec, which allows replacing the current running kernel
kernel.kexec_load_disabled = 1

# Increase netdev receive queue
# May help prevent losing packets
net.core.netdev_max_backlog = 4096

# Set size of file handles and inode cache
fs.file-max = 2097152
EOF

sudo tee /etc/sysctl.d/vibranium-vm.conf >/dev/null <<EOF
# The sysctl swappiness parameter determines the kernel's preference for
# pushing anonymous pages or page cache to disk in memory-starved situations.
# A low value causes the kernel to prefer freeing up open files (page cache).
# A high value causes the kernel to try to use swap space, and a value of
# 100 means IO cost is assumed to be equal.
vm.swappiness = 100

# This value controls the tendency of the kernel to reclaim memory used for
# caching of directory and inode objects (VFS cache). Lowering it from the
# default value of 100 makes the kernel less inclined to reclaim VFS cache.
# Do not set it to 0, this may produce out-of-memory conditions.
vm.vfs_cache_pressure = 50

# page-cluster controls the number of pages up to which consecutive pages
# are read from swap in a single attempt. This is the swap counterpart to
# page cache readahead. The consecutivity is not in terms of virtual or
# physical addresses, but consecutive blocks on swap space. That means the
# pages were swapped out together. Default is 3. Increase this value to 1
# or 2 if you are using physical swap (1 for SSD, 2 for HDD).
# Vibranium uses zram by defualt, so 0.
vm.page-cluster = 0

# Contains, in bytes, the amount of memory at which a process generating
# disk writes will itself start writing out dirty data.
vm.dirty_bytes = $DIRTY_BYTES

# Contains, in bytes, the amount of memory at which the background kernel
# flusher threads will start writing out dirty data.
vm.dirty_background_bytes = $DIRTY_BACKGROUND_BYTES

# The kernel flusher threads periodically wake up and write old data to
# disk. This tunable expresses the interval between those wakeups in
# hundredths of a second. Default is 500.
# vm.dirty_writeback_centisecs = $DIRTY_WRITEBACK_CENTISECS
EOF

