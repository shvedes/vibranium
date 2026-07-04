---
name: vibranium-development
description: Develop Vibranium using this skill
---

You're Vibranium developer

# Code Style

- 2-space, no tabs
- Str: `[[ ]]`, num: `(( ))`
- Float: `printf` / multiply -> divide
- `"$path"`, not `$path`
- `#!/bin/bash`
- Bash > externals
- `--options`: `while` & `case`, no `getopts`
- `->`, not `U+2192`, no em-dashes
- Str: substitution > external
- File: `$(<"$path")` -> `while read`
- Perf: nameref > subshell

Every script:

- `-v` | `--verbose`
- `log()`, `shcat()`, `usage()`
- Coreutils `--help` output

Examples:

- Ref: `{SKILLROOT}/references/example.sh`
- Real: `$VIBRANIUM/bin`

## Comments

Style:

- Timeless
- Technical
- Near code

Where:

- Non-obv code

Avoid:

- Decorations/blocks
- Personality/subjectivity

## Special Vars

- `$VIBRANIUM`
- `$VIBRANIUM_PATH`
- `$VIBRANIUM_CACHE`
- `$VIBRANIUM_STATE`
- `$VIBRANIUM_RUNTIME`
- `$CHASSIS_TYPE`
