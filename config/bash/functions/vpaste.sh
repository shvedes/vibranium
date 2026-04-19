vpaste() {
  READLINE_LINE+=$(wl-paste)
  READLINE_POINT=${#READLINE_LINE}
}

bind -x '"\C-y":vpaste'
