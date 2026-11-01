#!/bin/bash
# Suite: provider-claim - a provider id is claimed in ONE place, and the claim
# behaves.
#
# ProviderHost hands a record to the host Menu once and refuses a
# re-registration whose owner is a different object, so a record is only ever
# replaceable by the object that owns it. A claim can fail while nobody else
# wants the id for exactly one reason: this host still lists a dead predecessor.
# The recovery is therefore a property of the ID SPACE, not of the unit asking.
#
# Six units had each written the same recover-and-retry sequence around
# registerProvider - Bar, AppLauncher, ThemeRemover, Timer, Inhibitor,
# Recording - with the same reasoning copied into six comment blocks. Every copy
# was free to drift from the others, and a drifted copy fails by pinning a
# surface to a dead closure (the row keeps a confirm no live owner can run) or
# by retrying a claim that will never succeed.
#
# Two halves, and the first is the one that matters:
#
#   * BEHAVIOUR, in the live registry: a claim either takes the id or leaves the
#     record exactly as it was, only the owner releases it, the recovery is the
#     host's own and it is synchronous, and a bad argument is refused rather
#     than stored. The probe calls ProviderHost itself; nothing below reads the
#     source to find out what the claim does.
#   * SHAPE, only for the half no runtime can show: the six units call the host
#     directly instead of wrapping it, so there is no seventh copy to drift.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "provider-claim" "provider ids are claimed in one place, and the claim behaves"

require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/provider-claim.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "0" "$(qp_get threw)"

# ---------------------------------------------------------------------
t_section "a claim takes the id, or leaves the record exactly as it was"

t_eq "a free id is taken" "true" "$(qp_get claim.free)"
t_eq "and it resolves to the surface that was handed in" "true" "$(qp_get claim.free.same)"
t_eq "a foreign owner is refused" "false" "$(qp_get claim.foreign)"
# A refusal that also replaced the record would be worse than an accepted one:
# the row would carry a surface no live owner can run.
t_eq "and the record is untouched by the refusal" "true" "$(qp_get claim.foreign.same)"
t_eq "the owner may replace its own surface" "true" "$(qp_get claim.own)"
t_eq "and the id resolves to the new one" "true" "$(qp_get claim.own.same)"
t_eq "an unowned claim cannot take a live one" "false" "$(qp_get claim.unowned)"
t_eq "and leaves it alone too" "true" "$(qp_get claim.unowned.same)"
t_eq "two ids are two records" "true" "$(qp_get ids.independent)"
t_eq "and claiming one does not displace the other" "true" "$(qp_get ids.independent.same)"

# ---------------------------------------------------------------------
t_section "only the owner releases, and the release is synchronous"

t_eq "a foreign release is refused" "false" "$(qp_get release.foreign)"
t_eq "and changes nothing" "true" "$(qp_get release.foreign.same)"
t_eq "the owner's release lands" "true" "$(qp_get release.own)"
t_eq "and the id is free in the same turn" "true" "$(qp_get release.own.gone)"
t_eq "so anybody may claim it next" "true" "$(qp_get claim.after.release)"
t_eq "and gets the id" "true" "$(qp_get claim.after.release.same)"

# ---------------------------------------------------------------------
t_section "the recovery is the host's, and it happens in the same call"

# This is the assertion a deferred retry fails: the host drops its own stale
# record and claims again before returning, so the answer is true and the id is
# held NOW rather than two event-loop turns later.
t_eq "an owner reclaiming over its own record succeeds" "true" "$(qp_get recovery.reclaim)"
t_eq "and holds the id immediately" "true" "$(qp_get recovery.reclaim.same)"

# ---------------------------------------------------------------------
t_section "a bad argument is refused, never stored"

t_eq "an empty id" "false" "$(qp_get reject.empty.id)"
t_eq "a blank id" "false" "$(qp_get reject.blank.id)"
t_eq "a null provider" "false" "$(qp_get reject.null.provider)"
t_eq "an array is not a provider" "false" "$(qp_get reject.array.provider)"
t_eq "and none of them left a record behind" "true" "$(qp_get reject.stored.nothing)"
t_eq "an unknown id reads as null" "true" "$(qp_get unknown.id)"
t_eq "the probe cleaned up after itself" "true" "$(qp_get cleanup)"

# ---------------------------------------------------------------------
t_section "and every unit that owns an id calls the host directly"

HOST="$SHELL_DIR/common/runtime/ProviderHost.qml"
HOST_SRC="$(<"$HOST")"

t_file "ProviderHost is where the id space lives" "$HOST"
t_contains "it answers a claim" "function claimProvider(id, surface, owner)" "$HOST_SRC"
# The retry was the half that got copied six times, and it was unreachable: all
# six callers passed the deferred flag false. Pinned as gone, so a comeback has
# to bring a caller that needs it.
# The retry went through DeferredQueue; with no caller needing it, the queue is
# not mentioned by a call any more (the comment above says why it is gone).
t_not_contains "no deferred retry is left in the host" "DeferredQueue.run" "$HOST_SRC"
t_not_contains "and the claim takes no fourth argument" \
  "function claimProvider(id, surface, owner, deferred)" "$HOST_SRC"

UNITS=(
  "features/bar/Bar.qml"
  "features/launcher/AppLauncher.qml"
  "features/pickers/theme/ThemeRemover.qml"
  "services/media/Timer.qml"
  "services/media/Recording.qml"
  "services/power/Inhibitor.qml"
)
PINNED=0
for rel in "${UNITS[@]}"; do
  src="$(<"$SHELL_DIR/$rel")"
  t_contains "$(basename "$rel") calls the host" "ProviderHost.claimProvider(" "$src"
  t_not_contains "and defines no passthrough of its own" "function _claimProviderId" "$src"
  PINNED=$((PINNED + 1))
done
t_eq "and the scan cannot shrink: six units are pinned" "6" "$PINNED"
# One definition of the claim in the whole tree. A second would be a copy by
# another name, which is what the six passthroughs were.
t_eq "the claim is defined once in the tree" "1" \
  "$(grep -rl "function claimProvider(" "$SHELL_DIR" --include='*.qml' --include='*.js' | wc -l | tr -d ' ')"

t_note "the host Menu still registers as ProviderHost's host and gets every record replayed from the host's own map, so a unit's direct call changes nothing about when a row arrives - only about how many copies of the recovery exist"

t_summary
