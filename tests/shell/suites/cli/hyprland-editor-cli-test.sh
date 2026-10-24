#!/bin/bash
# Suite: hyprland-editor-cli - the node CLI over the Hyprland config editor.
#
# shell/common/settings/HyprlandEditorCli.js is the out-of-process entry point
# for one hl.config/hl.monitor value, for callers that are neither Quickshell
# nor Node-hosted. Its own header states the whole result contract, and that
# contract is what this suite tests:
#
#   get <path> <file> [options]     prints the VALUE
#   set <path> <value> <file> [...]  prints the RESOLVED PATH
#
#   exactly one line on stdout, "err: <message>" on failure, empty means the
#   command never ran. The usage path is the one case that does not honour that:
#   it writes the usage block to stderr and nothing at all to stdout
#   (HyprlandEditorCli.js:44), so a caller's "empty means it never ran" reads a
#   usage error the same as a failed launch.
#
# A caller in Hyprland's config VM cannot observe a child exit status, so it
# reads that one line and nothing else. Every case below therefore asserts the
# exit status, the exact stdout text, the stdout line count and an empty
# stderr together, not just the value.
#
# Isolation: every case runs inside one mktemp -d root created below, and HOME
# and XDG_CONFIG_HOME point into it, so neither the "~" expansion cases nor a
# stray relative write can reach the real ~/.config/hypr. The trap removes the
# root, restoring write permission first so the read-only cases below cannot
# leave anything behind.
#
# SC2088 and SC2016 are off for this file on purpose: the '~/...' and '$VAR'
# file arguments below are single quoted precisely so they reach the CLI
# unresolved, and it is the CLI's own expand_path that has to resolve them.

# shellcheck disable=SC2088,SC2016

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "hyprland-editor-cli" "the one-line result contract of HyprlandEditorCli.js"
require_tools node

CLI="$SHELL_DIR/common/settings/HyprlandEditorCli.js"
t_file "the CLI under test is in the tree" "$CLI"

# ---------------------------------------------------------------------------
# Isolation
# ---------------------------------------------------------------------------

T_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vb-hypr-cli.XXXXXX")"
trap 'chmod -R u+rwX "$T_ROOT" 2>/dev/null; rm -rf "$T_ROOT"' EXIT

export HOME="$T_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$XDG_CONFIG_HOME/hypr"

RUN="$T_ROOT/.run"
mkdir -p "$RUN"

# A real config file for the argument-validation cases, so a case that gets
# past the parser cannot be confused with one that fails on a missing file.
cat >"$T_ROOT/args.lua" <<'EOF'
hl.config({
  general = {
    border_size = 2,
  },
})
EOF

# ---------------------------------------------------------------------------
# Harness helpers
# ---------------------------------------------------------------------------

# cli <args...> - one run. RC/OUT/ERR hold the exit status and the two streams;
# the raw bytes stay in $RUN so the line counts below are counted, not guessed.
# Command substitution strips trailing newlines, so a two-line stdout would
# otherwise be indistinguishable from a one-line one.
cli() {
  node "$CLI" "$@" >"$RUN/out" 2>"$RUN/err"
  RC=$?
  OUT="$(cat "$RUN/out")"
  ERR="$(cat "$RUN/err")"
}

out_lines() { wc -l <"$RUN/out"; }
err_lines() { wc -l <"$RUN/err"; }

# t_result <label> <expected-exit> <expected-stdout> - the whole documented
# contract in one go: exit status, the exact stdout text, exactly one line of
# it, and an untouched stderr.
t_result() {
  local label="$1" want_rc="$2" want_out="$3"
  t_eq "$label: exit status" "$want_rc" "$RC"
  t_eq "$label: the one stdout line" "$want_out" "$OUT"
  t_lines "$label: stdout is exactly one line" 1 "$(out_lines)"
  t_empty "$label: stderr is empty" "$ERR"
}

# t_usage <label> <expected-exit> - the usage path, which is the one case that
# does not write the result line: 15 lines of usage on stderr, nothing on
# stdout. Asserted on its own so the one-line contract below is never quietly
# widened to cover it.
t_usage() {
  local label="$1" want_rc="$2"
  t_eq "$label: exit status" "$want_rc" "$RC"
  t_empty "$label: stdout is empty" "$OUT"
  t_lines "$label: stderr is the usage block" 15 "$(err_lines)"
}

# The usage text, verbatim. The first token of each form line is
# basename(argv[1]), so the CLI is always invoked through an absolute $CLI for
# these assertions to mean anything.
USAGE_TEXT="$(cat <<'EOF'
Usage:
  HyprlandEditorCli.js get <path> <file> [options]
  HyprlandEditorCli.js set <path> <value> <file> [options]

Arguments:
  <path>    colon-separated option path, e.g. general:border_size
  <value>   boolean, number or string; only valid with "set"
  <file>    config file to read or rewrite

Options:
  --scope <config|monitor>   root the path at an hl.config or hl.monitor block
                             (default: config)
  --output <name>            monitor block to select; required for monitor scope
  --occurrence <n>           select the nth match instead of the first
  -h, --help                 display this help and exit
EOF
)"

# t_ends_in_newline <label> <file> - the library re-serialises the file from
# parsed lines, so a dropped or added trailing newline would be invisible in a
# t_eq on the content. $(...) strips one trailing newline, so a file that ends
# in one yields an empty string here and a file that does not yields its last
# byte.
t_ends_in_newline() {
  t_empty "$1" "$(tail -c1 "$2")"
}

