DIR="${XDG_CONFIG_HOME:-$HOME/.config}/bash/plugins"

if [[ ! -d "$DIR" ]]; then
  mkdir -p "$DIR"
fi

URL="https://raw.githubusercontent.com/nkakouros-original/bash-autopairs/refs/heads/master/autopairs.sh"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/bash/plugins/autopairs.sh"

ensure_internet() {
  if ! curl -fsI --max-time 3 https://raw.githubusercontent.com >/dev/null 2>&1; then
    return 1
  fi
}

if [[ ! -f "$DEST" ]]; then
  echo "Installing plugins"

  if ! ensure_internet; then
    echo "${YELLOW}Warning${RESET}: no internet connection!"
    echo -e "Skipping plugin install\n"
    return 0
  fi

  echo -e "Installing ${YELLOW}autopairs.sh${RESET}\n"

  if curl -sSfL "$URL" -o "$DEST"; then
    return 0
  else
    echo -e "Failed to install ${YELLOW}autopairs.sh${RESET}\n" >&2
    return 1
  fi
fi
