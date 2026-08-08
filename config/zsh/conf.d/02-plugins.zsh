
# Load system-installed zsh plugins from /usr/share/zsh/plugins.
# Each plugin subdirectory must contain a <name>.zsh entry point; only
# that file is sourced, not internals. zsh-syntax-highlighting must be
# sourced last (per its README: after all plugins that add zle widgets,
# e.g. zsh-autosuggestions), and zsh-history-substring-search must be
# sourced before it (per its README), so both are pinned at the end.

plugins_dir=/usr/share/zsh/plugins

plugins=()
for dir in $plugins_dir/*(/N); do
  plugins+=$dir:t
done

pinned=(zsh-history-substring-search zsh-syntax-highlighting)

for plugin in ${plugins:|pinned} $pinned; do
  plugin_file="$plugins_dir/$plugin/$plugin.zsh"
  if [[ -f "$plugin_file" ]]; then
    source "$plugin_file"
  fi
done

# Customize the suggestion strategy when zsh-autosuggestions is installed.
if [[ -f "$plugins_dir/zsh-autosuggestions/zsh-autosuggestions.zsh" ]]; then
  # Fish-like (sort of) suggestion strategy.
  ZSH_AUTOSUGGEST_STRATEGY=(match_prev_cmd history completion)
fi

# Cleanup
unset plugins_dir plugins plugin_file