# types_fixture <file> - one hl.config block carrying every scalar type, a
# top-level option, a bracketed dotted key, and comments above and below the
# block that a rewrite must not disturb.
types_fixture() {
  cat >"$1" <<'EOF'
-- vibranium test fixture
local helper = require("helper")

hl.config({
  snap = 12,
  general = {
    border_size = 2,
    gaps_in = true,
    gaps_out = false,
    layout = "bsp",
    ["col.active_border"] = "0xff89b4fa",
    scale = 1.5,
  },
})
-- trailing comment
EOF
}

# monitor_fixture <file> - two hl.monitor blocks and one hl.config block, so
# the monitor-scope cases can show that the scope picks the right root.
monitor_fixture() {
  cat >"$1" <<'EOF'
-- monitor fixture
hl.monitor({
  output = "HDMI-A-1",
  mode = "preferred",
  scale = 1,
})

hl.monitor({
  output = "DP-2",
  mode = "high",
})

hl.config({
  general = {
    border_size = 2,
  },
})
EOF
}

# ---------------------------------------------------------------------------
# Usage and argument validation
# ---------------------------------------------------------------------------

t_section "usage is the whole argument contract"

cli
t_eq "no arguments: the usage block, verbatim" "$USAGE_TEXT" "$ERR"
t_eq "no arguments: exit status" 1 "$RC"
t_empty "no arguments: stdout is empty" "$OUT"
t_lines "no arguments: stderr is 15 lines" 15 "$(err_lines)"

cli -h
t_eq "-h: the usage block, verbatim" "$USAGE_TEXT" "$ERR"
t_eq "-h: exit status" 0 "$RC"
t_empty "-h: stdout is empty" "$OUT"
t_lines "-h: stderr is 15 lines" 15 "$(err_lines)"

cli --help
t_eq "--help: the usage block, verbatim" "$USAGE_TEXT" "$ERR"
t_eq "--help: exit status" 0 "$RC"
t_empty "--help: stdout is empty" "$OUT"

# -h and --help are recognised only as argv[0]. Anywhere else an argument that
# does not start with "--" is a positional operand, so this is a third operand
# and the count check fires instead.
cli get general:border_size "$T_ROOT/args.lua" -h
t_usage "-h after the operands is a positional, not a help request" 1

t_section "the mode and the operand count"

cli frobnicate general:border_size "$T_ROOT/args.lua"
t_result "an unknown mode" 1 "err: unknown mode 'frobnicate', expected 'get' or 'set'"

cli GET general:border_size "$T_ROOT/args.lua"
t_result "the mode is case sensitive" 1 "err: unknown mode 'GET', expected 'get' or 'set'"

cli get
t_usage "get with no operands" 1

cli get general:border_size
t_usage "get with one operand" 1

cli get general:border_size "$T_ROOT/args.lua" extra
t_usage "get with three operands" 1

cli set general:border_size 4
t_usage "set with two operands" 1

cli set general:border_size 4 "$T_ROOT/args.lua" extra
t_usage "set with four operands" 1

t_section "option parsing"

cli get general:border_size "$T_ROOT/args.lua" --bogus value
t_result "an unknown option with its operand" 1 "err: unknown option '--bogus'"

cli get general:border_size "$T_ROOT/args.lua" --bogus
t_result "an unknown option with no operand" 1 "err: --bogus requires an argument"

cli get general:border_size "$T_ROOT/args.lua" --scope
t_result "--scope with no operand" 1 "err: --scope requires an argument"

cli get general:border_size "$T_ROOT/args.lua" --output
t_result "--output with no operand" 1 "err: --output requires an argument"

cli get general:border_size "$T_ROOT/args.lua" --occurrence
t_result "--occurrence with no operand" 1 "err: --occurrence requires an argument"

cli get general:border_size "$T_ROOT/args.lua" --scope bogus
t_result "an invalid --scope" 1 "err: invalid scope 'bogus'"

cli set general:border_size 4 "$T_ROOT/args.lua" --scope monitor2
t_result "an invalid --scope on a set" 1 "err: invalid scope 'monitor2'"

cli get general:border_size "$T_ROOT/args.lua" --occurrence x
t_result "a non-integer --occurrence" 1 "err: --occurrence requires an integer, got 'x'"

cli get general:border_size "$T_ROOT/args.lua" --occurrence 1.5
t_result "a fractional --occurrence" 1 "err: --occurrence requires an integer, got '1.5'"

cli get general:border_size "$T_ROOT/args.lua" --occurrence ""
t_result "an empty --occurrence" 1 "err: --occurrence requires an integer, got ''"

cli get general:border_size "$T_ROOT/args.lua" --occurrence +2
t_result "a signed --occurrence is not an integer here" 1 "err: --occurrence requires an integer, got '+2'"

cli get general:border_size "$T_ROOT/args.lua" --scope monitor
t_result "monitor scope with no --output" 1 "err: --output is required when --scope is monitor"

cli set general:border_size 4 "$T_ROOT/args.lua" --scope monitor
t_result "monitor scope with no --output, on a set" 1 "err: --output is required when --scope is monitor"

# "--" is not a separator here: anything starting with "--" is an option.
cli get -- general:border_size "$T_ROOT/args.lua"
t_result "a bare -- is an unknown option" 1 "err: unknown option '--'"

# Only a "--" prefix makes an argument an option, so a bare -1 lands in the
# operand list and trips the count check: a negative occurrence has to arrive
# as the operand of --occurrence.
cli get general:border_size "$T_ROOT/args.lua" -1
t_usage "a single-dash argument is a positional" 1

# Ordering, which is part of what a caller sees: options are parsed before the
# operand count, and the path is parsed before the monitor-scope check.
cli get --scope bogus
t_result "an option error beats the operand-count check" 1 "err: invalid scope 'bogus'"

