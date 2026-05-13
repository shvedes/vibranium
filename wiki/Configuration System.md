
# Explanation: The Configuration Menu System (cfgr)

The `cfgr` system is the mechanism behind every settings menu in Vibranium's **Vibranium menu -> Settings** hierarchy. This article explains why it was built and how it works.

---

## The problem it solves

Before [`vb-lib-cfgr`](https://github.com/shvedes/vibranium/blob/master/bin/vb-lib-cfgr) existed, every settings script (`cfgr-audio`, `cfgr-brightness`, `cfgr-screenshots`, etc.) contained the same boilerplate:

1. Source settings.
2. Validate variables.
3. Build an array of display strings.
4. Call `rofi` and capture the selection.
5. Match the selection in a `case` statement.
6. Toggle or update the setting.
7. Loop back.

This code was copy-pasted across more than 20 scripts. Every structural bug fix had to be applied 20 times. Every UI improvement (column alignment, yes/no normalization) had to be propagated manually. Display labels and stored values were encoded in the same string, making parsing fragile.

`vb-lib-cfgr` replaces that boilerplate with a declarative system. A script now describes *what* its menu contains; the library handles *how* it is rendered and dispatched.

---

## The two parallel arrays

The library's data model is two module-level arrays:

```bash
_CFGR_ITEMS     # what rofi shows the user (display strings)
_CFGR_DISPATCH  # what happens when the user picks that row (descriptors)
```

They are always written in lockstep: `cfgr::item::bool` appends one entry to `_CFGR_ITEMS` and one to `_CFGR_DISPATCH` in the same call. Index N in `_CFGR_ITEMS` always corresponds to index N in `_CFGR_DISPATCH`.

The user sees only `_CFGR_ITEMS`. `_CFGR_DISPATCH` is internal to the library.

---

## Item registration: what `cfgr::item::*` builds

Each `cfgr::item::*` call appends one row.

**Bool item example:**
```
cfgr::item::bool --var VIBRANIUM_SCREENSHOT_FLASH_SCREEN --label "Flash screen"
```

Appends to `_CFGR_ITEMS`:
```
Flash screen : yes
```
(after `cfgr::build_menu` aligns columns and normalizes `true` → `yes`)

Appends to `_CFGR_DISPATCH`:
```
bool:VIBRANIUM_SCREENSHOT_FLASH_SCREEN
```

**String item example:**
```
cfgr::item::string --var VIBRANIUM_RECORDING_QUALITY --label "Quality" \
  --title "Recording quality" \
  --option "Medium:medium" "High:high" "Very high:very_high" "Ultra:ultra"
```

Appends to `_CFGR_ITEMS`:
```
Quality : High
```
(using the display label matching the current stored value `high`)

Appends to `_CFGR_DISPATCH`:
```
string:VIBRANIUM_RECORDING_QUALITY:Recording quality::Medium:medium\x1FHigh:high\x1FVery high:very_high\x1FUltra:ultra\x1F
```

The `\x1F` (ASCII unit-separator, 0x1F) is used as the option delimiter because individual options contain colons in their `Label:value` format. A naive `IFS=:` split would break them.

---

## The event loop

`cfgr::run "My Menu" "_build" VAR1 VAR2` runs this loop:

```
loop:
  source ~/.config/vibranium/settings
  helpers::check VAR1 VAR2
  _CFGR_ITEMS=()
  _CFGR_DISPATCH=()
  _build()               <- populates both arrays
  cfgr::build_menu()     <- aligns columns, normalizes booleans
  helpers::ui::menu()    <- rofi picks a row (returns index)
  if Escape: exit
  cfgr::dispatch(_CFGR_DISPATCH[N])
  goto loop
```

Because the arrays are cleared and rebuilt on every iteration, conditional items work correctly. A menu can show or hide rows based on the current state of a setting:

```bash
_build() {
  cfgr::item::bool --var VIBRANIUM_VOLUME_USE_AUDIO_FEEDBACK --label "Audio feedback"

  # Only show the variant picker if audio feedback is enabled
  if [[ "$VIBRANIUM_VOLUME_USE_AUDIO_FEEDBACK" == "true" ]]; then
    cfgr::item::string --var VIBRANIUM_VOLUME_AUDIO_FEEDBACK_VARIANT \
      --label "  Sound variant" --title "Select variant" \
      --option "Variant 1:variant1" "Variant 2:variant2" "Variant 3:variant3"
  fi
}
```

After the user toggles audio feedback off, the next iteration rebuilds the menu without the variant row.

---

## Dispatch routing

`cfgr::dispatch` receives the descriptor string for the selected row and routes to the appropriate handler:

| Descriptor type  | Handler                                                             |
| ---------------- | ------------------------------------------------------------------- |
| `bool:VAR`       | `cfgr::toggle_bool VAR`; optional hook call                         |
| `digit:VAR:...`  | Opens a rofi input prompt; validates range; writes to settings file |
| `string:VAR:...` | Opens a rofi picker with the option list; writes to settings file   |
| `action:FUNC`    | `eval FUNC`                                                         |
| `display:`       | No-op                                                               |

For `bool`, `digit`, and `string` types, `_cfgr::verify_option` is called before writing. This ensures the variable exists in the settings file; if not, its default value from `vb-core-defaults` is appended first. This prevents `sed -i` from silently failing to find the line to modify.

---

## Column alignment

`cfgr::build_menu` takes the raw item strings and aligns them into two columns. It:

1. Strips Pango markup tags for length measurement (so `<b>Label</b>` is measured as `Label`).
2. Finds the longest plain-text label across all items.
3. Pads each label with spaces to reach that length.
4. Normalizes `true` → `yes` and `false` → `no` in the value column.
5. Non-matching lines (action items, display items) are passed through unchanged.

This produces consistent visual alignment regardless of label length, making the menu easy to navigate.

---

## Menu chaining

The `cfgr` system supports nested menus. An action item's function can call `cfgr::run` recursively, or it can call another script (like `vb-menu-setup`). The `helpers::ui::close_menus` function tears down the entire menu chain when a terminal action (opening a terminal for package installation) is triggered.

The chain is tracked via `VIBRANIUM_MENU_PIDS`, a space-separated list of PIDs exported to child processes. Each menu script calls `helpers::ui::register_menu` on entry (via `helpers::ui::menu`) to add itself to the chain.

---

## Why the settings file is a shell script

The settings file (`~/.config/vibranium/settings`) is a plain `KEY=value` file that is sourced as a shell script. This has several advantages:

- No parser needed. Bash sources it directly.
- `sed -i` can update individual lines reliably.
- Missing variables are simply absent from the environment, and `helpers::check` fills them from defaults.
- Users can add comments, blank lines, and conditional logic if they want to (though the mutation functions do not preserve them).

The downside is that it is trivially possible to write a syntactically invalid shell expression that breaks the sourcing. Vibranium does not validate the file's syntax before sourcing it. If you edit it manually and introduce a syntax error, scripts will fail to source it and fall back to all defaults.

### Possible "To Do" list

-  I think we can get rid of `sed -i` completely and use shell's built-in commands instead of running an external command (the `fork()` kernel call)