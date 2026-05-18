function vpaste() {
  cat <<'EOF' >&2
vpaste: no-op -- impossible to achieve in bash.
However, you can create a custom function and bind it:

vpaste() {
  READLINE_LINE+=$(wl-paste)
  READLINE_POINT=${#READLINE_LINE}
}

bind -x '"\C-y":vpaste'
EOF
  return 1
}
