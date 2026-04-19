# Guard against wiping registered abbreviations on re-source.
[[ -v _ABBR_MAP ]] || declare -A _ABBR_MAP

abbr() {
  local cmd="$1"

  case "$cmd" in
  add)
    local name="$2"
    local expansion="$3"

    if [[ -z "$name" || -z "$expansion" ]]; then
      echo "abbr add: requires both <abbreviation> and <expansion>" >&2
      return 1
    fi

    _ABBR_MAP["$name"]="$expansion"
    ;;

  list)
    if [[ "${#_ABBR_MAP[@]}" -eq 0 ]]; then
      echo "No abbreviations registered."
      return 0
    fi

    # Print in two-column format: abbreviation -> expansion.
    local name
    for name in "${!_ABBR_MAP[@]}"; do
      printf "%-20s %s\n" "$name" "${_ABBR_MAP[$name]}"
    done | sort
    ;;

  *)
    echo "abbr: unknown command '${cmd:-<none>}'" >&2
    echo "usage: abbr add <abbreviation> <expansion>" >&2
    echo "       abbr list" >&2
    return 1
    ;;
  esac
}

_expand_abbr() {
  local before_cursor="${READLINE_LINE:0:$READLINE_POINT}"
  local after_cursor="${READLINE_LINE:$READLINE_POINT}"

  # Grab the last whitespace-delimited word before the cursor.
  local current_word="${before_cursor##* }"

  # ${_ABBR_MAP[$current_word]+x} expands to "x" if the key exists (even if
  # the value is empty), and to "" if the key is absent. Safer than -v with
  # a variable subscript.
  if [[ -n "$current_word" && -n "${_ABBR_MAP[$current_word]+x}" ]]; then
    local expansion="${_ABBR_MAP[$current_word]}"
    local prefix="${before_cursor:0:$((${#before_cursor} - ${#current_word}))}"

    READLINE_LINE="${prefix}${expansion} ${after_cursor}"
    READLINE_POINT=$((${#prefix} + ${#expansion} + 1))
  else
    READLINE_LINE="${before_cursor} ${after_cursor}"
    READLINE_POINT=$((READLINE_POINT + 1))
  fi
}