cli get "" "$T_ROOT/args.lua" --scope monitor
t_result "an empty path beats the monitor-scope check" 1 "err: empty path"

cli get "" "$T_ROOT/args.lua"
t_result "an empty path" 1 "err: empty path"

cli set "" 4 "$T_ROOT/args.lua"
t_result "an empty path on a set" 1 "err: empty path"

# ---------------------------------------------------------------------------
# get
# ---------------------------------------------------------------------------

t_section "get prints the typed value, one type at a time"

GET_DIR="$T_ROOT/get"
mkdir -p "$GET_DIR"
types_fixture "$GET_DIR/types.lua"

cli get general:border_size "$GET_DIR/types.lua"
t_result "an integer option" 0 "2"

cli get general:gaps_in "$GET_DIR/types.lua"
t_result "a true boolean" 0 "true"

cli get general:gaps_out "$GET_DIR/types.lua"
t_result "a false boolean" 0 "false"

cli get general:scale "$GET_DIR/types.lua"
t_result "a float" 0 "1.5"

cli get general:layout "$GET_DIR/types.lua"
t_result "a quoted string, unquoted on the way out" 0 "bsp"

cli get 'general:col.active_border' "$GET_DIR/types.lua"
t_result "a bracketed dotted key" 0 "0xff89b4fa"

cli get snap "$GET_DIR/types.lua"
t_result "a top-level option, with no section in the path" 0 "12"

t_note "the CLI prints String(value), so a value the file quotes as a string and one it quotes as a number are indistinguishable on stdout"

# The same option reached through a longer path, and a key the parser cannot
# see unless the file brackets it.
cli get general:border_size:extra "$GET_DIR/types.lua"
t_result "a path one level deeper than the file" 1 "err: not found"

printf 'hl.config({\n  general = {\n    col.active_border = "0xff89b4fa",\n  },\n})\n' >"$GET_DIR/bare_dot.lua"
cli get general:col.active_border "$GET_DIR/bare_dot.lua"
t_result "a bare dotted key is invisible to the reader" 1 "err: not found"
# option_key only accepts /^[A-Za-z0-9_-]+$/ unbracketed, so a dotted key has to
# be written ["dotted.key"] for either half of the round trip to see it. A set
# adds the bracketed line and leaves the bare one in place, which in Lua is the
# same key twice.
cp "$GET_DIR/bare_dot.lua" "$GET_DIR/bare_dot_set.lua"
cli set general:col.active_border red "$GET_DIR/bare_dot_set.lua"
t_result "setting a dotted key the file does not bracket" 0 "$GET_DIR/bare_dot_set.lua"
t_eq "and the bracketed key is added beside the bare one" \
  'hl.config({
  general = {
    col.active_border = "0xff89b4fa",
    ["col.active_border"] = "red",
  },
})' "$(cat "$GET_DIR/bare_dot_set.lua")"

t_section "get: a missing option and a missing file"

cli get general:nosuchoption "$GET_DIR/types.lua"
t_result "a missing option" 1 "err: not found"

cli get nosuchsection:border_size "$GET_DIR/types.lua"
t_result "a missing section" 1 "err: not found"

cli get border_size "$GET_DIR/types.lua"
t_result "a single-component path when only a nested option has that name" 1 "err: not found"

cli get general:border_size "$GET_DIR/absent.lua"
t_result "a get against a file that does not exist" 1 "err: not found"
t_no_file "a get does not create the file" "$GET_DIR/absent.lua"

: >"$GET_DIR/empty.lua"
cli get general:border_size "$GET_DIR/empty.lua"
t_result "a get against an empty file" 1 "err: not found"

printf 'hl.config({\r\n  general = {\r\n    border_size = 2,\r\n  },\r\n})\r\n' >"$GET_DIR/crlf.lua"
cli get general:border_size "$GET_DIR/crlf.lua"
t_result "a get against a CRLF file" 1 "err: not found"
# ltrim/trim in HyprlandEditor.js are /^\s*(.*)$/ and /^\s*(.*?)\s*$/ with no
# dotAll flag, and JS "." does not match a carriage return, so neither regex
# can match any line holding one: ltrim returns "" for every CRLF line and the
# whole file parses as empty. Recorded here so a CRLF config reporting
# "not found" is a known shape and not a new mystery.
t_note "a CRLF config reads as an empty file: the library's ltrim/trim regexes cannot match a line containing \\r, so every line strips to \"\""

t_section "get: the config scope reads the last hl.config block"

cat >"$GET_DIR/two_calls.lua" <<'EOF'
hl.config({
  general = {
    border_size = 2,
  },
})

hl.config({
  general = {
    border_size = 7,
  },
})
EOF

cli get general:border_size "$GET_DIR/two_calls.lua"
t_result "with two hl.config blocks the reader takes the last one" 0 "7"
cli get general@1:border_size "$GET_DIR/two_calls.lua"
t_result "@1 is the only general inside that last block" 0 "7"
cli get general@2:border_size "$GET_DIR/two_calls.lua"
t_result "@2 cannot reach back into the first block" 1 "err: not found"
t_note "get_scope_root picks calls[calls.length - 1], so the config scope is the LAST hl.config block in the file, not the first"

# The write half of the same boundary is not symmetric: an occurrence the
# reader reports as not found is a section the writer is happy to create.
cp "$GET_DIR/two_calls.lua" "$GET_DIR/two_calls_set.lua"
cli set general@2:border_size 9 "$GET_DIR/two_calls_set.lua"
t_result "a set with an out-of-range occurrence still reports success" 0 "$GET_DIR/two_calls_set.lua"
t_eq "and appends a second general block inside the last hl.config" "$(cat <<'EOF'
hl.config({
  general = {
    border_size = 2,
  },
})

