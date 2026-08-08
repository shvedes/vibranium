# Games

Vibranium includes a CLI game wrapper (`vb-core-gamemode`) that launches games inside the **gamescope** micro-compositor when it's available.
Gamescope can eliminate a whole category of Wine and XWayland quirks — input scaling, refresh rate mismatches, resolution issues — and in some cases it improves performance outright.
On top of that, the wrapper layers in game-mode performance profiles and MangoHud.

## Prerequisites

```bash
# Via the Vibranium menu: Vibranium Menu -> Install -> Package
# then search for:
gamescope        # required for the gamescope path
mangohud         # optional, in-game overlay
```

## Launching a game

```bash
vb-core-gamemode -- my-cool-game
```

With Steam:

```bash
vb-core-gamemode [OPTIONS] -- %command%
```

Put that in the game's Launch Options and Steam does the rest.

## What the wrapper does

The logic, in order of preference:

1. If `gamescope` is installed -> launch the game inside gamescope, with resolution/refresh taken from your **focused monitor**
2. If gamescope isn't available but `mangohud` is -> launch with MangoHud
3. If neither -> just run the game with the **performance power profile** enabled

The performance profile prefix is also applied in the gamescope path if you want it (`--power-profile` options — check `--help`).

## Notable details

- **Flag validation**: the wrapper validates extra flags you pass against a hard-coded allowlist of ~130 known gamescope flags — a typo'd flag gets caught immediately instead of gamescope silently doing something unexpected.
- **The LD_PRELOAD workaround**: gamescope and some launchers have a known "lag bomb" interaction; the wrapper clears `LD_PRELOAD` for the game and can re-inject it selectively with `--ld-workaround`.
- **Logs**: gamescope output goes to `~/.cache/vibranium/gamescope_latest.log`

```bash
vb-core-gamemode --help   # everything the wrapper can do
```
