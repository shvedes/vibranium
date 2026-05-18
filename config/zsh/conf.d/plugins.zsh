ZINIT_HOME="${ZSH_CONFIG_DIR}/plugins/zinit"
ZINIT_PLUGINS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/plugins"

add_padding=false

ensure_internet() {
  curl -fsI --max-time 3 https://raw.githubusercontent.com >/dev/null 2>&1
}

_zinit_plugin_dir() {
  echo "${ZINIT_PLUGINS_DIR}/${1/\//---}"
}

# Install (if missing + online) then load a plugin
zinit_ensure() {
  local plugin="$1"
  local plugin_dir
  plugin_dir="$(_zinit_plugin_dir "$plugin")"

  if [[ ! -d "$plugin_dir" ]]; then
    if ! ensure_internet; then
      echo "${YELLOW}Warning${RESET}: no internet connection!" >&2
      echo
      return 1
    fi
    echo "Installing ${YELLOW}$plugin${RESET}"
    add_padding=true
  fi

  zinit light "$plugin" &> /dev/null
}

# Bootstrap zinit
if [[ ! -d "${ZINIT_HOME}/.git" ]]; then
  add_padding=true
  if ! ensure_internet; then
    echo "${YELLOW}Warning${RESET}: no internet connection, skipping plugin isntall" >&2
    echo
    return 0
  fi
  echo "Installing ${YELLOW}plugin manager${RESET}"
  if ! git clone -q https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"; then
    echo "${RED}Error${RESET}: plugin manager installation failed" >&2
    echo
    return 1
  fi
fi

source "${ZINIT_HOME}/zinit.zsh"

zinit_ensure zsh-users/zsh-autosuggestions
zinit_ensure zdharma-continuum/fast-syntax-highlighting
zinit_ensure zsh-users/zsh-completions
zinit_ensure hlissner/zsh-autopair

if $add_padding; then
  echo
fi
