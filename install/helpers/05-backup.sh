#!/usr/bin/env bash

_VB_BACKUP_HOME_STORE="$HOME/.local/state/vibranium/backup/home"
_VB_BACKUP_SYSTEM_STORE="$HOME/.local/state/vibranium/backup/home"

# Decide whether a path needs sudo to touch.
helpers::_needs_sudo() {
  local path="$1"
  [[ "$path" != "$HOME" && "$path" != "$HOME"/* ]]
}

# Print the sudo command to use for a path, or nothing for plain $HOME paths.
# Usage: local as_root; as_root=$(helpers::_sudo_for "$path"); $as_root cp ...
helpers::_sudo_for() {
  if helpers::_needs_sudo "$1"; then
    printf 'sudo'
  fi
}

# Map an original absolute path to its backup path and manifest file.
# Sets the globals _VB_BK_PATH and _VB_BK_MANIFEST.
helpers::_resolve_backup_path() {
  local original="$1"
  local store rel

  if [[ "$original" == "$HOME" || "$original" == "$HOME"/* ]]; then
    store="$_VB_BACKUP_HOME_STORE"
    rel="${original#"$HOME"/}"
  else
    store="$_VB_BACKUP_SYSTEM_STORE"
    rel="${original#/}"
  fi

  _VB_BK_PATH="$store/$rel"
  _VB_BK_MANIFEST="$(dirname "$store")/manifest.log"
}

# Back up a single path (file, directory, or symlink) if it currently
# exists and has not been backed up before.
helpers::backup_path() {
  local original="$1"
  local as_root kind

  # Nothing on disk, nothing to preserve.
  if [[ ! -e "$original" && ! -L "$original" ]]; then
    return 0
  fi

  helpers::_resolve_backup_path "$original"

  # Already captured on an earlier run; never overwrite a real backup
  # with a possibly already-modified copy.
  if [[ -e "$_VB_BK_PATH" || -L "$_VB_BK_PATH" ]]; then
    return 0
  fi

  as_root=$(helpers::_sudo_for "$_VB_BK_PATH")
  $as_root mkdir -p "$(dirname "$_VB_BK_PATH")"

  # cp -a preserves permissions, ownership, timestamps, and symlinks.
  if ! $as_root cp -a "$original" "$_VB_BK_PATH" 2>/dev/null; then
    helpers::log::warn "Could not back up ${original}, continuing without a backup for it"
    return 1
  fi

  if [[ -L "$original" ]]; then
    kind=symlink
  elif [[ -d "$original" ]]; then
    kind=dir
  else
    kind=file
  fi

  $as_root mkdir -p "$(dirname "$_VB_BK_MANIFEST")"
  printf '%(%Y-%m-%d %H:%M:%S)T\t%s\t%s\t%s\n' -1 \
    "$original" "$_VB_BK_PATH" "$kind" | $as_root tee -a "$_VB_BK_MANIFEST" >/dev/null

  return 0
}

# Write stdin (typically a heredoc) to a file, backing up whatever was there before.
helpers::write_file() {
  local dest="$1"
  local as_root

  helpers::backup_path "$dest"

  as_root=$(helpers::_sudo_for "$dest")
  $as_root mkdir -p "$(dirname "$dest")"
  $as_root tee "$dest" >/dev/null
}

# Copy a single file, or a whole directory tree, onto a destination,
# backing up every destination path that already exists and is about to
# be overwritten.
#
# If src is a directory, its contents are merged into dest (dest is
# created if missing); pre-existing files in dest that have no
# counterpart in src are left untouched.
helpers::copy() {
  local src="$1" dest="$2"
  local as_root target rel entry

  as_root=$(helpers::_sudo_for "$dest")

  if [[ -d "$src" && ! -L "$src" ]]; then
    while IFS= read -r -d '' entry; do
      rel="${entry#"$src"/}"
      helpers::backup_path "$dest/$rel"
    done < <(find "$src" \( -type f -o -type l \) -print0)

    $as_root mkdir -p "$dest"
    $as_root cp -aT "$src" "$dest"
  else
    target="$dest"
    [[ -d "$dest" ]] && target="$dest/$(basename "$src")"

    helpers::backup_path "$target"
    $as_root mkdir -p "$(dirname "$target")"
    $as_root cp -a "$src" "$target"
  fi
}

# Create or update a symlink, backing up whatever real file or different
# symlink previously occupied that path.
helpers::symlink() {
  local target="$1" linkpath="$2"
  local as_root

  if [[ -L "$linkpath" && "$(readlink "$linkpath")" == "$target" ]]; then
    return 0
  fi

  helpers::backup_path "$linkpath"

  as_root=$(helpers::_sudo_for "$linkpath")
  $as_root mkdir -p "$(dirname "$linkpath")"
  $as_root ln -sf "$target" "$linkpath"
}

# In-place sed, backing up the file first.
# Usage: helpers::sed "$file" -Ei 's/foo/bar/'
helpers::sed() {
  local file="$1"
  shift
  local as_root
  as_root=$(helpers::_sudo_for "$file")

  helpers::backup_path "$file"
  $as_root sed -i "$@" "$file"
}

# Append a line to a file only if a marker string is not already present,
# backing up the file first.
helpers::append_once() {
  local file="$1" marker="$2" text="$3"
  local as_root
  as_root=$(helpers::_sudo_for "$file")

  if [[ -f "$file" ]] && $as_root grep -qF "$marker" "$file" 2>/dev/null; then
    return 0
  fi

  helpers::backup_path "$file"
  $as_root mkdir -p "$(dirname "$file")"
  printf '%s\n' "$text" | $as_root tee -a "$file" >/dev/null
}

# Remove a file, directory, or symlink, backing it up first.
helpers::remove() {
  local path="$1"
  local as_root

  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return 0
  fi

  as_root=$(helpers::_sudo_for "$path")

  helpers::backup_path "$path"
  $as_root rm -rf "$path"
}

# Print every backup captured so far, across both stores, oldest first.
helpers::backup_list() {
  local manifest store
  for store in "$_VB_BACKUP_HOME_STORE" "$_VB_BACKUP_SYSTEM_STORE"; do
    manifest="$(dirname "$store")/manifest.log"
    [[ -f "$manifest" ]] || continue
    cat "$manifest"
  done
}

# Restore a single path from its backup, overwriting whatever is
# currently there. Returns 1 if no backup exists for that path.
helpers::backup_restore() {
  local original="$1"
  local as_root

  helpers::_resolve_backup_path "$original"

  if [[ ! -e "$_VB_BK_PATH" && ! -L "$_VB_BK_PATH" ]]; then
    helpers::log::error "No backup found for ${original}"
    return 1
  fi

  as_root=$(helpers::_sudo_for "$original")
  $as_root mkdir -p "$(dirname "$original")"

  # Clear whatever currently sits at the path first. Without this, cp
  # refuses to write through an existing symlink, and a directory vs.
  # file type mismatch between the current path and the backup would
  # also fail.
  $as_root rm -rf "$original"
  $as_root cp -a "$_VB_BK_PATH" "$original"
  helpers::log::succsess "Restored ${original} from backup"
}
