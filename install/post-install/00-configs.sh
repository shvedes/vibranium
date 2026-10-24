#!/bin/bash

helpers::log::info "Copying configs"

mkdir -p "$HOME/.local/bin"
mkdir -p "$HOME/.local/state/vibranium"
mkdir -p "$HOME/.local/share/applications"

for entry in "$VIBRANIUM"/config/*; do
  [[ -e "$entry" ]] || continue
  helpers::copy "$entry" "$HOME/.config/${entry##*/}"
done

for entry in "$VIBRANIUM"/config/.*; do
  base="${entry##*/}"
  [[ "$base" == "." || "$base" == ".." ]] && continue
  helpers::copy "$entry" "$HOME/$base"
done

for entry in "$VIBRANIUM"/extras/local/bin/*; do
  [[ -e "$entry" ]] || continue
  helpers::copy "$entry" "$HOME/.local/bin/${entry##*/}"
done

for entry in "$VIBRANIUM"/applications/*.desktop; do
  [[ -e "$entry" ]] || continue
  helpers::copy "$entry" "$HOME/.local/share/applications/${entry##*/}"
done

# Custom entries are conditional: the shell cannot evaluate TryExec
# (Quickshell's DesktopEntries only filters Hidden/NoDisplay), so an entry
# whose backing executable is absent would linger in the launcher as a dead
# row. Skip it here; the migration backfills it once the tool is installed.
_tryexec_present() {
  [[ -z "$1" ]] && return 0
  command -v "$1" > /dev/null && return 0
  [[ -x "$VIBRANIUM/bin/$1" ]] && return 0
  return 1
}
for entry in "$VIBRANIUM"/applications/custom/*.desktop; do
  [[ -e "$entry" ]] || continue
  tryexec="$(sed -n 's/^TryExec=//p' "$entry" | head -n1)"
  if ! _tryexec_present "$tryexec"; then
    helpers::log::info "Skipping ${entry##*/} ($tryexec not installed)"
    continue
  fi
  helpers::copy "$entry" "$HOME/.local/share/applications/${entry##*/}"
done

for entry in "$VIBRANIUM"/applications/hidden/*.desktop; do
  [[ -e "$entry" ]] || continue
  helpers::copy "$entry" "$HOME/.local/share/applications/${entry##*/}"
done