hl.config({
  general = {
    border_size = 7,
  },

  general = {
    border_size = 9,
  },
})
EOF
)" "$(cat "$GET_DIR/two_calls_set.lua")"
t_note "an out-of-range occurrence is 'not found' to a get and a new section to a set, so a caller that reads back after writing can see a value the write claims to have placed"

# The reader and the writer do not agree on which line a single-component path
# names. find_option_in_section tracks brace depth, so a get only ever sees a
# top-level option; write_scalar_option's top-level branch takes the first key
# match at any depth. A set can therefore report success on a line the
# matching get will never read.
types_fixture "$GET_DIR/shadowed.lua"
cli get border_size "$GET_DIR/shadowed.lua"
t_result "the nested border_size is invisible to a one-component get" 1 "err: not found"
cli set border_size 42 "$GET_DIR/shadowed.lua"
t_result "but a one-component set rewrites it anyway" 0 "$GET_DIR/shadowed.lua"
t_eq "and the nested line is what changed" "$(cat <<'EOF'
-- vibranium test fixture
local helper = require("helper")

hl.config({
  snap = 12,
  general = {
    border_size = 42,
    gaps_in = true,
    gaps_out = false,
    layout = "bsp",
    ["col.active_border"] = "0xff89b4fa",
    scale = 1.5,
  },
})
-- trailing comment
EOF
)" "$(cat "$GET_DIR/shadowed.lua")"
cli get border_size "$GET_DIR/shadowed.lua"
t_result "and the same get still reports not found after the write" 1 "err: not found"
t_note "a one-component set and a one-component get disagree about nesting: the write path does not track brace depth, so it can report success on a line the read path will not look at"

# ---------------------------------------------------------------------------
# Occurrence
# ---------------------------------------------------------------------------

t_section "name@N and --occurrence"

OCC_DIR="$T_ROOT/occurrence"
mkdir -p "$OCC_DIR"
cat >"$OCC_DIR/occ.lua" <<'EOF'
hl.config({
  general = {
    border_size = 10,
  },
  general = {
    border_size = 20,
  },
  general = {
    border_size = 30,
  },
})
EOF

cli get general:border_size "$OCC_DIR/occ.lua"
t_result "no occurrence means the first match" 0 "10"

cli get general@1:border_size "$OCC_DIR/occ.lua"
t_result "@1" 0 "10"

cli get general@2:border_size "$OCC_DIR/occ.lua"
t_result "@2" 0 "20"

cli get general@3:border_size "$OCC_DIR/occ.lua"
t_result "@3" 0 "30"

cli get general@4:border_size "$OCC_DIR/occ.lua"
t_result "@4 is past the end" 1 "err: not found"

cli get general@-1:border_size "$OCC_DIR/occ.lua"
t_result "@-1 counts from the end" 0 "30"

cli get general@-2:border_size "$OCC_DIR/occ.lua"
t_result "@-2" 0 "20"

cli get general@-3:border_size "$OCC_DIR/occ.lua"
t_result "@-3" 0 "10"

cli get general@-4:border_size "$OCC_DIR/occ.lua"
t_result "@-4 is past the beginning" 1 "err: not found"

cli get general@0:border_size "$OCC_DIR/occ.lua"
t_result "@0 falls back to the first match" 0 "10"
# parseInt("-0") is -0 and parseInt("0") is 0, and the library reads the
# selector through "opts.occurrence || 1", so 0 of any sign is falsy and
# becomes 1 rather than being an error.
t_note "--occurrence and @0 are accepted and mean the first match: the library collapses a falsy 0 to 1"

cli get general@2:border_size@-1 "$OCC_DIR/occ.lua"
t_result "the last name@N component in the path wins" 0 "30"

cli get general:border_size@3 "$OCC_DIR/occ.lua"
t_result "an @N on the option selects the nth section" 0 "30"

cli get general:border_size "$OCC_DIR/occ.lua" --occurrence 2
t_result "--occurrence applies when the path names none" 0 "20"

cli get general:border_size "$OCC_DIR/occ.lua" --occurrence -2
t_result "a negative --occurrence counts from the end" 0 "20"

cli get general@2:border_size "$OCC_DIR/occ.lua" --occurrence 1
t_result "an explicit --occurrence loses to a name@N in the path" 0 "20"

# ---------------------------------------------------------------------------
# set
# ---------------------------------------------------------------------------

t_section "set writes the value and prints the resolved path"

SET_DIR="$T_ROOT/set"
mkdir -p "$SET_DIR"
types_fixture "$SET_DIR/write.lua"

cli set general:border_size 5 "$SET_DIR/write.lua"
t_result "a set prints the path, not the value" 0 "$SET_DIR/write.lua"
t_eq "the file content after the write, exactly" "$(cat <<'EOF'
-- vibranium test fixture
local helper = require("helper")

hl.config({
  snap = 12,
  general = {
    border_size = 5,
    gaps_in = true,
    gaps_out = false,
    layout = "bsp",
    ["col.active_border"] = "0xff89b4fa",
    scale = 1.5,
  },
})
-- trailing comment
EOF
)" "$(cat "$SET_DIR/write.lua")"
t_ends_in_newline "the trailing newline survives the rewrite" "$SET_DIR/write.lua"

cli get general:border_size "$SET_DIR/write.lua"
t_result "and the value reads back" 0 "5"

t_section "set creates the sections and the file it needs"

