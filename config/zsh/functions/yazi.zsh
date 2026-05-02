if command -v yazi >/dev/null; then
  function y() {
    local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd

    command yazi "$@" --cwd-file="$tmp"
    IFS= read -r -d '' cwd < "$tmp"

    if [ "$cwd" != "$PWD" ] && [ -d "$cwd" ]; then
      builtin cd -- "$cwd"
    fi

    command rm -f -- "$tmp"
  }
fi
