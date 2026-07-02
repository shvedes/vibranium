---
name: vibranium-development
description: Skill for developing Vibranium
---

# Code Style

You mostly will write in bash, not just bash, but top class bash. That means:

- Two spaces for indentation, no tabs
- Use `[[ ]]` for string/file tests, `(( ))` for numeric tests
- Prefer `(( count < 50 ))` over `[[ $count -lt 50 ]]`
- Quote paths with spaces instead of escaping with `\ `
- Shebangs: `#!/bin/bash` (never `#!/usr/bin/env bash`)
- Use pure bash as much as possible
- Parse CLI args in a `while`/`case` loop, not `getopts`
- Use ASCII dashes (`-`), not em dashes (U+2014).
- Use `->` not `→` (U+2192)

Each script must have `-v` / `--verbose` CLI option, `usage()` function for `--help` option, and `shcat()` as replacement for
`cat` in conjuction with heredoc and `log()`. `log()` must be used extensively with `--verbose` option and with
forced error messages even if `--verbose` isn't provided. Here's an example of these functions:

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

See how this sample doesn't have any external command?

## Comment style

Add **timeless, technical** inline comments targeting **non-obvious code**. Do NOT add header blocks, section banners, or comments on self-explanatory code.

- **Timeless**: Describe why the code exists, what invariants it maintains, what edge cases it handles. Avoid opinions, conversational tone, dates, version references, or transient context.
- **Technical**: Be precise about data formats, protocol behavior, mathematical operations, synchronization guarantees, file layouts, and side effects.
- **Near-code**: Place comments immediately above the relevant line(s). No file-level headers, no section banners.
- **Format**: Standard `# ` prefix. One space after `#`. Blank lines between unrelated comment blocks.

### Skip

- Trivial helpers: `shcat`, `log`, `usage`
- Variable declarations: `VERBOSE=false`, `QUIET=false`, `SELF=...`
- Standard arg-parsing `while case` loops
- Standard dependency checks (`command -v ...`)
- Lines already clear from context: `exit 0`, `source ...`, `helpers::check`

### Target

- **Functions with non-obvious arguments, side effects, or return conventions** - describe parameters, return values, and side effects.
- **Data format assumptions** - file layouts, pipe-separated fields, fixed-point scaling, etc.
- **Design rationale** - why a command is backgrounded, why a fallback is used, why a certain order is forced.
- **Brittle parsing** - awk/sed expressions that parse external command output; explain the expected input format.
- **Arithmetic tricks** - ceiling division, mod-cycling, rounding, scaling factors; explain the formula and the edge case it avoids.
- **Conditional branches where the reason isn't obvious** - e.g. "skip notification when waybar is active because it already shows the profile".
- **State synchronization** - file locking, cache reads vs writes, async vs sync operations.
- **Silent error handling** - `|| exit 0` with flock, empty fallbacks, suppressed stderr.

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

# Git Commits

All commits must follow **Conventional Commits** (`type(scope): description`). Types: `feat`, `fix`, `refactor`, `style`, `docs`, `chore`, `test`, `perf`, `ci`, `build`, `revert`. The commit body must be **plain text only** — no markdown, no bullet lists, no backticks. Wrap at 72 characters.

# Command Naming

You may use already existing Vibranium commands. Always try `--help` CLI flag first. All commands start with `vb-`.
Each command has its own prefix after `vb-`. Prefix means purpose. Use `vb-<previx>-*` glob to see all prefix commands.

