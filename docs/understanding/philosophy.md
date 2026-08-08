# Project philosophy

Before going further, read this page.  
It explains the reasoning behind Vibranium's design decisions and why certain things work the way they do.

## Vibranium vs Omarchy

Vibranium shares some ideas with [Omarchy](https://omarchy.org/), and some parts of its structure may feel familiar. However, Vibranium is **not a fork or a clone**.  
It was built independently and follows a different philosophy. Omarchy focuses on providing a highly curated experience where many decisions are already made for the user.
Vibranium takes a different approach:

> Provide a strong foundation, keep the default system minimal, and let the user decide what comes next.

It provides the essential pieces needed for a functional desktop, while leaving additional customization and system decisions in the user's hands.
It is a prepared foundation rather than a fully furnished environment.

## Why Vibranium is not an OS

Vibranium is not an operating system.
At its core, it is a collection of configuration files, scripts, and tools that customize an existing Arch Linux installation.
This distinction is intentional. Vibranium does not decide:

- How your disks are partitioned.
- Whether your system should use encryption.
- Which low-level system choices are appropriate for your hardware.

Those decisions depend heavily on the machine and the user's requirements.
A desktop system and a laptop do not necessarily need the same setup. A development workstation and a gaming machine may have different priorities.
Vibranium leaves these choices to the user.

## Arch Linux responsibility

Vibranium is built on top of Arch Linux, which means the underlying system remains the user's responsibility.

This includes:

- Disk partitioning.
- Disk encryption.
- Bootloader configuration.
- System maintenance.
- Other low-level system administration tasks.

Vibranium provides an easier way to manage the desktop environment on top of Arch, but it does not remove the need to understand the system underneath.
If concepts such as Arch package management, AUR packages, `mkinitcpio`, or bootloaders are unfamiliar, Vibranium may not be the right starting point.
The [installer](../user/installation.md) is designed to be careful and transparent, but it cannot replace understanding the system being installed.

## Performance as a value

Vibranium is more complex internally than it appears, but performance is a core design goal.

The scripts are written with efficiency in mind:

- Prefer shell built-ins where possible.
- Avoid unnecessary external commands.
- Minimize process creation.
- Keep frequently used operations lightweight.

Small optimizations add up because many scripts are executed during normal desktop usage.  
The result is a system that remains responsive while providing a rich configuration layer.

See [Performance](performance.md) for more details.

## Consequences

This philosophy creates several practical trade-offs:

- **Not install-and-forget**  
  Vibranium provides tools and configuration, but the user remains responsible for the system.

- **Setup wizards instead of forced defaults**  
  Features such as Secure Boot, firewall, Docker, and QEMU are available through setup wizards but are not enabled automatically. See [System setup](../user/setup.md).

- **A curated application ecosystem**  
  Vibranium focuses on a selected set of applications. It provides deep integration for those applications rather than trying to configure everything.

- **Transparency over automation**  
  When something goes wrong, the expected approach is to inspect the configuration, read the scripts, and understand the system rather than relying on hidden automation.
