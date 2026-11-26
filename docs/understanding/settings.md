# Settings & validation

Every managed setting in Vibranium follows one pipeline:

> **Schema catalog -> Quickshell store -> settings.json -> settings.env -> scripts**

Validation happens once, at write time, inside the Vibranium shell. Bash
scripts never validate - they read an already-valid projection.

## The schema catalog

Managed options live in one file next to the shell that reads them -
there is no separate directory because every row is editable from the
menus anyway:

```text
$VIBRANIUM/shell/common/settings/catalog.jsonc
```

The document holds settings `pages` plus the menu `menus` (main, setup,
install, remove, update, help, utilities). Page order in the file is
catalog order. Each settings page becomes a generated menu page and
declares its options:

```jsonc
{
  "pages": [
    {
      "label": "Recording",
      "options": [
        {
          "key": "RECORDING_FPS",
          "type": "int",              // bool | int | float | string | layout | timers
          "range": { "min": 15, "max": 120 },
          "step": 15,
          "default": 30,
          "label": "FPS cap",
          "desc": "Frames per second to record with."
        }
      ],
      "items": [ /* plain menu rows: actions, separators, guards */ ]
    }
  ]
}
```

Every settings page carries a `group` (`shell` | `env` | `hypr`) naming
the store that owns it. Keys carry their own namespace: `shell.*`, bare
`UPPER_SNAKE` env, `hypr.*`, `misc.*`. A key on the wrong group is a
parse error. Documented exceptions, riding pages as noted so each UI
stays on one page: `APP_LAUNCHER_ALWAYS_FOCUS` (App launcher),
`PLAYER_FADE_DURATION` (Media controls), `misc.cursorTheme` and
`misc.cursorSize` (General).

Inventory (193 keys on 42 pages: 22 shell + 2 env + 18 hypr):

| Group | Pages | Keys |
|---|---|---|
| `shell` | General, App launcher, Bar, modules, Audio, Screenshots, OSD, Night Light, Color picker, Lock screen, Idle, Media, Power, ... | 73 shell + 2 misc |
| `env` | Recording, Brightness | 11 env |
| `hypr` | Hyprland, Edit configs, Input, Appearance, Gaps, Blur, Glow, Shadows, Decoration, Dim, Animations, Advanced, Cursor, Scrolling, Dwindle, Master, ... | 103 hypr |

By type: bool 91, string 40, int 39, float 21,
`layout` 1 (bar zone layout), `timers` 1 (idle list). `layout`/`timers`
are first-class types with schema-side validators, not generic
object/array passthrough.

Option keys are always `key`: dotted shell paths stored under
`settings.json:shell`, bare names stored under `settings.json:options`
and projected into settings.env. `var`/`id` remain as compat shims.

Each store filters the one file by group: Settings keeps `shell` + `env`,
HyprlandSettings keeps `hypr`, MiscSettings adopts the `misc.*` options
wherever they ride. The top-level `title` carries the root chrome. A
catalog that cannot be read leaves the store with no options, and the
reason is logged.

### Descriptions and warnings

`desc` supports a minimal inline markup - `<b>`, `<i>`, `<u>` and `\n`
line breaks; anything else renders literally, so typos can never break
the menu. A `warning` adds cautionary copy (yellow notice box) below the
description, shown only while the entry's dropdown is expanded - under a
single separator above the description block. Warnings carry the same
inline markup as `desc`.

```jsonc
{
  "label": "Delete configuration",
  "desc": "Deletes the current configuration.",
  "warning": "This action cannot be undone."
}
```

### Grouped options

An option may name an `icon` (a shipped SVG stem) for the row that renders it,
and a page may collect options into one dropdown row instead of drawing them
one under another. The group is a plain menu item whose `children` name option
keys; each key keeps its own option record, so a child row validates, seeds and
persists exactly like the row it replaces. A claimed option is not drawn as a
row of its own - it appears only inside the group.

A child may also be a whole item instead of an option key. That is how a switch
the shell resolves through a provider - an app launcher plugin, a bar module -
embeds the same row its own page used to carry: the id is what the provider
answers the pill and the flip with, so the dropdown holds one switch, not a
copy. Such children declare no `icon`, and their page goes away with them.

```jsonc
{
  "type": "group",
  "label": "Enabled badges",
  "icon": "grid",
  "after": "shell.launcher.showBadges",
  "showIf": { "key": "shell.launcher.showBadges", "eq": true },
  "children": [
    "shell.launcher.showGameBadge",
    "shell.launcher.showChatBadge"
  ]
}
```