| Prefix | Purpose |
|--------|---------|
| `vb-app-*` | Simple wrappers for specific applications |
| `vb-backup-restore` | Backup/restore utility |
| `vb-bar-*` | Waybar custom modules (one icon per module) |
| `vb-cmd-*` | Auxiliary commands used by other scripts |
| `vb-core-*` | Desktop essentials: screenshots, recording, color picker, brightness, volume, wallpaper, clipboard, etc. Uses `vb-lib-core` and the settings system |
| `vb-cursor-*` | Cursor theme management |
| `vb-dev-*` | Development utilities |
| `vb-font-*` | Font management |
| `vb-hw-*` | Hardware helpers (battery, cpu, gpu, match) |
| `vb-launch-*` | Launch commands, TUI apps, PWAs (via Chromium), network manager, mpd |
| `vb-lib-*` | Library scripts (`core`, `cfgr`, `hypr`) |
| `vb-menu-*` | Rofi-based menu scripts |
| `vb-patch-*` | Wrappers for patching Discord, Spotify. Works with `libalpm` hooks + `sudo-bridge` or standalone |
| `vb-pkg-*` | Advanced `pacman`/`yay` wrappers |
| `vb-refresh-*` | Live config refresh for applications |
| `vb-setup-*` | Interactive setup (docker, qemu, sboot, ufw) |
| `vb-theme-*` | Theme management, including the template system via `vb-theme-set-templates` |
| `vb-toggle-*` | Toggle a single thing (animations, audio output, gaps, etc.) |
| `vb-tui-*` | Install/remove TUI applications (scriptable, supports CLI mode) |
| `vb-tweak-*` | Modify app settings, usually as a toggle |
| `vb-udev-*` | Scripts triggered by udev rules via `sudo-bridge` |
| `vb-update-*` | Update system, migrations |
| `vb-util-*` | Utilities: calculator, password manager, timer, etc. |
| `vb-version` | Version info |
| `vb-webapp-*` | Install/remove PWAs (scriptable, supports CLI mode) |

# Project Structure

| Path | Description |
|------|-------------|
| `applications/` | `.desktop` files: `custom/`, `hidden/`, app-specific |
| `awk/` | AWK helper scripts |
| `bin/` | All `vb-*` scripts |
| `config/` | Default application configs |
| `config/vibranium/` | Main Vibranium config: `settings`, `settings.advanced`, `settings.functions`, `hooks/`, `themed/` |
| `configure/` | Declarative rofi-based configuration menus (`cfgr-*`), uses `vb-lib-cfgr` |
| `default/` | Default configs: `hooks/startup/`, `hypr/` (Lua Hyprland config, animation presets, shaders, libs), `themed/` (twmplates + extended templates), `uwsm/` |
| `extras/` | `pacman` hooks, `udev` rules, custom Vibranium icon pack, VSCode theme, `su-bridge` |
| `install/` | Full install system: package lists, config, helpers, packaging, post-install scripts, first-run setup |
| `install.sh` | Bootstrap that delegates to `install/install` |
| `migrations/` | Numbered state migration scripts |
| `tests/` | Settings parser tests |
| `themes/` | 26 color themes across 8 families |
| `wiki/` | Project documentation (may be outdated) |

# Special Directories

Vibranium exports four standard XDG-aligned directories (defined in `default/uwsm/env`). All are
**writable, guaranteed to exist at runtime**, and should be used by scripts for their respective
purposes instead of creating ad-hoc directories.

| Variable | Path | Purpose |
|----------|------|---------|
| `VIBRANIUM` | `$XDG_DATA_HOME/vibranium` → `~/.local/share/vibranium` | Project root (git repository, scripts, configs, themes) |
| `VIBRANIUM_CACHE` | `$XDG_CACHE_HOME/vibranium` → `~/.cache/vibranium` | Non-essential cached data (package lists, color histories, recording logs, cookie jars) |
| `VIBRANIUM_RUNTIME` | `$XDG_RUNTIME_DIR/vibranium` → `/run/user/$UID/vibranium` | Ephemeral runtime files (lock files, FIFOs, temp output like screenshots, recording state) |
| `VIBRANIUM_STATE` | `$XDG_STATE_HOME/vibranium` → `~/.local/state/vibranium` | Persistent state (power profiles, wallpapers, migration tracking, cursor theme, monitor config) |

# Theme System

## Structure

Each theme in `themes/` is a directory with:

| File | Purpose |
|------|---------|
| `colors-extended.toml` | 62-color palette with dim/normal/bright per hue, background_0-5, foreground_0-4, accent (Vibranium native) |
| `theme.info` | `FAMILY=`, `VARIANT=`, `LIGHT=true/false` |
| `neovim.lua` | LazyVim colorscheme config |
| `vb-lib-theme` | Pango color variables for notifications (optional, generated by templates) |

