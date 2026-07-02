---
name: vibranium-development
description: Core dev conventions for Vibranium project
---

## Code Style

Write top-class bash. Rules:

- 2-space indent, no tabs
- `[[ ]]` for string/file tests, `(( ))` for numeric
- `(( count < 50 ))` over `[[ $count -lt 50 ]]`
- Quote paths w/ spaces, no `\ ` escape
- Shebang: `#!/bin/bash` (never `#!/usr/bin/env bash`)
- Pure bash when possible
- Parse CLI args w/ `while`/`case`, not `getopts`
- ASCII dashes (`-`), not em dashes (U+2014)
- `->` not `->` (U+2192)

Every script needs: `-v`/`--verbose`, `usage()` for `--help`, `shcat()` for heredoc, `log()`. `log()` used extensively w/ `--verbose`; forced error msgs even w/o `--verbose`.

```bash
VERBOSE=false

log() {
  local level="$1"; shift
  if $VERBOSE && [[ -t 0 ]]; then
    echo "[${0##*/}] $level: $*" >&2
  fi
}

shcat() {
  while IFS= read -r line; do
    printf '%s\n' "$line"
  done
}

usage() {
  shcat <<EOF
Usage: $SELF [OPTIONS]

Adjust screen brightness.

Options:
    --up              Increase brightness
    --down            Decrease brightness
    --set             Set brightness to <0-100>%
    -f, --force       Bypass state file, work directly with ddcutil
    -q, --quiet       Do not display notification or OSD
    -v, --verbose     Enable verbose output
    -h, --help        Show this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  --option1)
    # Something
    shift
    ;;
  --option2)
    # Something
    shift 2
    ;;
  -f | --force)
    FORCE=true
    shift
    ;;
  -v | --verbose)
    VERBOSE=true
    shift
    ;;
  -q | --quiet)
    QUIET=true
    shift
    ;;
  *)
    log Error "Unknown option: $*" >&2
    log Error "Try '${0##*/}' --help for more information" >&2
    exit 1
    ;;
  esac
done

log Info "Did thing X"
log Warn "Thing X not found, skipping"
log Error "Thing X failed, exiting!" >&2
```

Sample uses 0 external cmds. Pure bash idioms throughout `bin/`:

### String Manipulation

`vb-version` parses git output w/ param expansion:

```bash
DATE="${INFO%%|*}"           # Remove longest suffix after |
REST="${INFO#*|}"            # Remove shortest prefix before |
SHORT_HASH="${REST%%|*}"
BRANCH="${REFS#*HEAD -> }"   # Extract after prefix
BRANCH="${BRANCH%%,*}"       # Remove trailing comma and beyond
TAG="${DESCRIBE_NO_HASH%-*}"
COMMITS_AHEAD="${DESCRIBE_NO_HASH##*-}"
```

### File Reading Without `cat`

```bash
channel="$(<"$state")"                              # Whole file
while IFS= read -r line; do ... done <"$file"        # Line by line
while IFS= read -r line; do ... done < <(cmd)        # From command
read -r var < <(cmd)                                  # First line only
```

### Associative Arrays

Theme discovery (`vb-theme-set`) builds `FAMILIES[family]="variants"`, `FOLDER_MAP[key]=dir`:

```bash
declare -A FAMILIES=() FOLDER_MAP=()
for dir in "$@"; do
  [[ -f "$dir/theme.info" ]] || continue
  FAMILIES[$family]="${FAMILIES[$family]:+${FAMILIES[$family]} }$variant"
  FOLDER_MAP["$family $variant"]="$dir"
done
```

`cfgr-misc` browser selection:

```bash
declare -A browsers_map=()
[[ $(command -v firefox) ]] && browsers_map["Firefox"]="firefox.desktop"
[[ $(command -v chromium) ]] && browsers_map["Chromium"]="chromium.desktop"
```

### Namerefs

`vb-lib-core` validates vars transparently:

```bash
helpers::check() {
  for var_name in "$@"; do
    declare -n ref="$var_name"
    case ${OPTION_TYPES[$var_name]} in
      bool) [[ $ref != true && $ref != false ]] && ref=${OPTION_DEFAULTS[$var_name]} ;;
      int)  [[ $ref =~ ^-?[0-9]+$ ]] || ref=${OPTION_DEFAULTS[$var_name]} ;;
    esac
  done
}
```

### Brace Expansion + Process Substitution

`vb-toggle-loopback` iteration w/ timeout:

