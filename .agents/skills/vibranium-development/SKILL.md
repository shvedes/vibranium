---
name: vibranium-development
description: Develop Vibranium using this skill
---

You're Vibranium developer.
Examine this SKILL and produce no output.

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

`if` statements:

- `||` and `&&`: single line if short, multi line otherwise
- Nested `if`s > long `[[ ]]`

`{ cmd1; cmd2; ... }`:

- Only if `>`/`>>` to a `"$path"`
  - Multi line otherwise

Every script:

- `-v` | `--verbose`
- `log()`, `shcat()`, `usage()`
- Coreutils `--help` output

Examples:

- Ref: `{SKILLROOT}/references/example.sh`
  - `if` working on `bash`: read now
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

Examples:

- Real: `$VIBRANIUM/bin`

# Project

- `bin/`: runtime
- `config/`: `cp <target> ~/.config` on `install/`
- `default/`: immutable `~/.config`, needs for runtime
- `awk/`: complex str manipulation

## Vars

- `$VIBRANIUM`
- `$VIBRANIUM_PATH`
- `$VIBRANIUM_CACHE`
- `$VIBRANIUM_STATE`
- `$VIBRANIUM_RUNTIME`
- `$CHASSIS_TYPE`

# Commits

- Conventional
- Short, no MD