types_fixture "$SET_DIR/new_section.lua"
cli set general:gaps_out true "$SET_DIR/new_section.lua"
t_result "a new option in an existing section" 0 "$SET_DIR/new_section.lua"
cli get general:gaps_out "$SET_DIR/new_section.lua"
t_result "the new option reads back" 0 "true"

types_fixture "$SET_DIR/new_nested.lua"
cli set a:b:c 7 "$SET_DIR/new_nested.lua"
t_result "a new section chain" 0 "$SET_DIR/new_nested.lua"
t_eq "the new chain is written with the file's own indent unit" "$(cat <<'EOF'
-- vibranium test fixture
local helper = require("helper")

hl.config({
  snap = 12,
  general = {
    border_size = 2,
    gaps_in = true,
    gaps_out = false,
    layout = "bsp",
    ["col.active_border"] = "0xff89b4fa",
    scale = 1.5,
  },

  a = {
    b = {
      c = 7,
    },
  },
})
-- trailing comment
EOF
)" "$(cat "$SET_DIR/new_nested.lua")"

types_fixture "$SET_DIR/new_top.lua"
cli set cursor_no_confirm true "$SET_DIR/new_top.lua"
t_result "a new top-level option" 0 "$SET_DIR/new_top.lua"
t_contains "and it lands inside the hl.config block" "  cursor_no_confirm = true," "$(cat "$SET_DIR/new_top.lua")"

cli set general:layout "" "$SET_DIR/new_top.lua"
t_result "an empty value is refused rather than written" 1 "err: empty value"

# A missing file reads as empty and is created, but only inside a directory
# that already exists: the create path is fs.writeFileSync, which does not
# mkdir. The header's "a missing file ... is created on write" holds for the
# file, not for the directory tree around it.
mkdir -p "$SET_DIR/missing_dir"
cli set general:border_size 3 "$SET_DIR/missing_dir/created.lua"
t_result "a set into a missing file, in a directory that exists" 0 "$SET_DIR/missing_dir/created.lua"
t_file "the file now exists" "$SET_DIR/missing_dir/created.lua"
t_ends_in_newline "with a trailing newline" "$SET_DIR/missing_dir/created.lua"
t_eq "and holds a minimal hl.config block" "$(cat <<'EOF'
hl.config({
    general = {
        border_size = 3,
    },
})
EOF
)" "$(cat "$SET_DIR/missing_dir/created.lua")"
cli get general:border_size "$SET_DIR/missing_dir/created.lua"
t_result "and the value reads back out of the created file" 0 "3"

cli set general:border_size 3 "$SET_DIR/no_such_dir/created.lua"
t_result "a set into a missing directory" 1 "err: ENOENT: no such file or directory, open '$SET_DIR/no_such_dir/created.lua'"
t_no_file "and nothing is created" "$SET_DIR/no_such_dir/created.lua"
t_note "creation covers the file, not the parent directory: a set below a missing directory reports ENOENT instead of making one"

t_section "set infers the value type and writes it accordingly"

TYPE_DIR="$T_ROOT/types"
mkdir -p "$TYPE_DIR"
types_fixture "$TYPE_DIR/typed.lua"
cli set general:flag_true true "$TYPE_DIR/typed.lua"
t_result "true" 0 "$TYPE_DIR/typed.lua"
cli set general:flag_false false "$TYPE_DIR/typed.lua"
t_result "false" 0 "$TYPE_DIR/typed.lua"
cli set general:num 42 "$TYPE_DIR/typed.lua"
t_result "42" 0 "$TYPE_DIR/typed.lua"
cli set general:str "x y" "$TYPE_DIR/typed.lua"
t_result "a value with a space is one argument" 0 "$TYPE_DIR/typed.lua"
t_eq "all four, in the file, exactly" "$(cat <<'EOF'
-- vibranium test fixture
local helper = require("helper")

hl.config({
  snap = 12,
  general = {
    border_size = 2,
    gaps_in = true,
    gaps_out = false,
    layout = "bsp",
    ["col.active_border"] = "0xff89b4fa",
    scale = 1.5,
    flag_true = true,
    flag_false = false,
    num = 42,
    str = "x y",
  },
})
-- trailing comment
EOF
)" "$(cat "$TYPE_DIR/typed.lua")"

types_fixture "$TYPE_DIR/literal_quoted.lua"
cli set general:layout '"bsp"' "$TYPE_DIR/literal_quoted.lua"
t_result "a value that already carries its own quotes" 0 "$TYPE_DIR/literal_quoted.lua"
t_contains "the quotes are consumed and re-serialised as a string" 'layout = "bsp",' "$(cat "$TYPE_DIR/literal_quoted.lua")"

types_fixture "$TYPE_DIR/float.lua"
cli set general:scale 2.0 "$TYPE_DIR/float.lua"
t_result "2.0" 0 "$TYPE_DIR/float.lua"
t_contains "a whole number written from a float literal loses its point" "scale = 2," "$(cat "$TYPE_DIR/float.lua")"
cli set general:scale 0.25 "$TYPE_DIR/float.lua"
t_contains "while a real float keeps it" "scale = 0.25," "$(cat "$TYPE_DIR/float.lua")"
cli set general:scale -3 "$TYPE_DIR/float.lua"
t_contains "and a negative integer keeps its sign" "scale = -3," "$(cat "$TYPE_DIR/float.lua")"

