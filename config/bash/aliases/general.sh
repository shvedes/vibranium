alias se="sudoedit"

if command -v imv >/dev/null; then
  alias imv="imv-dir"
fi

if command -v nvim >/dev/null; then
  alias v="nvim"
elif command -v vim >/dev/null; then
  alias v="vim"
fi