`colors-extended.toml` format (`themes/nightfox/colors-extended.toml`):
```toml
black_dim = "#1b2532"
black = "#202a37"
black_bright = "#26303d"
red_dim = "#c33c5e"
red = "#c94f6d"
...
background_0 = "#192330"
background_5 = "#5a6b84"
foreground_0 = "#cdcecf"
accent_dim = "#526f97"
accent = "#719cd6"
```

## Omarchy Community Themes

`vb-theme-install` pulls themes from GitHub. It strips vendor prefixes (`omarchy-`, `vibranium-`, `theme-`) from repo names and checks for `colors.toml` (Omarchy base16 format) or `colors-extended.toml` (Vibranium extended). Both formats are supported at install time for backwards compatibility.

Community themes go in `$XDG_CONFIG_HOME/vibranium/themes/`. `vb-theme-set` discovers themes from both `$VIBRANIUM/themes/` (official) and the user path, populating `FAMILIES`, `STANDALONE_THEMES`, and `THEME_LIGHT` associative arrays.

## Template System

Application configs in `default/themed/` use Jinja-like placeholders. Each app has two template variants:
- `.tpl` - base (Omarchy-compatible), computes shades from 16 base16 colors
- `.extended.tpl` - Vibranium native, references named keys from `colors-extended.toml`

When `colors-extended.toml` exists in the active theme, extended templates take priority.

Placeholder operations (parsed by `awk`): `{{ var_lower }}`, `{{ var_strip }}`, `{{ var|lightness=+0.15 }}`, `{{ var|alpha=0.5 }}`, `{{ var_upper }}`, `{{ var_0x }}`, `{{ var_r/g/b }}`, `{{ var_rgb }}`, `{{ var_h/s/l }}`, `{{ var_hsl }}`, `{{ var_hwb }}`, `{{ var_w }}`.

`vb-theme-set-templates` processes all templates:
1. Reads `colors.toml` + `colors-extended.toml` into flat key/value table
2. Walks user templates (`$XDG_CONFIG_HOME/vibranium/themed/`) first, then built-in ones
3. Extended wins over base when available
4. `force_template_files` in `settings.advanced` can override theme-shipped files

Current apps with templates: alacritty, btop, chromium, colors.css, dunst, gtk.css, hyprland, hyprlock, hyprtoolkit, neovim, obsidian, qtct, rofi, swayosd, vb-lib-theme (bash + lua), vscode, waybar, yazi, zathura.

# Settings System

Settings are declarative with type validation. Three layers:

| File | Purpose |
|------|---------|
| `config/vibranium/settings` | Auto-generated runtime values (do not edit) |
| `config/vibranium/settings.advanced` | User-editable overrides, `force_template_files`, `vb_launcher_keywords` |
| `config/vibranium/settings.functions` | User-defined bash functions for launcher keywords |

**Default definitions** live in `bin/vb-core-defaults` with annotated metadata:
```bash
# @type string
# @values alacritty foot
VIBRANIUM_GLOBAL_TERMINAL="alacritty"

# @type bool
VIBRANIUM_GLOBAL_USE_OSD=false

# @type int
# @range 0..100
VIBRANIUM_SCREENSHOT_JPEG_QUALITY=80
```

**Validation** (`vb-lib-core:helpers::check()`): Parsed once by `awk`, cached in associative arrays, validated per type - booleans normalized to true/false, integers range-checked, enums matched against pipe-delimited allowed values. Invalid values fall back to defaults.

**Hooks:** `config/vibranium/hooks/` supports `startup/`, `shutdown/`, `theme/` directories. Any `.sh` file runs in alphanumeric order. Hooks have context variables (e.g. `$FONT` in font-change, theme variables in theme hooks).

# Configure System

`configure/cfgr-*` scripts are declarative rofi-based menus. Each script:
1. Defines a `_build()` function calling `cfgr::item::*` helpers
2. Ends with `cfgr::run "Title" "_build" [VARS...]`

Item types from `vb-lib-cfgr` (1199 lines):
- `cfgr::item::bool` - toggle with optional hook
- `cfgr::item::digit` - numeric input with min/max/type
- `cfgr::item::string` - enum picker from named options
- `cfgr::item::action` - run function or submenu
- `cfgr::item::raw` - custom display string + dispatch

