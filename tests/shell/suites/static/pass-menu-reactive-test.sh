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
MENU_SRC="$(<"$SHELL_DIR/features/menu/Menu.qml")"
WIDTH_SRC="$(<"$SHELL_DIR/features/menu/MenuWidth.qml")"
LIB_SRC="$(<"$SHELL_DIR/features/menu/MenuLib.js")"
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
t_contains "Pass rows opt out of the global index" "pageOpts), api, false)" "$PASS_SRC"
t_contains "an empty name closes the flow silently" '&& v0 === "") return true' "$PASS_SRC"
t_not_contains "file rows carry no sub line" 'sub: file.dir' "$PASS_SRC"
t_contains "a container drop republishes" "function onPagesDropped()" "$PASS_SRC"
t_contains "the summon lands pass-menu as root frame" "Menu.jumpTo(root.menuPage, 0)" "$PASS_SRC"
t_contains "the keybind's open verb toggles an open Pass page" "if (root.ownsFrame()) return root.close()" "$PASS_SRC"
t_contains "Create here is the first folder child" "const children = [root._createRows(dir)[0]]" "$PASS_SRC"
t_contains "with a path-derived separator directly beneath it" 'id: Model.rowId("sep", dir)' "$PASS_SRC"
t_contains "a committed flow's close latch is cleared" "Menu.slotCloseFinished({ uid: flowUid })" "$PASS_SRC"
t_contains "a final/skipped select stage commits the flow" "row.commitFlow()" "$ENTRY_SRC"
t_contains "Create has a real icon" 'icon: "file"' "$PASS_SRC"
t_contains "Delete uses the remove glyph" 'icon: "remove"' "$PASS_SRC"
t_contains "Delete is accented red" 'iconAccent: () => "red"' "$PASS_SRC"
t_contains "separators request a visible gap" "sepHeight: 22" "$PASS_SRC"
t_contains "a committed flow resets its wizard cursor" "Menu.resetFlow({ uid: item.uid })" "$PASS_SRC"
t_contains "a separator can override the shared height" "itm && Number(itm.sepHeight) > 0" "$ENTRY_SRC"
t_contains "the staged confirm outranks a group's own view" ": row.confirmOpen ? 1003" "$ENTRY_SRC"
t_contains "Esc steps a flow back instead of folding it" "frow.backFlow()" "$PANEL_SRC"
t_contains "a recycled delegate drops transient row state" "onModelDataChanged:" "$ENTRY_SRC"
t_contains "Delete asks for the red icon colour" 'iconColor: "red"' "$PASS_SRC"
t_contains "the icon colour is a row role" "iconColor: \"\"" "$MENUPAGE_SRC"
t_contains "Entry honours the row icon colour" "String(itm.iconColor" "$ENTRY_SRC"
t_contains "nested delete routes to the focused child" "panel.focusedRow()" "$PANEL_SRC"
t_contains "closing the menu clears flow state" "root._flow = ({})" "$MENU_SRC"
t_contains "an identical projection skips republish" "sig === root._lastPublishSig" "$PASS_SRC"
t_contains "nested dropdown width is measured" "root._groupNeedW(kid, level + 1)" "$WIDTH_SRC"
t_contains "a page may raise its own height ceiling" "effMaxHeight: panel.pageMaxHeight > 0" "$PANEL_SRC"
t_contains "separator height overrides are part of the card estimate" "Number(it.sepHeight) > 0" "$PANEL_SRC"
t_contains "Esc steps back before the field gets it" "frow.backFlow()" "$PANEL_SRC"
t_contains "identity changes reset a delegate's transient state" "_rowUid !== \"\"" "$ENTRY_SRC"
t_contains "flow option labels are measured for card width" "flowph" "$WIDTH_SRC"
t_contains "an empty options array does not hide a flow" "kid.options.length > 0" "$WIDTH_SRC"
t_contains "Delete swallows instead of opening the filter" 'return { name: "delete", arg: null }' "$LIB_SRC"
t_contains "Delete routes only to a deletable child" "kid.itm.delCommand === \"\"" "$PANEL_SRC"
t_contains "the delete hint names the row" "String(itm?.label ?? \"this item\")" "$ENTRY_SRC"
t_contains "hidden values leave the select slot blank" "itm.hideValue" "$ENTRY_SRC"
t_not_contains "Move has no sub line" 'label: "Move", sub:' "$PASS_SRC"
t_contains "summon starts in list mode" "Menu.panel.focusFilter(\"list\")" "$PASS_SRC"
t_not_contains "git rows close after their verb" 'call: "pass push", keepOpen' "$PASS_SRC"
t_contains "a page ceiling cannot exceed the screen" "Math.min(panel.pageMaxHeight, panel.hardMaxHeight)" "$PANEL_SRC"
t_contains "action children carry no copy" 'label: "Copy", icon: "copy"' "$PASS_SRC"
t_contains "file rows take the key delete path" 'delCommand: "@forget"' "$PASS_SRC"
t_contains "a committed delete forces a republish" "onDeleteCommitted: path =>" "$PASS_SRC"

t_section "providers keyed by path, not by position"

t_contains "flow callbacks" "runFlow" "$PASS_SRC"
t_contains "confirm callbacks" "runConfirm" "$PASS_SRC"
t_contains "forget callbacks" "forget:" "$PASS_SRC"
t_contains "one page resolver serves every row id" "provider: id => root._surfaceForId(id)" "$PASS_SRC"
t_contains "menu falls back to the page resolver" "api.provider(id)" "$MENU_SRC"
t_contains "landing seats without center-follow" "list.landIndex(idx)" "$PASS_SRC"
t_contains "the reveal starts on the settled edge" "autoRevealIndex = at2" "$PASS_SRC"
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
t_contains "list rows delegate deletion to the shared owner" "Menu.rowDelete(itm" "$ENTRY_SRC"
# Batch E moved the guarded delete path out of Entry into Menu._runDelete;
# pin the owner rather than the old inline spelling so @forget stays routed.
t_contains "list rows can route @forget" 'dc === "@forget"' "$MENU_SRC"
t_contains "through the injected page api" "root.dynamicApi(root.frame.id)" "$MENU_SRC"
t_contains "options carry icons" "icon: o.icon" "$MENUPAGE_SRC"
t_contains "and glyphs" "glyph: o.glyph" "$MENUPAGE_SRC"
t_contains "OptionRow paints the icon" "name: midCol.iconName" "$OPTROW_SRC"

t_summary
