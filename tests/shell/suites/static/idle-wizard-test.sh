#!/bin/bash
# Suite: idle-wizard - the Add timer wizard asks for minutes and a command.
#
# The wizard is the only way the menu creates a timer, and its shape is a
# product decision rather than an implementation detail: a timer is a
# COMMAND, so the wizard asks for the minutes to wait and then for the
# command to run. There is no action stage, because a stage offering
# "Lock session", "Suspend" or "Run command" would put the choice back in
# front of the user for a decision the command text already makes - and
# "Run command" as an option is a stage that exists only to be answered.
#
# Two things follow from that, and both are pinned here:
#
#   1. The flow is two stages, a number and a text. A select stage in the
#      middle is the defect this suite exists to catch: it would put the
#      action dropdown between the minutes and the command field, which is
#      exactly the "one more click before the field" shape the wizard was
#      changed to remove.
#   2. The commit writes a command row and only a command row. A wizard
#      that can still write a bare lock or suspend row keeps the second
#      model alive in the one place a user can reach it.
#
# This is a SOURCE suite: the Idle page is a menu surface, and a menu
# surface cannot be constructed headlessly (no PanelWindow backend under
# QT_QPA_PLATFORM=offscreen), so the flow literal is lifted out of the
# daemon and evaluated - the same way boot-catalog-test.sh lifts
# Boot.qml's catalog. The two names the literal closes over (the minute
# floor and the daemon's own action list) are stubbed: the minute floor
# is a number, and the action list is empty, so a flow that reached for
# it would evaluate to a select stage with no options rather than a
# crash - which is the shape the "no action stage" assertion then fails.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "idle-wizard" "the Add timer wizard: minutes, then the command to run, and never an action picker"

require_tools node sed

DAEMON="$SHELL_DIR/services/session/IdleDaemon.qml"
t_file "the idle daemon is where the wizard lives" "$DAEMON"
DAEMON_SRC="$(<"$DAEMON")"

# --- the flow literal, lifted and evaluated ---------------------------------

FLOW_RECORDS="$(DAEMON="$DAEMON" node - <<'NODE'
const fs = require("fs")
const src = fs.readFileSync(process.env.DAEMON, "utf8")

// The Add timer row's flow, located by the id that owns it, so a flow
// belonging to some other row is never the one measured.
const idAt = src.indexOf('id: "idle-add"')
if (idAt < 0) {
  process.stdout.write("error=no idle-add row\n")
  process.exit(0)
}
const at = src.indexOf("flow: [", idAt)
if (at < 0) {
  process.stdout.write("error=no flow on the idle-add row\n")
  process.exit(0)
}
const start = src.indexOf("[", at)

// Bracket balance that does not trip over braces inside strings or comments.
let i = start
let depth = 0
let end = -1
while (i < src.length) {
  const c = src[i]
  if (c === '"' || c === "'") {
    const quote = c
    i++
    while (i < src.length) {
      if (src[i] === "\\") { i += 2; continue }
      if (src[i] === quote) { i++; break }
      i++
    }
    continue
  }
  if (c === "/" && src[i + 1] === "/") {
    while (i < src.length && src[i] !== "\n") i++
    continue
  }
  if (c === "/" && src[i + 1] === "*") {
    const close = src.indexOf("*/", i + 2)
    i = close < 0 ? src.length : close + 2
    continue
  }
  if (c === "[" || c === "(" || c === "{") { depth++; i++; continue }
  if (c === "]" || c === ")" || c === "}") {
    depth--
    if (depth === 0) { end = i; break }
    i++
    continue
  }
  i++
}
if (end < 0) {
  process.stdout.write("error=unterminated flow literal\n")
  process.exit(0)
}

let flow = null
try {
  flow = new Function("minMinutes", "root",
    "return (" + src.slice(start, end + 1) + ")")(1, { _actionOptions: () => [] })
} catch (e) {
  process.stdout.write("error=the flow literal does not evaluate: " + String(e.message) + "\n")
  process.exit(0)
}
if (!Array.isArray(flow)) {
  process.stdout.write("error=the flow is not a list of stages\n")
  process.exit(0)
}

const out = []
const rec = (k, v) => out.push(k + "=" + v)
rec("count", flow.length)
rec("kinds", flow.map(s => String(s.kind)).join(","))
rec("selects", flow.filter(s => s.kind === "select").length)
rec("options", flow.filter(s => s.options !== undefined).length)
const number = flow.find(s => s.kind === "number")
rec("numberMin", number ? number.min : "-")
rec("numberMax", number ? number.max : "-")
rec("numberUnit", number ? (number.unit === undefined ? "-" : number.unit) : "-")
const text = flow.find(s => s.kind === "text")
rec("textPlaceholder", text ? (text.placeholder === undefined ? "-" : text.placeholder) : "-")
process.stdout.write(out.join("\n") + "\n")
NODE
)"

flow_fact() {
  printf '%s\n' "$FLOW_RECORDS" | grep -m1 "^$1=" | cut -d= -f2-
}

t_section "the wizard asks for the minutes, then for the command"

t_eq "the flow literal evaluates" "" "$(printf '%s\n' "$FLOW_RECORDS" | grep -m1 '^error=' | cut -d= -f2-)"
t_eq "the flow is two stages" "2" "$(flow_fact count)"
t_eq "a number stage and a text stage, in that order" "number,text" "$(flow_fact kinds)"
t_eq "the number stage is the minutes" "1" "$(flow_fact numberMin)"
t_eq "capped at a week" "10080" "$(flow_fact numberMax)"
t_eq "and carries its unit" "min" "$(flow_fact numberUnit)"
t_eq "the text stage names the hint it shows" "e.g. vb-shell session lock" "$(flow_fact textPlaceholder)"

t_section "no stage offers a choice"

# The stage that was removed: an action picker between the minutes and the
# command field. Its return is the "one more click" the wizard exists to
# avoid, so its absence is the contract rather than a detail.
t_eq "no stage is a select" "0" "$(flow_fact selects)"
t_eq "and no stage brings an option list" "0" "$(flow_fact options)"
t_not_contains "the daemon keeps no action-option list" "_actionOptions" "$DAEMON_SRC"
t_not_contains "and no option is spelled out for the picker" 'label: "Run command"' "$DAEMON_SRC"

t_section "the commit writes a command row, and only a command row"

COMMIT_SRC="$(sed -n '/^  function commitAddWizard/,/^  }$/p' "$DAEMON")"
t_contains "the wizard's commit writes a command row" 'action: "command"' "$COMMIT_SRC"
t_not_contains "and never a bare lock action" 'action: "lock"' "$COMMIT_SRC"
t_not_contains "nor a bare suspend action" 'action: "suspend"' "$COMMIT_SRC"
# The stage it reads the command from is found by KIND, so the commit
# survives a stage being inserted or reordered - and a stage that is
# missing leaves the command empty, which the commit refuses.
t_contains "the command stage is located by kind" 'stages[s].kind === "text"' "$COMMIT_SRC"
t_contains "and an empty command is refused" 'if (command === "") return true' "$COMMIT_SRC"

t_note "the wizard's two stages are the whole flow: the minutes to wait, then the command to run - the action a timer performs is what its command says, so a stage that offered 'Lock session' or 'Suspend' would only ask the user to say it twice"
t_summary