Each child is still a whole row: a `sub` line paints under its label, behind
the icon the option declares and at a size one step down from a row's own glyph.
A child can be any page row type - toggle, progress, text, select, number or
range - drawn by the same Entry at that smaller register. Its editor or option
dropdown unfolds inside the group with the same push as its description.
Ctrl-I on the child under the cursor unfolds that child's `desc` or `warning` in
a nested dropdown inside the group's own dropdown. The slot is an overlay, so
the card keeps its resting size while the rows around the child shift inside the
clipped dropdown to reveal the copy. The description is keyed by the child and
folds when the child cursor moves. A toggle child is flipped in place by Enter
or a click. A child carrying a `when` guard is left out of the list while the
guard says no, the way a gated page row is. `after` places the group under the
row it belongs to; without it the group follows every generated option row on
the page.

### Conditional visibility

Three layers - pick by what the condition depends on.

| Layer | Depends on | Form | Evaluated |
|---|---|---|---|
| `showIf` | other options' values | `{ "key": X, "eq" \| "neq" \| "in": arg }`, ANDed, transitive + cycle-safe | instantly in UI |
| `requires` | machine reality, fixed vocabulary | `{ "chassis": "laptop" \| "vm" \| "!vm", "binary": "<name>" }` | via batched bash guard |
| `visibility` | authorship intent | `"visible"` (default) \| `"hidden"` (click hooks) \| `"internal"` (layout, timers) | at parse |

**`showIf` - other options' values.** Declarative, instant, no forks:

```jsonc
{
  "key": "RECORDING_FPS",
  "type": "int", "range": { "min": 15, "max": 120 }, "default": 30,
  "showIf": { "key": "RECORDING_CAPTURE_SOURCE", "eq": true }
}
```

- One condition is an object: `{ "key": X, "eq" | "neq" | "in": arg }`.
  `"in"` takes an array (any-of). A bare object or an array of conditions
  (ANDed) are both accepted.
- Shell-only options are addressed by their full path:
  `{ "key": "shell.lockscreen.blurPower", "eq": "high" }`.
- Chains resolve transitively with cycle safety - if the parent option's
  own condition fails, its dependents report unavailable too. Cross-store
  references (shell rows gated on `hypr.*`) stay intact: the file holds
  every key, and each entry resolves in its own store at runtime.
- A row whose condition fails stays listed: it renders muted, in a box that
  fades away once the condition holds, and the cursor steps over it. Rows
  never appear or disappear while a menu is open, so the card keeps its shape;
  a section link whose rows are all muted is muted with them. Search only
  surfaces rows whose condition holds.
- **UI-only.** Hidden options keep their value and stay projected into the
  env file; scripts never see menu visibility.
- Self references are pruned at load with a warning.

**`requires` - machine reality.** Structured replacement for free-form
option `when`/`disabled` (raw action `items` may still carry `when`
bash; options may not):

```jsonc
{
  "key": "shell.power.acProfile",
  "requires": { "chassis": "laptop" }
}
```

A failed requirement behaves like a failed `showIf`: the row keeps its slot,
renders muted and unselectable, and leaves search. Nothing is removed from a
page once it has been declared.

Rule of thumb: preference-dependent -> `showIf`; world-dependent with a
fixed shape (laptop-only, not-a-VM, needs a binary) -> `requires`;
programmatic state that is never a row -> `visibility: internal`.

## The user config

```text
~/.config/vibranium/settings.json
```

Sparse JSONC: only overrides are stored, defaults live in the schema.
Everything except `options` belongs to the Quickshell shell and lives under
the `shell` namespace; `options` holds the env-projected overrides:

```jsonc
{
  "shell": {
    "debug": true,
    "wallpaper": { "enabled": true },
    "lockscreen": { "blurPower": "medium" },
    "statusbar": { "position": "top", "layout": { "...": "..." } }
  },
  "options": {
    "RECORDING_FPS": 60
  }
}
```

Hand edits are first-class - the shell watches the file, re-validates on
change and regenerates the env projection. Files written in the legacy flat
layout (top-level `wallpaper`/`lockscreen`/`statusbar`) fold into
`shell.*` automatically and are rewritten normalized. Unknown sections pass
through untouched; an unparsable file is never rewritten. Setting an option
back to its default removes the override again.

## The bash env projection

```text
$VIBRANIUM_RUNTIME/settings.env   # canonical, atomic-swapped on every change
```

A plain sourced `KEY=VAL` file rendered from validated in-memory state:

```bash
RECORDING_FPS=30
VOLUME_ADJUSTMENT_STEP=5
```

`vb-lib-core` sources it. The shell seeds the file on boot before user
scripts run, so readers always see validated values. Writes are atomic (temp +
rename): readers see either the old or the new content, never partial.
File order follows catalog order (page order in catalog.jsonc keeps it
stable); reordering UI pages never reorders the env file.

