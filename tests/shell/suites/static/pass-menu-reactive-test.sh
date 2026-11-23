#!/bin/bash
# Suite: pass-menu-reactive - the Pass facade's user surface is one derivation.
#
# Pass cannot be constructed offscreen: it is a singleton whose page surface
# reaches Menu -> MenuView -> a PanelWindow backend that offscreen does not
# have. The construction suite already proves the module's declared types;
# this suite pins the contracts that matter to the rewrite as SOURCE rules:
# one deferred publish writes the page/provider tables, row ids are
# path-derived, the credential never becomes a QML property, and the two
# generic menu extensions stay small (option icons and list-row @forget).
# Runtime behavior is exercised against an artificial store over IPC; what is
# pinned here is the shape a future edit must not quietly change.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "pass-menu-reactive" "one derivation owns the two Pass pages"

PASS_SRC="$(<"$SHELL_DIR/features/pass/Pass.qml")"
CTRL_SRC="$(<"$SHELL_DIR/features/pass/PassController.qml")"
MODEL_SRC="$(<"$SHELL_DIR/features/pass/Model.js")"
ENTRY_SRC="$(<"$SHELL_DIR/features/menu/Entry.qml")"
PANEL_SRC="$(<"$SHELL_DIR/features/menu/MenuPanel.qml")"
EDITOR_SRC="$(<"$SHELL_DIR/features/menu/InlineEditor.qml")"
MENUPAGE_SRC="$(<"$SHELL_DIR/features/menu/MenuPage.js")"
OPTROW_SRC="$(<"$SHELL_DIR/features/menu/OptionRow.qml")"
QMLDIR="$(<"$SHELL_DIR/features/pass/qmldir")"

t_section "the facade has no window, no panel and no navigation state"

t_not_contains "no overlay window" "OverlayWindow" "$PASS_SRC"
t_not_contains "no per-screen variants" "Variants" "$PASS_SRC"
t_not_contains "no old row renderer" "PassPanel" "$PASS_SRC"
t_not_contains "no mode/currentDir navigation" "property string currentDir" "$PASS_SRC"
t_contains "the only surface is two dynamic pages" "readonly property string menuPage" "$PASS_SRC"
t_contains "and the vault page id" "readonly property string vaultPage" "$PASS_SRC"
t_not_contains "the module no longer declares the panel" "PassPanel" "$QMLDIR"
t_not_contains "nor the old entry" "PassEntry" "$QMLDIR"
t_contains "the module still declares the facade" "singleton Pass" "$QMLDIR"
t_contains "and the headless store engine" "PassController" "$QMLDIR"

t_section "one state, one deferred publish"

t_contains "the five facts are read together" "readonly property var pageFacts" "$PASS_SRC"
t_contains "entries" "entries: root.entries" "$PASS_SRC"
t_contains "allDirs" "allDirs: root.allDirs" "$PASS_SRC"
t_contains "gitReady" "gitReady: root.gitReady" "$PASS_SRC"
t_contains "passBinary" "passBinary: root.passBinary" "$PASS_SRC"
t_contains "initialized" "initialized: root.initialized" "$PASS_SRC"
t_contains "the fact binding only arms" "onPageFactsChanged: root._schedulePublish()" "$PASS_SRC"
t_contains "publishing is deferred off the binding edge" "Qt.callLater(root._publish)" "$PASS_SRC"
t_eq "one publish function owns the page table" "1" "$(grep -c '^  function _publish()' <<<"$PASS_SRC")"
t_eq "both pages are injected there" "2" "$(grep -c 'Menu.injectPage(Menu.buildDynamicPage' <<<"$PASS_SRC")"
t_contains "search opt-out keeps vault names out of global search" ", api, false)" "$PASS_SRC"
t_contains "a container drop republishes" "function onPagesDropped()" "$PASS_SRC"
t_contains "the summon lands pass-menu as root frame" "Menu.jumpTo(root.menuPage, 0)" "$PASS_SRC"
t_contains "the keybind's open verb toggles an open Pass page" "if (root.ownsFrame()) return root.close()" "$PASS_SRC"
t_contains "Create here is the first folder child" "const children = [root._createRows(dir)[0]," "$PASS_SRC"
t_contains "with a path-derived separator directly beneath it" 'id: Model.rowId("sep", dir)' "$PASS_SRC"
t_contains "providers are claimed under uid as well as id" "[spec.id, spec.uid]" "$PASS_SRC"
t_contains "a committed flow's close latch is cleared" "Menu.slotCloseFinished({ uid: flowUid })" "$PASS_SRC"
t_contains "unchanged providers are not re-claimed" "nextIds.some((v, i) => v !== oldIds[i])" "$PASS_SRC"
t_contains "a final/skipped select stage commits the flow" "row.commitFlow()" "$ENTRY_SRC"
t_contains "Create has a real icon" 'icon: "file"' "$PASS_SRC"
t_contains "Delete uses the remove glyph" 'icon: "remove"' "$PASS_SRC"
t_contains "Delete is accented red" 'iconAccent: () => "red"' "$PASS_SRC"
t_contains "separators request a visible gap" "sepHeight: 22" "$PASS_SRC"
t_contains "a committed flow resets its wizard cursor" "Menu.resetFlow({ uid: item.uid })" "$PASS_SRC"
t_contains "a separator can override the shared height" "itm && Number(itm.sepHeight) > 0" "$ENTRY_SRC"
t_contains "the staged confirm outranks a group's own view" ": row.confirmOpen ? 1003" "$ENTRY_SRC"
t_contains "Esc steps a flow back instead of folding it" "deep.backFlow()" "$PANEL_SRC"
t_contains "a recycled delegate drops transient row state" "onModelDataChanged:" "$ENTRY_SRC"