`cfgr::run` sources settings, validates variables via `helpers::check`, calls `_build` to populate item arrays, opens rofi, then dispatches based on descriptor string. Descriptors encode the type, variable name, and optional hook/action.

All 21 configure scripts: `cfgr-audio`, `cfgr-brightness`, `cfgr-color-picker`, `cfgr-general`, `cfgr-idle`, `cfgr-launcher`, `cfgr-menu`, `cfgr-misc`, `cfgr-nightshift`, `cfgr-player`, `cfgr-power-profile`, `cfgr-recording`, `cfgr-screenshots`, `cfgr-waybar-menu`, `cfgr-waybar-module`, `cfgr-wm-advanced`, `cfgr-wm-appearance`, `cfgr-wm-input`, `cfgr-wm-menu`, `waybar-toggle-modules`.

# Pure Bash Patterns (Real Examples)

These idioms appear throughout `bin/`:

## String Manipulation

`vb-version` parses git output with parameter expansion:

```bash
DATE="${INFO%%|*}"           # Remove longest suffix after |
REST="${INFO#*|}"            # Remove shortest prefix before |
SHORT_HASH="${REST%%|*}"
BRANCH="${REFS#*HEAD -> }"   # Extract after prefix
BRANCH="${BRANCH%%,*}"       # Remove trailing comma and beyond
TAG="${DESCRIBE_NO_HASH%-*}"
COMMITS_AHEAD="${DESCRIBE_NO_HASH##*-}"
```

## File Reading Without `cat`

```bash
channel="$(<"$state")"                              # Whole file
while IFS= read -r line; do ... done <"$file"        # Line by line
while IFS= read -r line; do ... done < <(cmd)        # From command
read -r var < <(cmd)                                  # First line only
```

## Associative Arrays

Theme discovery (`vb-theme-set`) builds `FAMILIES[family]="variants"` and `FOLDER_MAP[key]=dir`:

```bash
declare -A FAMILIES=() FOLDER_MAP=()
for dir in "$@"; do
  [[ -f "$dir/theme.info" ]] || continue
  FAMILIES[$family]="${FAMILIES[$family]:+${FAMILIES[$family]} }$variant"
  FOLDER_MAP["$family $variant"]="$dir"
done
```

`cfgr-misc` uses them for browser selection:

```bash
declare -A browsers_map=()
[[ $(command -v firefox) ]] && browsers_map["Firefox"]="firefox.desktop"
[[ $(command -v chromium) ]] && browsers_map["Chromium"]="chromium.desktop"
```

## Namerefs

`vb-lib-core` validates variables transparently:

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

## Brace Expansion + Process Substitution

`vb-toggle-loopback` uses iteration with timeout:
```bash

for i in {1..10}; do
  SINK_INPUT_ID=$(find_sink_input_id "$NEW_MODULE_ID")
  [[ -n "$SINK_INPUT_ID" ]] && { pactl set-sink-input-volume "$SINK_INPUT_ID" ...; break; }
  sleep 0.1
done
```

## File-as-Toggle Pattern

`vb-toggle-smartgaps` creates/removes a file to toggle state:

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

## Regex Tests + Functional Returns

`vb-toggle-reading-mode` uses boolean return and `[[ =~ ]]`:

```bash
_grayscale_enabled() {
  local opt
  opt="$(hyprctl -j getoption decoration:screen_shader | jq -r '.str')"
  [[ "$opt" == "[[EMPTY]]" || "$opt" =~ ^()$ ]] && return 1 || return 0
}
```

## Lock File + Singleton

`vb-util-calc` uses `flock` with `exec FD`:

```bash
exec 9>"$LOCKFILE"

if ! flock -n 9; then
  pkill -f "rofi.*-show calc" 2>/dev/null
  exit 0
fi
```

## CLI Arg Parsing Pattern (every script)

```bash
while [[ $# -gt 0 ]]; do
  case "$1" in
  -v | --verbose) VERBOSE=true; shift ;;
  --) shift; break ;;
  *) break ;;
  esac
done
```

# AUX Systems

## AWK Scripts

`awk/` contains 7 helper scripts invoked by Bash via pipe. Never standalone.