```bash
for i in {1..10}; do
  SINK_INPUT_ID=$(find_sink_input_id "$NEW_MODULE_ID")
  [[ -n "$SINK_INPUT_ID" ]] && { pactl set-sink-input-volume "$SINK_INPUT_ID" ...; break; }
  sleep 0.1
done
```

### File-as-Toggle Pattern

`vb-toggle-smartgaps` creates/removes file to toggle:

```bash
if [[ -f "$FILE" ]]; then
  rm -f "$FILE"
else
  shcat >"$FILE" <<EOF
hl.workspace_rule({ workspace = "w[tv1] w[g0] s[false]", gaps_out = 0, gaps_in = 0 })
EOF
fi

hyprctl -q reload config-only
```

### Regex Tests + Functional Returns

`vb-toggle-reading-mode` boolean return + `[[ =~ ]]`:

```bash
_grayscale_enabled() {
  local opt
  opt="$(hyprctl -j getoption decoration:screen_shader | jq -r '.str')"
  [[ "$opt" == "[[EMPTY]]" || "$opt" =~ ^()$ ]] && return 1 || return 0
}
```

### Lock File + Singleton

`vb-util-calc` uses `flock` + `exec FD`:

```bash
exec 9>"$LOCKFILE"

if ! flock -n 9; then
  pkill -f "rofi.*-show calc" 2>/dev/null
  exit 0
fi
```

### CLI Arg Parsing (every script)

```bash
while [[ $# -gt 0 ]]; do
  case "$1" in
  -v | --verbose) VERBOSE=true; shift ;;
  --) shift; break ;;
  *) break ;;
  esac
done
```

## Comment Style

**Timeless, technical** inline comments on **non-obvious code**. No header blocks, section banners, or self-explanatory code comments.

**Timeless**: why code exists, invariants, edge cases. No opinions/dates/versions/transient context.
**Technical**: precise data formats, protocol behavior, math, sync guarantees, file layouts, side effects.
**Near-code**: above relevant line(s). No file-level headers.
**Format**: `# ` prefix, 1 space after `#`. Blank lines between unrelated blocks.

### Skip

- Trivial helpers: `shcat`, `log`, `usage`
- Var decls: `VERBOSE=false`, `QUIET=false`, `SELF=...`
- Standard `while case` arg-parsing
- Standard deps checks (`command -v ...`)
- Obvious: `exit 0`, `source ...`, `helpers::check`

### Target

- Fns w/ non-obvious args/side effects/return conventions — params, returns, side effects
- Data format assumptions — file layout, pipe-separated fields, fixed-point scaling
- Design rationale — why backgrounded, why fallback, why forced order
- Brittle parsing — awk/sed parsing external cmd output; explain input format
- Arithmetic tricks — ceiling div, mod-cycling, rounding, scaling factors; explain formula + edge case
- Conditional branches w/ non-obvious reason — "skip notif when waybar active; it already shows profile"
- State sync — file locking, cache read vs write, async vs sync
- Silent error handling — `|| exit 0` w/ flock, empty fallbacks, suppressed stderr

### Examples

```bash
# Convert a wpctl-style decimal volume string (e.g. "0.85", "1.50") to a
# fixed-point integer scaled by x100 for integer arithmetic in Bash.
# The x100 representation is also used for notify-send progress bars;
# when ALLOW_ABOVE_HUNDRED is true the bar is re-scaled later as
#   bar = vol100 * 100 / max100
_to_int100() {
```

```bash
# swayosd-client handles both the volume change and OSD atomically.
# When swayosd is unavailable or USE_OSD is false, fall back to
# manual wpctl set-volume + notify-send.
  if [[ "$VIBRANIUM_VOLUME_USE_VISUAL_FEEDBACK" == true ]]; then
```

```bash
# Mic operations intentionally do not call feedback(): the audio
# feedback plays on the default (speaker) sink and would confuse the
# user when they are adjusting their microphone level.
case "$action" in
```

```bash
# Read the active profile from the state file's first line ("current:<name>").
# Falls back to powerprofilesctl(1) when the file is missing.
# NOTE: _load_state() also writes this file but with additional list lines -
# this function intentionally ignores everything after line 1.
get_power_profile() {
```

## Git Commits

Conventional Commits (`type(scope): description`). Types: `feat`, `fix`, `refactor`, `style`, `docs`, `chore`, `test`, `perf`, `ci`, `build`, `revert`. Body plain text only — no markdown, no bullets, no backticks. Wrap at 72.

## Command Naming

All cmds start w/ `vb-`. Try `--help` first. Prefix = purpose. `vb-<prefix>-*` glob to list.

