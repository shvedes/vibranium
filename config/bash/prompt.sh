# Use starship if available
if command -v starship >/dev/null; then
  eval -- "$(/usr/bin/starship init bash --print-full-init)"
  return 0
fi

# Fallback to default
echo "${YELLOW}Warning${RESET}: starship not found, using fallback prompt"

__build_prompt() {
  local last_status=$?

  # ── ANSI colour codes (wrapped in \001…\002 so readline counts them as
  #    non-printing and line-wrapping stays correct) ────────────────────────
  local bold_cyan=$'\001\e[1;36m\002'
  local bold_green=$'\001\e[1;32m\002'
  local bold_red=$'\001\e[1;31m\002'
  local ital_cyan=$'\001\e[3;36m\002'
  local cyan=$'\001\e[36m\002'
  local green=$'\001\e[32m\002'
  local red=$'\001\e[31m\002'
  local gray=$'\001\e[90m\002'
  local yellow=$'\001\e[33m\002'
  local reset=$'\001\e[0m\002'

  # ── Helper: truncate a slash-separated path to at most 2 trailing
  #    components, prefixing with ../ when truncation occurs ────────────────
  __trunc_path() {
    local path="$1"
    local IFS='/'
    local -a parts
    read -ra parts <<<"$path"
    local n=${#parts[@]}
    if ((n > 2)); then
      printf '%s' "../${parts[n-2]}/${parts[n-1]}"
    else
      printf '%s' "$path"
    fi
  }

  # ── Directory string ─────────────────────────────────────────────────────
  local dir_str=""
  local git_root
  git_root=$(git rev-parse --show-toplevel 2>/dev/null)

  if [[ -n "$git_root" ]]; then
    local repo_name cwd
    repo_name=$"${git_root##*/}"
    cwd=$PWD

    if [[ "$cwd" == "$git_root" ]]; then
      # At repo root — show name only
      dir_str="${bold_cyan}${repo_name}${reset} "
    else
      # Inside repo — show name + truncated relative path
      local rel rel_display
      rel="${cwd#${git_root}/}"
      rel_display=$(__trunc_path "$rel")
      dir_str="${bold_cyan}${repo_name}${reset}${cyan}/${rel_display}${reset} "
    fi
  else
    # Not in a git repo — show tilde-home path, truncated
    local cwd display
    cwd=$PWD
    display="${cwd/#$HOME/\~}"
    display=$(__trunc_path "$display")
    dir_str="${cyan}${display}${reset} "
  fi

  # ── Git branch ───────────────────────────────────────────────────────────
  local branch_str=""
  if [[ -n "$git_root" ]]; then
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null)
    [[ -z "$branch" ]] && branch=$(git rev-parse --short HEAD 2>/dev/null)
    [[ -n "$branch" ]] && branch_str="${yellow}at ${ital_cyan}${branch}${reset} "
  fi

  # ── Git status flags ─────────────────────────────────────────────────────
  local status_str=""
  if [[ -n "$git_root" ]]; then
    local gs_flags=""

    # Ahead / behind upstream
    local ab behind_count=0 ahead_count=0
    ab=$(git rev-list --count --left-right "@{upstream}...HEAD" 2>/dev/null)
    if [[ -n "$ab" ]]; then
      read -r behind_count ahead_count <<<"$ab"
      if ((ahead_count > 0 && behind_count > 0)); then
        gs_flags+="${bold_green}⇡${reset} ${ahead_count} ${bold_red}⇣${reset} ${behind_count} "
      elif ((ahead_count > 0)); then
        gs_flags+="${bold_green}⇡${reset} ${ahead_count} "
      elif ((behind_count > 0)); then
        gs_flags+="${bold_red}⇣${reset} ${behind_count} "
      fi
    fi

    # Porcelain file statuses
    local conflicted=0 untracked=0 modified=0 staged=0 renamed=0 deleted=0
    local line xy x y
    while IFS= read -r line; do
      xy="${line:0:2}"
      x="${xy:0:1}"
      y="${xy:1:1}"
      case "$xy" in
      '??')
        untracked=1
        continue
        ;;
      UU | AA | DD | AU | UA | DU | UD)
        conflicted=1
        continue
        ;;
      esac
      case "$x" in
      R) renamed=1 ;;
      D) deleted=1 ;;
      A | C | M) staged=1 ;;
      esac
      case "$y" in
      D) deleted=1 ;;
      M | C) modified=1 ;;
      esac
    done < <(git status --porcelain=v1 2>/dev/null)

    # Stash
    local stashed=0
    if [[ -n "$(git stash list --format='%gd' 2>/dev/null)" ]]; then
      stashed=1
    fi

    # Assemble symbols (same order as original)
    ((conflicted)) && gs_flags+="${red}[!]${reset} "
    ((untracked)) && gs_flags+="${cyan}[U]${reset} "
    ((modified)) && gs_flags+="${green}[M]${reset} "
    ((stashed)) && gs_flags+="${gray}[S]${reset} "
    ((staged)) && gs_flags+="${yellow}[+]${reset} "
    ((renamed)) && gs_flags+="${cyan}[R]${reset} "
    ((deleted)) && gs_flags+="${red}[D]${reset} "

    status_str="$gs_flags"
  fi

  # ── Prompt character (green on success, red on failure) ──────────────────
  local char_str symbol="❯"

  if [[ -c /dev/tty ]] && [[ $TERM == linux ]]; then
    symbol=">"
  fi

  if ((last_status == 0)); then
    char_str="${bold_green}${symbol}${reset} "
  else
    char_str="${bold_red}${symbol}${reset} "
  fi

  PS1="${dir_str}${branch_str}${status_str}${char_str}"
}

PROMPT_COMMAND='__build_prompt'
