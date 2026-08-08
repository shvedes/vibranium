# Settings & validation

Every managed setting in Vibranium follows the same lifecycle:

> **Defaults catalog -> Validation -> Settings file -> Runtime**

This pipeline ensures that every component sees valid configuration values, whether they come from the graphical menus or manual edits.

## Configuration files

| File | Purpose |
|------|---------|
| `$VIBRANIUM/bin/vb-core-defaults` | Defines every managed setting, its default value, type, and constraints. |
| `~/.config/vibranium/settings` | Stores user-defined settings. Managed automatically by the Settings menu, but can also be edited manually. |
| `~/.config/vibranium/settings.advanced` | Advanced settings intended for manual editing. |
| `~/.config/vibranium/settings.functions` | Helper functions used by `settings.advanced`. |

## The settings file

The main configuration file is:

```text
~/.config/vibranium/settings
```

It is a plain shell script containing `KEY=value` assignments.

This allows Vibranium to source the file directly without requiring a custom parser. The Settings menu modifies individual variables automatically, while manual edits take effect the next time a component reads the corresponding setting.

Because the file is sourced by Bash, invalid shell syntax prevents it from being loaded.  
If this happens, scripts fall back to their default values until the syntax error is corrected.

## Validation

Every managed setting is validated before it is used.

If a setting is:

- missing,
- empty,
- outside its allowed range,
- or contains an invalid value,

Vibranium automatically falls back to the default value defined in the defaults catalog.  
Validation occurs every time a script requests a setting. Invalid values therefore never propagate through the system.

Valid values are also normalized where appropriate. For example:

- booleans are converted to lowercase
- integers are normalized before use

## The defaults catalog

All managed settings are defined in `$VIBRANIUM/bin/vb-core-defaults`.  
This file serves as the single source of truth for every configurable option.  
Each managed variable is documented using machine-readable annotations:

```bash
# @type int
# @range 0..100
# @desc JPEG compression level.
# @desc AKA JPEG quality.
VIBRANIUM_SCREENSHOT_JPEG_QUALITY=80

# @type string
# @values png jpeg ppm
# @desc File type used when taking a screenshot.
VIBRANIUM_SCREENSHOT_FILE_TYPE="jpeg"

# @type bool
# @desc Whether to briefly flash the screen when taking a screenshot.
VIBRANIUM_SCREENSHOT_FLASH_SCREEN=true
```

Supported setting types:

| Type | Constraints | Default format |
|------|-------------|----------------|
| `bool` | Must be `true` or `false` | Unquoted `true` / `false` |
| `int` | Optional `@range N..M` | Unquoted integer |
| `string` | `@values` is required | Double-quoted string |

Variables without a `@type` annotation are ignored by the validator.  
Variables annotated with `@ignore` are also skipped, allowing unrestricted values where appropriate.

!!! warning

    The annotation format is strict.

    `vb-core-defaults` is parsed by an AWK-based validator that verifies both annotations and default values.  
    Invalid tags, malformed ranges, incorrectly quoted defaults, or defaults outside their declared ranges all produce validation errors.

## The validator

Settings are validated through the `helpers::check()` function defined in `vb-lib-core`.  
Scripts typically request settings like this:

```bash
helpers::check \
    VIBRANIUM_RECORDING_FPS \
    VIBRANIUM_RECORDING_QUALITY
```

On its first invocation, the validator parses `vb-core-defaults` into a set of associative arrays that are cached for the lifetime of the current process.

For each requested variable, the validator performs the following steps:

1. If the variable is missing or empty, the default value is applied.
2. If the value is invalid, the default value is applied.
3. If the value is valid, it is normalized before use.
4. If the variable does not exist in the defaults catalog, a warning is emitted and the value is left unchanged.

Normalization currently includes:

- lowercasing boolean values
- canonicalizing integer values
- validating integer ranges using Bash's `10#` syntax to avoid octal interpretation

Because every component validates settings through the same helper, the defaults catalog remains the authoritative definition of every managed option.

## Reading settings

Scripts can retrieve validated settings directly:

```bash
vb-cmd-get-option VIBRANIUM_SOME_SETTING
```

The command prints the validated runtime value.

!!! warning

    Do not use this command in loops. For a single VAR lookup, this approach is fairly expensive.  
    If you need to read multiple VARs, use `helpers::check()` directly.

## Related pages

- [Advanced settings](../user/advanced-settings.md)
- [The cfgr menu system](configuration-system.md)
- [Settings validation internals](../internals/settings-validation.md)
