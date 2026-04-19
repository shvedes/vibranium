# Use trash-cli when available,
# fallback to plain rm.
function rm() {
  if command -v trash >/dev/null; then
    trash -v "$@"
  else
    command rm "$@"
  fi
}

