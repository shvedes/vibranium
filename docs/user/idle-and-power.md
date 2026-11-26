# Idle, locking & power

The shell's idle daemon handles automatic session locking and suspend timeouts.
Configure in **Vibranium Menu** -> **Settings** -> **Idle**.

## Locking & sleep timeouts

The daemon locks your session and sleeps your PC after inactivity.
The default timeouts **depend on your machine type**, and the reasoning is security: with a laptop, you may be in a cafe with a half-open laptop, where even a short unattended moment has consequences.
Desktops live in safer places.

| Machine | Lock | Sleep |
|---|---|---|
| Laptop | 2 minutes | 5 minutes |
| Desktop / VM | 10 minutes | 15 minutes |

## What a timer runs

Every timer row runs a **command** of your own. The **Add timer** row asks for two things in turn: how many **seconds** to wait, then the command to run - there is no separate "lock" or "suspend" choice, because a command says the same thing and can say more. The number stage steps by 1, starts at one second past the last timer (or 60 seconds for an empty schedule) and accepts up to 604800 seconds (one week).

The shipped timers are `vb-shell session lock` after 600 seconds and `vb-shell session suspend` after 900.

From a terminal the same owner is available through `vb-shell`:

```text
vb-shell idle list
vb-shell idle add 600 'vb-shell session suspend'
vb-shell idle remove 0
vb-shell idle class 0 suspend
vb-shell idle enable
vb-shell idle disable
vb-shell idle reload
vb-shell idle status
```

`vb-shell --help` prints the local CLI guide (no shell is started);
`-h` is an alias for `--help`; `-j`/`--json` produces typed JSON instead.
JSON success frames are
`{"v":1,"ok":true,"data":...,"format":...,"next":...}` and errors are
`{"v":1,"ok":false,"error":{"code":"...","message":"..."}}` on stderr. A
silent change omits `data`; a paged `list` uses `items` plus a `next` cursor.
Exit status is 0 on success, 2 for
`usage`/`unknown-target`/`unknown-command`/`invalid-argument`, and 1 for all
other failures. The timer schema, the wizard and the shell's backend all use
seconds together; see the downgrade boundary below before writing a schedule
you later want an older release to read.

`add` takes decimal seconds (1-604800) and one argv atom holding the command;
it never accepts a `10m` suffix. `remove`, `class` and the row ids are the
zero-based positions printed by `list`, so refresh them after an edit. A timer
can be declared `lock`, `suspend` or `none`; a command that is one of
Vibranium's own session verbs keeps its automatic class.

!!! note "Downgrade boundary"
    Timers are persisted in seconds. A schedule saved by older releases (in
    minutes) is still read and converted losslessly, but an older release
    cannot read a seconds-based write. Do not downgrade the shell after
    editing timers.

A command row is *declared* before it is saved: declare it as a lock and the idle inhibitor holds it back, declare it as a suspend and the sleep inhibitor does. An undeclared command is never held back, whatever its text happens to look like - Vibranium does not guess what a command does to your session. The Idle page shows which of the two applies to each row. A command that is one of Vibranium's own session verbs (`vb-shell session lock`, `vb-shell session suspend`), or the plain `systemctl suspend` its own suspend runs, is recognized as such on its own, so a timer saved before the declaration existed still behaves. Older persisted rows still using `vb-shell lockscreen lock` are recognized as locks too, even though that spelling is no longer a published command; a timer saved by an older version as a plain lock or suspend still runs the way it did.

## The sleep inhibitor

The Utilities menu (++ctrl+alt+u++) has a **Caffeine** dropdown: the sleep inhibitor.
Pick a duration (5, 10, 15, 30 minutes, or Infinite) and the system won't go to sleep automatically until it expires.
Each pick restarts the countdown immediately. There's a subtle distinction in how it works, set in the settings:

| Type | What gets inhibited |
|---|---|
| `sleep` | Your session still **locks** normally, but the PC never sleeps automatically |
| `idle` | Your session never **locks** automatically at all |

The bar always shows the caffeine icon on the left. While a finite inhibit is active it grows a pill on the right with the remaining time (`m:ss`); Infinite shows no pill and the glyph itself turns accent.
Left-click steps forward (from Infinite it disables instead of wrapping to 5 min), right-click steps back (from 5 min it disables instead of wrapping to Infinite), middle-click disables. Each pick restarts the countdown immediately with no delay.
While active, the Utilities Caffeine row offers a two-step stop confirmation instead of the duration list.
The lock releases by itself when the countdown expires.

The same owner is exposed through `vb-shell inhibitor`:

