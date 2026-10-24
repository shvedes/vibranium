#!/bin/bash
# Suite: the instantiation policy of common/ui/List.qml - how many delegates a
# list actually builds, as a function of model size.
#
# `list-test.sh` already pins the policy's CONSTANTS: listFullRows 150, the
# 100000px small-list buffer, the 300px wall buffer, the autoCache gate. Those
# are what the source says. This suite measures what the engine does with
# them, which nothing else in the tree can do: "is row 148 of a 149-row list a
# live delegate" is a property of Qt's prefetch, not of any QML expression, and
# it is the claim the whole policy rests on.
#
# Ui.qml:96-106 states the policy: lists under `listFullRows` "instantiate every
# delegate, so layout is exact and wrap seats never traverse estimates", while
# "4-digit walls stay estimated" and the cap is a cost cap in rows. The
# List.qml:1416-1418 comment names the dependents - the menu and the launcher
# rely on far-end wrap targets staying instantiated, which is why turning the
# buffer off (autoCache false) is a compat switch and not a tuning knob.
#
# So there are three things to pin, and they are different in kind:
#
#   1. THE BRANCH. Which buffer each side of the threshold resolves to, and
#      that the comparison is strict - 149 rows is a small list, 150 is
#      already a wall. Deterministic arithmetic.
#   2. THE CONSEQUENCE. A sub-threshold list has a delegate for every row,
#      far end included; a wall has a bounded, FLAT count - 200 rows and 2000
#      rows cost the same, which is the property "the unit cost scales with"
#      is asserting. Deterministic for a fixed geometry, and the relations
#      are asserted alongside the raw counts so a Qt prefetch change fails on
#      the informative one first.
#   3. THE COST. Measured and REPORTED, never asserted. Build time is a
#      property of this machine's CPU and of the offscreen platform plugin;
#      pinning a millisecond figure would be a flaky test wearing a number as
#      a costume. The delegate COUNT is the real cost driver and it is
#      deterministic, so that is what is asserted.
#
# Fixture geometry is held constant so model size is the only variable: a
# 300x300 viewport, Ui.rowMinH (34) delegates, List.qml's default 2px spacing -
# a 36px row pitch, so eight rows fill the viewport and a 149-row list is
# 5382px of content.
#
# What is NOT covered here, and is not claimed: real delegates. The row this
# measures is a bare Item of Ui.rowMinH height, because the question is how
# many of them the view builds, not what one costs - a real Entry.qml row
# carries three slots and a dropdown, so the absolute figures below are a
# floor on the per-delegate cost, never an estimate of it. Also not covered:
# GridView (GridList keeps its own policy), a model swapped while a slot is
# mid-unfold, and the add/remove transitions in flight, which defer the
# install and are not deterministic to sample.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "list-instantiation" "common/ui/List.qml: what the cacheBuffer policy actually instantiates"
require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/list-instantiation.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing during construction" "none" "$(qp_get probe.error)"
t_eq "and no observation in the whole run threw" "0" "$(qp_get probe.threw)"

# --- the branch ---------------------------------------------------------------

t_section "the branch: one buffer per side of a strict threshold"
qp_assert "the threshold is 150 rows" b.threshold 150
qp_assert "a 36px row pitch (rowMinH 34 plus the default 2px gap)" b.rowPitch 36
qp_assert "so a 300px viewport holds eight rows" b.viewportRows 8
qp_assert "149 rows resolve to the small-list buffer" b.sub 100000
qp_assert "which covers the whole list and some" b.subCount 149
qp_assert "200 rows resolve to the wall buffer" b.wall 300
qp_assert "and 2000 rows resolve to the same one" b.huge 300
qp_assert "with 2000 in the model" b.hugeCount 2000
qp_assert "the comparison is strict: 150 rows is already a wall" b.at 300
qp_assert "holding 150 rows" b.atCount 150
t_note "List.qml:1420 reads count < Ui.listFullRows, so the threshold itself belongs to the wall branch. Anything that sizes itself to 'at most listFullRows' and expects the fully-instantiated regime is off by one row."
qp_assert "autoCache false really is a zero buffer on a wall" b.noCache 0
qp_assert "and on a list that fits its viewport" b.noCacheSmall 0
qp_assert "while the default on the same rows is the small-list buffer" b.control 100000
t_note "contentItem.children is NOT the delegate count. Measured: 151 children against 149 live rows on a fully-instantiated list, and 19 against 17 on a wall - the same two view-internal items in both regimes. Anything that wants the delegate count has to ask the engine per index; counting children over-reports by two and would make a wall look like it prefetches more than it does."
qp_assert "the gap on a fully-instantiated list" b.subChildren 151
qp_assert "and the gap on a wall" b.wallChildren 19
qp_assert "a 2000-row wall has the same two extra" b.hugeChildren 19

# --- sub-threshold ------------------------------------------------------------

t_section "a sub-threshold list instantiates every row, far end included"
qp_assert "the list holds 149 rows" s.count 149
qp_assert "and has a live delegate for every one" s.live 149
qp_assert "which is the whole model" s.liveIsWhole true
qp_assert "the last row is a real delegate" s.lastLive true
qp_assert "and so is a row in the middle" s.midLive true
t_note "This is the contract the menu and the launcher are built on (List.qml:1416-1418): a wrap seat that lands on the far end of a small list finds a delegate there, so the seat never has to traverse the estimate table and never ratchets originY across a gap."
qp_assert "one row more and the far end is gone" s.atLastLive false
qp_assert "because 150 rows is a wall now" s.atBufferIsWall wall
qp_assert "which is bounded like one" s.atLive 17