# inferType runs Number(s) and takes the result whenever it is not NaN, so
# anything JavaScript can read as a number is written unquoted - including the
# hex form a Hyprland colour is written in. The value is silently turned into a
# different value rather than refused.
types_fixture "$TYPE_DIR/hex.lua"
cli set general:col.active_border 0xff89b4fa "$TYPE_DIR/hex.lua"
t_result "a hex colour as a value" 0 "$TYPE_DIR/hex.lua"
t_contains "is written as a decimal number, not as a string" '["col.active_border"] = 4287214842,' "$(cat "$TYPE_DIR/hex.lua")"
cli get general:col.active_border "$TYPE_DIR/hex.lua"
t_result "and reads back as that number" 0 "4287214842"
types_fixture "$TYPE_DIR/hex_str.lua"
cli set general:col.active_border red "$TYPE_DIR/hex_str.lua"
t_contains "while a non-numeric value stays a quoted string" '["col.active_border"] = "red",' "$(cat "$TYPE_DIR/hex_str.lua")"
t_note "inferType coerces any value JavaScript can parse as a number, so 0xff89b4fa, 1e3, 0b1010, 0o17, ' 5 ' and Infinity are all written unquoted; a Hyprland colour is silently stored as a decimal"

# ---------------------------------------------------------------------------
# The in-place write
# ---------------------------------------------------------------------------

t_section "the write stays in place, so a symlink survives it"

SYM_DIR="$T_ROOT/symlink"
mkdir -p "$SYM_DIR/target"
cat >"$SYM_DIR/target/real.lua" <<'EOF'
-- the real file behind the link
hl.config({
  general = {
    border_size = 1,
  },
})
EOF
ln -s target/real.lua "$SYM_DIR/link.lua"
t_true "the fixture starts as a symlink" test -L "$SYM_DIR/link.lua"
t_eq "pointing at a relative target" "target/real.lua" "$(readlink "$SYM_DIR/link.lua")"

cli set general:border_size 99 "$SYM_DIR/link.lua"
t_result "a set through the symlink" 0 "$SYM_DIR/link.lua"
t_true "the link is still a symlink after the write" test -L "$SYM_DIR/link.lua"
t_eq "and still points where it did" "target/real.lua" "$(readlink "$SYM_DIR/link.lua")"
t_eq "the target carries the new value" "$(cat <<'EOF'
-- the real file behind the link
hl.config({
  general = {
    border_size = 99,
  },
})
EOF
)" "$(cat "$SYM_DIR/target/real.lua")"
cli get general:border_size "$SYM_DIR/target/real.lua"
t_result "readable through the target" 0 "99"
cli get general:border_size "$SYM_DIR/link.lua"
t_result "and through the link" 0 "99"
t_note "set prints the path it was handed, not the link target, so a caller cannot use its output to learn where the bytes landed"

# The other half of the same property: an in-place write needs write permission
# on the file alone, where a temp-file-and-rename would need it on the parent
# directory. A read-only parent with a writable file is the case that separates
# the two implementations, and unlike the EACCES cases below it holds for root
# too, so it is asserted unconditionally.
RO_DIR="$T_ROOT/readonly_parent"
mkdir -p "$RO_DIR"
types_fixture "$RO_DIR/ro.lua"
chmod 500 "$RO_DIR"
cli set general:border_size 7 "$RO_DIR/ro.lua"
chmod 700 "$RO_DIR"
t_result "a set into a read-only parent directory with a writable file" 0 "$RO_DIR/ro.lua"
cli get general:border_size "$RO_DIR/ro.lua"
t_result "and the write landed" 0 "7"

# ---------------------------------------------------------------------------
# Path handling
# ---------------------------------------------------------------------------

t_section "the file argument is expanded, not canonicalised"

HOME_DIR="$T_ROOT/home/.config/hypr"
types_fixture "$HOME_DIR/hl.lua"

# The quoted '~' and '$VAR' arguments below are the point of the case: the
# tilde and the variable have to reach the CLI unresolved so that its own
# expand_path is what handles them. HOME and XDG_CONFIG_HOME above point into
# the temp root, so that expansion cannot land in the real home.
cli get general:border_size '~/.config/hypr/hl.lua'
t_result "a get through ~" 0 "2"

cli set general:border_size 11 '~/.config/hypr/hl.lua'
t_result "a set through ~ prints the expanded path" 0 "$HOME/.config/hypr/hl.lua"
cli get general:border_size '~/.config/hypr/hl.lua'
t_result "and the value changed" 0 "11"

cli get general:border_size '${XDG_CONFIG_HOME}/hypr/hl.lua'
t_result "a get through \${XDG_CONFIG_HOME}" 0 "11"

cli get general:border_size '$XDG_CONFIG_HOME/hypr/hl.lua'
t_result "a get through \$XDG_CONFIG_HOME" 0 "11"

cli get general:border_size '~'
t_result "a bare ~ is the home directory, which is not a config" 1 "err: not found"
t_note "the printed path is the argument after ~ and \$VAR expansion only: it is never made absolute, so a relative argument comes back relative"

REL_DIR="$T_ROOT/relative"
mkdir -p "$REL_DIR"
types_fixture "$REL_DIR/rel.lua"
pushd "$REL_DIR" >/dev/null || t_block "the relative-path working directory is unusable"
cli set general:border_size 8 rel.lua
t_result "a set with a relative path" 0 "rel.lua"
cli get general:border_size ./rel.lua
t_result "a get with a relative path" 0 "8"
popd >/dev/null || t_block "the relative-path working directory could not be restored"
t_file "and it landed in the working directory" "$REL_DIR/rel.lua"

# ---------------------------------------------------------------------------
# Unwritable targets
# ---------------------------------------------------------------------------

t_section "an unwritable target is an err: line, not a crash"