```text
vb-shell inhibitor status
vb-shell inhibitor remaining
vb-shell inhibitor start 600      # 0 means infinite
vb-shell inhibitor stop
vb-shell inhibitor cycle next
vb-shell inhibitor cycle back
```

Both cycle directions step from the live target rather than a remembered
index, so a bar click and the CLI agree even when a custom duration was set
with `start`. Forward runs `300 -> 600 -> 900 -> 1800 -> infinite -> off`;
backward runs `off -> infinite -> 1800 -> 900 -> 600 -> 300 -> off`. A custom
finite target steps to the next larger (or smaller) named duration. `remaining`
is `null` when off, `0` while an infinite lock is held, otherwise whole seconds
left. `status` reports `active` (local intent), `held` (the backend child) and
the target separately. The old native `inhibitor toggle` is retired.

To unlock a locked session, use the lockscreen prompt.

## What holds a timer back

Three things, and only these:

- **Caffeine** (the toggle above) and any other `systemd-inhibit --what=idle` lock, through the system inhibitor registry.
- **A Wayland idle inhibit** held by any client. This one never reaches D-Bus: a browser playing a video asks the compositor to stay awake over the Wayland idle-inhibit protocol, so before a lock or suspend timer runs, Vibranium asks the compositor which windows are inhibiting idle. A Chromium video therefore holds the timer back even though neither the logind registry nor the screensaver stream can see it.
- **A screensaver inhibit** (`org.freedesktop.ScreenSaver`) - what a browser or video player asks for while it plays video, so a YouTube video keeps the session untouched until it ends. Vibranium watches that interface's Inhibit/UnInhibit method calls; a player that asks and dies without releasing is dropped after a day rather than leaving your session unlocked for good.

Anything else - the screen blanker, a player that requests nothing, a timer that is not declared - leaves the timers running.

## Power profiles

Vibranium manages power profiles over D-Bus, through the shell's `powerProfile` service, which both reads the active profile and writes it back to power-profiles-daemon.
Not all hardware supports every ACPI power profile.
Vibranium asks the daemon which profiles this machine can actually switch to, and only ever asks for one of those, so the cycle adjusts itself.
For example, if the `performance` profile is unavailable, cycling works like this:

```text
power-saver -> balanced -> power-saver
```

On systems with full support, the cycle is:

```text
power-saver -> balanced -> performance -> power-saver -> ...
```

Use ++super+b++ to cycle through the available profiles.
With **OSD notifications** on (the default), each switch flashes the target profile's icon and name at the bottom of the screen.
The flash follows the OSD offset but ignores the OSD position setting.

The bar's power profile slot shows the active profile and is an indicator only: clicking it does nothing, and `balanced` takes no room at all, so switching profiles never leaves a gap in the bar.

## AC, battery and low battery alerts

**Vibranium Menu** -> **Settings** -> **Power** decides what the shell does when the power source changes, and when it warns about a dying battery.

| Row | What it sets |
|---|---|
| **Power profile (AC)** | the profile applied when the charger is connected |
| **Power profile (battery)** | the profile applied when the charger is unplugged |
| **OSD notifications** | flash the target profile's icon and name on switch |
| **Low battery alerts** | master switch for the warnings |
| **Warning level** | the charge level a draining battery warns at |
| **Critical level** | the charge level it warns about urgently |

**Last active** on the battery row restores the profile that was active before AC was connected, so unplugging the cable puts the machine back to what it was doing.
When the configured profile is one the daemon will not take, the AC row falls back to `performance` and then to `balanced`, and the battery row falls back to `balanced`.

!!! note
    The alerts fire only while a battery is actually discharging.
    Charging, pending charge and fully charged all mean the battery is not running down, so a fully charged battery at 5% is never an alert, at any level.

A warning re-arms once the battery climbs back above that level, so the next dip warns again.
Two batteries each get their own notification instead of one replacing the other, and each one names the device it is about.

!!! note
    The two profile rows are hidden on desktops, virtual machines, and other systems that never switch power source.
    The menu adapts to your hardware.

## Battery percentage in the bar

**Vibranium Menu** -> **Settings** -> **Statusbar** -> **Module options** -> **Power** -> **Show percentage** prints the charge next to the battery icon.
The readout starts on the machine's own battery pack; scrolling over the module steps it through every battery device, mice and keyboards included, without widening the bar.
The last device you scrolled to is remembered across shell restarts, and with no builtin battery the readout starts on the lowest device.

The tooltip and each row of the island's device list state when a device is charging, and the time to full whenever UPower reports one.
A discharging device shows the time left instead.
