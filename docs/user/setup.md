# System setup

As described in the [Project philosophy](../understanding/philosophy.md), Vibranium aims to stay minimal by default.

However, minimal does not mean manual. The **Setup** section of the Vibranium Menu (++ctrl+alt+v++) provides guided wizards for common system tasks:

- [Secure Boot](#secure-boot) — configure UEFI Secure Boot with your own keys
- [Firewall](#firewall) — configure UFW with a sensible default policy
- [Docker](#docker) — install and configure Docker, Compose, lazydocker, and networking
- [QEMU](#qemu) — set up QEMU, libvirt, and Virtual Machine Manager

## How they work

Each wizard keeps the setup process simple: it asks whether you want the feature enabled, then handles the required configuration automatically.

The scripts take care of tasks such as:

- Installing required packages.
- Enabling services.
- Configuring permissions.
- Setting up networking.
- Adding required user groups.
- Applying system configuration changes.

Once the wizard finishes, the feature is ready to use.

## Secure Boot

Vibranium provides a guided Secure Boot setup process.

Instead of manually generating keys, signing files, and configuring firmware options, the setup wizard handles the complete process with a single guided flow.

### Before you begin

There is one required manual step: your UEFI firmware must be placed into **Setup Mode**.

Setup Mode removes previously enrolled Secure Boot keys, allowing Vibranium to enroll your own keys.

The exact steps depend on your motherboard manufacturer. If you are unsure which motherboard you have, you can check with `hostnamectl`.

Setup Mode is enabled from your motherboard's UEFI settings, usually under the Secure Boot or Boot section.

### Running the wizard

Open **Vibranium Menu** -> **Setup** -> **Secure Boot**.

Confirm the setup when prompted and wait for the process to complete.

The wizard performs the required steps automatically:

- Generates your own Secure Boot keys.
- Enrolls required Microsoft keys alongside your keys.
- Signs EFI binaries on your EFI System Partition.
- Regenerates initramfs files with valid signatures.

### After rebooting

After the system restarts, Vibranium verifies the setup.

It checks that:

- Secure Boot is enabled.
- Your keys were enrolled correctly.

The setup process also performs a security audit and reports any known firmware issues that could affect Secure Boot protection.

### Notes

- Secure Boot requires a UEFI system. Legacy BIOS boot is not supported.
- Vibranium checks that your system uses a compatible boot configuration before making changes.
- The wizard verifies that your firmware accepts Secure Boot variable changes before continuing.
- Your keys belong to you and can be removed later by returning the firmware to Setup Mode or using `sbctl`.

!!! warning
    Secure Boot changes firmware-level settings.  
    Make sure you know how to access your motherboard's UEFI settings and recover from a failed configuration before continuing.

## Firewall

Vibranium does not enable a firewall by default.

A firewall configuration should match how the system is used, so Vibranium provides a setup wizard instead of applying a fixed policy that may interfere with your workflow.

### Running the wizard

Open **Vibranium Menu** -> **Setup** -> **Firewall**.

The wizard installs [UFW](https://en.wikipedia.org/wiki/Uncomplicated_Firewall) and configures it with a sensible default policy:

- Allow outgoing connections
- Block incoming connections
- Allow local network traffic

Allowing local network traffic keeps common features working, such as printers,  
file sharing, and accessing your machine from other devices on the same network.

### Automatic configuration

After applying the basic policy, Vibranium checks your installed services and adjusts the firewall where needed.

Examples:

- **Docker** — allows container networking to function correctly
- **QEMU/libvirt** — allows virtual machines to communicate through their bridge interfaces
- **Syncthing and similar services** — applies required local network rules

A default restrictive firewall can unintentionally block services that rely on local networking.  
Vibranium configures the initial firewall state based on your system instead of applying rules that may break existing features.

### After setup

The wizard shows a summary of applied changes and any additional steps that may require manual attention.  
UFW is enabled automatically and starts with the system.  
You can check the current status with:

```bash
sudo ufw status
```

### Manual configuration

UFW remains a standard firewall tool. Existing commands and documentation continue to apply:

```bash
sudo ufw allow 22
sudo ufw status numbered
```

Vibranium only handles the initial setup.

## Docker

Vibranium provides a setup wizard for creating a complete Docker environment.
The wizard does more than install the Docker package.  
It configures the required services and system integration so Docker works correctly after setup.

### Running the wizard

Open **Vibranium Menu** -> **Setup** -> **Docker**.

The wizard handles:

- Installing Docker
- Optionally installing Docker Compose and [lazydocker](https://github.com/jesseduffield/lazydocker)
- Configuring Docker daemon settings
- Setting up networking
- Applying required firewall adjustments
- Adding your user to the Docker group

### Configuration details

The wizard applies several recommended defaults:

- Enables Docker socket activation so the daemon only starts when needed
- Configures log rotation to prevent unlimited container logs from consuming disk space
- Ensures containers can resolve network addresses correctly
- Applies networking rules required for Docker containers to communicate with the host

If the [Firewall](#firewall) wizard has been used, Vibranium also configures the required firewall rules for Docker networking.

### After setup

You can verify the installation with:

```bash
docker run hello-world
```

If you installed [lazydocker](https://github.com/jesseduffield/lazydocker), it can be started with:

```bash
lazydocker
```

It is also available from the application launcher.

## QEMU

Vibranium provides a setup wizard for installing and configuring the QEMU/libvirt virtualization stack.

### Running the wizard

Open **Vibranium Menu** -> **Setup** -> **QEMU**.

The wizard installs and configures:

- **QEMU** — system virtualization and emulation tools
- **libvirt** — the virtualization management layer
- **dnsmasq** — DHCP and DNS services for the libvirt network
- **Virtual Machine Manager** — the graphical interface for managing virtual machines

The setup also handles the required system integration:

- Adds your user to the required groups
- Enables libvirt services and sockets
- Configures networking
- Applies firewall rules for virtual machine bridge interfaces if the [Firewall](#firewall) wizard has been used

### After setup

Once configuration is complete, the wizard displays a summary of installed components and offers to launch **Virtual Machine Manager** immediately.  
From there, you can create a virtual machine, select an ISO image, and configure the VM through the graphical interface.

!!! note
    For better graphics performance inside virtual machines, use a virtio GPU and enable 3D acceleration in the VM display settings.