Only bare `UPPER_SNAKE` options appear here. Shell-internal config
(wallpaper, lockscreen, statusbar) stays in settings.json only. Retired
`VIBRANIUM_BAR_*` options no longer exist anywhere.

## Changing values

Any of these routes land in the same store, validation and env swap:

- the Settings menu (`qs.menu`, generated from the schema)
- IPC: `vb-shell settings get <KEY>`, `set <KEY> <JSON>`,
  `toggle <KEY>`, `dump`, `reload`
- hand edits to settings.json

Invalid values are rejected at the boundary (out-of-range, enum violation,
type mismatch) and never reach disk or scripts. Hooks declared on an option
(`"hook": "..."`) run detached after the env swap completes.

## Shell IPC migration

`vb-shell` is now the supported scripting contract for the targets named in
the shell IPC work order. Native debug handlers and in-process Registry calls
for those targets are not discovery fallbacks, and retired spellings have no
translation alias.

### CLI contract for scripts

`vb-shell --help` is a local guide: it needs no running shell and never starts
one. `-h` is an alias for `--help` and prints that local guide; `-j`/`--json`
emits typed JSON instead of the human table. `-l`/`--list` lists the public
targets once;
`-v`/`--verbose` adds only the transport path and duration. Global options are
accepted only before the first path word, and a standalone `--` ends option
parsing while a later `--` marks the remaining words literal.

A JSON success is `{"v":1,"ok":true,"data":...,"format":...,"next":...}`. An
operation with no result omits `data` entirely, which is different from
`"data":null`; paged results carry `items` (and optional `meta`) plus a `next`
cursor that must be used as returned. An error is
`{"v":1,"ok":false,"error":{"code":"...","message":"..."}}`, emitted on stderr
in JSON mode. In text mode errors are `vb-shell: CODE: message` on stderr.
Exit status is 0 on success; `usage`, `unknown-target`, `unknown-command` and
`invalid-argument` are 2; every other failure (including transport, backend,
authentication and timeout) is 1. Never treat a zero exit alone as success -
check the frame.

- **Hyprland options:** flip a known boolean with
  `vb-shell hyprlandSettings set <KEY> --toggle`. `--toggle` is grammar on
  that leaf; the JSON string `"--toggle"` is still ordinary data for
  `set <KEY> <JSON>`. An unknown key is `not-found`; a validator refusal is
  `invalid-argument`. The old native `hyprlandSettings toggle <KEY>` is gone,
  while the in-process `toggleOption` used by the Settings UI stays.
- **Idle timers:** the persisted row is `{seconds, ...}`. Read the schedule
  with `vb-shell idle list`, append with `vb-shell idle add <SECONDS> <COMMAND>`
  (one command atom, decimal seconds only), and use `idle remove <ID>`,
  `idle class <ID> lock|suspend|none`, `idle enable|disable|reload|status`.
  Add-wizard and CLI IDs are the zero-based positions shown by `list`, so
  refresh them after an edit. Legacy `minutes` rows are still read and
  converted losslessly, but **older releases cannot read new seconds writes**:
  do not downgrade the shell after editing timers. The command strings
  `vb-shell session lock`, `vb-shell session suspend` and `systemctl suspend`
  keep their automatic action class. Persisted rows that still name
  `vb-shell lockscreen lock` are recognized as locks as well, but that spelling
  is no longer a published command.
- **Sleep inhibitor:** use `vb-shell inhibitor start <SECONDS>` (`0` is
  infinite), `stop`, `cycle next`, `cycle back`, `remaining` and `status`.
  The native `inhibitor toggle` is retired. Both cycle directions compute the
  next step from the live `targetSec`, so a bar click and the CLI agree even
  for a custom duration. `inhibitor status` reports whether the local inhibit
  intent is active.
- **Lockscreen:** lock from the terminal with `vb-shell session lock` and read
  the requested-or-secure state with `vb-shell session status`. The former
  `lockscreen` CLI target is gone; the resident lock surface stays reachable
  in-process through the neutral Registry. Unlocking uses the lockscreen
  prompt. The native effect toggles and `cycleBlurPower` are retired. Those
  preferences remain in Settings, with animation reachable as
  `vb-shell hyprlandSettings set hypr.animations.enabled --toggle`.

External user scripts that used the retired native spellings must be migrated
by hand; the shell deliberately does not accept them under a new alias.

## Legacy migration

The old annotated bash catalog (`bin/vb-core-defaults`) and the awk parser
are gone. On first start the shell imports a legacy
`~/.config/vibranium/settings` into settings.json and renames it to
`settings.migrated`. Values dropped from the schema are skipped with a
warning.

## Related pages

- [Advanced settings](../user/advanced-settings.md)
- [How it works](how-it-works.md)
