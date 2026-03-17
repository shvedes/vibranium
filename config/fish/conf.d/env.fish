# Use TUI Pinentry prompt when in SSH.
if status is-interactive; and test -t 0
  set -gx GPG_TTY (tty)
  set -gx PINENTRY_USER_DATA tty
end
