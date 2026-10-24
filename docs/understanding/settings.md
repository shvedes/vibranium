# Settings & validation

Every managed setting in Vibranium follows one pipeline:

> **Schema catalog -> Quickshell store -> settings.json -> settings.env -> scripts**

Validation happens once, at write time, inside the Vibranium shell. Bash
scripts never validate - they read an already-valid projection.

## The schema catalog

Managed options live in a directory of small per-domain files:

```text
$VIBRANIUM/default/vibranium/settings/
  _index.jsonc            # root page chrome: { "width": 250, "title": "Settings" }
  shell/10-wallpaper.jsonc ... shell/23-network.jsonc
  env/21-recording.jsonc ... env/22-brightness.jsonc
  hypr/30-input.jsonc ... hypr/42-master.jsonc
  misc/50-cursor.jsonc
```

File order (numeric prefixes) is catalog order. Each file holds a `pages`
array - one page per category. Each page becomes a generated menu page and
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

Namespace equals directory: `shell/*` holds only `shell.*`, `env/*` only
bare `UPPER_SNAKE`, `hypr/*` only `hypr.*`, `misc/*` only `misc.*`. A key in
the wrong file is a parse error. One documented exception:
`APP_LAUNCHER_ALWAYS_FOCUS` rides the App launcher page in
`shell/11-launcher.jsonc` so the launcher UI stays on one page.

Per-file inventory (186 keys after the `audioFeedback` removals and the
`shell.osd.showOnLockscreen` removal):

| File(s) | Pages | Keys |
|---|---|---|
| `shell/10-wallpaper.jsonc` | General, Misc | 7 shell |
| `shell/11-launcher.jsonc` | App launcher, Enabled plugins | 7 shell + 1 env |
| `shell/12-bar.jsonc` | Bar, Enabled modules, Module options | 10 shell |
| `shell/13-bar-modules.jsonc` | 8 module pages | 18 shell |
| `shell/14-audio.jsonc` | Audio | 3 shell |
| `shell/15-screenshots.jsonc` | Screenshots | 6 shell |
| `shell/16-osd.jsonc` | OSD | 1 shell |
| `shell/17-nightlight.jsonc` | Night Light | 2 shell |
| `shell/18-colorpicker.jsonc` | Color picker | 3 shell |
| `shell/19-lockscreen.jsonc` | Lock screen | 9 shell |
| `shell/20-idle.jsonc` | Idle | 2 shell |
| `shell/22-power.jsonc` | Power | 5 shell |
| `shell/23-network.jsonc` | Network | 2 shell |
| `env/21-recording.jsonc` | Recording | 7 env |
| `env/22-brightness.jsonc` | Brightness | 2 env |
| `env/24-media.jsonc` | Media player | 1 env |
| `hypr/30-input.jsonc` | Hyprland, Edit configs, Input, Touchpad, Layouts | 12 hypr |
| `hypr/31-gaps.jsonc` | Appearance, Gaps | 3 hypr |
| `hypr/32-blur.jsonc` | Blur | 8 hypr |
| `hypr/33-glow.jsonc` | Glow | 3 hypr |
| `hypr/34-shadow.jsonc` | Shadows | 4 hypr |
| `hypr/35-decoration.jsonc` | Decoration | 9 hypr |
| `hypr/36-dim.jsonc` | Window dimming | 4 hypr |
| `hypr/37-animations.jsonc` | Animations | 2 hypr |
| `hypr/38-general.jsonc` | Advanced | 7 hypr |
| `hypr/39-cursor.jsonc` | Cursor | 20 hypr |
| `hypr/40-scrolling.jsonc` | Scrolling | 7 hypr |
| `hypr/41-dwindle.jsonc` | Dwindle | 11 hypr |
| `hypr/42-master.jsonc` | Master | 13 hypr |
| `misc/50-cursor.jsonc` | Cursor | 2 misc |

By type: bool 86, string 43 (33 enum + 10 free), int 37, float 21,
`layout` 1 (bar zone layout), `timers` 1 (idle list). `layout`/`timers`
are first-class types with schema-side validators, not generic
object/array passthrough.

Option keys are always `key`: dotted shell paths stored under
`settings.json:shell`, bare names stored under `settings.json:options`
and projected into settings.env. `var`/`id` remain as compat shims.

Each store scans only its own files: Settings reads `shell/` + `env/`,
HyprlandSettings reads `hypr/`, MiscSettings reads `misc/`. The catalog
lives in one place - `default/vibranium/settings/` - and `_index.jsonc`
carries its root chrome. A catalog that cannot be read leaves the store
with no options, and the reason is logged.

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
- Chains resolve transitively with cycle safety - if the parent option is
  itself hidden, its dependents hide too. Cross-file references stay
  intact: each entry resolves in its own store at runtime.
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
File order follows catalog order (numeric filename prefixes keep it
stable); reordering UI pages never reorders the env file.

Only bare `UPPER_SNAKE` options appear here. Shell-internal config
(wallpaper, lockscreen, statusbar) stays in settings.json only. Retired
`VIBRANIUM_BAR_*` options no longer exist anywhere.

## Changing values

Any of these routes land in the same store, validation and env swap:

- the Settings menu (`qs.menu`, generated from the schema)
- IPC: `vb-shell settings get|set|toggle|dump|reload <var> [json]`
- hand edits to settings.json

Invalid values are rejected at the boundary (out-of-range, enum violation,
type mismatch) and never reach disk or scripts. Hooks declared on an option
(`"hook": "..."`) run detached after the env swap completes.

## Legacy migration

The old annotated bash catalog (`bin/vb-core-defaults`) and the awk parser
are gone. On first start the shell imports a legacy
`~/.config/vibranium/settings` into settings.json and renames it to
`settings.migrated`. Values dropped from the schema are skipped with a
warning.

## Related pages

- [Advanced settings](../user/advanced-settings.md)
- [How it works](how-it-works.md)
