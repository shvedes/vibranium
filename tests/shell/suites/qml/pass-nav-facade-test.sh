#!/bin/bash
# Suite: pass-nav-facade - retired with the standalone Pass panel.
#
# The Pass rewrite removed PassPanel and the facade's mode/currentDir/
# selectedPath navigation state. Navigation now belongs to the shared menu
# framework, whose own suites cover the stack, the landing chain and the
# uid-keyed model diff. Keeping this source-extraction probe would assert a
# component and a state writer that no longer exist, so the old checks are
# recorded as skips rather than silently dropped.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "pass-nav-facade" "retired: navigation moved into the shared menu"

t_note "Pass is now two Menu.buildDynamicPage pages (pass-menu, pass-vault) landed with Menu.jumpTo. The facade no longer owns mode/currentDir/selectedPath; the menu owns the stack and the focus. The old probe read PassPanel.qml, which has been removed from the module."
t_skip "the pass panel's single navigation writer" "PassPanel.qml and its navigation state were removed; MenuPanel's landing chain is covered by the menu suites"
t_skip "browseTo/select/back gesture and verb equivalence" "those facade verbs no longer exist; submenu and group navigation are the menu framework's"

t_summary
