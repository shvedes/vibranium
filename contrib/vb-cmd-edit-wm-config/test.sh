#!/usr/bin/env bash
set -euo pipefail

BIN="${1:-./target/release/vb-cmd-edit-wm-config}"

if [[ ! -x "$BIN" ]]; then
  echo "Binary not found or not executable: $BIN"
  echo "Usage: $0 [path/to/binary]"
  exit 1
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

PASS=0
FAIL=0
WORK=$(mktemp -d)
# trap 'rm -rf "$WORK"' EXIT

pass() {
  echo "  PASS  $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL  $1"
  echo "        expected: $2"
  echo "        got:      $3"
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local desc="$1" expected="$2" got="$3"
  if [[ "$expected" == "$got" ]]; then pass "$desc"; else fail "$desc" "$expected" "$got"; fi
}

assert_contains() {
  local desc="$1" needle="$2" file="$3"
  if grep -qF "$needle" "$file"; then
    pass "$desc"
  else fail "$desc" "(contains) $needle" "(not found in file)"; fi
}

assert_not_contains() {
  local desc="$1" needle="$2" file="$3"
  if ! grep -qF "$needle" "$file"; then
    pass "$desc"
  else fail "$desc" "(not present) $needle" "(was found in file)"; fi
}

assert_exit() {
  local desc="$1" expected_code="$2"
  shift 2
  local code=0
  "$@" >/dev/null 2>&1 || code=$?
  if [[ "$code" == "$expected_code" ]]; then
    pass "$desc"
  else fail "$desc" "exit $expected_code" "exit $code"; fi
}

# Run a command, capture stdout, assert it equals the expected string.
assert_output() {
  local desc="$1" expected="$2"
  shift 2
  local got
  got=$("$@" 2>/dev/null) || true
  if [[ "$got" == "$expected" ]]; then
    pass "$desc"
  else fail "$desc" "$expected" "$got"; fi
}

make_conf() {
  local f
  f=$(mktemp "$WORK/conf.XXXXXX")
  cat >"$f" <<'EOF'
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    layout = dwindle
}

decoration {
    rounding = 10

    blur {
        enabled = true
        size = 3
        passes = 1
    }
}

animations {
    enabled = yes
}

misc {
    force_default_wallpaper = -1
}
EOF
  echo "$f"
}

# ─── WRITE: update existing value ────────────────────────────────────────────
echo ""
echo "── write: update existing value ────────────────────────────────────────"

F=$(make_conf)
"$BIN" "general:gaps_in:99" "$F"
assert_contains "update section option" "gaps_in = 99" "$F"
assert_not_contains "old value gone" "gaps_in = 5" "$F"

F=$(make_conf)
"$BIN" "decoration:rounding:5" "$F"
assert_contains "update nested option" "rounding = 5" "$F"
assert_not_contains "old rounding gone" "rounding = 10" "$F"

F=$(make_conf)
"$BIN" "decoration:blur:passes:4" "$F"
assert_contains "update deeply nested option" "passes = 4" "$F"
assert_not_contains "old passes gone" "passes = 1" "$F"

F=$(make_conf)
"$BIN" "animations:enabled:no" "$F"
assert_contains "update boolean value" "enabled = no" "$F"

# ─── WRITE: no side-effects on other keys ────────────────────────────────────
echo ""
echo "── write: no side-effects on other keys ────────────────────────────────"

F=$(make_conf)
"$BIN" "general:gaps_in:77" "$F"
assert_contains "gaps_out untouched" "gaps_out = 10" "$F"
assert_contains "border_size untouched" "border_size = 2" "$F"
assert_contains "rounding untouched" "rounding = 10" "$F"
assert_contains "blur:size untouched" "size = 3" "$F"
assert_contains "animations:enabled untouched" "enabled = yes" "$F"

# ─── WRITE: create new option in existing section ────────────────────────────
echo ""
echo "── write: add new option to existing section ───────────────────────────"

F=$(make_conf)
"$BIN" "general:new_option:hello" "$F"
assert_contains "new option in existing section" "new_option = hello" "$F"
assert_contains "existing option still intact" "gaps_in = 5" "$F"

F=$(make_conf)
"$BIN" "decoration:blur:new_key:val" "$F"
assert_contains "new option in existing nested section" "new_key = val" "$F"

# ─── WRITE: create new sections ──────────────────────────────────────────────
echo ""
echo "── write: create new sections ──────────────────────────────────────────"

F=$(make_conf)
"$BIN" "input:repeat_rate:25" "$F"
assert_contains "new section created" "input {" "$F"
assert_contains "new section option" "repeat_rate = 25" "$F"

F=$(make_conf)
"$BIN" "input:touchpad:natural_scroll:yes" "$F"
assert_contains "new doubly-nested section" "touchpad {" "$F"
assert_contains "new doubly-nested option" "natural_scroll = yes" "$F"