# --- walls --------------------------------------------------------------------

t_section "a wall instantiates a bounded band, not the model"
qp_assert "the wall holds 200 rows" w.count 200
qp_assert "but only 17 delegates exist" w.live 17
qp_assert "which is fewer than the model" w.liveLtCount true
qp_assert "the far end is not instantiated" w.lastLive false
qp_assert "nor is the middle" w.midLive false
t_note "17 is the viewport's eight rows plus roughly the 300px buffer on each side (300/36 = 8.3 rows a side). It is Qt's prefetch arithmetic for this geometry, not a shell constant - the two branches above are the shell's decision, this number is the engine's. The relations below are the part that must survive a Qt change; the raw count is pinned so such a change fails loudly here rather than quietly somewhere else."
qp_assert "the table still describes the whole content" w.tableTotal 7198
qp_assert "and the row-pitch formula agrees with it" w.tableTotalFormula 7198
qp_assert "and it agrees with the laid-out content" w.tableMatchesContent true
t_note "The wall is estimated, not measured, and that is what makes the cap free: rows the view never builds resolve through the Ui.rowMinH floor, so a row still has a usable height without a delegate. The height TABLE is deliberately not asserted here - which rows land in it depends on which delegates had been measured by the time the probe read, so it is a timing-sensitive number and pinning it would be flaky. What is deterministic, and asserted, is that the table still totals the whole content."

t_section "a 4-digit model costs the same to hold as a small wall"
qp_assert "the big list holds 2000 rows" h.count 2000
qp_assert "and has the same 17 delegates" h.live 17
qp_assert "identical to the 200-row wall" h.liveEqWall true
qp_assert "and far fewer than its own model" h.liveLtCount true
qp_assert "so the far end is not built" h.lastLive false
qp_assert "the content still totals correctly" h.tableTotal 71998
qp_assert "and the same formula holds at 4 digits" h.tableTotalFormula 71998
t_note "This is the assertion the policy exists for, and the one that makes 'A cost cap in rows, the unit cost scales with' (Ui.qml:101) a fact rather than a claim: the per-row cost is bounded and flat in the row count, so a 4-digit list costs what a 200-row one costs to hold. Before this suite nothing in the tree checked it - list-test.sh pinned the buffers, and the referenced list-performance-test.sh that would have measured it is not in the tree."
qp_assert "a wall is still operable: the cursor seats at the last row" h.settleIndex 1999
qp_assert "and lands inside the model" h.settleInRange true
t_note "Bounded instantiation is not degraded operation: settling the cursor onto a row the view has not built still works, because the height table places an uninstantiated row without needing its delegate."

# --- the gate -----------------------------------------------------------------

t_section "the autoCache gate: prefetch is what it costs, not correctness"
qp_assert "with the gate off a wall has a zero buffer" g.buffer 0
qp_assert "and 9 delegates - the viewport alone" g.live 9
qp_assert "which is fewer than the 17 the buffer buys" g.fewerThanBuffered true
qp_assert "and its far end is not built" g.lastLive false
t_note "300px/36px = 8.3, so a 300px viewport covers nine rows and a zero buffer builds exactly those. The 17 above is that nine plus the buffer's eight a side."
qp_assert "eight rows with the gate off are all built" g.smallLive 8
qp_assert "the whole eight-row model" g.smallWhole true
qp_assert "including the last" g.smallLastLive true
qp_assert "and the same eight with the buffer on are also all built" g.bufferedSmallLive 8
qp_assert "the whole model there too" g.bufferedSmallWhole true
t_note "Eight rows at a 36px pitch is 250px, inside the 300px viewport, so the buffer has nothing to add: with the gate off or on the list is built whole. That is what makes the gate safe to expose - turning it off costs prefetch on anything long, and nothing at all on anything the viewport already covers."

# --- stability ----------------------------------------------------------------

t_section "the counts are settled, not merely a first reading"
t_note "A bound is only worth asserting if the view has stopped instantiating by the time it is read. Each count is taken once in the phase that measures it and re-read a beat later; a rising number would mean 'bounded' had only held so far."
qp_assert "the sub-threshold list is still whole" z.subLive 149
qp_assert "unchanged" z.subUnchanged true
qp_assert "and still whole" z.subStillWhole true
qp_assert "the wall is still 17" z.wallLive 17
qp_assert "unchanged" z.wallUnchanged true
qp_assert "the 4-digit list is still 17" z.hugeLive 17
qp_assert "unchanged" z.hugeUnchanged true
qp_assert "and still flat against the wall" z.hugeStillFlat true
qp_assert "nothing threw while reading them" z.probeThrew 0

# --- the reported cost --------------------------------------------------------

t_section "the cost, measured and deliberately not asserted"
t_note "Build time is a property of this machine's CPU and of the offscreen platform plugin, so it is reported rather than pinned - a millisecond assertion here would be flaky by construction. The delegate count is the part of the cost that belongs to the component, and it is asserted above. The figures this run measured:"
t_note "rebuilding the 2000-row list: $(qp_get c.buildMs)ms, leaving $(qp_get c.buildLive) delegates live of $(qp_get c.buildRows) rows"
t_note "rebuilding the 149-row list: $(qp_get c.smallBuildMs)ms, leaving $(qp_get c.smallBuildLive) delegates live of $(qp_get c.smallBuildRows) rows"
t_note "A model swap does not build the model - both rebuilds land at the viewport band whatever the row count, which is the same flatness the static counts show. A cold first build is the expensive case, and it is bounded by the buffer, not by the row count."

t_summary