mkdir -p "$T_ROOT/a_directory"
cli set general:border_size 3 "$T_ROOT/a_directory"
t_result "a set whose target is a directory" 1 "err: EISDIR: illegal operation on a directory, open '$T_ROOT/a_directory'"

cli get general:border_size "$T_ROOT/a_directory"
t_result "a get whose target is a directory" 1 "err: not found"

NOPERM_DIR="$T_ROOT/no_permission"
mkdir -p "$NOPERM_DIR"
chmod 500 "$NOPERM_DIR"
cli set general:border_size 3 "$NOPERM_DIR/new.lua"
chmod 700 "$NOPERM_DIR"
if [[ $(id -u) -eq 0 ]]; then
  t_skip "a set below a read-only directory" "running as root: the mode bits do not apply"
else
  t_result "a set below a read-only directory" 1 "err: EACCES: permission denied, open '$NOPERM_DIR/new.lua'"
  t_no_file "and nothing is created" "$NOPERM_DIR/new.lua"
fi

ROFILE_DIR="$T_ROOT/readonly_file"
mkdir -p "$ROFILE_DIR"
types_fixture "$ROFILE_DIR/ro.lua"
chmod 400 "$ROFILE_DIR/ro.lua"
cli set general:border_size 3 "$ROFILE_DIR/ro.lua"
chmod 600 "$ROFILE_DIR/ro.lua"
if [[ $(id -u) -eq 0 ]]; then
  t_skip "a set onto a read-only file" "running as root: the mode bits do not apply"
else
  t_result "a set onto a read-only file" 1 "err: EACCES: permission denied, open '$ROFILE_DIR/ro.lua'"
  cli get general:border_size "$ROFILE_DIR/ro.lua"
  t_eq "and the file is untouched" "2" "$OUT"
fi

# ---------------------------------------------------------------------------
# Monitor scope
# ---------------------------------------------------------------------------

t_section "monitor scope roots the path at a named hl.monitor block"

MON_DIR="$T_ROOT/monitor"
mkdir -p "$MON_DIR"
monitor_fixture "$MON_DIR/mon.lua"

cli get mode "$MON_DIR/mon.lua" --scope monitor --output HDMI-A-1
t_result "reading a monitor option" 0 "preferred"

cli get mode "$MON_DIR/mon.lua" --scope monitor --output DP-2
t_result "the second monitor block is a different option" 0 "high"

cli get scale "$MON_DIR/mon.lua" --scope monitor --output DP-2
t_result "an option only the first block has" 1 "err: not found"

cli get border_size "$MON_DIR/mon.lua" --scope monitor --output HDMI-A-1
t_result "monitor scope does not read hl.config" 1 "err: not found"

cli get mode "$MON_DIR/mon.lua" --scope config --output HDMI-A-1
t_result "and --output is ignored under the config scope" 1 "err: not found"

cli get mode "$MON_DIR/mon.lua" --scope monitor --output eDP-1
t_result "an unknown output name" 1 "err: not found"

monitor_fixture "$MON_DIR/write.lua"
cli set mode 1920x1080 "$MON_DIR/write.lua" --scope monitor --output DP-2
t_result "writing into the named block prints the path" 0 "$MON_DIR/write.lua"
t_eq "and touches nothing else in the file" "$(cat <<'EOF'
-- monitor fixture
hl.monitor({
  output = "HDMI-A-1",
  mode = "preferred",
  scale = 1,
})

hl.monitor({
  output = "DP-2",
  mode = "1920x1080",
})

hl.config({
  general = {
    border_size = 2,
  },
})
EOF
)" "$(cat "$MON_DIR/write.lua")"

monitor_fixture "$MON_DIR/create.lua"
cli set mode 1280x720 "$MON_DIR/create.lua" --scope monitor --output "eDP-1"
t_result "writing to an output that has no block yet" 0 "$MON_DIR/create.lua"
t_eq "creates the block at the end of the file" "$(cat <<'EOF'
-- monitor fixture
hl.monitor({
  output = "HDMI-A-1",
  mode = "preferred",
  scale = 1,
})

hl.monitor({
  output = "DP-2",
  mode = "high",
})

hl.config({
  general = {
    border_size = 2,
  },
})
hl.monitor({
  mode = "1280x720",
  output = "eDP-1",
})
EOF
)" "$(cat "$MON_DIR/create.lua")"
t_note "a set for an unknown --output creates the block rather than reporting it, so only a get reports an unknown output name; the new option is written above the generated output key"

# ---------------------------------------------------------------------------
# Robustness
# ---------------------------------------------------------------------------

t_section "values a shell would mangle"

ROB_DIR="$T_ROOT/robust"
mkdir -p "$ROB_DIR"

types_fixture "$ROB_DIR/space.lua"
cli set general:layout "x y z" "$ROB_DIR/space.lua"
t_result "a value with spaces" 0 "$ROB_DIR/space.lua"
t_contains "written as a quoted string" 'layout = "x y z",' "$(cat "$ROB_DIR/space.lua")"
cli get general:layout "$ROB_DIR/space.lua"
t_result "and it round-trips" 0 "x y z"

types_fixture "$ROB_DIR/squote.lua"
cli set general:layout "it's" "$ROB_DIR/squote.lua"
t_result "a value with a single quote" 0 "$ROB_DIR/squote.lua"
t_contains "written unescaped inside double quotes" "layout = \"it's\"," "$(cat "$ROB_DIR/squote.lua")"
cli get general:layout "$ROB_DIR/squote.lua"
t_result "and it round-trips" 0 "it's"