F=$(make_conf)
"$BIN" "a:b:c:d:42" "$F"
assert_contains "triply-nested section a" "a {" "$F"
assert_contains "triply-nested section b" "b {" "$F"
assert_contains "triply-nested section c" "c {" "$F"
assert_contains "triply-nested option d" "d = 42" "$F"

# ─── WRITE: top-level (no section) option ────────────────────────────────────
echo ""
echo "── write: top-level options ────────────────────────────────────────────"

F=$(mktemp "$WORK/toplevel.XXXXXX")
printf 'monitor = ,preferred,auto,1\n' >"$F"
"$BIN" "monitor:eDP-1" "$F"
assert_contains "update top-level option" "monitor = eDP-1" "$F"
assert_not_contains "old top-level value gone" "monitor = ,preferred" "$F"

F=$(mktemp "$WORK/toplevel2.XXXXXX")
"$BIN" "my_key:my_val" "$F"
assert_contains "create new top-level option" "my_key = my_val" "$F"

# ─── WRITE: create from empty / missing file ─────────────────────────────────
echo ""
echo "── write: create from empty / missing file ─────────────────────────────"

F=$(mktemp "$WORK/empty.XXXXXX")
"$BIN" "general:gaps_in:3" "$F"
assert_contains "write to empty file" "gaps_in = 3" "$F"

F="$WORK/nonexistent_new.conf"
"$BIN" "general:gaps_in:7" "$F"
assert_contains "write to non-existent file" "gaps_in = 7" "$F"

# ─── WRITE: idempotency ───────────────────────────────────────────────────────
echo ""
echo "── write: idempotency ──────────────────────────────────────────────────"

F=$(make_conf)
"$BIN" "general:gaps_in:99" "$F"
"$BIN" "general:gaps_in:99" "$F"
assert_contains "second write doesn't corrupt" "gaps_in = 99" "$F"
COUNT=$(grep -c "gaps_in" "$F")
assert_eq "no duplicate key lines" "1" "$COUNT"

# ─── WRITE: quote stripping ───────────────────────────────────────────────────
echo ""
echo "── write: quote stripping ──────────────────────────────────────────────"

F=$(make_conf)
"$BIN" 'general:gaps_in:"42"' "$F"
assert_contains "double-quoted value stripped" "gaps_in = 42" "$F"
assert_not_contains "quotes not written to file" 'gaps_in = "42"' "$F"

F=$(make_conf)
"$BIN" "general:gaps_in:'7'" "$F"
assert_contains "single-quoted value stripped" "gaps_in = 7" "$F"

# ─── WRITE: indentation preserved ────────────────────────────────────────────
echo ""
echo "── write: indentation preserved ────────────────────────────────────────"

F=$(mktemp "$WORK/indent2.XXXXXX")
printf 'general {\n  gaps_in = 5\n  gaps_out = 10\n}\n' >"$F"
"$BIN" "general:gaps_in:99" "$F"
assert_contains "2-space indent on update" "  gaps_in = 99" "$F"
"$BIN" "general:new_key:hello" "$F"
assert_contains "2-space indent on new key" "  new_key = hello" "$F"

F=$(mktemp "$WORK/indenttab.XXXXXX")
printf 'general {\n\tgaps_in = 5\n}\n' >"$F"
"$BIN" "general:new_key:hello" "$F"
assert_contains "tab indent on new key" "$(printf '\tnew_key = hello')" "$F"

# ─── WRITE: empty value rejected ─────────────────────────────────────────────
echo ""
echo "── write: empty value rejected ─────────────────────────────────────────"

F=$(make_conf)
assert_exit "empty double-quote rejected" 1 "$BIN" 'general:gaps_in:""' "$F"
assert_exit "empty single-quote rejected" 1 "$BIN" "general:gaps_in:''" "$F"

# ─── Error cases ─────────────────────────────────────────────────────────────
echo ""
echo "── error cases ─────────────────────────────────────────────────────────"

assert_exit "too few args exits 1" 1 "$BIN" "onlyonepath"

# ─── @occurrence selector ─────────────────────────────────────────────────────
echo ""
echo "── @occurrence selector ────────────────────────────────────────────────"

F=$(mktemp "$WORK/occ.XXXXXX")
cat >"$F" <<'EOF'
monitor {
    name = eDP-1
    width = 1920
}

monitor {
    name = HDMI-1
    width = 1920
}

monitor {
    name = DP-1
    width = 1920
}
EOF

"$BIN" "monitor:width:3840@2" "$F"
WIDTHS=$(grep "width" "$F" | awk -F'= ' '{print $2}' | tr -d ' \n')
assert_eq "@2 changes only second block" "192038401920" "$WIDTHS"

"$BIN" "monitor:width:2560@-1" "$F"
WIDTHS=$(grep "width" "$F" | awk -F'= ' '{print $2}' | tr -d ' \n')
assert_eq "@-1 changes only last block" "192038402560" "$WIDTHS"

# ─── READ: basic retrieval ────────────────────────────────────────────────────
echo ""
echo "── read: basic retrieval ───────────────────────────────────────────────"

F=$(make_conf)

