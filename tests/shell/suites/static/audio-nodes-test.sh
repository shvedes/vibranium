#!/usr/bin/env bash
# Suite: shell/common/audio/ - the Pipewire graph observation
#
# Four `Connections` handlers in AudioNodes.qml were written against a Pipewire
# service that emits `nodeAdded`/`nodeRemoved`/`linkAdded`/`linkRemoved`. It does
# not. Read out of Quickshell's own typeinfo, the `Pipewire` type exports NO
# SIGNALS AT ALL - those four names exist as C++ METHODS, which are
# Quickshell's internal PipeWire callbacks exposed as invokable and are not
# emittable.
#
# A `Connections { target: Pipewire; function onNodeAdded() }` therefore declares
# a handler for a signal that does not exist. Qt says so once per handler, every
# start:
#
#   WARN scene: QML Connections at @common/audio/AudioNodes.qml[517:3]: Detected
#   function "onNodeAdded" in Connections element. This is probably intended to
#   be a signal handler but no signal of the target matches the name.
#
# Four warnings, and - the part that matters - four handlers that never ran. The
# audio graph was not being observed at all.
#
# The observable is the MODEL. `Pipewire.nodes` and `Pipewire.links` are
# `UntypedObjectModel`s, which emit objectInserted/Removed Pre/Post. This suite
# reads that typeinfo directly rather than restating it, so the assertions
# cannot drift from the API the shell is actually compiled against.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "audio-nodes" "the Pipewire graph observation: handler names against the real typeinfo"

require_tools node grep sed

AN="$SHELL_DIR/common/audio/AudioNodes.qml"
QMLTYPES_DIR=/usr/lib/qt6/qml/Quickshell
PIPEWIRE_TYPES="$QMLTYPES_DIR/Services/Pipewire/quickshell-service-pipewire.qmltypes"
CORE_TYPES="$QMLTYPES_DIR/quickshell-core.qmltypes"

t_section "the typeinfo this suite reads is actually there"

t_file "the Pipewire typeinfo exists" "$PIPEWIRE_TYPES"
t_file "the core typeinfo exists" "$CORE_TYPES"

