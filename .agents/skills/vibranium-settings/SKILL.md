---
name: vibranium-settings
description: Settings system for Vibranium - declarative config, type validation, annotation format
---

## Settings System

Declarative, type-validated. 3 layers:

| File | Purpose |
|------|---------|
| `config/vibranium/settings` | Auto-generated runtime vals (do not edit) |
| `config/vibranium/settings.advanced` | User-editable overrides, `force_template_files`, `vb_launcher_keywords` |
| `config/vibranium/settings.functions` | User-defined bash fns for launcher keywords |

**Defaults** in `bin/vb-core-defaults` w/ annotated metadata:
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

**Validation** (`vb-lib-core:helpers::check()`): Parsed once by `awk`, cached in assoc arrays. Bool -> true/false, int -> range-checked, string -> matched against pipe-delimited allowed values. Invalid -> fall back to default.

**Hooks:** `config/vibranium/hooks/startup/`, `shutdown/`, `theme/`. Any `.sh` runs alphanumeric order. Context vars passed (e.g. `$FONT`, theme vars).

## Settings Annotation Format

`bin/vb-core-defaults` defines managed settings w/ metadata blocks, parsed by `vb-parse-defaults.awk`:

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

Tags: `@type` (bool/int/string, required), `@range` (int only, `N..M`), `@values` (string only), `@desc`/`@note` (free-form, parser-ignored), `@ignore`. No blank lines between block + assignment.