# Single-level section option.
assert_output "read section option" "5" "$BIN" --get "general:gaps_in" "$F"
assert_output "read another section option" "10" "$BIN" --get "general:gaps_out" "$F"
assert_output "read string option" "dwindle" "$BIN" --get "general:layout" "$F"

# Two levels deep.
assert_output "read nested option" "10" "$BIN" --get "decoration:rounding" "$F"

# Three levels deep.
assert_output "read doubly-nested option" "true" "$BIN" --get "decoration:blur:enabled" "$F"
assert_output "read doubly-nested number" "3" "$BIN" --get "decoration:blur:size" "$F"
assert_output "read doubly-nested passes" "1" "$BIN" --get "decoration:blur:passes" "$F"

# Negative value as-is.
assert_output "read negative value" "-1" "$BIN" --get "misc:force_default_wallpaper" "$F"

# ─── READ: top-level option ───────────────────────────────────────────────────
echo ""
echo "── read: top-level option ──────────────────────────────────────────────"

F=$(mktemp "$WORK/toplevel_read.XXXXXX")
printf 'monitor = eDP-1\nsome_flag = 42\n' >"$F"

assert_output "read top-level option" "eDP-1" "$BIN" --get "monitor" "$F"
assert_output "read top-level numeric option" "42" "$BIN" --get "some_flag" "$F"

# ─── READ: value with spaces preserved ───────────────────────────────────────
echo ""
echo "── read: value with spaces ─────────────────────────────────────────────"

F=$(mktemp "$WORK/spaces.XXXXXX")
cat >"$F" <<'EOF'
general {
    label = hello world
}
EOF

assert_output "read value containing spaces" "hello world" "$BIN" --get "general:label" "$F"

# ─── READ: round-trip with write ─────────────────────────────────────────────
echo ""
echo "── read: round-trip with write ─────────────────────────────────────────"

F=$(make_conf)

# Write a new value then read it back; must match exactly.
"$BIN" "decoration:blur:size:8" "$F"
assert_output "round-trip nested update" "8" "$BIN" --get "decoration:blur:size" "$F"

"$BIN" "general:gaps_in:42" "$F"
assert_output "round-trip section update" "42" "$BIN" --get "general:gaps_in" "$F"

# Write a brand-new option then read it back.
"$BIN" "general:new_key:hello" "$F"
assert_output "round-trip new option" "hello" "$BIN" --get "general:new_key" "$F"

# Write a new nested section + option then read it back.
"$BIN" "input:touchpad:natural_scroll:yes" "$F"
assert_output "round-trip new nested section" "yes" "$BIN" --get "input:touchpad:natural_scroll" "$F"

# ─── READ: @occurrence selector ───────────────────────────────────────────────
echo ""
echo "── read: @occurrence selector ──────────────────────────────────────────"

F=$(mktemp "$WORK/occ_read.XXXXXX")
cat >"$F" <<'EOF'
monitor {
    name = eDP-1
}

monitor {
    name = HDMI-1
}

monitor {
    name = DP-1
}
EOF

assert_output "read @1 (first block)" "eDP-1" "$BIN" --get "monitor:name@1" "$F"
assert_output "read @2 (second block)" "HDMI-1" "$BIN" --get "monitor:name@2" "$F"
assert_output "read @3 (third block)" "DP-1" "$BIN" --get "monitor:name@3" "$F"
assert_output "read @-1 (last block)" "DP-1" "$BIN" --get "monitor:name@-1" "$F"
assert_output "read @-2 (second-last)" "HDMI-1" "$BIN" --get "monitor:name@-2" "$F"

# ─── READ: missing option / section exits 1 silently ─────────────────────────
echo ""
echo "── read: missing option / section exits 1 silently ─────────────────────"

F=$(make_conf)

assert_exit "missing option in real section exits 1" 1 "$BIN" --get "general:nonexistent" "$F"
assert_exit "missing section exits 1" 1 "$BIN" --get "nosuchsection:opt" "$F"
assert_exit "missing nested option exits 1" 1 "$BIN" --get "decoration:blur:nosuchkey" "$F"
assert_exit "out-of-range @occurrence exits 1" 1 "$BIN" --get "general:gaps_in@99" "$F"
assert_exit "missing top-level option exits 1" 1 "$BIN" --get "nosuchkey" "$F"

# No output should be produced for a miss (stdout must be empty).
GOT=$("$BIN" --get "general:nonexistent" "$F" 2>/dev/null || true)
assert_eq "miss produces no stdout" "" "$GOT"

# ─── READ: does not mutate the file ───────────────────────────────────────────
echo ""
echo "── read: does not mutate the file ──────────────────────────────────────"

F=$(make_conf)
BEFORE=$(cat "$F")
"$BIN" --get "decoration:blur:size" "$F" >/dev/null
AFTER=$(cat "$F")
assert_eq "file unchanged after read" "$BEFORE" "$AFTER"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────"
echo "  $PASS passed,  $FAIL failed"
echo "────────────────────────────────────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]]