| Prefix | Purpose |
|--------|---------|
| `vb-app-*` | App wrappers |
| `vb-backup-restore` | Backup/restore |
| `vb-bar-*` | Waybar custom modules (1 icon/module) |
| `vb-cmd-*` | Aux cmds for other scripts |
| `vb-core-*` | Desktop essentials (screenshot, record, color picker, brightness, volume, wallpaper, clipboard). Uses `vb-lib-core` + settings |
| `vb-cursor-*` | Cursor theme mgmt |
| `vb-dev-*` | Dev utils |
| `vb-font-*` | Font mgmt |
| `vb-hw-*` | Hardware helpers (battery, cpu, gpu, match) |
| `vb-launch-*` | Launch cmds, TUI, PWAs (Chromium), network mgr, mpd |
| `vb-lib-*` | Lib scripts (`core`, `cfgr`, `hypr`) |
| `vb-menu-*` | Rofi menus |
| `vb-patch-*` | Discord/Spotify patching. w/ `libalpm` hooks + `sudo-bridge` or standalone |
| `vb-pkg-*` | Advanced `pacman`/`yay` wrappers |
| `vb-refresh-*` | Live config refresh for apps |
| `vb-setup-*` | Interactive setup (docker, qemu, sboot, ufw) |
| `vb-theme-*` | Theme mgmt |
| `vb-toggle-*` | Toggle single thing (animations, audio output, gaps) |
| `vb-tui-*` | Install/remove TUI apps (scriptable, CLI mode) |
| `vb-tweak-*` | Modify app settings (toggle) |
| `vb-udev-*` | udev-triggered scripts via `sudo-bridge` |
| `vb-update-*` | Update system, migrations |
| `vb-util-*` | Utils: calculator, password mgr, timer |
| `vb-version` | Version info |
| `vb-webapp-*` | Install/remove PWAs (scriptable, CLI mode) |

## Project Structure

| Path | Desc |
|------|------|
| `applications/` | `.desktop` files: `custom/`, `hidden/`, app-specific |
| `awk/` | AWK helper scripts |
| `bin/` | All `vb-*` scripts |
| `config/` | Default app configs |
| `config/vibranium/` | Main config: `settings`, `settings.advanced`, `settings.functions`, `hooks/`, `themed/` |
| `configure/` | Declarative rofi config menus (`cfgr-*`), uses `vb-lib-cfgr` |
| `default/` | Default configs: `hooks/startup/`, `hypr/` (Lua Hyprland config, anim presets, shaders, libs), `themed/` (templates + extended), `uwsm/` |
| `extras/` | `pacman` hooks, `udev` rules, Vibranium icon pack, VSCode theme, `su-bridge` |
| `install/` | Full install system: pkg lists, config, helpers, packaging, post-install, first-run |
| `install.sh` | Bootstrap -> delegates to `install/install` |
| `migrations/` | Timestamped state migration scripts |
| `tests/` | Settings parser tests |
| `themes/` | 26 themes across 8 families |
| `wiki/` | Docs (may be outdated) |

## Special Directories

Four XDG-aligned dirs (declared in `default/uwsm/env`). All writable + guaranteed exist at runtime. Use these — no ad-hoc dirs.

| Variable | Path | Purpose |
|----------|------|---------|
| `VIBRANIUM` | `$XDG_DATA_HOME/vibranium` -> `~/.local/share/vibranium` | Project root (git repo, scripts, configs, themes) |
| `VIBRANIUM_CACHE` | `$XDG_CACHE_HOME/vibranium` -> `~/.cache/vibranium` | Non-essential cache (pkg lists, color history, recording logs, cookie jars) |
| `VIBRANIUM_RUNTIME` | `$XDG_RUNTIME_DIR/vibranium` -> `/run/user/$UID/vibranium` | Ephemeral runtime (lock files, FIFOs, temp output: screenshots, recording state) |
| `VIBRANIUM_STATE` | `$XDG_STATE_HOME/vibranium` -> `~/.local/state/vibranium` | Persistent state (power profiles, wallpapers, migration tracking, cursor theme, monitor config) |

## Configure System

`configure/cfgr-*` = declarative rofi menus. Each script:
1. `_build()` fn calling `cfgr::item::*` helpers
2. Ends w/ `cfgr::run "Title" "_build" [VARS...]`

Item types from `vb-lib-cfgr` (1199 lines):
- `cfgr::item::bool` — toggle + optional hook
- `cfgr::item::digit` — numeric input w/ min/max/type
- `cfgr::item::string` — enum picker from named options
- `cfgr::item::action` — run fn or submenu
- `cfgr::item::raw` — custom display + dispatch

