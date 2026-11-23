#!/bin/bash
# Suite: pass-pin-tokens - retired with the standalone Pass panel.
#
# The LNC-2 delete pin and LNC-3 deferred row-sync tokens lived entirely in
# PassPanel.qml. That row renderer is gone: the vault is now an ordinary Menu
# page, so row timing, delete confirmation and focus landings are owned by
# Entry.qml, List.qml and MenuPanel.qml and covered by the menu suites. The
# source-extraction probe asserted a file that no longer exists.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "pass-pin-tokens" "retired: row timing moved into the shared menu"

t_note "PassPanel.qml was removed. Its two overlapping-intent token tests now belong to the shared menu's list/reveal and settled-waiter machinery; the facade only publishes facts and releases a focus landing on the panel's settled edge."
t_skip "the PassPanel delete pin generations" "PassPanel.qml no longer exists; staged deletes use the menu's ConfirmSlot and the page api's forget route"
t_skip "the PassPanel deferred sync token" "row installs and landings are MenuPanel.recomputeRows / whenSettled, covered by the menu suites"

t_summary