types_fixture "$ROB_DIR/dquote.lua"
cli set general:layout 'say "hi"' "$ROB_DIR/dquote.lua"
t_result "a value with a double quote" 0 "$ROB_DIR/dquote.lua"
t_contains "written escaped" 'layout = "say \"hi\"",' "$(cat "$ROB_DIR/dquote.lua")"
cli get general:layout "$ROB_DIR/dquote.lua"
t_result "and it round-trips" 0 'say "hi"'

types_fixture "$ROB_DIR/backslash.lua"
cli set general:layout 'a\b' "$ROB_DIR/backslash.lua"
t_result "a value with a backslash" 0 "$ROB_DIR/backslash.lua"
t_contains "written escaped" 'layout = "a\\b",' "$(cat "$ROB_DIR/backslash.lua")"
cli get general:layout "$ROB_DIR/backslash.lua"
t_result "and it round-trips" 0 'a\b'

mixed_value=$'a\\b"c\'d'
types_fixture "$ROB_DIR/mixed.lua"
cli set general:layout "$mixed_value" "$ROB_DIR/mixed.lua"
t_result "a value with a backslash, a double quote and a single quote" 0 "$ROB_DIR/mixed.lua"
t_contains "each one is escaped on the way in" 'layout = "a\\b\"c'"'"'d",' "$(cat "$ROB_DIR/mixed.lua")"
cli get general:layout "$ROB_DIR/mixed.lua"
t_result "and it round-trips" 0 "$mixed_value"

t_section "a newline in a value is the one thing that cannot round-trip"

nl_value=$'a\nb'
types_fixture "$ROB_DIR/newline.lua"
cli set general:layout "$nl_value" "$ROB_DIR/newline.lua"
t_result "a set with a newline in the value" 0 "$ROB_DIR/newline.lua"
nl_content="$(cat "$ROB_DIR/newline.lua")"
t_contains "the newline lands inside the quoted string" 'layout = "a' "$nl_content"
t_contains "and the string ends on the following line" 'b",' "$nl_content"
t_lines "so the file grows by a line: 16 instead of the fixture's 15" 16 "$(printf '%s\n' "$nl_content" | wc -l)"
cli get general:layout "$ROB_DIR/newline.lua"
t_result "and the read back is the first physical line only" 0 '"a'
t_note "a newline in a value does not round-trip: it is written literally into the string, splitting the option across two lines, and the reader returns the first line with its opening quote"

t_section "a path with a space in it"

types_fixture "$ROB_DIR/with space.lua"
cli set general:border_size 8 "$ROB_DIR/with space.lua"
t_result "a set to a path with a space" 0 "$ROB_DIR/with space.lua"
cli get general:border_size "$ROB_DIR/with space.lua"
t_result "and a get from it" 0 "8"
t_file "the file is where it was asked for" "$ROB_DIR/with space.lua"

t_section "a very long value and a very long key"

long_value="$(printf 'v%.0s' $(seq 1 4000))"
types_fixture "$ROB_DIR/long_value.lua"
cli set general:layout "$long_value" "$ROB_DIR/long_value.lua"
t_result "a 4000 character value" 0 "$ROB_DIR/long_value.lua"
cli get general:layout "$ROB_DIR/long_value.lua"
t_result "and it round-trips" 0 "$long_value"
t_count "the whole value survives" "4000" "$(printf '%s' "$OUT" | wc -c)"

long_key="$(printf 'k%.0s' $(seq 1 500))"
types_fixture "$ROB_DIR/long_key.lua"
cli set "general:$long_key" 1 "$ROB_DIR/long_key.lua"
t_result "a 500 character option name" 0 "$ROB_DIR/long_key.lua"
cli get "general:$long_key" "$ROB_DIR/long_key.lua"
t_result "and it round-trips" 0 "1"

long_dotted="prefix.$(printf 'k%.0s' $(seq 1 500))"
types_fixture "$ROB_DIR/long_dotted.lua"
cli set "general:$long_dotted" 2 "$ROB_DIR/long_dotted.lua"
t_result "a 500 character dotted option name" 0 "$ROB_DIR/long_dotted.lua"
t_contains "which is bracketed on the way in" "[\"$long_dotted\"] = 2," "$(cat "$ROB_DIR/long_dotted.lua")"
cli get "general:$long_dotted" "$ROB_DIR/long_dotted.lua"
t_result "and it round-trips" 0 "2"

# ---------------------------------------------------------------------------
# The shebang
# ---------------------------------------------------------------------------

t_section "the shebang makes the file runnable on its own"

if [[ -x $CLI ]]; then
  types_fixture "$T_ROOT/shebang.lua"
  SHEBANG_OUT="$("$CLI" get general:border_size "$T_ROOT/shebang.lua" 2>"$RUN/shebang_err")"
  SHEBANG_RC=$?
  t_eq "run directly, the value is the same" "2" "$SHEBANG_OUT"
  t_eq "run directly, the exit status is the same" 0 "$SHEBANG_RC"
  t_empty "run directly, stderr is empty" "$(cat "$RUN/shebang_err")"

  types_fixture "$T_ROOT/shebang_set.lua"
  "$CLI" set general:border_size 4 "$T_ROOT/shebang_set.lua" >"$RUN/shebang_out" 2>"$RUN/shebang_err"
  t_eq "a set run directly prints its path" "$T_ROOT/shebang_set.lua" "$(cat "$RUN/shebang_out")"
  t_lines "and exactly one line of it" 1 "$(wc -l <"$RUN/shebang_out")"
  cli get general:border_size "$T_ROOT/shebang_set.lua"
  t_eq "with the value written" "4" "$OUT"
else
  t_skip "the CLI is executable through its shebang" "$CLI is not executable"
fi

t_summary
