# The shell

During installation you're asked which shell you want, with three options: **bash**, **zsh**, and **fish**.
All three get largely the same configuration — Vibranium aims for **feature parity** between them. The aliases, custom functions, colors, and prompts are shared; what differs is how each shell implements them.

## What you get

Each shell config lives in its own folder inside `~/.config` and is split into two parts:

| Path | Purpose |
|---|---|
| `~/.config/bash/conf.d/`, `~/.config/zsh/conf.d/`, `~/.config/fish/conf.d/` | Drop-in startup scripts, sourced in alphanumerical order |
| `~/.config/bash/functions/`, `~/.config/zsh/functions/`, `~/.config/fish/functions/` | Custom shell functions |

The configuration is yours — edit, override, or delete anything you don't like. You can also write your own startup scripts and drop them into `conf.d/`; they'll be picked up automatically.

### Custom functions

All three shells share the same set of functions with identical options and usage messages. Each function accepts `-h`/`--help`:

| Function | What it does |
|---|---|
| `bak` | Create backups of files/directories with `--prefix`, `--suffix`, `--timestamp`, `--hidden` options |
| `ccd` | Create a directory (with parents) and `cd` into it |
| `copy` | Copy files to the Wayland clipboard as `file://` URIs |
| `open` | Open files/directories with the default application via `xdg-open` |
| `mkvenv` | Create a Python virtual environment and activate it immediately |
| `y` / `yazi` | Open [yazi](https://github.com/sxyazi/yazi) and `cd` to wherever you exited it from |
| `toggle-startup-message` | Show or hide the startup greeting (uses a `.silent` marker file in the config folder) |

### Shared aliases

Every shell registers the same alias set, each guarded by `command -v` so it only appears when the tool is installed:

- **eza/ls** — `l`, `ls`, `la`, `laa`, `ll`, `lla`, `llaa`, `tree` (with `--hyperlink=auto` and group-directories-first)
- **cd** — parent-directory shortcuts `..`, `...`, `....`, `.....`, typo fixes `dc`, `cd..`, `cd...`, `cd....`
- **zoxide** — `zq`, `zz`, `za`, `zr`, `zrm`
- **trash-cli** — `rm` becomes `trash -v` when available
- **misc** — `wget` forced into XDG locations, `v` → `nvim` (or `vim`), `imv` → `imv-dir`, plus the Vibranium alias `vibranium-healthcheck`
- **typos** — `sl`, `clearr`, `exti`, `sudp`, `gti`, `dokcer`, `pacamn`, `systemclt`, `crul`, `ffmepg`, and more

Run `alias` in bash/zsh or `abbr --list` in fish to see the full list.

### Greeting

On startup each shell prints a short message pointing to its config folder, plus update and health-check notifications when relevant. `toggle-startup-message` switches it off and on again (creating/removing a `.silent` file in the config folder).

### History

bash and zsh store history in an XDG-compliant location — `~/.local/state/bash/history` and `~/.local/state/zsh/history` — so no dotfiles are left in `$HOME`. zsh keeps the last 10,000 entries (`HISTSIZE`/`SAVEHIST`). fish handles its own history natively in `~/.local/state/fish`.

## Differences between shells

Feature parity covers the functions and aliases above; beyond that, each shell plays to its strengths.

### Bash

The vanilla baseline. No plugin system — everything you get is in the config folder. Keybinding: a fish-like `^W` that deletes the closest path component (e.g. `foo/bar/baz` → `foo/bar/`), enabled by unbinding the tty-level word erase (`stty werase undef`) and rebinding `^W` in readline to `unix-filename-rubout`.

### Zsh

Adds proper plugin support on top of the baseline:

- **System-installed plugins** — zsh plugins installed as Arch packages (e.g. `zsh-syntax-highlighting`, `zsh-autosuggestions`, `zsh-history-substring-search`) are discovered in `/usr/share/zsh/plugins` and loaded automatically. The installer adds `zsh-syntax-highlighting` and `zsh-autosuggestions` when zsh is chosen. Load order is handled: `zsh-history-substring-search` is sourced before `zsh-syntax-highlighting`, which is always last, as its README requires.
- **Keybindings** — emacs keymap is forced (an `EDITOR=nvim` would otherwise put zsh into vi mode), `^W` deletes the closest path component, `^P`/`^N` do fish-like history cycling that filters by what you've typed, and `^E` accepts the current autosuggestion — or moves to the end of the line when there's none.

### Fish

Ships with features the others need plugins for, natively: autosuggestions, history search, and command highlighting (`fish_color_command`). Two things set it apart:

- **Native abbreviations** — typo fixes and shortcuts are registered as [abbreviations](https://fishshell.com/docs/current/cmds/abbr.html), not aliases: they expand in place when you press Space/Enter, so you always see the real command. Beyond the shared typo set, fish gets a large bonus set: a git cheatsheet (`g`, `ga`, `gc`, `gs`, `gp`, …), docker (`d`, `dco`, `dps`, …), npm (`ni`, `nrd`, `nt`, …), python (`py`, `serve`), tmux (`tm`), ip (`ipa`, `ipl`), systemctl (`sc`, `scu`), plus `cl`, `q`, `h`, `du1`, and a bash-compatible `!!` that recalls the last command from anywhere in the line.
- **Plugin manager** — [fisher](https://github.com/jorgebucaran/fisher) is installed automatically on first interactive run (when a network connection is available; otherwise a warning is printed and plugin setup is skipped). Two plugins come preloaded: `autopair` (auto-closing pairs) and `sponge` (dangling keybindings for slow keypresses).

Smaller fish-specific quirks: `mkvenv` activates through `bin/activate.fish` (not `bin/activate`), the yazi wrapper replaces the `yazi` command itself rather than adding a `y` shortcut, and if starship is missing fish shows a custom fallback prompt (exit code, current directory, git branch) instead of the default one.

## Prompt

All three shells share one prompt generator: [Starship](https://starship.rs/).
That means your prompt looks identical across shells, and there's exactly one prompt config to maintain: `~/.config/starship.toml`.
Customize it to your heart's content (see [Overriding configs](overriding-configs.md)).

### Git module

Minimal Nerd Font glyphs, with status kept mostly as plain, color-coded text:

![Git module](../assets/images/starship_git_module.jpeg)

| Indicator | Meaning |
|---|---|
| `[!]` | Conflicted |
| `[U]` | Untracked |
| `[M]` | Modified |
| `[S]` | Stashed |
| `[+]` | Staged |
| `[R]` | Renamed |
| `[D]` | Deleted |
| `↑ N` | Ahead of remote by N |
| `↓ N` | Behind remote by N |
| `↑ N ↓ M` | Diverged |

### Sudo module

When you run `sudo`, Linux caches your credentials briefly.
The prompt shows `[!!]` on the far left while the cache is alive, and it disappears when the cache expires.

### Hostname

Hidden by default — you know your own machine's name. But when you SSH in, it appears.

### Python venv

`mkvenv` creates virtual environments; when one is active, a simple indicator appears.

### Command duration

Any command taking more than a second shows its runtime on the far right.