| Script | Purpose |
|--------|---------|
| `vb-parse-defaults.awk` | Parses `vb-core-defaults` annotation blocks, emits bash `eval`-able array assignments |
| `vb-theme-set-templates.awk` | template engine: `{{ var }}` substitution, color math (RGB/HSL/HWB), lightness shifts, alpha compositing |
| `vb-bar-pacman.awk` | Renders Waybar updates module: filters/sorts/truncates `pacman -Qu` output, Pango markup |
| `cfgr-verify-digit.awk` | Validates user digit input against type (int/float) and range |
| `cfgr-idle-get-timeouts.awk` | Extracts timeout values from `hypridle.conf` listener blocks |
| `cfgr-idle-update-timeouts.awk` | Replaces timeout values in `hypridle.conf` |
| `vb-pkg-parse-systemd.awk` | Parses `pacman -Ql` output, categorizes units by scope/type |

## `vb-lib-hypr` — Hyprland IPC

Shell-level Hyprland option access (`bin/vb-lib-hypr`):

- `hypr::bool/int/float/str <option>` — read via `hyprctl -j getoption | jq`
- `hypr::fetch <spec...>` — **batch N+1 avoidance**: single `hyprctl --batch -j` + `jq -rs` call. Spec format: `option:path|type`. Populates `$HYPR[]` associative array.
- `hypr::set <option> <value> <config>` — write via `vb-cmd-edit-wm-config`
- `hypr::toggle <option> <config>` — toggle boolean option
- `hypr::reload` — `hyprctl -q reload config-only`

Config file constants: `HYPR_CONF_INPUT`, `HYPR_CONF_ADVANCED`, `HYPR_CONF_LAF`, `HYPR_CONF_SMARTGAPS`, `HYPR_CONF_ANIMATIONS`.

## Hyprland Lua Runtime

`default/hypr/lib/hyprland.lua` provides `Hypr.Helpers.*` functions inside Hyprland's Lua runtime:
- `CenterFloatingWindow(win)` — 70% monitor size, centered
- `ForceKillWindow()` — two-press kill with 1.5s timer and red border tag
- `WindowToggleFreeze()` — SIGSTOP/SIGCONT via `/proc/pid/stat` state check
- `ScaleStep(direction)` — fractional scale stepping (1/120 quantization, min 0.5 / max 3.0)
- `LaunchTUI(binary, command)` — launch with missing-dependency notification

Uses `WIN_NOTIF = 33` (shared notification replace-ID) and `KillConfirm = nil` global for confirmation state machine.

## Migrations

Timestamp-based versioning in `migrations/<unix_timestamp>.sh`. Each script is idempotent (author's responsibility).
Runs only on upgrades, not fresh installs. Triggered by `bin/vb-update`.

## Settings Annotation Format

`bin/vb-core-defaults` defines managed settings with metadata blocks parsed by `vb-parse-defaults.awk`:

```bash
# @type string
# @values alacritty foot
VIBRANIUM_GLOBAL_TERMINAL="alacritty"

# @type bool
VIBRANIUM_GLOBAL_USE_OSD=false

# @type int
# @range 0..100
VIBRANIUM_SCREENSHOT_JPEG_QUALITY=80
```

Tags: `@type` (bool/int/string, required), `@range` (int only, `N..M`), `@values` (string only), `@desc`/`@note` (free-form, ignored by parser), `@ignore`. No blank lines between block and assignment.

## Tool Dependencies (Non-Bash)

| Tool | Usage |
|------|-------|
| `jq` | Hyprland JSON, PipeWire, system APIs (60+ invocations across ~20 scripts) |
| `hyprctl` | All Hyprland IPC (40+ invocations) |
| `notify-send` | Desktop notifications (50+ invocations) |
| `rofi` | Menus, launcher, password manager, calculator |
| `fzf` | Interactive selection (package mgmt, webapp/tui removal, man pages) |
| `flock` | Singleton lock pattern (mediacontrol, brightness, nightshift, calculator) |
| `slurp` + `grim` | Region selection + screenshot capture |
| `pactl` / `wpctl` | Audio control |

## Hooks

`config/vibranium/hooks/startup/`, `shutdown/`, `theme/` — `.sh` files run in alphanumeric order. Single hooks like `font-change.sh` at root level get context variables (e.g. `$FONT`).

