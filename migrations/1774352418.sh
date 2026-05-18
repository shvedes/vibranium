if [[ "$CHASSIS_TYPE" == vm ]]; then
  exit 0
fi

sudo pacman -Rnsc --noconfirm hyprpaper
vb-pkg-install --embedded -- awww-git

cp $VIBRANIUM/config/systemd/user/awww.service ~/.config/systemd/user/awww.service

systemctl -q --user daemon-reload
systemctl -q --user enable --now awww

vb-core-wallpaper "$(vb-cmd-get-wallpaper)"
