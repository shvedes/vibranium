# Installation

Vibranium is designed for a **clean Arch Linux installation**.  
The supported installation target is either:

- a manual Arch Linux installation
- an Arch Linux installation created with `archinstall`

Minimal Arch-based distributions may also work, provided they are close to upstream Arch and do not include a preconfigured desktop environment. These configurations are not tested or officially supported.

## Requirements

- Vanilla Arch Linux
- `systemd-networkd` (recommended)
- `systemd-boot` and/or Unified Kernel Images (optional)
- Virtual machines are supported with some limitations

## Installation

```bash
curl -sSfL https://raw.githubusercontent.com/shvedes/vibranium/master/install.sh | bash
```

The installer will:

- ask which release branch to install
- install all required packages
- detect your hardware
- install the appropriate drivers and hardware-specific components
- configure the system automatically

## After installation

Reboot the system and select the **Hyprland (uwsm-managed)** session from your display manager.  
Selecting a different Hyprland session is unsupported and will prevent parts of Vibranium from working correctly.

## Virtual machines

The installer automatically detects virtualized environments.  
When running inside a virtual machine, hardware-specific configuration is skipped and VM-specific defaults are applied automatically.  
Some features are unavailable because they require physical hardware, including:

- [Screen recording](screen-recording.md)
- [Brightness control](brightness.md)
- [Setup wizard](setup.md)

Applications that depend on advanced GPU features may also have reduced functionality, depending on the virtual graphics adapter. For example, `mpv` hardware acceleration may not be available.

The rest of Vibranium functions normally, including themes, menus, screenshots, and general desktop functionality.