t_section "providers keyed by path, not by position"

t_contains "flow callbacks" "runFlow" "$PASS_SRC"
t_contains "confirm callbacks" "runConfirm" "$PASS_SRC"
t_contains "forget callbacks" "forget:" "$PASS_SRC"
t_contains "claim is keyed by row id" "ProviderHost.claimProvider(keys[k], surface, root)" "$PASS_SRC"
t_contains "ids come from the pure helper" "Model.rowId(" "$PASS_SRC"
t_not_contains "no ordinal id" "rowId(String(index))" "$PASS_SRC"
t_contains "the landing is gated on the live page" "Menu.itemByUid(chain[chain.length - 1])" "$PASS_SRC"
t_not_contains "no readiness timer in the landing path" "landingTimer" "$PASS_SRC"

t_section "the credential exit path is unchanged"

t_contains "a single sink" "SecretStore.feed(key, v => copyProc.write(v))" "$PASS_SRC"
t_contains "flags in argv, value on stdin" '["wl-copy", "--sensitive", "--type", "text/plain"]' "$PASS_SRC"
t_contains "stdin closes on the real feed edge" "copyProc.stdinEnabled = false" "$PASS_SRC"
t_contains "the controller never keeps plaintext" "SecretStore.stash" "$CTRL_SRC"
t_not_contains "no decrypted QML property" "property string secret" "$CTRL_SRC"

t_section "pure helpers stay pure"

t_contains "path-derived ids" "function rowId(kind, path)" "$MODEL_SRC"
t_contains "slash validation" "function validPath(path)" "$MODEL_SRC"
t_contains "singular/plural counts" "function countWord(n, singular, plural)" "$MODEL_SRC"
t_contains "folder subtext" "function folderSubtitle(entries, allDirs, dir)" "$MODEL_SRC"
t_contains "focus neighbour" "function neighbourAfter(entries, allDirs, path)" "$MODEL_SRC"
t_not_contains "no Qt import in the model" "import QtQuick" "$MODEL_SRC"

t_section "the two generic menu extensions"

t_contains "the editor forwards one flag" "sensitive: root.sensitive" "$EDITOR_SRC"
t_contains "the reveal eye follows it" "revealable: root.sensitive" "$EDITOR_SRC"
t_contains "caps from the live keyboard" "capsActive: root.sensitive && Core.Keyboard.capsOn" "$EDITOR_SRC"
t_contains "and the press is reported back" "onCapsToggled: if (root.sensitive) Core.Keyboard.toggleCaps()" "$EDITOR_SRC"
t_contains "a flow stage declares sensitivity" "row.flowStep.sensitive === true" "$ENTRY_SRC"
t_contains "list rows can route @forget" 'dc === "@forget"' "$ENTRY_SRC"
t_contains "through the injected page api" "Menu.dynamicApi(Menu.frame.id)" "$ENTRY_SRC"
t_contains "options carry icons" "icon: o.icon" "$MENUPAGE_SRC"
t_contains "and glyphs" "glyph: o.glyph" "$MENUPAGE_SRC"
t_contains "OptionRow paints the icon" "name: midCol.iconName" "$OPTROW_SRC"

t_summary
