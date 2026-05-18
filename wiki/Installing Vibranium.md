Vibranium is designed for a clean Arch Linux installation, either manually or via `archinstall`.

It may work on minimal Arch-based setups such as CachyOS without a graphical environment, but this is not officially tested. 

`systemd-networkd` is recommended network backed to start with. If you have NetworkManager, Vibranium will try to migrate automatically during installation.

Installation on existing long-term systems is not recommended and not supported. The installer does not create backups and may overwrite or break existing configuration files. Do not install it on a system you rely on.

Vibranium can also be installed in a virtual machine, although only QEMU has been tested. The installer detects VM environment and adjusts system and Vibranium settings accordingly. In a VM, some features will be unavailable, such as brightness control, screen recording, night light and more.

To install, run:
```bash
curl -sSfL https://raw.githubusercontent.com/shvedes/vibranium/master/install.sh | bash
```

The installer will guide you through a series of prompts, configure the system, install required packages, and set up hardware drivers.