
# Don't throw errors when a used path is empty.
shopt -s nullglob

# Get *this* directory.
# The $BASH_CONFIG_DIR is defined later.
script_dir="${BASH_SOURCE[0]%/*}"
script_dir="${script_dir:-.}"

# Source each found .sh file in the conf.d/
# subdirectory in alphanumerical order.
for f in "$script_dir"/{conf.d,functions}/*.sh; do
  if [[ -f "$f" ]]; then
    source "$f"
  fi
done

# Cleanup
unset script_dir

# Load custom binds
source "$BASH_CONFIG_DIR/binds.sh"

# Bash won't create the parent dir if it doesn't exist, so...
# HISTFILE defined in conf.d/00-environment.sh.
if [[ ! -d "${HISTFILE%/*}" ]]; then
  mkdir -p -- "${HISTFILE%/*}"
fi
