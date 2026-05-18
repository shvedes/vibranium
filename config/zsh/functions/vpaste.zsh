# @vibranium
# @description Inline paste from clipboard

function vpaste() {
  cat <<'EOF' >&2
vpaste: no-op -- impossible to achieve in zsh.
However, in zsh this is supported via ZLE widget:

vpaste-widget() {
  LBUFFER+=$(wl-paste)
}

zle -N vpaste-widget
bindkey '^Y' vpaste-widget
EOF
  return 1
}
