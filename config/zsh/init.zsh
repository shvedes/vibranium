
# Don't throw errors when a used path is empty.
setopt null_glob

# Get *this* directory.
# The $ZSH_CONFIG_DIR is defined later.
script_dir="${(%):-%N}"
script_dir="${script_dir:A:h}"

# Source each found .zsh file in the conf.d/
# subdirectory in alphanumerical order.
for f in "$script_dir"/{conf.d,functions}/*.zsh; do
  if [[ -f "$f" ]]; then
    source "$f"
  fi
done

# Cleanup
unset script_dir

# Load custom binds
source "$ZSH_CONFIG_DIR/binds.zsh"

# Zsh won't create the parent dir if it doesn't exist, so...
# HISTFILE defined in conf.d/00-environment.zsh.
if [[ ! -d "${HISTFILE%/*}" ]]; then
  mkdir -p -- "${HISTFILE%/*}"
fi
