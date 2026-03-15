#!/usr/bin/env bash

if ! term::ask_yes_no N "Would you like to install gaming-related packages?"; then
  exit 0
fi

mapfile -t packages < <(grep -Ev '^(#|$)' "$VIBRANIUM/install/vb-gaming.pkgs")

if term::ask_yes_no Y "Install Heroic Games Launcher (AUR)?"; then
  packages+=(heroic-games-launcher)
fi

if term::ask_yes_no Y "Install RetroArch?"; then
  packages+=(libretro)
fi

# 🤓
if term::ask_yes_no Y "Install official Minecraft Launcher (AUR)?"; then
  packages+=(minecraft-launcher)
else
  if term::ask_yes_no Y "Oh, you want PrismLauncher?"; then
    packages+=(prismlauncher)
  else
    if term::ask_yes_no Y "Aha, got you! You want cracked PrismLauncher, right?"; then
      if term::ask_yes_no Y "Git branch (y) or pre-compiled (n)?"; then
        packages+=(prismlauncher-offline)
      else
        packages+=(prismlauncher-offline-bin)
      fi
    else
      _log_info "Fine, fine.. Sorry for bothering you.."
    fi
  fi
fi

for pkg in "${packages[@]}"; do
  printf "%s\n" "$pkg" >> /tmp/vibranium.packages
done

touch /tmp/vb-uncomment-mangohud
UpdateSummary "User choice: installed gaming packages"
