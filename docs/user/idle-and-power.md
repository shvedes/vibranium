# Idle, locking & power

`hypridle` handles automatic session locking and suspend timeouts.
Configure in **Vibranium Menu** -> **Settings** -> **idle**.

## Locking & sleep timeouts

Hypridle locks your session and sleeps your PC after inactivity.
The default timeouts **depend on your machine type**, and the reasoning is security: with a laptop, you may be in a cafe with a half-open laptop, where even a short unattended moment has consequences.
Desktops live in safer places.

| Machine | Lock | Sleep |
|---|---|---|
| Laptop | 2 minutes | 5 minutes |
| Desktop / VM | 10 minutes | 15 minutes |

## The sleep inhibitor

The Utilities menu (++ctrl+alt+u++) has a **Caffeine**-style toggle: the sleep inhibitor.
While active, the system won't go to sleep automatically. There's a subtle distinction in how it works, set in the settings:

| Type | What gets inhibited |
|---|---|
| `sleep` | Your session still **locks** normally, but the PC never sleeps automatically |
| `idle` | Your session never **locks** automatically at all |

The bar shows an inhibitor icon while it's active, so you always know.
Click on it to disable.

## Power profiles

Vibranium manages power profiles through `powerprofilesctl` (power-profiles-daemon).  
Not all hardware supports every ACPI power profile. Vibranium detects which profiles are available and adjusts the cycle accordingly.  
For example, if the `performance` profile is unavailable, cycling works like this:

```text
power-saver -> balanced -> power-saver
```

On systems with full support, the cycle is:

```text
power-saver -> balanced -> performance -> power-saver -> ...
```

Use ++super+b++ to cycle through the available profiles.

The Waybar power profile module updates automatically to reflect the active profile.  
It is an indicator only and cannot be clicked. When the `balanced` profile is active, the icon is hidden.  
When Waybar is disabled, a notification will be shown instead.

On laptops, the **Power Profiles** menu is available in the settings.  
It lets you choose which power profile Vibranium should automatically apply when switching between AC power and battery.

!!! note
    Power profile controls are hidden on desktops, virtual machines, and other systems where the hardware or firmware does not support power profile switching.  
    The settings menu adapts automatically to your hardware.
