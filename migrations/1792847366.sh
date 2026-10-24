#!/bin/bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'
SELF="${0##*/}"
SELF="${SELF/.sh/}"

# The launcher cannot evaluate TryExec (Quickshell's DesktopEntries only
# filters Hidden/NoDisplay), so custom entries copied unconditionally by
# older installs linger as dead rows when their tool is absent (MPD,
# Syncthing on fresh installs). Reconcile each one: remove the stale copy
# when the backing executable is missing, install it when present. Fresh
# installs are gated in install/post-install/00-configs.sh; this covers the
# installs that already copied them, and backfills entries for tools the
# user installed afterwards. Idempotent: safe to re-run.
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"

_tryexec_present() {
  [[ -z "$1" ]] && return 0
  command -v "$1" > /dev/null && return 0
  [[ -x "$VIBRANIUM/bin/$1" ]] && return 0
  return 1
}

for entry in "$VIBRANIUM"/applications/custom/*.desktop; do
  [[ -e "$entry" ]] || continue
  base="${entry##*/}"
  tryexec="$(sed -n 's/^TryExec=//p' "$entry" | head -n1)"
  if ! _tryexec_present "$tryexec"; then
    if [[ -e "$data_dir/applications/$base" ]]; then
      echo "${GREEN}[MIGRATION|$SELF]${RESET} Removing stale $base ($tryexec not installed)"
      rm -f "$data_dir/applications/$base"
    fi
    continue
  fi
  if [[ ! -e "$data_dir/applications/$base" ]] || [[ "$entry" -nt "$data_dir/applications/$base" ]]; then
    echo "${GREEN}[MIGRATION|$SELF]${RESET} Installing $base"
    mkdir -p "$data_dir/applications"
    cp -a --no-preserve=ownership "$entry" "$data_dir/applications/$base"
  fi
done

# Fresh clones always carry the xfce4-about NoDisplay override now; installs
# from before it was tracked still show the system entry.
if [[ ! -e "$data_dir/applications/xfce4-about.desktop" ]]; then
  echo "${GREEN}[MIGRATION|$SELF]${RESET} Hiding xfce4-about"
  mkdir -p "$data_dir/applications"
  cp -a --no-preserve=ownership \
    "$VIBRANIUM/applications/hidden/xfce4-about.desktop" \
    "$data_dir/applications/xfce4-about.desktop"
fi