# One node, printing what QS really publishes. Reused by every assertion below so
# that the ground truth is read once and stated once.
# Two LINES, not one line with a separator. `Pipewire` publishes no signals, so
# the Signal list is empty, so a "|" separator produced a string with no space in
# it and `read` handed the whole thing to the first variable as a single word.
# The empty answer is the finding; losing it to word splitting would have hidden
# exactly the thing this suite exists to state.
# `mapfile`, not `read`. `read` is line-oriented by definition: it consumes up to
# the FIRST newline and stops, so a two-line payload handed it the empty Signal
# line and left the methods unread - which is how the finding this suite exists
# to state got lost twice. A leading empty line is exactly what an honest "no
# signals" answer looks like, so the transport has to preserve it.
mapfile -t _pw <<<"$(node -e '
  const fs = require("fs")
  const pw = fs.readFileSync(process.argv[1], "utf8")
  const i = pw.indexOf("qs::service::pipewire::Pipewire")
  // Bounded at the NEXT component, not at a fixed character count: a window wide
  // enough to hold the Pipewire block also reaches into PwAudioChannel, whose
  // only method is toString, and a stray toString in a list of PipeWire callbacks
  // is a wrong answer that reads as a formatting problem.
  const end = pw.indexOf("Component {", i + 10)
  const blk = pw.slice(i, end > 0 ? end : i + 8000)
  const grab = (re) => [...blk.matchAll(re)].map(m => m[1])
  const sigs = grab(/Signal \{\n\s*name: "([A-Za-z]+)"/g)
  const meths = grab(/Method \{\n\s*name: "([A-Za-z]+)"/g)
  process.stdout.write(sigs.join(",") + "\n" + meths.join(","))
' "$PIPEWIRE_TYPES")"
PW_SIGS="${_pw[0]:-}"
PW_METHODS="${_pw[1]:-}"

MODEL_SIGS="$(node -e '
  const fs = require("fs")
  const co = fs.readFileSync(process.argv[1], "utf8")
  const j = co.indexOf("name: \"UntypedObjectModel\"")
  process.stdout.write([...co.slice(j, j + 4000).matchAll(/Signal \{\n\s*name: "([A-Za-z]+)"/g)].map(m => m[1]).join(","))
' "$CORE_TYPES")"

# ---------------------------------------------------------------------------
# The four dead handlers.
# ---------------------------------------------------------------------------
t_section "the four handlers that never fired are gone"

# The finding itself, restated from the typeinfo rather than from a comment, so
# that a future QS upgrade which DOES add these signals shows up here as a
# failure to re-check rather than as a passing test nobody reads.
t_eq "the Pipewire singleton publishes no signals at all" "" "$PW_SIGS"
t_eq "and the four names are METHODS, not signals" \
  "onNodeAdded,onNodeRemoved,onLinkAdded,onLinkRemoved,onLinkGroupAdded,onLinkGroupRemoved" \
  "$PW_METHODS"

# A method is invokable and not emittable, which is the whole trap: the names are
# RIGHT, so grep finds them, qmllint is silent, and the code reads correctly. Only
# the runtime knows the difference.
t_eq "so no Connections handler may name one" "0" \
  "$(grep -cE 'function on(Node|Link)(Group)?(Added|Removed)[[:space:]]*\(' "$AN" || true)"

# The `target: Pipewire` form is the specific mistake: it is the singleton that
# has no signals, as against the models below which do.
t_eq "and nothing targets the bare Pipewire singleton" "0" \
  "$(grep -cE '^[[:space:]]*target:[[:space:]]*Pipewire[[:space:]]*$' "$AN" || true)"

# ---------------------------------------------------------------------------
# What replaced them.
# ---------------------------------------------------------------------------
t_section "the node set is observed through one subscription, not per-object signals"

t_eq "UntypedObjectModel publishes insert/remove, Pre and Post" \
  "objectInsertedPre,objectInsertedPost,objectRemovedPre,objectRemovedPost" \
  "$MODEL_SIGS"

# The models are published asynchronously, so `Pipewire.nodes` is null for a beat
# at startup. The guard used to sit in a `Connections` `target:` binding, where an
# unguarded `Pipewire.nodes` was inert rather than fatal and produced no
# complaint. It now sits in the `.values` read that feeds every consumer, and a
# missing ternary there is an unguarded null dereference on the shell's first
# frame rather than a dead handler - so the guard is asserted where it moved.
t_eq "the nodes read is guarded against a null model" "1" \
  "$(grep -cE 'readonly property var nodes: Pipewire\.nodes \? Pipewire\.nodes\.values : \[\]' "$AN" || true)"
t_eq "and so is the links read" "1" \
  "$(grep -cE 'readonly property var linkValues: Pipewire\.links \? Pipewire\.links\.values : \[\]' "$AN" || true)"

# `onNodesChanged` is the SOLE subscription to the node set. It has to be exactly
# one: a second subscriber would be a second re-pointing of the tracker, and a
# dropped one is the bug this file originally had - a graph whose nodes arrive
# and leave with nothing following them.
t_eq "the node set is subscribed to exactly once" "1" \
  "$(grep -cE '^[[:space:]]*onNodesChanged:[[:space:]]*\{' "$AN" || true)"

# And the subscription does the one thing it must: hand the new set to the tracker
# that holds the observations. A handler that fired without re-pointing would pass
# the count above and observe nothing.
t_eq "and it re-points the single object tracker at the new set" "1" \
  "$(grep -cE 'root\._objectTracker\.objects = root\.nodes' "$AN" || true)"

# One tracker for the node set, created on the first observation and reused by
# every later one. Asserted as the early return rather than as the declaration:
# the declaration count cannot tell a shared tracker from one recreated per
# observer, and the early return is exactly the line that makes it shared.
t_eq "the tracker is reused, not recreated per observer" "1" \
  "$(grep -cE 'if \(root\._objectTracker !== null\) return root\._objectTracker' "$AN" || true)"

# ---------------------------------------------------------------------------
# The redaction contract survives the rewrite.
# ---------------------------------------------------------------------------
t_section "the redaction contract is unchanged by the fix"

# The redaction contract forbids exactly one field, `PwNodeIface.id`, because
# it is the only numeric identity in the PipeWire API. A fix that reached for the
# object to name it would have reintroduced the leak while removing a warning -
# and a warning is a much cheaper thing to live with.
# The contract is stated where the audio surfaces state it: Audio.qml's
# `_muteTransition` and PipeWireState.qml's default-node block both say that the
# numeric node id is graph state the shell's redaction contract forbids naming
# on any surface.
# NOT "the file never reads .id" - it must. `identity()` reads `node.id` to key
# the tracker that joins two outputs naming the same device, and that use is
# correct: the contract forbids LOGGING the id, not reading it. An earlier
# version of this assertion forbade the read and would have failed on the one
# piece of the file doing its job.
t_eq "the id is read exactly once, by identity()" "1" \
  "$(grep -cE '^[[:space:]]*const id = node\.id' "$AN" || true)"

# The assertion that is actually the contract: no log call is given one.
t_eq "and no log line is ever handed a node id" "0" \
  "$(grep -cE '(Log\.[a-z]+|_trace)\([^)]*\.id\b' "$AN" || true)"

t_eq "nor is identity()'s result" "0" \
  "$(grep -cE '(Log\.[a-z]+|_trace)\([^)]*identity\(' "$AN" || true)"

# The counts the tracker's consumers read are computed from the two `.values`
# lists, never from a counter a handler incremented. A count kept in a handler
# is a count that can disagree with the model it claims to describe, and these
# two are the only numbers a caller sees.
t_eq "the node count is counted off the model's values" "1" \
  "$(grep -cE 'nodeCount: root\.countOf\(root\.nodes\)' "$AN" || true)"
t_eq "and the link count off the link model's values" "1" \
  "$(grep -cE 'linkCount: root\.countOf\(root\.linkValues\)' "$AN" || true)"

t_summary
