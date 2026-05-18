#!/usr/bin/env bash

source vb-lib-core
source $VIBRANIUM/install/helpers/00-logging.sh

packages=()

shells=(
  "Bash"
  "Zsh"
  "Fish"
)
shell_pkgs=(
  "bash"
  "zsh"
  "fish"
)

printf "%s[QSTN]%s What is your shell of choice?\n" "$CYAN" "$RESET"

for i in "${!shells[@]}"; do
  printf "%s[????]%s %s%d)%s %s\n" "$CYAN" "$RESET" "$YELLOW" "$((i + 1))" "$RESET" "${shells[$i]}"
done

while true; do
  printf "%s[>>>>]%s Enter number (1-%d) [default: 1]: %s" "$CYAN" "$RESET" "${#shells[@]}" "$YELLOW"
  trap 'printf "%s" "$RESET"' INT

  term::enable_input
  read -r shell_idx
  term::disable_input

  printf "%s" "$RESET"
  trap - INT

  shell_idx="${shell_idx:-1}" # Default to 1 (Bash) if empty

  if [[ "$shell_idx" =~ ^[0-9]+$ ]] && ((shell_idx >= 1 && shell_idx <= ${#shells[@]})); then
    selected_shell="${shells[$((shell_idx - 1))]}"
    selected_shell_pkg="${shell_pkgs[$((shell_idx - 1))]}"

    if [[ "$selected_shell" == "Other" ]]; then
      printf "%s[>>>>]%s Enter package name: %s" "$CYAN" "$RESET" "$YELLOW"
      trap 'printf "%s" "$RESET"' INT

      term::enable_input
      read -r custom_shell_pkg
      term::disable_input

      printf "%s" "$RESET"
      trap - INT

      [[ -n "$custom_shell_pkg" ]] && packages+=("$custom_shell_pkg")
    elif [[ -n "$selected_shell_pkg" ]]; then
      packages+=("$selected_shell_pkg")
    fi
    break
  fi
done

for pkg in "${packages[@]}"; do
  printf "%s\n" "$pkg" >>/tmp/vibranium.packages
done

echo "$packages" >/tmp/shell
