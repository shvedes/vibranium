#!/bin/bash

packages=()

browsers=(
  "Firefox"
  "Google Chrome (ungoogled)"
  "Brave"
  "Vivaldi"
  "LibreWolf"
  "Opera"
  "None"
  "Other"
)
browser_pkgs=(
  "firefox"
  "ungoogled-chromium"
  "brave-bin"
  "vivaldi"
  "librewolf-bin"
  "opera"
  ""
  ""
)

printf "%s[QSTN]%s What is your browser of choice?\n" "$C" "$RS"

for i in "${!browsers[@]}"; do
  printf "%s[????]%s %s%d)%s %s\n" "$C" "$RS" "$Y" "$((i + 1))" "$RS" "${browsers[$i]}"
done

echo -e "${C}[QSTN]${RS} Note: ${C}Chromium${RS} is already included"

while true; do
  printf "%s[>>>>]%s Enter number (1-%d): %s" "$C" "$RS" "${#browsers[@]}" "$Y"
  trap 'printf "%s" "$RS"' INT

  term::enable_input
  read -r browser_idx
  term::disable_input

  printf "%s" "$RS"
  trap - INT

  if [[ "$browser_idx" =~ ^[0-9]+$ ]] && ((browser_idx >= 1 && browser_idx <= ${#browsers[@]})); then
    selected_browser="${browsers[$((browser_idx - 1))]}"
    selected_browser_pkg="${browser_pkgs[$((browser_idx - 1))]}"

    if [[ "$selected_browser" == "Other" ]]; then
      printf "%s[>>>>]%s Enter package name: %s" "$C" "$RS" "$Y"
      trap 'printf "%s" "$RS"' INT

      term::enable_input
      read -r custom_browser_pkg
      term::disable_input

      printf "%s" "$RS"
      trap - INT

      [[ -n "$custom_browser_pkg" ]] && packages+=("$custom_browser_pkg")
    elif [[ -n "$selected_browser_pkg" ]]; then
      # "None" and any future label-only entries have an empty pkg and are skipped here
      packages+=("$selected_browser_pkg")
    fi
    break
  fi
done

for pkg in "${packages[@]}"; do
  printf "%s\n" "$pkg" >>/tmp/vibranium.packages
done
