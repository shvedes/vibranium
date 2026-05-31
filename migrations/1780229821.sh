#!/usr/bin/bash

case "$SHELL" in
  *fish)
    echo -e '\n# Added by Vibranium migration\nalias omarchy-theme-install="vb-theme-install"' >> ~/.config/fish/config.fish
  ;;
  *zsh)
    echo -e '\n# Added by Vibranium migration\nalias omarchy-theme-install="vb-theme-install"' >> ~/.config/zsh/aliases/general.zsh
  ;;
  *bash)
    echo -e '\n# Added by Vibranium migration\nalias omarchy-theme-install="vb-theme-install"' >> ~/.config/bash/aliases/general.sh
  ;;
esac

