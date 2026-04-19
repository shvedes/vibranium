DIR="${XDG_CONFIG_HOME:-$HOME/.config}/bash/plugins"

if [[ ! -d "$DIR" ]]; then
  mkdir -p "$DIR"
fi

URL="https://raw.githubusercontent.com/nkakouros-original/bash-autopairs/refs/heads/master/autopairs.sh"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/bash/plugins/autopairs.sh"

if [[ ! -f "$DEST" ]]; then
  echo "Installing autopairs.sh"
  if curl -sSfL "$URL" -o "$DEST"; then
    echo "Installed autopairs.sh"
    return 0
  else
    echo "Failed to install autopairs.sh" >&2
    return 1
  fi
fi
