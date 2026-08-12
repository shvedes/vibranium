#!/bin/bash

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

printf "%s[QSTN]%s What is your shell of choice?\n" "$C" "$RS"

for i in "${!shells[@]}"; do
  printf "%s[????]%s %s%d)%s %s\n" "$C" "$RS" "$Y" "$((i + 1))" "$RS" "${shells[$i]}"
done

while true; do
  printf "%s[>>>>]%s Enter number (1-%d) [default is %s]: %s" \
    "$C" "$RS" "${#shells[@]}" "${SHELL##*/}" "$Y"
  trap 'printf "%s" "$RS"' INT

  term::enable_input
  read -r shell_idx
  term::disable_input

  printf "%s" "$RS"
  trap - INT

  default_shell_idx=1
  active_shell="${SHELL##*/}"

  for i in "${!shell_pkgs[@]}"; do
    if [[ "${shell_pkgs[$i]}" == "$active_shell" ]]; then
      default_shell_idx=$((i + 1))
      break
    fi
  done

  shell_idx="${shell_idx:-$default_shell_idx}"

  if [[ "$shell_idx" =~ ^[0-9]+$ ]] && ((shell_idx >= 1 && shell_idx <= ${#shells[@]})); then
    selected_shell="${shells[$((shell_idx - 1))]}"
    selected_shell_pkg="${shell_pkgs[$((shell_idx - 1))]}"

    if [[ "$selected_shell" == "Other" ]]; then
      printf "%s[>>>>]%s Enter package name: %s" "$C" "$RS" "$Y"
      trap 'printf "%s" "$RS"' INT

      term::enable_input
      read -r custom_shell_pkg
      term::disable_input

      printf "%s" "$RS"
      trap - INT

      [[ -n "$custom_shell_pkg" ]] && packages+=("$custom_shell_pkg")
    elif [[ -n "$selected_shell_pkg" ]]; then
      packages+=("$selected_shell_pkg")

      if [[ "$selected_shell_pkg" == "bash" ]]; then
        packages+=("bash-completion")
      elif [[ "$selected_shell_pkg" == "zsh" ]]; then
        packages+=(
          "zsh-syntax-highlighting"
          "zsh-autosuggestions"
        )
      fi
    fi
    break
  fi
done

for pkg in "${packages[@]}"; do
  printf "%s\n" "$pkg" >> /tmp/vibranium.packages
done

echo "$packages" > /tmp/shell
