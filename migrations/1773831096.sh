#!/usr/bin/env bash

remove=false

if ! command -v rust > /dev/null; then
  vb-pkg-install --embedded -- rust
  remove=true
fi

if [[ -f $VIBRANIUM_PATH/vb-cmd-edit-wm-config ]]; then
  rm -f $VIBRANIUM_PATH/vb-cmd-edit-wm-config
fi

cd $VIBRANIUM/contrib/vb-cmd-edit-wm-config
bash build.sh

if [[ $remove == true ]]; then
  sudo pacman -Rnsc --noconfirm rust &> /dev/null &
fi
