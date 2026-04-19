function flist() {
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/bash/functions"
  local -a funcs=()
  local prev_line=""

  # Only valid identifier chars — avoids the '(' inside '[^...]' which
  # breaks bash's regex engine. Trailing '()' on the name is excluded
  # naturally since '(' is not in [a-zA-Z0-9_-].
  local re_func='^[[:space:]]*function[[:space:]]+([a-zA-Z_][a-zA-Z0-9_-]*)'
  local re_desc='^[[:space:]]*#[[:space:]]*@description[[:space:]]+(.*)'

  for file in "$dir"/*.sh; do
    [[ -f "$file" ]] || continue

    # Read the first two lines and require both markers to be present.
    local line1 line2
    {
      IFS= read -r line1
      IFS= read -r line2
    } <"$file"
    [[ "$line1" =~ ^[[:space:]]*#[[:space:]]*@vibranium ]] || continue
    [[ "$line2" =~ ^[[:space:]]*#[[:space:]]*@description ]] || continue

    while IFS= read -r line; do
      if [[ "$line" =~ $re_func ]]; then
        local name="${BASH_REMATCH[1]}"
        local desc=""

        if [[ "$prev_line" =~ $re_desc ]]; then
          desc="${BASH_REMATCH[1]}"
        fi

        funcs+=("$name|$desc")
      fi
      prev_line="$line"
    done <"$file"

    prev_line=""
  done

  local max_len=0
  for f in "${funcs[@]}"; do
    local n="${f%%|*}"
    ((${#n} > max_len)) && max_len=${#n}
  done

  local name_col_width=$((max_len + 3))

  printf '\033[1;37m%-*s  | %s\033[0m\n' "$name_col_width" "Function" "Description"
  printf '%*s\n' "$((name_col_width + 25))" '' | tr ' ' '-'

  for f in "${funcs[@]}"; do
    printf '\033[0;32m%-*s\033[0m  | \033[0;33m%s\033[0m\n' \
      "$name_col_width" "${f%%|*}" "${f#*|}"
  done
}
