# @vibranium
# @description Extract archives
function extract() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: ${FUNCNAME[0]} <archive> [archive...]" >&2
    echo "${FUNCNAME[0]}: expected FILE, got nothing" >&2
    return 1
  fi

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: ${FUNCNAME[0]} <archive> [archive...]"
    echo "Supports: .tar, .tar.*, .zip, .7z"
    return 0
  fi

  local archive

  for archive in "$@"; do
    if [[ ! -f "$archive" ]]; then
      echo "File not found: $archive" >&2
      return 1
    fi

    case "$archive" in
    *.tar | *.tar.*)
      if ! tar -xaf "$archive"; then
        echo "Failed to extract $archive" >&2
        return 1
      fi
      ;;

    *.zip)
      if ! command -v unzip >/dev/null 2>&1; then
        echo "Couldn't extract $archive: command unzip not found" >&2
        return 1
      fi

      if ! unzip "$archive"; then
        echo "Failed to extract $archive" >&2
        return 1
      fi
      ;;

    *.7z)
      if ! command -v 7z >/dev/null 2>&1; then
        echo "Couldn't extract $archive: command 7z not found" >&2
        return 1
      fi

      if ! 7z x "$archive"; then
        echo "Failed to extract $archive" >&2
        return 1
      fi
      ;;

    *)
      echo "Unknown format: $archive" >&2
      return 1
      ;;
    esac

    echo "Extracted $archive"
  done
}
