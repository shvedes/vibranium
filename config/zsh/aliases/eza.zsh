if command -v eza > /dev/null; then
  alias l="eza --hyperlink=auto"
  alias ls="ezaa --hyperlink=auto"
  alias sl="eza --hyperlink=auto"
  alias ll="eza -lhbg@ --group-directories-first --hyperlink=auto"
  alias la="eza -ahbg@ --group-directories-first --hyperlink=auto"
  alias lla="eza -alhbg@ --group-directories-first --hyperlink=auto"
  alias tree="eza --tree --hyperlink=auto"
fi
