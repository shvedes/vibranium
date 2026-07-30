#!/bin/bash
# Previously vb-cmd-edit-wm-config was a compiled binary gitignored in
# .gitignore.  It is now a Lua script tracked by git.  If the old ELF
# is still on disk (e.g. because the gitignore prevented git from
# removing it), delete it and precompile the editor library.
#
# A plain `git pull` will fail with
#   "untracked working tree file 'bin/vb-cmd-edit-wm-config' would be
#    overwritten by merge"
# -- delete that file, then re-run the update.

if [[ -f "$VIBRANIUM/bin/vb-cmd-edit-wm-config" ]] && file "$VIBRANIUM/bin/vb-cmd-edit-wm-config" | grep -q ELF; then
  rm -f "$VIBRANIUM/bin/vb-cmd-edit-wm-config"
fi

luac -o "$VIBRANIUM_CACHE/editor.luac" "$VIBRANIUM/default/hypr/lib/editor.lua"