`cfgr::run` sources settings, validates via `helpers::check`, calls `_build`, opens rofi, dispatches by descriptor. Descriptor encodes type + var name + optional hook/action.

21 scripts: `cfgr-audio`, `cfgr-brightness`, `cfgr-color-picker`, `cfgr-general`, `cfgr-idle`, `cfgr-launcher`, `cfgr-menu`, `cfgr-misc`, `cfgr-nightshift`, `cfgr-player`, `cfgr-power-profile`, `cfgr-recording`, `cfgr-screenshots`, `cfgr-waybar-menu`, `cfgr-waybar-module`, `cfgr-wm-advanced`, `cfgr-wm-appearance`, `cfgr-wm-input`, `cfgr-wm-menu`, `waybar-toggle-modules`.

## AUX Systems

### AWK Scripts

7 helpers in `awk/`. Bash-piped only. Never standalone.

| Script | Purpose |
|--------|---------|
| `vb-parse-defaults.awk` | Parse `vb-core-defaults` annotation blocks, emit bash `eval`-able array assigns |
| `vb-theme-set-templates.awk` | Template engine: `{{ var }}` substitution, color math (RGB/HSL/HWB), lightness shifts, alpha compositing |
| `vb-bar-pacman.awk` | Waybar updates module: filter/sort/truncate `pacman -Qu`, Pango markup |
| `cfgr-verify-digit.awk` | Validate digit input against type (int/float) + range |
| `cfgr-idle-get-timeouts.awk` | Extract timeout vals from `hypridle.conf` listener blocks |
| `cfgr-idle-update-timeouts.awk` | Replace timeout vals in `hypridle.conf` |
| `vb-pkg-parse-systemd.awk` | Parse `pacman -Ql`, categorize units by scope/type |

### `vb-lib-hypr` — Hyprland IPC

Shell-level Hyprland option access (`bin/vb-lib-hypr`):

- `hypr::bool/int/float/str <option>` — read via `hyprctl -j getoption | jq`
- `hypr::fetch <spec...>` — **batch N+1 avoidance**: single `hyprctl --batch -j` + `jq -rs`. Spec: `option:path|type`. Populates `$HYPR[]` assoc array.
- `hypr::set <option> <value> <config>` — write via `vb-cmd-edit-wm-config`
- `hypr::toggle <option> <config>` — toggle bool
- `hypr::reload` — `hyprctl -q reload config-only`

Config file constants: `HYPR_CONF_INPUT`, `HYPR_CONF_ADVANCED`, `HYPR_CONF_LAF`, `HYPR_CONF_SMARTGAPS`, `HYPR_CONF_ANIMATIONS`.

### Hyprland Lua Runtime

`default/hypr/lib/hyprland.lua` provides `Hypr.Helpers.*` inside Hyprland Lua runtime:
- `CenterFloatingWindow(win)` — 70% monitor size, centered
- `ForceKillWindow()` — 2-press kill w/ 1.5s timer + red border tag
- `WindowToggleFreeze()` — SIGSTOP/SIGCONT via `/proc/pid/stat` state check
- `ScaleStep(direction)` — fractional scale stepping (1/120 quantize, min 0.5 / max 3.0)
- `LaunchTUI(binary, command)` — launch w/ missing-dependency notif

Uses `WIN_NOTIF = 33` (shared notif replace-ID) + `KillConfirm = nil` global for confirm state machine.

### Migrations

Timestamp-based: `migrations/<unix_timestamp>.sh`. Idempotent (author responsibility). Runs on upgrade only, not fresh install. Triggered by `bin/vb-update`.

### Tool Dependencies (Non-Bash)

| Tool | Usage |
|------|-------|
| `jq` | Hyprland JSON, PipeWire, system APIs (60+ invocations across ~20 scripts) |
| `hyprctl` | All Hyprland IPC (40+ invocations) |
| `notify-send` | Desktop notifications (50+ invocations) |
| `rofi` | Menus, launcher, password mgr, calculator |
| `fzf` | Interactive selection (pkg mgmt, webapp/tui removal, man pages) |
| `flock` | Singleton lock (mediacontrol, brightness, nightshift, calculator) |
| `slurp` + `grim` | Region selection + screenshot capture |
| `pactl` / `wpctl` | Audio control |

### Hooks

`config/vibranium/hooks/startup/`, `shutdown/`, `theme/` — `.sh` runs alphanumeric order. Root-level hooks (e.g. `font-change.sh`) get context vars (e.g. `$FONT`).
